import AppKit

/// A BLE-only workspace: it never receives a Wi-Fi client or a device-tool service.
final class MiniDroneViewController: NSViewController {
    let client = MiniDroneBLEClient()
    var onExit: ((Bool) -> Void)?
    var onConnectionChanged: (() -> Void)?
    var onNeutralize: (() -> Void)?
    private let devicePicker = NSPopUpButton()
    private let grabberPicker = NSPopUpButton()
    private let cannonPicker = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let flight = NSTextField(labelWithString: "Ready when you are")
    private let battery = NSTextField(labelWithString: "—")
    private let inputStatus = NSTextField(wrappingLabelWithString: "")
    private let activity = NSTextField(wrappingLabelWithString: "Wake your Mambo, then search nearby.")
    private var deviceIDs: [UUID] = []
    private var scanButton = NSButton()
    private var connectButton = NSButton()
    private var flatTrimButton = NSButton()
    private var takeOffButton = NSButton()
    private var landButton = NSButton()
    private var emergencyButton = NSButton()
    private var openButton = NSButton()
    private var closeButton = NSButton()
    private var fireButton = NSButton()
    private var airButton = NSButton()
    private var groundButton = NSButton()
    private var recentActivity: [String] = []

    override func loadView() {
        view = LabBackgroundView()
        LabVisualStyle.applyTheme(.miniDrone, to: view)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let heading = row()
        if let icon = LabVisualStyle.brandIcon() {
            let image = NSImageView(image: icon)
            image.widthAnchor.constraint(equalToConstant: 40).isActive = true
            image.heightAnchor.constraint(equalToConstant: 40).isActive = true
            heading.addArrangedSubview(image)
        }
        let identity = column()
        identity.spacing = 3
        identity.addArrangedSubview(label("Parrot Lab", size: 24, weight: .bold))
        identity.addArrangedSubview(label("MINIDRONE / MAMBO", size: 11, weight: .semibold, muted: true))
        heading.addArrangedSubview(identity)
        heading.addArrangedSubview(spacer())
        airButton = button("Air mode", #selector(exitAir), symbol: "paperplane")
        groundButton = button("Ground mode", #selector(exitGround), symbol: "car")
        heading.addArrangedSubview(airButton)
        heading.addArrangedSubview(groundButton)
        let badge = label("MiniDrone mode", size: 13, weight: .semibold)
        badge.textColor = LabVisualStyle.accent
        heading.addArrangedSubview(badge)
        root.addArrangedSubview(heading)

        let connection = column()
        connection.addArrangedSubview(label("BLUETOOTH CONNECTION", size: 11, weight: .bold, muted: true))
        let devices = row()
        devicePicker.addItem(withTitle: "No MiniDrones found")
        devicePicker.setAccessibilityLabel("Nearby MiniDrones")
        devicePicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        devicePicker.widthAnchor.constraint(equalToConstant: 320).isActive = true
        devicePicker.menu?.autoenablesItems = false
        devices.addArrangedSubview(devicePicker)
        devices.addArrangedSubview(spacer())
        scanButton = button("Search nearby", #selector(scan), symbol: "antenna.radiowaves.left.and.right")
        connectButton = button("Connect", #selector(connect), symbol: "link")
        devices.addArrangedSubview(scanButton)
        connectButton.bezelColor = LabVisualStyle.accent
        devices.addArrangedSubview(connectButton)
        connection.addArrangedSubview(devices)
        status.textColor = LabVisualStyle.mutedText
        status.font = .systemFont(ofSize: 12)
        connection.addArrangedSubview(status)
        root.addArrangedSubview(card(connection))

        let flightContent = column()
        let metrics = row()
        let flightIcon = NSImageView(image: NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil) ?? NSImage())
        flightIcon.contentTintColor = LabVisualStyle.accent
        flightIcon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        flightIcon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        metrics.addArrangedSubview(flightIcon)
        let stateColumn = column()
        stateColumn.addArrangedSubview(label("FLIGHT", size: 11, weight: .bold, muted: true))
        flight.font = .systemFont(ofSize: 30, weight: .medium)
        flight.textColor = LabVisualStyle.accent
        stateColumn.addArrangedSubview(flight)
        metrics.addArrangedSubview(stateColumn)
        metrics.addArrangedSubview(spacer())
        let batteryColumn = column()
        batteryColumn.addArrangedSubview(label("BATTERY", size: 11, weight: .bold, muted: true))
        battery.font = .monospacedDigitSystemFont(ofSize: 30, weight: .medium)
        batteryColumn.addArrangedSubview(battery)
        metrics.addArrangedSubview(batteryColumn)
        flightContent.addArrangedSubview(metrics)
        let actions = row()
        flatTrimButton = button("Flat trim", #selector(flatTrim), symbol: "level")
        takeOffButton = button("Take off", #selector(takeOff), symbol: "arrow.up")
        takeOffButton.bezelColor = LabVisualStyle.accent
        landButton = button("Land", #selector(land), symbol: "arrow.down")
        emergencyButton = button("Emergency stop", #selector(emergency), symbol: "exclamationmark.octagon")
        emergencyButton.contentTintColor = .systemRed
        emergencyButton.toolTip = "Immediately cut motor power"
        [flatTrimButton, takeOffButton, landButton].forEach(actions.addArrangedSubview)
        actions.addArrangedSubview(spacer())
        actions.addArrangedSubview(emergencyButton)
        flightContent.addArrangedSubview(actions)
        inputStatus.font = .systemFont(ofSize: 12)
        inputStatus.textColor = LabVisualStyle.mutedText
        flightContent.addArrangedSubview(inputStatus)
        let inputActions = row()
        let configure = NSButton(title: "Input settings…", target: nil, action: #selector(AppDelegate.showSettings(_:)))
        configure.bezelStyle = .rounded
        inputActions.addArrangedSubview(configure)
        let mappings = NSButton(title: "Edit mappings…", target: nil, action: #selector(AppDelegate.showFlightControlMappings(_:)))
        mappings.bezelStyle = .rounded
        inputActions.addArrangedSubview(mappings)
        inputActions.addArrangedSubview(spacer())
        inputActions.addArrangedSubview(label("Piloting pauses while editing controls", size: 11, muted: true))
        flightContent.addArrangedSubview(inputActions)
        root.addArrangedSubview(card(flightContent))

        let accessories = column()
        accessories.addArrangedSubview(label("ACCESSORIES", size: 11, weight: .bold, muted: true))
        let accessoryRow = row()
        accessoryRow.distribution = .fillEqually
        let grabberColumn = column()
        let cannonColumn = column()
        grabberColumn.spacing = 8
        cannonColumn.spacing = 8
        grabberColumn.addArrangedSubview(label("Grabber", size: 14, weight: .semibold))
        cannonColumn.addArrangedSubview(label("Cannon", size: 14, weight: .semibold))
        let grabberActions = row()
        let cannonActions = row()
        grabberPicker.menu?.autoenablesItems = false
        cannonPicker.menu?.autoenablesItems = false
        grabberPicker.setAccessibilityLabel("Connected grabber")
        cannonPicker.setAccessibilityLabel("Connected cannon")
        grabberPicker.target = self
        grabberPicker.action = #selector(accessorySelectionChanged)
        cannonPicker.target = self
        cannonPicker.action = #selector(accessorySelectionChanged)
        openButton = button("Open", #selector(openGrabber), symbol: nil)
        closeButton = button("Close", #selector(closeGrabber), symbol: nil)
        fireButton = button("Fire cannon", #selector(fireCannon), symbol: nil)
        [grabberPicker, openButton, closeButton].forEach(grabberActions.addArrangedSubview)
        [cannonPicker, fireButton].forEach(cannonActions.addArrangedSubview)
        grabberColumn.addArrangedSubview(grabberActions)
        cannonColumn.addArrangedSubview(cannonActions)
        accessoryRow.addArrangedSubview(grabberColumn)
        accessoryRow.addArrangedSubview(cannonColumn)
        accessories.addArrangedSubview(accessoryRow)
        accessories.addArrangedSubview(label("Accessories appear automatically when attached. Assign their buttons in Edit mappings.",
                                             size: 12, muted: true))
        root.addArrangedSubview(card(accessories))

        let log = column()
        log.addArrangedSubview(label("ACTIVITY", size: 11, weight: .bold, muted: true))
        activity.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        activity.textColor = LabVisualStyle.mutedText
        activity.maximumNumberOfLines = 3
        log.addArrangedSubview(activity)
        root.addArrangedSubview(card(log))
        root.addArrangedSubview(spacer())
        for child in root.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        }
        client.onChange = { [weak self] in
            self?.refresh()
            self?.onConnectionChanged?()
        }
        client.onLog = { [weak self] message in
            guard let self else { return }
            self.recentActivity.append(message)
            self.recentActivity = Array(self.recentActivity.suffix(3))
            self.activity.stringValue = self.recentActivity.joined(separator: "\n")
        }
        refresh()
    }

    func refreshInputs(_ text: String) {
        inputStatus.stringValue = text.replacingOccurrences(of: "WAITING FOR ARSDK", with: "Connect your MiniDrone")
    }

    private func refresh() {
        let selected = deviceIDs.indices.contains(devicePicker.indexOfSelectedItem) ? deviceIDs[devicePicker.indexOfSelectedItem] : nil
        deviceIDs = client.devices.map(\.id)
        let choices = client.devices.enumerated().map { (index, device) in
            (index, "\(device.name)  ·  \(device.signal) dBm")
        }
        Self.populateChoices(devicePicker, choices: choices.isEmpty ? [(-1, "No MiniDrones found")] : choices)
        if let selected, let index = deviceIDs.firstIndex(of: selected) { devicePicker.selectItem(at: index) }
        let busy = [.connecting, .subscribing, .ready, .disconnecting].contains(client.connection)
        devicePicker.isEnabled = !busy && !deviceIDs.isEmpty
        scanButton.isEnabled = !busy && client.connection != .scanning
        connectButton.title = busy ? "Disconnect" : "Connect"
        connectButton.isEnabled = client.connection != .disconnecting && (busy || !deviceIDs.isEmpty)
        status.stringValue = client.ready ? "Connected to \(client.connectedName)" : client.connection.title
        switch client.connection {
        case .ready: status.textColor = .systemGreen
        case .failed: status.textColor = .systemOrange
        default: status.textColor = LabVisualStyle.mutedText
        }
        flight.stringValue = client.telemetry.flightState?.title ?? (client.ready ? "Waiting for flight state" : "Ready when you are")
        battery.stringValue = client.telemetry.battery.map { "\($0)%" } ?? "—"
        battery.textColor = (client.telemetry.battery ?? 100) < 20 ? .systemOrange : .labelColor
        flatTrimButton.isEnabled = client.ready && client.telemetry.flightState == .landed
        takeOffButton.isEnabled = client.canTakeOff
        landButton.isEnabled = client.ready
        emergencyButton.isEnabled = client.ready
        // Switching workspaces must not silently abandon an airborne BLE drone.
        let mayLeave = !client.ready || client.telemetry.flightState == .landed || client.telemetry.flightState == .emergency
        airButton.isEnabled = mayLeave
        groundButton.isEnabled = mayLeave
        airButton.toolTip = mayLeave ? "Return to Bebop" : "Land or disconnect before switching modes"
        groundButton.toolTip = mayLeave ? "Return to Jumping Sumo" : airButton.toolTip
        populate(grabberPicker, ids: client.telemetry.grabbers.keys.sorted(), title: "Grabber")
        populate(cannonPicker, ids: client.telemetry.cannons.keys.sorted(), title: "Cannon")
        accessorySelectionChanged()
    }

    private func populate(_ picker: NSPopUpButton, ids: [UInt8], title: String) {
        let choices = ids.map { (Int($0), "\(title) \($0)") }
        Self.populateChoices(picker, choices: choices.isEmpty ? [(-1, "Not attached")] : choices)
        picker.isEnabled = client.ready && !ids.isEmpty
    }
    /// Keep menu items alive during telemetry updates so an open menu stays usable.
    private static func populateChoices(_ picker: NSPopUpButton, choices: [(Int, String)]) {
        let selection = picker.selectedItem?.tag
        if picker.itemArray.map(\.tag) != choices.map({ $0.0 }) {
            picker.removeAllItems()
            for (tag, title) in choices {
                picker.addItem(withTitle: title)
                picker.lastItem?.tag = tag
            }
            if let selection { picker.selectItem(withTag: selection) }
        } else {
            for (item, choice) in zip(picker.itemArray, choices) where item.title != choice.1 {
                item.title = choice.1
            }
        }
    }

    static func pickerSelfTest() -> Bool {
        let picker = NSPopUpButton()
        populateChoices(picker, choices: [(37, "Grabber 37"), (93, "Grabber 93")])
        picker.selectItem(withTag: 93)
        let selected = picker.selectedItem
        for _ in 0..<100 {
            populateChoices(picker, choices: [(37, "Grabber 37"), (93, "Grabber 93")])
            guard picker.selectedItem === selected else { return false }
        }
        populateChoices(picker, choices: [(37, "Updated name"), (93, "Grabber 93")])
        guard picker.selectedItem === selected, picker.item(at: 0)?.title == "Updated name" else { return false }
        populateChoices(picker, choices: [(52, "Grabber 52"), (93, "Grabber 93")])
        guard picker.selectedItem?.tag == 93 else { return false }
        populateChoices(picker, choices: [(-1, "Not attached")])
        return picker.numberOfItems == 1 && picker.selectedItem?.tag == -1
    }

    private func selectedID(_ picker: NSPopUpButton) -> UInt8? {
        guard let value = picker.selectedItem?.tag else { return nil }
        return UInt8(exactly: value)
    }
    @objc private func accessorySelectionChanged() {
        let grabberReady = selectedID(grabberPicker).map(client.telemetry.canUseGrabber) ?? false
        openButton.isEnabled = client.ready && grabberReady
        closeButton.isEnabled = openButton.isEnabled
        fireButton.isEnabled = client.ready && (selectedID(cannonPicker).map(client.telemetry.canFireCannon) ?? false)
    }
    func perform(_ action: FlightControlAction) {
        switch action {
        case .takeOffLand: onNeutralize?(); client.takeOffOrLand()
        case .flatTrim: flatTrim()
        case .emergency: emergency()
        case .grabberOpen: openGrabber()
        case .grabberClose: closeGrabber()
        case .cannonFire: fireCannon()
        default: break
        }
    }
    @objc private func scan() { client.scan() }
    @objc private func connect() {
        if [.connecting, .subscribing, .ready].contains(client.connection) { onNeutralize?(); client.disconnect() }
        else if deviceIDs.indices.contains(devicePicker.indexOfSelectedItem) { client.connect(id: deviceIDs[devicePicker.indexOfSelectedItem]) }
    }
    @objc private func flatTrim() { onNeutralize?(); client.flatTrim() }
    @objc private func takeOff() { onNeutralize?(); client.takeOff() }
    @objc private func land() { onNeutralize?(); client.land() }
    @objc private func emergency() { onNeutralize?(); client.emergency() }
    @objc private func openGrabber() { client.grabber(id: selectedID(grabberPicker), close: false) }
    @objc private func closeGrabber() { client.grabber(id: selectedID(grabberPicker), close: true) }
    @objc private func fireCannon() { client.cannon(id: selectedID(cannonPicker)) }
    @objc private func exitAir() { onExit?(false) }
    @objc private func exitGround() { onExit?(true) }

    private func row() -> NSStackView {
        let result = NSStackView()
        result.orientation = .horizontal
        result.alignment = .centerY
        result.spacing = 12
        return result
    }
    private func column() -> NSStackView {
        let result = NSStackView()
        result.orientation = .vertical
        result.alignment = .leading
        result.spacing = 12
        return result
    }
    private func label(_ title: String, size: CGFloat, weight: NSFont.Weight = .regular, muted: Bool = false) -> NSTextField {
        let result = NSTextField(labelWithString: title)
        result.font = .systemFont(ofSize: size, weight: weight)
        result.textColor = muted ? LabVisualStyle.mutedText : .labelColor
        return result
    }
    private func button(_ title: String, _ action: Selector, symbol: String?) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        result.controlSize = .large
        if let symbol { result.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); result.imagePosition = .imageLeading }
        return result
    }
    private func spacer() -> NSView {
        let result = NSView()
        result.setContentHuggingPriority(.init(1), for: .horizontal)
        result.setContentHuggingPriority(.init(1), for: .vertical)
        return result
    }
    private func card(_ content: NSStackView) -> NSView {
        let panel = LabPanelView()
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -18)
        ])
        for child in content.arrangedSubviews where child is NSStackView || child is NSTextField {
            child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        return panel
    }
}
