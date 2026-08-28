import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var controller: MainViewController?
    private var settingsWindow: NSWindow?
    private weak var developerDiagnosticsCheckbox: NSButton?
    private weak var temporalEnabledCheckbox: NSButton?
    private weak var temporalBidirectionalCheckbox: NSButton?
    private weak var temporalHistorySlider: NSSlider?
    private weak var temporalGhostSlider: NSSlider?
    private weak var temporalConsistencySlider: NSSlider?
    private weak var temporalLatencySlider: NSSlider?
    private weak var temporalHistoryValue: NSTextField?
    private weak var temporalGhostValue: NSTextField?
    private weak var temporalConsistencyValue: NSTextField?
    private weak var temporalLatencyValue: NSTextField?

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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Parrot Lab Settings"
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let content = LabBackgroundView(frame: panel.contentView?.bounds ?? .zero)
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
        explanation.widthAnchor.constraint(equalToConstant: 460).isActive = true
        stack.addArrangedSubview(explanation)

        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 460).isActive = true
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

        panel.contentView = content
        panel.center()
        settingsWindow = panel
        developerDiagnosticsCheckbox = checkbox
        temporalEnabledCheckbox = temporalCheckbox
        temporalBidirectionalCheckbox = bidirectionalCheckbox
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

    @objc private func temporalSettingChanged(_ sender: Any?) {
        guard let controller else { return }
        var configuration = controller.currentTemporalReconstructionConfiguration
        configuration.isEnabled = temporalEnabledCheckbox?.state == .on
        configuration.usesBidirectionalFlow = temporalBidirectionalCheckbox?.state == .on
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
        guard let configuration = controller?.currentTemporalReconstructionConfiguration else { return }
        temporalEnabledCheckbox?.state = configuration.isEnabled ? .on : .off
        temporalBidirectionalCheckbox?.state = configuration.usesBidirectionalFlow ? .on : .off
        temporalHistorySlider?.doubleValue = configuration.historyWeight
        temporalGhostSlider?.doubleValue = configuration.ghostRejection
        temporalConsistencySlider?.doubleValue = configuration.consistencyThresholdPixels
        temporalLatencySlider?.doubleValue = configuration.latencyBudgetMilliseconds
        temporalHistoryValue?.stringValue = String(format: "%.0f%%", configuration.historyWeight * 100)
        temporalGhostValue?.stringValue = String(format: "%.0f%%", configuration.ghostRejection * 100)
        temporalConsistencyValue?.stringValue = String(format: "%.1f px", configuration.consistencyThresholdPixels)
        temporalLatencyValue?.stringValue = String(format: "%.0f ms", configuration.latencyBudgetMilliseconds)
        let controlsEnabled = configuration.isEnabled
        temporalBidirectionalCheckbox?.isEnabled = controlsEnabled
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

    func applicationWillTerminate(_ notification: Notification) {
        controller?.prepareForTermination()
    }
}
