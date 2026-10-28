import AppKit

/// ANAFI camera workspace, separate from Bebop's ARStream/Dragon settings.
final class AnafiViewController: NSViewController {
    let session = AnafiSession()
    private let stream = AnafiRTSPClient()
    private let video = H264VideoView(frame: .zero)
    private let recorder = ProcessedH264Recorder()
    private let converter = H264MP4Converter()
    private let discovery = AnafiDiscovery()
    private var discoveryPort: UInt16 = 44_444
    var onExit: (() -> Void)?
    var onControlsChanged: (() -> Void)?
    var onNeutralize: (() -> Void)?
    var onOwnerMaintenanceRequested: (() -> Void)?
    private let maintenanceAccess = SC3MaintenanceAccess(address: AnafiRoute.direct.defaultHost)
    private(set) var state = AnafiSessionState()
    private var connecting = false
    private var streamWanted = false
    private var streamLive = false
    private var shuttingDown = false
    private var recordingConversion = false
    private var route = AnafiRoute.direct
    private let host = NSTextField(string: AnafiRoute.direct.defaultHost)
    private let bridgePort = NSTextField(string: "4321")
    private let routePicker = NSPopUpButton()
    private let connectionLabel = NSTextField(wrappingLabelWithString: "")
    private let flightLabel = NSTextField(wrappingLabelWithString: "")
    private let videoLabel = NSTextField(labelWithString: "Live preview · ready to connect")
    private let activity = NSTextField(wrappingLabelWithString: "ANAFI 4K · experimental support")
    private let cameraSummary = NSTextField(wrappingLabelWithString: "Camera settings appear after connecting.")
    private let inputStatus = NSTextField(wrappingLabelWithString: "")
    private let cameraMode = NSPopUpButton(), recordingMode = NSPopUpButton(), resolution = NSPopUpButton(), fps = NSPopUpButton()
    private let hyperlapse = NSPopUpButton(), photoMode = NSPopUpButton(), photoFormat = NSPopUpButton(), photoFile = NSPopUpButton()
    private let burst = NSPopUpButton(), bracket = NSPopUpButton(), style = NSPopUpButton(), wb = NSPopUpButton(), ev = NSPopUpButton()
    private let streamingMode = NSPopUpButton(), enhancement = NSPopUpButton()
    private let interval = NSSlider(value: 2, minValue: 0.1, maxValue: 60, target: nil, action: nil)
    private let intervalLabel = NSTextField(labelWithString: "2.0 s")
    private let tilt = NSSlider(value: 0, minValue: -90, maxValue: 90, target: nil, action: nil)
    private let zoom = NSSlider(value: 1, minValue: 1, maxValue: 3, target: nil, action: nil)
    private let tiltLabel = NSTextField(labelWithString: "0°"), zoomLabel = NSTextField(labelWithString: "1×")
    private let pitchSpeed = NSSlider(value: 20, minValue: 1, maxValue: 90, target: nil, action: nil)
    private let pitchSpeedLabel = NSTextField(labelWithString: "—")
    private let hdr = NSButton(checkboxWithTitle: "HDR", target: nil, action: nil)
    private let macControls = NSButton(checkboxWithTitle: "Enable Mac flight controls", target: nil, action: nil)
    private var connectButton = NSButton(), videoButton = NSButton(), sdRecordButton = NSButton(), photoButton = NSButton()
    private var trimButton = NSButton(), takeoffButton = NSButton(), landButton = NSButton(), emergencyButton = NSButton()
    private var applyVideoButton = NSButton(), applyPhotoButton = NSButton(), exitButton = NSButton(), localRecordButton = NSButton()
    private var snapshotButton = NSButton(), focusButton = NSButton()
    private var inspector: NSScrollView?
    private var recentActivity: [String] = []
    private var mediaDirectory = MediaFileNamer.defaultDirectory
    private var lastCameraID: UInt8?
    private var dirtyVideo = false
    private var dirtyPhoto = false
    private var parameterSets: [UInt8: Data] = [:]

    var controlsAvailable: Bool { state.canPilot && macControls.state == .on }
    var canExit: Bool { !state.connected && !connecting && !recorder.isActive && !recordingConversion }
    var diagnosticSummary: String { "ANAFI route=\(route.title) connected=\(state.connected) flight=\(state.flightLabel) " +
        "camera=\(state.camera.id?.description ?? "unknown") video=\(streamLive) requested=\(streamWanted) " +
        "\(recorder.diagnosticSummary) converting=\(recordingConversion)" }

    override func loadView() {
        view = LabBackgroundView(); LabVisualStyle.applyTheme(.air, to: view)
        let root = column(spacing: 10); root.edgeInsets = .init(top: 16, left: 16, bottom: 16, right: 16)
        pin(root, to: view)
        let heading = row()
        heading.distribution = .fill
        if let icon = LabVisualStyle.brandIcon() {
            let image = NSImageView(image: icon); image.widthAnchor.constraint(equalToConstant: 40).isActive = true
            image.heightAnchor.constraint(equalToConstant: 40).isActive = true; heading.addArrangedSubview(image)
        }
        let title = column(spacing: 2)
        title.addArrangedSubview(label("Parrot Lab", size: 24, weight: .bold))
        title.addArrangedSubview(label("ANAFI 4K · CAMERA & FLIGHT", size: 11, muted: true))
        heading.addArrangedSubview(title); heading.addArrangedSubview(spacer())
        let settingsButton = NSButton(title: "Settings", target: nil, action: #selector(AppDelegate.showSettings(_:)))
        settingsButton.bezelStyle = .rounded; heading.addArrangedSubview(settingsButton)
        exitButton = button("Air / Ground / MiniDrone", #selector(exitWorkspace))
        heading.addArrangedSubview(exitButton); root.addArrangedSubview(heading)

        let connection = column(spacing: 8), connectionRow = row()
        connectionRow.distribution = .fill
        routePicker.addItems(withTitles: AnafiRoute.allCases.map(\.title))
        routePicker.target = self; routePicker.action = #selector(routeChanged)
        routePicker.widthAnchor.constraint(equalToConstant: 160).isActive = true
        host.widthAnchor.constraint(equalToConstant: 150).isActive = true
        host.setAccessibilityLabel("ANAFI or SC3 address")
        host.delegate = maintenanceAccess
        maintenanceAccess.onUnlock = { [weak self] in self?.onOwnerMaintenanceRequested?() }
        connectionRow.addArrangedSubview(routePicker); connectionRow.addArrangedSubview(host)
        bridgePort.widthAnchor.constraint(equalToConstant: 65).isActive = true
        bridgePort.setAccessibilityLabel("SC3 USB bridge port")
        bridgePort.toolTip = "Port of your local USB/accessory byte bridge. It must forward raw libmux data, not ARSDK UDP."
        connectionRow.addArrangedSubview(bridgePort)
        connectionRow.addArrangedSubview(button("Find", #selector(findDevice)))
        connectionRow.addArrangedSubview(spacer())
        connectButton = button("Connect", #selector(connect)); connectionRow.addArrangedSubview(connectButton)
        videoButton = button("Start video", #selector(toggleVideo)); connectionRow.addArrangedSubview(videoButton)
        focusButton = button("Focus", #selector(toggleFocus)); focusButton.setButtonType(.pushOnPushOff)
        connectionRow.addArrangedSubview(focusButton)
        connection.addArrangedSubview(connectionRow); connection.addArrangedSubview(connectionLabel)
        root.addArrangedSubview(card(connection))

        let content = row(); content.alignment = .top; content.spacing = 14
        content.distribution = .fill
        let preview = column(spacing: 10)
        video.translatesAutoresizingMaskIntoConstraints = false; video.wantsLayer = true
        video.layer?.cornerRadius = 14; video.layer?.masksToBounds = true
        preview.addArrangedSubview(video)
        video.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        preview.addArrangedSubview(videoLabel)
        let capture = row()
        capture.distribution = .fill
        snapshotButton = button("Save frame", #selector(saveFrame)); capture.addArrangedSubview(snapshotButton)
        localRecordButton = button("Record on Mac", #selector(recordLocal)); capture.addArrangedSubview(localRecordButton)
        capture.addArrangedSubview(button("Save to…", #selector(chooseFolder))); capture.addArrangedSubview(spacer())
        preview.addArrangedSubview(capture); content.addArrangedSubview(preview)
        for child in preview.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
        }
        preview.setContentHuggingPriority(.defaultLow, for: .horizontal)
        preview.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.widthAnchor.constraint(equalToConstant: 355).isActive = true
        let document = LabFlippedBackgroundView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; inspector = scroll
        let settings = column(spacing: 12); pin(settings, to: document)
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        for card in [flightCard(), cameraCard(), viewCard()] {
            settings.addArrangedSubview(card); card.widthAnchor.constraint(equalTo: settings.widthAnchor).isActive = true
        }
        content.addArrangedSubview(scroll); scroll.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        root.addArrangedSubview(content); content.setContentHuggingPriority(.defaultLow, for: .vertical)
        activity.font = .monospacedSystemFont(ofSize: 11, weight: .regular); activity.maximumNumberOfLines = 3
        root.addArrangedSubview(card(activity))
        // Leading alignment alone leaves rows at their fitting widths when
        // this controller is embedded or the window is resized.
        for child in root.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        }
        wireCallbacks(); refresh()
    }

    private func flightCard() -> NSView {
        let stack = column(spacing: 9)
        stack.addArrangedSubview(label("FLIGHT", size: 11, weight: .bold, muted: true))
        flightLabel.font = .systemFont(ofSize: 15, weight: .medium); stack.addArrangedSubview(flightLabel)
        let buttons = row()
        trimButton = button("Trim", #selector(trim)); takeoffButton = button("Take off", #selector(takeoff))
        landButton = button("Land", #selector(land))
        [trimButton, takeoffButton, landButton].forEach(buttons.addArrangedSubview); stack.addArrangedSubview(buttons)
        emergencyButton = button("Emergency motor stop", #selector(emergency)); emergencyButton.contentTintColor = .systemRed
        stack.addArrangedSubview(emergencyButton)
        macControls.target = self; macControls.action = #selector(toggleMacControls); stack.addArrangedSubview(macControls)
        stack.addArrangedSubview(label("SC3 keeps stick control until you enable Mac controls.", size: 11, muted: true))
        stack.addArrangedSubview(inputStatus)
        let inputs = row()
        let settings = NSButton(title: "Input settings…", target: nil, action: #selector(AppDelegate.showSettings(_:)))
        settings.bezelStyle = .rounded; inputs.addArrangedSubview(settings)
        let mappings = NSButton(title: "Mappings…", target: nil, action: #selector(AppDelegate.showFlightControlMappings(_:)))
        mappings.bezelStyle = .rounded; inputs.addArrangedSubview(mappings); stack.addArrangedSubview(inputs)
        return card(stack)
    }
    private func cameraCard() -> NSView {
        let stack = column(spacing: 9)
        stack.addArrangedSubview(label("AIRCRAFT CAMERA · SD CARD", size: 11, weight: .bold, muted: true))
        stack.addArrangedSubview(cameraSummary)
        addSetting("Camera", cameraMode, to: stack, action: #selector(cameraModeChanged))
        let videoOptions = column(spacing: 8)
        addSetting("Video mode", recordingMode, to: videoOptions, action: #selector(videoChoicesChanged))
        addSetting("Resolution", resolution, to: videoOptions, action: #selector(videoChoicesChanged))
        addSetting("Frame rate", fps, to: videoOptions, action: #selector(videoChoicesChanged))
        addSetting("Hyperlapse", hyperlapse, to: videoOptions, action: #selector(videoChoicesChanged))
        applyVideoButton = button("Apply video settings", #selector(applyVideo)); videoOptions.addArrangedSubview(applyVideoButton)
        stack.addArrangedSubview(LabDisclosureButton(title: "Video settings", views: [videoOptions], expanded: true))
        stack.addArrangedSubview(videoOptions); videoOptions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        sdRecordButton = button("Record on ANAFI", #selector(recordSD)); stack.addArrangedSubview(sdRecordButton)
        stack.addArrangedSubview(separator())
        let photoOptions = column(spacing: 8)
        addSetting("Photo mode", photoMode, to: photoOptions, action: #selector(photoChoicesChanged))
        addSetting("Photo frame", photoFormat, to: photoOptions, action: #selector(photoChoicesChanged))
        addSetting("Photo file", photoFile, to: photoOptions, action: #selector(photoChoicesChanged))
        addSetting("Burst", burst, to: photoOptions, action: #selector(photoChoicesChanged)); addSetting("Bracketing", bracket, to: photoOptions, action: #selector(photoChoicesChanged))
        interval.target = self; interval.action = #selector(photoChoicesChanged)
        let intervalRow = row(); intervalRow.addArrangedSubview(interval); intervalRow.addArrangedSubview(intervalLabel)
        addSetting("Interval", intervalRow, to: photoOptions)
        applyPhotoButton = button("Apply photo settings", #selector(applyPhoto)); photoOptions.addArrangedSubview(applyPhotoButton)
        stack.addArrangedSubview(LabDisclosureButton(title: "Photo settings", views: [photoOptions]))
        stack.addArrangedSubview(photoOptions); photoOptions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        photoButton = button("Take photo on ANAFI", #selector(takePhoto)); stack.addArrangedSubview(photoButton)
        stack.addArrangedSubview(separator())
        let colourOptions = column(spacing: 8)
        addSetting("Colour profile", style, to: colourOptions, action: #selector(styleChanged))
        addSetting("White balance", wb, to: colourOptions, action: #selector(wbChanged))
        addSetting("Exposure (EV)", ev, to: colourOptions, action: #selector(evChanged))
        hdr.target = self; hdr.action = #selector(hdrChanged); colourOptions.addArrangedSubview(hdr)
        stack.addArrangedSubview(LabDisclosureButton(title: "Colour & exposure", views: [colourOptions]))
        stack.addArrangedSubview(colourOptions); colourOptions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(label("Choices follow the drone's capabilities. 4K applies to SD recording; the live feed has its own resolution.", size: 11, muted: true))
        return card(stack)
    }
    private func viewCard() -> NSView {
        let stack = column(spacing: 9)
        stack.addArrangedSubview(label("GIMBAL & LIVE VIEW", size: 11, weight: .bold, muted: true))
        let pitchRow = row(); pitchRow.addArrangedSubview(tilt); pitchRow.addArrangedSubview(tiltLabel)
        tilt.target = self; tilt.action = #selector(tiltChanged); addSetting("Camera pitch", pitchRow, to: stack)
        let speedRow = row(); speedRow.addArrangedSubview(pitchSpeed); speedRow.addArrangedSubview(pitchSpeedLabel)
        pitchSpeed.target = self; pitchSpeed.action = #selector(pitchSpeedChanged); addSetting("Pitch speed", speedRow, to: stack)
        let zoomRow = row(); zoomRow.addArrangedSubview(zoom); zoomRow.addArrangedSubview(zoomLabel)
        zoom.target = self; zoom.action = #selector(zoomChanged); addSetting("Zoom", zoomRow, to: stack)
        stack.addArrangedSubview(button("Center camera", #selector(centerCamera)))
        addSetting("Live feed", streamingMode, to: stack, action: #selector(streamingChanged))
        enhancement.addItems(withTitles: VideoEnhancementPreset.allCases.map(\.menuTitle))
        enhancement.target = self; enhancement.action = #selector(enhancementChanged)
        addSetting("Mac image", enhancement, to: stack)
        return card(stack)
    }
    private func wireCallbacks() {
        discovery.onResult = { [weak self] host, port in
            self?.host.stringValue = host; self?.discoveryPort = port; self?.log("Found ARSDK at \(host):\(port)")
        }
        discovery.onStatus = { [weak self] in self?.log($0) }
        session.onChange = { [weak self] value in
            guard let self, !self.shuttingDown else { return }
            let wasConnected = self.state.connected
            self.state = value; self.connecting = !value.connected && value.message.hasPrefix("Connecting")
            if !value.connected {
                self.macControls.state = .off
                if wasConnected { self.onNeutralize?() }
                if wasConnected, self.route.usesMux { self.stopStream() }
            }
            if self.lastCameraID != value.camera.id {
                self.lastCameraID = value.camera.id; self.dirtyVideo = false; self.dirtyPhoto = false
            }
            self.populateCamera()
            self.refresh(); self.onControlsChanged?()
            if value.connected, !wasConnected, self.route.usesMux { self.startStream(); self.refresh() }
        }
        session.onLog = { [weak self] in self?.log($0) }
        session.onMuxVideo = { [weak self] result in
            guard let self, !self.shuttingDown, self.route.usesMux, self.streamWanted else { return }
            switch result {
            case .success(let url): self.stream.start(url: url)
            case .failure(let error): self.stopStream(); self.log(error.localizedDescription); self.refresh()
            }
        }
        stream.onAccessUnit = { [weak self] in self?.display($0) }
        stream.onState = { [weak self] message, live in
            guard let self, !self.shuttingDown else { return }
            if message == "Video stopped", self.streamWanted { return }
            self.streamLive = live; self.videoLabel.stringValue = message
            if !live, !message.hasPrefix("Opening") { self.streamWanted = false; self.recorder.stop() }
            self.log(message); self.refresh()
        }
        stream.onStats = { [weak self] stats in
            self?.videoLabel.stringValue = String(format: "Live ANAFI · %.1f fps · %d kb/s · %.1f ms jitter", stats.encodedAUFPS, stats.bitrateKbps, stats.jitterMs)
        }
        video.onCodedFormat = { [weak self] width, height in self?.log("Live feed \(width) × \(height)") }
        video.onDebug = { [weak self] in self?.log($0) }
        video.onProcessedFrame = { [weak self] in self?.recorder.observe($0) }
        recorder.onFinished = { [weak self] result in
            guard let self, !self.shuttingDown else { return }
            if let error = result.errorDescription { self.log("Recording: \(error)"); self.refresh(); return }
            self.recordingConversion = true; self.refresh()
            self.converter.convert(inputURL: result.url, outputURL: result.url.deletingPathExtension().appendingPathExtension("mp4"), quality: .original)
        }
        converter.onCompletion = { [weak self] result in
            guard let self, !self.shuttingDown else { return }
            self.recordingConversion = false
            switch result {
            case .success(let result): self.log("Mac recording saved: \(result.outputURL.lastPathComponent)")
            case .failure(let error): self.log("MP4 conversion: \(error.localizedDescription); original H.264 retained")
            }
            self.refresh()
        }
    }
    private func refresh() {
        guard isViewLoaded else { return }
        connectionLabel.stringValue = state.message
        connectionLabel.textColor = state.connected ? .systemGreen : LabVisualStyle.mutedText
        flightLabel.stringValue = "\(state.flightLabel) · Battery \(state.battery.map { "\($0)%" } ?? "—")" +
            (state.altitude.map { String(format: "\nAltitude %.1f m", $0) } ?? "")
        connectButton.title = state.connected || connecting ? "Disconnect" : "Connect"
        routePicker.isEnabled = !state.connected && !connecting && !streamWanted
        host.isEnabled = routePicker.isEnabled
        host.isHidden = route.usesMux
        bridgePort.isHidden = !route.usesMux; bridgePort.isEnabled = routePicker.isEnabled
        videoButton.title = streamWanted ? "Stop video" : "Start video"
        videoButton.isEnabled = !route.usesMux || state.connected || streamWanted
        exitButton.isEnabled = canExit
        trimButton.isEnabled = state.connected && state.linkedAnafi && state.flightState == 0
        takeoffButton.isEnabled = trimButton.isEnabled
        landButton.isEnabled = state.connected && state.linkedAnafi
        emergencyButton.isEnabled = landButton.isEnabled
        macControls.isEnabled = state.connected && state.linkedAnafi && state.flightState != nil
        let camera = state.camera, available = state.connected && state.linkedAnafi && camera.id != nil
        let busy = camera.recording == true || camera.photoActive
        [cameraMode, recordingMode, resolution, fps, hyperlapse, photoMode, photoFormat, photoFile, burst, bracket,
         style, wb, ev, streamingMode].forEach { $0.isEnabled = available && $0.numberOfItems > 0 && !busy }
        applyVideoButton.isEnabled = available && !busy && validRecordingChoice()
        applyPhotoButton.isEnabled = available && !busy && validPhotoChoice()
        sdRecordButton.title = camera.recording == true ? "Stop ANAFI recording" : "Record on ANAFI"
        sdRecordButton.isEnabled = available && camera.recordingAvailable && camera.mode == 0 && camera.recording != nil
        let photoSequence = camera.photoMode == 3 || camera.photoMode == 4
        photoButton.title = camera.photoActive && photoSequence ? "Stop photo sequence" : "Take photo on ANAFI"
        photoButton.isEnabled = available && camera.photoAvailable && camera.mode == 1 &&
            camera.recording != true && (!camera.photoActive || photoSequence)
        hdr.state = camera.hdr == true ? .on : .off; hdr.isEnabled = available && camera.hdrAvailable && !busy
        tilt.isEnabled = available && camera.gimbalID != nil
        tilt.minValue = Double(camera.pitchMinimum); tilt.maxValue = Double(camera.pitchMaximum)
        pitchSpeed.isEnabled = available && camera.gimbalID != nil && camera.pitchSpeed != nil
        pitchSpeed.minValue = Double(camera.pitchSpeedMinimum); pitchSpeed.maxValue = Double(camera.pitchSpeedMaximum)
        if !pitchSpeed.isHighlighted, let value = camera.pitchSpeed { pitchSpeed.doubleValue = Double(value) }
        pitchSpeedLabel.stringValue = camera.pitchSpeed.map { String(format: "%.0f°/s", $0) } ?? "—"
        zoom.isEnabled = available && camera.zoomAvailable; zoom.maxValue = Double(camera.zoomMaximum)
        if !tilt.isHighlighted { tilt.doubleValue = Double(camera.pitch) }
        if !zoom.isHighlighted { zoom.doubleValue = Double(camera.zoom) }
        tiltLabel.stringValue = String(format: "%.0f°", camera.pitch); zoomLabel.stringValue = String(format: "%.1f×", camera.zoom)
        cameraSummary.stringValue = camera.id == nil ? "Waiting for camera capabilities" :
            "\(camera.mode == 1 ? "Photo" : "Video") · \(camera.recording == true ? "Recording on SD" : "Ready")"
        localRecordButton.title = recorder.isRecording ? "Stop Mac recording" : recorder.isActive || recordingConversion ? "Saving…" : "Record on Mac"
        localRecordButton.isEnabled = recorder.isRecording || (streamLive && !recorder.isActive && !recordingConversion)
        snapshotButton.isEnabled = streamLive
        // States may precede capability lists in an all-states response.
        hyperlapse.isEnabled = hyperlapse.isEnabled && recordingMode.selectedItem?.tag == 1
        burst.isEnabled = burst.isEnabled && photoMode.selectedItem?.tag == 2
        bracket.isEnabled = bracket.isEnabled && photoMode.selectedItem?.tag == 1
        interval.isEnabled = available && !busy && (photoMode.selectedItem?.tag == 3 || photoMode.selectedItem?.tag == 4)
        interval.minValue = Double(photoMode.selectedItem?.tag == 4 ? camera.gpslapseMinimum : camera.timelapseMinimum)
        interval.maxValue = max(60, interval.minValue)
        intervalLabel.stringValue = String(format: "%.1f %@", interval.doubleValue, photoMode.selectedItem?.tag == 4 ? "m" : "s")
    }
    private func populateCamera() {
        let c = state.camera
        choices(cameraMode, ["Video", "Photo"], mask: UInt64(c.cameraModes), selected: c.mode)
        let rm = c.recordingCapabilities.values.reduce(UInt64(0)) { $0 | UInt64($1.modes) }
        choices(recordingMode, ["Standard", "Hyperlapse", "Slow motion", "High frame rate"], mask: rm, selected: dirtyVideo ? nil : c.recordingMode)
        choices(hyperlapse, ["15×", "30×", "60×", "120×", "240×"], mask: UInt64(c.hyperlapseValues), selected: dirtyVideo ? nil : c.hyperlapse)
        updateVideoChoices()
        let pm = c.photoCapabilities.values.reduce(UInt64(0)) { $0 | UInt64($1.modes) }
        choices(photoMode, ["Single", "Bracketing", "Burst", "Timelapse", "GPS lapse"], mask: pm, selected: dirtyPhoto ? nil : c.photoMode)
        updatePhotoChoices()
        choices(burst, ["14 over 4 s", "14 over 2 s", "14 over 1 s", "10 over 4 s", "10 over 2 s", "10 over 1 s", "4 over 4 s", "4 over 2 s", "4 over 1 s"], mask: UInt64(c.burstValues), selected: dirtyPhoto ? nil : c.burst)
        choices(bracket, ["3 ±1 EV", "3 ±2 EV", "3 ±3 EV", "5 ±1/2 EV", "5 ±1/3 EV", "5 ±2/3 EV", "7 ±1/2/3 EV"], mask: UInt64(c.bracketingValues), selected: dirtyPhoto ? nil : c.bracketing)
        choices(style, ["Standard", "P-Log", "Intense", "Pastel"], mask: UInt64(c.styles), selected: c.style)
        choices(wb, ["Auto", "Candle", "Sunset", "Incandescent", "Warm fluorescent", "Halogen", "Fluorescent", "Cool fluorescent", "Flash", "Daylight", "Sunny", "Cloudy", "Snow", "Hazy", "Shade", "Green foliage", "Blue sky"], mask: UInt64(c.whiteBalances), selected: c.whiteBalance)
        choices(ev, (0..<19).map { String(format: "%+.2f", Double($0 - 9) / 3) }, mask: c.evValues, selected: c.ev)
        choices(streamingMode, ["Low latency", "More reliable", "Reliable · lower FPS"], mask: UInt64(c.streamingModes), selected: c.streamingMode)
        if !dirtyPhoto { interval.doubleValue = Double(c.interval) }
    }
    private func choices(_ popup: NSPopUpButton, _ titles: [String], mask: UInt64, selected: UInt32?) {
        let previous = popup.selectedItem?.tag
        let tags = titles.indices.filter { mask & (UInt64(1) << $0) != 0 }
        if popup.itemArray.map(\.tag) != tags {
            popup.removeAllItems()
            for tag in tags { popup.addItem(withTitle: titles[tag]); popup.lastItem?.tag = tag }
        }
        if let selected, popup.menu?.item(withTag: Int(selected)) != nil { popup.selectItem(withTag: Int(selected)) }
        else if let previous, popup.menu?.item(withTag: previous) != nil { popup.selectItem(withTag: previous) }
        popup.menu?.autoenablesItems = false
    }
    private func updateVideoChoices() {
        let mode = recordingMode.selectedItem?.tag ?? -1, c = state.camera
        let groups = c.recordingCapabilities.values.filter { AnafiCameraState.contains($0.modes, mode) }
        choices(resolution, ["DCI 4K", "UHD 4K", "2.7K", "1080p", "720p", "480p", "1080p SD", "720p SD"],
                mask: groups.reduce(0) { $0 | UInt64($1.resolutions) }, selected: dirtyVideo ? nil : c.resolution)
        let res = resolution.selectedItem?.tag ?? -1
        choices(fps, ["24", "25", "30", "48", "50", "60", "96", "100", "120", "9", "15", "20", "192", "200", "240"],
                mask: groups.filter { AnafiCameraState.contains($0.resolutions, res) }.reduce(0) { $0 | UInt64($1.framerates) }, selected: dirtyVideo ? nil : c.framerate)
    }
    private func updatePhotoChoices() {
        let mode = photoMode.selectedItem?.tag ?? -1, c = state.camera
        let groups = c.photoCapabilities.values.filter { AnafiCameraState.contains($0.modes, mode) }
        choices(photoFormat, ["Full sensor", "Rectilinear"], mask: groups.reduce(0) { $0 | UInt64($1.formats) }, selected: dirtyPhoto ? nil : c.photoFormat)
        let format = photoFormat.selectedItem?.tag ?? -1
        choices(photoFile, ["JPEG", "DNG", "DNG + JPEG"], mask: groups.filter { AnafiCameraState.contains($0.formats, format) }.reduce(0) { $0 | UInt64($1.files) }, selected: dirtyPhoto ? nil : c.photoFile)
    }
    private func validRecordingChoice() -> Bool {
        guard let mode = recordingMode.selectedItem?.tag, let res = resolution.selectedItem?.tag, let fps = fps.selectedItem?.tag else { return false }
        return state.camera.recordingCapabilities.values.contains { $0.supports(mode: mode, resolution: res, fps: fps) }
    }
    private func validPhotoChoice() -> Bool {
        guard let mode = photoMode.selectedItem?.tag, let format = photoFormat.selectedItem?.tag, let file = photoFile.selectedItem?.tag else { return false }
        return state.camera.photoCapabilities.values.contains { AnafiCameraState.contains($0.modes, mode) &&
            AnafiCameraState.contains($0.formats, format) && AnafiCameraState.contains($0.files, file) }
    }
    @objc private func routeChanged() {
        discovery.cancel(); discoveryPort = 44_444
        route = AnafiRoute(rawValue: routePicker.indexOfSelectedItem) ?? .direct; host.stringValue = route.defaultHost
        state.message = route == .direct ? "Join ANAFI Wi-Fi on this Mac." :
            route.usesMux ? "USB preview requires a local accessory bridge. Enter its port, then Connect." :
            "SC3 network must be available on this Mac (192.168.53.1)."
        refresh()
    }
    @objc private func connect() {
        discovery.cancel()
        if state.connected || connecting {
            onNeutralize?(); session.disconnect(); stopStream(); state = AnafiSessionState(); connecting = false; refresh(); onControlsChanged?()
        } else {
            guard route.usesMux || AnafiRoute.validHost(host.stringValue) else { log("Enter a valid IPv4 address"); return }
            if route.usesMux, UInt16(bridgePort.stringValue).map({ $0 > 0 }) != true { log("Enter a valid USB bridge port"); return }
            connecting = true; macControls.state = .off
            if route.usesMux { session.connectMux(link: SC3MuxTCPLink(port: UInt16(bridgePort.stringValue)!)) }
            else { session.connect(host: host.stringValue, route: route, discoveryPort: discoveryPort); startStream() }
            refresh()
        }
    }
    @objc private func toggleVideo() { if streamWanted { stopStream() } else { startStream() }; refresh() }
    private func startStream() {
        if route.usesMux {
            guard state.connected, !streamWanted else { return }
            parameterSets.removeAll(); video.reset(); streamWanted = true; videoLabel.stringValue = "Opening SC3 camera…"
            session.startMuxVideo(); return
        }
        guard let url = route.videoURL(host: host.stringValue), !streamWanted else { return }
        parameterSets.removeAll(); video.reset(); streamWanted = true; stream.start(url: url)
    }
    private func stopStream() {
        streamWanted = false; streamLive = false; recorder.stop(); stream.stop(); session.stopMuxVideo(); video.reset()
    }
    private func display(_ unit: H264AccessUnit) {
        guard !shuttingDown, streamWanted else { return }
        var changed = false
        for nal in unit.nalUnits {
            guard let first = nal.first else { continue }
            let type = first & 0x1f
            if type == 7 || type == 8 {
                if let old = parameterSets[type], old != nal { changed = true }
                parameterSets[type] = nal
            }
        }
        if changed {
            // Camera/recording mode changes may renegotiate live H.264. Keep
            // the shared decoder's existing Bebop behavior untouched.
            if recorder.isRecording { recorder.stop(); log("Camera video format changed; Mac recording finalized") }
            video.reset()
            let sets = [parameterSets[7], parameterSets[8]].compactMap { $0 }
            video.display(accessUnit: H264AccessUnit(nalUnits: sets, rtpTimestamp: unit.rtpTimestamp, rtpHeaderExtensions: []))
        }
        video.display(accessUnit: unit)
    }
    var isWorkspaceFocused: Bool { focusButton.state == .on }
    func toggleWorkspaceFocus() { focusButton.performClick(nil) }
    @objc private func toggleFocus() {
        LabMotion.layout(in: view) { inspector?.isHidden = focusButton.state == .on }
        if focusButton.state != .on, let inspector { LabMotion.reveal(inspector) }
    }
    @objc private func exitWorkspace() { guard canExit else { return }; shutdown(); onExit?() }
    @objc private func toggleMacControls() { onNeutralize?(); session.setMacPiloting(macControls.state == .on); onControlsChanged?() }
    @objc private func trim() { if trimButton.isEnabled { session.send(ARSDKPhotoCommand.flatTrim) } }
    @objc private func takeoff() { if takeoffButton.isEnabled { session.send(ARSDKPhotoCommand.takeOff) } }
    @objc private func land() { onNeutralize?(); if landButton.isEnabled { session.send(ARSDKPhotoCommand.landing) } }
    @objc private func emergency() {
        onNeutralize?()
        if emergencyButton.isEnabled { macControls.state = .off; session.sendEmergency() }
    }
    @objc private func cameraModeChanged() { cameraCommand(31, popup: cameraMode) }
    @objc private func styleChanged() { cameraCommand(18, popup: style) }
    @objc private func evChanged() { cameraCommand(14, popup: ev) }
    @objc private func wbChanged() {
        guard let id = state.camera.id, let value = wb.selectedItem?.tag else { return }
        session.send(AnafiCommand.camera(11, id: id, values: [UInt32(value), state.camera.whiteBalanceTemperature]))
    }
    @objc private func streamingChanged() { cameraCommand(37, popup: streamingMode) }
    private func cameraCommand(_ command: UInt16, popup: NSPopUpButton) {
        guard popup.isEnabled, let id = state.camera.id, let tag = popup.selectedItem?.tag else { return }
        session.send(AnafiCommand.camera(command, id: id, values: [UInt32(tag)]))
    }
    @objc private func hdrChanged() {
        guard hdr.isEnabled, let id = state.camera.id else { return }
        session.send(AnafiCommand.camera(28, id: id, values: [hdr.state == .on ? 1 : 0]))
    }
    @objc private func videoChoicesChanged() { dirtyVideo = true; updateVideoChoices(); refresh() }
    @objc private func photoChoicesChanged() { dirtyPhoto = true; updatePhotoChoices(); refresh() }
    @objc private func applyVideo() {
        guard applyVideoButton.isEnabled, let id = state.camera.id, validRecordingChoice() else { return }
        session.send(AnafiCommand.recording(id: id, mode: UInt32(recordingMode.selectedItem!.tag),
                     resolution: UInt32(resolution.selectedItem!.tag), fps: UInt32(fps.selectedItem!.tag),
                     hyperlapse: UInt32(hyperlapse.selectedItem?.tag ?? Int(state.camera.hyperlapse))))
        dirtyVideo = false
    }
    @objc private func applyPhoto() {
        guard applyPhotoButton.isEnabled, let id = state.camera.id, validPhotoChoice() else { return }
        let mode = UInt32(photoMode.selectedItem!.tag)
        let minimum = mode == 4 ? state.camera.gpslapseMinimum : state.camera.timelapseMinimum
        session.send(AnafiCommand.photo(id: id, mode: mode, format: UInt32(photoFormat.selectedItem!.tag),
                     file: UInt32(photoFile.selectedItem!.tag), burst: UInt32(burst.selectedItem?.tag ?? Int(state.camera.burst)),
                     bracketing: UInt32(bracket.selectedItem?.tag ?? Int(state.camera.bracketing)),
                     interval: max(minimum, interval.floatValue)))
        dirtyPhoto = false
    }
    @objc private func recordSD() {
        guard sdRecordButton.isEnabled, let id = state.camera.id else { return }
        session.send(AnafiCommand.camera(state.camera.recording == true ? 43 : 42, id: id))
    }
    @objc private func takePhoto() {
        if photoButton.isEnabled, let id = state.camera.id {
            session.send(AnafiCommand.camera(state.camera.photoActive ? 50 : 39, id: id))
        }
    }
    @objc private func tiltChanged() {
        guard tilt.isEnabled, let id = state.camera.gimbalID else { return }
        session.send(AnafiCommand.gimbalPitch(id: id, degrees: tilt.floatValue), reliable: false)
        tiltLabel.stringValue = String(format: "%.0f°", tilt.doubleValue)
    }
    @objc private func zoomChanged() {
        guard zoom.isEnabled, let id = state.camera.id else { return }
        session.send(AnafiCommand.zoom(id: id, level: zoom.floatValue), reliable: false)
    }
    @objc private func pitchSpeedChanged() {
        guard pitchSpeed.isEnabled, let id = state.camera.gimbalID else { return }
        session.send(AnafiCommand.gimbalSpeed(id: id, yaw: state.camera.yawSpeed, pitch: pitchSpeed.floatValue, roll: state.camera.rollSpeed))
        pitchSpeedLabel.stringValue = String(format: "%.0f°/s", pitchSpeed.doubleValue)
    }
    @objc private func centerCamera() { if let id = state.camera.gimbalID { session.send(AnafiCommand.feature(148, 11, id: id)) } }
    @objc private func enhancementChanged() {
        video.enhancementPreset = VideoEnhancementPreset(rawValue: enhancement.indexOfSelectedItem) ?? .off
    }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { mediaDirectory = url; log("Mac capture folder: \(url.path)") }
    }
    @objc private func saveFrame() {
        guard let image = video.latestFrameImage() else { log("Waiting for a decoded video frame"); return }
        let url = MediaFileNamer.pictureURL(directory: mediaDirectory, format: .png, aircraftToken: "ANAFI")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try StillImageWriter.write(image, to: url, format: .png)
                DispatchQueue.main.async { self?.log("Frame saved: \(url.lastPathComponent)") }
            } catch { DispatchQueue.main.async { self?.log(error.localizedDescription) } }
        }
    }
    @objc private func recordLocal() {
        if recorder.isRecording { recorder.stop() }
        else if !recorder.isActive, !recordingConversion, streamLive {
            do { _ = try recorder.start(directory: mediaDirectory, aircraftToken: "ANAFI") }
            catch { log(error.localizedDescription) }
        }
        refresh()
    }
    func refreshInputs(_ text: String) { inputStatus.stringValue = text }
    func disableMacInputs() {
        guard macControls.state == .on else { return }
        macControls.state = .off; session.setMacPiloting(false)
    }
    func perform(_ action: FlightControlAction) {
        guard controlsAvailable else { return }
        switch action {
        case .takeOffLand: if state.flightState == 0 { takeoff() } else { land() }
        case .emergency: emergency()
        case .cameraUp, .cameraDown:
            tilt.doubleValue = min(tilt.maxValue, max(tilt.minValue, tilt.doubleValue + (action == .cameraUp ? 5 : -5))); tiltChanged()
        case .cameraCenter: centerCamera()
        case .returnHome: if state.gpsFix { onNeutralize?(); session.send(ARSDKPhotoCommand.navigateHome(start: true)) }
        case .cancelReturnHome: session.send(ARSDKPhotoCommand.navigateHome(start: false))
        default: break
        }
    }
    func shutdown() {
        guard !shuttingDown else { return }; shuttingDown = true
        discovery.cancel(); onNeutralize?(); session.onChange = nil; session.onLog = nil; session.disconnectAndWait()
        session.onMuxVideo = nil; stream.onState = nil; stream.onAccessUnit = nil; stream.onStats = nil; stream.stopAndWait()
        video.reset(); recorder.stopAndWait(); _ = converter.cancelAndWait()
    }
    private func log(_ message: String) {
        guard !shuttingDown else { return }
        recentActivity.append(message); if recentActivity.count > 3 { recentActivity.removeFirst() }
        activity.stringValue = recentActivity.joined(separator: "\n")
    }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, muted: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = muted ? LabVisualStyle.mutedText : .labelColor; return field
    }
    private func column(spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing; return stack
    }
    private func row() -> NSStackView {
        let stack = NSStackView(); stack.orientation = .horizontal; stack.alignment = .centerY
        stack.spacing = 8; return stack
    }
    private func spacer() -> NSView { let view = NSView(); view.setContentHuggingPriority(.init(1), for: .horizontal); return view }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; return button
    }
    private func addSetting(_ title: String, _ control: NSView, to stack: NSStackView, action: Selector? = nil) {
        let line = row(), name = label(title, size: 12); name.widthAnchor.constraint(equalToConstant: 105).isActive = true
        line.addArrangedSubview(name); line.addArrangedSubview(control); stack.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        control.widthAnchor.constraint(equalTo: line.widthAnchor, constant: -113).isActive = true
        if let popup = control as? NSPopUpButton { popup.target = self; popup.action = action; popup.menu?.autoenablesItems = false }
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    private func pin(_ child: NSView, to parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
        NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: parent.leadingAnchor), child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                                     child.topAnchor.constraint(equalTo: parent.topAnchor), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
    }
    private func card(_ content: NSView) -> NSView {
        let card = NSView(); card.wantsLayer = true; card.layer?.backgroundColor = LabVisualStyle.panel.cgColor
        card.layer?.cornerRadius = 14; card.layer?.borderWidth = 1; card.layer?.borderColor = LabVisualStyle.border.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14), content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)])
        if let stack = content as? NSStackView {
            for child in stack.arrangedSubviews where child is NSStackView || child is NSTextField {
                child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        return card
    }
    private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    @objc private func findDevice() {
        if route.usesMux { log("Start your USB accessory bridge first; Parrot Lab discovers SC3 over libmux when you connect.") }
        else if !state.connected && !connecting && !streamWanted { discovery.search(route: route) }
    }

    static func layoutSelfTest() -> Bool {
        _ = NSApplication.shared
        // Exercise the actual mode embedding, not only a standalone view whose
        // frame is assigned after construction (the old preview path).
        let parent = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = parent
        parent.enterAnafiMode()
        guard let controller = parent.children.compactMap({ $0 as? AnafiViewController }).first,
              let root = controller.view.subviews.first as? NSStackView,
              let inspector = controller.inspector else { return false }
        defer { controller.shutdown(); window.contentViewController = nil }
        for size in [NSSize(width: 1180, height: 720), NSSize(width: 1440, height: 900),
                     NSSize(width: 1920, height: 1080), NSSize(width: 1180, height: 720)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            let width = controller.view.bounds.width - 32
            guard root.arrangedSubviews.count == 4,
                  root.arrangedSubviews.allSatisfy({ abs($0.frame.width - width) < 1 }),
                  let content = root.arrangedSubviews[2] as? NSStackView,
                  let preview = content.arrangedSubviews.first as? NSStackView,
                  abs(controller.video.frame.width - preview.frame.width) < 1,
                  abs(preview.frame.width + inspector.frame.width + content.spacing - width) < 1,
                  inspector.frame.height > 280,
                  let document = inspector.documentView,
                  abs(document.frame.width - inspector.contentView.bounds.width) < 1,
                  document.frame.height > inspector.contentView.bounds.height else {
                let body = root.arrangedSubviews[2] as? NSStackView
                fputs("ANAFI layout self-test failed at \(size): root=\(root.frame), rows=\(root.arrangedSubviews.map { $0.frame }), body=\(body?.arrangedSubviews.map { $0.frame } ?? []), video=\(controller.video.frame), inspector=\(inspector.frame), document=\(inspector.documentView?.frame ?? .zero), clip=\(inspector.contentView.bounds)\n", stderr)
                return false
            }
            controller.focusButton.state = .on; controller.toggleFocus()
            controller.view.layoutSubtreeIfNeeded()
            guard inspector.isHidden, abs(controller.video.frame.width - width) < 1 else { return false }
            controller.focusButton.state = .off; controller.toggleFocus()
            controller.view.layoutSubtreeIfNeeded()
            guard !inspector.isHidden, abs(inspector.frame.width - 355) < 1 else { return false }
        }
        return true
    }

    static func interactionSelfTest() -> Bool {
        _ = NSApplication.shared
        let controller = AnafiViewController(); _ = controller.view
        defer { controller.shutdown() }
        guard !controller.takeoffButton.isEnabled, !controller.sdRecordButton.isEnabled,
              !controller.macControls.isEnabled, controller.canExit else { return false }
        controller.state.connected = true; controller.state.linkedAnafi = true; controller.state.flightState = 0
        _ = controller.state.camera.consume(AnafiSelfTest.cameraCapability())
        controller.state.camera.recordingCapabilities = [
            1: .init(id: 1, modes: 1, resolutions: 2, framerates: 7, hdr: true),
            2: .init(id: 2, modes: 4, resolutions: 8, framerates: 48, hdr: false)
        ]
        controller.state.camera.photoCapabilities = [1: .init(id: 1, modes: 1, formats: 3, files: 5)]
        controller.state.camera.mode = 0; controller.state.camera.recordingMode = 0
        controller.state.camera.resolution = 1; controller.state.camera.framerate = 2
        controller.state.camera.recording = false; controller.state.camera.recordingAvailable = true
        controller.populateCamera(); controller.refresh()
        guard controller.takeoffButton.isEnabled, controller.sdRecordButton.isEnabled,
              controller.resolution.itemArray.map(\.tag) == [1],
              controller.fps.itemArray.map(\.tag) == [0, 1, 2], !controller.controlsAvailable else { return false }
        controller.recordingMode.selectItem(withTag: 2); controller.videoChoicesChanged()
        guard controller.resolution.itemArray.map(\.tag) == [3], controller.fps.itemArray.map(\.tag) == [4, 5],
              controller.validRecordingChoice(), controller.photoFile.itemArray.map(\.tag) == [0, 2] else { return false }
        controller.state.camera.recording = true; controller.refresh()
        guard !controller.applyVideoButton.isEnabled, !controller.cameraMode.isEnabled,
              controller.sdRecordButton.title == "Stop ANAFI recording" else { return false }
        controller.state.camera.recording = false; controller.state.camera.mode = 1
        controller.state.camera.photoAvailable = true; controller.state.camera.photoActive = true
        controller.state.camera.photoMode = 3; controller.refresh()
        guard controller.photoButton.isEnabled, controller.photoButton.title == "Stop photo sequence",
              !controller.applyPhotoButton.isEnabled else { return false }
        controller.state.camera.photoMode = 0; controller.refresh()
        guard !controller.photoButton.isEnabled else { return false }
        controller.state = AnafiSessionState(); controller.populateCamera(); controller.refresh()
        return !controller.takeoffButton.isEnabled && !controller.sdRecordButton.isEnabled &&
            controller.cameraMode.numberOfItems == 0 && !controller.controlsAvailable
    }
}
