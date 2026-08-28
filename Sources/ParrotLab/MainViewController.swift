import AppKit
import UniformTypeIdentifiers

final class MainViewController: NSViewController {
    private enum SC2DriverInstallPhase {
        case idle
        case discovering
        case preparingFTP
        case uploading
        case installing
        case rebooting
    }

    private enum SC2DiscoveryPurpose {
        case manual
        case driverInstall
        case rfPowerProfile
    }

    private enum RFPowerMode {
        case enableTested
        case restoreStock

        var profileArgument: String {
            switch self {
            case .enableTested: return "epa2_pd16_m80"
            case .restoreStock: return "stock"
            }
        }

        var progressLabel: String {
            switch self {
            case .enableTested: return "ENABLING RF MOD"
            case .restoreStock: return "RESTORING RF"
            }
        }

        var completionTitle: String {
            switch self {
            case .enableTested: return "RF power profile enabled"
            case .restoreStock: return "Stock RF profile restored"
            }
        }
    }

    private enum RFPowerPhase {
        case idle
        case discovering
        case uploadingSC2
        case uploadingBebop
        case applyingSC2
        case applyingBebop
        case queueingBebopReboot
        case queueingSC2Reboot
    }

    private enum QueuedDragonOperation {
        case launch(String)
        case restore
    }

    private struct DragonControlEndpoint: Equatable {
        let host: String
        let port: UInt16
        let label: String
    }

    private static let customDragonModeTag = 100
    private let parser = SC2TelemetryParser()
    private var arsdkTelemetryReducer = ARSDKTelemetryReducer()
    private let telnet = TelnetClient()
    private let dragonControlTelnet = TelnetClient()
    private let bebopSystemTelnet = TelnetClient()
    private let sc2DiscoveryTelnet = TelnetClient()
    private let sc2DriverTelnet = TelnetClient()
    private let rfPowerSC2Telnet = TelnetClient()
    private let rfPowerBebopTelnet = TelnetClient()
    private let sc2USBDiscovery = SC2USBDiscovery()
    private let restreamProbe = RestreamProbe()
    private let rtpReceiver = RTPH264Receiver()
    private let streamRecorder = ProcessedH264Recorder()
    private let rawArchiveRecorder = H264StreamRecorder()
    private let mp4Converter = H264MP4Converter()
    private let arsdkClient = ARSDKCommandClient()
    private lazy var droneFisheyeCapture = DroneFisheyeCaptureController(client: arsdkClient)
    private let droneMediaFTP = DroneMediaFTP()
    private let toolInstaller = BebopToolInstaller()
    private var snapshot = TelemetrySnapshot()
    private var arsdkRefreshTimer: Timer?
    private var arsdkSessionWanted = false
    private var arsdkConnectionInFlight = false
    private var arsdkConnected = false
    private var lastARSDKTelemetryAt: Date?
    private var telemetryFreshnessTimer: Timer?
    private var lastFlightStateUpdate: Date?
    private var videoRunning = false
    private var videoStatus = "Restream idle"
    private var videoFormatStatus = "FORMAT waiting"
    private var videoCodedFormatStatus = "CODED waiting"
    private var videoMetadataPresence = VideoMetadataPresence()
    private var mediaDirectoryURL = MediaFileNamer.defaultDirectory
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?
    private var rawH264ArchiveEnabled = UserDefaults.standard.bool(
        forKey: "ParrotLab.ArchiveRawIncomingH264"
    )
    private var calibratedRollingShutterEnabled = UserDefaults.standard.bool(
        forKey: "ParrotLab.Calibrated471RollingShutterV2"
    )
    private var developerVideoDiagnosticsEnabled = UserDefaults.standard.bool(
        forKey: "ParrotLab.DeveloperVideoDiagnostics"
    )
    private lazy var temporalReconstructionConfiguration = TemporalReconstructionConfiguration(
        isEnabled: UserDefaults.standard.bool(forKey: "ParrotLab.Temporal.Enabled"),
        historyWeight: Self.storedDouble("ParrotLab.Temporal.HistoryWeight", fallback: 0.58),
        ghostRejection: Self.storedDouble("ParrotLab.Temporal.GhostRejection", fallback: 0.68),
        consistencyThresholdPixels: Self.storedDouble("ParrotLab.Temporal.ConsistencyPixels", fallback: 2.0),
        latencyBudgetMilliseconds: Self.storedDouble("ParrotLab.Temporal.LatencyBudgetMs", fallback: 65.0),
        usesBidirectionalFlow: UserDefaults.standard.object(forKey: "ParrotLab.Temporal.Bidirectional") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "ParrotLab.Temporal.Bidirectional")
    )
    private var processedRecordingStats: ProcessedRecordingStats?
    private var videoConversionInFlight = false
    private var videoConversionProgressAlert: NSAlert?
    private var pictureWriteInFlight = false
    private var dronePhotoInFlight = false
    private var dronePhotoBaseline = Set<DroneRemotePhoto>()
    private let pictureWriteGroup = DispatchGroup()
    private var dragonCommandInFlight = false
    private var dragonCommandConnected = false
    private var dragonCommandSucceeded = false
    private var dragonCommandResponded = false
    private var dragonCommandCanRetryAfterNoResult = false
    private var pendingDragonCommand: String?
    private var pendingDragonEndpoints: [DragonControlEndpoint] = []
    private var activeDragonEndpoint: DragonControlEndpoint?
    private var dragonCommandTimeoutTimer: Timer?
    private var pendingDragonLaunchSummary: String?
    private var queuedDragonOperation: QueuedDragonOperation?
    private var queuedDragonTelemetryNotBefore: Date?
    private var pendingDragonInstall = false
    private var toolUploadInFlight = false
    private var persistentTelnetInstallInFlight = false
    private var persistentTelnetConnected = false
    private var persistentTelnetTimeoutTimer: Timer?
    private var sc2DriverInstallInFlight = false
    private var sc2DriverTelnetConnected = false
    private var sc2DriverInstallSucceeded = false
    private var pendingSC2DriverHost: String?
    private var sc2DriverInstallPhase = SC2DriverInstallPhase.idle
    private var sc2DriverPreparationTimeoutTimer: Timer?
    private var sc2DriverDiscoveryAttempted = false
    private var sc2DiscoveryInFlight = false
    private var sc2DiscoveryPurpose: SC2DiscoveryPurpose?
    private var sc2DiscoveryTelnetConnected = false
    private var sc2DiscoveryResult: String?
    private var sc2DiscoveryTimeoutTimer: Timer?
    private var rfPowerOperationInFlight = false
    private var rfPowerMode: RFPowerMode?
    private var rfPowerPhase = RFPowerPhase.idle
    private var rfPowerSC2Host: String?
    private var rfPowerSC2Connected = false
    private var rfPowerBebopConnected = false
    private var rfPowerStepSucceeded = false
    private var rfPowerDiscoveryAttempted = false
    private var rfPowerTimeoutTimer: Timer?
    private var dragonRuntimeStatus = "SC2 OFFLINE"

    private static let mediaDirectoryPreferenceKey = "ParrotLabMediaDirectory"
    private static let mp4QualityPreferenceKey = "ParrotLabMP4ConversionQuality"
    private static let cachedSC2HostPreferenceKey = "ParrotLabCachedSC2Host"
    private static let cachedSC2USBHostPreferenceKey = "ParrotLabCachedSC2USBHost"

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
    private let droneFisheyeButton = NSButton(title: "Drone 4K Fisheye", target: nil, action: nil)
    private let dragonResolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dragonBitrateSlider = NSSlider(value: 12_000, minValue: 1_000, maxValue: 16_000, target: nil, action: nil)
    private let dragonBitrateValue = NSTextField(labelWithString: "12.0 Mbps")
    private let dragonLockRateButton = NSButton(checkboxWithTitle: "Lock bitrate", target: nil, action: nil)
    private let dragonCustomArgumentsLabel = NSTextField(labelWithString: "CUSTOM ARGUMENTS")
    private let dragonCustomArgumentsField = NSTextField(
        string: "-V 2 -f 30 -R gpu -S 0 -q 12000 -o"
    )
    private let dragonApplyButton = NSButton(title: "Apply profile", target: nil, action: nil)
    private let dragonRestoreButton = NSButton(title: "Restore stock", target: nil, action: nil)
    private let dragonStatusLabel = NSTextField(labelWithString: "SC2 OFFLINE")
    private let statusLabel = NSTextField(labelWithString: "DISCONNECTED")
    private let rfLabel = NSTextField(labelWithString: "Waiting for RF telemetry")
    private let flightLabel = NSTextField(labelWithString: "Waiting for flight telemetry")
    private let navigationLabel = NSTextField(labelWithString: "Waiting for ARSDK navigation")
    private let healthLabel = NSTextField(labelWithString: "Waiting for controller health")
    private let videoLabel = NSTextField(labelWithString: "Restream idle")
    private let console = NSTextView(frame: .zero)

    override func loadView() {
        if let savedPath = UserDefaults.standard.string(forKey: Self.mediaDirectoryPreferenceKey),
           !savedPath.isEmpty {
            mediaDirectoryURL = URL(fileURLWithPath: savedPath, isDirectory: true)
        }
        let savedUSBHost = UserDefaults.standard.string(forKey: Self.cachedSC2USBHostPreferenceKey) ?? ""
        let savedBridgeHost = UserDefaults.standard.string(forKey: Self.cachedSC2HostPreferenceKey) ?? ""
        if Self.isValidIPv4Host(savedUSBHost) {
            hostField.stringValue = savedUSBHost
        } else if Self.isValidIPv4Host(savedBridgeHost) {
            hostField.stringValue = savedBridgeHost
        }
        view = LabBackgroundView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        view.appearance = NSAppearance(named: .darkAqua)
        buildInterface()
        wireDataSources()
        applyRollingShutterConfiguration()
        applyTemporalReconstructionConfiguration()
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
        let version = NSTextField(labelWithString: "V1.3")
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
        recordingButton.toolTip = "Record Parrot Lab's processed GPU output through the bounded VideoToolbox encoder"
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
        pictureButton.toolTip = "Save the latest processed output frame at its selected resolution, without the HUD overlay"
        pictureButton.widthAnchor.constraint(equalToConstant: 82).isActive = true
        mediaControls.addArrangedSubview(pictureButton)
        styleButton(droneFisheyeButton, action: #selector(captureDroneFisheye), symbol: "camera.aperture")
        droneFisheyeButton.toolTip = "Ask stock Dragon for its original full-sensor fisheye JPEG, then download it unchanged"
        droneFisheyeButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        mediaControls.addArrangedSubview(droneFisheyeButton)
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
        videoModePopup.toolTip = "Compatibility preserves the proven decoder. Both 900p modes use the firmware-matched modified Dragon and capture frame-synchronized metadata."
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

        let document = LabFlippedView(frame: .zero)
        document.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.addArrangedSubview(buildDragonCard())
        stack.addArrangedSubview(card(title: "VIDEO", body: videoLabel, maximumLines: 24))
        stack.addArrangedSubview(card(title: "RF LINK", body: rfLabel))
        stack.addArrangedSubview(card(title: "FLIGHT", body: flightLabel))
        stack.addArrangedSubview(card(title: "ARSDK NAVIGATION", body: navigationLabel))
        stack.addArrangedSubview(card(title: "SC2 HEALTH", body: healthLabel))

        let notice = NSTextField(wrappingLabelWithString: "Dragon video profiles change runtime options only. They never write the persistent Dragon property or replace the stock system binary.")
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
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
        ])
        return scroll
    }

    private func card(title: String, body: NSTextField, maximumLines: Int = 8) -> NSView {
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
        body.maximumNumberOfLines = maximumLines
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
        let heading = NSTextField(labelWithString: "DRAGON VIDEO")
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
        dragonResolutionPopup.addItem(withTitle: "Custom · modified binary")
        dragonResolutionPopup.lastItem?.tag = Self.customDragonModeTag
        dragonResolutionPopup.selectItem(withTag: DragonVideoResolution.temporal900.rawValue)
        dragonResolutionPopup.target = self
        dragonResolutionPopup.action = #selector(dragonResolutionChanged)
        dragonResolutionPopup.controlSize = .regular
        dragonResolutionPopup.font = .systemFont(ofSize: 12, weight: .medium)
        dragonResolutionPopup.widthAnchor.constraint(equalToConstant: 274).isActive = true
        stack.addArrangedSubview(dragonResolutionPopup)

        dragonCustomArgumentsLabel.font = .systemFont(ofSize: 9.5, weight: .bold)
        dragonCustomArgumentsLabel.textColor = LabVisualStyle.mutedText
        dragonCustomArgumentsLabel.alignment = .center
        dragonCustomArgumentsLabel.isHidden = true
        stack.addArrangedSubview(dragonCustomArgumentsLabel)

        styleTextField(dragonCustomArgumentsField, width: 274)
        dragonCustomArgumentsField.alignment = .left
        dragonCustomArgumentsField.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        dragonCustomArgumentsField.placeholderString = "-V 2 -f 30 -R gpu -S 0 …"
        dragonCustomArgumentsField.toolTip = "Whitespace-separated arguments for the uploaded modified Dragon binary. Shell metacharacters are rejected."
        dragonCustomArgumentsField.isHidden = true
        stack.addArrangedSubview(dragonCustomArgumentsField)

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

        let warning = NSTextField(wrappingLabelWithString: "900p Temporal has no flight-state interlock. Other profiles require LANDED. Every restart briefly drops the SC2 link, video and telemetry.")
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
                self.cacheSC2Host(host)
                self.startARSDKTelemetry(host: host)
            case .connecting:
                self.statusLabel.stringValue = "CONNECTING"
                self.statusLabel.textColor = .systemYellow
            case .failed(let message):
                self.stopARSDKTelemetry()
                self.stopTelemetryFreshnessTimer()
                self.snapshot.connectionLabel = "Disconnected"
                self.statusLabel.stringValue = "FAILED"
                self.statusLabel.textColor = .systemRed
                self.connectButton.title = "Connect SC2"
                self.dragonRuntimeStatus = "SC2 OFFLINE"
                self.appendLog("Connection failed: \(message)")
            case .stopped, .idle:
                self.stopARSDKTelemetry()
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
        arsdkClient.onTelemetryEvent = { [weak self] event in
            self?.consumeARSDKTelemetry(event)
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
        bebopSystemTelnet.onLine = { [weak self] line in
            self?.handlePersistentTelnetLine(line)
        }
        bebopSystemTelnet.onDebug = { [weak self] message in
            self?.appendLog("Persistent Telnet: \(message)")
        }
        bebopSystemTelnet.onState = { [weak self] state in
            self?.handlePersistentTelnetState(state)
        }
        sc2DiscoveryTelnet.onLine = { [weak self] line in
            self?.handleSC2DiscoveryLine(line)
        }
        sc2DiscoveryTelnet.onDebug = { [weak self] message in
            self?.appendLog("SC2 discovery: \(message)")
        }
        sc2DiscoveryTelnet.onState = { [weak self] state in
            self?.handleSC2DiscoveryState(state)
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
        rfPowerSC2Telnet.onLine = { [weak self] line in
            self?.handleRFPowerLine(line, device: "SkyController 2")
        }
        rfPowerSC2Telnet.onDebug = { [weak self] message in
            self?.appendLog("RF power SC2: \(message)")
        }
        rfPowerSC2Telnet.onState = { [weak self] state in
            self?.handleRFPowerTelnetState(state, device: "SkyController 2")
        }
        rfPowerBebopTelnet.onLine = { [weak self] line in
            self?.handleRFPowerLine(line, device: "Bebop 2")
        }
        rfPowerBebopTelnet.onDebug = { [weak self] message in
            self?.appendLog("RF power Bebop: \(message)")
        }
        rfPowerBebopTelnet.onState = { [weak self] state in
            self?.handleRFPowerTelnetState(state, device: "Bebop 2")
        }
        toolInstaller.onProgress = { [weak self] message in
            guard let self else { return }
            self.appendLog("FTP: \(message)")
            if self.pendingDragonInstall {
                self.dragonRuntimeStatus = message.uppercased()
                self.updateInterface()
            }
        }
        sc2USBDiscovery.onProgress = { [weak self] message in
            self?.appendLog(message)
        }
        restreamProbe.onDebug = { [weak self] message in self?.appendLog(message) }
        rtpReceiver.onDebug = { [weak self] message in self?.appendLog(message) }
        hudView.videoView.onDebug = { [weak self] message in self?.appendLog(message) }
        hudView.videoView.onFormat = { [weak self] width, height in
            guard let self else { return }
            self.videoFormatStatus = "FORMAT \(width)x\(height)"
            self.updateInterface()
        }
        hudView.videoView.onCodedFormat = { [weak self] width, height in
            guard let self else { return }
            self.videoCodedFormatStatus = "CODED \(width)x\(height)"
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
            self?.rawArchiveRecorder.observe(accessUnit)
        }
        hudView.videoView.onProcessedFrame = { [weak self] frame in
            self?.streamRecorder.observe(frame)
        }
        streamRecorder.onFinished = { [weak self] result in
            self?.recordingFinished(result)
        }
        streamRecorder.onStats = { [weak self] stats in
            self?.processedRecordingStats = stats
            self?.updateInterface()
        }
        rawArchiveRecorder.onFinished = { [weak self] result in
            guard let self else { return }
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(result.bytesWritten),
                countStyle: .file
            )
            self.appendLog("Untouched diagnostic H.264 archive saved: \(result.url.path) · \(size)")
            if let error = result.errorDescription {
                self.appendLog("Raw archive finished with an error: \(error)")
            }
        }
        mp4Converter.onCompletion = { [weak self] result in
            self?.mp4ConversionFinished(result)
        }
        droneFisheyeCapture.onLog = { [weak self] message in
            self?.appendLog("ARSDK: \(message)")
        }
        droneFisheyeCapture.onStatus = { [weak self] status in
            guard let self else { return }
            self.droneFisheyeButton.title = status
            self.updateInterface()
        }
        droneFisheyeCapture.onCompletion = { [weak self] result in
            self?.droneFisheyeCommandFinished(result)
        }
        hudView.videoView.onFrameReady = { [weak self] in
            self?.updateInterface()
        }
        hudView.videoView.onPipelineStats = { [weak self] stats in
            guard let self else { return }
            self.snapshot.videoDecodedFPS = stats.decodedFPS
            self.snapshot.videoDisplayRefreshFPS = stats.displayRefreshFPS
            self.snapshot.videoProcessedFPS = stats.processedFPS
            self.snapshot.videoProcessingDroppedFrames = stats.processingDroppedFrames
            self.snapshot.videoProcessingLatencyMs = stats.processingLatencyMilliseconds
            self.snapshot.videoProcessedWidth = stats.processedWidth
            self.snapshot.videoProcessedHeight = stats.processedHeight
            self.snapshot.videoTemporalHistoryDepth = stats.temporalHistoryDepth
            self.snapshot.videoTemporalHistoryAgeMs = stats.temporalHistoryAgeMilliseconds
            self.snapshot.videoTemporalMotionAvailable = stats.temporalMotionAvailable
            self.snapshot.videoTemporalMotionConfidence = stats.temporalMotionConfidence
            self.snapshot.videoTemporalReprojectionStatus = stats.temporalReprojectionStatus
            self.snapshot.videoTemporalFlowLatencyMs = stats.temporalFlowLatencyMilliseconds
            self.snapshot.videoTemporalHistoryUsed = stats.temporalHistoryUsed
            self.snapshot.videoLastRTPTimestamp = stats.lastRTPTimestamp
            self.snapshot.videoMotionAssociationOffsetMs = stats.motionAssociationOffsetMilliseconds
            self.snapshot.videoCameraCalibrationStatus = stats.cameraCalibrationStatus
            self.snapshot.videoCameraReadoutStatus = stats.cameraReadoutStatus
            self.snapshot.videoRollingShutterStatus = stats.rollingShutterStatus
            self.updateInterface()
        }
        rtpReceiver.onStats = { [weak self] stats in
            guard let self else { return }
            self.snapshot.videoBitrateKbps = stats.bitrateKbps
            self.snapshot.videoEncodedAUFPS = stats.encodedAUFPS
            self.snapshot.videoUniqueTimestampFPS = stats.uniqueTimestampFPS
            self.snapshot.videoPackets = stats.packets
            self.snapshot.videoDuplicatePackets = stats.duplicatePackets
            self.snapshot.videoPacketsLost = stats.packetsLost
            self.snapshot.videoJitterMs = stats.jitterMs
            self.updateInterface()
        }
    }

    @objc private func toggleConnection() {
        if connectButton.title == "Disconnect" {
            stopARSDKTelemetry()
            telnet.stop()
            return
        }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        parser.reset()
        arsdkTelemetryReducer.reset()
        snapshot = TelemetrySnapshot()
        lastFlightStateUpdate = nil
        updateInterface()
        appendLog("Connecting to SC2 Telnet at \(host):23")
        telnet.connect(host: host)
    }

    private func startARSDKTelemetry(host: String, forceReconnect: Bool = false) {
        guard !host.isEmpty, connectButton.title == "Disconnect" else { return }
        arsdkSessionWanted = true
        if forceReconnect {
            arsdkClient.stop()
            arsdkConnected = false
            arsdkConnectionInFlight = false
        }
        guard !arsdkConnected, !arsdkConnectionInFlight else { return }

        arsdkConnectionInFlight = true
        appendLog("Opening persistent ARSDK telemetry through SC2 \(host):44444")
        arsdkClient.connect(host: host) { [weak self] result in
            guard let self else { return }
            self.arsdkConnectionInFlight = false
            guard self.arsdkSessionWanted, self.connectButton.title == "Disconnect" else {
                self.arsdkClient.stop()
                return
            }
            switch result {
            case .success:
                self.arsdkConnected = true
                self.lastARSDKTelemetryAt = Date()
                self.appendLog("ARSDK telemetry connected; requesting all drone and controller states")
                self.arsdkClient.sendRequestAllStates()
                self.arsdkClient.sendRequestSkyControllerAllStates()
                self.startARSDKRefreshTimer(host: host)
            case .failure(let error):
                self.arsdkConnected = false
                self.appendLog("ARSDK telemetry unavailable: \(error.localizedDescription)")
                self.scheduleARSDKReconnect(host: host)
            }
        }
    }

    private func startARSDKRefreshTimer(host: String) {
        arsdkRefreshTimer?.invalidate()
        arsdkRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.arsdkSessionWanted,
                  self.connectButton.title == "Disconnect" else { return }
            if !self.dronePhotoInFlight,
               let last = self.lastARSDKTelemetryAt,
               Date().timeIntervalSince(last) > 12 {
                self.appendLog("ARSDK telemetry became stale; reconnecting through SC2")
                self.startARSDKTelemetry(host: host, forceReconnect: true)
            } else {
                self.arsdkClient.sendRequestAllStates()
                self.arsdkClient.sendRequestSkyControllerAllStates()
            }
        }
    }

    private func scheduleARSDKReconnect(host: String) {
        arsdkRefreshTimer?.invalidate()
        arsdkRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.startARSDKTelemetry(host: host)
        }
    }

    private func stopARSDKTelemetry() {
        arsdkSessionWanted = false
        arsdkRefreshTimer?.invalidate()
        arsdkRefreshTimer = nil
        arsdkConnectionInFlight = false
        arsdkConnected = false
        lastARSDKTelemetryAt = nil
        arsdkClient.stop()
    }

    private func consumeARSDKTelemetry(_ event: ARSDKTelemetryEvent) {
        guard arsdkTelemetryReducer.consume(event, into: &snapshot) else { return }
        lastARSDKTelemetryAt = Date()
        if case .flyingState = event {
            handleFreshFlightState()
        } else if snapshot.flightState != "UNKNOWN" {
            lastFlightStateUpdate = Date()
        }
        updateInterface()
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
        applyRollingShutterConfiguration()
        videoFormatStatus = "FORMAT waiting"
        videoMetadataPresence = VideoMetadataPresence()
        videoStatus = "Restream idle"
        appendLog("Video mode selected: \(mode.menuTitle)")
        if let profile = mode.expectedDragonProfile {
            appendLog("\(mode.menuTitle) expects Dragon profile: \(profile)")
            appendLog("Dragon Video can apply the matching non-persistent runtime profile while landed")
        }
        updateInterface()
    }

    private var selectedDragonResolution: DragonVideoResolution? {
        DragonVideoResolution(rawValue: dragonResolutionPopup.selectedItem?.tag ?? -1)
    }

    private var customDragonModeSelected: Bool {
        dragonResolutionPopup.selectedItem?.tag == Self.customDragonModeTag
    }

    private var temporalDragonModeSelected: Bool {
        selectedDragonResolution == .temporal900
    }

    @objc private func dragonResolutionChanged() {
        if let resolution = selectedDragonResolution {
            dragonBitrateSlider.integerValue = resolution.recommendedBitrateKbps
        }
        updateDragonBitrateLabel()
        updateInterface()
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
        guard canApplySelectedDragonProfile else {
            showDragonAlert(
                title: "Dragon controls are locked",
                message: temporalDragonModeSelected
                    ? "Connect to the SC2 before applying 900p Temporal."
                    : "Connect to the SC2 and wait until live telemetry explicitly reports LANDED."
            )
            return
        }
        if customDragonModeSelected {
            applyCustomDragonArguments()
            return
        }
        guard let resolution = selectedDragonResolution,
              let profile = DragonVideoProfile(
                resolution: resolution,
                bitrateKbps: dragonBitrateSlider.integerValue,
                locksBitrate: dragonLockRateButton.state == .on
              ) else {
            appendLog("Dragon profile rejected: bitrate must be 1–16 Mbps in 0.5 Mbps steps")
            return
        }

        if videoRunning { startVideo() }
        videoModePopup.selectItem(withTag: profile.resolution.receiverMode.rawValue)
        hudView.videoView.receiveMode = profile.resolution.receiverMode
        videoFormatStatus = "FORMAT waiting"
        videoMetadataPresence = VideoMetadataPresence()
        queuedDragonOperation = nil
        queuedDragonTelemetryNotBefore = nil
        pendingDragonLaunchSummary = profile.launchSummary
        runDragonCommand(profile.applyCommand, status: "APPLYING · \(profile.launchSummary)")
    }

    private func applyCustomDragonArguments() {
        let launch: DragonCustomLaunch
        do {
            launch = try DragonCustomLaunch(arguments: dragonCustomArgumentsField.stringValue)
        } catch {
            showDragonAlert(
                title: "Custom arguments rejected",
                message: error.localizedDescription
            )
            appendLog("Custom Dragon arguments rejected: \(error.localizedDescription)")
            return
        }

        if videoRunning { startVideo() }
        queuedDragonOperation = nil
        queuedDragonTelemetryNotBefore = nil
        pendingDragonLaunchSummary = "CUSTOM MODIFIED"
        runDragonCommand(
            launch.applyCommand,
            status: "APPLYING · CUSTOM MODIFIED",
            logMessage: "Queueing modified Dragon with validated custom arguments: \(launch.arguments)"
        )
    }

    @objc private func restoreStockDragon() {
        guard canAdjustDragon else {
            showDragonAlert(
                title: "Stock restore is locked",
                message: "Connect to the SC2 and wait until live telemetry explicitly reports LANDED."
            )
            return
        }

        if videoRunning { startVideo() }
        queuedDragonOperation = nil
        queuedDragonTelemetryNotBefore = nil
        pendingDragonLaunchSummary = nil
        runDragonCommand(DragonVideoProfile.restoreCommand, status: "RESTORING STOCK")
    }

    func installDragonLabOnBebop2() {
        guard !toolUploadInFlight, !persistentTelnetInstallInFlight else {
            showToolAlert(title: "Upload already running", message: "Wait for the current FTP transfer to finish.")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Install or update Dragon Lab on Bebop 2?"
        alert.informativeText = "Parrot Lab will upload the 900p Dragon binaries for Bebop firmware 4.4.2 and 4.7.1 plus the runtime helper through anonymous FTP to 192.168.42.1:/internal_000. Every file is downloaded for SHA-256 verification and marked executable. At launch, the helper reads the installed firmware version and selects only its matching binary. It will not replace /usr/bin/dragon-prog or restart Dragon."
        alert.addButton(withTitle: "Install / Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        toolUploadInFlight = true
        dragonCommandInFlight = true
        dragonCommandConnected = false
        dragonCommandSucceeded = false
        pendingDragonLaunchSummary = nil
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
                    logMessage: "FTP transfer verified; marking the three app-owned files executable and checking their MD5 digests",
                    canRetryAfterNoResult: true
                )
            case .failure(let error):
                self.dragonRuntimeStatus = "ERROR · FTP INSTALL"
                self.appendLog("Dragon Lab installation failed: \(error.localizedDescription)")
                self.showToolAlert(title: "Dragon Lab was not installed", message: error.localizedDescription)
                self.finishDragonCommand()
            }
        }
    }

    func enablePersistentTelnetOnBebop2() {
        guard !toolUploadInFlight, !dragonCommandInFlight,
              !persistentTelnetInstallInFlight, !sc2DriverInstallInFlight else {
            showToolAlert(
                title: "Tool operation already running",
                message: "Wait for the current transfer or device operation to finish."
            )
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Permanently enable root Telnet on this Bebop 2?"
        alert.informativeText = "This one-time operation requires Telnet to be manually enabled now. It supports confirmed Bebop 2 firmware 4.4.2 and 4.7.1. Because the system partition is full, Parrot Lab first backs up /usr/sbin/tcpdump to internal_000 and replaces it with a symlink. It then briefly remounts the system partition writable and adds /bin/usbnetwork.sh immediately before exit 0 in /etc/init.d/rcS. Future boots will start the stock developer network services, including no-password root Telnet and ADB.\n\nAnyone on the aircraft network will have root shell access. Use this only on a trusted private network. No reboot is performed."
        alert.addButton(withTitle: "Enable Permanently")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        toolUploadInFlight = true
        persistentTelnetInstallInFlight = true
        persistentTelnetConnected = false
        dragonRuntimeStatus = "ENABLING PERSISTENT TELNET"
        updateInterface()
        appendLog("Uploading the persistent Telnet installer to Bebop 2 FTP 192.168.42.1:21/internal_000")

        toolInstaller.install(.persistentTelnet) { [weak self] result in
            guard let self else { return }
            self.toolUploadInFlight = false
            switch result {
            case .success(let install):
                self.appendVerifiedAssets(install)
                guard let command = self.persistentTelnetInstallCommand(install) else {
                    self.finishPersistentTelnetInstall(
                        success: false,
                        message: "The persistent Telnet installer manifest is incomplete."
                    )
                    return
                }
                self.appendLog("FTP verification passed; connecting directly to Bebop Telnet at 192.168.42.1:23")
                self.bebopSystemTelnet.connect(
                    host: BebopToolPackage.ftpHost,
                    port: 23,
                    startupCommand: command
                )
                self.persistentTelnetTimeoutTimer = Timer.scheduledTimer(
                    withTimeInterval: 15,
                    repeats: false
                ) { [weak self] _ in
                    guard let self, self.persistentTelnetInstallInFlight else { return }
                    self.finishPersistentTelnetInstall(
                        success: false,
                        message: "Bebop Telnet did not confirm installation within 15 seconds. Manually enable Telnet, stay connected to the aircraft network, and try again."
                    )
                }
            case .failure(let error):
                self.finishPersistentTelnetInstall(success: false, message: error.localizedDescription)
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

    func configureRFPowerMod() {
        guard !toolUploadInFlight, !dragonCommandInFlight,
              !persistentTelnetInstallInFlight, !sc2DriverInstallInFlight,
              !sc2DiscoveryInFlight, !rfPowerOperationInFlight else {
            showToolAlert(
                title: "Tool operation already running",
                message: "Wait for the current transfer or device operation to finish."
            )
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Configure the RF power profile on both devices?"
        alert.informativeText = "Enable applies the tested EPA2 / PD16 / MAXP80 profile to both the SkyController 2 and Bebop 2. It was stable in field testing, but it is not laboratory-certified for EVM, unwanted emissions, or legal EIRP; use it only where permitted.\n\nRestore Stock uses each device's preserved original NVM baseline when available, otherwise its device-specific stock values. Both choices update RF Lab first, create verified backups, and write only the active NVM file.\n\nKeep the aircraft safely landed. When both writes verify, Parrot Lab will reboot the SC2 first and the Bebop 2 afterward, so all links will temporarily drop."
        alert.addButton(withTitle: "Enable Tested Profile")
        alert.addButton(withTitle: "Restore Stock")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        let mode: RFPowerMode
        switch response {
        case .alertFirstButtonReturn: mode = .enableTested
        case .alertSecondButtonReturn: mode = .restoreStock
        default: return
        }

        if videoRunning { startVideo() }
        let enteredHost = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cachedHost = UserDefaults.standard.string(forKey: Self.cachedSC2HostPreferenceKey) ?? ""
        let cachedUSBHost = UserDefaults.standard.string(forKey: Self.cachedSC2USBHostPreferenceKey) ?? ""
        let candidateHost: String?
        if connectButton.title == "Disconnect", Self.isValidIPv4Host(enteredHost) {
            candidateHost = enteredHost
        } else if Self.isValidIPv4Host(cachedUSBHost) {
            candidateHost = cachedUSBHost
        } else if Self.isValidIPv4Host(cachedHost) {
            candidateHost = cachedHost
        } else {
            candidateHost = nil
        }

        toolUploadInFlight = true
        rfPowerOperationInFlight = true
        rfPowerMode = mode
        rfPowerPhase = .idle
        rfPowerSC2Host = candidateHost
        rfPowerSC2Connected = false
        rfPowerBebopConnected = false
        rfPowerStepSucceeded = false
        rfPowerDiscoveryAttempted = false
        statusLabel.stringValue = mode.progressLabel
        statusLabel.textColor = .systemYellow
        updateInterface()
        appendLog("RF power workflow authorized without a flight-state interlock")

        if let candidateHost {
            appendLog("Updating RF Lab on the entered/cached SC2 address \(candidateHost)")
            beginRFPowerSC2Upload(host: candidateHost)
        } else {
            appendLog("No valid cached bridge-side SC2 address; discovering it through the Bebop")
            rfPowerDiscoveryAttempted = true
            rfPowerPhase = .discovering
            beginSC2Discovery(purpose: .rfPowerProfile)
        }
    }

    @discardableResult
    func setVideoEnhancement(rawValue: Int) -> Bool {
        guard let preset = VideoEnhancementPreset(rawValue: rawValue) else { return false }
        guard !streamRecorder.isActive else {
            showMediaAlert("Finish the current recording before changing the processed-video pipeline.")
            return false
        }
        hudView.videoView.enhancementPreset = preset
        appendLog("Mac image enhancement changed to \(preset.menuTitle)")
        updateInterface()
        return true
    }

    @discardableResult
    func setMetalFXSpatialScaling(rawValue: Int) -> Bool {
        guard let mode = VideoSpatialScalingMode(rawValue: rawValue) else { return false }
        guard !streamRecorder.isActive else {
            showMediaAlert("Finish the current recording before changing its processed output resolution.")
            return false
        }
        if mode.usesMetalFX && !hudView.videoView.isMetalFXSpatialScalingSupported {
            showMediaAlert("Apple MetalFX Spatial is not supported by this Mac.")
            appendLog("MetalFX Spatial selection rejected: unsupported GPU")
            return false
        }
        hudView.videoView.spatialScalingMode = mode
        appendLog("Mac spatial scaling changed to \(mode.menuTitle)")
        updateInterface()
        return true
    }

    func setRawH264ArchiveEnabled(_ enabled: Bool) {
        guard !streamRecorder.isActive else {
            showMediaAlert("Finish the current recording before changing the diagnostic raw archive option.")
            return
        }
        rawH264ArchiveEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ParrotLab.ArchiveRawIncomingH264")
        appendLog(enabled
            ? "Untouched incoming H.264 developer archive armed for future recordings"
            : "Untouched incoming H.264 developer archive disabled")
        updateInterface()
    }

    var isRawH264ArchiveEnabled: Bool { rawH264ArchiveEnabled }

    @discardableResult
    func setCalibratedRollingShutterEnabled(_ enabled: Bool) -> Bool {
        calibratedRollingShutterEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ParrotLab.Calibrated471RollingShutterV2")
        applyRollingShutterConfiguration()
        appendLog(enabled
            ? "Calibrated 4.7.1 900p rolling-shutter correction enabled for the stabilized 900p Temporal profile"
            : "Calibrated rolling-shutter correction disabled")
        updateInterface()
        return true
    }

    var isCalibratedRollingShutterEnabled: Bool { calibratedRollingShutterEnabled }

    func setDeveloperVideoDiagnosticsEnabled(_ enabled: Bool) {
        developerVideoDiagnosticsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ParrotLab.DeveloperVideoDiagnostics")
        appendLog(enabled
            ? "Detailed developer video diagnostics enabled"
            : "Detailed developer video diagnostics hidden")
        updateInterface()
    }

    var isDeveloperVideoDiagnosticsEnabled: Bool { developerVideoDiagnosticsEnabled }

    var currentTemporalReconstructionConfiguration: TemporalReconstructionConfiguration {
        temporalReconstructionConfiguration
    }

    func setTemporalReconstructionConfiguration(_ value: TemporalReconstructionConfiguration) {
        var sanitized = value
        sanitized.historyWeight = min(0.85, max(0, value.historyWeight))
        sanitized.ghostRejection = min(1, max(0, value.ghostRejection))
        sanitized.consistencyThresholdPixels = min(8, max(0.5, value.consistencyThresholdPixels))
        sanitized.latencyBudgetMilliseconds = min(120, max(15, value.latencyBudgetMilliseconds))
        temporalReconstructionConfiguration = sanitized
        UserDefaults.standard.set(sanitized.isEnabled, forKey: "ParrotLab.Temporal.Enabled")
        UserDefaults.standard.set(sanitized.historyWeight, forKey: "ParrotLab.Temporal.HistoryWeight")
        UserDefaults.standard.set(sanitized.ghostRejection, forKey: "ParrotLab.Temporal.GhostRejection")
        UserDefaults.standard.set(sanitized.consistencyThresholdPixels, forKey: "ParrotLab.Temporal.ConsistencyPixels")
        UserDefaults.standard.set(sanitized.latencyBudgetMilliseconds, forKey: "ParrotLab.Temporal.LatencyBudgetMs")
        UserDefaults.standard.set(sanitized.usesBidirectionalFlow, forKey: "ParrotLab.Temporal.Bidirectional")
        applyTemporalReconstructionConfiguration()
        appendLog(sanitized.isEnabled
            ? String(
                format: "Experimental temporal reconstruction enabled · history %.0f%% · ghost rejection %.0f%% · budget %.0f ms · %@ flow",
                sanitized.historyWeight * 100,
                sanitized.ghostRejection * 100,
                sanitized.latencyBudgetMilliseconds,
                sanitized.usesBidirectionalFlow ? "bidirectional" : "single-direction"
            )
            : "Experimental temporal reconstruction disabled")
        updateInterface()
    }

    private func applyTemporalReconstructionConfiguration() {
        hudView.videoView.temporalReconstructionConfiguration = temporalReconstructionConfiguration
    }

    private func applyRollingShutterConfiguration() {
        hudView.videoView.rollingShutterConfiguration = RollingShutterProcessingConfiguration(
            isEnabled: calibratedRollingShutterEnabled,
            calibrationProfile: .firmware471GPUFixedRaised,
            quaternionConvention: VideoQuaternionConvention(
                action: .active,
                handedness: .rightHanded,
                composition: .frameViewOnly
            ),
            timestampAnchor: .frameEOF,
            maximumStabilizationAngleDegrees: 6,
            irqDelaySeconds: 0
        )
    }

    private func beginRFPowerSC2Upload(host: String) {
        guard rfPowerOperationInFlight else { return }
        rfPowerSC2Host = host
        rfPowerPhase = .uploadingSC2
        appendLog("Uploading and verifying RF Lab on SkyController 2 at \(host)")
        toolInstaller.install(.rfModSuite, host: host) { [weak self] result in
            guard let self, self.rfPowerOperationInFlight else { return }
            switch result {
            case .success(let install):
                self.cacheSC2Host(host)
                self.appendVerifiedAssets(install)
                self.appendLog("RF Lab updated on SkyController 2")
                self.beginRFPowerBebopUpload()
            case .failure(let error):
                if !self.rfPowerDiscoveryAttempted {
                    self.rfPowerDiscoveryAttempted = true
                    self.rfPowerPhase = .discovering
                    self.appendLog("SC2 upload at \(host) failed; refreshing its DHCP address through the Bebop")
                    self.beginSC2Discovery(purpose: .rfPowerProfile)
                } else {
                    self.finishRFPowerOperation(
                        success: false,
                        message: "Could not update RF Lab on the SkyController 2: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func beginRFPowerBebopUpload() {
        guard rfPowerOperationInFlight else { return }
        rfPowerPhase = .uploadingBebop
        appendLog("Uploading and verifying RF Lab on Bebop 2 at 192.168.42.1")
        toolInstaller.install(.rfModSuite, host: BebopToolPackage.ftpHost) { [weak self] result in
            guard let self, self.rfPowerOperationInFlight else { return }
            switch result {
            case .success(let install):
                self.appendVerifiedAssets(install)
                self.appendLog("RF Lab updated on Bebop 2")
                self.beginRFPowerApplyOnSC2()
            case .failure(let error):
                self.finishRFPowerOperation(
                    success: false,
                    message: "Could not update RF Lab on the Bebop 2: \(error.localizedDescription)"
                )
            }
        }
    }

    private func beginRFPowerApplyOnSC2() {
        guard rfPowerOperationInFlight, let host = rfPowerSC2Host,
              let mode = rfPowerMode else { return }
        rfPowerPhase = .applyingSC2
        rfPowerSC2Connected = false
        rfPowerStepSucceeded = false
        appendLog("Applying \(mode.profileArgument) on SkyController 2 with backup and verification")
        rfPowerSC2Telnet.connect(
            host: host,
            port: 23,
            startupCommand: "NO_COLOR=1 RF_LAB_NO_CLEAR=1 sh /data/lib/ftp/internal_000/parrot_rf_lab.sh apply-profile \(mode.profileArgument); exit"
        )
        armRFPowerTimeout(seconds: 25, step: "SkyController 2 profile application")
    }

    private func beginRFPowerApplyOnBebop() {
        guard rfPowerOperationInFlight, let mode = rfPowerMode else { return }
        rfPowerPhase = .applyingBebop
        rfPowerBebopConnected = false
        rfPowerStepSucceeded = false
        appendLog("Applying \(mode.profileArgument) on Bebop 2 with backup and verification")
        rfPowerBebopTelnet.connect(
            host: BebopToolPackage.ftpHost,
            port: 23,
            startupCommand: "NO_COLOR=1 RF_LAB_NO_CLEAR=1 sh /data/ftp/internal_000/parrot_rf_lab.sh apply-profile \(mode.profileArgument); exit"
        )
        armRFPowerTimeout(seconds: 25, step: "Bebop 2 profile application")
    }

    private func beginRFPowerRebootSequence() {
        guard rfPowerOperationInFlight, let host = rfPowerSC2Host else { return }
        // Queue the aircraft's longer delay first. The controller command is
        // queued only after that shell confirms, so the SC2 resets first while
        // the Bebop remains reachable long enough to receive both commands.
        rfPowerPhase = .queueingBebopReboot
        rfPowerBebopConnected = false
        rfPowerStepSucceeded = false
        appendLog("Both RF files verified; queueing Bebop reboot after the SC2")
        rfPowerBebopTelnet.connect(
            host: BebopToolPackage.ftpHost,
            port: 23,
            startupCommand: "echo __PARROTLAB_RF_REBOOT__=BEBOP_QUEUED; sync; sleep 8; reboot"
        )
        rfPowerSC2Host = host
        armRFPowerTimeout(seconds: 8, step: "Bebop reboot scheduling")
    }

    private func beginRFPowerSC2Reboot() {
        guard rfPowerOperationInFlight, let host = rfPowerSC2Host else { return }
        rfPowerPhase = .queueingSC2Reboot
        rfPowerSC2Connected = false
        rfPowerStepSucceeded = false
        appendLog("Queueing SkyController 2 reboot first; Bebop 2 follows several seconds later")
        rfPowerSC2Telnet.connect(
            host: host,
            port: 23,
            startupCommand: "echo __PARROTLAB_RF_REBOOT__=SC2_QUEUED; sync; sleep 2; reboot"
        )
        armRFPowerTimeout(seconds: 8, step: "SkyController 2 reboot scheduling")
    }

    private func armRFPowerTimeout(seconds: TimeInterval, step: String) {
        rfPowerTimeoutTimer?.invalidate()
        rfPowerTimeoutTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.rfPowerOperationInFlight else { return }
            self.finishRFPowerOperation(success: false, message: "\(step) did not confirm within \(Int(seconds)) seconds. Check the event log and device state before retrying.")
        }
    }

    private func handleRFPowerLine(_ rawLine: String, device: String) {
        guard rfPowerOperationInFlight else { return }
        if let event = SC2TelemetryParser.deviceMarkerPayload(
            "__PARROTLAB_RF_PROFILE__=",
            in: rawLine
        ) {
            if event.hasPrefix("OK:") {
                let expected = (device == "SkyController 2" && rfPowerPhase == .applyingSC2) ||
                    (device == "Bebop 2" && rfPowerPhase == .applyingBebop)
                guard expected else { return }
                rfPowerStepSucceeded = true
                appendLog("\(device) RF profile write verified: \(event)")
            } else if event.hasPrefix("ERROR:") {
                finishRFPowerOperation(
                    success: false,
                    message: "\(device) rejected the RF profile update (\(event)). Its reboot was not intentionally queued."
                )
            }
            return
        }

        guard let event = SC2TelemetryParser.deviceMarkerPayload(
            "__PARROTLAB_RF_REBOOT__=",
            in: rawLine
        ) else { return }
        if event == "BEBOP_QUEUED", device == "Bebop 2",
           rfPowerPhase == .queueingBebopReboot {
            rfPowerTimeoutTimer?.invalidate()
            rfPowerTimeoutTimer = nil
            appendLog("Bebop 2 accepted its delayed reboot command")
            beginRFPowerSC2Reboot()
        } else if event == "SC2_QUEUED", device == "SkyController 2",
                  rfPowerPhase == .queueingSC2Reboot {
            rfPowerTimeoutTimer?.invalidate()
            rfPowerTimeoutTimer = nil
            appendLog("SkyController 2 accepted its earlier reboot command")
            finishRFPowerOperation(success: true, message: nil)
        }
    }

    private func handleRFPowerTelnetState(_ state: TelnetClient.State, device: String) {
        guard rfPowerOperationInFlight else { return }
        let isSC2 = device == "SkyController 2"
        let expectedPhase: Bool
        if isSC2 {
            expectedPhase = rfPowerPhase == .applyingSC2 || rfPowerPhase == .queueingSC2Reboot
        } else {
            expectedPhase = rfPowerPhase == .applyingBebop || rfPowerPhase == .queueingBebopReboot
        }
        guard expectedPhase else { return }

        switch state {
        case .ready:
            if isSC2 { rfPowerSC2Connected = true } else { rfPowerBebopConnected = true }
        case .failed(let message):
            finishRFPowerOperation(
                success: false,
                message: "\(device) Telnet failed during the RF power workflow: \(message)"
            )
        case .stopped:
            let connected = isSC2 ? rfPowerSC2Connected : rfPowerBebopConnected
            guard connected else { return }
            if rfPowerPhase == .applyingSC2 {
                guard rfPowerStepSucceeded else {
                    finishRFPowerOperation(
                        success: false,
                        message: "The SkyController 2 shell closed without confirming its RF profile write."
                    )
                    return
                }
                rfPowerTimeoutTimer?.invalidate()
                rfPowerTimeoutTimer = nil
                beginRFPowerApplyOnBebop()
            } else if rfPowerPhase == .applyingBebop {
                guard rfPowerStepSucceeded else {
                    finishRFPowerOperation(
                        success: false,
                        message: "The Bebop 2 shell closed without confirming its RF profile write."
                    )
                    return
                }
                rfPowerTimeoutTimer?.invalidate()
                rfPowerTimeoutTimer = nil
                beginRFPowerRebootSequence()
            } else if rfPowerPhase == .queueingBebopReboot {
                finishRFPowerOperation(
                    success: false,
                    message: "The Bebop 2 shell closed before confirming its delayed reboot command."
                )
            } else if rfPowerPhase == .queueingSC2Reboot {
                finishRFPowerOperation(
                    success: false,
                    message: "The SkyController 2 shell closed before confirming its reboot command."
                )
            }
        case .idle, .connecting:
            break
        }
    }

    private func finishRFPowerOperation(success: Bool, message: String?) {
        guard rfPowerOperationInFlight else { return }
        let completedMode = rfPowerMode
        rfPowerTimeoutTimer?.invalidate()
        rfPowerTimeoutTimer = nil
        toolUploadInFlight = false
        rfPowerOperationInFlight = false
        rfPowerMode = nil
        rfPowerPhase = .idle
        rfPowerSC2Host = nil
        rfPowerSC2Connected = false
        rfPowerBebopConnected = false
        rfPowerStepSucceeded = false
        rfPowerDiscoveryAttempted = false

        if success {
            statusLabel.stringValue = "REBOOTING"
            statusLabel.textColor = .systemCyan
            updateInterface()
            // Leave both command sessions alive while their ordered sleeps run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.rfPowerSC2Telnet.stop()
                self?.rfPowerBebopTelnet.stop()
            }
            let title = completedMode?.completionTitle ?? "RF power profile updated"
            appendLog("RF power workflow complete; SC2 reboot is scheduled before Bebop 2")
            showToolAlert(
                title: title,
                message: "Both active NVM files passed identity, write, and digest verification. The SkyController 2 will reboot first; the Bebop 2 follows several seconds later. Expect USB, Wi-Fi, video, and telemetry to drop, then reconnect after both devices return.",
                style: .informational
            )
        } else {
            rfPowerSC2Telnet.stop()
            rfPowerBebopTelnet.stop()
            statusLabel.stringValue = connectButton.title == "Disconnect" ? "LIVE" : "DISCONNECTED"
            statusLabel.textColor = connectButton.title == "Disconnect" ? .systemGreen : .systemOrange
            updateInterface()
            showToolAlert(
                title: "RF power profile was not completed",
                message: message ?? "A device did not confirm the requested change."
            )
        }
    }

    func findSC2HostThroughBebop() {
        guard !toolUploadInFlight, !dragonCommandInFlight,
              !persistentTelnetInstallInFlight, !sc2DriverInstallInFlight,
              !sc2DiscoveryInFlight else {
            showToolAlert(
                title: "Tool operation already running",
                message: "Wait for the current transfer or device operation to finish."
            )
            return
        }

        toolUploadInFlight = true
        updateInterface()
        beginSC2Discovery(purpose: .manual)
    }

    func findSC2USBHost() {
        guard !toolUploadInFlight, !dragonCommandInFlight,
              !persistentTelnetInstallInFlight, !sc2DriverInstallInFlight,
              !sc2DiscoveryInFlight, !rfPowerOperationInFlight else {
            showToolAlert(
                title: "Tool operation already running",
                message: "Wait for the current transfer or device operation to finish."
            )
            return
        }

        toolUploadInFlight = true
        updateInterface()
        appendLog("Discovering the SkyController 2 endpoint on active macOS USB network interfaces")
        sc2USBDiscovery.discover { [weak self] result in
            guard let self else { return }
            self.toolUploadInFlight = false
            self.updateInterface()
            switch result {
            case .success(let discovery):
                self.cacheSC2Host(discovery.host)
                self.appendLog(
                    "SC2 USB confirmed: \(discovery.interfaceName) local \(discovery.localAddress) → \(discovery.host):\(discovery.servicePort) (\(discovery.serviceName))"
                )
                self.showToolAlert(
                    title: "SkyController 2 USB address found",
                    message: "Found and verified the controller at \(discovery.host) through macOS interface \(discovery.interfaceName) (local address \(discovery.localAddress)). \(discovery.serviceName) answered on port \(discovery.servicePort).\n\nThe USB address has been cached and filled into SC2 HOST.",
                    style: .informational
                )
            case .failure(let error):
                self.appendLog("SC2 USB discovery failed: \(error.localizedDescription)")
                self.showToolAlert(
                    title: "SkyController 2 USB address not found",
                    message: error.localizedDescription
                )
            }
        }
    }

    func installSC2DriverPatch() {
        guard !toolUploadInFlight, !dragonCommandInFlight,
              !persistentTelnetInstallInFlight, !sc2DriverInstallInFlight else {
            showToolAlert(title: "Tool operation already running", message: "Wait for the current transfer or device operation to finish.")
            return
        }

        let enteredHost = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cachedHost = UserDefaults.standard.string(forKey: Self.cachedSC2HostPreferenceKey) ?? ""
        let cachedUSBHost = UserDefaults.standard.string(forKey: Self.cachedSC2USBHostPreferenceKey) ?? ""
        let candidateHost: String?
        if connectButton.title == "Disconnect", Self.isValidIPv4Host(enteredHost) {
            // A live app connection is stronger evidence than a DHCP cache.
            candidateHost = enteredHost
        } else if Self.isValidIPv4Host(cachedUSBHost) {
            candidateHost = cachedUSBHost
        } else if Self.isValidIPv4Host(cachedHost) {
            candidateHost = cachedHost
        } else {
            // With no verified connection or bridge-side cache, discover from
            // the Bebop rather than trusting the UI's historical default.
            candidateHost = nil
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        let bootstrapMode = !hasFreshLandedTelemetry
        if bootstrapMode {
            alert.messageText = "Bootstrap the SC2 Apple-NCM driver?"
            alert.informativeText = "Parrot Lab is not enforcing a flight-state interlock for installs. Continue only with the drone powered off, or physically landed with its propellers removed.\n\nThis is only for SkyController 2 firmware 1.0.9. Parrot Lab will first try the entered or cached controller address. If it cannot connect, it will upload a read-only discovery helper to the Bebop, find the SC2's current DHCP address, cache it, install the persistent Apple-NCM driver, and reboot the controller."
            alert.addButton(withTitle: "Bootstrap and Reboot")
        } else {
            alert.messageText = "Install the persistent SC2 Apple-NCM driver and reboot?"
            alert.informativeText = "This is only for SkyController 2 firmware 1.0.9. Parrot Lab will first try the entered or cached controller address. If it cannot connect, it will ask the Bebop for the SC2's current DHCP address, cache it, install the persistent Apple-NCM driver, and reboot the controller. Disconnect any phone and expect the controller connection to drop."
            alert.addButton(withTitle: "Install and Reboot")
        }
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if videoRunning { startVideo() }
        toolUploadInFlight = true
        sc2DriverInstallInFlight = true
        sc2DriverTelnetConnected = false
        sc2DriverInstallSucceeded = false
        sc2DriverDiscoveryAttempted = false
        pendingSC2DriverHost = candidateHost
        statusLabel.stringValue = "INSTALLING"
        statusLabel.textColor = .systemYellow
        updateInterface()
        if bootstrapMode {
            appendLog("SC2 driver bootstrap authorized without a flight-state interlock")
        }
        if let candidateHost {
            appendLog("Trying entered/cached SC2 address \(candidateHost) before Bebop-side discovery")
            beginSC2DriverPreparation(host: candidateHost)
        } else {
            appendLog("No valid cached SC2 address; starting Bebop-side discovery")
            sc2DriverDiscoveryAttempted = true
            sc2DriverInstallPhase = .discovering
            beginSC2Discovery(purpose: .driverInstall)
        }
    }

    private func beginSC2DriverPreparation(host: String) {
        guard sc2DriverInstallInFlight else { return }
        pendingSC2DriverHost = host
        sc2DriverTelnetConnected = false
        sc2DriverInstallPhase = .preparingFTP
        appendLog("Preparing the two existing SC2 driver files for in-place FTP replacement")
        sc2DriverTelnet.connect(
            host: host,
            port: 23,
            startupCommand: sc2DriverFTPFilePreparationCommand()
        )
        sc2DriverPreparationTimeoutTimer?.invalidate()
        sc2DriverPreparationTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: 8,
            repeats: false
        ) { [weak self] _ in
            guard let self,
                  self.sc2DriverInstallInFlight,
                  self.sc2DriverInstallPhase == .preparingFTP else { return }
            self.appendLog("SC2 driver file preparation timed out after 8 seconds")
            self.retrySC2DriverWithDiscovery(
                reason: "the entered/cached SC2 address did not complete its Telnet preparation"
            )
        }
    }

    private func retrySC2DriverWithDiscovery(reason: String) {
        guard sc2DriverInstallInFlight else { return }
        sc2DriverPreparationTimeoutTimer?.invalidate()
        sc2DriverPreparationTimeoutTimer = nil
        sc2DriverTelnetConnected = false
        sc2DriverTelnet.stop()
        if sc2DriverDiscoveryAttempted {
            finishSC2DriverInstall(
                success: false,
                message: "SC2 installation could not continue after address discovery: \(reason)."
            )
            return
        }
        sc2DriverDiscoveryAttempted = true
        sc2DriverInstallPhase = .discovering
        appendLog("SC2 connection failed; discovering its current DHCP address through the Bebop")
        beginSC2Discovery(purpose: .driverInstall)
    }

    private func beginSC2Discovery(purpose: SC2DiscoveryPurpose) {
        guard !sc2DiscoveryInFlight else { return }
        sc2DiscoveryInFlight = true
        sc2DiscoveryPurpose = purpose
        sc2DiscoveryTelnetConnected = false
        sc2DiscoveryResult = nil
        sc2DiscoveryTimeoutTimer?.invalidate()
        sc2DiscoveryTimeoutTimer = nil
        appendLog("Uploading the SC2 address helper to Bebop 2 at 192.168.42.1")

        toolInstaller.install(.sc2Discovery, host: BebopToolPackage.ftpHost) { [weak self] result in
            guard let self, self.sc2DiscoveryInFlight else { return }
            switch result {
            case .success(let install):
                self.appendVerifiedAssets(install)
                guard let helper = install.assets.first(where: { $0.assetName == "parrotlab_find_sc2_ip.sh" }) else {
                    self.finishSC2Discovery(
                        host: nil,
                        message: "The bundled SC2 discovery helper is missing."
                    )
                    return
                }
                let helperPath = "/data/ftp/internal_000/\(helper.remoteName)"
                self.appendLog("Querying the Bebop association and DHCP tables for the current SC2 address")
                self.sc2DiscoveryTelnet.connect(
                    host: BebopToolPackage.ftpHost,
                    port: 23,
                    startupCommand: "sh \(helperPath); exit"
                )
                self.sc2DiscoveryTimeoutTimer = Timer.scheduledTimer(
                    withTimeInterval: 12,
                    repeats: false
                ) { [weak self] _ in
                    guard let self, self.sc2DiscoveryInFlight else { return }
                    self.sc2DiscoveryTelnet.stop()
                    self.finishSC2Discovery(
                        host: nil,
                        message: "Bebop Telnet did not return an SC2 address within 12 seconds. Ensure Bebop Telnet is enabled and the SC2 is associated with the drone."
                    )
                }
            case .failure(let error):
                self.finishSC2Discovery(
                    host: nil,
                    message: "Could not upload the discovery helper to the Bebop: \(error.localizedDescription)"
                )
            }
        }
    }

    private func handleSC2DiscoveryLine(_ rawLine: String) {
        guard sc2DiscoveryInFlight,
              let payload = SC2TelemetryParser.deviceMarkerPayload(
                "__PARROTLAB_SC2_IP__=",
                in: rawLine
              ) else { return }
        if Self.isValidIPv4Host(payload) {
            sc2DiscoveryResult = payload
            appendLog("Bebop reports the associated SC2 at \(payload)")
        } else if payload == "NOT_FOUND" {
            appendLog("Bebop could not match an associated SC2 to a current DHCP lease")
        }
    }

    private func handleSC2DiscoveryState(_ state: TelnetClient.State) {
        guard sc2DiscoveryInFlight else { return }
        switch state {
        case .ready:
            sc2DiscoveryTelnetConnected = true
        case .failed(let message):
            finishSC2Discovery(
                host: nil,
                message: "Could not query Bebop Telnet at 192.168.42.1: \(message). Enable Bebop Telnet and try again."
            )
        case .stopped:
            guard sc2DiscoveryTelnetConnected else { return }
            if let host = sc2DiscoveryResult {
                finishSC2Discovery(host: host, message: nil)
            } else {
                finishSC2Discovery(
                    host: nil,
                    message: "The Bebop did not find an associated SkyController 2. Connect the SC2 to this Bebop, ensure Telnet is enabled on the Bebop, and retry."
                )
            }
        case .idle, .connecting:
            break
        }
    }

    private func finishSC2Discovery(host: String?, message: String?) {
        guard sc2DiscoveryInFlight else { return }
        let purpose = sc2DiscoveryPurpose
        sc2DiscoveryInFlight = false
        sc2DiscoveryPurpose = nil
        sc2DiscoveryTelnetConnected = false
        sc2DiscoveryTimeoutTimer?.invalidate()
        sc2DiscoveryTimeoutTimer = nil
        sc2DiscoveryTelnet.stop()

        if let host {
            cacheSC2Host(host)
            switch purpose {
            case .driverInstall:
                appendLog("Continuing the SC2 driver install at discovered address \(host)")
                beginSC2DriverPreparation(host: host)
            case .rfPowerProfile:
                appendLog("Continuing the RF power workflow at discovered SC2 address \(host)")
                beginRFPowerSC2Upload(host: host)
            case .manual:
                toolUploadInFlight = false
                updateInterface()
                showToolAlert(
                    title: "SkyController 2 found",
                    message: "The Bebop reports the SkyController 2 at \(host). The SC2 HOST field and update cache have been filled automatically.",
                    style: .informational
                )
            case nil:
                toolUploadInFlight = false
                updateInterface()
            }
            return
        }

        let detail = message ?? "SC2 address discovery failed."
        switch purpose {
        case .driverInstall:
            finishSC2DriverInstall(success: false, message: detail)
        case .rfPowerProfile:
            finishRFPowerOperation(success: false, message: detail)
        case .manual, nil:
            toolUploadInFlight = false
            updateInterface()
            showToolAlert(title: "SkyController 2 was not found", message: detail)
        }
    }

    private func cacheSC2Host(_ host: String) {
        guard Self.isValidIPv4Host(host) else { return }
        hostField.stringValue = host
        // Keep the stable USB endpoint separate from the controller's dynamic
        // DHCP address on the Bebop subnet; either can then be selected without
        // overwriting the other.
        if host.hasPrefix("192.168.53.") {
            UserDefaults.standard.set(host, forKey: Self.cachedSC2USBHostPreferenceKey)
        } else if host.hasPrefix("192.168.42.") {
            UserDefaults.standard.set(host, forKey: Self.cachedSC2HostPreferenceKey)
        }
    }

    private static func isValidIPv4Host(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isNumber }),
                  let value = UInt16(component) else { return false }
            return value <= 255
        }
    }

    private static func storedDouble(_ key: String, fallback: Double) -> Double {
        guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else {
            return fallback
        }
        return number.doubleValue
    }

    private func sc2DriverFTPFilePreparationCommand() -> String {
        let root = "/data/lib/ftp/internal_000"
        return "D=\(root); " +
            "for N in install_sc2_apple_ncm.sh apple_mac_ncm.ko; do " +
            "F=$D/$N; B=$F.parrotlab-old; " +
            "if [ ! -e \"$F\" ] && [ ! -L \"$F\" ] && { [ -e \"$B\" ] || [ -L \"$B\" ]; }; " +
            "then mv \"$B\" \"$F\"; fi; " +
            "chmod 0666 \"$F\" >/dev/null 2>&1 || true; " +
            "L=$(ls -ld \"$F\" 2>/dev/null); echo __PARROTLAB_SC2_FTP_FILE__=$N'|'$L; " +
            "done; exit"
    }

    private func beginSC2DriverFTPUpload(host: String) {
        guard sc2DriverInstallInFlight, sc2DriverInstallPhase == .uploading else { return }
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
                self.sc2DriverInstallPhase = .installing
                self.sc2DriverTelnet.connect(host: host, port: 23, startupCommand: command)
            case .failure(let error):
                self.appendLog("SC2 driver FTP upload failed: \(error.localizedDescription)")
                self.finishSC2DriverInstall(success: false, message: error.localizedDescription)
            }
        }
    }

    private func uploadRFModSuite(host: String, targetName: String, devicePath: String) {
        guard !toolUploadInFlight, !dragonCommandInFlight,
              !persistentTelnetInstallInFlight, !sc2DriverInstallInFlight else {
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
                if targetName == "SkyController 2" {
                    self.cacheSC2Host(host)
                }
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
            let stagedAs = asset.assetName == asset.remoteName ? "" : " · staged as \(asset.remoteName)"
            appendLog("Verified \(asset.assetName)\(stagedAs) · \(asset.byteCount) bytes · SHA-256 \(asset.sha256)")
        }
    }

    private func dragonInstallVerificationCommand(_ result: BebopToolInstallResult) -> String? {
        guard let binary442 = result.assets.first(where: { $0.assetName == "dragon-prog-900p-4.4.2" }),
              let binary471 = result.assets.first(where: { $0.assetName == "dragon-prog-900p-4.7.1" }),
              let helper = result.assets.first(where: { $0.assetName == "parrotlab_dragon_video.sh" }) else {
            return nil
        }
        return "chmod 755 \(binary442.devicePath) \(binary471.devicePath) \(helper.devicePath); " +
            "D442=$(md5sum \(binary442.devicePath)); D442=${D442%% *}; " +
            "D471=$(md5sum \(binary471.devicePath)); D471=${D471%% *}; " +
            "H=$(md5sum \(helper.devicePath)); H=${H%% *}; " +
            "if [ -x \(binary442.devicePath) ] && [ -x \(binary471.devicePath) ] && " +
            "[ -x \(helper.devicePath) ] && " +
            "[ \"$D442\" = \"\(binary442.md5)\" ] && " +
            "[ \"$D471\" = \"\(binary471.md5)\" ] && " +
            "[ \"$H\" = \"\(helper.md5)\" ]; " +
            "then echo __PARROTLAB_INSTALL__=READY; else echo __PARROTLAB_INSTALL__=ERROR; fi; exit"
    }

    private func persistentTelnetInstallCommand(_ result: BebopToolInstallResult) -> String? {
        guard let script = result.assets.first(where: {
            $0.assetName == "install_bebop2_persistent_telnet.sh"
        }) else { return nil }
        return "chmod 755 \(script.devicePath); " +
            "S=$(md5sum \(script.devicePath)); S=${S%% *}; " +
            "if [ \"$S\" != \"\(script.md5)\" ]; " +
            "then echo __PARROTLAB_TELNET__=ERROR_DIGEST; " +
            "elif sh \(script.devicePath) install; then :; " +
            "else echo __PARROTLAB_TELNET__=ERROR_INSTALLER; fi; exit"
    }

    private func handlePersistentTelnetLine(_ rawLine: String) {
        guard let event = SC2TelemetryParser.deviceMarkerPayload(
            "__PARROTLAB_TELNET__=",
            in: rawLine
        ) else { return }
        if event == "INSTALLED" {
            appendLog("Bebop confirmed usbnetwork.sh is enabled in rcS at boot")
            finishPersistentTelnetInstall(success: true, message: nil)
        } else if event.hasPrefix("ERROR") {
            appendLog("Persistent Telnet installer reported: \(event)")
            finishPersistentTelnetInstall(
                success: false,
                message: "The Bebop installer reported \(event). The system partition was returned to read-only."
            )
        }
    }

    private func handlePersistentTelnetState(_ state: TelnetClient.State) {
        switch state {
        case .ready:
            persistentTelnetConnected = true
        case .failed(let message):
            guard persistentTelnetInstallInFlight else { return }
            finishPersistentTelnetInstall(
                success: false,
                message: "Direct Bebop Telnet failed: \(message). Manually enable Telnet for this one-time installation."
            )
        case .stopped:
            guard persistentTelnetInstallInFlight, persistentTelnetConnected else { return }
            finishPersistentTelnetInstall(
                success: false,
                message: "The Bebop shell closed without confirming the persistent boot trigger."
            )
        case .idle, .connecting:
            break
        }
    }

    private func finishPersistentTelnetInstall(success: Bool, message: String?) {
        guard persistentTelnetInstallInFlight else { return }
        toolUploadInFlight = false
        persistentTelnetInstallInFlight = false
        persistentTelnetConnected = false
        persistentTelnetTimeoutTimer?.invalidate()
        persistentTelnetTimeoutTimer = nil
        bebopSystemTelnet.stop()
        dragonRuntimeStatus = success ? "PERSISTENT TELNET ENABLED" : "READY · LANDED ONLY"
        updateInterface()

        if success {
            showToolAlert(
                title: "Persistent Bebop Telnet enabled",
                message: "The stock developer network script will now run automatically on every boot, enabling Telnet and ADB. tcpdump remains available through /usr/sbin/tcpdump via its verified internal_000 backup. No reboot was performed.\n\nTo remove the rcS boot call later, run:\nsh /data/ftp/internal_000/install_bebop2_persistent_telnet.sh uninstall",
                style: .informational
            )
        } else {
            showToolAlert(
                title: "Persistent Bebop Telnet was not enabled",
                message: message ?? "The aircraft did not confirm installation."
            )
        }

    }

    private func sc2DriverInstallCommand(_ result: BebopToolInstallResult) -> String? {
        guard let script = result.assets.first(where: { $0.assetName == "install_sc2_apple_ncm.sh" }),
              let module = result.assets.first(where: { $0.assetName == "apple_mac_ncm.ko" }) else {
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
            "then rm -f \(scriptPath).parrotlab-old \(modulePath).parrotlab-old; " +
            "echo __PARROTLAB_SC2_DRIVER__=INSTALLED_REBOOTING; sync; sleep 2; reboot; " +
            "else R=$?; echo __PARROTLAB_SC2_DRIVER__=ERROR_INSTALLER:$R; fi; exit"
    }

    private func handleSC2DriverInstallLine(_ rawLine: String) {
        if let detail = SC2TelemetryParser.deviceMarkerPayload(
            "__PARROTLAB_SC2_FTP_FILE__=",
            in: rawLine
        ) {
            appendLog("SC2 existing FTP driver file: \(detail)")
            return
        }
        if SC2TelemetryParser.deviceMarkerPayload(
            "__PARROTLAB_SC2_DRIVER_SCRIPT__=",
            in: rawLine
        ) == "INSTALLED" {
            appendLog("SC2 installer confirmed the persistent plboot configuration")
        }
        guard let event = SC2TelemetryParser.deviceMarkerPayload(
            "__PARROTLAB_SC2_DRIVER__=",
            in: rawLine
        ) else { return }
        guard event == "INSTALLED_REBOOTING" || event == "ERROR_DIGEST" ||
                event.hasPrefix("ERROR_INSTALLER") else { return }
        if event == "INSTALLED_REBOOTING" {
            sc2DriverInstallSucceeded = true
            sc2DriverInstallPhase = .rebooting
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
            if sc2DriverInstallPhase == .preparingFTP {
                retrySC2DriverWithDiscovery(
                    reason: "SC2 Telnet could not prepare the existing driver files: \(message)"
                )
            } else if sc2DriverInstallSucceeded {
                finishSC2DriverInstall(success: true, message: nil)
            } else {
                appendLog("SC2 driver Telnet failed: \(message)")
                finishSC2DriverInstall(success: false, message: "SC2 Telnet failed: \(message)")
            }
        case .stopped:
            guard sc2DriverInstallInFlight else { return }
            if sc2DriverInstallPhase == .preparingFTP,
               sc2DriverTelnetConnected,
               let host = pendingSC2DriverHost {
                sc2DriverPreparationTimeoutTimer?.invalidate()
                sc2DriverPreparationTimeoutTimer = nil
                cacheSC2Host(host)
                appendLog("SC2 driver file preparation completed; starting normal FTP replacement")
                sc2DriverTelnetConnected = false
                sc2DriverInstallPhase = .uploading
                beginSC2DriverFTPUpload(host: host)
            } else if sc2DriverInstallPhase == .uploading {
                return
            } else if !sc2DriverTelnetConnected {
                return
            } else if sc2DriverInstallSucceeded {
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
        toolUploadInFlight = false
        sc2DriverInstallInFlight = false
        sc2DriverTelnetConnected = false
        sc2DriverInstallSucceeded = false
        sc2DriverDiscoveryAttempted = false
        pendingSC2DriverHost = nil
        sc2DriverInstallPhase = .idle
        sc2DriverPreparationTimeoutTimer?.invalidate()
        sc2DriverPreparationTimeoutTimer = nil
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
        }
    }

    private var canAdjustDragon: Bool {
        connectButton.title == "Disconnect" &&
            hasFreshLandedTelemetry &&
            !dragonCommandInFlight &&
            !toolUploadInFlight &&
            !persistentTelnetInstallInFlight &&
            !sc2DriverInstallInFlight
    }

    private var canApplySelectedDragonProfile: Bool {
        connectButton.title == "Disconnect" &&
            (temporalDragonModeSelected || hasFreshLandedTelemetry) &&
            !dragonCommandInFlight &&
            !toolUploadInFlight &&
            !persistentTelnetInstallInFlight &&
            !sc2DriverInstallInFlight
    }

    private var hasFreshLandedTelemetry: Bool {
        guard snapshot.flightState == "LANDED", let lastFlightStateUpdate else { return false }
        return Date().timeIntervalSince(lastFlightStateUpdate) <= 3
    }

    private func runDragonCommand(
        _ command: String,
        status: String,
        logMessage: String = "Dragon control requested; runtime-only helper will validate the profile",
        canRetryAfterNoResult: Bool = false
    ) {
        let sc2Host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        dragonCommandInFlight = true
        dragonCommandConnected = false
        dragonCommandSucceeded = false
        dragonCommandResponded = false
        dragonCommandCanRetryAfterNoResult = canRetryAfterNoResult
        pendingDragonCommand = command
        pendingDragonEndpoints.removeAll(keepingCapacity: true)
        if !sc2Host.isEmpty, sc2Host != BebopToolPackage.ftpHost {
            pendingDragonEndpoints.append(DragonControlEndpoint(
                host: sc2Host,
                port: 2324,
                label: "SC2 relay"
            ))
        }
        pendingDragonEndpoints.append(DragonControlEndpoint(
            host: BebopToolPackage.ftpHost,
            port: 23,
            label: "Bebop direct fallback"
        ))
        dragonRuntimeStatus = status
        updateInterface()
        appendLog(logMessage)
        startNextDragonControlEndpoint()
    }

    private func startNextDragonControlEndpoint(after failure: String? = nil) {
        dragonCommandTimeoutTimer?.invalidate()
        dragonCommandTimeoutTimer = nil
        if let failure { appendLog(failure) }
        guard dragonCommandInFlight, let command = pendingDragonCommand,
              !pendingDragonEndpoints.isEmpty else {
            dragonRuntimeStatus = "CONTROL ERROR · NO TELNET PATH"
            appendLog("Dragon control failed: the SC2 relay and direct Bebop fallback were unavailable")
            finishDragonCommand()
            return
        }

        let endpoint = pendingDragonEndpoints.removeFirst()
        activeDragonEndpoint = endpoint
        dragonCommandConnected = false
        appendLog("Dragon control trying \(endpoint.label) at \(endpoint.host):\(endpoint.port)")
        dragonControlTelnet.connect(
            host: endpoint.host,
            port: endpoint.port,
            startupCommand: command
        )
        dragonCommandTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) {
            [weak self] _ in
            guard let self, self.dragonCommandInFlight,
                  self.activeDragonEndpoint == endpoint,
                  !self.dragonCommandResponded else { return }
            if self.dragonCommandConnected {
                if self.dragonCommandCanRetryAfterNoResult,
                   !self.pendingDragonEndpoints.isEmpty {
                    self.startNextDragonControlEndpoint(
                        after: "Dragon control received no result through \(endpoint.label); trying the fallback path"
                    )
                    return
                }
                self.dragonRuntimeStatus = "NO RESULT · \(endpoint.label.uppercased())"
                self.appendLog("Dragon control connected through \(endpoint.label), but the device returned no result within 8 seconds")
                self.finishDragonCommand()
            } else {
                self.startNextDragonControlEndpoint(
                    after: "Dragon control could not connect through \(endpoint.label) within 8 seconds"
                )
            }
        }
    }

    private func handleDragonControlState(_ state: TelnetClient.State) {
        switch state {
        case .ready:
            dragonCommandConnected = true
            if let activeDragonEndpoint {
                appendLog("Dragon control connected through \(activeDragonEndpoint.label)")
            }
        case .failed(let message):
            guard dragonCommandInFlight else { return }
            if dragonCommandResponded {
                if dragonCommandSucceeded {
                    appendLog("Dragon control closed after confirming the request")
                }
                finishDragonCommand()
                return
            }
            if dragonCommandConnected {
                if dragonCommandCanRetryAfterNoResult,
                   !pendingDragonEndpoints.isEmpty {
                    let label = activeDragonEndpoint?.label ?? "current path"
                    startNextDragonControlEndpoint(
                        after: "Dragon control \(label) closed without a result; trying the fallback path"
                    )
                    return
                }
                dragonRuntimeStatus = "CONTROL ERROR · NO RESULT"
                appendLog("Dragon control connection failed after the command was sent: \(message)")
                finishDragonCommand()
            } else {
                let label = activeDragonEndpoint?.label ?? "current path"
                startNextDragonControlEndpoint(after: "Dragon control \(label) failed: \(message)")
            }
        case .stopped:
            // TelnetClient emits .stopped once while replacing an old
            // connection. Only treat closure after .ready as completion.
            guard dragonCommandInFlight, dragonCommandConnected else { return }
            if dragonCommandResponded {
                finishDragonCommand()
            } else {
                if dragonCommandCanRetryAfterNoResult,
                   !pendingDragonEndpoints.isEmpty {
                    let label = activeDragonEndpoint?.label ?? "current path"
                    startNextDragonControlEndpoint(
                        after: "Dragon control \(label) closed without a result; trying the fallback path"
                    )
                    return
                }
                dragonRuntimeStatus = "NO RESULT · CONNECTION CLOSED"
                appendLog("Dragon control shell closed without returning a result marker")
                finishDragonCommand()
            }
        case .idle, .connecting:
            break
        }
    }

    private func handleDragonControlLine(_ rawLine: String) {
        if let event = SC2TelemetryParser.deviceMarkerPayload(
            "__PARROTLAB_INSTALL__=",
            in: rawLine
        ) {
            guard event == "READY" || event == "ERROR" else { return }
            dragonCommandResponded = true
            dragonCommandTimeoutTimer?.invalidate()
            dragonCommandTimeoutTimer = nil
            if event == "READY" {
                dragonCommandSucceeded = true
                dragonRuntimeStatus = "LAB FILES READY"
                appendLog("Dragon Lab files are executable and match the verified FTP upload")
                showToolAlert(
                    title: "Dragon Lab installed",
                    message: "Both firmware-specific 900p binaries and the runtime helper are verified in /data/ftp/internal_000. The helper will automatically select the 4.4.2 or 4.7.1 binary at launch. Stock /usr/bin/dragon-prog was not changed and Dragon was not restarted.",
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
        guard let payload = SC2TelemetryParser.deviceMarkerPayload(
            "__PARROTLAB_DRAGON__=",
            in: rawLine
        ) else { return }
        let fields = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let event = fields.first else { return }
        guard ["QUEUED", "RUNNING", "RESTORED", "STATUS", "ERROR"].contains(event) else {
            appendLog("Dragon helper: \(payload)")
            return
        }
        dragonCommandResponded = true
        dragonCommandTimeoutTimer?.invalidate()
        dragonCommandTimeoutTimer = nil

        switch event {
        case "QUEUED":
            dragonCommandSucceeded = true
            let operation = fields.count > 1 ? fields[1] : "apply"
            if operation == "restore" {
                queuedDragonOperation = .restore
                dragonRuntimeStatus = "RESTORE QUEUED · WAITING FOR LINK"
            } else {
                let summary = pendingDragonLaunchSummary ?? "DRAGON VIDEO"
                queuedDragonOperation = .launch(summary)
                dragonRuntimeStatus = "QUEUED · \(summary)"
            }
            queuedDragonTelemetryNotBefore = Date().addingTimeInterval(3)
            appendLog("Detached Dragon worker accepted; the SC2 relay may drop until Dragon restarts")
        case "RUNNING":
            dragonCommandSucceeded = true
            if let summary = pendingDragonLaunchSummary {
                dragonRuntimeStatus = "RUNNING · \(summary)"
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
            break
        }
        updateInterface()
    }

    private func finishDragonCommand() {
        guard dragonCommandInFlight else { return }
        if !dragonCommandSucceeded, !dragonRuntimeStatus.hasPrefix("ERROR"),
           !dragonRuntimeStatus.hasPrefix("CONTROL ERROR"),
           !dragonRuntimeStatus.hasPrefix("NO RESULT") {
            dragonRuntimeStatus = "NO RESULT · CHECK HELPER"
        }
        dragonCommandInFlight = false
        dragonCommandConnected = false
        dragonCommandResponded = false
        dragonCommandCanRetryAfterNoResult = false
        dragonCommandTimeoutTimer?.invalidate()
        dragonCommandTimeoutTimer = nil
        pendingDragonCommand = nil
        pendingDragonEndpoints.removeAll(keepingCapacity: false)
        activeDragonEndpoint = nil
        pendingDragonLaunchSummary = nil
        pendingDragonInstall = false
        updateInterface()

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
            videoCodedFormatStatus = "CODED waiting"
            videoMetadataPresence = VideoMetadataPresence()
            snapshot.videoBitrateKbps = nil
            snapshot.videoEncodedAUFPS = nil
            snapshot.videoUniqueTimestampFPS = nil
            snapshot.videoDecodedFPS = nil
            snapshot.videoDisplayRefreshFPS = nil
            snapshot.videoProcessedFPS = nil
            snapshot.videoProcessingDroppedFrames = 0
            snapshot.videoProcessingLatencyMs = nil
            snapshot.videoProcessedWidth = nil
            snapshot.videoProcessedHeight = nil
            snapshot.videoTemporalHistoryDepth = 0
            snapshot.videoTemporalHistoryAgeMs = nil
            snapshot.videoTemporalMotionAvailable = false
            snapshot.videoTemporalMotionConfidence = nil
            snapshot.videoTemporalReprojectionStatus = "BYPASSED · NO FRAME MOTION"
            snapshot.videoTemporalFlowLatencyMs = nil
            snapshot.videoTemporalHistoryUsed = false
            snapshot.videoLastRTPTimestamp = nil
            snapshot.videoMotionAssociationOffsetMs = nil
            snapshot.videoCameraCalibrationStatus = Bebop900pCameraCalibration.profile.statusLabel
            snapshot.videoCameraReadoutStatus = "ROW LUT 31.167 ms · CURVED LEFT→RIGHT"
            snapshot.videoRollingShutterStatus = "RS OFF · CALIBRATION AVAILABLE"
            snapshot.videoPackets = 0
            snapshot.videoDuplicatePackets = 0
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
        rawArchiveRecorder.resetParameterSets()
        do {
            try rtpReceiver.start(port: port)
            videoRunning = true
            videoButton.title = "Stop video"
            videoModePopup.isEnabled = false
            videoStatus = "Listening UDP \(port) · probing SC2"
            if let profile = mode.expectedDragonProfile {
                appendLog("Starting \(mode.menuTitle) receiver; expected Dragon profile: \(profile)")
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
            if line.contains("state:") {
                handleFreshFlightState()
            }
            updateInterface()
        }
    }

    private func handleFreshFlightState() {
        let now = Date()
        lastFlightStateUpdate = now
        if let queuedDragonOperation,
           now >= (queuedDragonTelemetryNotBefore ?? .distantPast) {
            switch queuedDragonOperation {
            case .launch(let summary):
                dragonRuntimeStatus = "RUNNING · \(summary)"
                appendLog("Drone telemetry returned after the detached Dragon restart")
            case .restore:
                dragonRuntimeStatus = "STOCK RESTORED"
                videoModePopup.selectItem(withTag: VideoReceiveMode.compatibility.rawValue)
                hudView.videoView.receiveMode = .compatibility
                appendLog("Drone telemetry returned after restoring stock Dragon")
            }
            self.queuedDragonOperation = nil
            queuedDragonTelemetryNotBefore = nil
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

        let gpsState: String
        switch snapshot.gpsFixed {
        case true: gpsState = "FIX"
        case false: gpsState = "NO FIX"
        case nil: gpsState = "WAITING"
        }
        navigationLabel.stringValue = [
            "GPS \(gpsState) · \(snapshot.satelliteCount.map { "\($0) SAT" } ?? "— SAT")",
            "LAT \(snapshot.latitude.map { String(format: "%.6f", $0) } ?? "—")",
            "LON \(snapshot.longitude.map { String(format: "%.6f", $0) } ?? "—")",
            "SPEED \(snapshot.horizontalSpeed.map { String(format: "%.1f m/s", $0) } ?? "—")",
            "HOME \(snapshot.distanceFromHome.map { String(format: "%.0f m", $0) } ?? "—")",
            arsdkConnected ? "SOURCE ARSDK · SC2" : "SOURCE WAITING"
        ].joined(separator: "\n")

        healthLabel.stringValue = [
            "BATTERY \(number(snapshot.sc2BatteryPercent, "%"))",
            "CPU \(number(snapshot.sc2TemperatureC, "°C"))",
            snapshot.sc2PowerState ?? "—"
        ].joined(separator: "\n")

        var videoLines = [
            "MODE \(selectedVideoMode.statusLabel) · ENH \(hudView.videoView.enhancementPreset.statusLabel)",
            "\(videoFormatStatus) · OUT \(processedOutputStatus)",
            videoStatus,
            "RTP \(snapshot.videoBitrateKbps.map { "\($0) kbps" } ?? "waiting") · LOST \(snapshot.videoPacketsLost)",
            "FPS AU \(fps(snapshot.videoEncodedAUFPS)) · DEC \(fps(snapshot.videoDecodedFPS)) · PROC \(fps(snapshot.videoProcessedFPS))",
            snapshot.videoRollingShutterStatus,
            processedRecordingStatus
        ]
        if developerVideoDiagnosticsEnabled {
            videoLines.append(contentsOf: [
                "SCALER \(hudView.videoView.spatialScalingMode.statusLabel) · \(videoCodedFormatStatus)",
                metadataStatus,
                "PKT \(snapshot.videoPackets) · DUP \(snapshot.videoDuplicatePackets) · JIT \(snapshot.videoJitterMs.map { String(format: "%.1f ms", $0) } ?? "—")",
                "RTP-TS FPS \(fps(snapshot.videoUniqueTimestampFPS)) · DISPLAY \(fps(snapshot.videoDisplayRefreshFPS))",
                "PROCESS \(snapshot.videoProcessingLatencyMs.map { String(format: "%.1f ms", $0) } ?? "—") · DROP \(snapshot.videoProcessingDroppedFrames)",
                "TEMPORAL \(snapshot.videoTemporalHistoryDepth)/3 · \(snapshot.videoTemporalHistoryAgeMs.map { String(format: "%.1f ms", $0) } ?? "—")",
                "MOTION \(snapshot.videoTemporalMotionAvailable ? "AU-SYNC" : "WAITING") · CONF \(snapshot.videoTemporalMotionConfidence.map { String(format: "%.2f", $0) } ?? "—")",
                "FLOW \(snapshot.videoTemporalFlowLatencyMs.map { String(format: "%.1f ms", $0) } ?? "—") · HISTORY \(snapshot.videoTemporalHistoryUsed ? "USED" : "RESET/BYPASS")",
                "RTP TS \(snapshot.videoLastRTPTimestamp.map(String.init) ?? "—") · ASSOCIATION \(snapshot.videoMotionAssociationOffsetMs == nil ? "—" : "EXACT")",
                snapshot.videoTemporalReprojectionStatus,
                "CAL \(snapshot.videoCameraCalibrationStatus)",
                snapshot.videoCameraReadoutStatus
            ])
        }
        videoLabel.maximumNumberOfLines = developerVideoDiagnosticsEnabled ? 24 : 7
        videoLabel.stringValue = videoLines.joined(separator: "\n")

        let connected = connectButton.title == "Disconnect"
        let landed = hasFreshLandedTelemetry
        let deviceOperationActive = toolUploadInFlight || dragonCommandInFlight || dronePhotoInFlight ||
            persistentTelnetInstallInFlight || sc2DriverInstallInFlight
        hostField.isEnabled = !deviceOperationActive
        connectButton.isEnabled = !deviceOperationActive
        let profileSelectionEnabled = connected && !dragonCommandInFlight &&
            !toolUploadInFlight && !persistentTelnetInstallInFlight &&
            !sc2DriverInstallInFlight
        let customSelected = customDragonModeSelected
        let profileApplyEnabled = profileSelectionEnabled && (temporalDragonModeSelected || landed)
        dragonResolutionPopup.isEnabled = profileSelectionEnabled
        dragonBitrateSlider.isEnabled = profileSelectionEnabled && !customSelected
        dragonLockRateButton.isEnabled = profileSelectionEnabled && !customSelected
        dragonCustomArgumentsLabel.isHidden = !customSelected
        dragonCustomArgumentsField.isHidden = !customSelected
        dragonCustomArgumentsField.isEnabled = profileSelectionEnabled && landed && customSelected
        dragonApplyButton.title = customSelected ? "Start custom" : "Apply profile"
        dragonApplyButton.isEnabled = profileApplyEnabled
        dragonRestoreButton.isEnabled = profileSelectionEnabled && landed

        let recordingActive = streamRecorder.isActive
        browseMediaButton.isEnabled = !recordingActive && !dronePhotoInFlight
        recordingButton.isEnabled = videoRunning && (!recordingActive || streamRecorder.isRecording)
        pictureFormatPopup.isEnabled = !pictureWriteInFlight
        pictureButton.isEnabled = videoRunning && hudView.videoView.latestFrameImage() != nil && !pictureWriteInFlight
        droneFisheyeButton.isEnabled = connected && !dronePhotoInFlight && !deviceOperationActive

        if dragonCommandInFlight {
            dragonStatusLabel.stringValue = dragonRuntimeStatus
            dragonStatusLabel.textColor = .systemYellow
        } else if !connected {
            dragonStatusLabel.stringValue = "SC2 OFFLINE"
            dragonStatusLabel.textColor = LabVisualStyle.mutedText
        } else if !landed && temporalDragonModeSelected {
            dragonStatusLabel.stringValue = "TEMPORAL READY · NO FLIGHT INTERLOCK"
            dragonStatusLabel.textColor = .systemGreen
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
        let motion = videoMetadataPresence.hasDecodedVideoMetadataV2 ? "MOTION SYNC ✓" : "MOTION —"
        return "META \(sei)  \(rtp)  \(motion)"
    }

    private var processedOutputStatus: String {
        guard let width = snapshot.videoProcessedWidth,
              let height = snapshot.videoProcessedHeight,
              width > 0, height > 0 else { return "waiting" }
        return "\(width)x\(height)"
    }

    private var processedRecordingStatus: String {
        guard streamRecorder.isActive else {
            return rawH264ArchiveEnabled ? "REC PROCESSED · RAW ARCHIVE ARMED" : "REC PROCESSED"
        }
        guard let stats = processedRecordingStats else { return "REC STARTING"
        }
        return String(
            format: "REC %dx%d · %.1f FPS · %.1f Mbps · DROP %llu+%llu · Q %d/%@",
            stats.width,
            stats.height,
            stats.encodedFPS,
            stats.bitrateMbps,
            stats.droppedBeforeEncoder,
            stats.droppedByEncoder,
            stats.encoderInFlight,
            ByteCountFormatter.string(fromByteCount: Int64(stats.diskQueueBytes), countStyle: .memory)
        )
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
            if rawH264ArchiveEnabled {
                do {
                    let rawURL = try rawArchiveRecorder.start(
                        directory: mediaDirectoryURL,
                        at: started,
                        rawArchive: true
                    )
                    appendLog("Untouched diagnostic H.264 archive started: \(rawURL.path)")
                } catch {
                    appendLog("Processed recording will continue, but raw archive could not start: \(error.localizedDescription)")
                }
            }
            recordingStartedAt = started
            processedRecordingStats = nil
            recordingButton.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
            recordingButton.bezelColor = .systemRed
            recordingTimer?.invalidate()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.updateRecordingButton()
            }
            updateRecordingButton()
            updateInterface()
            appendLog("Processed Parrot Lab H.264 recording started: \(temporaryURL.path)")
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
        rawArchiveRecorder.stop()
    }

    private func updateRecordingButton() {
        guard let recordingStartedAt, streamRecorder.isRecording else { return }
        let elapsed = Date().timeIntervalSince(recordingStartedAt)
        recordingButton.title = "Stop \(MediaFileNamer.durationStamp(elapsed))"
    }

    private func recordingFinished(_ result: H264RecordingResult) {
        rawArchiveRecorder.stop()
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
        processedRecordingStats = nil
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

    func convertFinishedH264ToMP4() {
        guard !videoConversionInFlight, !mp4Converter.isConverting else {
            showMediaAlert("A video conversion is already running.")
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.title = "Choose a finished Parrot Lab H.264 recording"
        openPanel.prompt = "Choose Recording"
        openPanel.allowedContentTypes = [UTType(filenameExtension: "h264") ?? .data]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.directoryURL = mediaDirectoryURL
        guard openPanel.runModal() == .OK, let inputURL = openPanel.url else { return }

        let savedQuality = UserDefaults.standard.object(forKey: Self.mp4QualityPreferenceKey) as? Int
            ?? MP4ConversionQuality.maximum
        let qualityView = MP4ConversionQualityView(initialPercent: savedQuality)
        let qualityAlert = NSAlert()
        qualityAlert.alertStyle = .informational
        qualityAlert.messageText = "MP4 conversion quality"
        qualityAlert.informativeText = "100% packages the original H.264 stream into MP4 without changing a frame. Lower settings re-encode the video to reduce its size."
        qualityAlert.accessoryView = qualityView
        qualityAlert.addButton(withTitle: "Continue")
        qualityAlert.addButton(withTitle: "Cancel")
        guard qualityAlert.runModal() == .alertFirstButtonReturn else { return }
        let quality = qualityView.quality
        UserDefaults.standard.set(quality.percent, forKey: Self.mp4QualityPreferenceKey)

        let savePanel = NSSavePanel()
        savePanel.title = "Save converted MP4"
        savePanel.prompt = "Convert"
        savePanel.allowedContentTypes = [.mpeg4Movie]
        savePanel.canCreateDirectories = true
        savePanel.directoryURL = inputURL.deletingLastPathComponent()
        savePanel.nameFieldStringValue = inputURL.deletingPathExtension().lastPathComponent + ".mp4"
        guard savePanel.runModal() == .OK, let outputURL = savePanel.url else { return }

        beginMP4Conversion(inputURL: inputURL, outputURL: outputURL, quality: quality)
    }

    private func beginMP4Conversion(
        inputURL: URL,
        outputURL: URL,
        quality: MP4ConversionQuality
    ) {
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .regular
        progress.startAnimation(nil)
        progress.frame = NSRect(x: 0, y: 0, width: 390, height: 32)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = quality.copiesOriginalStream
            ? "Packaging original video into MP4…"
            : "Converting video to MP4…"
        alert.informativeText = "Source: \(inputURL.lastPathComponent)\nQuality: \(quality.displayLabel)"
        alert.accessoryView = progress
        alert.addButton(withTitle: "Cancel")
        videoConversionInFlight = true
        videoConversionProgressAlert = alert
        appendLog("MP4 conversion started: \(inputURL.path) → \(outputURL.path) · \(quality.displayLabel)")

        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] _ in
                guard let self, self.videoConversionInFlight else { return }
                self.appendLog("Cancelling MP4 conversion")
                self.mp4Converter.cancel()
            }
        }
        mp4Converter.convert(inputURL: inputURL, outputURL: outputURL, quality: quality)
    }

    private func mp4ConversionFinished(_ result: Result<H264MP4ConversionResult, Error>) {
        videoConversionInFlight = false
        if let alert = videoConversionProgressAlert {
            if let parent = alert.window.sheetParent {
                parent.endSheet(alert.window)
            } else {
                alert.window.orderOut(nil)
            }
        }
        videoConversionProgressAlert = nil

        switch result {
        case .failure(let error):
            appendLog("MP4 conversion failed: \(error.localizedDescription)")
            showMediaAlert("Could not convert the video: \(error.localizedDescription)")
        case .success(let conversion):
            appendLog("MP4 saved: \(conversion.outputURL.path) · \(conversion.quality.displayLabel)")
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "MP4 video saved"
            alert.informativeText = "Saved \(conversion.outputURL.lastPathComponent) to:\n\(conversion.outputURL.deletingLastPathComponent().path)"
            alert.addButton(withTitle: "Reveal in Finder")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([conversion.outputURL])
            }
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

    @objc private func captureDroneFisheye() {
        guard connectButton.title == "Disconnect" else {
            showMediaAlert("Connect Parrot Lab to the SkyController 2 first.")
            return
        }
        guard !dronePhotoInFlight else { return }
        do {
            try FileManager.default.createDirectory(at: mediaDirectoryURL, withIntermediateDirectories: true)
        } catch {
            showMediaAlert("Could not create the media directory: \(error.localizedDescription)")
            return
        }

        dronePhotoInFlight = true
        droneFisheyeButton.title = "PREPARING 4K FISHEYE"
        updateInterface()
        appendLog("Preparing stock 4K fisheye capture through the SC2")
        droneMediaFTP.snapshot { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.failDronePhoto(error)
            case .success(let baseline):
                self.dronePhotoBaseline = baseline
                let host = self.hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                self.droneFisheyeCapture.start(host: host)
            }
        }
    }

    private func droneFisheyeCommandFinished(_ result: Result<Void, Error>) {
        switch result {
        case .failure(let error):
            failDronePhoto(error)
        case .success:
            droneFisheyeButton.title = "DOWNLOADING 4K FISHEYE"
            appendLog("Drone confirmed the fisheye photo; waiting for the original JPEG on FTP")
            droneMediaFTP.downloadNewPhoto(excluding: dronePhotoBaseline, to: mediaDirectoryURL) { [weak self] result in
                self?.finishDronePhoto(result)
            }
        }
    }

    private func finishDronePhoto(_ result: Result<URL, Error>) {
        dronePhotoInFlight = false
        dronePhotoBaseline.removeAll()
        droneFisheyeButton.title = "Drone 4K Fisheye"
        updateInterface()
        switch result {
        case .failure(let error):
            appendLog("4K fisheye capture failed: \(error.localizedDescription)")
            showMediaAlert(error.localizedDescription)
        case .success(let url):
            appendLog("Original drone JPEG saved unchanged: \(url.path)")
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "4K fisheye saved"
            alert.informativeText = "Saved \(url.lastPathComponent) to:\n\(url.deletingLastPathComponent().path)"
            alert.addButton(withTitle: "Reveal in Finder")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func failDronePhoto(_ error: Error) {
        finishDronePhoto(Result<URL, Error>.failure(error))
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
        mp4Converter.cancel()
        toolInstaller.cancel()
        sc2USBDiscovery.cancel()
        droneFisheyeCapture.cancel()
        stopARSDKTelemetry()
        bebopSystemTelnet.stop()
        sc2DiscoveryTimeoutTimer?.invalidate()
        sc2DiscoveryTimeoutTimer = nil
        sc2DiscoveryTelnet.stop()
        sc2DriverTelnet.stop()
        rfPowerTimeoutTimer?.invalidate()
        rfPowerTimeoutTimer = nil
        rfPowerSC2Telnet.stop()
        rfPowerBebopTelnet.stop()
        recordingTimer?.invalidate()
        recordingTimer = nil
        streamRecorder.stopAndWait()
        rawArchiveRecorder.stopAndWait()
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
    private func fps(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "—"
    }
    private func degrees(_ value: Double?) -> String {
        value.map { String(format: "%.1f°", $0 * 180 / .pi) } ?? "—"
    }
}
