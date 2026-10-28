import Foundation
import AppKit
import Network

enum AnafiSelfTest {
    static func run() -> Bool {
        func check(_ value: Bool, _ name: String) -> Bool {
            if !value { fputs("ANAFI self-test failed: \(name)\n", stderr) }; return value
        }
        guard check(AnafiRoute.direct.videoURL(host: "192.168.42.1")?.absoluteString == "rtsp://192.168.42.1:554/live" &&
                    AnafiRoute.skyController3.videoURL(host: "192.168.53.1")?.absoluteString == "rtsp://192.168.53.1:654/live" &&
                    AnafiRoute.direct.videoURL(host: "host\r\nInjected") == nil &&
                    ParrotProductModel(productID: 0x0914) == .anafi4K &&
                    !ParrotProductModel.anafi4K.capabilities.supportsBB2DragonLab, "route isolation"),
              check(AnafiCommand.camera(31, id: 3, values: [1]) == Data([143, 0, 31, 0, 3, 1, 0, 0, 0]) &&
                    AnafiCommand.pilotingSource(mac: true) == Data([4, 20, 0, 0, 1, 0, 0, 0]) &&
                    AnafiCommand.gimbalPitch(id: 7, degrees: -45).count == 33 &&
                    AnafiCommand.recording(id: 3, mode: 0, resolution: 1, fps: 2, hyperlapse: 0).count == 21 &&
                    AnafiCommand.photo(id: 3, mode: 0, format: 1, file: 2, burst: 0, bracketing: 0, interval: 2).count == 29,
                    "camera and SC3 command fixtures"),
              check(AnafiCommand.commandPort(["status": 0, "proto_v": 2, "c2d_port": 2233]) == nil &&
                    AnafiCommand.commandPort(["status": 0, "proto_v": 1, "c2d_port": 2233]) == 2233 &&
                    AnafiCommand.commandPort(["status": 0, "c2d_port": 65536]) == nil,
                    "protocol negotiation"),
              check(reliability(), "ordered retries and sequence rollover"),
              check(cameraFixtures(), "camera capability and state fixtures"),
              check(rtspFixtures(), "fragmented RTSP and SDP fixtures"),
              check(callbackEpochs(), "stale callback cancellation") else { return false }
        guard check(sessionLoopback(), "ANAFI/SC3 handshake, ACK retry, telemetry and reconnect"),
              check(rtspLoopback(), "RTSP connect, video, disconnect and reconnect"),
              check(AnafiViewController.interactionSelfTest(), "camera settings and mode interaction"),
              check(AnafiViewController.layoutSelfTest(), "embedded workspace resizing") else { return false }
        print("ANAFI packet, camera, RTSP and lifecycle self-tests passed")
        return true
    }
    static func cameraCapability(id: UInt8 = 3) -> Data {
        var data = Data([143, 0, 1, 0, id])
        data.appendAnafiLE(UInt32(0)); data.append(15)
        data.appendAnafiLE(UInt32(1)); data.appendAnafiLE(UInt32(1))
        data.appendAnafiLE(UInt64(0x7ffff)); data.appendAnafiLE(UInt32(0x3ffff)); data.appendAnafiLE(UInt64.max)
        data.appendAnafiLE(UInt32(1)); data.appendAnafiLE(UInt16(15)); data.append(3)
        data.appendAnafiLE(UInt16(31)); data.appendAnafiLE(UInt16(127)); data.appendAnafiLE(UInt16(511)); data.append(7)
        data.appendAnafiLE(Float(1).bitPattern); data.appendAnafiLE(Float(2).bitPattern)
        return data
    }
    static func cameraFixtures() -> Bool {
        var camera = AnafiCameraState()
        let cap = cameraCapability()
        for length in 0..<cap.count {
            var empty = AnafiCameraState()
            guard !empty.consume(cap.prefix(length)), empty.id == nil else { return false }
        }
        guard camera.consume(cap), camera.id == 3, camera.styles == 15, camera.streamingModes == 7,
              !camera.consume(AnafiCommand.camera(32, id: 0, values: [1])), camera.mode == nil,
              camera.consume(AnafiCommand.camera(32, id: 3, values: [1])), camera.mode == 1,
              camera.consume(AnafiCommand.camera(38, id: 3, values: [2])), camera.streamingMode == 2,
              camera.consume(AnafiCommand.camera(45, id: 3, values: [1, 1]) + Data(repeating: 0, count: 8)),
              camera.recording == true else { return false }
        var rec = Data([143, 0, 2, 0]); rec.appendAnafiLE(UInt16(8)); rec.appendAnafiLE(UInt16(1))
        rec.appendAnafiLE(UInt16(2)); rec.appendAnafiLE(UInt32(7)); rec.appendAnafiLE(UInt32(1)); rec.append(1)
        guard camera.consume(rec), let capability = camera.recordingCapabilities[8],
              capability.supports(mode: 0, resolution: 1, fps: 2),
              !capability.supports(mode: 2, resolution: 1, fps: 2) else { return false }
        rec[rec.count - 1] = 8
        guard camera.consume(rec), camera.recordingCapabilities.isEmpty else { return false }
        var badZoom = AnafiCommand.camera(22, id: 3); badZoom.appendAnafiLE(Float.nan.bitPattern)
        guard !camera.consume(badZoom), camera.zoom == 1 else { return false }
        camera = AnafiCameraState()
        return !camera.consume(AnafiCommand.camera(32, id: 3, values: [0])) && camera.mode == nil
    }
    static func reliability() -> Bool {
        var channel = AnafiReliableChannel()
        guard channel.enqueue(Data([1])), channel.enqueue(Data([2])), let first = channel.next(now: 0),
              channel.next(now: 0.1) == nil, channel.next(now: 0.2) == first else { return false }
        channel.acknowledge(99)
        guard channel.pending != nil else { return false }
        channel.acknowledge(1)
        guard let second = channel.next(now: 0.3), second != first,
              AnafiNetworkFrame.decode(second)?.first?.sequence == 2 else { return false }
        channel.acknowledge(2)
        for index in 3...258 {
            guard channel.enqueue(Data([0])), let packet = channel.next(now: Double(index)),
                  AnafiNetworkFrame.decode(packet)?.first?.sequence == UInt8(truncatingIfNeeded: index) else { return false }
            channel.acknowledge(UInt8(truncatingIfNeeded: index))
        }
        guard channel.enqueue(Data([4])), channel.next(now: 500) != nil, channel.enqueue(Data([5])) else { return false }
        let closing = channel.closingPacket(AnafiCommand.pilotingSource(mac: false))
        guard AnafiNetworkFrame.decode(closing)?.first?.sequence == 4,
              channel.pending == nil, channel.queued.isEmpty, channel.next(now: 501) == nil else { return false }
        guard AnafiNetworkFrame.decode(Data([4, 126, 1, 6, 0, 0, 0])) == nil,
              AnafiNetworkFrame.decode(first + second)?.count == 2 else { return false }
        _ = channel.enqueue(Data([0])); _ = channel.next(now: 1000)
        for count in 1...6 { _ = channel.next(now: 1000 + Double(count)) }
        guard channel.failed && !channel.enqueue(Data([0])) else { return false }
        var emergency = AnafiReliableChannel(channel: 12, maximumRetries: nil)
        guard emergency.enqueue(ARSDKPhotoCommand.emergency), let stop = emergency.next(now: 0),
              AnafiNetworkFrame.decode(stop)?.first?.channel == 12 else { return false }
        for count in 1...20 {
            guard emergency.next(now: Double(count)) == stop, !emergency.failed else { return false }
        }
        emergency.acknowledge(2)
        guard emergency.pending != nil else { return false }
        emergency.acknowledge(1)
        return emergency.pending == nil && emergency.next(now: 30) == nil
    }
    static func rtspFixtures() -> Bool {
        let body = "v=0\r\nm=video 0 RTP/AVP 97\r\na=rtpmap:97 H264/90000\r\na=control:trackID=0\r\na=fmtp:97 sprop-parameter-sets=ZwE=,aAE=\r\n"
        let packet = Data([0x80, 0xe1, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1, 0x65, 0x88])
        let response = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        let multiplexed = response + Data([0x24, 0, 0, UInt8(packet.count)]) + packet
        for split in 0...multiplexed.count {
            var parser = AnafiRTSPParser()
            do {
                let items = try parser.append(multiplexed.prefix(split)) + parser.append(multiplexed.dropFirst(split))
                guard items.count == 2, items.last == .packet(0, packet) else { return false }
            } catch { return false }
        }
        var parser = AnafiRTSPParser()
        do { _ = try parser.append(Data("RTSP/1.0 200 OK\r\nContent-Length: -1\r\n\r\n".utf8)); return false } catch {}
        guard let base = URL(string: "rtsp://127.0.0.1:654/live"), let sdp = AnafiSDP(body: Data(body.utf8), base: base),
              sdp.controlURL.absoluteString == "rtsp://127.0.0.1:654/live/trackID=0", sdp.payloadType == 97,
              sdp.parameterSets == [Data([0x67, 1]), Data([0x68, 1])] else { return false }
        let redirected = body.replacingOccurrences(of: "trackID=0", with: "rtsp://192.168.42.2:654/live")
        return AnafiSDP(body: Data(redirected.utf8), base: base)?.controlURL.absoluteString == "rtsp://127.0.0.1:654/live" &&
            AnafiSDP.rebase(URL(string: "rtsp://192.168.42.1/live/")!, onto: base)?.absoluteString == "rtsp://127.0.0.1:654/live/"
    }
    static func callbackEpochs() -> Bool {
        let epochs = AnafiCallbackEpoch(), old = epochs.advance(), new = epochs.advance()
        return !epochs.contains(old) && epochs.retire(old) == nil && epochs.contains(new) &&
            epochs.retire(new) != nil && !epochs.contains(new)
    }
    private static func spin(until predicate: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
    private static func rtspLoopback() -> Bool {
        let fixture: AnafiRTSPFixture
        do { fixture = try AnafiRTSPFixture() } catch { return false }
        defer { fixture.stop() }
        guard spin(until: { fixture.port != nil }), let port = fixture.port,
              let url = URL(string: "rtsp://127.0.0.1:\(port)/live") else { return false }
        let client = AnafiRTSPClient()
        var frames = 0, live = false, failed = false
        client.onAccessUnit = { if $0.nalUnits == [Data([0x65, 0x88])] { frames += 1 } }
        client.onState = { text, ready in live = ready; if !ready && !text.hasPrefix("Opening") && text != "Video stopped" { failed = true } }
        for round in 1...3 {
            live = false; client.start(url: url)
            guard spin(until: { frames == round || failed }), !failed, live else { client.stop(); return false }
            client.stop()
            guard spin(until: { !live }) else { return false }
        }
        return frames == 3
    }
    private static func sessionLoopback() -> Bool {
        let fixture: AnafiSessionFixture
        do { fixture = try AnafiSessionFixture() } catch { return false }
        defer { fixture.stop() }
        guard spin(until: { fixture.port != nil }), let port = fixture.port else { return false }
        let client = AnafiSession()
        var state = AnafiSessionState(), failed = false
        client.onChange = { state = $0 }
        client.onLog = { if $0.contains("timed out") { failed = true } }
        for route in [AnafiRoute.direct, .skyController3, .direct] {
            state = AnafiSessionState()
            client.connect(host: "127.0.0.1", route: route, discoveryPort: port)
            guard spin(until: { state.camera.id == 3 || failed }), state.battery == 91,
                  state.flightState == 0, state.linkedAnafi, !state.macPiloting, !failed else { client.disconnect(); return false }
            client.setMacPiloting(true)
            guard spin(until: { state.canPilot || failed }), state.canPilot, !failed else { client.disconnect(); return false }
            client.updateInput(.init(roll: 20, pitch: 0, yaw: 0, gaz: 0))
            guard spin(until: { fixture.sawNonNeutralInput }) else { client.disconnect(); return false }
            client.setMacPiloting(false)
            guard spin(until: { !state.macPiloting }), spin(until: { fixture.sawNeutralInput }) else { client.disconnect(); return false }
            client.sendEmergency()
            guard spin(until: { fixture.sawEmergency }), !state.macPiloting else { client.disconnect(); return false }
            client.disconnect()
            guard spin(until: { !state.connected }), state.camera.id == nil else { return false }
        }
        return fixture.sawRetry
    }
}

/// A loopback-only fake RTSP server exercises the actual asynchronous client.
/// It cannot discover or contact an aircraft/controller.
private final class AnafiRTSPFixture {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "parrotlab.anafi.rtsp-fixture")
    private let lock = NSLock()
    private var storedPort: UInt16?
    private var connections: [NWConnection] = []
    var port: UInt16? { lock.lock(); defer { lock.unlock() }; return storedPort }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.lock.lock(); self.storedPort = self.listener.port?.rawValue; self.lock.unlock()
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection); connection.start(queue: self.queue); self.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel(); queue.sync { connections.forEach { $0.cancel() }; connections.removeAll() } }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let bytes { buffer.append(bytes) }
            while let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard let text = String(data: buffer.prefix(range.upperBound), encoding: .utf8) else { connection.cancel(); return }
                buffer = Data(buffer.dropFirst(range.upperBound))
                let method = text.split(separator: " ").first ?? ""
                let sequence = text.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("CSeq:") })?.dropFirst(5).trimmingCharacters(in: .whitespaces) ?? "0"
                var headers = "", body = ""
                if method == "DESCRIBE" {
                    body = "v=0\r\nm=video 0 RTP/AVP 97\r\na=rtpmap:97 H264/90000\r\na=control:trackID=0\r\n"
                    headers = "Content-Length: \(body.utf8.count)\r\n"
                }
                if method == "SETUP" { headers = "Session: fixture;timeout=10\r\nTransport: RTP/AVP/TCP;unicast;interleaved=2-3\r\n" }
                var response = Data("RTSP/1.0 200 OK\r\nCSeq: \(sequence)\r\n\(headers)\r\n\(body)".utf8)
                if method == "PLAY" {
                    let rtp = Data([0x80, 0xe1, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1, 0x65, 0x88])
                    response.append(Data([0x24, 2, 0, UInt8(rtp.count)])); response.append(rtp)
                }
                // Split a header and combine PLAY with video in the same read.
                connection.send(content: response.prefix(9), completion: .contentProcessed { _ in })
                connection.send(content: response.dropFirst(9), completion: .contentProcessed { _ in })
            }
            if !complete, error == nil { self.receive(connection, buffer: buffer) }
        }
    }
}

private final class AnafiSessionFixture {
    private let tcp: NWListener
    private let udp: NWListener
    private let queue = DispatchQueue(label: "parrotlab.anafi.session-fixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var outgoing: NWConnection?
    private var storedPort: UInt16?
    private var dropFirstACK = true
    private var retry = false, nonNeutral = false, neutral = false, emergency = false
    var port: UInt16? { lock.lock(); defer { lock.unlock() }; return storedPort }
    var sawRetry: Bool { lock.lock(); defer { lock.unlock() }; return retry }
    var sawNonNeutralInput: Bool { lock.lock(); defer { lock.unlock() }; return nonNeutral }
    var sawNeutralInput: Bool { lock.lock(); defer { lock.unlock() }; return neutral }
    var sawEmergency: Bool { lock.lock(); defer { lock.unlock() }; return emergency }
    init() throws {
        let t = NWParameters.tcp, u = NWParameters.udp
        t.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        u.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        tcp = try NWListener(using: t); udp = try NWListener(using: u)
        tcp.stateUpdateHandler = { [weak self] status in
            guard let self, case .ready = status else { return }
            self.publishPort()
        }
        udp.stateUpdateHandler = { [weak self] status in
            guard let self, case .ready = status else { return }
            self.publishPort()
        }
        tcp.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection); connection.start(queue: self.queue); self.receiveHandshake(connection, buffer: Data())
        }
        udp.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection); connection.start(queue: self.queue); self.receiveCommands(connection)
        }
        tcp.start(queue: queue); udp.start(queue: queue)
    }
    private func publishPort() {
        guard tcp.port != nil, udp.port != nil else { return }
        lock.lock(); storedPort = tcp.port?.rawValue; lock.unlock()
    }
    func stop() {
        tcp.cancel(); udp.cancel()
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll(); outgoing?.cancel(); outgoing = nil }
    }
    private func receiveHandshake(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer; if let data { buffer.append(data) }
            if let object = ARSDKDiscoveryProtocol.responseObject(from: buffer),
               let local = object["d2c_port"] as? Int, let port = NWEndpoint.Port(rawValue: UInt16(local)),
               let commandPort = self.udp.port?.rawValue {
                self.outgoing?.cancel()
                let outgoing = NWConnection(host: "127.0.0.1", port: port, using: .udp)
                self.outgoing = outgoing; outgoing.start(queue: self.queue); self.dropFirstACK = true
                self.lock.lock(); self.nonNeutral = false; self.neutral = false; self.emergency = false; self.lock.unlock()
                let response = Data("{\"status\":0,\"proto_v\":1,\"c2d_port\":\(commandPort)}".utf8)
                connection.send(content: response.prefix(7), completion: .contentProcessed { _ in })
                connection.send(content: response.dropFirst(7), completion: .contentProcessed { _ in })
            } else if !complete, error == nil { self.receiveHandshake(connection, buffer: buffer) }
        }
    }
    private func send(_ data: Data) { outgoing?.send(content: data, completion: .contentProcessed { _ in }) }
    private func receiveCommands(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let frames = AnafiNetworkFrame.decode(data) {
                for frame in frames {
                    if frame.type == 4, frame.channel == 12, frame.payload == ARSDKPhotoCommand.emergency {
                        self.lock.lock(); self.emergency = true; self.lock.unlock()
                        self.send(ARSDKPhotoProtocol.frame(type: 1, id: 140, sequence: 1, payload: Data([frame.sequence])))
                    }
                    if frame.type == 4, frame.channel == 11 {
                        if self.dropFirstACK {
                            self.dropFirstACK = false
                            var link = Data([137, 0, 5, 0]); link.appendAnafiLE(UInt32(3))
                            link.append(Data("fixture\0".utf8)); link.appendAnafiLE(UInt16(0x0914)); link.append(Data("ANAFI fixture\0".utf8))
                            let events = [link, AnafiSelfTest.cameraCapability(), Data([0, 5, 1, 0, 91]), Data([1, 4, 1, 0, 0, 0, 0, 0])]
                            for (index, event) in events.enumerated() {
                                let packet = ARSDKPhotoProtocol.frame(type: 4, id: 126, sequence: UInt8(index + 1), payload: event)
                                self.send(packet); self.send(packet) // retransmitted notification must be ACKed again
                            }
                        } else {
                            if frame.sequence == 1 { self.lock.lock(); self.retry = true; self.lock.unlock() }
                            self.send(ARSDKPhotoProtocol.frame(type: 1, id: 139, sequence: 1, payload: Data([frame.sequence])))
                            if frame.payload.starts(with: Data([4, 20, 0, 0])) {
                                let event = Data([4, 21, 0, 0]) + frame.payload.dropFirst(4)
                                self.send(ARSDKPhotoProtocol.frame(type: 2, id: 127, sequence: frame.sequence, payload: event))
                            }
                        }
                    }
                    if frame.type == 2, frame.channel == 10, frame.payload.starts(with: Data([1, 0, 2, 0])), frame.payload.count >= 9 {
                        self.lock.lock()
                        if frame.payload[5...8].contains(where: { $0 != 0 }) { self.nonNeutral = true }
                        else if self.nonNeutral { self.neutral = true }
                        self.lock.unlock()
                    }
                }
            }
            if error == nil { self.receiveCommands(connection) }
        }
    }
}
