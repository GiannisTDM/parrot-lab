import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private enum VehicleInputMode: Int, CaseIterable {
        case off
        case keyboard
        case gamepad
        case keyboardAndGamepad

        var title: String {
            switch self {
            case .off: return "Off"
            case .keyboard: return "Keyboard"
            case .gamepad: return "Gamepad"
            case .keyboardAndGamepad: return "Keyboard + Gamepad"
            }
        }

        init(keyboardEnabled: Bool, gamepadEnabled: Bool) {
            switch (keyboardEnabled, gamepadEnabled) {
            case (false, false): self = .off
            case (true, false): self = .keyboard
            case (false, true): self = .gamepad
            case (true, true): self = .keyboardAndGamepad
            }
        }

        var enablesKeyboard: Bool { self == .keyboard || self == .keyboardAndGamepad }
        var enablesGamepad: Bool { self == .gamepad || self == .keyboardAndGamepad }
    }

    private var window: NSWindow?
    private var controller: MainViewController?
    private weak var sc2MappingsButton: NSButton?
    private var settingsAirOnlyViews: [NSView] = []
    private weak var miniDroneSettingsNote: NSTextField?
    private weak var flightSettingsTitle: NSTextField?
    private var settingsWindow: NSWindow?
    private var flightMappingsWindow: NSWindow?
    private weak var standaloneBebopCheckbox: NSButton?
    private weak var vehicleInputModePopup: NSPopUpButton?
    private weak var controllerDeadzoneSlider: NSSlider?
    private weak var controllerSensitivitySlider: NSSlider?
    private weak var controllerDeadzoneValue: NSTextField?
    private weak var controllerSensitivityValue: NSTextField?
    private weak var invertPitchCheckbox: NSButton?
    private weak var invertGazCheckbox: NSButton?
    private var keyboardMappingPopups: [FlightControlAction: NSPopUpButton] = [:]
    private var controllerMappingPopups: [FlightControlAction: NSPopUpButton] = [:]
    private var controllerAxisMappingPopups: [FlightControlAction: NSPopUpButton] = [:]
    private weak var developerDiagnosticsCheckbox: NSButton?
    private weak var temporalEnabledCheckbox: NSButton?
    private weak var temporalBidirectionalCheckbox: NSButton?
    private weak var temporalFrameGenerationCheckbox: NSButton?
    private weak var temporalHistorySlider: NSSlider?
    private weak var temporalGhostSlider: NSSlider?
    private weak var temporalConsistencySlider: NSSlider?
    private weak var temporalLatencySlider: NSSlider?
    private weak var temporalFlowResolutionSlider: NSSlider?
    private weak var temporalHistoryValue: NSTextField?
    private weak var temporalGhostValue: NSTextField?
    private weak var temporalConsistencyValue: NSTextField?
    private weak var temporalLatencyValue: NSTextField?
    private weak var temporalFlowResolutionValue: NSTextField?
    private weak var temporalExplanationLabel: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let brandIcon = LabVisualStyle.brandIcon() {
            NSApp.applicationIconImage = brandIcon
        }
        let controller = MainViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.controller = controller
        self.window = window
        controller.onGroundModeChanged = { [weak self] _ in
            self?.refreshForGroundModeChange()
        }
        rebuildToolsMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func installDragonLabOnBebop2(_ sender: Any?) {
        controller?.installDragonLabOnBebop2()
    }

    @objc func performBebopFlatTrim(_ sender: Any?) {
        controller?.performBebopFlatTrim()
    }

    @objc func toggleBebopMagnetometerCalibration(_ sender: Any?) {
        controller?.toggleBebopMagnetometerCalibration()
    }

    @objc func showSettings(_ sender: Any?) {
        let panel = settingsWindow ?? makeSettingsWindow()
        refreshSettingsControls()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeSettingsWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 820),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Parrot Lab Settings"
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = LabVisualStyle.panel

        let scroll = NSScrollView(frame: panel.contentView?.bounds ?? .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let content = LabFlippedBackgroundView(frame: NSRect(x: 0, y: 0, width: 540, height: 1_100))
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        let flightTitle = NSTextField(labelWithString: "Connection and vehicle control")
        flightTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        flightTitle.textColor = .white
        stack.addArrangedSubview(flightTitle)
        flightSettingsTitle = flightTitle
        let bluetoothNote = NSTextField(wrappingLabelWithString:
            "MiniDrone connects over Bluetooth. Choose your inputs and adjust how the sticks respond. Piloting pauses while you edit controls."
        )
        bluetoothNote.font = .systemFont(ofSize: 12)
        bluetoothNote.textColor = LabVisualStyle.mutedText
        bluetoothNote.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.addArrangedSubview(bluetoothNote)
        miniDroneSettingsNote = bluetoothNote

        let standaloneCheckbox = NSButton(
            checkboxWithTitle: "Connect directly to product Wi-Fi (Bebop / Sumo)",
            target: self,
            action: #selector(flightControlSettingChanged(_:))
        )
        standaloneCheckbox.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(standaloneCheckbox)

        let standaloneExplanation = NSTextField(wrappingLabelWithString:
            "Enable for a direct product connection. Disable to route the selected aircraft or Jumping Sumo through SkyController 2."
        )
        standaloneExplanation.font = .systemFont(ofSize: 11.5)
        standaloneExplanation.textColor = LabVisualStyle.mutedText
        standaloneExplanation.maximumNumberOfLines = 2
        standaloneExplanation.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.addArrangedSubview(standaloneExplanation)

        let inputRow = NSStackView()
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 12
        let inputLabel = NSTextField(labelWithString: "Vehicle input")
        inputLabel.font = .systemFont(ofSize: 13, weight: .medium)
        inputLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        inputRow.addArrangedSubview(inputLabel)
        let inputModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for mode in VehicleInputMode.allCases {
            inputModePopup.addItem(withTitle: mode.title)
            inputModePopup.lastItem?.tag = mode.rawValue
        }
        inputModePopup.menu?.autoenablesItems = false
        inputModePopup.target = self
        inputModePopup.action = #selector(flightControlSettingChanged(_:))
        inputModePopup.widthAnchor.constraint(equalToConstant: 250).isActive = true
        inputRow.addArrangedSubview(inputModePopup)
        stack.addArrangedSubview(inputRow)

        let controllerNote = NSTextField(wrappingLabelWithString:
            "Choose keyboard, gamepad, or both. After connecting a gamepad, sweep both sticks fully in every direction and release to center. Each direction learns its range automatically, including while disconnected from the vehicle. Stick limit still caps output."
        )
        controllerNote.font = .systemFont(ofSize: 11.5)
        controllerNote.textColor = LabVisualStyle.mutedText
        controllerNote.maximumNumberOfLines = 5
        controllerNote.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.addArrangedSubview(controllerNote)

        let controllerTuning = NSStackView()
        controllerTuning.orientation = .horizontal
        controllerTuning.spacing = 14
        let deadzoneRow = makeCompactFlightSlider(
            title: "Deadzone",
            minimum: FlightControlConfiguration.controllerDeadzoneRange.lowerBound,
            maximum: FlightControlConfiguration.controllerDeadzoneRange.upperBound,
            action: #selector(flightControlSettingChanged(_:))
        )
        let sensitivityRow = makeCompactFlightSlider(
            title: "Stick limit",
            minimum: FlightControlConfiguration.controllerSensitivityRange.lowerBound,
            maximum: FlightControlConfiguration.controllerSensitivityRange.upperBound,
            action: #selector(flightControlSettingChanged(_:))
        )
        controllerTuning.addArrangedSubview(deadzoneRow.container)
        controllerTuning.addArrangedSubview(sensitivityRow.container)
        stack.addArrangedSubview(controllerTuning)

        let invertRow = NSStackView()
        invertRow.orientation = .horizontal
        invertRow.spacing = 20
        let invertPitch = NSButton(
            checkboxWithTitle: "Invert pitch", target: self,
            action: #selector(flightControlSettingChanged(_:))
        )
        let invertGaz = NSButton(
            checkboxWithTitle: "Invert gaz", target: self,
            action: #selector(flightControlSettingChanged(_:))
        )
        invertRow.addArrangedSubview(invertPitch)
        invertRow.addArrangedSubview(invertGaz)
        let mappingsButton = NSButton(
            title: "Configure mappings…", target: self,
            action: #selector(showFlightControlMappings(_:))
        )
        mappingsButton.bezelStyle = .rounded
        invertRow.addArrangedSubview(mappingsButton)
        stack.addArrangedSubview(invertRow)
        let sc2Mappings = NSButton(title: "Configure SkyController 2 sticks & buttons…", target: self,
                                  action: #selector(showSC2Mappings(_:)))
        stack.addArrangedSubview(sc2Mappings)
        sc2MappingsButton = sc2Mappings

        let flightSeparator = NSBox()
        flightSeparator.boxType = .separator
        flightSeparator.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.addArrangedSubview(flightSeparator)

        let title = NSTextField(labelWithString: "Developer options")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        stack.addArrangedSubview(title)

        let checkbox = NSButton(
            checkboxWithTitle: "Show detailed video diagnostics in the sidebar",
            target: self,
            action: #selector(toggleDeveloperVideoDiagnosticsSetting(_:))
        )
        checkbox.state = controller?.isDeveloperVideoDiagnosticsEnabled == true ? .on : .off
        checkbox.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(checkbox)

        let explanation = NSTextField(wrappingLabelWithString:
            "Keeps the normal Video card concise. Enable this only when inspecting RTP timing, decoder, motion, calibration, and processing details."
        )
        explanation.font = .systemFont(ofSize: 11.5)
        explanation.textColor = LabVisualStyle.mutedText
        explanation.maximumNumberOfLines = 3
        explanation.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.addArrangedSubview(explanation)

        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.addArrangedSubview(separator)

        let temporalTitle = NSTextField(labelWithString: "Experimental temporal reconstruction")
        temporalTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        temporalTitle.textColor = .white
        stack.addArrangedSubview(temporalTitle)

        let temporalExplanation = NSTextField(wrappingLabelWithString:
            "Runs causal IMU-assisted residual optical flow and confidence/occlusion rejection before MetalFX. Requires decoded 1600 × 900; -o metadata enables IMU alignment, otherwise it uses flow only. It is off by default and may reduce live FPS."
        )
        temporalExplanation.font = .systemFont(ofSize: 11.5)
        temporalExplanation.textColor = LabVisualStyle.mutedText
        temporalExplanation.maximumNumberOfLines = 3
        temporalExplanation.widthAnchor.constraint(equalToConstant: 460).isActive = true
        stack.addArrangedSubview(temporalExplanation)
        temporalExplanationLabel = temporalExplanation

        let temporalCheckbox = NSButton(
            checkboxWithTitle: "Enable experimental temporal reconstruction",
            target: self,
            action: #selector(temporalSettingChanged(_:))
        )
        temporalCheckbox.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(temporalCheckbox)

        let bidirectionalCheckbox = NSButton(
            checkboxWithTitle: "Bidirectional flow occlusion check (best ghost rejection)",
            target: self,
            action: #selector(temporalSettingChanged(_:))
        )
        bidirectionalCheckbox.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(bidirectionalCheckbox)

        let frameGenerationCheckbox = NSButton(
            checkboxWithTitle: "Generate one midpoint every two source frames (target 45 FPS)",
            target: self,
            action: #selector(temporalSettingChanged(_:))
        )
        frameGenerationCheckbox.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(frameGenerationCheckbox)

        let flowResolutionRow = makeTemporalSliderRow(
            title: "Residual flow quality ceiling (auto performance governor)",
            minimum: 0.18,
            maximum: 1,
            action: #selector(temporalSettingChanged(_:))
        )
        stack.addArrangedSubview(flowResolutionRow.container)

        let historyRow = makeTemporalSliderRow(
            title: "History strength",
            minimum: 0,
            maximum: 0.85,
            action: #selector(temporalSettingChanged(_:))
        )
        stack.addArrangedSubview(historyRow.container)

        let ghostRow = makeTemporalSliderRow(
            title: "Ghost rejection",
            minimum: 0,
            maximum: 1,
            action: #selector(temporalSettingChanged(_:))
        )
        stack.addArrangedSubview(ghostRow.container)

        let consistencyRow = makeTemporalSliderRow(
            title: "Occlusion consistency threshold",
            minimum: 0.5,
            maximum: 8,
            action: #selector(temporalSettingChanged(_:))
        )
        stack.addArrangedSubview(consistencyRow.container)

        let latencyRow = makeTemporalSliderRow(
            title: "Flow latency budget",
            minimum: 15,
            maximum: 120,
            action: #selector(temporalSettingChanged(_:))
        )
        stack.addArrangedSubview(latencyRow.container)

        scroll.documentView = content
        panel.contentView = scroll
        panel.center()
        settingsWindow = panel
        standaloneBebopCheckbox = standaloneCheckbox
        vehicleInputModePopup = inputModePopup
        controllerDeadzoneSlider = deadzoneRow.slider
        controllerDeadzoneValue = deadzoneRow.value
        controllerSensitivitySlider = sensitivityRow.slider
        controllerSensitivityValue = sensitivityRow.value
        invertPitchCheckbox = invertPitch
        invertGazCheckbox = invertGaz
        developerDiagnosticsCheckbox = checkbox
        temporalEnabledCheckbox = temporalCheckbox
        temporalBidirectionalCheckbox = bidirectionalCheckbox
        temporalFrameGenerationCheckbox = frameGenerationCheckbox
        temporalFlowResolutionSlider = flowResolutionRow.slider
        temporalFlowResolutionValue = flowResolutionRow.value
        temporalHistorySlider = historyRow.slider
        temporalHistoryValue = historyRow.value
        temporalGhostSlider = ghostRow.slider
        temporalGhostValue = ghostRow.value
        temporalConsistencySlider = consistencyRow.slider
        temporalConsistencyValue = consistencyRow.value
        temporalLatencySlider = latencyRow.slider
        temporalLatencyValue = latencyRow.value
        let videoStart = stack.arrangedSubviews.firstIndex(of: flightSeparator)!
        settingsAirOnlyViews = [standaloneCheckbox, standaloneExplanation, sc2Mappings] +
            Array(stack.arrangedSubviews[videoStart...])
        refreshSettingsControls()
        return panel
    }

    @objc func showSC2Mappings(_ sender: Any?) { controller?.showSC2Mappings() }

    @objc private func toggleDeveloperVideoDiagnosticsSetting(_ sender: Any?) {
        guard let checkbox = sender as? NSButton else { return }
        controller?.setDeveloperVideoDiagnosticsEnabled(checkbox.state == .on)
    }

    private func makeTemporalSliderRow(
        title: String,
        minimum: Double,
        maximum: Double,
        action: Selector
    ) -> (container: NSStackView, slider: NSSlider, value: NSTextField) {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 3
        container.widthAnchor.constraint(equalToConstant: 460).isActive = true

        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.alignment = .centerY
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        heading.addArrangedSubview(label)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.addArrangedSubview(spacer)
        let value = NSTextField(labelWithString: "—")
        value.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        value.textColor = LabVisualStyle.accent
        heading.addArrangedSubview(value)
        container.addArrangedSubview(heading)

        let slider = NSSlider(value: minimum, minValue: minimum, maxValue: maximum, target: self, action: action)
        slider.isContinuous = false
        slider.widthAnchor.constraint(equalToConstant: 460).isActive = true
        container.addArrangedSubview(slider)
        return (container, slider, value)
    }

    private func makeCompactFlightSlider(
        title: String,
        minimum: Double,
        maximum: Double,
        action: Selector
    ) -> (container: NSStackView, slider: NSSlider, value: NSTextField) {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 3
        container.widthAnchor.constraint(equalToConstant: 226).isActive = true
        let heading = NSStackView()
        heading.orientation = .horizontal
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        heading.addArrangedSubview(label)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.addArrangedSubview(spacer)
        let value = NSTextField(labelWithString: "—")
        value.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        value.textColor = LabVisualStyle.accent
        heading.addArrangedSubview(value)
        container.addArrangedSubview(heading)
        let slider = NSSlider(value: minimum, minValue: minimum, maxValue: maximum, target: self, action: action)
        slider.isContinuous = false
        slider.widthAnchor.constraint(equalToConstant: 226).isActive = true
        container.addArrangedSubview(slider)
        return (container, slider, value)
    }

    @objc private func flightControlSettingChanged(_ sender: Any?) {
        guard let controller else { return }
        var configuration = controller.currentFlightControlConfiguration
        configuration.standaloneBebopEnabled = standaloneBebopCheckbox?.state == .on
        let inputMode = VehicleInputMode(rawValue: vehicleInputModePopup?.selectedTag() ?? 0) ?? .off
        configuration.keyboardEnabled = inputMode.enablesKeyboard
        configuration.controllerEnabled = inputMode.enablesGamepad
        configuration.controllerDeadzone = controllerDeadzoneSlider?.doubleValue
            ?? configuration.controllerDeadzone
        configuration.controllerSensitivity = controllerSensitivitySlider?.doubleValue
            ?? configuration.controllerSensitivity
        configuration.invertPitch = invertPitchCheckbox?.state == .on
        configuration.invertGaz = invertGazCheckbox?.state == .on
        controller.setFlightControlConfiguration(configuration)
        refreshSettingsControls()
    }

    @objc func showFlightControlMappings(_ sender: Any?) {
        guard let panel = flightMappingsWindow ?? makeFlightControlMappingsWindow() else { return }
        refreshFlightMappingControls()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeFlightControlMappingsWindow() -> NSPanel? {
        guard let controller else { return nil }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = controller.isMiniDroneModeActive ? "MiniDrone mappings" : "Parrot Lab Vehicle Control Mappings"
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = LabVisualStyle.panel

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let document = LabFlippedBackgroundView(frame: NSRect(x: 0, y: 0, width: 630, height: 920))
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        let title = NSTextField(labelWithString: "Keyboard and gamepad actions")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(title)
        let note = NSTextField(wrappingLabelWithString:
            "Choose a key, stick direction or button for each action. Keyboard movement requires the safety-hold key. Piloting pauses while this window is active."
        )
        note.textColor = LabVisualStyle.mutedText
        note.maximumNumberOfLines = 3
        note.widthAnchor.constraint(equalToConstant: 590).isActive = true
        stack.addArrangedSubview(note)

        let headings = NSStackView()
        headings.orientation = .horizontal
        headings.spacing = 10
        for (text, width) in [("Action", 200.0), ("Keyboard", 175.0), ("Gamepad", 195.0)] {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .bold)
            label.textColor = LabVisualStyle.mutedText
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
            headings.addArrangedSubview(label)
        }
        stack.addArrangedSubview(headings)

        keyboardMappingPopups.removeAll()
        controllerMappingPopups.removeAll()
        controllerAxisMappingPopups.removeAll()
        let mappingActions = controller.isMiniDroneModeActive
            ? FlightControlAction.allCases.filter(\.isMiniDroneRelevant)
            : controller.isGroundModeActive
            ? FlightControlAction.allCases.filter(\.isGroundRelevant)
            : FlightControlAction.allCases.filter { $0.jumpingSumoJumpType == nil && !$0.isMiniDroneOnly }
        for action in mappingActions {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            let label = NSTextField(labelWithString: controller.isGroundModeActive ? action.groundTitle : action.title)
            label.widthAnchor.constraint(equalToConstant: 200).isActive = true
            label.textColor = action == .emergency ? .systemRed : .labelColor
            row.addArrangedSubview(label)

            let keyboard = NSPopUpButton(frame: .zero, pullsDown: false)
            for key in FlightKeyboardKey.choices {
                keyboard.addItem(withTitle: key.title)
                keyboard.lastItem?.tag = Int(key.keyCode)
            }
            keyboard.menu?.autoenablesItems = false
            keyboard.target = self
            keyboard.action = #selector(flightMappingChanged(_:))
            keyboard.identifier = NSUserInterfaceItemIdentifier("keyboard.\(action.rawValue)")
            keyboard.widthAnchor.constraint(equalToConstant: 175).isActive = true
            keyboardMappingPopups[action] = keyboard
            row.addArrangedSubview(keyboard)

            if action == .movementEnable {
                let gamepadLabel = NSTextField(labelWithString: "No safety hold required")
                gamepadLabel.font = .systemFont(ofSize: 12, weight: .medium)
                gamepadLabel.textColor = LabVisualStyle.mutedText
                gamepadLabel.alignment = .center
                gamepadLabel.widthAnchor.constraint(equalToConstant: 195).isActive = true
                row.addArrangedSubview(gamepadLabel)
            } else if action.isControllerDirection {
                let gamepad = NSPopUpButton(frame: .zero, pullsDown: false)
                for (index, direction) in FlightControllerAxisDirection.allCases.enumerated() {
                    gamepad.addItem(withTitle: direction.title)
                    gamepad.lastItem?.tag = index
                }
                gamepad.menu?.autoenablesItems = false
                gamepad.target = self
                gamepad.action = #selector(flightMappingChanged(_:))
                gamepad.identifier = NSUserInterfaceItemIdentifier("gamepadAxis.\(action.rawValue)")
                gamepad.widthAnchor.constraint(equalToConstant: 195).isActive = true
                controllerAxisMappingPopups[action] = gamepad
                row.addArrangedSubview(gamepad)
            } else {
                let gamepad = NSPopUpButton(frame: .zero, pullsDown: false)
                for (index, button) in FlightControllerButton.allCases.enumerated() {
                    gamepad.addItem(withTitle: button.title)
                    gamepad.lastItem?.tag = index
                }
                gamepad.menu?.autoenablesItems = false
                gamepad.target = self
                gamepad.action = #selector(flightMappingChanged(_:))
                gamepad.identifier = NSUserInterfaceItemIdentifier("gamepad.\(action.rawValue)")
                gamepad.widthAnchor.constraint(equalToConstant: 195).isActive = true
                controllerMappingPopups[action] = gamepad
                row.addArrangedSubview(gamepad)
            }
            stack.addArrangedSubview(row)
        }

        let reset = NSButton(title: "Restore default mappings", target: self, action: #selector(resetFlightMappings(_:)))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)
        scroll.documentView = document
        panel.contentView = scroll
        panel.minSize = NSSize(width: 650, height: 480)
        panel.center()
        flightMappingsWindow = panel
        refreshFlightMappingControls()
        return panel
    }

    @objc private func flightMappingChanged(_ sender: Any?) {
        guard let popup = sender as? NSPopUpButton,
              let identifier = popup.identifier?.rawValue,
              let actionName = identifier.split(separator: ".").last,
              let action = FlightControlAction(rawValue: String(actionName)),
              let controller else { return }
        var configuration = controller.currentFlightControlConfiguration
        if identifier.hasPrefix("keyboard.") {
            configuration.keyboardKeys[action] = UInt16(clamping: popup.selectedTag())
        } else if identifier.hasPrefix("gamepadAxis."),
                  FlightControllerAxisDirection.allCases.indices.contains(popup.selectedTag()) {
            configuration.bindControllerAxisDirection(
                FlightControllerAxisDirection.allCases[popup.selectedTag()],
                to: action
            )
        } else if identifier.hasPrefix("gamepad."),
                  FlightControllerButton.allCases.indices.contains(popup.selectedTag()) {
            configuration.bindControllerButton(
                FlightControllerButton.allCases[popup.selectedTag()],
                to: action
            )
        }
        controller.setFlightControlConfiguration(configuration)
        refreshFlightMappingControls()
    }

    @objc private func resetFlightMappings(_ sender: Any?) {
        guard let controller else { return }
        var configuration = controller.currentFlightControlConfiguration
        configuration.keyboardKeys = FlightControlConfiguration.defaultKeyboardKeys
        configuration.controllerButtons = FlightControlConfiguration.defaultControllerButtons
        configuration.controllerAxisDirections = FlightControlConfiguration.defaultControllerAxisDirections
        controller.setFlightControlConfiguration(configuration)
        refreshFlightMappingControls()
    }

    private func refreshFlightMappingControls() {
        guard let configuration = controller?.currentFlightControlConfiguration else { return }
        for action in FlightControlAction.allCases {
            keyboardMappingPopups[action]?.selectItem(
                withTag: Int(configuration.keyboardKeys[action] ?? UInt16.max)
            )
            let selected = configuration.controllerButtons[action] ?? .unassigned
            controllerMappingPopups[action]?.selectItem(
                withTag: FlightControllerButton.allCases.firstIndex(of: selected) ?? 0
            )
            let axis = configuration.controllerAxisDirections[action] ?? .unassigned
            controllerAxisMappingPopups[action]?.selectItem(
                withTag: FlightControllerAxisDirection.allCases.firstIndex(of: axis) ?? 0
            )
        }
    }

    @objc private func temporalSettingChanged(_ sender: Any?) {
        guard let controller else { return }
        var configuration = controller.currentTemporalReconstructionConfiguration
        configuration.isEnabled = temporalEnabledCheckbox?.state == .on
        configuration.usesBidirectionalFlow = temporalBidirectionalCheckbox?.state == .on
        configuration.generatesIntermediateFrames = temporalFrameGenerationCheckbox?.state == .on
        configuration.flowResolutionScale = temporalFlowResolutionSlider?.doubleValue
            ?? configuration.flowResolutionScale
        configuration.historyWeight = temporalHistorySlider?.doubleValue ?? configuration.historyWeight
        configuration.ghostRejection = temporalGhostSlider?.doubleValue ?? configuration.ghostRejection
        configuration.consistencyThresholdPixels = temporalConsistencySlider?.doubleValue
            ?? configuration.consistencyThresholdPixels
        configuration.latencyBudgetMilliseconds = temporalLatencySlider?.doubleValue
            ?? configuration.latencyBudgetMilliseconds
        controller.setTemporalReconstructionConfiguration(configuration)
        refreshSettingsControls()
    }

    @objc func toggleGroundTemporal720p45(_ sender: Any?) {
        controller?.toggleGroundTemporal720p45()
        refreshSettingsControls()
    }

    private func refreshSettingsControls() {
        let miniDrone = controller?.isMiniDroneModeActive == true
        settingsAirOnlyViews.forEach { $0.isHidden = miniDrone }
        miniDroneSettingsNote?.isHidden = !miniDrone
        flightSettingsTitle?.stringValue = miniDrone ? "MiniDrone controls" : "Connection and vehicle control"
        settingsWindow?.title = miniDrone ? "MiniDrone controls" : "Parrot Lab Settings"
        let desiredHeight: CGFloat = miniDrone ? 440 : 820
        if settingsWindow?.contentView?.bounds.height != desiredHeight {
            settingsWindow?.setContentSize(NSSize(width: 540, height: desiredHeight))
        }
        sc2MappingsButton?.isHidden = miniDrone
        developerDiagnosticsCheckbox?.state = controller?.isDeveloperVideoDiagnosticsEnabled == true ? .on : .off
        if let flight = controller?.currentFlightControlConfiguration {
            standaloneBebopCheckbox?.state = flight.standaloneBebopEnabled ? .on : .off
            standaloneBebopCheckbox?.isEnabled = controller?.isGroundModeActive != true && controller?.isMiniDroneModeActive != true
            let inputMode = VehicleInputMode(
                keyboardEnabled: flight.keyboardEnabled,
                gamepadEnabled: flight.controllerEnabled
            )
            vehicleInputModePopup?.selectItem(withTag: inputMode.rawValue)
            controllerDeadzoneSlider?.doubleValue = flight.controllerDeadzone
            controllerSensitivitySlider?.doubleValue = flight.controllerSensitivity
            controllerDeadzoneValue?.stringValue = String(format: "%.0f%%", flight.controllerDeadzone * 100)
            controllerSensitivityValue?.stringValue = String(format: "%.0f%%", flight.controllerSensitivity * 100)
            invertPitchCheckbox?.state = flight.invertPitch ? .on : .off
            invertGazCheckbox?.state = flight.invertGaz ? .on : .off
            controllerDeadzoneSlider?.isEnabled = flight.controllerEnabled
            controllerSensitivitySlider?.isEnabled = flight.controllerEnabled
            invertPitchCheckbox?.isEnabled = flight.controllerEnabled
            invertGazCheckbox?.isEnabled = flight.controllerEnabled
        }
        guard let configuration = controller?.currentTemporalReconstructionConfiguration else { return }
        temporalExplanationLabel?.stringValue = configuration.flowOnlyGround
            ? "Sumo: image-only optical flow, lighter history and bidirectional occlusion rejection. Outputs 720p without stretching. 30 FPS input can generate up to 45 FPS. No IMU or aircraft calibration; settings are separate from Bebop."
            : "Bebop: IMU-assisted residual optical flow and confidence/occlusion rejection before MetalFX. Requires 1600 × 900; without motion metadata it uses flow only. Settings are separate from Sumo."
        temporalEnabledCheckbox?.title = configuration.flowOnlyGround
            ? "Enable Sumo 720p optical-flow reconstruction"
            : "Enable experimental temporal reconstruction"
        temporalEnabledCheckbox?.state = configuration.isEnabled ? .on : .off
        temporalBidirectionalCheckbox?.state = configuration.usesBidirectionalFlow ? .on : .off
        temporalFrameGenerationCheckbox?.state = configuration.generatesIntermediateFrames ? .on : .off
        temporalFlowResolutionSlider?.doubleValue = configuration.flowResolutionScale
        temporalHistorySlider?.doubleValue = configuration.historyWeight
        temporalGhostSlider?.doubleValue = configuration.ghostRejection
        temporalConsistencySlider?.doubleValue = configuration.consistencyThresholdPixels
        temporalLatencySlider?.doubleValue = configuration.latencyBudgetMilliseconds
        temporalHistoryValue?.stringValue = String(format: "%.0f%%", configuration.historyWeight * 100)
        temporalGhostValue?.stringValue = String(format: "%.0f%%", configuration.ghostRejection * 100)
        temporalConsistencyValue?.stringValue = String(format: "%.1f px", configuration.consistencyThresholdPixels)
        temporalLatencyValue?.stringValue = String(format: "%.0f ms", configuration.latencyBudgetMilliseconds)
        temporalFlowResolutionValue?.stringValue = String(format: "%.0f%%", configuration.flowResolutionScale * 100)
        let controlsEnabled = configuration.isEnabled
        temporalBidirectionalCheckbox?.isEnabled = controlsEnabled && !configuration.flowOnlyGround
        temporalFrameGenerationCheckbox?.isEnabled = controlsEnabled && configuration.usesBidirectionalFlow
        temporalFlowResolutionSlider?.isEnabled = controlsEnabled
        temporalHistorySlider?.isEnabled = controlsEnabled
        temporalGhostSlider?.isEnabled = controlsEnabled
        temporalConsistencySlider?.isEnabled = controlsEnabled && configuration.usesBidirectionalFlow
        temporalLatencySlider?.isEnabled = controlsEnabled
    }

    private func refreshForGroundModeChange() {
        rebuildToolsMenu()
        if let contentView = settingsWindow?.contentView {
            LabVisualStyle.applyTheme(
                controller?.isMiniDroneModeActive == true ? .miniDrone : (controller?.isGroundModeActive == true ? .ground : .air),
                to: contentView
            )
            settingsWindow?.backgroundColor = LabVisualStyle.panel
        }
        refreshSettingsControls()
        guard let mappings = flightMappingsWindow else { return }
        let wasVisible = mappings.isVisible
        mappings.close()
        flightMappingsWindow = nil
        keyboardMappingPopups.removeAll()
        controllerMappingPopups.removeAll()
        controllerAxisMappingPopups.removeAll()
        if wasVisible { showFlightControlMappings(nil) }
    }

    @objc func enablePersistentTelnetOnBebop2(_ sender: Any?) {
        controller?.enablePersistentTelnetOnBebop2()
    }

    @objc func uploadRFModSuiteToBebop2(_ sender: Any?) {
        controller?.uploadRFModSuiteToBebop2()
    }

    @objc func uploadRFModSuiteToSkyController2(_ sender: Any?) {
        controller?.uploadRFModSuiteToSkyController2()
    }

    @objc func configureRFPowerMod(_ sender: Any?) {
        controller?.configureRFPowerMod()
    }

    @objc func configureSC2RFPowerMod(_ sender: Any?) {
        controller?.configureRFPowerMod(sc2Only: true)
    }

    @objc func uploadSumoRFModSuite(_ sender: Any?) { controller?.uploadSumoRFModSuite() }
    @objc func configureSumoRFPowerMod(_ sender: Any?) { controller?.configureSumoRFPowerMod() }
    @objc func startSumoB29(_ sender: Any?) { controller?.startSumoB29() }

    private func rebuildToolsMenu() {
        guard let menu = NSApp.mainMenu?.item(withTitle: "Tools")?.submenu else { return }
        populateToolsMenu(menu, ground: controller?.isGroundModeActive == true)
    }

    func populateToolsMenu(_ menu: NSMenu, ground: Bool) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        if controller?.isMiniDroneModeActive == true {
            add("Configure MiniDrone Controls…", #selector(showFlightControlMappings(_:)))
            return
        }
        if ground {
            add("Start Sumo 30 FPS Dragon (B29)…", #selector(startSumoB29(_:)))
            add("Upload Sumo RF Lab…", #selector(uploadSumoRFModSuite(_:)))
            add("Enable/Disable Sumo RF Power Mod…", #selector(configureSumoRFPowerMod(_:)))
        } else {
            add("Bebop Flat Trim", #selector(performBebopFlatTrim(_:)))
            add("Start Bebop Magnetometer Calibration", #selector(toggleBebopMagnetometerCalibration(_:)))
            menu.addItem(.separator())
            add("Install/Update Dragon Lab on Bebop 2", #selector(installDragonLabOnBebop2(_:)))
            add("Enable Persistent Telnet on Bebop 2…", #selector(enablePersistentTelnetOnBebop2(_:)))
            add("Upload RF/MOD Suite to Bebop 2", #selector(uploadRFModSuiteToBebop2(_:)))
            add("Enable/Disable Paired Bebop 2 + SC2 RF Power Mod…", #selector(configureRFPowerMod(_:)))
        }
        menu.addItem(.separator())
        add("Upload RF/MOD Suite to SkyController 2", #selector(uploadRFModSuiteToSkyController2(_:)))
        add("Enable/Disable SC2 RF Power Mod…", #selector(configureSC2RFPowerMod(_:)))
        add("Configure SC2 Sticks & Buttons…", #selector(showSC2Mappings(_:)))
        menu.addItem(.separator())
        add("Find SC2 IP through Bebop 2…", #selector(findSC2HostThroughBebop(_:)))
        add("Find SC2 USB Networking IP…", #selector(findSC2USBHost(_:)))
        add("Install/Update SC2 Driver Patch", #selector(installSC2DriverPatch(_:)))
    }

    static func toolsMenuSelfTest() -> Bool {
        let delegate = AppDelegate()
        let menu = NSMenu(title: "Tools")
        for ground in [false, true, false, true] {
            delegate.populateToolsMenu(menu, ground: ground)
            let actions = menu.items.compactMap(\.action)
            guard actions.contains(#selector(startSumoB29(_:))) == ground,
                  actions.contains(#selector(uploadSumoRFModSuite(_:))) == ground,
                  actions.contains(#selector(configureSumoRFPowerMod(_:))) == ground,
                  actions.contains(#selector(performBebopFlatTrim(_:))) == !ground,
                  actions.contains(#selector(installDragonLabOnBebop2(_:))) == !ground,
                  actions.contains(#selector(configureRFPowerMod(_:))) == !ground,
                  actions.contains(#selector(configureSC2RFPowerMod(_:))),
                  actions.contains(#selector(uploadRFModSuiteToSkyController2(_:))),
                  actions.contains(#selector(installSC2DriverPatch(_:))),
                  actions.contains(#selector(findSC2USBHost(_:))),
                  Set(actions.map(NSStringFromSelector)).count == actions.count else { return false }
        }
        return true
    }

    @objc func selectVideoEnhancement(_ sender: Any?) {
        guard let selectedItem = sender as? NSMenuItem,
              controller?.setVideoEnhancement(rawValue: selectedItem.tag) == true else { return }
        if let items = selectedItem.menu?.items {
            for item in items where item.action == #selector(AppDelegate.selectVideoEnhancement(_:)) {
                item.state = item === selectedItem ? .on : .off
            }
        }
    }

    @objc func selectMetalFXSpatialScaling(_ sender: Any?) {
        guard let selectedItem = sender as? NSMenuItem,
              controller?.setMetalFXSpatialScaling(rawValue: selectedItem.tag) == true else { return }
        if let items = selectedItem.menu?.items {
            for item in items where item.action == #selector(AppDelegate.selectMetalFXSpatialScaling(_:)) {
                item.state = item === selectedItem ? .on : .off
            }
        }
    }

    @objc func toggleCalibratedRollingShutter(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let controller else { return }
        let enabled = !controller.isCalibratedRollingShutterEnabled
        guard controller.setCalibratedRollingShutterEnabled(enabled) else { return }
        item.state = controller.isCalibratedRollingShutterEnabled ? .on : .off
    }

    @objc func convertFinishedH264ToMP4(_ sender: Any?) {
        controller?.convertFinishedH264ToMP4()
    }

    @objc func toggleRawH264Archive(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let controller else { return }
        let enabled = !controller.isRawH264ArchiveEnabled
        controller.setRawH264ArchiveEnabled(enabled)
        item.state = controller.isRawH264ArchiveEnabled ? .on : .off
    }

    @objc func installSC2DriverPatch(_ sender: Any?) {
        controller?.installSC2DriverPatch()
    }

    @objc func findSC2HostThroughBebop(_ sender: Any?) {
        controller?.findSC2HostThroughBebop()
    }

    @objc func findSC2USBHost(_ sender: Any?) {
        controller?.findSC2USBHost()
    }

    /// Builds real settings/mapping controls without showing windows or opening Bluetooth.
    static func settingsInteractionSelfTest() -> Bool {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.object(forKey: FlightControlConfiguration.defaultsKey)
        let previousTheme = LabVisualStyle.themeMode
        let delegate = AppDelegate()
        let controller = MainViewController()
        delegate.controller = controller
        _ = controller.view
        controller.enterMiniDroneMode()
        defer {
            controller.prepareForTermination()
            if let saved { UserDefaults.standard.set(saved, forKey: FlightControlConfiguration.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: FlightControlConfiguration.defaultsKey) }
            LabVisualStyle.applyTheme(previousTheme, to: NSView())
        }
        var config = controller.currentFlightControlConfiguration
        config.controllerEnabled = true
        controller.setFlightControlConfiguration(config)
        _ = delegate.makeSettingsWindow()
        guard delegate.makeFlightControlMappingsWindow() != nil,
              let input = delegate.vehicleInputModePopup else { return false }
        for action in [#selector(flightControlSettingChanged(_:)), #selector(flightMappingChanged(_:)),
                       #selector(resetFlightMappings(_:))] {
            guard delegate.validateMenuItem(NSMenuItem(title: "Choice", action: action, keyEquivalent: "")) else { return false }
        }
        guard !delegate.validateMenuItem(NSMenuItem(title: "Device tool", action: #selector(installSC2DriverPatch(_:)), keyEquivalent: "")),
              delegate.settingsAirOnlyViews.allSatisfy(\.isHidden),
              delegate.miniDroneSettingsNote?.isHidden == false else { return false }
        let choices = [input] + Array(delegate.keyboardMappingPopups.values) +
            Array(delegate.controllerMappingPopups.values) + Array(delegate.controllerAxisMappingPopups.values)
        for popup in choices {
            popup.menu?.update()
            guard popup.isEnabled, popup.numberOfItems > 1,
                  popup.itemArray.allSatisfy(\.isEnabled) else { return false }
        }
        for mode in [VehicleInputMode.off, .keyboard, .gamepad, .keyboardAndGamepad] {
            input.selectItem(withTag: mode.rawValue)
            delegate.flightControlSettingChanged(input)
            let changed = controller.currentFlightControlConfiguration
            guard changed.keyboardEnabled == mode.enablesKeyboard,
                  changed.controllerEnabled == mode.enablesGamepad else { return false }
        }
        guard let gamepad = delegate.controllerMappingPopups[.cannonFire],
              let axis = delegate.controllerAxisMappingPopups[.pitchForward],
              let keyboard = delegate.keyboardMappingPopups[.grabberOpen],
              let buttonIndex = FlightControllerButton.allCases.firstIndex(of: .x),
              let axisIndex = FlightControllerAxisDirection.allCases.firstIndex(of: .leftStickUp) else { return false }
        gamepad.selectItem(withTag: buttonIndex)
        delegate.flightMappingChanged(gamepad)
        axis.selectItem(withTag: axisIndex)
        delegate.flightMappingChanged(axis)
        keyboard.selectItem(withTag: 18)
        delegate.flightMappingChanged(keyboard)
        let updated = controller.currentFlightControlConfiguration
        guard updated.controllerButtons[.cannonFire] == .x,
              updated.controllerAxisDirections[.pitchForward] == .leftStickUp,
              updated.keyboardKeys[.grabberOpen] == 18,
              FlightControlConfiguration.load() == updated else { return false }
        delegate.resetFlightMappings(nil)
        return controller.currentFlightControlConfiguration.controllerButtons == FlightControlConfiguration.defaultControllerButtons &&
            MiniDroneViewController.pickerSelfTest()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let controller else { return false }
        let action = menuItem.action
        if controller.isMiniDroneModeActive {
            // AppKit validates popup choices through the control's action too.
            // Configuration actions must remain usable while device tools are hidden.
            return [#selector(showSettings(_:)), #selector(showFlightControlMappings(_:)),
                    #selector(flightControlSettingChanged(_:)), #selector(flightMappingChanged(_:)),
                    #selector(resetFlightMappings(_:))].contains { $0 == action }
        }
        if action == #selector(toggleGroundTemporal720p45(_:)) {
            menuItem.state = controller.isGroundModeActive && controller.currentTemporalReconstructionConfiguration.isEnabled ? .on : .off
            return controller.isGroundModeActive
        }
        if action == #selector(performBebopFlatTrim(_:)) {
            return controller.canUseBebopCalibrationTools
        }
        if action == #selector(toggleBebopMagnetometerCalibration(_:)) {
            menuItem.title = controller.isMagnetometerCalibrationActive
                ? "Stop Bebop Magnetometer Calibration"
                : "Start Bebop Magnetometer Calibration"
            return controller.canUseBebopCalibrationTools
        }
        if action == #selector(installDragonLabOnBebop2(_:)) {
            return controller.aircraftCapabilities.supportsBB2DragonLab
        }
        if action == #selector(enablePersistentTelnetOnBebop2(_:)) {
            return controller.aircraftCapabilities.supportsBB2PersistentTelnetInstall
        }
        if action == #selector(uploadRFModSuiteToBebop2(_:)) ||
            action == #selector(configureRFPowerMod(_:)) {
            return controller.aircraftCapabilities.supportsValidatedRFMod
        }
        if action == #selector(toggleCalibratedRollingShutter(_:)) {
            return controller.aircraftCapabilities.supportsBB2CameraCalibration ||
                controller.isCalibratedRollingShutterEnabled
        }
        if controller.isGroundModeActive {
            if action == #selector(toggleRawH264Archive(_:)) {
                return false
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.prepareForTermination()
    }
}
