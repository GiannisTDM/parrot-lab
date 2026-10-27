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
    case longJump
    case emergency
    case flatTrim
    case grabberOpen
    case grabberClose
    case cannonFire

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
        case .longJump: return "Long jump"
        case .flatTrim: return "Flat trim"
        case .grabberOpen: return "Open grabber"
        case .grabberClose: return "Close grabber"
        case .cannonFire: return "Fire cannon"
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

    var isMiniDroneOnly: Bool {
        [.flatTrim, .grabberOpen, .grabberClose, .cannonFire].contains(self)
    }

    var isMiniDroneRelevant: Bool {
        isContinuousAxis || isMiniDroneOnly || self == .takeOffLand || self == .emergency
    }

    var isGroundRelevant: Bool {
        switch self {
        case .movementEnable, .pitchForward, .pitchBackward, .rollLeft, .rollRight, .highJump, .longJump, .emergency:
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

    var jumpingSumoJumpType: ARSDKPhotoCommand.JumpingSumoJumpType? {
        switch self {
        case .highJump: return .high
        case .longJump: return .long
        default: return nil
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

enum ControllerResponseCurve: Float {
    case standard = 1.35
    case groundSteering = 3

    init(action: FlightControlAction, groundMode: Bool) {
        self = groundMode && (action == .rollLeft || action == .rollRight)
            ? .groundSteering : .standard
    }
}

/// Session-local ranges, keyed by physical direction rather than action. Learn
/// on release so a new endpoint never increases gain during a held gesture.
struct ControllerStickRanges {
    private var peaks: [FlightControllerAxisDirection: Float] = [:]
    private var endpoints: [FlightControllerAxisDirection: Float] = [:]

    mutating func observe(_ source: Float, direction: FlightControllerAxisDirection, deadzone: Float) {
        guard direction != .unassigned, source.isFinite else { return }
        let magnitude = min(1, max(0, source))
        if magnitude > deadzone {
            peaks[direction] = max(peaks[direction] ?? 0, magnitude)
        } else if let peak = peaks.removeValue(forKey: direction), peak >= 0.5 {
            // Ignore drift and small movements. Subsequent sweeps can extend,
            // but never shrink, the learned range for this connection.
            endpoints[direction] = max(endpoints[direction] ?? 0, peak)
        }
    }

    func scaledMagnitude(_ source: Float, direction: FlightControllerAxisDirection,
                         deadzone: Float, limit: Float,
                         response: ControllerResponseCurve = .standard) -> Float {
        guard direction != .unassigned, source.isFinite, source > deadzone else { return 0 }
        let endpoint = endpoints[direction] ?? 1
        let normalized = min(1, max(0, (source - deadzone) / max(0.001, endpoint - deadzone)))
        return pow(normalized, response.rawValue) * min(1, max(0, limit)) * 100
    }

    mutating func cancelGesture() {
        peaks.removeAll()
    }
}

struct FlightControlConfiguration: Equatable, Codable {
    static let controllerDeadzoneRange = 0.0...0.45
    static let controllerSensitivityRange = 0.25...1.0

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
        .longJump: UInt16.max,
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
        .longJump: .unassigned,
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
              let decoded = try? JSONDecoder().decode(FlightControlConfiguration.self, from: data) else {
            return FlightControlConfiguration()
        }
        return decoded
    }

    var clampedControllerTuning: FlightControlConfiguration {
        var result = self
        result.controllerDeadzone = min(Self.controllerDeadzoneRange.upperBound,
                                       max(Self.controllerDeadzoneRange.lowerBound, controllerDeadzone))
        result.controllerSensitivity = min(Self.controllerSensitivityRange.upperBound,
                                          max(Self.controllerSensitivityRange.lowerBound, controllerSensitivity))
        return result
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// Keep one action per physical key, matching button and stick remapping.
    mutating func bindKeyboardKey(_ keyCode: UInt16, to action: FlightControlAction) {
        if keyCode != UInt16.max {
            for existingAction in FlightControlAction.allCases
                where existingAction != action && keyboardKeys[existingAction] == keyCode {
                keyboardKeys[existingAction] = UInt16.max
            }
        }
        keyboardKeys[action] = keyCode
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
        // Add the new action without changing any existing custom bindings.
        if keyboardKeys[.longJump] == nil { keyboardKeys[.longJump] = UInt16.max }
        if controllerButtons[.longJump] == nil { controllerButtons[.longJump] = .unassigned }
        controllerAxisDirections = try values.decodeIfPresent(
            [FlightControlAction: FlightControllerAxisDirection].self,
            forKey: .controllerAxisDirections
        ) ?? Self.defaultControllerAxisDirections
        // ConfigurationV1 predates remappable analogue directions. Migrate
        // here so all decoding paths apply the same defaults as app startup.
        if controllerAxisDirections.isEmpty {
            controllerAxisDirections = Self.defaultControllerAxisDirections
        }
    }
}

/// A conservative admission rule for the unverified SC3 relay trial only.
/// GameController names/categories are identification hints, not evidence that
/// the SC3's physical HID layout has been verified. Generic HID is excluded.
enum FlightGameControllerAdmission {
    static func allows(vendorName: String?, productCategory: String, restricted: Bool) -> Bool {
        guard restricted else { return true }
        func compact(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let vendor = compact(vendorName ?? "")
        let category = compact(productCategory)
        let identity = vendor + category
        guard !["parrot", "skycontroller", "sc3"].contains(where: identity.contains) else { return false }
        let knownCategories = [GCProductCategoryXboxOne, GCProductCategoryDualShock4, GCProductCategoryDualSense]
        if knownCategories.contains(productCategory) { return true }
        return ["xbox", "microsoft", "dualsense", "dualshock", "playstation", "sony", "nintendo",
                "gulikit", "8bitdo", "steelseries", "gamesir", "logitech", "razer", "powera",
                "backbone", "nacon", "hori"].contains(where: vendor.contains)
    }
}

/// App-focused keyboard and native macOS GameController input. Xbox, PlayStation
/// and MFi pads use Apple's GameController framework; macOS does not expose XInput.
final class FlightInputManager {
    var onPilotingInput: ((BebopPilotingInput) -> Void)?
    var onAction: ((FlightControlAction) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Focus/input loss is distinct from an ordinary neutral command. A relay
    /// session can disarm here without recursively reacting to neutralize().
    var onControlLoss: (() -> Void)?

    private(set) var configuration = FlightControlConfiguration.load()
    private(set) var requiresVerifiedExternalGameController = false
    private let inputSourcesInstalled: Bool
    private var localEventMonitor: Any?
    private var controllerObservers: [NSObjectProtocol] = []
    private var pressedKeys = Set<UInt16>()
    private var pressedControllerActions = Set<FlightControlAction>()
    private var controllerInput = BebopPilotingInput.neutral
    private var lastEmittedInput = BebopPilotingInput.neutral
    private var controlsAreAvailable = false
    private var groundMode = false
    private var stickRanges: [ObjectIdentifier: ControllerStickRanges] = [:]

    init(installInputSources: Bool = true) {
        inputSourcesInstalled = installInputSources
        // Deterministic self-tests exercise policy/state without registering
        // event monitors or starting wireless controller discovery.
        guard installInputSources else { return }
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
        ) { [weak self] note in
            if let controller = note.object as? GCController,
               let gamepad = controller.extendedGamepad {
                self?.stickRanges.removeValue(forKey: ObjectIdentifier(gamepad))
            }
            self?.handleControlLoss()
            self?.reportControllerStatus()
        })
        controllerObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleControlLoss() })
        controllerObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow,
                  window.contentViewController is MainViewController else { return }
            self?.handleControlLoss()
        })
        GCController.controllers().forEach(configure)
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    deinit {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        controllerObservers.forEach(NotificationCenter.default.removeObserver)
        if inputSourcesInstalled { GCController.stopWirelessControllerDiscovery() }
    }

    func apply(_ configuration: FlightControlConfiguration) {
        neutralize()
        self.configuration = configuration
        configuration.save()
        if inputSourcesInstalled { GCController.controllers().forEach(configure) }
        emitCombinedInput()
        reportControllerStatus()
    }

    func setGroundMode(_ enabled: Bool) {
        guard groundMode != enabled else { return }
        neutralize()
        groundMode = enabled
    }

    func setControlsAvailable(_ available: Bool) {
        controlsAreAvailable = available
        if !available { neutralize() }
        reportControllerStatus()
    }

    func setRequiresVerifiedExternalGameController(_ required: Bool) {
        guard requiresVerifiedExternalGameController != required else { return }
        neutralize()
        requiresVerifiedExternalGameController = required
        if inputSourcesInstalled { GCController.controllers().forEach(configure) }
        reportControllerStatus()
    }

    func reemitInput() {
        emitCombinedInput()
    }

    func neutralize() {
        for key in Array(stickRanges.keys) { stickRanges[key]?.cancelGesture() }
        pressedKeys.removeAll()
        controllerInput = .neutral
        pressedControllerActions.removeAll()
        lastEmittedInput = .neutral
        onPilotingInput?(.neutral)
    }

    private func handleControlLoss() {
        neutralize()
        onControlLoss?()
    }

    var diagnosticSummary: String {
        let value = lastEmittedInput
        return "input available=\(controlsAreAvailable) axes=\(value.roll),\(value.pitch),\(value.yaw),\(value.gaz) " +
            "keys=\(pressedKeys.count) buttons=\(pressedControllerActions.count) " +
            "external-gamepads-only=\(requiresVerifiedExternalGameController)"
    }
    var hasNeutralOutput: Bool { lastEmittedInput == .neutral }

    /// Availability forces output to zero, so output alone cannot prove a
    /// held stick/button was released before explicitly arming the relay.
    /// These are existing GameController snapshots; no discovery is started.
    var hasNeutralInputsForArming: Bool {
        guard hasNeutralOutput,
              !configuration.keyboardEnabled || pressedKeys.isEmpty,
              !configuration.controllerEnabled || (controllerInput == .neutral && pressedControllerActions.isEmpty) else { return false }
        if configuration.keyboardEnabled, inputSourcesInstalled,
           !Self.boundKeysReleasedForArming(Array(configuration.keyboardKeys.values), isDown: {
               CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
           }) { return false }
        guard configuration.controllerEnabled, inputSourcesInstalled else { return true }
        let directions = Set(configuration.controllerAxisDirections.filter { $0.key.isContinuousAxis }.map(\.value))
        let buttons = Set(configuration.controllerButtons.filter { !$0.key.isContinuousAxis }.map(\.value))
        let deadzone = Float(configuration.controllerDeadzone)
        return GCController.controllers().filter(accepts).allSatisfy { controller in
            guard let gamepad = controller.extendedGamepad else { return true }
            let rawAxes = [gamepad.leftThumbstick.xAxis.value, gamepad.leftThumbstick.yAxis.value,
                           gamepad.rightThumbstick.xAxis.value, gamepad.rightThumbstick.yAxis.value]
            guard rawAxes.allSatisfy(\.isFinite) else { return false }
            return Self.inputsAreNeutralForArming(keysHeld: false,
                axisMagnitudes: directions.map { $0.magnitude(on: gamepad) },
                buttonsHeld: buttons.contains { isPressed($0, on: gamepad) }, deadzone: deadzone)
        }
    }

    static func inputsAreNeutralForArming(keysHeld: Bool, axisMagnitudes: [Float], buttonsHeld: Bool, deadzone: Float) -> Bool {
        !keysHeld && !buttonsHeld && deadzone.isFinite && (0..<1).contains(deadzone) &&
            axisMagnitudes.allSatisfy { $0.isFinite && (0...deadzone).contains($0) }
    }

    static func boundKeysReleasedForArming(_ bindings: [UInt16], isDown: (UInt16) -> Bool) -> Bool {
        var keys = Set(bindings.filter { $0 != UInt16.max })
        // Keyboard events intentionally share the two Shift safety keys.
        if keys.contains(56) || keys.contains(60) { keys.formUnion([56, 60]) }
        return !keys.contains(where: isDown)
    }

    private func handleKeyboard(_ event: NSEvent) {
        guard configuration.keyboardEnabled else { return }
        guard isMainFlightWindowActive, !isEditingText else {
            if !pressedKeys.isEmpty {
                pressedKeys.removeAll()
                emitCombinedInput()
            }
            return
        }
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
        controller.handlerQueue = .main
        guard let gamepad = controller.extendedGamepad else {
            reportControllerStatus()
            return
        }
        gamepad.valueChangedHandler = { [weak self, weak controller, weak gamepad] _, _ in
            guard let self, let controller, let gamepad else { return }
            self.read(gamepad, controller: controller)
        }
        reportControllerStatus()
    }

    private func accepts(_ controller: GCController) -> Bool {
        FlightGameControllerAdmission.allows(vendorName: controller.vendorName,
            productCategory: controller.productCategory, restricted: requiresVerifiedExternalGameController)
    }

    private func read(_ gamepad: GCExtendedGamepad, controller: GCController) {
        // An excluded native HID must neither drive nor clear an accepted
        // external gamepad's current input when it produces an event.
        guard accepts(controller) else { return }
        guard configuration.controllerEnabled, isMainFlightWindowActive else {
            stickRanges[ObjectIdentifier(gamepad)]?.cancelGesture()
            controllerInput = .neutral
            emitCombinedInput()
            return
        }
        let deadzone = Float(configuration.controllerDeadzone)
        let sensitivity = Float(configuration.controllerSensitivity)
        let key = ObjectIdentifier(gamepad)
        var ranges = stickRanges[key] ?? ControllerStickRanges()
        for direction in FlightControllerAxisDirection.allCases {
            ranges.observe(direction.magnitude(on: gamepad), direction: direction, deadzone: deadzone)
        }
        stickRanges[key] = ranges
        // Range learning also works while disconnected from the vehicle.
        guard controlsAreAvailable else {
            controllerInput = .neutral
            emitCombinedInput()
            return
        }
        func scaledMagnitude(for action: FlightControlAction) -> Float {
            let direction = configuration.controllerAxisDirections[action] ?? .unassigned
            return ranges.scaledMagnitude(direction.magnitude(on: gamepad), direction: direction,
                                          deadzone: deadzone, limit: sensitivity,
                                          response: ControllerResponseCurve(action: action, groundMode: groundMode))
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
            lastEmittedInput = .neutral
            onPilotingInput?(.neutral)
            return
        }
        let keyboard = keyboardInput()
        func combine(_ first: Int8, _ second: Int8) -> Int8 {
            Int8(clamping: Int(first) + Int(second))
        }
        let combined = BebopPilotingInput(
            roll: combine(keyboard.roll, controllerInput.roll),
            pitch: combine(keyboard.pitch, controllerInput.pitch),
            yaw: combine(keyboard.yaw, controllerInput.yaw),
            gaz: combine(keyboard.gaz, controllerInput.gaz)
        )
        lastEmittedInput = combined
        onPilotingInput?(combined)
    }

    private func reportControllerStatus() {
        let controllers = inputSourcesInstalled ? GCController.controllers().filter { $0.extendedGamepad != nil } : []
        let connected = controllers.filter(accepts).count
        let state = controlsAreAvailable ? "READY" : "WAITING FOR ARSDK"
        let restriction = requiresVerifiedExternalGameController ? " · SC3 HID UNVERIFIED · \(controllers.count - connected) EXCLUDED" : ""
        onStatus?("\(state) · \(connected) GAMEPAD\(connected == 1 ? "" : "S")\(restriction)")
    }

    static func relayInputSafetySelfTest() -> Bool {
        let manager = FlightInputManager(installInputSources: false)
        var emitted = [BebopPilotingInput]()
        var losses = 0
        var neutralAtLoss = false
        manager.onPilotingInput = { emitted.append($0) }
        manager.onControlLoss = { [weak manager] in
            guard let manager else { return }
            losses += 1
            neutralAtLoss = manager.hasNeutralOutput && manager.pressedKeys.isEmpty &&
                manager.pressedControllerActions.isEmpty && manager.controllerInput == .neutral
        }
        defer { manager.onControlLoss = nil }
        guard !manager.requiresVerifiedExternalGameController else { return false }
        manager.pressedKeys = [49]
        manager.pressedControllerActions = [.highJump]
        manager.controllerInput = BebopPilotingInput(roll: 25, pitch: 30, yaw: 0, gaz: 0)
        manager.lastEmittedInput = manager.controllerInput
        manager.setRequiresVerifiedExternalGameController(true)
        guard manager.requiresVerifiedExternalGameController, manager.hasNeutralOutput,
              manager.controllerInput == .neutral, manager.pressedKeys.isEmpty,
              manager.pressedControllerActions.isEmpty, emitted == [.neutral], losses == 0 else { return false }
        manager.setRequiresVerifiedExternalGameController(true)
        guard emitted.count == 1 else { return false }
        manager.pressedKeys = [56]
        manager.pressedControllerActions = [.longJump]
        manager.controllerInput = BebopPilotingInput(roll: 0, pitch: -30, yaw: 0, gaz: 0)
        manager.lastEmittedInput = manager.controllerInput
        manager.handleControlLoss()
        guard losses == 1, neutralAtLoss, emitted == [.neutral, .neutral] else { return false }
        manager.neutralize()
        manager.setRequiresVerifiedExternalGameController(false)
        manager.onControlLoss = nil
        guard losses == 1, !manager.requiresVerifiedExternalGameController, manager.hasNeutralOutput,
              manager.hasNeutralInputsForArming else { return false }
        manager.configuration.keyboardEnabled = true
        manager.pressedKeys = [56, 13]
        // The emitted output is neutral while unavailable, but Shift+W is
        // still held and must not become movement after arming.
        guard manager.hasNeutralOutput, !manager.hasNeutralInputsForArming else { return false }
        manager.pressedKeys.removeAll()
        manager.configuration.controllerEnabled = true
        manager.pressedControllerActions = [.highJump]
        guard manager.hasNeutralOutput, !manager.hasNeutralInputsForArming else { return false }
        manager.pressedControllerActions.removeAll()
        return manager.hasNeutralInputsForArming
    }
}
