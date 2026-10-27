import Foundation
import Network
import Darwin
import ImageIO

enum SC3SumoNativeSelfTest {
    static func run() -> Bool {
        guard packets(), commands(), loopback(), disconnectedController(), eventACKWriteFailure() else {
            fputs("SC3 native Sumo self-test failed\n", stderr); return false
        }
        print("SC3 native Sumo observer bounds, ownership isolation and reconnect self-tests passed (host fixtures)")
        return true
    }
    /// Explicit developer-only probe; never called from ordinary self-tests.
    /// Connecting observes the controller's existing session and leaves all
    /// physical controls owned by the SC3. The caller supplies the live host.
    static func probe(host: String, duration: TimeInterval = 4, jpegOutput: URL? = nil) -> Bool {
        let session = SC3SumoNativeSession()
        var connected = false, requested = false
        var previous = ""
        var frames = 0, decoded = 0, width = 0, height = 0
        var saved = jpegOutput == nil
        session.onMJPEGFrame = { data, _ in
            frames += 1
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            decoded += 1; width = image.width; height = image.height
            if !saved, let jpegOutput {
                do { try data.write(to: jpegOutput, options: .atomic); saved = true }
                catch { fputs("Could not save native video probe frame: \(error)\n", stderr) }
            }
        }
        session.onChange = { state in
            connected = state.connected
            let summary = "\(state.message) · model=\(state.linkedProductID.map { String($0, radix: 16) } ?? "none") ready=\(state.telemetryReady) battery=\(state.battery.map(String.init) ?? "unknown") · \(state.videoMessage)"
            if summary != previous { print(summary); previous = summary }
            if state.connected, !requested { requested = true; session.startVideo() }
        }
        session.onLog = { print($0) }
        session.start(host: host)
        let end = Date().addingTimeInterval(min(60, max(1, duration.isFinite ? duration : 4)))
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        let result = connected && (jpegOutput == nil || (saved && decoded > 0))
        print("Native MJPEG received=\(frames) decoded=\(decoded) dimensions=\(width)x\(height)")
        print(session.diagnosticSummary); session.stopAndWait()
        return result
    }
    private static func fail(_ line: UInt = #line) -> Bool { fputs("SC3 native Sumo failure at line \(line)\n", stderr); return false }
    static func info(nonce: UInt64, instance: UInt64 = 42, generation: UInt32 = 1, interval: Int32 = -1,
                     flags: UInt32 = 15, size: UInt32 = 65_000, maximum: UInt32 = 4) -> Data {
        var data = Data(); data.appendAnafiLE(flags); data.appendAnafiLE(UInt32(0x0902))
        data.appendAnafiLE(size); data.appendAnafiLE(maximum); data.appendAnafiLE(interval); data.appendAnafiLE(UInt32(1))
        return SC3SumoNativeObserver.Packet(kind: .info, instance: instance, generation: generation, nonce: nonce, payload: data).encoded
    }
    static func fragment(nonce: UInt64, instance: UInt64 = 42, generation: UInt32 = 1, frame: UInt16 = 1,
                         number: UInt8 = 0, count: UInt8 = 1, bytes: Data) -> Data {
        var payload = Data(); payload.appendAnafiLE(frame); payload.append(contentsOf: [0, number, count]); payload.append(bytes)
        let raw = ARSDKPhotoProtocol.frame(type: 3, id: 125, sequence: number, payload: payload)
        return SC3SumoNativeObserver.Packet(kind: .raw, instance: instance, generation: generation, nonce: nonce, payload: raw).encoded
    }
    private static func packets() -> Bool {
        let jpeg = Data([255, 216, 1, 2, 255, 217])
        var wire = SC3SumoNativeVideoWire(nonce: 99)
        guard SC3SumoNativeObserver.decode(wire.hello)?.kind == .hello,
              wire.consume(fragment(nonce: 99, bytes: jpeg)).jpeg == nil,
              wire.consume(info(nonce: 98)).changed == false,
              wire.consume(info(nonce: 99)).changed, wire.info?.ready == true,
              wire.consume(fragment(nonce: 99, bytes: jpeg)).jpeg?.payload == jpeg,
              wire.consume(fragment(nonce: 99, bytes: jpeg)).jpeg == nil,
              SC3SumoNativeObserver.decode(wire.bye ?? Data())?.nonce == 99 else { return fail() }
        // A fragmented 65 KB JPEG arrives out of order; the complete raw
        // ARNetwork record remains under the real UDP datagram ceiling.
        let large = Data([255, 216]) + Data(repeating: 7, count: 65_016) + Data([255, 217])
        let last = fragment(nonce: 99, frame: 2, number: 1, count: 2, bytes: Data(large.dropFirst(65_000)))
        guard wire.consume(last).jpeg == nil,
              wire.consume(fragment(nonce: 99, frame: 2, count: 2, bytes: Data(large.prefix(65_000)))).jpeg?.payload == large,
              wire.consume(fragment(nonce: 99, frame: 3, bytes: Data(repeating: 1, count: 65_001))).jpeg == nil,
              wire.consume(fragment(nonce: 99, frame: 3, count: 5, bytes: jpeg)).jpeg == nil else { return fail() }
        for length in 0..<32 { guard SC3SumoNativeObserver.decode(Data(repeating: 0, count: length)) == nil else { return fail() } }
        var bad = info(nonce: 99); bad[12] = 0
        guard SC3SumoNativeObserver.decode(bad) == nil,
              !wire.consume(info(nonce: 99, size: UInt32.max)).changed,
              !wire.consume(info(nonce: 99, maximum: 129)).changed,
              !wire.consume(info(nonce: 99, interval: -2)).changed else { return fail() }
        // Sequence rollover, generation retirement and instance replacement.
        var rollover = SC3SumoNativeVideoWire(nonce: 99)
        guard rollover.consume(info(nonce: 99, generation: UInt32.max)).changed,
              rollover.consume(fragment(nonce: 99, generation: UInt32.max, frame: UInt16.max, bytes: jpeg)).jpeg != nil,
              rollover.consume(fragment(nonce: 99, generation: UInt32.max, frame: 0, bytes: jpeg)).jpeg != nil,
              rollover.consume(info(nonce: 99, generation: 1)).changed,
              rollover.consume(fragment(nonce: 99, generation: UInt32.max, frame: 1, bytes: jpeg)).jpeg == nil,
              !rollover.consume(info(nonce: 99, generation: UInt32.max)).changed,
              rollover.generation == 1,
              rollover.consume(info(nonce: 99, instance: 43)).failure != nil else { return fail() }
        var acknowledged = SC3SumoNativeVideoWire(nonce: 100)
        _ = acknowledged.consume(info(nonce: 100, interval: 0))
        let result = acknowledged.consume(fragment(nonce: 100, bytes: jpeg))
        guard let ack = result.acknowledgement, let packet = SC3SumoNativeObserver.decode(ack),
              packet.kind == .acknowledgement, packet.payload.count == 25,
              let frame = AnafiNetworkFrame.decode(packet.payload)?.first,
              frame.type == 2, frame.channel == 13, frame.payload.count == 18,
              wire.consume(fragment(nonce: 99, frame: 4, bytes: jpeg)).acknowledgement == nil else { return fail() }
        let changedNegotiation = acknowledged.consume(info(nonce: 100, interval: 0, size: 64_000))
        guard changedNegotiation.accepted, changedNegotiation.retireFrames,
              acknowledged.info?.negotiation.fragmentSize == 64_000 else { return fail() }
        // Repeated malformed/incomplete data is bounded by the existing four
        // pending-frame assembler; a later complete frame still succeeds.
        for value in 0..<2_000 {
            _ = wire.consume(fragment(nonce: 99, frame: UInt16(value + 10), count: 4, bytes: Data([1])))
        }
        return wire.consume(fragment(nonce: 99, frame: 3_000, bytes: jpeg)).jpeg?.payload == jpeg
    }
    private static func commands() -> Bool {
        var commands = SC3SumoNativeCommands()
        guard !commands.enqueue(ARSDKPhotoCommand.jumpingSumoPCMD(flag: false, speed: 0, turn: 0)),
              !commands.enqueue(ARSDKPhotoCommand.jumpingSumoJump(.high)),
              !commands.enqueue(AnafiCommand.pilotingSource(mac: true)),
              commands.enqueue(ARSDKPhotoCommand.jumpingSumoVideoEnable(true)),
              let first = commands.next(now: 0), commands.next(now: 0.1) == nil,
              commands.next(now: 0.2) == first else { return fail() }
        commands.cancelVideo()
        guard commands.next(now: 1) == nil, !commands.pending,
              commands.enqueue(ARSDKPhotoCommand.requestAllStates), let next = commands.next(now: 1),
              first[2] &+ 1 == next[2] else { return fail() }
        for index in 0..<520 {
            guard let packet = AnafiNetworkFrame.decode(next)?.first else { return fail() }
            if index == 0 { commands.acknowledge(packet.sequence) }
            guard commands.enqueue(ARSDKPhotoCommand.requestAllStates),
                  let sent = commands.next(now: TimeInterval(index + 2)),
                  let frame = AnafiNetworkFrame.decode(sent)?.first else { return fail() }
            commands.acknowledge(frame.sequence)
        }
        return !commands.failed
    }
    private static func spin(timeout: TimeInterval = 4, _ predicate: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
    private static func loopback() -> Bool {
        let fixture: SC3SumoNativeFixture
        do { fixture = try SC3SumoNativeFixture() } catch { return fail() }
        defer { fixture.stop() }
        guard spin({ fixture.discoveryPort != nil }), let port = fixture.discoveryPort else { return fail() }
        let session = SC3SumoNativeSession(loopbackDiscoveryPort: port, loopbackObserverPort: fixture.observerPort)
        defer { session.stopAndWait() }
        var state = SC3SumoNativeState(), frames = 0, bad = false
        session.onChange = { state = $0 }
        session.onMJPEGFrame = { jpeg, _ in if jpeg == SC3SumoNativeFixture.jpeg { frames += 1 } else { bad = true } }
        for round in 0..<3 {
            session.start(host: "127.0.0.1")
            guard spin({ state.linkedSumo && state.telemetryReady && state.battery == 73 }), !bad,
                  state.controllerProductID == nil, state.pilotingSource == 0 else { return fail() }
            let before = frames
            session.startVideo()
            guard spin({ frames > before && state.videoReceiving }), fixture.validCommands, !bad else {
                fputs("\(session.diagnosticSummary) state=\(state.message) video=\(state.videoMessage)\n", stderr); return fail()
            }
            // Queue an old-generation JPEG on the main queue, then process a
            // newer INFO while the UI deliberately does not drain callbacks.
            // The fixture pauses ordinary video so only that retired JPEG
            // could increment the callback count during the subsequent pump.
            let beforeGeneration = frames
            let generation = fixture.queueOldFrameAndChangeGeneration()
            let deadline = Date().addingTimeInterval(1)
            while !session.diagnosticSummary.contains("upstream-gen=\(generation) "), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard session.diagnosticSummary.contains("upstream-gen=\(generation) ") else { return fail() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            guard !bad, frames == beforeGeneration, !state.videoReceiving else { return fail() }
            fixture.resumeVideo()
            guard spin({ frames > beforeGeneration && state.videoReceiving }), !bad else { return fail() }
            let beforeReconnect = frames
            fixture.reconnectUpstreamWithStaleVideo()
            guard spin({ frames > beforeReconnect && state.videoReceiving }), !bad else { return fail() }
            let old = frames
            session.stopVideo(); _ = session.diagnosticSummary
            guard spin({ !state.videoRequested }) else { return fail() }
            fixture.sendPreviousVideo(); Thread.sleep(forTimeInterval: 0.04)
            guard spin({ frames == old }) else { return fail() }
            session.startVideo()
            guard spin({ frames > old }), fixture.validCommands else { return fail() }
            let oldEvents = frames
            fixture.sendPreviousVideo(); Thread.sleep(forTimeInterval: 0.04)
            session.stopAndWait()
            guard spin({ !state.connected }), frames == oldEvents,
                  session.diagnosticSummary.contains("udp=false"), fixture.sawBye else { return fail() }
            if round == 2 { return fixture.validCommands && fixture.connections == 3 }
        }
        return fail()
    }
    private static func disconnectedController() -> Bool {
        let fixture: SC3SumoNativeFixture
        do { fixture = try SC3SumoNativeFixture(linkedStatus: 1) } catch { return fail() }
        defer { fixture.stop() }
        guard spin({ fixture.discoveryPort != nil }), let port = fixture.discoveryPort else { return fail() }
        let session = SC3SumoNativeSession(loopbackDiscoveryPort: port, loopbackObserverPort: fixture.observerPort)
        defer { session.stopAndWait() }
        var state = SC3SumoNativeState(), callbacks = 0, frames = 0
        session.onChange = { state = $0; callbacks += 1 }
        session.onMJPEGFrame = { _, _ in frames += 1 }
        session.start(host: "127.0.0.1")
        guard spin({ state.connected && callbacks >= 3 }), !state.linkedSumo,
              state.linkedProductID == nil, state.battery == nil, !state.telemetryReady else { return fail() }
        session.startVideo()
        guard spin({ state.videoRequested && state.videoMessage.contains("observer connected") }),
              !state.videoAvailable, frames == 0, fixture.validCommands else { return fail() }
        return true
    }
    private static func eventACKWriteFailure() -> Bool {
        let fixture: SC3SumoNativeFixture
        do { fixture = try SC3SumoNativeFixture() } catch { return fail() }
        defer { fixture.stop() }
        guard spin({ fixture.discoveryPort != nil }), let port = fixture.discoveryPort else { return fail() }
        let session = SC3SumoNativeSession(loopbackDiscoveryPort: port, loopbackObserverPort: fixture.observerPort,
                                          failEventACKForTesting: true)
        defer { session.stopAndWait() }
        var state = SC3SumoNativeState()
        session.onChange = { state = $0 }
        session.start(host: "127.0.0.1")
        guard spin({ state.message.contains("UDP write failed") }), !state.connected else { return fail() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        // The failing ACK belongs to a CoPilotingState event. Its payload
        // must never mutate the reset session, and the same receive loop must
        // not perform recvfrom(-1) and replace the actual write failure.
        return state.message.contains("UDP write failed") && state.pilotingSource == nil &&
            state.linkedProductID == nil && !state.telemetryReady &&
            session.diagnosticSummary.contains("failures=1 ") && session.diagnosticSummary.contains("udp=false")
    }
}

/// Native proxy + v2 observer emulator. All endpoints are ephemeral loopback;
/// no USB, ADB, Sumo or controller service is contacted by these tests.
private final class SC3SumoNativeFixture {
    static let jpeg = Data([255, 216, 1, 2, 255, 217])
    private let queue = DispatchQueue(label: "parrotlab.sc3.sumo.native.fixture")
    private let lock = NSLock()
    private let listener: NWListener
    private let nativeFD: Int32
    private let observerFD: Int32
    private var sources: [DispatchSourceRead] = []
    private var peers: [NWConnection] = []
    private var storedPort: UInt16?
    private var valid = true
    private var count = 0
    private var bye = false
    private var nativeSequence: UInt8 = 0
    private var frameNumber: UInt16 = 0
    private var observerGeneration: UInt32 = 1
    private var observerFramesPaused = false
    private var previousVideo: (Data, sockaddr_in)?
    private var nativeAddress: sockaddr_in?
    private let linkedStatus: UInt32
    let observerPort: UInt16
    private let nativePort: UInt16
    var discoveryPort: UInt16? { lock.lock(); defer { lock.unlock() }; return storedPort }
    var validCommands: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    var connections: Int { lock.lock(); defer { lock.unlock() }; return count }
    var sawBye: Bool { lock.lock(); defer { lock.unlock() }; return bye }
    init(linkedStatus: UInt32 = 3) throws {
        self.linkedStatus = linkedStatus
        func udp() throws -> (Int32, UInt16) {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard result == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
            return (fd, UInt16(bigEndian: address.sin_port))
        }
        (nativeFD, nativePort) = try udp()
        do { (observerFD, observerPort) = try udp() } catch { Darwin.close(nativeFD); throw error }
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        do { listener = try NWListener(using: parameters) } catch { Darwin.close(nativeFD); Darwin.close(observerFD); throw error }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.lock.lock(); self.storedPort = self.listener.port?.rawValue; self.lock.unlock()
        }
        listener.newConnectionHandler = { [weak self] peer in
            guard let self else { peer.cancel(); return }
            self.lock.lock(); self.count += 1; self.lock.unlock()
            self.nativeSequence = 0; self.peers.append(peer); peer.start(queue: self.queue)
            self.receiveDiscovery(peer, accumulated: Data())
        }
        for fd in [nativeFD, observerFD] {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(fd) }
            source.setCancelHandler { Darwin.close(fd) }; sources.append(source); source.resume()
        }
        listener.start(queue: queue)
    }
    private func receiveDiscovery(_ peer: NWConnection, accumulated: Data) {
        peer.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, complete, _ in
            guard let self else { return }
            var data = accumulated; if let bytes { data.append(bytes) }
            guard data.count <= 16_384 else { peer.cancel(); return }
            guard let object = ARSDKDiscoveryProtocol.responseObject(from: data) else {
                if !complete { self.receiveDiscovery(peer, accumulated: data) }; return
            }
            if object["proto_v_min"] as? Int != 1 || object["proto_v_max"] as? Int != 1 || object["d2c_port"] as? Int == nil {
                self.invalidate(); return
            }
            let response = Data("{\"status\":0,\"proto_v\":1,\"c2d_port\":\(self.nativePort)}\0".utf8)
            // Deliberately split discovery across reads.
            peer.send(content: Data(response.prefix(8)), completion: .contentProcessed { _ in
                peer.send(content: Data(response.dropFirst(8)), completion: .contentProcessed { _ in })
            })
        }
    }
    private func invalidate() { lock.lock(); valid = false; lock.unlock() }
    private func read(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        for _ in 0..<64 {
            var address = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
            guard count >= 0 else { return }
            let bytes = Data(buffer.prefix(count))
            if fd == observerFD { consumeObserver(bytes, address: address); continue }
            nativeAddress = address
            guard let frames = AnafiNetworkFrame.decode(bytes) else { invalidate(); continue }
            for frame in frames {
                if frame.type == 1 || (frame.type == 2 && frame.channel == 1) { continue }
                let allowed = [ARSDKPhotoCommand.requestAllStates, ARSDKPhotoCommand.requestSkyControllerAllStates,
                               ARSDKPhotoCommand.jumpingSumoVideoEnable(true)]
                guard frame.type == 4, frame.channel == 11, allowed.contains(frame.payload) else { invalidate(); continue }
                send(ARSDKPhotoProtocol.frame(type: 1, id: 139, sequence: 0, payload: Data([frame.sequence])), fd: nativeFD, to: address)
                if frame.payload == ARSDKPhotoCommand.requestSkyControllerAllStates {
                    event(Data([4, 21, 0, 0, 0, 0, 0, 0]), to: address)
                    linkEvent(status: linkedStatus, to: address)
                } else if frame.payload == ARSDKPhotoCommand.requestAllStates {
                    event(Data([0, 5, 1, 0, 73]), to: address); event(Data([0, 5, 0, 0]), to: address)
                }
            }
        }
    }
    private func event(_ bytes: Data, to address: sockaddr_in) {
        nativeSequence &+= 1
        let frame = ARSDKPhotoProtocol.frame(type: 4, id: 127, sequence: nativeSequence, payload: bytes)
        send(frame, fd: nativeFD, to: address)
        // Reliable retransmission must be ACKed but delivered just once.
        send(frame, fd: nativeFD, to: address)
    }
    private func linkEvent(status: UInt32, to address: sockaddr_in) {
        var link = Data([137, 0, 5, 0]); link.appendAnafiLE(status); link.append(0)
        link.appendAnafiLE(UInt16(0x0902)); link.append(Data("fixture Sumo\0".utf8)); event(link, to: address)
    }
    private func consumeObserver(_ bytes: Data, address: sockaddr_in) {
        guard let packet = SC3SumoNativeObserver.decode(bytes) else { invalidate(); return }
        if packet.kind == .bye { lock.lock(); bye = true; lock.unlock(); return }
        if packet.kind == .acknowledgement { return }
        guard packet.kind == .hello else { invalidate(); return }
        send(SC3SumoNativeSelfTest.info(nonce: packet.nonce, generation: observerGeneration), fd: observerFD, to: address)
        guard !observerFramesPaused else { return }
        frameNumber &+= 1
        let raw = SC3SumoNativeSelfTest.fragment(nonce: packet.nonce, generation: observerGeneration,
                                               frame: frameNumber, bytes: Self.jpeg)
        previousVideo = (raw, address); send(raw, fd: observerFD, to: address)
    }
    func sendPreviousVideo() { queue.async { [weak self] in guard let self, let previous = self.previousVideo else { return }; self.send(previous.0, fd: self.observerFD, to: previous.1) } }
    func queueOldFrameAndChangeGeneration() -> UInt32 {
        queue.sync {
            observerFramesPaused = true
            guard let previous = previousVideo, let packet = SC3SumoNativeObserver.decode(previous.0) else { return observerGeneration }
            frameNumber &+= 1
            let old = SC3SumoNativeSelfTest.fragment(nonce: packet.nonce, generation: observerGeneration,
                frame: frameNumber, bytes: Data([255, 216, 99, 255, 217]))
            send(old, fd: observerFD, to: previous.1)
            observerGeneration &+= 1
            send(SC3SumoNativeSelfTest.info(nonce: packet.nonce, generation: observerGeneration), fd: observerFD, to: previous.1)
            return observerGeneration
        }
    }
    func resumeVideo() {
        queue.async { [weak self] in
            guard let self, let previous = self.previousVideo,
                  let packet = SC3SumoNativeObserver.decode(previous.0) else { return }
            self.observerFramesPaused = false; self.frameNumber &+= 1
            let raw = SC3SumoNativeSelfTest.fragment(nonce: packet.nonce, generation: self.observerGeneration,
                                                   frame: self.frameNumber, bytes: Self.jpeg)
            self.previousVideo = (raw, previous.1); self.send(raw, fd: self.observerFD, to: previous.1)
        }
    }
    func reconnectUpstreamWithStaleVideo() {
        queue.async { [weak self] in
            guard let self, let nativeAddress = self.nativeAddress, let previous = self.previousVideo,
                  let packet = SC3SumoNativeObserver.decode(previous.0) else { return }
            self.linkEvent(status: 1, to: nativeAddress); self.linkEvent(status: 3, to: nativeAddress)
            self.frameNumber &+= 1
            let stale = SC3SumoNativeSelfTest.fragment(nonce: packet.nonce, generation: self.observerGeneration,
                                                       frame: self.frameNumber,
                                                       bytes: Data([255, 216, 99, 255, 217]))
            self.send(stale, fd: self.observerFD, to: previous.1)
        }
    }
    private func send(_ bytes: Data, fd: Int32, to address: sockaddr_in) {
        var address = address
        _ = bytes.withUnsafeBytes { buffer in withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } }
    }
    func stop() { listener.cancel(); queue.sync { peers.forEach { $0.cancel() }; peers.removeAll(); sources.forEach { $0.cancel() }; sources.removeAll() } }
}
