import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var sc3RFWindow: SC3RFWindow?
    private var sc3MaintenanceWindow: SC3MaintenanceWindow?
    private var ownerMaintenanceUnlocked = false
    @objc private func showSC3Maintenance(_ sender: Any?) {
        guard ownerMaintenanceUnlocked else { return }
        if sc3MaintenanceWindow == nil {
            let panel = SC3MaintenanceWindow()
            panel.onBegin = { [weak self] in self?.controller?.beginSC3OwnerMaintenance() ?? false }
            panel.onEnd = { [weak self] in self?.controller?.endSC3OwnerMaintenance() }
            sc3MaintenanceWindow = panel
        }
        sc3MaintenanceWindow?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showSC3RFLab(_ sender: Any?) {
        if sc3RFWindow == nil {
            let panel = SC3RFWindow()
            panel.onBeginWrite = { [weak self] in self?.controller?.beginSC3RFWrite() ?? false }
            panel.onEndWrite = { [weak self] in self?.controller?.endSC3RFWrite() }
            sc3RFWindow = panel
        }
        sc3RFWindow?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
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
    private var settingsMiniDroneHiddenViews: [NSView] = []
    private weak var miniDroneSettingsNote: NSTextField?
    private weak var flightSettingsTitle: NSTextField?
    private var settingsWindow: NSWindow?
    private var flightMappingsWindow: NSWindow?
    private weak var advancedVideoDisclosure: LabDisclosureButton?
    private weak var standaloneBebopCheckbox: NSButton?
    private weak var standaloneExplanationLabel: NSTextField?
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
    private weak var developerDiagnosticsExplanation: NSTextField?
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

    // These helpers address native SC2 services or the product's FTP/Telnet
    // endpoints. The SC3 relay forwards only Sumo discovery and ARNetwork.
    private static let relayUnavailableActions: [Selector] = [
        #selector(showSC2Mappings(_:)), #selector(findSC2HostThroughBebop(_:)),
        #selector(findSC2USBHost(_:)), #selector(installSC2DriverPatch(_:)),
        #selector(installDragonLabOnBebop2(_:)), #selector(enablePersistentTelnetOnBebop2(_:)),
        #selector(uploadRFModSuiteToBebop2(_:)), #selector(uploadRFModSuiteToSkyController2(_:)),
        #selector(configureRFPowerMod(_:)), #selector(configureSC2RFPowerMod(_:)),
        #selector(uploadSumoRFModSuite(_:)), #selector(configureSumoRFPowerMod(_:)),
        #selector(startSumoB29(_:)), #selector(installSumoStartupB29(_:)),
        #selector(restoreSumoStartupDragon(_:)), #selector(performBebopFlatTrim(_:)),
        #selector(toggleBebopMagnetometerCalibration(_:))
    ]

    private var deviceToolsAvailable: Bool { controller?.isSumoSC3Selected != true }

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
        controller.onOwnerMaintenanceRequested = { [weak self] in
            guard let self else { return }
            self.ownerMaintenanceUnlocked = true
            self.rebuildToolsMenu()
            self.showSC3Maintenance(nil)
        }
        rebuildToolsMenu()
        if let menu = NSApp.mainMenu { refreshModeMenus(menu) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func installDragonLabOnBebop2(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.installDragonLabOnBebop2()
    }

    @objc func performBebopFlatTrim(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.performBebopFlatTrim()
    }

    @objc func toggleBebopMagnetometerCalibration(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.toggleBebopMagnetometerCalibration()
    }

    @objc func showSettings(_ sender: Any?) {
        let panel = settingsWindow ?? makeSettingsWindow()
        refreshSettingsControls()
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showVideoProcessingSettings(_ sender: Any?) {
        showSettings(sender)
        guard let disclosure = advancedVideoDisclosure else { return }
        if !disclosure.expanded { disclosure.performClick(nil) }
        guard let scroll = settingsWindow?.contentView as? NSScrollView,
              let document = scroll.documentView else { return }
        document.layoutSubtreeIfNeeded()
        let y = max(0, disclosure.convert(disclosure.bounds, to: document).minY - 16)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc func toggleWorkspaceFocus(_ sender: Any?) { controller?.toggleWorkspaceFocus() }

    @objc func toggleMenuDiagnostics(_ sender: Any?) {
        guard let controller else { return }
        controller.setDeveloperVideoDiagnosticsEnabled(!controller.isDeveloperVideoDiagnosticsEnabled)
        refreshSettingsControls()
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
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
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
        standaloneExplanationLabel = standaloneExplanation

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
            checkboxWithTitle: "Show detailed video and connection diagnostics",
            target: self,
            action: #selector(toggleDeveloperVideoDiagnosticsSetting(_:))
        )
        checkbox.state = controller?.isDeveloperVideoDiagnosticsEnabled == true ? .on : .off
        checkbox.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(checkbox)

        let explanation = NSTextField(wrappingLabelWithString:
            "Adds stream details in the sidebar and session transitions in Activity. Tools → Copy Connection Diagnostics gives a current snapshot at any time."
        )
        explanation.font = .systemFont(ofSize: 11.5)
        explanation.textColor = LabVisualStyle.mutedText
        explanation.maximumNumberOfLines = 3
        explanation.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.addArrangedSubview(explanation)
        developerDiagnosticsExplanation = explanation

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
        let temporalStart = stack.arrangedSubviews.firstIndex(of: separator)!
        let advanced = NSStackView(); advanced.orientation = .vertical; advanced.alignment = .leading; advanced.spacing = 10
        for item in Array(stack.arrangedSubviews[temporalStart...]) {
            stack.removeArrangedSubview(item); item.removeFromSuperview(); advanced.addArrangedSubview(item)
        }
        let advancedToggle = LabDisclosureButton(title: "Advanced video processing", views: [advanced])
        advancedVideoDisclosure = advancedToggle
        stack.addArrangedSubview(advancedToggle)
        // Mode changes hide the wrapper, preserving the user's disclosure
        // state instead of unhiding every advanced control during refresh.
        let advancedWrapper = NSStackView(); advancedWrapper.orientation = .vertical; advancedWrapper.alignment = .leading
        advancedWrapper.addArrangedSubview(advanced)
        stack.addArrangedSubview(advancedWrapper)
        settingsMiniDroneHiddenViews = [standaloneCheckbox, standaloneExplanation, sc2Mappings, advancedToggle, advancedWrapper]
        refreshSettingsControls()
        return panel
    }

    @objc func showSC2Mappings(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.showSC2Mappings()
    }
    @objc func copyConnectionDiagnostics(_ sender: Any?) { controller?.copyConnectionDiagnostics() }

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
        // The explicit SC3 relay route has no representation in this legacy
        // direct/SC2 checkbox. Input tuning must not select a different route.
        if !controller.isSumoSC3Selected {
            configuration.standaloneBebopEnabled = standaloneBebopCheckbox?.state == .on
        }
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
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeFlightControlMappingsWindow() -> NSPanel? {
        guard let controller else { return nil }
        let availableHeight = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: min(720, max(420, availableHeight - 80))),
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
            guard let keyCode = FlightKeyboardKey.choices.first(where: { Int($0.keyCode) == popup.selectedTag() })?.keyCode else { return }
            configuration.bindKeyboardKey(keyCode, to: action)
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
        let anafi = controller?.isAnafiModeActive == true
        let sumoRelay = controller?.isSumoSC3Selected == true
        settingsMiniDroneHiddenViews.forEach { $0.isHidden = miniDrone || anafi }
        miniDroneSettingsNote?.isHidden = !miniDrone
        flightSettingsTitle?.stringValue = anafi ? "ANAFI input controls" : miniDrone ? "MiniDrone controls" : "Connection and vehicle control"
        settingsWindow?.title = anafi ? "ANAFI input controls" : miniDrone ? "MiniDrone controls" : "Parrot Lab Settings"
        let desiredHeight: CGFloat = miniDrone || anafi ? 445 : 660
        let availableHeight = (settingsWindow?.screen ?? window?.screen ?? NSScreen.main)?.visibleFrame.height
            ?? (desiredHeight + 80)
        let fittedHeight = min(desiredHeight, max(350, availableHeight - 80))
        if settingsWindow?.contentView?.bounds.height != fittedHeight {
            settingsWindow?.setContentSize(NSSize(width: 540, height: fittedHeight))
        }
        sc2MappingsButton?.isHidden = miniDrone || anafi || sumoRelay
        developerDiagnosticsCheckbox?.title = miniDrone
            ? "Show detailed Bluetooth and connection diagnostics"
            : "Show detailed video and connection diagnostics"
        developerDiagnosticsExplanation?.stringValue = miniDrone
            ? "Shows Bluetooth session and flight-state transitions in Activity. Tools → Copy Connection Diagnostics captures the current command and acknowledgement state."
            : "Adds stream details in the sidebar and session transitions in Activity. Tools → Copy Connection Diagnostics gives a current snapshot at any time."
        developerDiagnosticsCheckbox?.state = controller?.isDeveloperVideoDiagnosticsEnabled == true ? .on : .off
        if let flight = controller?.currentFlightControlConfiguration {
            standaloneBebopCheckbox?.state = !sumoRelay && flight.standaloneBebopEnabled ? .on : .off
            standaloneBebopCheckbox?.title = sumoRelay ? (controller?.isSumoSC3NativeSelected == true ? "Sumo via native SC3 (experimental)" : "Sumo via SC3 USB relay (experimental)") : controller?.isGroundModeActive == true
                ? "Connect directly to Sumo Wi-Fi"
                : "Connect directly to product Wi-Fi (Bebop / Sumo)"
            standaloneExplanationLabel?.stringValue = sumoRelay
                ? "Choose the route in the connection bar. Input settings preserve this route. Native SC3 mappings are separate from Mac mappings."
                : controller?.isGroundModeActive == true
                ? "Connect to Jumping Sumo directly or through SkyController 2. Disconnect before changing routes."
                : "Connect to a Bebop or Sumo directly, or route it through SkyController 2. Disconnect before changing routes."
            standaloneBebopCheckbox?.isEnabled = !miniDrone && !sumoRelay && controller?.canChangeConnectionRoute == true
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
        let editable = controller?.canAdjustVideoProcessing == true
        temporalEnabledCheckbox?.isEnabled = editable
        temporalBidirectionalCheckbox?.isEnabled = editable && controlsEnabled && !configuration.flowOnlyGround
        temporalFrameGenerationCheckbox?.isEnabled = editable && controlsEnabled && configuration.usesBidirectionalFlow
        temporalFlowResolutionSlider?.isEnabled = editable && controlsEnabled
        temporalHistorySlider?.isEnabled = editable && controlsEnabled
        temporalGhostSlider?.isEnabled = editable && controlsEnabled
        temporalConsistencySlider?.isEnabled = editable && controlsEnabled && configuration.usesBidirectionalFlow
        temporalLatencySlider?.isEnabled = editable && controlsEnabled
    }

    private func refreshForGroundModeChange() {
        rebuildToolsMenu()
        if let menu = NSApp.mainMenu { refreshModeMenus(menu) }
        if let contentView = settingsWindow?.contentView {
            LabVisualStyle.applyTheme(
                controller?.isMiniDroneModeActive == true ? .miniDrone : (controller?.isGroundModeActive == true ? .ground : .air),
                to: contentView
            )
            settingsWindow?.backgroundColor = LabVisualStyle.panel
        }
        refreshSettingsControls()
        if let scroll = settingsWindow?.contentView as? NSScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
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
        guard deviceToolsAvailable else { return }
        controller?.enablePersistentTelnetOnBebop2()
    }

    @objc func uploadRFModSuiteToBebop2(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.uploadRFModSuiteToBebop2()
    }

    @objc func uploadRFModSuiteToSkyController2(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.uploadRFModSuiteToSkyController2()
    }

    @objc func configureRFPowerMod(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.configureRFPowerMod()
    }

    @objc func configureSC2RFPowerMod(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.configureRFPowerMod(sc2Only: true)
    }

    @objc private func showSC3SumoMappings(_ sender: Any?) { controller?.showSC3SumoMappings() }
    @objc private func installSC3SumoVideo(_ sender: Any?) { controller?.manageSC3SumoVideo(.install) }
    @objc private func restoreSC3SumoVideo(_ sender: Any?) { controller?.manageSC3SumoVideo(.restore) }
    @objc private func showSC3SumoVideoStatus(_ sender: Any?) { controller?.manageSC3SumoVideo(.status) }

    @objc func uploadSumoRFModSuite(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.uploadSumoRFModSuite()
    }
    @objc func configureSumoRFPowerMod(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.configureSumoRFPowerMod()
    }
    @objc func startSumoB29(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.startSumoB29()
    }
    @objc func installSumoStartupB29(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.replaceSumoStartupDragon(restore: false)
    }
    @objc func restoreSumoStartupDragon(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.replaceSumoStartupDragon(restore: true)
    }

    private func rebuildToolsMenu() {
        guard let menu = NSApp.mainMenu?.item(withTitle: "Tools")?.submenu else { return }
        populateToolsMenu(menu, ground: controller?.isGroundModeActive == true)
    }

    private func refreshModeMenus(_ menu: NSMenu) {
        let specialized = controller?.isMiniDroneModeActive == true || controller?.isAnafiModeActive == true
        let ground = controller?.isGroundModeActive == true
        let items = LabMenuBar.descendants(of: menu)
        items.first { $0.identifier == LabMenuBar.videoID }?.isHidden = specialized
        items.first { $0.identifier == LabMenuBar.motionID }?.isHidden = ground
        items.first { $0.identifier == LabMenuBar.groundMotionID }?.isHidden = !ground
    }

    func populateToolsMenu(_ menu: NSMenu, ground: Bool) {
        menu.removeAllItems()
        let specialized = controller?.isMiniDroneModeActive == true || controller?.isAnafiModeActive == true
        LabMenuBar.command(menu, "Input Settings…", #selector(showSettings(_:)), target: self, symbol: "gamecontroller")
        LabMenuBar.command(menu, "Keyboard & Gamepad Mappings…", #selector(showFlightControlMappings(_:)), target: self)
        LabMenuBar.command(menu, "SkyController 3 RF Lab…", #selector(showSC3RFLab(_:)), target: self, symbol: "antenna.radiowaves.left.and.right")
        if ownerMaintenanceUnlocked {
            LabMenuBar.command(menu, "SkyController 3 Maintenance…", #selector(showSC3Maintenance(_:)), target: self, symbol: "wrench.and.screwdriver")
        }
        if !specialized {
            if ground {
                LabMenuBar.command(menu, "Native SC3 Sumo Mappings…", #selector(showSC3SumoMappings(_:)), target: self)
            }
            LabMenuBar.command(menu, "SkyController 2 Mappings…", #selector(showSC2Mappings(_:)), target: self)
            menu.addItem(.separator())
            if !ground {
                let calibration = LabMenuBar.submenu(menu, "Aircraft Calibration", symbol: "level")
                LabMenuBar.command(calibration, "Flat Trim", #selector(performBebopFlatTrim(_:)), target: self)
                LabMenuBar.command(calibration, "Start Magnetometer Calibration", #selector(toggleBebopMagnetometerCalibration(_:)), target: self)
            }
            let connection = LabMenuBar.submenu(menu, "Connection", symbol: "cable.connector")
            LabMenuBar.command(connection, "Find SC2 via Bebop 2…", #selector(findSC2HostThroughBebop(_:)), target: self)
            LabMenuBar.command(connection, "Find SC2 USB Address…", #selector(findSC2USBHost(_:)), target: self)
            LabMenuBar.command(connection, "Install / Update SC2 Driver Patch…", #selector(installSC2DriverPatch(_:)), target: self)

            let devices = LabMenuBar.submenu(menu, "Device Tools", symbol: "wrench.and.screwdriver")
            let vehicle = LabMenuBar.submenu(devices, ground ? "Jumping Sumo" : "Bebop 2")
            if ground {
                LabMenuBar.command(vehicle, "Start 30 FPS Dragon (B29)…", #selector(startSumoB29(_:)), target: self)
                let startup = LabMenuBar.submenu(vehicle, "Startup Dragon")
                LabMenuBar.command(startup, "Install B29 as Default…", #selector(installSumoStartupB29(_:)), target: self)
                LabMenuBar.command(startup, "Restore Original Dragon…", #selector(restoreSumoStartupDragon(_:)), target: self)
                LabMenuBar.command(vehicle, "Upload RF Lab…", #selector(uploadSumoRFModSuite(_:)), target: self)
                LabMenuBar.command(vehicle, "Configure RF Power Mod…", #selector(configureSumoRFPowerMod(_:)), target: self)
            } else {
                LabMenuBar.command(vehicle, "Install / Update Dragon Lab…", #selector(installDragonLabOnBebop2(_:)), target: self)
                LabMenuBar.command(vehicle, "Enable Persistent Telnet…", #selector(enablePersistentTelnetOnBebop2(_:)), target: self)
                LabMenuBar.command(vehicle, "Upload RF / MOD Suite…", #selector(uploadRFModSuiteToBebop2(_:)), target: self)
                LabMenuBar.command(vehicle, "Configure Paired Bebop + SC2 RF Power…", #selector(configureRFPowerMod(_:)), target: self)
            }
            let sc2 = LabMenuBar.submenu(devices, "SkyController 2")
            LabMenuBar.command(sc2, "Upload RF / MOD Suite…", #selector(uploadRFModSuiteToSkyController2(_:)), target: self)
            LabMenuBar.command(sc2, "Configure RF Power Mod…", #selector(configureSC2RFPowerMod(_:)), target: self)
            if ground {
                let sc3 = LabMenuBar.submenu(devices, "SkyController 3")
                LabMenuBar.command(sc3, "Enable Sumo Video at Startup…", #selector(installSC3SumoVideo(_:)), target: self)
                LabMenuBar.command(sc3, "Restore Startup Without Sumo Video…", #selector(restoreSC3SumoVideo(_:)), target: self)
                LabMenuBar.command(sc3, "Show Sumo Video Status…", #selector(showSC3SumoVideoStatus(_:)), target: self)
            }
        }
        menu.addItem(.separator())
        LabMenuBar.command(menu, "Convert H.264 to MP4…", #selector(convertFinishedH264ToMP4(_:)), target: self, symbol: "film")
        LabMenuBar.command(menu, "Copy Connection Diagnostics", #selector(copyConnectionDiagnostics(_:)), target: self,
                           symbol: "doc.on.clipboard")
        let developer = LabMenuBar.submenu(menu, "Developer", symbol: "ladybug")
        LabMenuBar.command(developer, "Detailed Diagnostics", #selector(toggleMenuDiagnostics(_:)), target: self)
        if !specialized && !ground {
            let raw = LabMenuBar.command(developer, "Archive Original H.264", #selector(toggleRawH264Archive(_:)), target: self)
            raw.toolTip = "Also saves the untouched incoming Bebop stream during future Mac recordings."
        }
    }

    static func toolsMenuSelfTest() -> Bool {
        let delegate = AppDelegate()
        let menu = NSMenu(title: "Tools")
        delegate.showSC3Maintenance(nil)
        guard delegate.sc3MaintenanceWindow == nil, SC3MaintenanceAccess.selfTest() else { return false }
        for unlocked in [false, true] {
        delegate.ownerMaintenanceUnlocked = unlocked
        for ground in [false, true, false, true] {
            delegate.populateToolsMenu(menu, ground: ground)
            let actions = LabMenuBar.descendants(of: menu).filter { $0.submenu == nil }.compactMap(\.action)
            guard actions.contains(#selector(startSumoB29(_:))) == ground,
                  actions.contains(#selector(installSumoStartupB29(_:))) == ground,
                  actions.contains(#selector(restoreSumoStartupDragon(_:))) == ground,
                  actions.contains(#selector(uploadSumoRFModSuite(_:))) == ground,
                  actions.contains(#selector(configureSumoRFPowerMod(_:))) == ground,
                  actions.contains(#selector(performBebopFlatTrim(_:))) == !ground,
                  actions.contains(#selector(installDragonLabOnBebop2(_:))) == !ground,
                  actions.contains(#selector(configureRFPowerMod(_:))) == !ground,
                  actions.contains(#selector(configureSC2RFPowerMod(_:))),
                  actions.contains(#selector(uploadRFModSuiteToSkyController2(_:))),
                  actions.contains(#selector(installSC2DriverPatch(_:))),
                  actions.contains(#selector(findSC2USBHost(_:))),
                  actions.contains(#selector(copyConnectionDiagnostics(_:))),
                  actions.contains(#selector(showSC3RFLab(_:))),
                  actions.contains(#selector(showSC3Maintenance(_:))) == unlocked,
                  Set(actions.map(NSStringFromSelector)).count == actions.count else { return false }
        }
        }
        return LabMenuBar.selfTest(delegate: delegate)
    }

    /// Exercises route-specific AppKit validation without contacting a device.
    static func sc3SumoMenuSelfTest() -> Bool {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.object(forKey: FlightControlConfiguration.defaultsKey)
        let previousTheme = LabVisualStyle.themeMode
        let delegate = AppDelegate()
        let controller = MainViewController()
        delegate.controller = controller
        _ = controller.view
        defer {
            controller.prepareForTermination()
            if let saved { UserDefaults.standard.set(saved, forKey: FlightControlConfiguration.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: FlightControlConfiguration.defaultsKey) }
            LabVisualStyle.applyTheme(previousTheme, to: NSView())
        }
        controller.setSumoSC3RelayForPreview()
        _ = delegate.makeSettingsWindow()
        guard controller.isSumoSC3RelaySelected,
              delegate.sc2MappingsButton?.isHidden == true,
              delegate.standaloneBebopCheckbox?.isEnabled == false,
              delegate.standaloneBebopCheckbox?.title.contains("SC3 USB relay") == true else { return false }
        let menu = NSMenu(title: "Tools")
        delegate.populateToolsMenu(menu, ground: true)
        for action in Self.relayUnavailableActions {
            guard !delegate.validateMenuItem(NSMenuItem(title: "Device tool", action: action, keyEquivalent: "")) else { return false }
        }
        for action in [#selector(installSC3SumoVideo(_:)), #selector(restoreSC3SumoVideo(_:)), #selector(showSC3SumoVideoStatus(_:))] {
            guard !delegate.validateMenuItem(NSMenuItem(title: "SC3 video", action: action, keyEquivalent: "")) else { return false }
        }
        for action in [#selector(showSettings(_:)), #selector(showFlightControlMappings(_:)),
                       #selector(flightControlSettingChanged(_:)), #selector(flightMappingChanged(_:)),
                       #selector(resetFlightMappings(_:)), #selector(convertFinishedH264ToMP4(_:)),
                       #selector(copyConnectionDiagnostics(_:)), #selector(showVideoProcessingSettings(_:)),
                       #selector(toggleGroundTemporal720p45(_:))] {
            guard delegate.validateMenuItem(NSMenuItem(title: "Local tool", action: action, keyEquivalent: "")) else { return false }
        }
        // Even a stale checkbox value must not reroute a generic input edit.
        delegate.standaloneBebopCheckbox?.state = .on
        delegate.vehicleInputModePopup?.selectItem(withTag: VehicleInputMode.keyboardAndGamepad.rawValue)
        delegate.flightControlSettingChanged(delegate.vehicleInputModePopup)
        guard controller.isSumoSC3RelaySelected,
              controller.currentFlightControlConfiguration.keyboardEnabled,
              controller.currentFlightControlConfiguration.controllerEnabled,
              delegate.standaloneBebopCheckbox?.isEnabled == false else { return false }
        controller.setSumoSC3NativeForPreview()
        delegate.refreshSettingsControls()
        let airRoute = controller.currentFlightControlConfiguration.standaloneBebopEnabled
        delegate.standaloneBebopCheckbox?.state = airRoute ? .off : .on
        delegate.flightControlSettingChanged(delegate.vehicleInputModePopup)
        guard controller.isSumoSC3NativeSelected,
              controller.currentFlightControlConfiguration.standaloneBebopEnabled == airRoute,
              delegate.standaloneBebopCheckbox?.isEnabled == false,
              !delegate.deviceToolsAvailable,
              delegate.validateMenuItem(NSMenuItem(title: "Native mappings", action: #selector(showSC3SumoMappings(_:)), keyEquivalent: "")) else { return false }
        for action in [#selector(installSC3SumoVideo(_:)), #selector(restoreSC3SumoVideo(_:)), #selector(showSC3SumoVideoStatus(_:))] {
            guard delegate.validateMenuItem(NSMenuItem(title: "SC3 video", action: action, keyEquivalent: "")) else { return false }
        }
        for action in Self.relayUnavailableActions {
            guard !delegate.validateMenuItem(NSMenuItem(title: "Device tool", action: action, keyEquivalent: "")) else { return false }
        }
        controller.setGroundModeForPreview(true)
        delegate.refreshSettingsControls()
        return !controller.isSumoSC3RelaySelected &&
            delegate.standaloneBebopCheckbox?.isEnabled == true &&
            delegate.sc2MappingsButton?.isHidden == false &&
            delegate.validateMenuItem(NSMenuItem(title: "SC2 mappings", action: #selector(showSC2Mappings(_:)), keyEquivalent: "")) &&
            delegate.validateMenuItem(NSMenuItem(title: "B29", action: #selector(startSumoB29(_:)), keyEquivalent: ""))
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
        guard deviceToolsAvailable else { return }
        controller?.installSC2DriverPatch()
    }

    @objc func findSC2HostThroughBebop(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.findSC2HostThroughBebop()
    }

    @objc func findSC2USBHost(_ sender: Any?) {
        guard deviceToolsAvailable else { return }
        controller?.findSC2USBHost()
    }

    /// Builds real settings/mapping controls without showing windows or opening Bluetooth.
    static func renderSettingsPreview(to path: String, miniDrone: Bool) -> Bool {
        _ = NSApplication.shared
        let previousTheme = LabVisualStyle.themeMode
        let delegate = AppDelegate()
        let controller = MainViewController()
        delegate.controller = controller
        _ = controller.view
        if miniDrone { controller.enterMiniDroneMode() }
        defer {
            controller.prepareForTermination()
            LabVisualStyle.applyTheme(previousTheme, to: NSView())
        }
        let panel = delegate.makeSettingsWindow()
        guard let view = panel.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        return PreviewRenderer.writePNG(of: view, to: path)
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
        defer {
            controller.prepareForTermination()
            if let saved { UserDefaults.standard.set(saved, forKey: FlightControlConfiguration.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: FlightControlConfiguration.defaultsKey) }
            LabVisualStyle.applyTheme(previousTheme, to: NSView())
        }
        controller.setGroundModeForPreview(true)
        _ = delegate.makeSettingsWindow()
        guard delegate.standaloneBebopCheckbox?.isEnabled == true,
              delegate.standaloneBebopCheckbox?.title == "Connect directly to Sumo Wi-Fi" else { return false }
        let groundMenu = LabMenuBar.make(delegate: delegate)
        delegate.refreshModeMenus(groundMenu)
        guard LabMenuBar.descendants(of: groundMenu).first(where: { $0.identifier == LabMenuBar.motionID })?.isHidden == true,
              LabMenuBar.descendants(of: groundMenu).first(where: { $0.identifier == LabMenuBar.groundMotionID })?.isHidden == false,
              groundMenu.item(withTitle: "Video")?.isHidden == false else { return false }
        let focus = groundMenu.item(withTitle: "View")?.submenu?.items.first
        guard let focus, delegate.validateMenuItem(focus), focus.state == .off else { return false }
        delegate.toggleWorkspaceFocus(focus)
        guard delegate.validateMenuItem(focus), focus.state == .on else { return false }
        delegate.toggleWorkspaceFocus(focus)
        let enhancement = NSMenuItem(title: "Denoise", action: #selector(selectVideoEnhancement(_:)), keyEquivalent: "")
        enhancement.tag = VideoEnhancementPreset.denoise.rawValue
        guard controller.setVideoEnhancement(rawValue: enhancement.tag),
              delegate.validateMenuItem(enhancement), enhancement.state == .on else { return false }
        guard let wrapper = delegate.settingsMiniDroneHiddenViews.last as? NSStackView,
              let advanced = wrapper.arrangedSubviews.first,
              let disclosure = delegate.settingsMiniDroneHiddenViews.dropLast().last as? LabDisclosureButton,
              advanced.isHidden else { return false }
        delegate.refreshSettingsControls()
        guard advanced.isHidden else { return false }
        disclosure.performClick(nil)
        guard !advanced.isHidden else { return false }
        delegate.refreshSettingsControls()
        guard !advanced.isHidden else { return false }
        controller.enterMiniDroneMode()
        delegate.refreshSettingsControls()
        var config = controller.currentFlightControlConfiguration
        config.controllerEnabled = true
        controller.setFlightControlConfiguration(config)
        guard delegate.makeFlightControlMappingsWindow() != nil,
              let input = delegate.vehicleInputModePopup else { return false }
        for action in [#selector(flightControlSettingChanged(_:)), #selector(flightMappingChanged(_:)),
                       #selector(resetFlightMappings(_:))] {
            guard delegate.validateMenuItem(NSMenuItem(title: "Choice", action: action, keyEquivalent: "")) else { return false }
        }
        guard !delegate.validateMenuItem(NSMenuItem(title: "Device tool", action: #selector(installSC2DriverPatch(_:)), keyEquivalent: "")),
              !delegate.validateMenuItem(enhancement),
              delegate.settingsMiniDroneHiddenViews.allSatisfy(\.isHidden),
              delegate.miniDroneSettingsNote?.isHidden == false,
              delegate.developerDiagnosticsCheckbox?.isHidden == false,
              delegate.developerDiagnosticsCheckbox?.title.contains("Bluetooth") == true,
              let settingsScroll = delegate.settingsWindow?.contentView as? NSScrollView else { return false }
        settingsScroll.layoutSubtreeIfNeeded()
        guard (settingsScroll.documentView?.frame.height ?? 0) >= settingsScroll.contentView.bounds.height - 1 else { return false }
        let menu = LabMenuBar.make(delegate: delegate)
        delegate.refreshModeMenus(menu)
        let miniTools = menu.item(withTitle: "Tools")?.submenu
        guard menu.item(withTitle: "Video")?.isHidden == true,
              !delegate.validateMenuItem(focus),
              let miniTools,
              let conversion = miniTools.items.first(where: { $0.action == #selector(convertFinishedH264ToMP4(_:)) }),
              delegate.validateMenuItem(conversion),
              !LabMenuBar.descendants(of: miniTools).contains(where: { $0.action == #selector(toggleRawH264Archive(_:)) }),
              LabMenuBar.descendants(of: miniTools).contains(where: { $0.action == #selector(showFlightControlMappings(_:)) }) else { return false }
        delegate.controller = nil
        delegate.refreshModeMenus(menu)
        guard menu.items.allSatisfy({ !$0.isHidden }) else { return false }
        delegate.controller = controller
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
        keyboard.selectItem(withTag: 49)
        delegate.flightMappingChanged(keyboard)
        guard controller.currentFlightControlConfiguration.keyboardKeys[.grabberOpen] == 49,
              controller.currentFlightControlConfiguration.keyboardKeys[.takeOffLand] == UInt16.max else { return false }
        delegate.resetFlightMappings(nil)
        return controller.currentFlightControlConfiguration.controllerButtons == FlightControlConfiguration.defaultControllerButtons &&
            MiniDroneViewController.pickerSelfTest()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let controller else { return false }
        let action = menuItem.action
        if action == #selector(showSC3RFLab(_:)) { return true }
        if action == #selector(showSC3Maintenance(_:)) { return ownerMaintenanceUnlocked }
        if action == #selector(showSC3SumoMappings(_:)) { return controller.isSumoSC3NativeSelected }
        if [#selector(installSC3SumoVideo(_:)), #selector(restoreSC3SumoVideo(_:)), #selector(showSC3SumoVideoStatus(_:))].contains(where: { $0 == action }) {
            return controller.canManageSC3SumoVideo
        }
        if controller.isSumoSC3Selected,
           Self.relayUnavailableActions.contains(where: { $0 == action }) { return false }
        if action == #selector(installSumoStartupB29(_:)) || action == #selector(restoreSumoStartupDragon(_:)) {
            return controller.isGroundModeActive
        }
        if action == #selector(convertFinishedH264ToMP4(_:)) { return true }
        if action == #selector(toggleWorkspaceFocus(_:)) {
            menuItem.state = controller.isWorkspaceFocused ? .on : .off
            return !controller.isMiniDroneModeActive
        }
        if action == #selector(toggleMenuDiagnostics(_:)) {
            menuItem.state = controller.isDeveloperVideoDiagnosticsEnabled ? .on : .off
            return true
        }
        if action == #selector(showVideoProcessingSettings(_:)) {
            return !controller.isMiniDroneModeActive && !controller.isAnafiModeActive
        }
        if controller.isMiniDroneModeActive || controller.isAnafiModeActive {
            // AppKit validates popup choices through the control's action too.
            // Configuration actions must remain usable while device tools are hidden.
            return [#selector(showSettings(_:)), #selector(showFlightControlMappings(_:)),
                    #selector(flightControlSettingChanged(_:)), #selector(flightMappingChanged(_:)),
                    #selector(resetFlightMappings(_:)), #selector(copyConnectionDiagnostics(_:))].contains { $0 == action }
        }
        if action == #selector(selectVideoEnhancement(_:)) {
            guard let preset = VideoEnhancementPreset(rawValue: menuItem.tag) else { return false }
            menuItem.state = controller.currentVideoEnhancement == preset ? .on : .off
            return controller.canAdjustVideoProcessing
        }
        if action == #selector(selectMetalFXSpatialScaling(_:)) {
            guard let mode = VideoSpatialScalingMode(rawValue: menuItem.tag) else { return false }
            menuItem.state = controller.currentSpatialScaling == mode ? .on : .off
            return controller.canAdjustVideoProcessing &&
                (!mode.usesMetalFX || controller.isMetalFXSpatialScalingSupported)
        }
        if action == #selector(toggleRawH264Archive(_:)) {
            menuItem.state = controller.isRawH264ArchiveEnabled ? .on : .off
            return !controller.isGroundModeActive && controller.canAdjustVideoProcessing
        }
        if action == #selector(toggleGroundTemporal720p45(_:)) {
            menuItem.state = controller.isGroundModeActive && controller.currentTemporalReconstructionConfiguration.isEnabled ? .on : .off
            return controller.isGroundModeActive && controller.canAdjustVideoProcessing
        }
        if action == #selector(performBebopFlatTrim(_:)) {
            return controller.canUseBebopCalibrationTools
        }
        if action == #selector(toggleBebopMagnetometerCalibration(_:)) {
            menuItem.title = controller.isMagnetometerCalibrationActive
                ? "Stop Magnetometer Calibration"
                : "Start Magnetometer Calibration"
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
            menuItem.state = controller.isCalibratedRollingShutterEnabled ? .on : .off
            return controller.aircraftCapabilities.supportsBB2CameraCalibration ||
                controller.isCalibratedRollingShutterEnabled
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        sc3MaintenanceWindow?.stopReadOnly()
        sc3RFWindow?.stop()
        controller?.prepareForTermination()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SC3MaintenanceCoordinator.shared.critical else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "SC3 maintenance is still active"
        alert.informativeText = "A storage/reboot phase must not be interrupted. Wait for its checked result or STOP checkpoint; private evidence and locks must be preserved."
        alert.runModal(); return .terminateCancel
    }
}
