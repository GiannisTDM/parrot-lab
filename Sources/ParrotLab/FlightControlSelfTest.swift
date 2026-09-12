import Foundation

enum FlightControlSelfTest {
    static func run() -> Bool {
        guard stickRangeTest() else { return false }
        guard steeringResponseTest() else { return false }
        guard jumpCommandTest() else { return false }
        guard configurationTest() else { return false }
        let timestamp: UInt32 = 0x7a12_3456
        let payload = ARSDKPhotoCommand.pcmd(
            flag: true, roll: -100, pitch: 100, yaw: -1, gaz: 1,
            timestampAndSequence: timestamp
        )
        guard payload == Data([
            1, 0, 2, 0, 1, 156, 100, 255, 1, 0x56, 0x34, 0x12, 0x7a
        ]),
        ARSDKPhotoCommand.takeOff == Data([1, 0, 1, 0]),
        ARSDKPhotoCommand.landing == Data([1, 0, 3, 0]),
        ARSDKPhotoCommand.emergency == Data([1, 0, 4, 0]),
        ARSDKPhotoCommand.navigateHome(start: true) == Data([1, 0, 5, 0, 1]),
        ARSDKPhotoCommand.cameraOrientation(tilt: -100, pan: 100) == Data([1, 1, 0, 0, 156, 100]),
        JumpingSumoPilotingInput(sharedInput: BebopPilotingInput(
            roll: -55, pitch: 80, yaw: 100, gaz: -100
        )) == JumpingSumoPilotingInput(speed: 80, turn: -55),
        ARSDKPhotoCommand.jumpingSumoPCMD(flag: true, speed: 80, turn: -55) ==
            Data([3, 0, 0, 0, 1, 80, 201]) else {
            return false
        }
        var configuration = FlightControlConfiguration()
        configuration.controllerDeadzone = 0.18
        configuration.bindControllerButton(.a, to: .returnHome)
        configuration.bindControllerAxisDirection(.leftStickUp, to: .pitchForward)
        guard configuration.controllerButtons[.returnHome] == .a,
              configuration.controllerButtons[.takeOffLand] == .unassigned,
              configuration.controllerAxisDirections[.pitchForward] == .leftStickUp,
              configuration.controllerAxisDirections[.gazUp] == .unassigned else {
            return false
        }
        return (try? JSONDecoder().decode(
            FlightControlConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )) == configuration
    }

    private static func configurationTest() -> Bool {
        var configuration = FlightControlConfiguration()
        configuration.keyboardEnabled = true
        configuration.invertPitch = true
        configuration.bindControllerButton(.leftShoulder, to: .highJump)
        configuration.controllerDeadzone = -1
        configuration.controllerSensitivity = 2
        var expected = configuration
        expected.controllerDeadzone = 0
        expected.controllerSensitivity = 1
        guard configuration.clampedControllerTuning == expected else { return false }
        configuration.controllerDeadzone = 1
        configuration.controllerSensitivity = -1
        expected.controllerDeadzone = 0.45
        expected.controllerSensitivity = 0.25
        guard configuration.clampedControllerTuning == expected,
              expected.clampedControllerTuning == expected else { return false }

        // Older profiles with no analogue direction map must migrate without
        // resetting unrelated settings or an existing jump-button binding.
        expected.controllerAxisDirections = [:]
        guard let data = try? JSONEncoder().encode(expected),
              let decoded = try? JSONDecoder().decode(FlightControlConfiguration.self, from: data) else { return false }
        expected.controllerAxisDirections = FlightControlConfiguration.defaultControllerAxisDirections
        return decoded == expected &&
            (try? JSONDecoder().decode(FlightControlConfiguration.self, from: Data("{}".utf8))) ==
                FlightControlConfiguration()
    }

    private static func stickRangeTest() -> Bool {
        var ranges = ControllerStickRanges()
        func output(_ value: Float, _ direction: FlightControllerAxisDirection, limit: Float = 1) -> Float {
            ranges.scaledMagnitude(value, direction: direction, deadzone: 0.12, limit: limit)
        }
        // Different physical endpoints must each reach the selected limit.
        for (direction, peak): (FlightControllerAxisDirection, Float) in [
            (.rightStickUp, 0.80), (.rightStickDown, 0.95),
            (.leftStickLeft, 0.91), (.leftStickRight, 0.91)
        ] {
            let before = output(peak, direction)
            ranges.observe(peak, direction: direction, deadzone: 0.12)
            guard output(peak, direction) == before else { return false }
            ranges.observe(0, direction: direction, deadzone: 0.12)
            guard output(peak, direction) == 100,
                  output(peak, direction, limit: 0.75) == 75,
                  output(0.12, direction) == 0,
                  output(0.3, direction) > 0, output(0.3, direction) < 50,
                  output(1, direction) == 100 else { return false }
        }
        ranges.observe(0.6, direction: .rightStickUp, deadzone: 0.12)
        ranges.observe(0, direction: .rightStickUp, deadzone: 0.12)
        guard output(0.8, .rightStickUp) == 100, output(0.6, .rightStickUp) < 100 else { return false }
        ranges.observe(1, direction: .rightStickUp, deadzone: 0.12)
        ranges.observe(0, direction: .rightStickUp, deadzone: 0.12)
        guard output(0.8, .rightStickUp) < 100, output(0.95, .rightStickDown) == 100 else { return false }
        var fresh = ControllerStickRanges()
        fresh.observe(0.4, direction: .rightStickUp, deadzone: 0.12)
        fresh.observe(0, direction: .rightStickUp, deadzone: 0.12)
        fresh.observe(0.8, direction: .rightStickUp, deadzone: 0.12)
        fresh.cancelGesture()
        fresh.observe(0, direction: .rightStickUp, deadzone: 0.12)
        return fresh.scaledMagnitude(0.8, direction: .rightStickUp, deadzone: 0.12, limit: 1) < 100
            && output(.nan, .rightStickUp) == 0
            && output(1, .unassigned) == 0
    }

    private static func steeringResponseTest() -> Bool {
        // The curve follows the turn action even when mapped to another stick.
        for action in FlightControlAction.allCases {
            let isTurn = action == .rollLeft || action == .rollRight
            guard ControllerResponseCurve(action: action, groundMode: true) ==
                    (isTurn ? .groundSteering : .standard),
                  ControllerResponseCurve(action: action, groundMode: false) == .standard else { return false }
        }
        var ranges = ControllerStickRanges()
        let deadzone: Float = 0.12
        for (direction, endpoint): (FlightControllerAxisDirection, Float) in [
            (.leftStickLeft, 0.91), (.rightStickUp, 0.8)
        ] {
            ranges.observe(endpoint, direction: direction, deadzone: deadzone)
            ranges.observe(0, direction: direction, deadzone: deadzone)
            func turn(_ position: Float, limit: Float = 1) -> Float {
                ranges.scaledMagnitude(deadzone + position * (endpoint - deadzone),
                                       direction: direction, deadzone: deadzone, limit: limit,
                                       response: .groundSteering)
            }
            // Quarter/half/three-quarter usable travel: 1.56%, 12.5%, 42.19%.
            guard abs(turn(0.25) - 1.5625) < 0.001,
                  abs(turn(0.5) - 12.5) < 0.001,
                  abs(turn(0.75) - 42.1875) < 0.001,
                  turn(0) == 0, turn(1) == 100,
                  turn(1, limit: 0.75) == 75 else { return false }
            var previous: Float = 0
            for step in 0...100 {
                let value = turn(Float(step) / 100)
                guard value >= previous, value <= 100 else { return false }
                previous = value
            }
        }
        return true
    }

    private static func jumpCommandTest() -> Bool {
        // Independent byte fixtures from jpsumo.xml and the ARCommands enum
        // encoding specification; the previous five-byte payload must fail.
        for (action, expected): (FlightControlAction, Data) in [
            (.highJump, Data([3, 2, 3, 0, 1, 0, 0, 0])),
            (.longJump, Data([3, 2, 3, 0, 0, 0, 0, 0]))
        ] {
            guard let type = action.jumpingSumoJumpType,
                  action.isGroundRelevant, !action.isContinuousAxis,
                  ARSDKPhotoCommand.jumpingSumoJump(type) == expected,
                  ARSDKPhotoProtocol.frame(type: 4, id: 11, sequence: 7,
                                           payload: ARSDKPhotoCommand.jumpingSumoJump(type)) ==
                    Data([4, 11, 7, 15, 0, 0, 0]) + expected else { return false }
        }
        guard FlightControlAction.takeOffLand.jumpingSumoJumpType == nil else { return false }
        var legacy = FlightControlConfiguration()
        legacy.keyboardKeys[.highJump] = 12
        legacy.bindControllerButton(.leftShoulder, to: .highJump)
        legacy.keyboardKeys.removeValue(forKey: .longJump)
        legacy.controllerButtons.removeValue(forKey: .longJump)
        guard let data = try? JSONEncoder().encode(legacy),
              var migrated = try? JSONDecoder().decode(FlightControlConfiguration.self, from: data),
              migrated.keyboardKeys[.highJump] == 12,
              migrated.controllerButtons[.highJump] == .leftShoulder,
              migrated.keyboardKeys[.longJump] == UInt16.max,
              migrated.controllerButtons[.longJump] == .unassigned else { return false }
        migrated.keyboardKeys[.longJump] = 14
        migrated.bindControllerButton(.leftShoulder, to: .longJump)
        guard migrated.controllerButtons[.highJump] == .unassigned,
              migrated.controllerButtons[.longJump] == .leftShoulder else { return false }
        return (try? JSONDecoder().decode(FlightControlConfiguration.self,
                                         from: JSONEncoder().encode(migrated))) == migrated
    }
}
