import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow?
    private var controller: MainViewController?
    private var settingsWindow: NSWindow?
    private var flightMappingsWindow: NSWindow?
    private weak var standaloneBebopCheckbox: NSButton?
    private weak var keyboardFlightCheckbox: NSButton?
    private weak var controllerFlightCheckbox: NSButton?
    private weak var controllerDeadzoneSlider: NSSlider?
    private weak var controllerSensitivitySlider: NSSlider?
    private weak var controllerDeadzoneValue: NSTextField?
    private weak var controllerSensitivityValue: NSTextField?
    private weak var invertPitchCheckbox: NSButton?
    private weak var invertGazCheckbox: NSButton?
    private var keyboardMappingPopups: [FlightControlAction: NSPopUpButton] = [:]
    private var controllerMappingPopups: [FlightControlAction: NSPopUpButton] = [:]
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
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func installDragonLabOnBebop2(_ sender: Any?) {
        controller?.installDragonLabOnBebop2()
    }

    @objc func showSettings(_ sender: Any?) {
        if let settingsWindow {
            refreshSettingsControls()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 820),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Parrot Lab Settings"
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let scroll = NSScrollView(frame: panel.contentView?.bounds ?? .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let content = LabFlippedBackgroundView(frame: NSRect(x: 0, y: 0, width: 540, height: 1_100))
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
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])

        let flightTitle = NSTextField(labelWithString: "Connection and flight control")
        flightTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        flightTitle.textColor = .white
        stack.addArrangedSubview(flightTitle)

        let standaloneCheckbox = NSButton(
            checkboxWithTitle: "Enable standalone aircraft (Bebop Drone / Bebop 2)",
            target: self,
            action: #selector(flightControlSettingChanged(_:))
        )
        standaloneCheckbox.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(standaloneCheckbox)

        let standaloneExplanation = NSTextField(wrappingLabelWithString:
            "Use while the Mac is joined directly to the aircraft Wi-Fi at 192.168.42.1. Parrot Lab automatically detects BB1 or BB2; this route is mutually exclusive with SkyController routing."
        )
        standaloneExplanation.font = .systemFont(ofSize: 11.5)
        standaloneExplanation.textColor = LabVisualStyle.mutedText
        standaloneExplanation.maximumNumberOfLines = 2
        standaloneExplanation.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.addArrangedSubview(standaloneExplanation)

        let keyboardCheckbox = NSButton(
            checkboxWithTitle: "Enable remappable keyboard flight control",
            target: self,
            action: #selector(flightControlSettingChanged(_:))
        )
        keyboardCheckbox.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(keyboardCheckbox)

        let controllerCheckbox = NSButton(
            checkboxWithTitle: "Enable native gamepad control (Xbox / PlayStation / MFi)",
            target: self,
            action: #selector(flightControlSettingChanged(_:))
        )
        controllerCheckbox.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(controllerCheckbox)

        let controllerNote = NSTextField(wrappingLabelWithString:
            "macOS uses Apple's GameController system rather than XInput. Stick layout matches the SC2: left yaw/gaz, right roll/pitch."
        )
        controllerNote.font = .systemFont(ofSize: 11.5)
        controllerNote.textColor = LabVisualStyle.mutedText
        controllerNote.maximumNumberOfLines = 2
        controllerNote.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.addArrangedSubview(controllerNote)

        let controllerTuning = NSStackView()
        controllerTuning.orientation = .horizontal
        controllerTuning.spacing = 14
        let deadzoneRow = makeCompactFlightSlider(
            title: "Deadzone", minimum: 0, maximum: 0.45,
            action: #selector(flightControlSettingChanged(_:))
        )
        let sensitivityRow = makeCompactFlightSlider(
            title: "Stick limit", minimum: 0.25, maximum: 1,
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
        keyboardFlightCheckbox = keyboardCheckbox
        controllerFlightCheckbox = controllerCheckbox
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
        refreshSettingsControls()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

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
        configuration.keyboardEnabled = keyboardFlightCheckbox?.state == .on
        configuration.controllerEnabled = controllerFlightCheckbox?.state == .on
        configuration.controllerDeadzone = controllerDeadzoneSlider?.doubleValue
            ?? configuration.controllerDeadzone
        configuration.controllerSensitivity = controllerSensitivitySlider?.doubleValue
            ?? configuration.controllerSensitivity
        configuration.invertPitch = invertPitchCheckbox?.state == .on
        configuration.invertGaz = invertGazCheckbox?.state == .on
        controller.setFlightControlConfiguration(configuration)
        refreshSettingsControls()
    }

    @objc private func showFlightControlMappings(_ sender: Any?) {
        if let flightMappingsWindow {
            refreshFlightMappingControls()
            flightMappingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Parrot Lab Flight Control Mappings"
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let document = LabFlippedView(frame: NSRect(x: 0, y: 0, width: 630, height: 920))
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
            "Keyboard movement is active only while its safety-hold key is pressed. Gamepad axes use the SC2 layout. Emergency has no default binding and should remain unassigned unless deliberately configured."
        )
        note.textColor = LabVisualStyle.mutedText
        note.maximumNumberOfLines = 3
        note.widthAnchor.constraint(equalToConstant: 590).isActive = true
        stack.addArrangedSubview(note)

        let headings = NSStackView()
        headings.orientation = .horizontal
        headings.spacing = 10
        for (text, width) in [("Action", 200.0), ("Keyboard", 175.0), ("Gamepad button", 195.0)] {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .bold)
            label.textColor = LabVisualStyle.mutedText
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
            headings.addArrangedSubview(label)
        }
        stack.addArrangedSubview(headings)

        keyboardMappingPopups.removeAll()
        controllerMappingPopups.removeAll()
        for action in FlightControlAction.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            let label = NSTextField(labelWithString: action.title)
            label.widthAnchor.constraint(equalToConstant: 200).isActive = true
            label.textColor = action == .emergency ? .systemRed : .labelColor
            row.addArrangedSubview(label)

            let keyboard = NSPopUpButton(frame: .zero, pullsDown: false)
            for key in FlightKeyboardKey.choices {
                keyboard.addItem(withTitle: key.title)
                keyboard.lastItem?.tag = Int(key.keyCode)
            }
            keyboard.target = self
            keyboard.action = #selector(flightMappingChanged(_:))
            keyboard.identifier = NSUserInterfaceItemIdentifier("keyboard.\(action.rawValue)")
            keyboard.widthAnchor.constraint(equalToConstant: 175).isActive = true
            keyboardMappingPopups[action] = keyboard
            row.addArrangedSubview(keyboard)

            let gamepad = NSPopUpButton(frame: .zero, pullsDown: false)
            for (index, button) in FlightControllerButton.allCases.enumerated() {
                gamepad.addItem(withTitle: button.title)
                gamepad.lastItem?.tag = index
            }
            gamepad.target = self
            gamepad.action = #selector(flightMappingChanged(_:))
            gamepad.identifier = NSUserInterfaceItemIdentifier("gamepad.\(action.rawValue)")
            gamepad.widthAnchor.constraint(equalToConstant: 195).isActive = true
            gamepad.isEnabled = !action.isContinuousAxis
            controllerMappingPopups[action] = gamepad
            row.addArrangedSubview(gamepad)
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
        panel.makeKeyAndOrderFront(nil)
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
        } else if identifier.hasPrefix("gamepad."),
                  FlightControllerButton.allCases.indices.contains(popup.selectedTag()) {
            configuration.controllerButtons[action] = FlightControllerButton.allCases[popup.selectedTag()]
        }
        controller.setFlightControlConfiguration(configuration)
        refreshFlightMappingControls()
    }

    @objc private func resetFlightMappings(_ sender: Any?) {
        guard let controller else { return }
        var configuration = controller.currentFlightControlConfiguration
        configuration.keyboardKeys = FlightControlConfiguration.defaultKeyboardKeys
        configuration.controllerButtons = FlightControlConfiguration.defaultControllerButtons
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

    private func refreshSettingsControls() {
        developerDiagnosticsCheckbox?.state = controller?.isDeveloperVideoDiagnosticsEnabled == true ? .on : .off
        if let flight = controller?.currentFlightControlConfiguration {
            standaloneBebopCheckbox?.state = flight.standaloneBebopEnabled ? .on : .off
            keyboardFlightCheckbox?.state = flight.keyboardEnabled ? .on : .off
            controllerFlightCheckbox?.state = flight.controllerEnabled ? .on : .off
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
        temporalBidirectionalCheckbox?.isEnabled = controlsEnabled
        temporalFrameGenerationCheckbox?.isEnabled = controlsEnabled && configuration.usesBidirectionalFlow
        temporalFlowResolutionSlider?.isEnabled = controlsEnabled
        temporalHistorySlider?.isEnabled = controlsEnabled
        temporalGhostSlider?.isEnabled = controlsEnabled
        temporalConsistencySlider?.isEnabled = controlsEnabled && configuration.usesBidirectionalFlow
        temporalLatencySlider?.isEnabled = controlsEnabled
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let controller else { return false }
        let action = menuItem.action
        if action == #selector(installDragonLabOnBebop2(_:)) {
            return controller.aircraftCapabilities.supportsBB2DragonLab
        }
        if action == #selector(enablePersistentTelnetOnBebop2(_:)) {
            return controller.aircraftCapabilities.supportsBB2PersistentTelnetInstall
        }
        if action == #selector(uploadRFModSuiteToBebop2(_:)) ||
            action == #selector(uploadRFModSuiteToSkyController2(_:)) ||
            action == #selector(configureRFPowerMod(_:)) {
            return controller.aircraftCapabilities.supportsValidatedRFMod
        }
        if action == #selector(toggleCalibratedRollingShutter(_:)) {
            return controller.aircraftCapabilities.supportsBB2CameraCalibration ||
                controller.isCalibratedRollingShutterEnabled
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.prepareForTermination()
    }
}
