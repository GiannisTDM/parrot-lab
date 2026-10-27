import Foundation
import Network
import Darwin

struct AnafiSessionState {
    var connected = false
    var message = "Connect to ANAFI Wi-Fi or SkyController 3"
    var route = AnafiRoute.direct
    var battery: Int?
    var flightState: UInt32?
    var altitude: Double?
    var gpsFix = false
    var camera = AnafiCameraState()
    var linkedAnafi = false
    var macPiloting = false
    var flightLabel: String {
        guard let flightState else { return "Waiting for flight state" }
        return ["Landed", "Taking off", "Hovering", "Flying", "Landing", "Emergency", "User takeoff", "Motor ramping"]
            .enumerated().first(where: { $0.offset == Int(flightState) })?.element ?? "Flight state \(flightState)"
    }
    var canPilot: Bool {
        guard let flightState else { return false }
        return connected && linkedAnafi && macPiloting && [0, 1, 2, 3, 4, 6, 7].contains(flightState)
    }
}

/// ANAFI and SC3 share command/state handling across NET and SC3 libmux.
/// NET resolves SC3 aircraft services at port + 100; MUX uses its IP proxy.
final class AnafiSession {
    var onChange: ((AnafiSessionState) -> Void)?
    var onLog: ((String) -> Void)?
    var onMuxVideo: ((Result<URL, Error>) -> Void)?
    private let queue = DispatchQueue(label: "parrotlab.anafi.session", qos: .userInitiated)
    private let epochs = AnafiCallbackEpoch()
    private let videoEpochs = AnafiCallbackEpoch()
    private var epoch: UInt64 = 0
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var remote: sockaddr_in?
    private var discovery: NWConnection?
    private var mux: SC3MuxBridge?
    private var discoveryData = Data()
    private var timer: DispatchSourceTimer?
    private var reliable = AnafiReliableChannel()
    private var emergency = AnafiReliableChannel(channel: 12, maximumRetries: nil)
    private var sequences: [UInt8: UInt8] = [:]
    private var received: [UInt8: UInt8] = [:]
    private var state = AnafiSessionState()
    private var input = BebopPilotingInput.neutral
    private var pcmdSequence: UInt8 = 0
    private var macRequested = false
    private var startedAt: TimeInterval = 0
    private var lastReceived: TimeInterval = 0
    private var linkedSerial: String?
    private var packets: UInt64 = 0
    private var duplicatePackets: UInt64 = 0

    func connect(host: String, route: AnafiRoute, discoveryPort: UInt16 = 44_444) {
        guard !route.usesMux else { connectMux(link: SC3MuxTCPLink(port: discoveryPort)); return }
        let token = epochs.advance()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token) else { return }
            self.closeLocked(); self.epoch = token; self.state.route = route
            guard AnafiRoute.validHost(host) else { self.fail("Enter a valid IPv4 address"); return }
            do { try self.openSocket() } catch { self.fail(error.localizedDescription); return }
            self.startedAt = ProcessInfo.processInfo.systemUptime
            self.state.message = "Connecting to \(route.title)…"; self.publish()
            guard let endpointPort = NWEndpoint.Port(rawValue: discoveryPort) else { self.fail("Invalid ARSDK discovery port"); return }
            let connection = NWConnection(host: .init(host), port: endpointPort, using: .tcp)
            self.discovery = connection
            connection.stateUpdateHandler = { [weak self, weak connection] status in
                guard let self, let connection, self.epochs.contains(token), self.discovery === connection else { return }
                switch status {
                case .ready:
                    var address = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let result = withUnsafeMutablePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(self.fd, $0, &length) }
                    }
                    guard result == 0 else { self.fail("Could not obtain ANAFI telemetry port"); return }
                    connection.send(content: AnafiCommand.handshake(localPort: UInt16(bigEndian: address.sin_port)),
                                    completion: .contentProcessed { [weak self] error in
                        guard let self, self.epochs.contains(token) else { return }
                        if let error { self.fail(error.localizedDescription) }
                        else { self.receiveDiscovery(host: host, token: token) }
                    })
                case .failed(let error): self.fail("\(route.title): \(error.localizedDescription). Check the Mac's network connection.")
                default: break
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick(token) }
            self.timer = timer; timer.resume()
            connection.start(queue: self.queue)
        }
    }
    func connectMux(link: SC2MuxByteLink) {
        let token = epochs.advance()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token) else { return }
            self.neutralLocked(); self.closeLocked(); self.epoch = token; self.state.route = .skyController3Mux
            self.startedAt = ProcessInfo.processInfo.systemUptime
            self.state.message = "Connecting to SC3 USB bridge…"; self.publish()
            let mux = SC3MuxBridge(); self.mux = mux
            mux.onConnected = { [weak self] in
                self?.queue.async {
                    guard let self, self.epochs.contains(token) else { return }
                    self.state.connected = true; self.lastReceived = ProcessInfo.processInfo.systemUptime
                    self.state.message = "SC3 USB connected · waiting for ANAFI"
                    _ = self.reliable.enqueue(ARSDKPhotoCommand.requestAllSettings)
                    _ = self.reliable.enqueue(ARSDKPhotoCommand.requestAllStates)
                    _ = self.reliable.enqueue(ARSDKPhotoCommand.requestSkyControllerAllStates)
                    self.flushReliable(); self.publish(); self.log("SC3 libmux command channels ready · ARSDK v1")
                }
            }
            mux.onTransport = { [weak self] bytes in
                self?.queue.async {
                    guard let self, self.epochs.contains(token), self.state.connected,
                          let frames = AnafiNetworkFrame.decode(bytes) else { return }
                    self.consumeFrames(frames)
                }
            }
            mux.onClosed = { [weak self] message in
                self?.queue.async { guard let self, self.epochs.contains(token) else { return }; self.fail(message) }
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick(token) }
            self.timer = timer; timer.resume(); mux.start(link: link)
        }
    }
    func startMuxVideo() {
        let token = currentEpoch()
        let videoToken = videoEpochs.advance()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token), self.videoEpochs.contains(videoToken) else { return }
            self.mux?.startVideo { [weak self] result in
                self?.videoEpochs.deliver(videoToken) { [weak self] in
                    guard let self, self.epochs.contains(token) else { return }; self.onMuxVideo?(result)
                }
            }
        }
    }
    func stopMuxVideo() {
        let token = currentEpoch()
        _ = videoEpochs.advance()
        queue.async { [weak self] in guard let self, self.epochs.contains(token) else { return }; self.mux?.stopVideo() }
    }
    func disconnect() {
        let token = epochs.advance()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token) else { return }
            self.neutralLocked()
            // SC3 also resets piloting ownership on disconnect. Best effort
            // restore before releasing the session, never transfer on connect.
            if self.state.route.isSC3, self.macRequested {
                self.write(self.reliable.closingPacket(AnafiCommand.pilotingSource(mac: false)))
            }
            self.closeLocked(); self.epoch = token; self.publish()
        }
    }
    func disconnectAndWait() { disconnect(); queue.sync {} }
    func send(_ payload: Data, reliable: Bool = true) {
        let token = currentEpoch()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token), self.state.connected else { return }
            if reliable {
                guard self.reliable.enqueue(payload) else { self.log("ANAFI command queue is full"); return }
                self.flushReliable()
            } else { self.sendFrame(type: 2, channel: 10, payload: payload) }
        }
    }
    func sendEmergency() {
        let token = currentEpoch()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token), self.state.connected, self.state.linkedAnafi else { return }
            self.neutralLocked(); self.macRequested = false; self.state.macPiloting = false
            // The XML marks Emergency HIGH_PRIO/RETRY. Its independent channel
            // must not wait behind camera commands or stop after five retries.
            if self.emergency.pending == nil, self.emergency.queued.isEmpty {
                _ = self.emergency.enqueue(ARSDKPhotoCommand.emergency)
            }
            self.flushReliable(); self.publish()
        }
    }
    func setMacPiloting(_ enabled: Bool) {
        let token = currentEpoch()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token), self.state.connected else { return }
            guard !enabled || (self.emergency.pending == nil && self.emergency.queued.isEmpty) else { return }
            self.neutralLocked(); self.macRequested = enabled
            if self.state.route.isSC3 {
                self.state.macPiloting = false // wait for CoPilotingState confirmation
                _ = self.reliable.enqueue(AnafiCommand.pilotingSource(mac: enabled)); self.flushReliable()
            } else { self.state.macPiloting = enabled }
            self.publish()
        }
    }
    func updateInput(_ value: BebopPilotingInput) {
        let token = currentEpoch()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token) else { return }
            self.input = self.state.canPilot ? value : .neutral
        }
    }
    private let epochLock = NSLock()
    private var publishedEpoch: UInt64 = 0
    private func currentEpoch() -> UInt64 { epochLock.lock(); defer { epochLock.unlock() }; return publishedEpoch }
    private func publish() {
        epochLock.lock(); publishedEpoch = epoch; epochLock.unlock()
        let snapshot = state
        epochs.deliver(epoch) { [weak self] in self?.onChange?(snapshot) }
    }
    private func log(_ message: String) { epochs.deliver(epoch) { [weak self] in self?.onLog?(message) } }
    private func openSocket() throws {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { throw socketError() }
        fd = socket
        _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
        guard fcntl(socket, F_SETFL, O_NONBLOCK) == 0 else { throw socketError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw socketError() }
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        let token = epoch
        source.setEventHandler { [weak self] in
            guard let self, self.epochs.contains(token), self.fd == socket else { return }
            self.readLocked()
        }
        source.setCancelHandler { Darwin.close(socket) }
        readSource = source; source.resume()
    }
    private func receiveDiscovery(host: String, token: UInt64) {
        guard let discovery else { return }
        discovery.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak discovery] data, _, complete, error in
            guard let self, let discovery, self.epochs.contains(token), self.discovery === discovery else { return }
            if let data { self.discoveryData.append(data) }
            guard self.discoveryData.count <= 65_536 else { self.fail("ANAFI discovery reply too large"); return }
            if let object = ARSDKDiscoveryProtocol.responseObject(from: self.discoveryData) {
                guard let port = AnafiCommand.commandPort(object) else {
                    self.fail("ANAFI rejected the connection or requires an unsupported protocol version"); return
                }
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { self.fail("Invalid ANAFI address"); return }
                self.remote = address
                self.discovery = nil; discovery.cancel()
                self.state.connected = true; self.state.linkedAnafi = self.state.route == .direct
                self.state.message = self.state.route == .direct ? "Connected to ANAFI 4K" : "SC3 connected · waiting for ANAFI"
                self.lastReceived = ProcessInfo.processInfo.systemUptime
                _ = self.reliable.enqueue(ARSDKPhotoCommand.requestAllSettings)
                _ = self.reliable.enqueue(ARSDKPhotoCommand.requestAllStates)
                if self.state.route.isSC3 { _ = self.reliable.enqueue(ARSDKPhotoCommand.requestSkyControllerAllStates) }
                self.flushReliable(); self.publish()
                self.log("ANAFI ARSDK-ng v1 ready via \(self.state.route.title); video uses RTSP port \(self.state.route.videoPort)")
                return
            }
            if let error { self.fail(error.localizedDescription) }
            else if complete { self.fail("Incomplete ANAFI discovery reply") }
            else { self.receiveDiscovery(host: host, token: token) }
        }
    }
    private func readLocked() {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<128 {
            var sender = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &bytes, bytes.count, 0, $0, &length) }
            }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK { fail("ANAFI telemetry read failed") }
                return
            }
            guard let remote, sender.sin_addr.s_addr == remote.sin_addr.s_addr,
                  let frames = AnafiNetworkFrame.decode(Data(bytes.prefix(count))) else { continue }
            consumeFrames(frames)
        }
    }
    private func consumeFrames(_ frames: [AnafiNetworkFrame]) {
        lastReceived = ProcessInfo.processInfo.systemUptime
        var changed = false
        for frame in frames {
                packets &+= 1
                if frame.type == 1, let sequence = frame.payload.first {
                    if frame.channel == 139 { reliable.acknowledge(sequence); flushReliable(); continue }
                    if frame.channel == 140 { emergency.acknowledge(sequence); flushReliable(); continue }
                }
                if frame.type == 2, frame.channel == 0 { sendFrame(type: 2, channel: 1, payload: frame.payload); continue }
                guard (125...127).contains(frame.channel), frame.type == 2 || frame.type == 4 else { continue }
                if frame.type == 4 { sendFrame(type: 1, channel: frame.channel &+ 128, payload: Data([frame.sequence])) }
                if let previous = received[frame.channel] {
                    let distance = frame.sequence &- previous
                    if distance == 0 || distance >= 128 { duplicatePackets &+= 1; continue }
                }
                received[frame.channel] = frame.sequence
                changed = consume(frame.payload) || changed
        }
        if changed { publish() }
    }
    private func consume(_ data: Data) -> Bool {
        var reader = AnafiWireReader(data)
        guard let feature = reader.byte(), let cls = reader.byte(), let command = reader.integer(UInt16.self) else { return false }
        if state.route.isSC3, feature == 137, cls == 0, command == 5 {
            guard let status = reader.integer(UInt32.self), let serial = reader.string(),
                  let model = reader.integer(UInt16.self), let name = reader.string() else { return false }
            let linked = status == 3 && model == 0x0914
            if !linked || serial != linkedSerial {
                neutralLocked(); state.camera = AnafiCameraState(); state.battery = nil
                state.flightState = nil; state.altitude = nil; state.gpsFix = false
            }
            state.linkedAnafi = linked; linkedSerial = linked ? serial : nil
            state.message = linked ? "SC3 → \(name)" : "SC3 connected · pair an ANAFI 4K in FreeFlight"
            if linked { _ = reliable.enqueue(ARSDKPhotoCommand.requestAllStates); flushReliable() }
            return true
        }
        if feature == 4, cls == 21, command == 0, let source = reader.integer(UInt32.self) {
            state.macPiloting = macRequested && source == 1
            if !state.macPiloting { input = .neutral }
            return true
        }
        guard state.linkedAnafi else { return false }
        if state.camera.consume(data) { return true }
        guard let event = ARSDKTelemetryProtocol.decode(data) else { return false }
        switch event {
        case .droneBattery(let value): state.battery = min(100, max(0, value))
        case .flyingState(let value): state.flightState = value
        case .altitude(let value): state.altitude = value
        case .gpsFix(let value): state.gpsFix = value
        case .flatTrimChanged: log("ANAFI flat trim confirmed")
        default: return false
        }
        return true
    }
    private func tick(_ token: UInt64) {
        guard epochs.contains(token) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !state.connected {
            if now - startedAt > 8 { fail("\(state.route.title) connection timed out. Ensure its network is available on this Mac.") }
            return
        }
        if now - lastReceived > 5 { neutralLocked(); fail("ANAFI telemetry lost · Mac controls neutralized"); return }
        flushReliable()
        if reliable.failed, emergency.pending == nil { neutralLocked(); fail("ANAFI command acknowledgement timed out"); return }
        if state.canPilot { sendPCMD() }
    }
    private func neutralLocked() {
        input = .neutral
        if state.canPilot { sendPCMD() }
    }
    private func sendPCMD() {
        pcmdSequence &+= 1
        let timestamp = UInt32(truncatingIfNeeded: UInt64(ProcessInfo.processInfo.systemUptime * 1000)) & 0x00ff_ffff
        let payload = ARSDKPhotoCommand.pcmd(flag: input.flag, roll: input.roll, pitch: input.pitch,
                                           yaw: input.yaw, gaz: input.gaz,
                                           timestampAndSequence: timestamp | UInt32(pcmdSequence) << 24)
        sendFrame(type: 2, channel: 10, payload: payload)
    }
    private func flushReliable() {
        if let packet = emergency.next(now: ProcessInfo.processInfo.systemUptime) { write(packet) }
        guard emergency.pending == nil else { return }
        if let packet = reliable.next(now: ProcessInfo.processInfo.systemUptime) { write(packet) }
    }
    private func sendFrame(type: UInt8, channel: UInt8, payload: Data) {
        let sequence = (sequences[channel] ?? 0) &+ 1; sequences[channel] = sequence
        write(ARSDKPhotoProtocol.frame(type: type, id: channel, sequence: sequence, payload: payload))
    }
    private func write(_ packet: Data) {
        if let mux { mux.sendTransport(packet); return }
        guard fd >= 0, var remote else { return }
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        if sent < 0, errno != EAGAIN && errno != EWOULDBLOCK { fail("ANAFI command write failed") }
    }
    private func fail(_ message: String) {
        guard let token = epochs.retire(epoch) else { return }
        neutralLocked()
        closeLocked(); epoch = token; state.message = message; publish(); log(message)
    }
    private func closeLocked() {
        _ = videoEpochs.advance()
        mux?.stop(); mux = nil
        timer?.cancel(); timer = nil; discovery?.cancel(); discovery = nil
        if let readSource { readSource.cancel() } else if fd >= 0 { Darwin.close(fd) }
        readSource = nil; fd = -1; remote = nil; discoveryData = Data()
        let route = state.route; state = AnafiSessionState(); state.route = route
        reliable = AnafiReliableChannel(); emergency = AnafiReliableChannel(channel: 12, maximumRetries: nil)
        sequences.removeAll(); received.removeAll()
        input = .neutral; macRequested = false; linkedSerial = nil
    }
    private func socketError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    func diagnostics(completion: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let message = "ANAFI generation=\(self.epoch) route=\(self.state.route.title) connected=\(self.state.connected) " +
                "linked=\(self.state.linkedAnafi) mac-controls=\(self.state.macPiloting) rx=\(self.packets) duplicates=\(self.duplicatePackets) " +
                "ack-pending=\(self.reliable.pending?.sequence.description ?? "none") queued=\(self.reliable.queued.count) " +
                "emergency-ack=\(self.emergency.pending?.sequence.description ?? "none") " +
                (self.mux?.diagnosticSummary ?? "")
            self.epochs.deliver(self.epoch) { completion(message) }
        }
    }
    deinit { timer?.cancel(); discovery?.cancel(); readSource?.cancel(); mux?.stop() }
}
