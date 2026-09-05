import AppKit
import GameController

enum FlightControlAction: String, CaseIterable, Codable {
    case movementEnable
    case pitchForward
    case pitchBackward
    case rollLeft
    case rollRight
    case yawLeft
    case yawRight
    case gazUp
    case gazDown
    case takeOffLand
    case returnHome
    case cancelReturnHome
    case cameraUp
    case cameraDown
    case cameraLeft
    case cameraRight
    case cameraCenter
    case highJump
    case emergency

    var title: String {
        switch self {
        case .movementEnable: return "Movement safety hold"
        case .pitchForward: return "Pitch forward"
        case .pitchBackward: return "Pitch backward"
        case .rollLeft: return "Roll left"
        case .rollRight: return "Roll right"
        case .yawLeft: return "Yaw left"
        case .yawRight: return "Yaw right"
        case .gazUp: return "Climb"
        case .gazDown: return "Descend"
        case .takeOffLand: return "Take off / land"
        case .returnHome: return "Return home"
        case .cancelReturnHome: return "Cancel return home"
        case .cameraUp: return "Camera up"
        case .cameraDown: return "Camera down"
        case .cameraLeft: return "Camera left"
        case .cameraRight: return "Camera right"
        case .cameraCenter: return "Center camera"
        case .highJump: return "High jump"
        case .emergency: return "Emergency cut-out"
        }
    }

    var groundTitle: String {
        switch self {
        case .movementEnable: return "Movement safety hold"
        case .pitchForward: return "Drive forward"
        case .pitchBackward: return "Drive backward"
        case .rollLeft: return "Turn left"
        case .rollRight: return "Turn right"
        case .highJump: return "High jump"
        case .emergency: return "Stop movement"
        default: return title
        }
    }

    var isGroundRelevant: Bool {
        switch self {
        case .movementEnable, .pitchForward, .pitchBackward, .rollLeft, .rollRight, .highJump, .emergency:
            return true
        default:
            return false
        }
    }

    var isContinuousAxis: Bool {
        switch self {
        case .pitchForward, .pitchBackward, .rollLeft, .rollRight,
             .yawLeft, .yawRight, .gazUp, .gazDown, .movementEnable:
            return true
        default:
            return false
        }
    }

    var isControllerDirection: Bool {
        isContinuousAxis && self != .movementEnable
    }
}

struct FlightKeyboardKey: Hashable {
    let keyCode: UInt16
    let title: String

    static let choices: [FlightKeyboardKey] = [
        .init(keyCode: UInt16.max, title: "Not assigned"),
        .init(keyCode: 56, title: "Left Shift"), .init(keyCode: 60, title: "Right Shift"),
        .init(keyCode: 49, title: "Space"),
        .init(keyCode: 13, title: "W"), .init(keyCode: 1, title: "S"),
        .init(keyCode: 0, title: "A"), .init(keyCode: 2, title: "D"),
        .init(keyCode: 12, title: "Q"), .init(keyCode: 14, title: "E"),
        .init(keyCode: 15, title: "R"), .init(keyCode: 3, title: "F"),
        .init(keyCode: 4, title: "H"), .init(keyCode: 38, title: "J"),
        .init(keyCode: 8, title: "C"), .init(keyCode: 17, title: "T"),
        .init(keyCode: 123, title: "Left Arrow"), .init(keyCode: 124, title: "Right Arrow"),
        .init(keyCode: 125, title: "Down Arrow"), .init(keyCode: 126, title: "Up Arrow"),
        .init(keyCode: 18, title: "1"), .init(keyCode: 19, title: "2"),
        .init(keyCode: 20, title: "3"), .init(keyCode: 21, title: "4"),
        .init(keyCode: 23, title: "5"), .init(keyCode: 22, title: "6"),
        .init(keyCode: 26, title: "7"), .init(keyCode: 28, title: "8"),
        .init(keyCode: 25, title: "9"), .init(keyCode: 29, title: "0")
    ]
}

enum FlightControllerButton: String, CaseIterable, Codable {
    case unassigned
    case a, b, x, y
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case menu, options

    var title: String {
        switch self {
        case .unassigned: return "Not assigned"
        case .a: return "A / Cross"
        case .b: return "B / Circle"
        case .x: return "X / Square"
        case .y: return "Y / Triangle"
        case .leftShoulder: return "Left shoulder"
        case .rightShoulder: return "Right shoulder"
        case .leftTrigger: return "Left trigger"
        case .rightTrigger: return "Right trigger"
        case .dpadUp: return "D-pad up"
        case .dpadDown: return "D-pad down"
        case .dpadLeft: return "D-pad left"
        case .dpadRight: return "D-pad right"
        case .menu: return "Menu"
        case .options: return "Options"
        }
    }
}

/// A positive half-axis which can be assigned to an individual movement
/// direction. Keeping the direction in the binding makes unconventional and
/// accessibility-oriented stick layouts possible without special cases.
enum FlightControllerAxisDirection: String, CaseIterable, Codable {
    case unassigned
    case leftStickLeft, leftStickRight, leftStickUp, leftStickDown
    case rightStickLeft, rightStickRight, rightStickUp, rightStickDown

    var title: String {
        switch self {
        case .unassigned: return "Not assigned"
        case .leftStickLeft: return "Left stick ←"
        case .leftStickRight: return "Left stick →"
        case .leftStickUp: return "Left stick ↑"
        case .leftStickDown: return "Left stick ↓"
        case .rightStickLeft: return "Right stick ←"
        case .rightStickRight: return "Right stick →"
        case .rightStickUp: return "Right stick ↑"
        case .rightStickDown: return "Right stick ↓"
        }
    }

    func magnitude(on gamepad: GCExtendedGamepad) -> Float {
        switch self {
        case .unassigned: return 0
        case .leftStickLeft: return max(0, -gamepad.leftThumbstick.xAxis.value)
        case .leftStickRight: return max(0, gamepad.leftThumbstick.xAxis.value)
        case .leftStickUp: return max(0, gamepad.leftThumbstick.yAxis.value)
        case .leftStickDown: return max(0, -gamepad.leftThumbstick.yAxis.value)
        case .rightStickLeft: return max(0, -gamepad.rightThumbstick.xAxis.value)
        case .rightStickRight: return max(0, gamepad.rightThumbstick.xAxis.value)
        case .rightStickUp: return max(0, gamepad.rightThumbstick.yAxis.value)
        case .rightStickDown: return max(0, -gamepad.rightThumbstick.yAxis.value)
        }
    }
}

struct FlightControlConfiguration: Equatable, Codable {
    var standaloneBebopEnabled = false
    var keyboardEnabled = false
    var controllerEnabled = false
    var controllerDeadzone = 0.12
    var controllerSensitivity = 0.75
    var invertPitch = false
    var invertGaz = false
    var keyboardKeys: [FlightControlAction: UInt16] = Self.defaultKeyboardKeys
    var controllerButtons: [FlightControlAction: FlightControllerButton] = Self.defaultControllerButtons
    var controllerAxisDirections: [FlightControlAction: FlightControllerAxisDirection] = Self.defaultControllerAxisDirections

    static let defaultKeyboardKeys: [FlightControlAction: UInt16] = [
        .movementEnable: 56,
        .pitchForward: 13, .pitchBackward: 1,
        .rollLeft: 0, .rollRight: 2,
        .yawLeft: 12, .yawRight: 14,
        .gazUp: 15, .gazDown: 3,
        .takeOffLand: 49,
        .returnHome: 4, .cancelReturnHome: 38,
        .cameraUp: 126, .cameraDown: 125,
        .cameraLeft: 123, .cameraRight: 124,
        .cameraCenter: 8,
        .highJump: UInt16.max,
        .emergency: UInt16.max
    ]

    static let defaultControllerButtons: [FlightControlAction: FlightControllerButton] = [
        .takeOffLand: .a,
        .returnHome: .y,
        .cancelReturnHome: .b,
        .cameraUp: .dpadUp, .cameraDown: .dpadDown,
        .cameraLeft: .dpadLeft, .cameraRight: .dpadRight,
        .cameraCenter: .rightShoulder,
        .highJump: .unassigned,
        .emergency: .unassigned
    ]

    static let defaultControllerAxisDirections: [FlightControlAction: FlightControllerAxisDirection] = [
        .pitchForward: .rightStickUp, .pitchBackward: .rightStickDown,
        .rollLeft: .rightStickLeft, .rollRight: .rightStickRight,
        .yawLeft: .leftStickLeft, .yawRight: .leftStickRight,
        .gazUp: .leftStickUp, .gazDown: .leftStickDown
    ]

    static let defaultsKey = "ParrotLab.FlightControl.ConfigurationV1"

    static func load() -> FlightControlConfiguration {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var decoded = try? JSONDecoder().decode(FlightControlConfiguration.self, from: data) else {
            return FlightControlConfiguration()
        }
        // ConfigurationV1 predates remappable analogue directions. An empty
        // decoded map is the migration signal for those existing installs.
        if decoded.controllerAxisDirections.isEmpty {
            decoded.controllerAxisDirections = defaultControllerAxisDirections
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// A physical button may trigger only one discrete action. Rebinding it
    /// moves the button instead of leaving two commands on the same press.
    mutating func bindControllerButton(_ button: FlightControllerButton, to action: FlightControlAction) {
        if button != .unassigned {
            for existingAction in FlightControlAction.allCases
                where existingAction != action && controllerButtons[existingAction] == button {
                controllerButtons[existingAction] = .unassigned
            }
        }
        controllerButtons[action] = button
    }

    /// A physical half-axis drives one movement direction. Moving an existing
    /// direction assignment avoids two actions firing from the same gesture.
    mutating func bindControllerAxisDirection(
        _ direction: FlightControllerAxisDirection,
        to action: FlightControlAction
    ) {
        if direction != .unassigned {
            for existingAction in FlightControlAction.allCases
                where existingAction != action && controllerAxisDirections[existingAction] == direction {
                controllerAxisDirections[existingAction] = .unassigned
            }
        }
        controllerAxisDirections[action] = direction
    }

    private enum CodingKeys: String, CodingKey {
        case standaloneBebopEnabled, keyboardEnabled, controllerEnabled
        case controllerDeadzone, controllerSensitivity, invertPitch, invertGaz
        case keyboardKeys, controllerButtons, controllerAxisDirections
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        standaloneBebopEnabled = try values.decodeIfPresent(Bool.self, forKey: .standaloneBebopEnabled) ?? false
        keyboardEnabled = try values.decodeIfPresent(Bool.self, forKey: .keyboardEnabled) ?? false
        controllerEnabled = try values.decodeIfPresent(Bool.self, forKey: .controllerEnabled) ?? false
        controllerDeadzone = try values.decodeIfPresent(Double.self, forKey: .controllerDeadzone) ?? 0.12
        controllerSensitivity = try values.decodeIfPresent(Double.self, forKey: .controllerSensitivity) ?? 0.75
        invertPitch = try values.decodeIfPresent(Bool.self, forKey: .invertPitch) ?? false
        invertGaz = try values.decodeIfPresent(Bool.self, forKey: .invertGaz) ?? false
        keyboardKeys = try values.decodeIfPresent([FlightControlAction: UInt16].self, forKey: .keyboardKeys)
            ?? Self.defaultKeyboardKeys
        controllerButtons = try values.decodeIfPresent(
            [FlightControlAction: FlightControllerButton].self,
            forKey: .controllerButtons
        ) ?? Self.defaultControllerButtons
        controllerAxisDirections = try values.decodeIfPresent(
            [FlightControlAction: FlightControllerAxisDirection].self,
            forKey: .controllerAxisDirections
        ) ?? Self.defaultControllerAxisDirections
    }
}

/// App-focused keyboard and native macOS GameController input. Xbox, PlayStation
/// and MFi pads use Apple's GameController framework; macOS does not expose XInput.
final class FlightInputManager {
    var onPilotingInput: ((BebopPilotingInput) -> Void)?
    var onAction: ((FlightControlAction) -> Void)?
    var onStatus: ((String) -> Void)?

    private(set) var configuration = FlightControlConfiguration.load()
    private var localEventMonitor: Any?
    private var controllerObservers: [NSObjectProtocol] = []
    private var pressedKeys = Set<UInt16>()
    private var pressedControllerActions = Set<FlightControlAction>()
    private var controllerInput = BebopPilotingInput.neutral
    private var controlsAreAvailable = false

    init() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            self?.handleKeyboard(event)
            return event
        }
        let center = NotificationCenter.default
        controllerObservers.append(center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.configure(controller)
        })
        controllerObservers.append(center.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            self?.controllerInput = .neutral
            self?.pressedControllerActions.removeAll()
            self?.emitCombinedInput()
            self?.reportControllerStatus()
        })
        controllerObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.neutralize() })
        controllerObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow,
                  window.contentViewController is MainViewController else { return }
            self?.neutralize()
        })
        GCController.controllers().forEach(configure)
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    deinit {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        controllerObservers.forEach(NotificationCenter.default.removeObserver)
        GCController.stopWirelessControllerDiscovery()
    }

    func apply(_ configuration: FlightControlConfiguration) {
        self.configuration = configuration
        configuration.save()
        if !configuration.keyboardEnabled { pressedKeys.removeAll() }
        if !configuration.controllerEnabled {
            controllerInput = .neutral
            pressedControllerActions.removeAll()
        }
        GCController.controllers().forEach(configure)
        emitCombinedInput()
        reportControllerStatus()
    }

    func setControlsAvailable(_ available: Bool) {
        controlsAreAvailable = available
        if !available { neutralize() }
        reportControllerStatus()
    }

    func reemitInput() {
        emitCombinedInput()
    }

    func neutralize() {
        pressedKeys.removeAll()
        controllerInput = .neutral
        pressedControllerActions.removeAll()
        onPilotingInput?(.neutral)
    }

    private func handleKeyboard(_ event: NSEvent) {
        guard configuration.keyboardEnabled else { return }
        let code = event.keyCode
        if event.type == .flagsChanged {
            let down = event.modifierFlags.contains(.shift)
            for shiftCode in [UInt16(56), UInt16(60)] {
                if down { pressedKeys.insert(shiftCode) } else { pressedKeys.remove(shiftCode) }
            }
        } else if event.type == .keyDown {
            let wasInserted = pressedKeys.insert(code).inserted
            if wasInserted, !event.isARepeat { triggerKeyboardDiscreteAction(for: code) }
        } else if event.type == .keyUp {
            pressedKeys.remove(code)
        }
        emitCombinedInput()
    }

    private func triggerKeyboardDiscreteAction(for keyCode: UInt16) {
        guard controlsAreAvailable, isMainFlightWindowActive, !isEditingText else { return }
        for action in FlightControlAction.allCases where !action.isContinuousAxis {
            if configuration.keyboardKeys[action] == keyCode, keyCode != UInt16.max {
                onAction?(action)
            }
        }
    }

    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    private var isMainFlightWindowActive: Bool {
        NSApp.isActive && NSApp.keyWindow?.contentViewController is MainViewController
    }

    private func keyboardInput() -> BebopPilotingInput {
        guard configuration.keyboardEnabled, controlsAreAvailable,
              isMainFlightWindowActive, !isEditingText,
              let safety = configuration.keyboardKeys[.movementEnable],
              safety != UInt16.max, pressedKeys.contains(safety) else { return .neutral }
        func axis(_ negative: FlightControlAction, _ positive: FlightControlAction) -> Int8 {
            let low = configuration.keyboardKeys[negative].map(pressedKeys.contains) == true
            let high = configuration.keyboardKeys[positive].map(pressedKeys.contains) == true
            if low == high { return 0 }
            return low ? -75 : 75
        }
        return BebopPilotingInput(
            roll: axis(.rollLeft, .rollRight),
            pitch: axis(.pitchBackward, .pitchForward),
            yaw: axis(.yawLeft, .yawRight),
            gaz: axis(.gazDown, .gazUp)
        )
    }

    private func configure(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else {
            reportControllerStatus()
            return
        }
        gamepad.valueChangedHandler = { [weak self, weak gamepad] _, _ in
            guard let self, let gamepad else { return }
            self.read(gamepad)
        }
        reportControllerStatus()
    }

    private func read(_ gamepad: GCExtendedGamepad) {
        guard configuration.controllerEnabled, controlsAreAvailable, isMainFlightWindowActive else {
            controllerInput = .neutral
            emitCombinedInput()
            return
        }
        let deadzone = Float(configuration.controllerDeadzone)
        let sensitivity = Float(configuration.controllerSensitivity)
        func scaledMagnitude(for action: FlightControlAction) -> Float {
            let direction = configuration.controllerAxisDirections[action] ?? .unassigned
            let source = direction.magnitude(on: gamepad)
            guard source > deadzone else { return 0 }
            let normalized = (source - deadzone) / max(0.001, 1 - deadzone)
            return pow(normalized, 1.35) * sensitivity * 100
        }
        func axis(
            negative: FlightControlAction,
            positive: FlightControlAction,
            inverted: Bool = false
        ) -> Int8 {
            let raw = scaledMagnitude(for: positive) - scaledMagnitude(for: negative)
            return Int8(clamping: Int(((inverted ? -raw : raw)).rounded()))
        }
        controllerInput = BebopPilotingInput(
            roll: axis(negative: .rollLeft, positive: .rollRight),
            pitch: axis(
                negative: .pitchBackward,
                positive: .pitchForward,
                inverted: configuration.invertPitch
            ),
            yaw: axis(negative: .yawLeft, positive: .yawRight),
            gaz: axis(negative: .gazDown, positive: .gazUp, inverted: configuration.invertGaz)
        )

        var nowPressed = Set<FlightControlAction>()
        for action in FlightControlAction.allCases where !action.isContinuousAxis {
            guard let binding = configuration.controllerButtons[action], binding != .unassigned,
                  isPressed(binding, on: gamepad) else { continue }
            nowPressed.insert(action)
            if !pressedControllerActions.contains(action) { onAction?(action) }
        }
        pressedControllerActions = nowPressed
        emitCombinedInput()
    }

    private func isPressed(_ button: FlightControllerButton, on gamepad: GCExtendedGamepad) -> Bool {
        switch button {
        case .unassigned: return false
        case .a: return gamepad.buttonA.isPressed
        case .b: return gamepad.buttonB.isPressed
        case .x: return gamepad.buttonX.isPressed
        case .y: return gamepad.buttonY.isPressed
        case .leftShoulder: return gamepad.leftShoulder.isPressed
        case .rightShoulder: return gamepad.rightShoulder.isPressed
        case .leftTrigger: return gamepad.leftTrigger.isPressed
        case .rightTrigger: return gamepad.rightTrigger.isPressed
        case .dpadUp: return gamepad.dpad.up.isPressed
        case .dpadDown: return gamepad.dpad.down.isPressed
        case .dpadLeft: return gamepad.dpad.left.isPressed
        case .dpadRight: return gamepad.dpad.right.isPressed
        case .menu: return gamepad.buttonMenu.isPressed
        case .options: return gamepad.buttonOptions?.isPressed == true
        }
    }

    private func emitCombinedInput() {
        guard controlsAreAvailable else {
            onPilotingInput?(.neutral)
            return
        }
        let keyboard = keyboardInput()
        func combine(_ first: Int8, _ second: Int8) -> Int8 {
            Int8(clamping: Int(first) + Int(second))
        }
        onPilotingInput?(BebopPilotingInput(
            roll: combine(keyboard.roll, controllerInput.roll),
            pitch: combine(keyboard.pitch, controllerInput.pitch),
            yaw: combine(keyboard.yaw, controllerInput.yaw),
            gaz: combine(keyboard.gaz, controllerInput.gaz)
        ))
    }

    private func reportControllerStatus() {
        let connected = GCController.controllers().filter { $0.extendedGamepad != nil }.count
        let state = controlsAreAvailable ? "READY" : "WAITING FOR ARSDK"
        onStatus?("\(state) · \(connected) GAMEPAD\(connected == 1 ? "" : "S")")
    }
}

enum FlightControlSelfTest {
    static func run() -> Bool {
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
}
