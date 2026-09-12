import Foundation

/// Packet and fake-GATT tests: no radio, permission prompt or hardware required.
enum MiniDroneSelfTest {
    static func run() -> Bool {
        let tests: [(String, () -> Bool)] = [
            ("encoding", encoding), ("BLE adapter lifecycle", MiniDroneBLEClient.offlineSelfTest),
            ("control mappings", mappings), ("reliable retry", retry), ("backpressure and FIFO", backpressure),
            ("emergency priority", emergency), ("notifications and sequences", notifications),
            ("telemetry and accessories", telemetry), ("subscription and reconnect reset", reset)
        ]
        for (name, test) in tests where !test() {
            fputs("MiniDrone self-test failed: \(name)\n", stderr)
            return false
        }
        return true
    }

    private static func encoding() -> Bool {
        MiniDroneCommand.flatTrim == Data([2, 0, 0, 0]) &&
        MiniDroneCommand.takeOff == Data([2, 0, 1, 0]) &&
        MiniDroneCommand.landing == Data([2, 0, 3, 0]) &&
        MiniDroneCommand.emergency == Data([2, 0, 4, 0]) &&
        MiniDroneCommand.pcmd(roll: -100, pitch: 100, yaw: -1, gaz: 1, milliseconds: 0x12345678) ==
            Data([2, 0, 2, 0, 1, 156, 100, 255, 1, 0x78, 0x56, 0x34, 0x12]) &&
        MiniDroneCommand.pcmd(roll: 0, pitch: 0, yaw: 127, gaz: -128, milliseconds: 0) ==
            Data([2, 0, 2, 0, 0, 0, 0, 100, 156, 0, 0, 0, 0]) &&
        MiniDroneCommand.grabber(id: 37, close: false) == Data([2, 16, 1, 0, 37, 0, 0, 0, 0]) &&
        MiniDroneCommand.grabber(id: 93, close: true) == Data([2, 16, 1, 0, 93, 1, 0, 0, 0]) &&
        MiniDroneCommand.cannon(id: 254) == Data([2, 16, 2, 0, 254, 0, 0, 0, 0]) &&
        MiniDroneChannel.command.uuid == "9a66fa0b-0800-9191-11e4-012d1540cb8e" &&
        MiniDroneChannel.commandACK.uuid == "9a66fb1b-0800-9191-11e4-012d1540cb8e"
    }

    private static func retry() -> Bool {
        var link = MiniDroneLink()
        var sent: [MiniDroneLink.Write] = []
        guard link.enqueue(MiniDroneCommand.takeOff) else { return false }
        link.tick(now: 0, pcmd: nil) { sent.append($0); return true }
        link.tick(now: 0.149, pcmd: nil) { sent.append($0); return true }
        guard sent.count == 1, sent[0].channel == .command,
              sent[0].data == Data([4, 1, 2, 0, 1, 0]) else { return false }
        for attempt in 1...5 {
            link.tick(now: Double(attempt) * 0.16, pcmd: nil) { sent.append($0); return true }
        }
        guard sent.count == 6, Set(sent.map(\.data)).count == 1, link.failure == nil else { return false }
        link.tick(now: 1, pcmd: nil) { sent.append($0); return true }
        guard link.failure != nil, sent.count == 6 else { return false }

        link = MiniDroneLink()
        link.enqueue(MiniDroneCommand.flatTrim)
        // Unsent, malformed, wrong-channel and wrong-sequence ACKs cannot complete a command.
        _ = link.receive(Data([1, 7, 1]), on: .commandACK)
        guard link.pendingCount == 1 else { return false }
        link.tick(now: 0, pcmd: nil) { _ in true }
        for (bytes, channel): ([UInt8], MiniDroneChannel) in [
            ([1, 0, 1], .emergencyACK), ([1, 0, 2], .commandACK),
            ([2, 0, 1], .commandACK), ([1, 0, 1, 0], .commandACK)
        ] { _ = link.receive(Data(bytes), on: channel) }
        guard link.pendingCount == 1 else { return false }
        _ = link.receive(Data([1, 99, 1]), on: .commandACK)
        link.tick(now: 10, pcmd: nil) { sent.append($0); return true }
        return link.pendingCount == 0 && link.failure == nil && sent.count == 6
    }

    private static func backpressure() -> Bool {
        var link = MiniDroneLink()
        var sent: [MiniDroneLink.Write] = []
        let oldPCMD = MiniDroneCommand.pcmd(roll: 100, pitch: 0, yaw: 0, gaz: 0, milliseconds: 0)
        let neutral = MiniDroneCommand.pcmd(roll: 0, pitch: 0, yaw: 0, gaz: 0, milliseconds: 10)
        link.enqueue(MiniDroneCommand.grabber(id: 42, close: true))
        link.enqueue(MiniDroneCommand.cannon(id: 99))
        for time in [0.0, 1, 2, 3, 4] { link.tick(now: time, pcmd: oldPCMD) { _ in false } }
        guard link.failure == nil else { return false }
        link.tick(now: 5, pcmd: neutral) { sent.append($0); return true }
        guard sent.count == 2, sent[0].channel == .command, sent[0].data[1] == 1,
              Data(sent[0].data.dropFirst(2)) == MiniDroneCommand.grabber(id: 42, close: true),
              sent[1].channel == .piloting, Data(sent[1].data.dropFirst(2)) == neutral else { return false }
        _ = link.receive(Data([1, 1, 1]), on: .commandACK)
        link.tick(now: 5.01, pcmd: nil) { sent.append($0); return true }
        guard sent.count == 3, sent[2].data == Data([4, 2]) + MiniDroneCommand.cannon(id: 99) else { return false }
        for _ in 0..<19 { guard link.enqueue(MiniDroneCommand.flatTrim) else { return false } }
        return !link.enqueue(MiniDroneCommand.flatTrim) &&
            !link.enqueue(Data(repeating: 0, count: 19)) && !link.enqueue(Data())
    }

    private static func emergency() -> Bool {
        var link = MiniDroneLink()
        link.enqueue(MiniDroneCommand.takeOff)
        link.enqueue(MiniDroneCommand.emergency, emergency: true)
        link.enqueue(MiniDroneCommand.emergency, emergency: true)
        var sent: [MiniDroneLink.Write] = []
        for attempt in 0..<30 {
            link.tick(now: Double(attempt) * 0.2, pcmd: nil) { sent.append($0); return true }
        }
        guard link.failure == nil, link.pendingCount == 1, sent.count == 30,
              sent.allSatisfy({ $0.channel == .emergency && $0.data == Data([4, 1, 2, 0, 4, 0]) }) else { return false }
        _ = link.receive(Data([1, 1, 1]), on: .commandACK)
        guard link.pendingCount == 1 else { return false }
        _ = link.receive(Data([1, 1, 1]), on: .emergencyACK)
        return link.pendingCount == 0
    }

    private static func notifications() -> Bool {
        var link = MiniDroneLink()
        let battery = Data([0, 5, 1, 0, 72])
        var sent: [MiniDroneLink.Write] = []
        guard link.receive(Data([4, 254]) + battery, on: .state) == battery,
              link.receive(Data([4, 254]) + battery, on: .state) == nil,
              link.receive(Data([4, 253]) + battery, on: .state) == nil,
              link.receive(Data([4, 255]) + battery, on: .state) == battery,
              link.receive(Data([4, 0]) + battery, on: .state) == battery,
              link.receive(Data([2, 0]) + battery, on: .telemetry) == battery,
              link.receive(Data([1, 1, 0]), on: .state) == nil else { return false }
        link.tick(now: 0, pcmd: nil) { sent.append($0); return true }
        guard sent.count == 5, sent.allSatisfy({ $0.channel == .acknowledge }),
              sent[0].data == Data([1, 1, 254]), sent[1].data == Data([1, 2, 254]),
              sent[4].data == Data([1, 5, 0]) else { return false }
        // Every command channel wraps independently; a late ACK cannot pop a new command.
        link = MiniDroneLink()
        for index in 1...257 {
            link.enqueue(MiniDroneCommand.flatTrim)
            var packet: MiniDroneLink.Write?
            link.tick(now: Double(index), pcmd: nil) { packet = $0; return true }
            guard packet?.data[1] == UInt8(truncatingIfNeeded: index) else { return false }
            _ = link.receive(Data([1, 0, UInt8(truncatingIfNeeded: index)]), on: .commandACK)
        }
        return link.pendingCount == 0
    }

    private static func telemetry() -> Bool {
        var state = MiniDroneTelemetry()
        guard !state.canFireCannon(0), !state.canUseGrabber(0) else { return false }
        state.consume(Data([0, 5, 1, 0, 87]))
        state.consume(Data([2, 3, 1, 0, 2, 0, 0, 0]))
        guard state.battery == 87, state.flightState == .hovering else { return false }
        // Some Mambo firmware pads GATT values and some encodes legacy enums as u8.
        state.consume(Data([0, 5, 1, 0, 63, 0, 0, 0]))
        state.consume(Data([2, 3, 1, 0, 3]))
        guard state.battery == 63, state.flightState == .flying else { return false }
        state.consume(Data([2, 3, 1, 0, 255, 0, 0, 0]))
        guard state.flightState == nil else { return false }
        state.consume(Data([2, 15, 1, 0, 37, 0, 0, 0, 0, 1]))
        state.consume(Data([2, 15, 1, 0, 38, 2, 0, 0, 0, 2]))
        state.consume(Data([2, 15, 2, 0, 93, 0, 0, 0, 0, 3]))
        guard state.canUseGrabber(37), state.canUseGrabber(38), state.canFireCannon(93),
              !state.canFireCannon(37) else { return false }
        state.consume(Data([2, 15, 2, 0, 93, 1, 0, 0, 0, 0]))
        state.consume(Data([2, 15, 1, 0, 37, 1, 0, 0, 0, 0]))
        guard !state.canFireCannon(93), !state.canUseGrabber(37) else { return false }
        state.consume(Data([2, 15, 1, 0, 37, 0, 0, 0, 0, 8]))
        guard state.grabbers[37] == nil, state.grabbers.count == 1 else { return false }
        state.consume(Data([2, 15, 1, 0, 0, 0, 0, 0, 0, 4]))
        state.consume(Data([2, 15, 2, 0, 19, 99, 0, 0, 0, 3]))
        guard state.grabbers.isEmpty, state.cannons.count == 1, !state.canFireCannon(19) else { return false }
        state.consume(Data([2, 15, 2, 0, 21, 0, 3]))
        guard state.canFireCannon(21) else { return false }
        for length in Array(0..<7) + [8, 9] {
            state.consume(Data([2, 15, 2, 0, 99, 0, 0, 0, 0, 3].prefix(length)))
        }
        return state.cannons[99] == nil && state.cannons.count == 1 && state.canFireCannon(21)
    }

    private static func reset() -> Bool {
        var subscriptions = MiniDroneSubscriptions()
        for channel in [MiniDroneChannel.state, .telemetry, .commandACK] {
            subscriptions.subscribed(channel)
            guard !subscriptions.ready else { return false }
        }
        subscriptions.subscribed(.emergencyACK)
        guard subscriptions.ready else { return false }
        subscriptions = MiniDroneSubscriptions()
        guard !subscriptions.ready else { return false }
        var link = MiniDroneLink()
        link.enqueue(MiniDroneCommand.takeOff)
        link.tick(now: 0, pcmd: nil) { _ in true }
        _ = link.receive(Data([4, 99, 0, 5, 1, 0, 80]), on: .state)
        link = MiniDroneLink()
        var writes = 0
        link.tick(now: 10, pcmd: nil) { _ in writes += 1; return true }
        return writes == 0 && link.pendingCount == 0 && link.failure == nil &&
            link.receive(Data([4, 1, 0, 5, 1, 0, 80]), on: .state) != nil
    }

    private static func mappings() -> Bool {
        let actions = FlightControlAction.allCases.filter(\.isMiniDroneRelevant)
        guard actions.contains(.takeOffLand), actions.contains(.emergency),
              actions.contains(.flatTrim), actions.contains(.grabberOpen),
              actions.contains(.grabberClose), actions.contains(.cannonFire),
              !actions.contains(.highJump), !actions.contains(.returnHome),
              !actions.contains(.cameraUp) else { return false }
        var config = FlightControlConfiguration()
        config.bindControllerButton(.x, to: .cannonFire)
        config.keyboardKeys[.grabberOpen] = 18
        guard let data = try? JSONEncoder().encode(config),
              let decoded = try? JSONDecoder().decode(FlightControlConfiguration.self, from: data) else { return false }
        return decoded == config && decoded.controllerButtons[.cannonFire] == .x &&
            decoded.keyboardKeys[.grabberOpen] == 18
    }

}
