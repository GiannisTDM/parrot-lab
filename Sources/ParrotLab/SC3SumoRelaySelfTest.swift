import Foundation
import Network
import Darwin

enum SC3SumoRelaySelfTest {
    static func run() -> Bool {
        guard check(routeContract(), "explicit ports and existing routes"),
              check(loopback(), "same-socket UDP, raw MJPEG, ACK, heartbeat and reconnect"),
              check(heartbeatOnlyCannotArm(), "heartbeat cannot substitute for initial drone state"),
              check(existingRoutes(), "direct Sumo and SC2 transport isolation"),
              check(discoveryFailures(), "missing relay, upstream failure and wrong model") else { return false }
        print("SC3 Sumo relay transport self-tests passed (loopback only; no hardware)")
        return true
    }

    private static func check(_ value: Bool, _ name: String) -> Bool {
        if !value { fputs("SC3 Sumo relay self-test failed: \(name)\n", stderr) }
        return value
    }

    private static func fail(_ line: UInt = #line) -> Bool {
        fputs("SC3 Sumo relay check failed at line \(line)\n", stderr)
        return false
    }

    private static func spin(timeout: TimeInterval = 4, _ predicate: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }

    private static func settle(_ duration: TimeInterval) {
        let end = Date().addingTimeInterval(duration)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private static func routeContract() -> Bool {
        ARSDKConnectionRoute.sumoSC3Relay.discoveryPort == 44_446 &&
        ARSDKConnectionRoute.skyController.discoveryPort == 44_444 &&
        ARSDKConnectionRoute.directProduct.discoveryPort == 44_444 &&
        ARSDKConnectionRoute.sumoSC3Relay.usesDirectARNetworkVideo &&
        ARSDKConnectionRoute.directProduct.usesDirectARNetworkVideo &&
        !ARSDKConnectionRoute.skyController.usesDirectARNetworkVideo &&
        SC3SumoRelay.defaultHost == "192.168.53.1" && SC3SumoRelay.defaultCommandPort == 54_323 &&
        SC3SumoRelay.keepaliveIntervalMilliseconds <= 500
    }

    private static func loopback() -> Bool {
        let fixture: SC3SumoRelayFixture
        do { fixture = try SC3SumoRelayFixture() } catch { return fail() }
        defer { fixture.stop() }
        guard spin({ fixture.port != nil }), let port = fixture.port else { return fail() }
        let client = ARSDKCommandClient(loopbackDiscoveryPort: port)
        defer { client.stop(); _ = client.diagnosticSummary }
        client.setProductModel(.jumpingSumo)
        var connected = false, failed = false, frames = 0, batteryEvents = 0, heartbeats = 0
        var lastHeartbeat: TimeInterval = 0
        var negotiation: ARStream1Negotiation?
        client.onMJPEGFrame = { jpeg, _ in
            if jpeg == SC3SumoRelayFixture.jpeg { frames += 1 } else { failed = true }
        }
        client.onTelemetryEvent = { if $0 == .droneBattery(73) { batteryEvents += 1 } }
        client.onRelayHeartbeat = {
            if !$0.isFinite || $0 < lastHeartbeat { failed = true }
            lastHeartbeat = $0; heartbeats += 1
        }
        client.onARStream1Diagnostics = { negotiation = $0.negotiation }
        for round in 0..<2 {
            connected = false
            let previousFrames = frames, previousBattery = batteryEvents, previousHeartbeats = heartbeats
            client.connect(host: "127.0.0.1", route: .sumoSC3Relay) {
                switch $0 { case .success: connected = true; case .failure: failed = true }
            }
            guard spin({ connected || failed }), connected, !failed,
                  spin({ frames > previousFrames && batteryEvents > previousBattery && heartbeats > previousHeartbeats }),
                  fixture.validDiscovery, !fixture.wrongSourcePort,
                  spin({ fixture.sawVideoACK(session: round) && fixture.sawReliableACK(session: round) && fixture.sawPong(session: round) }) else {
                fputs("SC3 relay round \(round): connected=\(connected) failed=\(failed) frames=\(frames) battery=\(batteryEvents) heartbeat=\(heartbeats) videoACK=\(fixture.sawVideoACK(session: round)) stateACK=\(fixture.sawReliableACK(session: round)) pong=\(fixture.sawPong(session: round)) \(client.diagnosticSummary)\n", stderr)
                return fail()
            }

            // Idle keepalive is bounded, neutral, and works with piloting off.
            guard spin(timeout: 2, { fixture.pcmd(session: round).count >= 3 }) else { return fail() }
            let idle = fixture.pcmd(session: round)
            guard idle.count <= 5, idle.allSatisfy({ $0.payload == Data([3, 0, 0, 0, 0, 0, 0]) }),
                  zip(idle, idle.dropFirst()).allSatisfy({ $1.time - $0.time < 1.2 }),
                  spin({ negotiation?.fragmentSize == 65_000 }),
                  negotiation?.fragmentMaximumNumber == 4,
                  negotiation?.maximumAcknowledgementInterval == 0 else { return fail() }

            // The UDP relay port is peer-checked. Video and malformed pings
            // cannot extend the state heartbeat; neither can another sender.
            let heartbeatBeforeNoise = heartbeats
            fixture.sendNoise(session: round)
            settle(0.12)
            guard heartbeats == heartbeatBeforeNoise, batteryEvents == previousBattery + 1 else { return fail() }

            // Connection/reconnection never implicitly arms old input or jumps.
            client.startPiloting()
            client.updatePilotingInput(.init(roll: 40, pitch: 40, yaw: 0, gaz: 0))
            client.sendJumpingSumoJump(.high)
            guard client.diagnosticSummary.contains("relayArmed=false"), fixture.jumps(session: round) == 0 else { return fail() }
            client.setRelayMovementEnabled(true)
            client.startPiloting()
            client.updatePilotingInput(.init(roll: -19, pitch: -27, yaw: 0, gaz: 0))
            guard spin({ fixture.pcmd(session: round).contains { $0.payload == Data([3, 0, 0, 0, 1, 229, 237]) } }) else { return fail() }
            client.sendJumpingSumoJump(.high)
            guard spin({ fixture.jumps(session: round) > 0 }) else { return fail() }
            client.neutralizePilotingInput()
            _ = client.diagnosticSummary
            settle(0.05)
            let jumpCount = fixture.jumps(session: round)
            settle(0.35)
            guard fixture.jumps(session: round) == jumpCount else { return fail() }
            client.setRelayMovementEnabled(true)
            client.startPiloting()
            client.updatePilotingInput(.init(roll: 11, pitch: 31, yaw: 0, gaz: 0))
            guard spin({ fixture.pcmd(session: round).last?.payload == Data([3, 0, 0, 0, 1, 31, 11]) }) else { return fail() }
            let queuedCallbackCounts = (batteryEvents, heartbeats)
            fixture.sendInitialEvents(session: round)
            // Let the network queue enqueue state/heartbeat callbacks while
            // the main queue is deliberately not pumping, then retire them.
            Thread.sleep(forTimeInterval: 0.1)
            client.stop()
            let summary = client.diagnosticSummary // serialize the close before checking the peer.
            guard summary.contains("udp=false"), summary.contains("relayKeepalive=false"),
                  summary.contains("acks=0"), summary.contains("axes=0,0,0,0"),
                  spin({ fixture.pcmd(session: round).last?.payload == Data([3, 0, 0, 0, 0, 0, 0]) }) else { return fail() }
            guard batteryEvents == queuedCallbackCounts.0, heartbeats == queuedCallbackCounts.1 else { return fail() }
            let afterClose = fixture.records(session: round).count
            let callbacksAfterClose = (frames, batteryEvents, heartbeats)
            fixture.sendInitialEvents(session: round)
            settle(0.6)
            guard fixture.records(session: round).count == afterClose,
                  frames == callbacksAfterClose.0, batteryEvents == callbacksAfterClose.1,
                  heartbeats == callbacksAfterClose.2 else { return fail() }
        }
        // An accidental mode change closes the relay; it must never become a
        // Bebop/ANAFI command path on the already negotiated UDP connection.
        connected = false
        let stateBeforeThirdConnection = batteryEvents
        client.connect(host: "127.0.0.1", route: .sumoSC3Relay) { if case .success = $0 { connected = true } }
        guard spin({ connected && batteryEvents > stateBeforeThirdConnection }), spin({ fixture.pcmd(session: 2).count > 0 }) else { return fail() }
        client.setRelayMovementEnabled(true); client.startPiloting()
        client.updatePilotingInput(.init(roll: 15, pitch: 25, yaw: 0, gaz: 0))
        guard spin({ fixture.pcmd(session: 2).contains { $0.payload == Data([3, 0, 0, 0, 1, 25, 15]) } }) else { return fail() }
        // No main-runloop pumping: network-queue freshness must stop movement
        // even if AppKit is stalled and cannot notice its own telemetry timer.
        Thread.sleep(forTimeInterval: SumoRelayDriveGate.freshnessInterval + 0.2)
        guard client.diagnosticSummary.contains("relayArmed=false"),
              client.diagnosticSummary.contains("pcmd=false"),
              fixture.pcmd(session: 2).last?.payload == Data([3, 0, 0, 0, 0, 0, 0]) else { return fail() }
        fixture.sendInitialEvents(session: 2)
        settle(0.1)
        client.updatePilotingInput(.init(roll: 50, pitch: 50, yaw: 0, gaz: 0))
        client.sendJumpingSumoJump(.high)
        guard client.diagnosticSummary.contains("relayArmed=false"), fixture.jumps(session: 2) == 0,
              fixture.pcmd(session: 2).last?.payload == Data([3, 0, 0, 0, 0, 0, 0]) else { return fail() }
        client.setProductModel(.anafi4K)
        return client.diagnosticSummary.contains("udp=false") && !failed
    }

    private static func discoveryFailures() -> Bool {
        for mode in [SC3SumoRelayFixture.Reply.rejected, .missingPort, .missingStatus, .malformed] {
            let fixture: SC3SumoRelayFixture
            do { fixture = try SC3SumoRelayFixture(reply: mode) } catch { return fail() }
            defer { fixture.stop() }
            guard spin({ fixture.port != nil }), let port = fixture.port else { return fail() }
            let client = ARSDKCommandClient(loopbackDiscoveryPort: port)
            defer { client.stop(); _ = client.diagnosticSummary }
            client.setProductModel(.jumpingSumo)
            var error: String?
            client.connect(host: "127.0.0.1", route: .sumoSC3Relay) {
                if case .failure(let failure) = $0 { error = failure.localizedDescription }
            }
            guard spin({ error != nil }), error?.contains("44446") == true,
                  error?.contains("USB network link") == true,
                  error?.contains("associated with the Sumo") == true,
                  client.diagnosticSummary.contains("udp=false") else { return fail() }
        }
        let closedFixture: SC3SumoRelayFixture
        do { closedFixture = try SC3SumoRelayFixture() } catch { return fail() }
        guard spin({ closedFixture.port != nil }), let closedPort = closedFixture.port else { closedFixture.stop(); return fail() }
        closedFixture.stop()
        let client = ARSDKCommandClient(loopbackDiscoveryPort: closedPort)
        defer { client.stop(); _ = client.diagnosticSummary }
        var error: String?
        client.setProductModel(.bebop2)
        client.connect(host: "127.0.0.1", route: .sumoSC3Relay) {
            if case .failure(let failure) = $0 { error = failure.localizedDescription }
        }
        guard spin({ error != nil }), error?.contains("requires Jumping Sumo") == true,
              client.diagnosticSummary.contains("udp=false") else { return fail() }
        error = nil
        client.setProductModel(.jumpingSumo)
        client.connect(host: "127.0.0.1", route: .sumoSC3Relay) {
            if case .failure(let failure) = $0 { error = failure.localizedDescription }
        }
        return spin({ error != nil }) && error?.contains("44446") == true && client.diagnosticSummary.contains("udp=false")
    }

    private static func existingRoutes() -> Bool {
        for route in [ARSDKConnectionRoute.directProduct, .skyController] {
            let fixture: SC3SumoRelayFixture
            do { fixture = try SC3SumoRelayFixture() } catch { return false }
            defer { fixture.stop() }
            guard spin({ fixture.port != nil }), let port = fixture.port else { return fail() }
            let client = ARSDKCommandClient(loopbackDiscoveryPort: port)
            defer { client.stop(); _ = client.diagnosticSummary }
            client.setProductModel(.jumpingSumo)
            var connected = false, batteries = 0, frames = 0, relayCallbacks = 0
            client.onTelemetryEvent = { if $0 == .droneBattery(73) { batteries += 1 } }
            client.onMJPEGFrame = { jpeg, _ in if jpeg == SC3SumoRelayFixture.jpeg { frames += 1 } }
            client.onRelayHeartbeat = { _ in relayCallbacks += 1 }
            client.onRelayState = { _ in relayCallbacks += 1 }
            client.connect(host: "127.0.0.1", route: route) { if case .success = $0 { connected = true } }
            guard spin({ connected }) else { return fail() }
            client.sendRequestAllStates()
            guard spin({ batteries == 1 }) else { return fail() }
            if route == .directProduct {
                guard spin({ frames == 1 && fixture.sawVideoACK(session: 0) }) else { return fail() }
            } else {
                settle(0.1)
                guard frames == 0, !fixture.sawVideoACK(session: 0) else { return fail() }
            }
            client.startPiloting()
            client.updatePilotingInput(.init(roll: 12, pitch: 34, yaw: 0, gaz: 0))
            guard spin({ fixture.pcmd(session: 0).contains { $0.payload == Data([3, 0, 0, 0, 1, 34, 12]) } }),
                  relayCallbacks == 0, client.diagnosticSummary.contains("relayKeepalive=false") else { return fail() }
        }
        return true
    }

    private static func heartbeatOnlyCannotArm() -> Bool {
        let fixture: SC3SumoRelayFixture
        do { fixture = try SC3SumoRelayFixture(initialState: false) } catch { return fail() }
        defer { fixture.stop() }
        guard spin({ fixture.port != nil }), let port = fixture.port else { return fail() }
        let client = ARSDKCommandClient(loopbackDiscoveryPort: port)
        defer { client.stop(); _ = client.diagnosticSummary }
        client.setProductModel(.jumpingSumo)
        var connected = false, pings = 0, states = 0
        client.onRelayHeartbeat = { _ in pings += 1 }
        client.onRelayState = { sample in
            if (0...1).contains(ProcessInfo.processInfo.systemUptime - sample) { states += 1 }
        }
        client.connect(host: "127.0.0.1", route: .sumoSC3Relay) { if case .success = $0 { connected = true } }
        guard spin({ connected && pings > 0 }) else { return fail() }
        client.setRelayMovementEnabled(true); client.startPiloting()
        client.updatePilotingInput(.init(roll: 30, pitch: 30, yaw: 0, gaz: 0))
        client.sendJumpingSumoJump(.high)
        guard states == 0, client.diagnosticSummary.contains("relayArmed=false"),
              fixture.jumps(session: 0) == 0,
              fixture.pcmd(session: 0).allSatisfy({ $0.payload == Data([3, 0, 0, 0, 0, 0, 0]) }) else { return fail() }
        fixture.sendDroneState(session: 0)
        guard spin({ states == 1 }), client.diagnosticSummary.contains("relayArmed=false") else { return fail() }
        client.setRelayMovementEnabled(true); client.startPiloting()
        client.updatePilotingInput(.init(roll: 10, pitch: 20, yaw: 0, gaz: 0))
        return spin({ fixture.pcmd(session: 0).contains { $0.payload == Data([3, 0, 0, 0, 1, 20, 10]) } })
    }
}

/// Numeric-loopback TCP discovery plus a single BSD UDP socket, mirroring the
/// relay's strict advertised client-port admission. No real USB/drone access.
private final class SC3SumoRelayFixture {
    enum Reply { case normal, rejected, missingPort, missingStatus, malformed }
    struct Record {
        let session: Int
        let type: UInt8
        let channel: UInt8
        let payload: Data
        let time: TimeInterval
    }
    static let jpeg = Data([0xff, 0xd8]) + Data(repeating: 0x35, count: 65_016) + Data([0xff, 0xd9])
    private let listener: NWListener
    private let queue = DispatchQueue(label: "parrotlab.sc3-sumo.fixture")
    private let udpFD: Int32
    private let noiseFD: Int32
    private let udpPort: UInt16
    private var source: DispatchSourceRead?
    private let reply: Reply
    private let initialState: Bool
    private var peers: [NWConnection] = []
    private var advertisedPorts: [UInt16] = []
    private var packets: [Record] = []
    private var emittedSessions = Set<Int>()
    private var discoveryValid = true
    private var invalidSourcePort = false
    private var storedPort: UInt16?
    var port: UInt16? { queue.sync { storedPort } }
    var validDiscovery: Bool { queue.sync { discoveryValid } }
    var wrongSourcePort: Bool { queue.sync { invalidSourcePort } }
    func records(session: Int) -> [Record] { queue.sync { packets.filter { $0.session == session } } }
    func pcmd(session: Int) -> [Record] { records(session: session).filter { $0.type == 2 && $0.channel == 10 } }
    func jumps(session: Int) -> Int { records(session: session).filter { $0.payload.starts(with: Data([3, 2, 3, 0])) }.count }
    func sawVideoACK(session: Int) -> Bool { records(session: session).contains { $0.channel == 13 && $0.payload.count == 18 } }
    func sawReliableACK(session: Int) -> Bool { records(session: session).contains { $0.type == 1 && $0.channel == 254 && $0.payload == Data([9]) } }
    func sawPong(session: Int) -> Bool { records(session: session).contains { $0.type == 2 && $0.channel == 1 && $0.payload == Data(repeating: 7, count: 8) } }

    init(reply: Reply = .normal, initialState: Bool = true) throws {
        self.reply = reply
        self.initialState = initialState
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let socket = try Self.socket()
        udpFD = socket.0; udpPort = socket.1
        do { noiseFD = try Self.socket().0 } catch { Darwin.close(socket.0); throw error }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.storedPort = self.listener.port?.rawValue
        }
        listener.newConnectionHandler = { [weak self] peer in
            guard let self else { peer.cancel(); return }
            self.peers.append(peer); peer.start(queue: self.queue); self.readDiscovery(peer, accumulated: Data())
        }
        let read = DispatchSource.makeReadSource(fileDescriptor: udpFD, queue: queue)
        read.setEventHandler { [weak self] in self?.readDatagrams() }
        source = read; read.resume()
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        queue.sync {
            peers.forEach { $0.cancel() }; peers.removeAll()
            source?.setEventHandler {}; source?.cancel(); source = nil
            Darwin.close(udpFD); Darwin.close(noiseFD)
        }
    }

    private static func socket() throws -> (Int32, UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        // Darwin's default UDP send buffer can be smaller than stock Sumo
        // fragments. The fixture must actually transmit, rather than silently
        // passing the small final fragment and ACK checks on its own.
        var sendBytes: Int32 = 262_144
        _ = withUnsafePointer(to: &sendBytes) {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0, named == 0 else { let error = errno; Darwin.close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    private func readDiscovery(_ peer: NWConnection, accumulated: Data) {
        peer.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var bytes = accumulated; if let data { bytes.append(data) }
            guard bytes.count <= 8192 else { peer.cancel(); return }
            if let object = ARSDKDiscoveryProtocol.responseObject(from: bytes),
               let integer = object["d2c_port"] as? Int, let port = UInt16(exactly: integer), port > 0 {
                self.discoveryValid = self.discoveryValid && object["controller_type"] as? String == "computer" &&
                    object["arstream2_client_stream_port"] == nil && object["arstream2_client_control_port"] == nil
                self.advertisedPorts.append(port)
                let reply: String
                switch self.reply {
                case .normal:
                    reply = "{\"status\":0,\"c2d_port\":\(self.udpPort),\"arstream_fragment_size\":65000,\"arstream_fragment_maximum_number\":4,\"arstream_max_ack_interval\":0,\"unrecognized_extension\":{\"preserved\":true}}"
                case .rejected: reply = "{\"status\":-1,\"c2d_port\":\(self.udpPort)}"
                case .missingPort: reply = "{\"status\":0,\"c2d_port\":0}"
                case .missingStatus: reply = "{\"c2d_port\":\(self.udpPort)}"
                case .malformed: reply = "not JSON"
                }
                let response = Data(reply.utf8) + Data([0])
                peer.send(content: response.prefix(9), completion: .contentProcessed { _ in })
                peer.send(content: response.dropFirst(9), completion: .contentProcessed { _ in peer.cancel() })
            } else if !complete, error == nil { self.readDiscovery(peer, accumulated: bytes) }
        }
    }

    private func readDatagrams() {
        var bytes = [UInt8](repeating: 0, count: 65_535)
        while true {
            var address = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = bytes.withUnsafeMutableBytes { buffer in
                withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udpFD, buffer.baseAddress, buffer.count, 0, $0, &length) }
                }
            }
            guard count > 0 else { return }
            let port = UInt16(bigEndian: address.sin_port)
            guard let session = advertisedPorts.lastIndex(of: port) else { invalidSourcePort = true; continue }
            let packet = Data(bytes.prefix(count))
            guard packet.count >= 7 else { continue }
            packets.append(Record(session: session, type: packet[0], channel: packet[1], payload: Data(packet.dropFirst(7)), time: ProcessInfo.processInfo.systemUptime))
            if emittedSessions.insert(session).inserted {
                sendInitialEventsLocked(session: session)
            } else if packet[0] == 2, packet[1] == 10 {
                // Over-negotiated five-fragment video remains rejected and
                // triggers periodic diagnostics without producing a frame.
                send(ARSDKPhotoProtocol.frame(type: 3, id: 125, sequence: 5,
                    payload: Data([43, 0, 1, 0, 5, 0xff, 0xd8, 0xff, 0xd9])), session: session)
            }
        }
    }

    func sendInitialEvents(session: Int) { queue.async { [weak self] in self?.sendInitialEventsLocked(session: session) } }
    private func sendInitialEventsLocked(session: Int) {
        guard advertisedPorts.indices.contains(session) else { return }
        if initialState { send(ARSDKPhotoProtocol.frame(type: 4, id: 126, sequence: 9, payload: Data([0, 5, 1, 0, 73])), session: session) }
        send(ARSDKPhotoProtocol.frame(type: 2, id: 0, sequence: 4, payload: Data(repeating: 7, count: 8)), session: session)
        for index in 0..<2 {
            let body = index == 0 ? Self.jpeg.prefix(65_000) : Self.jpeg.dropFirst(65_000)
            let fragment = Data([42, 0, 1, UInt8(index), 2]) + body
            send(ARSDKPhotoProtocol.frame(type: 3, id: 125, sequence: UInt8(index), payload: fragment), session: session)
        }
    }

    func sendDroneState(session: Int) {
        queue.async { [weak self] in
            self?.send(ARSDKPhotoProtocol.frame(type: 4, id: 126, sequence: 9,
                payload: Data([0, 5, 1, 0, 73])), session: session)
        }
    }

    func sendNoise(session: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.send(ARSDKPhotoProtocol.frame(type: 2, id: 0, sequence: 8, payload: Data([1])), session: session)
            self.send(ARSDKPhotoProtocol.frame(type: 2, id: 0, sequence: 9, payload: Data(repeating: 7, count: 8)), session: session, fd: self.noiseFD)
            self.send(ARSDKPhotoProtocol.frame(type: 4, id: 126, sequence: 9, payload: Data([0, 5, 1, 0, 73])), session: session, fd: self.noiseFD)
            self.send(Data([2, 0, 1, 40, 0, 0, 0, 1]), session: session)
        }
    }

    private func send(_ data: Data, session: Int, fd: Int32? = nil) {
        guard advertisedPorts.indices.contains(session) else { return }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = advertisedPorts[session].bigEndian
        data.withUnsafeBytes { buffer in
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd ?? udpFD, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
    }
}
