import Foundation
import Network
import Darwin

/// A video/state client of mppd's existing mobile proxy. Deliberately exposes
/// no piloting API: connecting a Mac must leave physical SC3 sticks in charge.
/// The v2 observer supplies raw ARStream-1, not an ANAFI/SC2 video endpoint.
final class SC3SumoNativeSession {
    var onChange: ((SC3SumoNativeState) -> Void)?
    var onTelemetryEvent: ((ARSDKTelemetryEvent) -> Void)?
    var onMJPEGFrame: ((Data, UInt64) -> Void)?
    var onLog: ((String) -> Void)?
    private let queue = DispatchQueue(label: "parrotlab.sc3.sumo.native", qos: .userInitiated)
    private let epochs = AnafiCallbackEpoch()
    private let videoEpochs = AnafiCallbackEpoch()
    private var epoch: UInt64 = 0
    private var state = SC3SumoNativeState()
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var discovery: NWConnection?
    private var timer: DispatchSourceTimer?
    private var remote: sockaddr_in?
    private var observerAddress: sockaddr_in?
    private var reliable = SC3SumoNativeCommands()
    private var sequences: [UInt8: UInt8] = [:]
    private var received: [UInt8: UInt8] = [:]
    private var wire: SC3SumoNativeVideoWire?
    private var startedAt: TimeInterval = 0
    private var lastReceived: TimeInterval = 0
    private var lastObserver: TimeInterval = 0
    private var lastHello: TimeInterval = 0
    private var videoStartedAt: TimeInterval = 0
    private var lastVideoFrame: TimeInterval = 0
    private var discoveryBytes = Data()
    private var packets: UInt64 = 0
    private var duplicates: UInt64 = 0
    private var videoEnableSent = false
    private var currentName = ""
    private let testDiscoveryPort: UInt16?
    private let testObserverPort: UInt16?
    private let testFailEventACK: Bool
    private var injectEventACKFailure = false
    private var transportFailures: UInt64 = 0

    init() { testDiscoveryPort = nil; testObserverPort = nil; testFailEventACK = false }
    /// Tests can replace endpoints only when connecting to literal loopback.
    init(loopbackDiscoveryPort: UInt16, loopbackObserverPort: UInt16, failEventACKForTesting: Bool = false) {
        testDiscoveryPort = loopbackDiscoveryPort; testObserverPort = loopbackObserverPort
        testFailEventACK = failEventACKForTesting
    }
    func start(host: String) {
        let token = epochs.advance()
        _ = videoEpochs.advance()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token) else { return }
            self.closeLocked(); self.epoch = token
            self.transportFailures = 0
            self.injectEventACKFailure = self.testFailEventACK && host == "127.0.0.1"
            guard SC3SumoRelay.isValidHost(host) else { self.fail("Enter the SC3's numeric USB IPv4 address"); return }
            do { try self.openSocket() } catch { self.fail(error.localizedDescription); return }
            self.startedAt = ProcessInfo.processInfo.systemUptime
            self.state.message = "Connecting to native SC3 mobile proxy…"; self.publish()
            let port = host == "127.0.0.1" ? (self.testDiscoveryPort ?? 44_444) : 44_444
            guard let endpoint = NWEndpoint.Port(rawValue: port) else { self.fail("Invalid native discovery port"); return }
            let connection = NWConnection(host: .init(host), port: endpoint, using: .tcp)
            self.discovery = connection
            connection.stateUpdateHandler = { [weak self, weak connection] status in
                guard let self, let connection, self.epochs.contains(token), self.discovery === connection else { return }
                switch status {
                case .ready:
                    guard let localPort = self.localPort else { self.fail("Could not obtain native telemetry port"); return }
                    // Explicit ARSDK v1 framing, already verified on SC3 1.8.1.
                    // No piloting-source/ownership or mobile-PCMD field is sent.
                    connection.send(content: AnafiCommand.handshake(localPort: localPort), completion: .contentProcessed { [weak self] error in
                        guard let self, self.epochs.contains(token) else { return }
                        if let error { self.fail("Native SC3 discovery: \(error.localizedDescription)") }
                        else { self.receiveDiscovery(host: host, token: token) }
                    })
                case .failed(let error), .waiting(let error):
                    self.fail("Native SC3 TCP 44444 unavailable: \(error.localizedDescription). Check the USB network link and native mppd; this route does not use the optional relay.")
                default: break
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick(token) }
            self.timer = timer; timer.resume(); connection.start(queue: self.queue)
        }
    }
    func stop() {
        let token = epochs.advance(); _ = videoEpochs.advance()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token) else { return }
            self.closeLocked(); self.epoch = token; self.publish()
        }
    }
    func stopAndWait() { stop(); queue.sync {} }
    func startVideo() {
        let token = epochToken(); let videoToken = videoEpochs.advance()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token), self.videoEpochs.contains(videoToken), self.state.connected else { return }
            self.closeVideoLocked()
            self.state.videoRequested = true
            self.restartObserverLocked()
            self.updateVideoEnable()
            guard self.epochs.contains(token) else { return }; self.publish()
        }
    }
    func stopVideo() {
        let token = epochToken(); _ = videoEpochs.advance()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token), self.state.videoRequested else { return }
            self.closeVideoLocked(); self.publish()
        }
    }
    private func epochToken() -> UInt64 { queue.sync { epoch } }
    private var localPort: UInt16? {
        guard fd >= 0 else { return nil }
        var address = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        return result == 0 ? UInt16(bigEndian: address.sin_port) : nil
    }
    private func openSocket() throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw socketError() }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            let error = socketError(); Darwin.close(descriptor); throw error
        }
        fd = descriptor
        let token = epoch
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.epochs.contains(token), self.fd == descriptor else { return }; self.readLocked()
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        self.source = source; source.resume()
    }
    private func receiveDiscovery(host: String, token: UInt64) {
        guard let discovery else { return }
        discovery.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak discovery] data, _, complete, error in
            guard let self, let discovery, self.epochs.contains(token), self.discovery === discovery else { return }
            if let data { self.discoveryBytes.append(data) }
            guard self.discoveryBytes.count <= 16_384 else { self.fail("Native SC3 discovery reply exceeded 16 KiB"); return }
            if let object = ARSDKDiscoveryProtocol.responseObject(from: self.discoveryBytes) {
                guard let port = AnafiCommand.commandPort(object) else {
                    self.fail("Native SC3 rejected the mobile connection or did not negotiate ARSDK v1"); return
                }
                var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
                guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { self.fail("Invalid SC3 address"); return }
                self.remote = address
                let observerPort = host == "127.0.0.1" ? (self.testObserverPort ?? SC3SumoNativeObserver.port) : SC3SumoNativeObserver.port
                address.sin_port = observerPort.bigEndian; self.observerAddress = address
                self.discovery = nil; discovery.cancel(); self.discoveryBytes.removeAll()
                self.state.connected = true; self.state.message = "Native SC3 connected · waiting for Sumo state"
                self.lastReceived = ProcessInfo.processInfo.systemUptime
                _ = self.reliable.enqueue(ARSDKPhotoCommand.requestSkyControllerAllStates)
                _ = self.reliable.enqueue(ARSDKPhotoCommand.requestAllStates)
                self.flushReliable()
                guard self.epochs.contains(token) else { return }; self.publish()
                self.log("Native SC3 mobile proxy TCP 44444 → negotiated UDP \(port); Mac piloting/ownership commands disabled")
                return
            }
            if let error { self.fail("Native SC3 discovery: \(error.localizedDescription)") }
            else if complete { self.fail("Incomplete native SC3 discovery reply") }
            else { self.receiveDiscovery(host: host, token: token) }
        }
    }
    private func readLocked() {
        let descriptor = fd, token = epoch
        guard currentSession(token, descriptor) else { return }
        var bytes = [UInt8](repeating: 0, count: 65_535)
        for _ in 0..<64 {
            guard currentSession(token, descriptor) else { return }
            var sender = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &bytes, bytes.count, 0, $0, &size) }
            }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK { fail("Native SC3 telemetry read failed") }
                return
            }
            guard sender.sin_family == sa_family_t(AF_INET) else { continue }
            let data = Data(bytes.prefix(count))
            if let address = observerAddress, samePeer(sender, address), state.videoRequested {
                consumeObserver(data)
                guard currentSession(token, descriptor) else { return }; continue
            }
            guard let address = remote, samePeer(sender, address), let frames = AnafiNetworkFrame.decode(data), !frames.isEmpty else { continue }
            lastReceived = ProcessInfo.processInfo.systemUptime
            for frame in frames {
                guard currentSession(token, descriptor) else { return }
                consume(frame)
                guard currentSession(token, descriptor) else { return }
            }
        }
    }
    private func currentSession(_ token: UInt64, _ descriptor: Int32) -> Bool {
        descriptor >= 0 && fd == descriptor && epoch == token && epochs.contains(token)
    }
    private func samePeer(_ a: sockaddr_in, _ b: sockaddr_in) -> Bool {
        a.sin_addr.s_addr == b.sin_addr.s_addr && a.sin_port == b.sin_port
    }
    private func consume(_ frame: AnafiNetworkFrame) {
        let token = epoch, descriptor = fd
        guard currentSession(token, descriptor) else { return }
        packets &+= 1
        if frame.type == 1, frame.channel == 139, frame.payload.count == 1 {
            reliable.acknowledge(frame.payload[0]); flushReliable(); return
        }
        if frame.type == 2, frame.channel == 0, frame.payload.count == 8 {
            sendFrame(type: 2, channel: 1, payload: frame.payload); return
        }
        guard frame.channel == 126 || frame.channel == 127, frame.type == 2 || frame.type == 4 else { return }
        // ACK retransmissions before suppressing duplicate state delivery.
        if frame.type == 4 { sendFrame(type: 1, channel: frame.channel &+ 128, payload: Data([frame.sequence])) }
        guard currentSession(token, descriptor) else { return }
        if let previous = received[frame.channel] {
            let distance = frame.sequence &- previous
            if distance == 0 || distance >= 128 { duplicates &+= 1; return }
        }
        received[frame.channel] = frame.sequence
        var reader = AnafiWireReader(frame.payload)
        guard let feature = reader.byte(), let cls = reader.byte(), let command = reader.integer(UInt16.self) else { return }
        if feature == 4, cls == 21, command == 0, let source = reader.integer(UInt32.self) {
            state.pilotingSource = source
            if source == 1 { state.message = "Native SC3 connected · another mobile client owns piloting; this viewer sends no input" }
            publish(); return
        }
        if feature == 137, cls == 0, command == 5 {
            guard let status = reader.integer(UInt32.self), let serial = reader.string(),
                  let model = reader.integer(UInt16.self), let name = reader.string() else { return }
            let linked = status == 3
            let changed = (state.linkedProductID != nil) != linked ||
                (linked && (state.linkedProductID != model || currentName != serial + "\0" + name))
            if changed {
                state.battery = nil; state.telemetryReady = false
                state.videoAvailable = false; state.videoReceiving = false; videoEnableSent = false
                self.reliable.cancelVideo(); _ = self.videoEpochs.advance()
                if state.videoRequested { restartObserverLocked() }
            }
            state.linkedProductID = linked ? model : nil; state.linkedName = linked ? name : ""
            currentName = linked ? serial + "\0" + name : ""
            state.message = state.linkedSumo ? "Native SC3 → \(name.isEmpty ? "Jumping Sumo" : name) · Mac input disabled" :
                linked ? "Native SC3 connected to model 0x\(String(model, radix: 16)); select a Sumo on the controller" :
                "Native SC3 connected · waiting for Sumo association"
            if state.linkedSumo, changed { _ = reliable.enqueue(ARSDKPhotoCommand.requestAllStates); flushReliable() }
            guard currentSession(token, descriptor) else { return }
            updateVideoEnable()
            guard currentSession(token, descriptor) else { return }; publish(); return
        }
        if state.linkedSumo, feature == 0, cls == 5, command == 0 {
            state.telemetryReady = true; publish(); return
        }
        guard let event = ARSDKTelemetryProtocol.decode(frame.payload) else { return }
        switch event {
        case .droneBattery(let battery):
            guard state.linkedSumo else { return }; state.battery = min(100, max(0, battery))
        case .controllerBattery, .controllerBatteryState: break
        default: guard state.linkedSumo, feature == 0 || feature == 3 else { return }
        }
        epochs.deliver(token) { [weak self] in self?.onTelemetryEvent?(event) }
        publish()
    }
    private func consumeObserver(_ data: Data) {
        let token = epoch, descriptor = fd
        guard currentSession(token, descriptor) else { return }
        guard var wire else { return }
        let output = wire.consume(data); self.wire = wire
        if let failure = output.failure {
            closeVideoLocked(); state.videoMessage = failure; publish(); return
        }
        guard output.accepted, let packet = SC3SumoNativeObserver.decode(data), packet.nonce == wire.nonce,
              packet.instance == wire.instance, packet.generation == wire.generation else { return }
        if output.retireFrames {
            videoEpochToken = videoEpochs.advance()
            lastVideoFrame = 0; videoStartedAt = ProcessInfo.processInfo.systemUptime
        }
        lastObserver = ProcessInfo.processInfo.systemUptime
        let available = state.linkedSumo && wire.info?.ready == true
        if output.changed || state.videoAvailable != available {
            state.videoAvailable = available
            state.videoReceiving = false
            state.videoMessage = state.videoAvailable ? "Native v2 observer ready · ARStream-1/MJPEG" :
                "Native v2 observer connected · waiting for Sumo transport and negotiated video"
            publish()
        }
        if let ack = output.acknowledgement, let observerAddress { write(ack, to: observerAddress) }
        guard currentSession(token, descriptor) else { return }
        if let frame = output.jpeg, state.linkedSumo {
            lastVideoFrame = ProcessInfo.processInfo.systemUptime
            if !state.videoReceiving { state.videoReceiving = true; state.videoMessage = "Native SC3 · live MJPEG"; publish() }
            let videoToken = videoEpochToken
            epochs.deliver(token) { [weak self] in
                guard let self, self.videoEpochs.contains(videoToken) else { return }
                self.onMJPEGFrame?(frame.payload, frame.frameNumber)
            }
        }
    }
    private var videoEpochToken: UInt64 = 0
    private func restartObserverLocked() {
        if let bye = wire?.bye, let observerAddress { rawWrite(bye, to: observerAddress) }
        wire = SC3SumoNativeVideoWire(nonce: UInt64.random(in: 1...UInt64.max))
        videoStartedAt = ProcessInfo.processInfo.systemUptime
        lastHello = 0; lastObserver = 0; lastVideoFrame = 0
        state.videoAvailable = false; state.videoReceiving = false
        state.videoMessage = "Checking native v2 ARStream-1 observer on UDP 44447…"
    }
    private func updateVideoEnable() {
        guard state.videoRequested, state.linkedSumo, !videoEnableSent else { return }
        videoEpochToken = videoEpochs.advance()
        videoEnableSent = reliable.enqueue(ARSDKPhotoCommand.jumpingSumoVideoEnable(true)); flushReliable()
    }
    private func closeVideoLocked() {
        _ = videoEpochs.advance()
        if let bye = wire?.bye, let observerAddress { rawWrite(bye, to: observerAddress) }
        wire = nil; state.videoRequested = false; state.videoAvailable = false; state.videoReceiving = false
        reliable.cancelVideo()
        videoEnableSent = false; lastObserver = 0
        state.videoMessage = "Native ARStream-1 video requires the separately staged v2 observer"
        // Do not send VideoEnable(0) on disconnect. mppd owns the upstream
        // session, and another mobile viewer may still be using its video.
    }
    private func tick(_ token: UInt64) {
        guard epochs.contains(token) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard state.connected else {
            if now - startedAt > 8 { fail("Native SC3 TCP 44444 discovery timed out; check the USB network link") }
            return
        }
        if now - lastReceived > 8 { fail("Native SC3 state proxy stopped responding; reconnect (physical controls remain controller-owned)"); return }
        flushReliable()
        guard epochs.contains(token) else { return }
        if reliable.failed { fail("Native SC3 state/video command acknowledgement timed out"); return }
        guard state.videoRequested else { return }
        if now - lastHello >= 0.5, let hello = wire?.hello, let observerAddress {
            lastHello = now; write(hello, to: observerAddress)
        }
        guard epochs.contains(token) else { return }
        if (lastObserver == 0 && now - videoStartedAt > 2) || (lastObserver > 0 && now - lastObserver > 3) {
            let message = "Native v2 video observer unavailable on UDP 44447. v1c provides physical control, but does not forward ARStream-1; activate the separate v2 candidate to bench-test video."
            if state.videoMessage != message {
                state.videoAvailable = false; state.videoReceiving = false; state.videoMessage = message; publish()
            }
        } else if state.videoAvailable, now - max(lastVideoFrame, videoStartedAt) > 3 {
            let message = "Native v2 observer ready, but no complete MJPEG frames arrived; inspect upstream buffer 125 and VideoEnable"
            if state.videoMessage != message { state.videoReceiving = false; state.videoMessage = message; publish() }
        }
    }
    private func sendFrame(type: UInt8, channel: UInt8, payload: Data) {
        sequences[channel, default: 0] &+= 1
        if let remote { write(ARSDKPhotoProtocol.frame(type: type, id: channel,
            sequence: sequences[channel] ?? 1, payload: payload), to: remote) }
    }
    private func flushReliable() {
        guard state.connected, let remote,
              let packet = reliable.next(now: ProcessInfo.processInfo.systemUptime) else { return }
        write(packet, to: remote)
    }
    @discardableResult private func rawWrite(_ data: Data, to address: sockaddr_in) -> Int {
        guard fd >= 0 else { return -1 }
        if injectEventACKFailure, data.count == 8, data[0] == 1,
           data[1] == 254 || data[1] == 255, address.sin_port == remote?.sin_port {
            injectEventACKFailure = false; errno = EPIPE; return -1
        }
        var destination = address
        return data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
    private func write(_ data: Data, to address: sockaddr_in) {
        let sent = rawWrite(data, to: address)
        if sent < 0, errno != EAGAIN && errno != EWOULDBLOCK { fail("Native SC3 UDP write failed: \(socketError().localizedDescription)") }
    }
    private func fail(_ message: String) {
        guard let next = epochs.retire(epoch) else { return }
        transportFailures &+= 1
        closeLocked(); epoch = next; state.message = message; publish(); log(message)
    }
    private func closeLocked() {
        closeVideoLocked(); timer?.cancel(); timer = nil; discovery?.cancel(); discovery = nil
        source?.cancel(); source = nil; fd = -1; remote = nil; observerAddress = nil
        reliable = SC3SumoNativeCommands(); sequences.removeAll(); received.removeAll(); discoveryBytes.removeAll()
        state = SC3SumoNativeState(); packets = 0; duplicates = 0; currentName = ""
    }
    private func publish() {
        let snapshot = state, token = epoch
        epochs.deliver(token) { [weak self] in self?.onChange?(snapshot) }
    }
    private func log(_ message: String) {
        let token = epoch
        epochs.deliver(token) { [weak self] in self?.onLog?(message) }
    }
    private func socketError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    var diagnosticSummary: String {
        queue.sync {
            "SC3 native gen=\(epoch) udp=\(fd >= 0) transport=\(state.connected) " +
            "controller-model=\(state.controllerProductID.map { String($0, radix: 16) } ?? "unreported") " +
            "drone-model=\(state.linkedProductID.map { String($0, radix: 16) } ?? "none") ready=\(state.telemetryReady) " +
            "piloting-source=\(state.pilotingSource.map(String.init) ?? "unreported") viewer-input=disabled " +
            "packets=\(packets) duplicates=\(duplicates) ack-pending=\(reliable.pending) " +
            "failures=\(transportFailures) " +
            "video-requested=\(state.videoRequested) observer=\(state.videoAvailable) " +
            "instance=\(wire?.instance.map(String.init) ?? "none") upstream-gen=\(wire?.generation.map(String.init) ?? "none") " +
            "video-frames=\(wire?.statistics.completedFrames ?? 0) rejected=\(wire?.rejectedPackets ?? 0)"
        }
    }
    deinit { source?.cancel(); discovery?.cancel(); timer?.cancel() }
}
