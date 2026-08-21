import AppKit

final class MainViewController: NSViewController {
    private let parser = SC2TelemetryParser()
    private let telnet = TelnetClient()
    private let droneProbeTelnet = TelnetClient()
    private let dragonControlTelnet = TelnetClient()
    private let sc2DriverTelnet = TelnetClient()
    private let restreamProbe = RestreamProbe()
    private let rtpReceiver = RTPH264Receiver()
    private let streamRecorder = H264StreamRecorder()
    private let toolInstaller = BebopToolInstaller()
    private var snapshot = TelemetrySnapshot()
    private var droneProbeTimer: Timer?
    private var telemetryFreshnessTimer: Timer?
    private var lastFlightStateUpdate: Date?
    private var videoRunning = false
    private var videoStatus = "Restream idle"
    private var videoFormatStatus = "FORMAT waiting"
    private var videoMetadataPresence = VideoMetadataPresence()
    private var mediaDirectoryURL = MediaFileNamer.defaultDirectory
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?
    private var pictureWriteInFlight = false
    private let pictureWriteGroup = DispatchGroup()
    private var dragonCommandInFlight = false
    private var dragonCommandConnected = false
    private var dragonCommandSucceeded = false
    private var pendingDragonProfile: DragonVideoProfile?
    private var pendingDragonInstall = false
    private var toolUploadInFlight = false
    private var sc2DriverInstallInFlight = false
    private var sc2DriverTelnetConnected = false
    private var sc2DriverInstallSucceeded = false
    private var pendingSC2DriverHost: String?
    private var dragonRuntimeStatus = "SC2 OFFLINE"

    private static let droneBatteryProbeCommand = #"B=$(ulogcat -d 2>/dev/null | sed -n 's/.*Battery percentage : *\([0-9][0-9]*\).*/\1/p' | tail -n 1); echo __PARROTLAB_DRONE_BATTERY__=${B:-NA}; exit"#
    private static let mediaDirectoryPreferenceKey = "ParrotLabMediaDirectory"

    private let hudView = VideoHUDView(frame: .zero)
    private let hostField = NSTextField(string: "192.168.42.88")
    private let rtpPortField = NSTextField(string: "55004")
    private let connectButton = NSButton(title: "Connect SC2", target: nil, action: nil)
    private let videoModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let videoButton = NSButton(title: "Start video", target: nil, action: nil)
    private let browseMediaButton = NSButton(title: "Browse…", target: nil, action: nil)
    private let recordingButton = NSButton(title: "Record", target: nil, action: nil)
    private let pictureFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pictureButton = NSButton(title: "Picture", target: nil, action: nil)
    private let dragonResolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dragonBitrateSlider = NSSlider(value: 8_000, minValue: 1_000, maxValue: 16_000, target: nil, action: nil)
    private let dragonBitrateValue = NSTextField(labelWithString: "8.0 Mbps")
    private let dragonLockRateButton = NSButton(checkboxWithTitle: "Lock bitrate", target: nil, action: nil)
    private let dragonApplyButton = NSButton(title: "Apply profile", target: nil, action: nil)
    private let dragonRestoreButton = NSButton(title: "Restore stock", target: nil, action: nil)
    private let dragonStatusLabel = NSTextField(labelWithString: "SC2 OFFLINE")
    private let statusLabel = NSTextField(labelWithString: "DISCONNECTED")
    private let rfLabel = NSTextField(labelWithString: "Waiting for RF telemetry")
    private let flightLabel = NSTextField(labelWithString: "Waiting for flight telemetry")
    private let healthLabel = NSTextField(labelWithString: "Waiting for controller health")
    private let videoLabel = NSTextField(labelWithString: "Restream idle")
    private let console = NSTextView(frame: .zero)

    override func loadView() {
        if let savedPath = UserDefaults.standard.string(forKey: Self.mediaDirectoryPreferenceKey),
           !savedPath.isEmpty {
            mediaDirectoryURL = URL(fileURLWithPath: savedPath, isDirectory: true)
        }
        view = LabBackgroundView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        view.appearance = NSAppearance(named: .darkAqua)
        buildInterface()
        wireDataSources()
        updateInterface()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.title = "Parrot Lab — Bebop 2 / SkyController 2"
        view.window?.minSize = NSSize(width: 1180, height: 720)
    }

    private func buildInterface() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        root.addArrangedSubview(buildToolbar())

        let center = NSStackView()
        center.orientation = .horizontal
        center.spacing = 12
        center.distribution = .fill
        hudView.translatesAutoresizingMaskIntoConstraints = false
        hudView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        center.addArrangedSubview(hudView)
        let sidebar = buildSidebar()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.widthAnchor.constraint(equalToConstant: 312).isActive = true
        center.addArrangedSubview(sidebar)
        root.addArrangedSubview(center)
        root.addArrangedSubview(buildConsolePanel())

        center.setContentHuggingPriority(.defaultLow, for: .vertical)
        center.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func buildToolbar() -> NSView {
        let panel = LabPanelView(emphasized: true, cornerRadius: 16)
        panel.heightAnchor.constraint(equalToConstant: 94).isActive = true

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 9
        rows.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            rows.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            rows.topAnchor.constraint(equalTo: panel.topAnchor, constant: 11),
            rows.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -11)
        ])

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.spacing = 9
        topRow.alignment = .centerY

        let mark = NSImageView()
        if let brandIcon = LabVisualStyle.brandIcon() {
            mark.image = brandIcon
        } else {
            mark.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Parrot Lab")
            mark.contentTintColor = LabVisualStyle.accent
            mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        }
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.widthAnchor.constraint(equalToConstant: 30).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 30).isActive = true
        topRow.addArrangedSubview(mark)

        let identity = NSStackView()
        identity.orientation = .vertical
        identity.spacing = -1
        let title = NSTextField(labelWithString: "PARROT LAB")
        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.textColor = .white
        let version = NSTextField(labelWithString: "V1.0")
        version.font = .monospacedSystemFont(ofSize: 8.5, weight: .bold)
        version.textColor = LabVisualStyle.accent
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 7
        titleRow.addArrangedSubview(title)
        titleRow.addArrangedSubview(version)
        let subtitle = NSTextField(labelWithString: "BEBOP 2 VIDEO & RF WORKBENCH")
        subtitle.font = .systemFont(ofSize: 9.5, weight: .semibold)
        subtitle.textColor = LabVisualStyle.mutedText
        identity.addArrangedSubview(titleRow)
        identity.addArrangedSubview(subtitle)
        topRow.addArrangedSubview(identity)

        let topSpacer = NSView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topRow.addArrangedSubview(topSpacer)

        let mediaControls = NSStackView()
        mediaControls.orientation = .horizontal
        mediaControls.alignment = .centerY
        mediaControls.spacing = 6
        mediaControls.addArrangedSubview(sectionLabel("MEDIA"))
        styleButton(browseMediaButton, action: #selector(browseMediaDirectory), symbol: "folder")
        browseMediaButton.toolTip = mediaDirectoryURL.path
        mediaControls.addArrangedSubview(browseMediaButton)
        styleButton(recordingButton, action: #selector(toggleRecording), symbol: "record.circle")
        recordingButton.bezelColor = .systemRed
        recordingButton.toolTip = "Record every received H.264 access unit without re-encoding"
        recordingButton.widthAnchor.constraint(equalToConstant: 112).isActive = true
        mediaControls.addArrangedSubview(recordingButton)
        for format in PictureFileFormat.allCases {
            pictureFormatPopup.addItem(withTitle: format.menuTitle)
            pictureFormatPopup.lastItem?.tag = format.rawValue
        }
        pictureFormatPopup.selectItem(withTag: PictureFileFormat.png.rawValue)
        pictureFormatPopup.controlSize = .regular
        pictureFormatPopup.font = .systemFont(ofSize: 11, weight: .medium)
        pictureFormatPopup.alignment = .center
        pictureFormatPopup.widthAnchor.constraint(equalToConstant: 66).isActive = true
        mediaControls.addArrangedSubview(pictureFormatPopup)
        styleButton(pictureButton, action: #selector(takePicture), symbol: "camera")
        pictureButton.toolTip = "Save the latest decoded source frame without the HUD overlay"
        pictureButton.widthAnchor.constraint(equalToConstant: 82).isActive = true
        mediaControls.addArrangedSubview(pictureButton)
        topRow.addArrangedSubview(mediaControls)

        configureStatusPill()
        topRow.addArrangedSubview(statusLabel)

        topRow.addArrangedSubview(sectionLabel("SC2 HOST"))
        styleTextField(hostField, width: 132)
        topRow.addArrangedSubview(hostField)

        styleButton(connectButton, action: #selector(toggleConnection), symbol: "cable.connector")
        topRow.addArrangedSubview(connectButton)
        rows.addArrangedSubview(topRow)

        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 9
        bottomRow.alignment = .centerY

        let bottomLeadingSpacer = NSView()
        let bottomTrailingSpacer = NSView()
        bottomLeadingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomTrailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomRow.addArrangedSubview(bottomLeadingSpacer)

        bottomRow.addArrangedSubview(sectionLabel("VIDEO RECEIVER"))
        for mode in VideoReceiveMode.allCases {
            videoModePopup.addItem(withTitle: mode.menuTitle)
            videoModePopup.lastItem?.tag = mode.rawValue
        }
        videoModePopup.selectItem(withTag: VideoReceiveMode.compatibility.rawValue)
        videoModePopup.target = self
        videoModePopup.action = #selector(videoModeChanged)
        videoModePopup.controlSize = .regular
        videoModePopup.font = .systemFont(ofSize: 12, weight: .medium)
        videoModePopup.alignment = .center
        videoModePopup.widthAnchor.constraint(equalToConstant: 235).isActive = true
        videoModePopup.toolTip = "Compatibility preserves the proven decoder. 1080p Lab expects the unwarped Dragon profile and captures FrameInfo metadata."
        bottomRow.addArrangedSubview(videoModePopup)

        bottomRow.addArrangedSubview(sectionLabel("RTP UDP"))
        styleTextField(rtpPortField, width: 76)
        bottomRow.addArrangedSubview(rtpPortField)
        styleButton(videoButton, action: #selector(startVideo), symbol: "video")
        videoButton.bezelColor = LabVisualStyle.accent
        bottomRow.addArrangedSubview(videoButton)

        let receiverHint = NSTextField(labelWithString: "Low-latency H.264 · bounded decode pipeline")
        receiverHint.font = .systemFont(ofSize: 10.5, weight: .regular)
        receiverHint.textColor = LabVisualStyle.mutedText
        receiverHint.alignment = .center
        bottomRow.addArrangedSubview(receiverHint)
        bottomRow.addArrangedSubview(bottomTrailingSpacer)
        bottomLeadingSpacer.widthAnchor.constraint(equalTo: bottomTrailingSpacer.widthAnchor).isActive = true
        rows.addArrangedSubview(bottomRow)
        return panel
    }

    private func buildSidebar() -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let document = LabFlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 980))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.addArrangedSubview(buildDragonCard())
        stack.addArrangedSubview(card(title: "VIDEO", body: videoLabel))
        stack.addArrangedSubview(card(title: "RF LINK", body: rfLabel))
        stack.addArrangedSubview(card(title: "FLIGHT", body: flightLabel))
        stack.addArrangedSubview(card(title: "SC2 HEALTH", body: healthLabel))

        let notice = NSTextField(wrappingLabelWithString: "Dragon Lab changes runtime options only. It never writes the persistent Dragon property or replaces the stock system binary.")
        notice.textColor = LabVisualStyle.mutedText
        notice.font = .systemFont(ofSize: 10.5)
        notice.maximumNumberOfLines = 5
        notice.widthAnchor.constraint(equalToConstant: 280).isActive = true
        stack.addArrangedSubview(notice)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor)
        ])
        scroll.documentView = document
        return scroll
    }

    private func card(title: String, body: NSTextField) -> NSView {
        let container = LabPanelView()
        container.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 13, left: 13, bottom: 13, right: 13)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 10.5, weight: .bold)
        heading.textColor = LabVisualStyle.accent
        stack.addArrangedSubview(heading)
        body.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        body.textColor = NSColor.white.withAlphaComponent(0.86)
        body.maximumNumberOfLines = 8
        body.lineBreakMode = .byWordWrapping
        body.widthAnchor.constraint(equalToConstant: 274).isActive = true
        stack.addArrangedSubview(body)
        return container
    }

    private func styleButton(_ button: NSButton, action: Selector, symbol: String? = nil) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
    }

    private func buildDragonCard() -> NSView {
        let container = LabPanelView(emphasized: true)
        container.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 13, left: 13, bottom: 13, right: 13)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let headingRow = NSStackView()
        headingRow.orientation = .horizontal
        headingRow.alignment = .centerY
        headingRow.spacing = 6
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        icon.contentTintColor = LabVisualStyle.accent
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        headingRow.addArrangedSubview(icon)
        let heading = NSTextField(labelWithString: "DRAGON LAB")
        heading.font = .systemFont(ofSize: 10.5, weight: .bold)
        heading.textColor = LabVisualStyle.accent
        headingRow.addArrangedSubview(heading)
        let runtimeTag = NSTextField(labelWithString: "RUNTIME ONLY")
        runtimeTag.font = .monospacedSystemFont(ofSize: 8.5, weight: .semibold)
        runtimeTag.textColor = LabVisualStyle.mutedText
        headingRow.addArrangedSubview(runtimeTag)
        stack.addArrangedSubview(headingRow)

        for resolution in DragonVideoResolution.allCases {
            dragonResolutionPopup.addItem(withTitle: resolution.menuTitle)
            dragonResolutionPopup.lastItem?.tag = resolution.rawValue
        }
        dragonResolutionPopup.selectItem(withTag: DragonVideoResolution.lab1080.rawValue)
        dragonResolutionPopup.target = self
        dragonResolutionPopup.action = #selector(dragonResolutionChanged)
        dragonResolutionPopup.controlSize = .regular
        dragonResolutionPopup.font = .systemFont(ofSize: 12, weight: .medium)
        dragonResolutionPopup.widthAnchor.constraint(equalToConstant: 274).isActive = true
        stack.addArrangedSubview(dragonResolutionPopup)

        let bitrateRow = NSStackView()
        bitrateRow.orientation = .horizontal
        bitrateRow.alignment = .centerY
        bitrateRow.addArrangedSubview(sectionLabel("MAX BITRATE"))
        let bitrateSpacer = NSView()
        bitrateSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bitrateRow.addArrangedSubview(bitrateSpacer)
        dragonBitrateValue.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        dragonBitrateValue.textColor = .white
        bitrateRow.addArrangedSubview(dragonBitrateValue)
        bitrateRow.widthAnchor.constraint(equalToConstant: 274).isActive = true
        stack.addArrangedSubview(bitrateRow)

        dragonBitrateSlider.numberOfTickMarks = 31
        dragonBitrateSlider.allowsTickMarkValuesOnly = true
        dragonBitrateSlider.isContinuous = true
        dragonBitrateSlider.target = self
        dragonBitrateSlider.action = #selector(dragonBitrateChanged)
        dragonBitrateSlider.widthAnchor.constraint(equalToConstant: 274).isActive = true
        stack.addArrangedSubview(dragonBitrateSlider)

        dragonLockRateButton.state = .off
        dragonLockRateButton.controlSize = .small
        dragonLockRateButton.font = .systemFont(ofSize: 11, weight: .medium)
        dragonLockRateButton.toolTip = "Adds -s to disable Dragon's adaptive streaming bitrate."
        stack.addArrangedSubview(dragonLockRateButton)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 7
        styleButton(dragonApplyButton, action: #selector(applyDragonProfile), symbol: "bolt.fill")
        dragonApplyButton.bezelColor = LabVisualStyle.accent
        styleButton(dragonRestoreButton, action: #selector(restoreStockDragon), symbol: "arrow.counterclockwise")
        actions.addArrangedSubview(dragonApplyButton)
        actions.addArrangedSubview(dragonRestoreButton)
        stack.addArrangedSubview(actions)

        dragonStatusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        dragonStatusLabel.textColor = LabVisualStyle.mutedText
        dragonStatusLabel.lineBreakMode = .byTruncatingTail
        dragonStatusLabel.widthAnchor.constraint(equalToConstant: 274).isActive = true
        stack.addArrangedSubview(dragonStatusLabel)

        let warning = NSTextField(wrappingLabelWithString: "Requires LANDED. Restarting Dragon briefly interrupts flight, video and telemetry services.")
        warning.font = .systemFont(ofSize: 10, weight: .regular)
        warning.textColor = NSColor.systemOrange.withAlphaComponent(0.82)
        warning.maximumNumberOfLines = 3
        warning.widthAnchor.constraint(equalToConstant: 274).isActive = true
        stack.addArrangedSubview(warning)
        return container
    }

    private func buildConsolePanel() -> NSView {
        let panel = LabPanelView(cornerRadius: 14)
        panel.heightAnchor.constraint(equalToConstant: 126).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8)
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.addArrangedSubview(sectionLabel("EVENT LOG"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(spacer)
        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearConsole))
        clearButton.bezelStyle = .inline
        clearButton.controlSize = .small
        clearButton.font = .systemFont(ofSize: 10.5, weight: .medium)
        clearButton.contentTintColor = LabVisualStyle.mutedText
        header.addArrangedSubview(clearButton)
        stack.addArrangedSubview(header)

        let consoleScroll = NSScrollView()
        consoleScroll.hasVerticalScroller = true
        consoleScroll.autohidesScrollers = true
        consoleScroll.borderType = .noBorder
        consoleScroll.drawsBackground = false
        console.isEditable = false
        console.isSelectable = true
        console.drawsBackground = false
        console.textColor = NSColor.white.withAlphaComponent(0.72)
        console.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        console.textContainerInset = NSSize(width: 4, height: 4)
        consoleScroll.documentView = console
        stack.addArrangedSubview(consoleScroll)
        return panel
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9.5, weight: .bold)
        label.textColor = LabVisualStyle.mutedText
        label.alignment = .center
        return label
    }

    private func styleTextField(_ field: NSTextField, width: CGFloat) {
        installVerticallyCenteredCell(on: field)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        field.isBezeled = false
        field.drawsBackground = false
        field.alignment = .center
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        field.layer?.cornerRadius = 7
        field.layer?.masksToBounds = true
        field.focusRingType = .exterior
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.heightAnchor.constraint(equalToConstant: 27).isActive = true
    }

    private func configureStatusPill() {
        installVerticallyCenteredCell(on: statusLabel)
        statusLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .bold)
        statusLabel.textColor = .systemOrange
        statusLabel.alignment = .center
        statusLabel.wantsLayer = true
        statusLabel.layer?.cornerRadius = 13
        statusLabel.layer?.masksToBounds = true
        statusLabel.widthAnchor.constraint(equalToConstant: 112).isActive = true
        statusLabel.heightAnchor.constraint(equalToConstant: 26).isActive = true
        updateStatusPillAppearance()
    }

    private func installVerticallyCenteredCell(on field: NSTextField) {
        let previous = field.cell
        let cell = LabVerticallyCenteredTextFieldCell(textCell: field.stringValue)
        cell.isEditable = previous?.isEditable ?? field.isEditable
        cell.isSelectable = previous?.isSelectable ?? field.isSelectable
        cell.isScrollable = true
        cell.usesSingleLineMode = true
        cell.lineBreakMode = .byClipping
        field.cell = cell
    }

    private func updateStatusPillAppearance() {
        let color = statusLabel.textColor ?? .secondaryLabelColor
        statusLabel.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        statusLabel.layer?.borderWidth = 1
        statusLabel.layer?.borderColor = color.withAlphaComponent(0.22).cgColor
    }

    @objc private func clearConsole() {
        console.string = ""
    }

    private func wireDataSources() {
        telnet.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.snapshot.connectionLabel = "Live SC2"
                self.statusLabel.stringValue = "LIVE"
                self.statusLabel.textColor = .systemGreen
                self.connectButton.title = "Disconnect"
                if self.dragonRuntimeStatus == "SC2 OFFLINE" {
                    self.dragonRuntimeStatus = "READY · LANDED ONLY"
                }
                self.startTelemetryFreshnessTimer()
                let host = self.hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                self.startDroneProbe(host: host)
            case .connecting:
                self.statusLabel.stringValue = "CONNECTING"
                self.statusLabel.textColor = .systemYellow
            case .failed(let message):
                self.stopDroneProbe()
                self.stopTelemetryFreshnessTimer()
                self.snapshot.connectionLabel = "Disconnected"
                self.statusLabel.stringValue = "FAILED"
                self.statusLabel.textColor = .systemRed
                self.connectButton.title = "Connect SC2"
                self.dragonRuntimeStatus = "SC2 OFFLINE"
                self.appendLog("Connection failed: \(message)")
            case .stopped, .idle:
                self.stopDroneProbe()
                self.stopTelemetryFreshnessTimer()
                self.snapshot.connectionLabel = "Disconnected"
                self.statusLabel.stringValue = "DISCONNECTED"
                self.statusLabel.textColor = .systemOrange
                self.connectButton.title = "Connect SC2"
                self.dragonRuntimeStatus = "SC2 OFFLINE"
            }
            self.updateInterface()
        }
        telnet.onLine = { [weak self] line in self?.consume(line: line) }
        telnet.onDebug = { [weak self] message in self?.appendLog(message) }
        droneProbeTelnet.onLine = { [weak self] line in
            guard let self else { return }
            if line.contains("__PARROTLAB_DRONE_BATTERY__=") {
                self.appendLog("Battery probe reply: \(SC2TelemetryParser.stripANSI(from: line))")
            }
            self.consume(line: line)
        }
        droneProbeTelnet.onDebug = { [weak self] message in
            self?.appendLog("Battery probe: \(message)")
        }
        dragonControlTelnet.onLine = { [weak self] line in
            self?.handleDragonControlLine(line)
        }
        dragonControlTelnet.onDebug = { [weak self] message in
            self?.appendLog("Dragon control: \(message)")
        }
        dragonControlTelnet.onState = { [weak self] state in
            self?.handleDragonControlState(state)
        }
        sc2DriverTelnet.onLine = { [weak self] line in
            self?.handleSC2DriverInstallLine(line)
        }
        sc2DriverTelnet.onDebug = { [weak self] message in
            self?.appendLog("SC2 driver install: \(message)")
        }
        sc2DriverTelnet.onState = { [weak self] state in
            self?.handleSC2DriverInstallState(state)
        }
        toolInstaller.onProgress = { [weak self] message in
            guard let self else { return }
            self.appendLog("FTP: \(message)")
            if self.pendingDragonInstall {
                self.dragonRuntimeStatus = message.uppercased()
                self.updateInterface()
            }
        }
        restreamProbe.onDebug = { [weak self] message in self?.appendLog(message) }
        rtpReceiver.onDebug = { [weak self] message in self?.appendLog(message) }
        hudView.videoView.onDebug = { [weak self] message in self?.appendLog(message) }
        hudView.videoView.onFormat = { [weak self] width, height in
            guard let self else { return }
            self.videoFormatStatus = "FORMAT \(width)x\(height)"
            self.updateInterface()
        }
        hudView.videoView.onMetadataPresence = { [weak self] presence in
            guard let self else { return }
            self.videoMetadataPresence = presence
            self.updateInterface()
        }
        rtpReceiver.onAccessUnit = { [weak self] accessUnit in
            self?.hudView.videoView.display(accessUnit: accessUnit)
        }
        rtpReceiver.onCompleteAccessUnit = { [weak self] accessUnit in
            self?.streamRecorder.observe(accessUnit)
        }
        streamRecorder.onFinished = { [weak self] result in
            self?.recordingFinished(result)
        }
        hudView.videoView.onFrameReady = { [weak self] in
            self?.updateInterface()
        }
        rtpReceiver.onStats = { [weak self] stats in
            guard let self else { return }
            self.snapshot.videoBitrateKbps = stats.bitrateKbps
            self.snapshot.videoPackets = stats.packets
            self.snapshot.videoPacketsLost = stats.packetsLost
            self.snapshot.videoJitterMs = stats.jitterMs
            self.updateInterface()
        }
    }

    @objc private func toggleConnection() {
        if connectButton.title == "Disconnect" {
            telnet.stop()
            return
        }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        parser.reset()
        snapshot = TelemetrySnapshot()
        lastFlightStateUpdate = nil
        updateInterface()
        appendLog("Connecting to SC2 Telnet at \(host):23")
        telnet.connect(host: host)
    }

    private func startDroneProbe(host: String) {
        stopDroneProbe()
        guard !host.isEmpty, !dragonCommandInFlight, !toolUploadInFlight,
              !sc2DriverInstallInFlight else { return }
        runDroneProbe(host: host)
        droneProbeTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.runDroneProbe(host: host)
        }
    }

    private func runDroneProbe(host: String) {
        // Port 2324 is the read-only SC2 boot relay to the drone's Telnet
        // service. Keeping this separate avoids nesting Telnet inside a shell.
        droneProbeTelnet.connect(host: host, port: 2324, startupCommand: Self.droneBatteryProbeCommand)
    }

    private func stopDroneProbe() {
        droneProbeTimer?.invalidate()
        droneProbeTimer = nil
        droneProbeTelnet.stop()
    }

    private func startTelemetryFreshnessTimer() {
        stopTelemetryFreshnessTimer()
        telemetryFreshnessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateInterface()
        }
    }

    private func stopTelemetryFreshnessTimer() {
        telemetryFreshnessTimer?.invalidate()
        telemetryFreshnessTimer = nil
    }

    private var selectedVideoMode: VideoReceiveMode {
        VideoReceiveMode(rawValue: videoModePopup.selectedItem?.tag ?? -1) ?? .compatibility
    }

    @objc private func videoModeChanged() {
        guard !videoRunning else { return }
        let mode = selectedVideoMode
        hudView.videoView.receiveMode = mode
        videoFormatStatus = "FORMAT waiting"
        videoMetadataPresence = VideoMetadataPresence()
        videoStatus = "Restream idle"
        appendLog("Video mode selected: \(mode.menuTitle)")
        if let profile = mode.expectedDragonProfile {
            appendLog("1080p Lab expects Dragon profile: \(profile)")
            appendLog("Dragon Lab can apply a matching non-persistent runtime profile while landed")
        }
        updateInterface()
    }

    private var selectedDragonResolution: DragonVideoResolution {
        DragonVideoResolution(rawValue: dragonResolutionPopup.selectedItem?.tag ?? -1) ?? .lab1080
    }

    @objc private func dragonResolutionChanged() {
        let bitrate = selectedDragonResolution.recommendedBitrateKbps
        dragonBitrateSlider.integerValue = bitrate
        updateDragonBitrateLabel()
    }

    @objc private func dragonBitrateChanged() {
        let rounded = Int((dragonBitrateSlider.doubleValue / 500.0).rounded()) * 500
        dragonBitrateSlider.integerValue = rounded
        updateDragonBitrateLabel()
    }

    private func updateDragonBitrateLabel() {
        dragonBitrateValue.stringValue = String(
            format: "%.1f Mbps",
            Double(dragonBitrateSlider.integerValue) / 1_000.0
        )
    }

    @objc private func applyDragonProfile() {
        guard canAdjustDragon else {
            showDragonAlert(
                title: "Dragon controls are locked",
                message: "Connect to the SC2 and wait until live telemetry explicitly reports LANDED."
            )
            return
        }
        guard let profile = DragonVideoProfile(
            resolution: selectedDragonResolution,
            bitrateKbps: dragonBitrateSlider.integerValue,
            locksBitrate: dragonLockRateButton.state == .on
        ) else {
            appendLog("Dragon profile rejected: bitrate must be 1–16 Mbps in 0.5 Mbps steps")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Restart Dragon with \(profile.resolution.statusLabel)?"
        alert.informativeText = "This stops and relaunches the drone's flight process with \(profile.bitrateLabel) \(profile.locksBitrate ? "locked bitrate" : "adaptive bitrate ceiling"). Keep the drone landed with props removed. The change is not persistent and a reboot restores normal startup."
        alert.addButton(withTitle: "Restart Dragon")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if videoRunning { startVideo() }
        videoModePopup.selectItem(withTag: profile.resolution.receiverMode.rawValue)
        hudView.videoView.receiveMode = profile.resolution.receiverMode
        videoFormatStatus = "FORMAT waiting"
        videoMetadataPresence = VideoMetadataPresence()
        pendingDragonProfile = profile
        runDragonCommand(profile.applyCommand, status: "APPLYING · \(profile.launchSummary)")
    }

    @objc private func restoreStockDragon() {
        guard canAdjustDragon else {
            showDragonAlert(
                title: "Stock restore is locked",
                message: "Connect to the SC2 and wait until live telemetry explicitly reports LANDED."
            )
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Restore stock Dragon startup?"
        alert.informativeText = "This stops the active Dragon process and relaunches /usr/bin/DragonStarter.sh. Keep the drone landed with props removed."
        alert.addButton(withTitle: "Restore stock")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if videoRunning { startVideo() }
        pendingDragonProfile = nil
        runDragonCommand(DragonVideoProfile.restoreCommand, status: "RESTORING STOCK")
    }

    func installDragonLabOnBebop2() {
        guard !toolUploadInFlight else {
            showToolAlert(title: "Upload already running", message: "Wait for the current FTP transfer to finish.")
            return
        }
        guard canAdjustDragon else {
            showDragonAlert(
                title: "Dragon Lab installation is locked",
                message: "Connect to the SC2 and wait until live telemetry explicitly reports LANDED. The app uses the SC2 relay only to verify and mark the uploaded files executable."
            )
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Install or update Dragon Lab on Bebop 2?"
        alert.informativeText = "Parrot Lab will upload the patched Dragon binary and runtime helper through anonymous FTP to 192.168.42.1:/internal_000, download both files for SHA-256 verification, then mark only those uploaded files executable. It will not replace /usr/bin/dragon-prog or restart Dragon."
        alert.addButton(withTitle: "Install / Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        stopDroneProbe()
        toolUploadInFlight = true
        dragonCommandInFlight = true
        dragonCommandConnected = false
        dragonCommandSucceeded = false
        pendingDragonProfile = nil
        pendingDragonInstall = true
        dragonRuntimeStatus = "UPLOADING LAB FILES"
        updateInterface()
        appendLog("Installing Dragon Lab to Bebop 2 FTP 192.168.42.1:21/internal_000")

        toolInstaller.install(.dragonLab) { [weak self] result in
            guard let self else { return }
            self.toolUploadInFlight = false
            switch result {
            case .success(let install):
                self.appendVerifiedAssets(install)
                guard let command = self.dragonInstallVerificationCommand(install) else {
                    self.dragonRuntimeStatus = "ERROR · INSTALL MANIFEST"
                    self.finishDragonCommand()
                    return
                }
                self.runDragonCommand(
                    command,
                    status: "VERIFYING LAB FILES",
                    logMessage: "FTP transfer verified; marking the two app-owned files executable and checking their MD5 digests"
                )
            case .failure(let error):
                self.dragonRuntimeStatus = "ERROR · FTP INSTALL"
                self.appendLog("Dragon Lab installation failed: \(error.localizedDescription)")
                self.showToolAlert(title: "Dragon Lab was not installed", message: error.localizedDescription)
                self.finishDragonCommand()
            }
        }
    }

    func uploadRFModSuiteToBebop2() {
        uploadRFModSuite(
            host: BebopToolPackage.ftpHost,
            targetName: "Bebop 2",
            devicePath: "/data/ftp/internal_000/parrot_rf_lab.sh"
        )
    }

    func uploadRFModSuiteToSkyController2() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        uploadRFModSuite(
            host: host,
            targetName: "SkyController 2",
            devicePath: "/data/lib/ftp/internal_000/parrot_rf_lab.sh"
        )
    }

    func installSC2DriverPatch() {
        guard !toolUploadInFlight, !dragonCommandInFlight, !sc2DriverInstallInFlight else {
            showToolAlert(title: "Tool operation already running", message: "Wait for the current transfer or device operation to finish.")
            return
        }
        guard connectButton.title == "Disconnect", hasFreshLandedTelemetry else {
            showToolAlert(
                title: "SC2 driver installation is locked",
                message: "Connect to the SC2 and wait until live telemetry explicitly reports LANDED. Rebooting a controller while the aircraft is active is not permitted."
            )
            return
        }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            showToolAlert(title: "Missing SC2 host", message: "Enter the current controller address in SC2 HOST.")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Install the persistent SC2 Apple-NCM driver and reboot?"
        alert.informativeText = "This is only for SkyController 2 firmware 1.0.9. Parrot Lab will upload and verify the installer plus ARM kernel module on \(host), connect to root Telnet on that same address, chmod 775 the installer, and run it. The installer writes /data/lib/parrotlab and a short plboot service under /etc/boxinit.d, then the app reboots the SC2. Keep the aircraft landed, disconnect any phone, and expect the controller connection to drop."
        alert.addButton(withTitle: "Install and Reboot")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if videoRunning { startVideo() }
        stopDroneProbe()
        toolUploadInFlight = true
        sc2DriverInstallInFlight = true
        sc2DriverTelnetConnected = false
        sc2DriverInstallSucceeded = false
        pendingSC2DriverHost = host
        statusLabel.stringValue = "INSTALLING"
        statusLabel.textColor = .systemYellow
        updateInterface()
        appendLog("Uploading the SC2 Apple-NCM installer and module to \(host):21/internal_000")

        toolInstaller.install(.sc2DriverPatch, host: host) { [weak self] result in
            guard let self else { return }
            self.toolUploadInFlight = false
            switch result {
            case .success(let install):
                self.appendVerifiedAssets(install)
                guard let command = self.sc2DriverInstallCommand(install) else {
                    self.appendLog("SC2 driver package manifest is incomplete")
                    self.finishSC2DriverInstall(success: false, message: "The bundled driver package is incomplete.")
                    return
                }
                self.appendLog("FTP verification passed; connecting to SC2 root Telnet at \(host):23")
                self.sc2DriverTelnet.connect(host: host, port: 23, startupCommand: command)
            case .failure(let error):
                self.appendLog("SC2 driver FTP upload failed: \(error.localizedDescription)")
                self.finishSC2DriverInstall(success: false, message: error.localizedDescription)
            }
        }
    }

    private func uploadRFModSuite(host: String, targetName: String, devicePath: String) {
        guard !toolUploadInFlight, !dragonCommandInFlight, !sc2DriverInstallInFlight else {
            showToolAlert(title: "Tool operation already running", message: "Wait for the current transfer or Dragon operation to finish.")
            return
        }
        guard !host.isEmpty else {
            showToolAlert(title: "Missing FTP host", message: "Enter the current SC2 address in the SC2 HOST field first.")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Upload RF/MOD Suite to \(targetName)?"
        alert.informativeText = "Parrot Lab will upload parrot_rf_lab.sh through anonymous FTP to \(host):/internal_000 and download it again for SHA-256 verification. It will not apply an RF profile or modify any system or factory file."
        alert.addButton(withTitle: "Upload")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        toolUploadInFlight = true
        updateInterface()
        appendLog("Uploading RF/MOD Suite to \(targetName) FTP \(host):21/internal_000")
        toolInstaller.install(.rfModSuite, host: host) { [weak self] result in
            guard let self else { return }
            self.toolUploadInFlight = false
            self.updateInterface()
            switch result {
            case .success(let install):
                self.appendVerifiedAssets(install)
                self.appendLog("RF/MOD Suite ready on \(targetName): \(devicePath)")
                self.showToolAlert(
                    title: "RF/MOD Suite uploaded",
                    message: "Verified on \(targetName) at:\n\(devicePath)\n\nLaunch it from a device shell with: sh \(devicePath) menu",
                    style: .informational
                )
            case .failure(let error):
                self.appendLog("RF/MOD Suite upload to \(targetName) failed: \(error.localizedDescription)")
                self.showToolAlert(title: "RF/MOD Suite upload failed", message: error.localizedDescription)
            }
        }
    }

    private func appendVerifiedAssets(_ result: BebopToolInstallResult) {
        for asset in result.assets {
            appendLog("Verified \(asset.remoteName) · \(asset.byteCount) bytes · SHA-256 \(asset.sha256)")
        }
    }

    private func dragonInstallVerificationCommand(_ result: BebopToolInstallResult) -> String? {
        guard let binary = result.assets.first(where: { $0.remoteName == "dragon-prog-1080p-mode1-30fps" }),
              let helper = result.assets.first(where: { $0.remoteName == "parrotlab_dragon_video.sh" }) else {
            return nil
        }
        return "chmod 755 \(binary.devicePath) \(helper.devicePath); " +
            "D=$(md5sum \(binary.devicePath)); D=${D%% *}; " +
            "H=$(md5sum \(helper.devicePath)); H=${H%% *}; " +
            "if [ -x \(binary.devicePath) ] && [ -x \(helper.devicePath) ] && " +
            "[ \"$D\" = \"\(binary.md5)\" ] && [ \"$H\" = \"\(helper.md5)\" ]; " +
            "then echo __PARROTLAB_INSTALL__=READY; else echo __PARROTLAB_INSTALL__=ERROR; fi; exit"
    }

    private func sc2DriverInstallCommand(_ result: BebopToolInstallResult) -> String? {
        guard let script = result.assets.first(where: { $0.remoteName == "install_sc2_apple_ncm.sh" }),
              let module = result.assets.first(where: { $0.remoteName == "apple_mac_ncm.ko" }) else {
            return nil
        }
        let root = "/data/lib/ftp/internal_000"
        let scriptPath = "\(root)/\(script.remoteName)"
        let modulePath = "\(root)/\(module.remoteName)"
        return "chmod 775 \(scriptPath); " +
            "S=$(md5sum \(scriptPath)); S=${S%% *}; " +
            "M=$(md5sum \(modulePath)); M=${M%% *}; " +
            "if [ \"$S\" != \"\(script.md5)\" ] || [ \"$M\" != \"\(module.md5)\" ]; " +
            "then echo __PARROTLAB_SC2_DRIVER__=ERROR_DIGEST; " +
            "elif \(scriptPath) \(modulePath); " +
            "then echo __PARROTLAB_SC2_DRIVER__=INSTALLED_REBOOTING; sync; sleep 2; reboot; " +
            "else echo __PARROTLAB_SC2_DRIVER__=ERROR_INSTALLER; fi; exit"
    }

    private func handleSC2DriverInstallLine(_ rawLine: String) {
        let line = SC2TelemetryParser.stripANSI(from: rawLine)
        if line.contains("__PARROTLAB_SC2_DRIVER_SCRIPT__=INSTALLED") {
            appendLog("SC2 installer confirmed the persistent plboot configuration")
        }
        guard let marker = line.range(of: "__PARROTLAB_SC2_DRIVER__=") else { return }
        let event = String(line[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["INSTALLED_REBOOTING", "ERROR_DIGEST", "ERROR_INSTALLER"].contains(event) else { return }
        if event == "INSTALLED_REBOOTING" {
            sc2DriverInstallSucceeded = true
            statusLabel.stringValue = "REBOOTING"
            statusLabel.textColor = .systemCyan
            appendLog("SC2 driver installation succeeded; reboot command issued")
            updateInterface()
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, self.sc2DriverInstallInFlight, self.sc2DriverInstallSucceeded else { return }
                self.sc2DriverTelnet.stop()
            }
        } else {
            sc2DriverInstallSucceeded = false
            appendLog("SC2 driver installer reported: \(event)")
        }
    }

    private func handleSC2DriverInstallState(_ state: TelnetClient.State) {
        switch state {
        case .ready:
            sc2DriverTelnetConnected = true
        case .failed(let message):
            guard sc2DriverInstallInFlight else { return }
            if sc2DriverInstallSucceeded {
                finishSC2DriverInstall(success: true, message: nil)
            } else {
                appendLog("SC2 driver Telnet failed: \(message)")
                finishSC2DriverInstall(success: false, message: "SC2 Telnet failed: \(message)")
            }
        case .stopped:
            guard sc2DriverInstallInFlight, sc2DriverTelnetConnected else { return }
            if sc2DriverInstallSucceeded {
                finishSC2DriverInstall(success: true, message: nil)
            } else {
                finishSC2DriverInstall(
                    success: false,
                    message: "The SC2 shell closed without confirming a successful driver installation. The reboot command was not issued."
                )
            }
        case .idle, .connecting:
            break
        }
    }

    private func finishSC2DriverInstall(success: Bool, message: String?) {
        guard sc2DriverInstallInFlight else { return }
        let host = pendingSC2DriverHost
        toolUploadInFlight = false
        sc2DriverInstallInFlight = false
        sc2DriverTelnetConnected = false
        sc2DriverInstallSucceeded = false
        pendingSC2DriverHost = nil
        updateInterface()

        if success {
            appendLog("SC2 rebooting with the new plboot Apple-NCM configuration")
            showToolAlert(
                title: "SC2 driver installed — controller rebooting",
                message: "The installer and module passed FTP and on-device digest checks. The persistent plboot service was installed and the reboot command was issued. Wait for the SkyController 2 to return, then reconnect Parrot Lab.",
                style: .informational
            )
        } else {
            statusLabel.stringValue = connectButton.title == "Disconnect" ? "LIVE" : "DISCONNECTED"
            statusLabel.textColor = connectButton.title == "Disconnect" ? .systemGreen : .systemOrange
            updateInterface()
            let detail = message ?? "The controller did not confirm installation."
            showToolAlert(title: "SC2 driver was not installed", message: detail)
            if connectButton.title == "Disconnect", let host {
                startDroneProbe(host: host)
            }
        }
    }

    private var canAdjustDragon: Bool {
        connectButton.title == "Disconnect" &&
            hasFreshLandedTelemetry &&
            !dragonCommandInFlight &&
            !toolUploadInFlight &&
            !sc2DriverInstallInFlight
    }

    private var hasFreshLandedTelemetry: Bool {
        guard snapshot.flightState == "LANDED", let lastFlightStateUpdate else { return false }
        return Date().timeIntervalSince(lastFlightStateUpdate) <= 3
    }

    private func runDragonCommand(
        _ command: String,
        status: String,
        logMessage: String = "Dragon control requested; runtime-only helper will validate the profile"
    ) {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        stopDroneProbe()
        dragonCommandInFlight = true
        dragonCommandConnected = false
        dragonCommandSucceeded = false
        dragonRuntimeStatus = status
        updateInterface()
        appendLog(logMessage)
        dragonControlTelnet.connect(host: host, port: 2324, startupCommand: command)
    }

    private func handleDragonControlState(_ state: TelnetClient.State) {
        switch state {
        case .ready:
            dragonCommandConnected = true
        case .failed(let message):
            guard dragonCommandInFlight else { return }
            dragonRuntimeStatus = "CONTROL ERROR"
            appendLog("Dragon control failed: \(message)")
            finishDragonCommand()
        case .stopped:
            // TelnetClient emits .stopped once while replacing an old
            // connection. Only treat closure after .ready as completion.
            guard dragonCommandInFlight, dragonCommandConnected else { return }
            finishDragonCommand()
        case .idle, .connecting:
            break
        }
    }

    private func handleDragonControlLine(_ rawLine: String) {
        let line = SC2TelemetryParser.stripANSI(from: rawLine)
        if let marker = line.range(of: "__PARROTLAB_INSTALL__=") {
            let event = String(line[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard event == "READY" || event == "ERROR" else { return }
            if event == "READY" {
                dragonCommandSucceeded = true
                dragonRuntimeStatus = "LAB FILES READY"
                appendLog("Dragon Lab files are executable and match the verified FTP upload")
                showToolAlert(
                    title: "Dragon Lab installed",
                    message: "The patched binary and helper are verified in /data/ftp/internal_000. Stock /usr/bin/dragon-prog was not changed and Dragon was not restarted.",
                    style: .informational
                )
            } else {
                dragonRuntimeStatus = "ERROR · DEVICE VERIFY"
                appendLog("Dragon Lab device-side executable/digest verification failed")
                showToolAlert(
                    title: "Dragon Lab verification failed",
                    message: "The FTP copies were valid, but the drone did not confirm their executable bits and MD5 digests. Do not apply a Lab profile until the install succeeds."
                )
            }
            updateInterface()
            return
        }
        guard let marker = line.range(of: "__PARROTLAB_DRAGON__=") else { return }
        let payload = String(line[marker.upperBound...])
        let fields = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let event = fields.first else { return }

        switch event {
        case "RUNNING":
            dragonCommandSucceeded = true
            if let profile = pendingDragonProfile {
                dragonRuntimeStatus = "RUNNING · \(profile.launchSummary)"
            } else {
                dragonRuntimeStatus = "RUNNING"
            }
            appendLog("Dragon helper: \(payload)")
        case "RESTORED":
            dragonCommandSucceeded = true
            dragonRuntimeStatus = "STOCK RESTORED"
            videoModePopup.selectItem(withTag: VideoReceiveMode.compatibility.rawValue)
            hudView.videoView.receiveMode = .compatibility
            appendLog("Dragon stock startup restored")
        case "STATUS":
            dragonCommandSucceeded = true
            dragonRuntimeStatus = fields.dropFirst().joined(separator: " · ")
        case "ERROR":
            dragonRuntimeStatus = "ERROR · " + fields.dropFirst().joined(separator: " ")
            appendLog("Dragon helper error: \(fields.dropFirst().joined(separator: " | "))")
        default:
            appendLog("Dragon helper: \(payload)")
        }
        updateInterface()
    }

    private func finishDragonCommand() {
        guard dragonCommandInFlight else { return }
        if !dragonCommandSucceeded, !dragonRuntimeStatus.hasPrefix("ERROR"),
           dragonRuntimeStatus != "CONTROL ERROR" {
            dragonRuntimeStatus = "NO RESULT · CHECK HELPER"
        }
        dragonCommandInFlight = false
        dragonCommandConnected = false
        pendingDragonProfile = nil
        pendingDragonInstall = false
        updateInterface()

        if connectButton.title == "Disconnect" {
            let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startDroneProbe(host: host)
            }
        }
    }

    private func showDragonAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showToolAlert(
        title: String,
        message: String,
        style: NSAlert.Style = .warning
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func startVideo() {
        if videoRunning {
            if streamRecorder.isRecording { stopRecording() }
            restreamProbe.cancel()
            rtpReceiver.stop()
            hudView.videoView.reset()
            videoRunning = false
            videoButton.title = "Start video"
            videoModePopup.isEnabled = true
            videoStatus = "Restream idle"
            videoFormatStatus = "FORMAT waiting"
            videoMetadataPresence = VideoMetadataPresence()
            snapshot.videoBitrateKbps = nil
            snapshot.videoPackets = 0
            snapshot.videoPacketsLost = 0
            snapshot.videoJitterMs = nil
            updateInterface()
            appendLog("Video receiver stopped")
            return
        }
        guard let port = UInt16(rtpPortField.stringValue) else {
            appendLog("Invalid RTP UDP port")
            return
        }
        let mode = selectedVideoMode
        hudView.videoView.receiveMode = mode
        streamRecorder.resetParameterSets()
        do {
            try rtpReceiver.start(port: port)
            videoRunning = true
            videoButton.title = "Stop video"
            videoModePopup.isEnabled = false
            videoStatus = "Listening UDP \(port) · probing SC2"
            if let profile = mode.expectedDragonProfile {
                appendLog("Starting 1080p Lab receiver; expected Dragon profile: \(profile)")
            } else {
                appendLog("Starting compatibility receiver with the proven recovery decoder")
            }
            updateInterface()
        } catch {
            appendLog("Could not open UDP \(port): \(error.localizedDescription)")
            return
        }

        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        restreamProbe.probe(host: host) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let descriptor):
                let announced = descriptor.videoPort.map(String.init) ?? "not announced"
                self.videoStatus = "SC2 TCP \(descriptor.requestPort) · RTP \(announced)"
                self.appendLog("Restream response: \(descriptor.response.replacingOccurrences(of: "\r\n", with: " | "))")
                if let announcedPort = descriptor.videoPort, announcedPort != port {
                    self.appendLog("SC2 announced UDP \(announcedPort); switching receiver from \(port)")
                    do {
                        try self.rtpReceiver.start(port: announcedPort)
                        self.rtpPortField.stringValue = String(announcedPort)
                    } catch {
                        self.appendLog("Could not bind announced UDP port: \(error.localizedDescription)")
                        self.videoStatus = "SC2 announced UDP \(announcedPort) · bind failed"
                    }
                }
                self.updateInterface()
            case .failure(let error):
                self.videoStatus = "UDP \(port) ready · probe unavailable"
                self.appendLog("Restream probe: \(error.localizedDescription)")
                self.updateInterface()
            }
        }
    }

    private func consume(line: String) {
        if parser.consume(line: line, into: &snapshot) {
            if line.contains("state:") { lastFlightStateUpdate = Date() }
            updateInterface()
        }
    }

    private func updateInterface() {
        updateStatusPillAppearance()
        hudView.update(snapshot: snapshot)
        rfLabel.stringValue = [
            "A0 \(dbm(snapshot.chain0RSSI))   A1 \(dbm(snapshot.chain1RSSI))",
            "AVG \(dbm(snapshot.chainAverage ?? snapshot.reportedRSSI))",
            "NOISE \(dbm(snapshot.noise))   SNR \(number(snapshot.snr, "dB"))",
            "RX \(number(snapshot.rxQuality, "%"))   USEFUL \(number(snapshot.rxUseful, "%"))",
            "PHY \(snapshot.phyRateMbps.map { String(format: "%.1f Mbps", $0) } ?? "—")"
        ].joined(separator: "\n")

        flightLabel.stringValue = [
            snapshot.flightState,
            "ALT \(snapshot.altitude.map { String(format: "%.1f m", $0) } ?? "—")",
            "DIST \(snapshot.distanceFromHome.map { String(format: "%.0f m", $0) } ?? "—")",
            "BATTERY \(number(snapshot.droneBatteryPercent, "%"))",
            "ROLL \(degrees(snapshot.roll))",
            "PITCH \(degrees(snapshot.pitch))",
            "YAW \(degrees(snapshot.yaw))"
        ].joined(separator: "\n")

        healthLabel.stringValue = [
            "BATTERY \(number(snapshot.sc2BatteryPercent, "%"))",
            "CPU \(number(snapshot.sc2TemperatureC, "°C"))",
            snapshot.sc2PowerState ?? "—"
        ].joined(separator: "\n")

        videoLabel.stringValue = [
            "MODE \(selectedVideoMode.statusLabel)",
            videoStatus,
            videoFormatStatus,
            metadataStatus,
            "RTP \(snapshot.videoBitrateKbps.map { "\($0) kbps" } ?? "waiting")",
            "PACKETS \(snapshot.videoPackets)",
            "LOST \(snapshot.videoPacketsLost)",
            "JITTER \(snapshot.videoJitterMs.map { String(format: "%.1f ms", $0) } ?? "—")"
        ].joined(separator: "\n")

        let connected = connectButton.title == "Disconnect"
        let landed = hasFreshLandedTelemetry
        let deviceOperationActive = toolUploadInFlight || dragonCommandInFlight || sc2DriverInstallInFlight
        hostField.isEnabled = !deviceOperationActive
        connectButton.isEnabled = !deviceOperationActive
        let controlsEnabled = connected && landed && !dragonCommandInFlight &&
            !toolUploadInFlight && !sc2DriverInstallInFlight
        dragonResolutionPopup.isEnabled = controlsEnabled
        dragonBitrateSlider.isEnabled = controlsEnabled
        dragonLockRateButton.isEnabled = controlsEnabled
        dragonApplyButton.isEnabled = controlsEnabled
        dragonRestoreButton.isEnabled = controlsEnabled

        let recordingActive = streamRecorder.isActive
        browseMediaButton.isEnabled = !recordingActive
        recordingButton.isEnabled = videoRunning && (!recordingActive || streamRecorder.isRecording)
        pictureFormatPopup.isEnabled = !pictureWriteInFlight
        pictureButton.isEnabled = videoRunning && hudView.videoView.latestFrameImage() != nil && !pictureWriteInFlight

        if dragonCommandInFlight {
            dragonStatusLabel.stringValue = dragonRuntimeStatus
            dragonStatusLabel.textColor = .systemYellow
        } else if !connected {
            dragonStatusLabel.stringValue = "SC2 OFFLINE"
            dragonStatusLabel.textColor = LabVisualStyle.mutedText
        } else if !landed {
            let status = snapshot.flightState == "LANDED" ? "STALE TELEMETRY" : snapshot.flightState
            dragonStatusLabel.stringValue = "LOCKED · \(status)"
            dragonStatusLabel.textColor = .systemOrange
        } else {
            dragonStatusLabel.stringValue = dragonRuntimeStatus
            dragonStatusLabel.textColor = dragonRuntimeStatus.hasPrefix("ERROR") ? .systemRed : .systemGreen
        }
    }

    private var metadataStatus: String {
        let sei = videoMetadataPresence.hasLegacyFrameInfoSEI ? "SEI ✓" : "SEI —"
        let rtp = videoMetadataPresence.hasRTPHeaderExtensions ? "RTP-EXT ✓" : "RTP-EXT —"
        return "META \(sei)  \(rtp)"
    }

    @objc private func browseMediaDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose where Parrot Lab saves media"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = mediaDirectoryURL
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        mediaDirectoryURL = selected
        UserDefaults.standard.set(selected.path, forKey: Self.mediaDirectoryPreferenceKey)
        browseMediaButton.toolTip = selected.path
        appendLog("Media directory: \(selected.path)")
    }

    @objc private func toggleRecording() {
        if streamRecorder.isRecording {
            stopRecording()
            return
        }
        guard videoRunning else {
            showMediaAlert("Start the video receiver before recording.")
            return
        }
        let started = Date()
        do {
            let temporaryURL = try streamRecorder.start(directory: mediaDirectoryURL, at: started)
            recordingStartedAt = started
            recordingButton.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
            recordingButton.bezelColor = .systemRed
            recordingTimer?.invalidate()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.updateRecordingButton()
            }
            updateRecordingButton()
            updateInterface()
            appendLog("Raw H.264 recording started: \(temporaryURL.path)")
        } catch {
            showMediaAlert("Could not start recording: \(error.localizedDescription)")
            appendLog("Recording failed to start: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard streamRecorder.isRecording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingButton.title = "Finishing…"
        recordingButton.isEnabled = false
        streamRecorder.stop()
    }

    private func updateRecordingButton() {
        guard let recordingStartedAt, streamRecorder.isRecording else { return }
        let elapsed = Date().timeIntervalSince(recordingStartedAt)
        recordingButton.title = "Stop \(MediaFileNamer.durationStamp(elapsed))"
    }

    private func recordingFinished(_ result: H264RecordingResult) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
        recordingButton.title = "Record"
        recordingButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        recordingButton.bezelColor = .systemRed
        updateInterface()
        let size = ByteCountFormatter.string(fromByteCount: Int64(result.bytesWritten), countStyle: .file)
        appendLog("Recording saved: \(result.url.path) · \(MediaFileNamer.durationStamp(result.duration)) · \(size)")
        if let error = result.errorDescription {
            showMediaAlert("The partial recording was saved, but an error occurred: \(error)")
        }
    }

    @objc private func takePicture() {
        guard videoRunning, let image = hudView.videoView.latestFrameImage() else {
            showMediaAlert("No decoded video frame is available yet.")
            return
        }
        let format = PictureFileFormat(rawValue: pictureFormatPopup.selectedTag()) ?? .png
        do {
            try FileManager.default.createDirectory(at: mediaDirectoryURL, withIntermediateDirectories: true)
        } catch {
            showMediaAlert("Could not create the media directory: \(error.localizedDescription)")
            return
        }
        let url = MediaFileNamer.pictureURL(directory: mediaDirectoryURL, format: format)
        pictureWriteInFlight = true
        pictureButton.title = "Saving…"
        updateInterface()
        pictureWriteGroup.enter()
        let writeGroup = pictureWriteGroup
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { writeGroup.leave() }
            let result = Result { try StillImageWriter.write(image, to: url, format: format) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pictureWriteInFlight = false
                self.pictureButton.title = "Picture"
                self.updateInterface()
                switch result {
                case .success:
                    self.appendLog("Picture saved: \(url.path)")
                case .failure(let error):
                    self.appendLog("Picture save failed: \(error.localizedDescription)")
                    self.showMediaAlert("Could not save the picture: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showMediaAlert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Media capture"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func prepareForTermination() {
        toolInstaller.cancel()
        sc2DriverTelnet.stop()
        recordingTimer?.invalidate()
        recordingTimer = nil
        streamRecorder.stopAndWait()
        _ = pictureWriteGroup.wait(timeout: .now() + 5)
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let storage = console.textStorage else { return }
        storage.append(NSAttributedString(
            string: line,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.74)]
        ))
        let maximumConsoleLength = 200_000
        if storage.length > maximumConsoleLength {
            storage.deleteCharacters(in: NSRange(
                location: 0,
                length: storage.length - maximumConsoleLength
            ))
        }
        console.scrollToEndOfDocument(nil)
    }

    private func dbm(_ value: Int?) -> String { value.map { "\($0) dBm" } ?? "—" }
    private func number(_ value: Int?, _ suffix: String) -> String { value.map { "\($0)\(suffix)" } ?? "—" }
    private func degrees(_ value: Double?) -> String {
        value.map { String(format: "%.1f°", $0 * 180 / .pi) } ?? "—"
    }
}
