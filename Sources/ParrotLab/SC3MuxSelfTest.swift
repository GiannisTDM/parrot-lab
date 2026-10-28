import Foundation
import Network

enum SC3MuxSelfTest {
    static func run() -> Bool {
        guard packets(), loopback() else { fputs("SC3 libmux self-test failed\n", stderr); return false }
        print("SC3 libmux command, video proxy, ACK and reconnect self-tests passed"); return true
    }
    private static func packets() -> Bool {
        let wire = SC3MuxProtocol(); _ = wire.start()
        let discovery = SC2PompMessage.encode(id: 2, fields: [.string("SC3"), .u32(0x0918), .string("fixture")])
        let encoded = SC2MuxCodec.encode(channel: 2, payload: discovery)
        guard wire.receive(encoded.prefix(5)).isEmpty, wire.receive(encoded.dropFirst(5)).count == 1,
              wire.receive(SC2MuxCodec.encode(channel: 3, payload: SC2PompMessage.encode(id: 2,
                fields: [.i32(0), .string("{\"proto_v\":1}")]))) == [.connected] else { return false }
        let request = wire.requestVideo()
        guard case .write(let packet) = request.last,
              let proxy = control(packet), proxy.id == 9, proxy.args[3] == 554,
              proxy.extra == Data("drone\0".utf8) else { return false }
        let reply = SC3MuxControl(10, args: [proxy.args[0], 0, 0, 0x0102a8c0, 554], extra: Data("drone\0".utf8))
        guard wire.receive(reply.packet) == [.videoResolved], wire.connectVideo().count == 2,
              let channel = wire.videoChannel else { return false }
        guard wire.receive(SC3MuxControl(15, channel: channel | 0x8000_0000, args: [5678]).packet) == [.videoConnected],
              wire.sendVideo(Data(repeating: 42, count: 1_048_576)).count == 2, wire.videoWaitingACK,
              wire.sendVideo(Data([1])).isEmpty,
              wire.receive(SC3MuxControl(18, channel: channel + 1 | 0x8000_0000).packet).isEmpty,
              wire.videoWaitingACK,
              wire.receive(SC3MuxControl(18, channel: channel | 0x8000_0000).packet) == [.videoWritable],
              !wire.videoWaitingACK,
              wire.receive(SC2MuxCodec.encode(channel: channel | 0x8000_0000, payload: Data([1, 2]))) == [.videoData(Data([1, 2]))] else { return false }
        _ = wire.closeVideo()
        guard wire.receive(SC2MuxCodec.encode(channel: channel | 0x8000_0000, payload: Data([9]))).isEmpty else { return false }
        for size in 0..<32 { guard SC3MuxControl.decode(Data(repeating: 0, count: size)) == nil else { return false } }
        let rejected = SC3MuxProtocol(); _ = rejected.start(); _ = rejected.receive(encoded)
        let bad = rejected.receive(SC2MuxCodec.encode(channel: 3, payload: SC2PompMessage.encode(id: 2,
            fields: [.i32(0), .string("{\"proto_v\":3}")])))
        guard case .failed = bad.first else { return false }
        return !rejected.connected
    }
    private static func control(_ packet: Data) -> SC3MuxControl? {
        var decoder = SC2MuxStreamDecoder()
        return decoder.append(packet).first.flatMap { SC3MuxControl.decode($0.payload) }
    }
    private static func spin(_ predicate: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(4)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
    private static func loopback() -> Bool {
        let fixture: SC3MuxFixture
        do { fixture = try SC3MuxFixture() } catch { return false }
        defer { fixture.stop() }
        guard spin({ fixture.port != nil }), let port = fixture.port else { return false }
        let session = AnafiSession(), video = AnafiRTSPClient()
        var state = AnafiSessionState(), frames = 0, failed = false
        defer { session.disconnectAndWait(); video.stopAndWait() }
        session.onChange = { state = $0 }
        session.onMuxVideo = { result in
            switch result { case .success(let url): video.start(url: url); case .failure: failed = true }
        }
        video.onAccessUnit = { if $0.nalUnits == [Data([0x65, 0x88])] { frames += 1 } }
        for round in 1...3 {
            session.connectMux(link: SC3MuxTCPLink(port: port))
            guard spin({ state.camera.id == 3 || failed }), !failed, state.route.usesMux,
                  state.battery == 91, state.flightState == 0, state.linkedAnafi, !state.macPiloting else { return false }
            // Supersede a queued start, then restart video in the same command
            // session. Old proxy readiness/EOF callbacks must stay retired.
            session.startMuxVideo(); session.stopMuxVideo(); session.startMuxVideo()
            guard spin({ frames == round * 2 - 1 || failed }), !failed else { return false }
            video.stop(); session.stopMuxVideo(); session.startMuxVideo()
            guard spin({ frames == round * 2 || failed }), !failed, state.camera.id == 3,
                  state.connected else { return false }
            session.setMacPiloting(true)
            guard spin({ state.canPilot }) else { return false }
            session.updateInput(.init(roll: 20, pitch: 0, yaw: 0, gaz: 0))
            guard spin({ fixture.nonNeutral >= round }) else { return false }
            session.disconnect(); video.stop()
            guard spin({ !state.connected && fixture.neutral >= round && fixture.ownershipReturned >= round }),
                  state.camera.id == nil, !state.canPilot else { return false }
        }
        return fixture.retry && frames == 6
    }
}

/// Loopback USB/accessory bridge emulator; no real USB or aircraft service.
private final class SC3MuxFixture {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "parrotlab.sc3.fixture")
    private let lock = NSLock()
    private var peers: [SC3MuxFixturePeer] = []
    private var storedPort: UInt16?
    private var counts = ["input": 0, "neutral": 0, "ownership": 0, "retry": 0]
    var port: UInt16? { lock.lock(); defer { lock.unlock() }; return storedPort }
    private func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }
    var nonNeutral: Int { count("input") }
    var neutral: Int { count("neutral") }
    var ownershipReturned: Int { count("ownership") }
    var retry: Bool { count("retry") > 0 }
    init() throws {
        let params = NWParameters.tcp; params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.lock.lock(); self.storedPort = self.listener.port?.rawValue; self.lock.unlock()
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let peer = SC3MuxFixturePeer(connection: connection)
            peer.onCount = { [weak self] key in
                guard let self else { return }; self.lock.lock(); self.counts[key, default: 0] += 1; self.lock.unlock()
            }
            self.peers.append(peer); peer.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel(); queue.sync { peers.forEach { $0.stop() }; peers.removeAll() } }
}

private final class SC3MuxFixturePeer {
    var onCount: ((String) -> Void)?
    private let connection: NWConnection
    private var decoder = SC2MuxStreamDecoder()
    private var videoChannel: UInt32?
    private var request = Data()
    private var dropACK = true, sawInput = false, sawNeutral = false
    private var stateSequence: UInt8 = 0
    init(connection: NWConnection) { self.connection = connection }
    func start(queue: DispatchQueue) { connection.start(queue: queue); receive() }
    func stop() { connection.cancel() }
    private func send(_ packet: Data) {
        connection.send(content: packet.prefix(5), completion: .contentProcessed { _ in })
        connection.send(content: packet.dropFirst(5), completion: .contentProcessed { _ in })
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { for frame in self.decoder.append(data) { self.consume(frame) } }
            if !complete, error == nil { self.receive() }
        }
    }
    private func consume(_ frame: SC2MuxFrame) {
        if frame.channel == 0, let control = SC3MuxControl.decode(frame.payload) {
            switch control.id {
            case 127: if control.args[0] == 0 { send(SC3MuxControl(127, args: [1, 2]).packet) }
            case 9: send(SC3MuxControl(10, args: [control.args[0], 0, 0, 0x0102a8c0, 554], extra: Data("drone\0".utf8)).packet)
            case 13:
                videoChannel = control.channel
                send(SC3MuxControl(15, channel: control.channel | 0x8000_0000, args: [5678]).packet)
            case 14: videoChannel = nil; request = Data()
            case 17: send(SC3MuxControl(18, channel: control.channel | 0x8000_0000).packet)
            default: break
            }
        } else if frame.channel == 2 {
            send(SC2MuxCodec.encode(channel: 2, payload: SC2PompMessage.encode(id: 2,
                fields: [.string("SC3 fixture"), .u32(0x0918), .string("sc3-fixture")])) )
        } else if frame.channel == 3 {
            send(SC2MuxCodec.encode(channel: 3, payload: SC2PompMessage.encode(id: 2,
                fields: [.i32(0), .string("{\"proto_v\":1}")])))
        } else if frame.channel == 1 {
            for packet in AnafiNetworkFrame.decode(frame.payload) ?? [] { consumeCommand(packet) }
        } else if frame.channel == videoChannel { request.append(frame.payload); consumeRTSP() }
    }
    private func event(_ payload: Data, reliable: Bool = false) {
        stateSequence &+= 1
        let packet = ARSDKPhotoProtocol.frame(type: reliable ? 4 : 2, id: reliable ? 126 : 127,
                                             sequence: stateSequence, payload: payload)
        send(SC2MuxCodec.encode(channel: 1, payload: packet))
        if reliable { send(SC2MuxCodec.encode(channel: 1, payload: packet)) }
    }
    private func consumeCommand(_ packet: AnafiNetworkFrame) {
        if packet.type == 4, packet.channel == 11 {
            if dropACK {
                dropACK = false
                var link = Data([137, 0, 5, 0]); link.appendAnafiLE(UInt32(3)); link.append(Data("anafi\0".utf8))
                link.appendAnafiLE(UInt16(0x0914)); link.append(Data("ANAFI fixture\0".utf8))
                for payload in [link, AnafiSelfTest.cameraCapability(), Data([0, 5, 1, 0, 91]), Data([1, 4, 1, 0, 0, 0, 0, 0])] { event(payload, reliable: true) }
                return
            }
            if packet.sequence == 1 { onCount?("retry") }
            send(SC2MuxCodec.encode(channel: 1, payload: ARSDKPhotoProtocol.frame(type: 1, id: 139,
                sequence: 1, payload: Data([packet.sequence]))))
            if packet.payload.starts(with: Data([4, 20, 0, 0])) {
                if packet.payload.last == 0, packet.payload[4] == 0 { onCount?("ownership") }
                event(Data([4, 21, 0, 0]) + packet.payload.dropFirst(4))
            }
        }
        if packet.type == 2, packet.channel == 10, packet.payload.count >= 9,
           packet.payload.starts(with: Data([1, 0, 2, 0])) {
            if packet.payload[5...8].contains(where: { $0 != 0 }) {
                if !sawInput { sawInput = true; onCount?("input") }
            } else if sawInput, !sawNeutral { sawNeutral = true; onCount?("neutral") }
        }
    }
    private func consumeRTSP() {
        while let end = request.range(of: Data("\r\n\r\n".utf8)), let channel = videoChannel,
              let text = String(data: request.prefix(end.upperBound), encoding: .utf8) {
            request = Data(request.dropFirst(end.upperBound))
            let method = text.split(separator: " ").first ?? ""
            let cseq = text.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("CSeq:") })?.dropFirst(5).trimmingCharacters(in: .whitespaces) ?? "0"
            var headers = "", body = ""
            if method == "DESCRIBE" {
                body = "v=0\r\nm=video 0 RTP/AVP 97\r\na=rtpmap:97 H264/90000\r\na=control:trackID=0\r\n"
                headers = "Content-Base: rtsp://192.168.42.1/live\r\nContent-Length: \(body.utf8.count)\r\n"
            }
            if method == "SETUP" { headers = "Session: fixture;timeout=60\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" }
            var response = Data("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n\(headers)\r\n\(body)".utf8)
            if method == "PLAY" {
                let rtp = Data([0x80, 0xe1, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1, 0x65, 0x88])
                response.append(Data([0x24, 0, 0, UInt8(rtp.count)])); response.append(rtp)
            }
            send(SC2MuxCodec.encode(channel: channel | 0x8000_0000, payload: response))
        }
    }
}
