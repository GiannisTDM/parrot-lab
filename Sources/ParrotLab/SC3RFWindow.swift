import AppKit

final class SC3RFWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onBeginWrite: (() -> Bool)?
    var onEndWrite: (() -> Void)?
    private let queue = DispatchQueue(label: "parrotlab.sc3.rf", qos: .utility)
    private var generation: UInt64 = 0
    private var busy = false, saving = false
    private var client: SC3RFClient?
    private var executor: SC3RFADBExecutor?
    private var timer: Timer?
    private var draft = SC3RFDraft()
    private var invalidFields = Set<SC3RFKey>()
    private var previous: SC3RFObservation?
    private let adb = NSTextField(string: "/opt/homebrew/bin/adb")
    private let port = NSTextField(string: "5038")
    private let serial = NSComboBox()
    private let status = NSTextField(wrappingLabelWithString: "Select the existing SC3 maintenance transport. No radio changes occur on connect.")
    private let telemetry = NSTextField(wrappingLabelWithString: "No SC3 observation yet.")
    private let hashLabel = NSTextField(wrappingLabelWithString: "Saved INI · not read")
    private let notice = NSTextField(wrappingLabelWithString: "Changes are local until you preview and type APPLY.")
    private let diff = NSTextView()
    private let discover = NSButton(title: "Find transports", target: nil, action: nil)
    private let connect = NSButton(title: "Connect", target: nil, action: nil)
    private let disconnect = NSButton(title: "Disconnect", target: nil, action: nil)
    private let refresh = NSButton(title: "Read saved settings", target: nil, action: nil)
    private let previewButton = NSButton(title: "Preview changes", target: nil, action: nil)
    private let save = NSButton(title: "Save reviewed changes…", target: nil, action: nil)
    private let discard = NSButton(title: "Discard edits", target: nil, action: nil)
    private let monitoring = NSButton(checkboxWithTitle: "Live readouts · every 4 seconds", target: nil, action: nil)
    private var inputs: [SC3RFKey: NSTextField] = [:]
    private var toggles: [SC3RFKey: NSPopUpButton] = [:]
    private var saved: [SC3RFKey: NSTextField] = [:]
    private var pending: [SC3RFKey: NSTextField] = [:]
    private var defaults: [SC3RFKey: NSButton] = [:]

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 950, height: 820),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "SkyController 3 · QCA RF Lab 0.2.0"
        panel.isReleasedWhenClosed = false; panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = LabVisualStyle.panel
        super.init(window: panel); panel.delegate = self
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; panel.contentView?.addSubview(scroll)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 22, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = root
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: panel.contentView!.topAnchor), scroll.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), root.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        func add(_ view: NSView) { root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44).isActive = true }
        func label(_ text: String, heading: Bool = false) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: heading ? 15 : 12, weight: heading ? .semibold : .regular)
            label.textColor = heading ? .labelColor : .secondaryLabelColor; add(label)
        }
        label("Existing SC3 connection", heading: true)
        label("Rooted retail SC3 1.8.1 only · QCA6174 · ADB is maintenance, separate from Sumo video/control.")
        serial.stringValue = "192.168.53.1:9050"; serial.usesDataSource = false
        adb.setAccessibilityLabel("Absolute host ADB executable"); port.setAccessibilityLabel("Existing ADB server port")
        serial.setAccessibilityLabel("Explicit SC3 transport")
        port.widthAnchor.constraint(equalToConstant: 65).isActive = true
        serial.widthAnchor.constraint(equalToConstant: 205).isActive = true
        add(NSStackView(views: [NSTextField(labelWithString: "ADB"), adb, NSTextField(labelWithString: "Port"), port]))
        add(NSStackView(views: [serial, discover, connect, disconnect]))
        status.font = .systemFont(ofSize: 12); add(status)
        label("Link observation · peer → SC3 receive", heading: true)
        telemetry.font = .monospacedSystemFont(ofSize: 12, weight: .regular); add(telemetry)
        add(monitoring)
        label("Query 138 reports receive driver RSSI. TX readback is a driver statistic, not measured conducted power/EIRP. Missing values stay —; PHY rates are not throughput.")
        label("Saved configuration / pending changes", heading: true)
        add(hashLabel)
        for (index, key) in SC3RFKey.allCases.enumerated() {
            let title = NSTextField(labelWithString: key.title)
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            title.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let savedValue = NSTextField(wrappingLabelWithString: "Saved: —"), pendingValue = NSTextField(labelWithString: "")
            savedValue.widthAnchor.constraint(equalToConstant: 190).isActive = true
            pendingValue.widthAnchor.constraint(equalToConstant: 120).isActive = true
            saved[key] = savedValue; pending[key] = pendingValue
            let control: NSControl
            if key == .tpc {
                let popup = NSPopUpButton(); popup.addItems(withTitles: ["ON", "OFF"])
                popup.target = self; popup.action = #selector(tpcChanged); toggles[key] = popup; control = popup
            } else {
                let field = NSTextField(string: ""); field.placeholderString = "\(key.range.lowerBound)…\(key.range.upperBound)"
                field.tag = index; field.delegate = self; inputs[key] = field; control = field
            }
            control.widthAnchor.constraint(equalToConstant: 74).isActive = true; control.setAccessibilityLabel(key.title)
            let unset = NSButton(title: "Use driver default", target: self, action: #selector(unsetPressed))
            unset.tag = index; defaults[key] = unset
            let row = NSStackView(views: [title, savedValue, control, unset, pendingValue]); row.spacing = 10
            add(row)
        }
        label("Defaults: cap 128 is a sentinel, not 128 dBm; SAR 30/30 differs from the shipped 10/10. AP TPC accepts peer requests. FlexConnect 0…9 is experimental; units and RF effect are unknown. Unset differs from an explicit value equal to its default.")
        notice.textColor = .systemOrange; add(notice)
        add(NSStackView(views: [refresh, discard, previewButton, save]))
        let diffScroll = NSScrollView(); diffScroll.hasVerticalScroller = true; diffScroll.borderType = .bezelBorder
        diff.isEditable = false; diff.isRichText = false; diff.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diff.string = "Preview the actual INI diff before saving."; diffScroll.documentView = diff
        diffScroll.heightAnchor.constraint(equalToConstant: 160).isActive = true; add(diffScroll)
        label("Saving changes only the persistent INI with recovery backups. Activation is not verified and may disrupt a later link. No automatic reboot/reload. Preserved-original recovery remains in the existing interactive RF Lab tool; it is not a factory reset.")
        for (button, action) in [(discover, #selector(discoverPressed)), (connect, #selector(connectPressed)),
            (disconnect, #selector(disconnectPressed)), (refresh, #selector(refreshPressed)), (discard, #selector(discardPressed)),
            (previewButton, #selector(previewPressed)), (save, #selector(savePressed)), (monitoring, #selector(monitoringPressed))] {
            button.target = self; button.action = action
        }
        panel.minSize = NSSize(width: 950, height: 650); panel.center(); update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func stop() {
        generation &+= 1; timer?.invalidate(); timer = nil; executor?.cancel(); executor = nil; client = nil
        busy = false; previous = nil; invalidFields.removeAll()
        telemetry.stringValue = "No current observation · reconnect to read the SC3."
        if saving { saving = false; onEndWrite?() }
    }
    deinit { timer?.invalidate(); executor?.cancel() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if saving { status.stringValue = "Wait for the bounded save/readback to finish before closing."; return false }
        return allowDiscard()
    }
    func windowWillClose(_ notification: Notification) { stop(); draft = SC3RFDraft(); update() }
    private func allowDiscard() -> Bool {
        guard !draft.edits.isEmpty || !invalidFields.isEmpty else { return true }
        let alert = NSAlert(); alert.messageText = "Discard local RF edits?"; alert.informativeText = "No settings will be saved."
        alert.addButton(withTitle: "Discard edits"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func update(fill: Bool = false) {
        let editable = client != nil && draft.settings?.fileIssue == nil && draft.settings != nil && !busy
        let valid = editable && invalidFields.isEmpty
        for key in SC3RFKey.allCases {
            let row = draft.settings?.rows[key]
            let source = row?.source ?? "unread"
            saved[key]?.stringValue = row == nil ? "Saved: — (not read)" : source == "unset" ? "Unset → \(key.defaultLabel)" : "Saved: \(row?.saved ?? draft.settings?.rawSaved[key]?.prefix(32).description ?? "invalid") [\(source)]"
            saved[key]?.toolTip = key.rawValue + " · driver default: " + key.defaultLabel
            pending[key]?.stringValue = draft.edits[key].map { $0 == "unset" ? "→ unset" : "→ \($0)" } ?? "—"
            inputs[key]?.isEnabled = editable; toggles[key]?.isEnabled = editable; defaults[key]?.isEnabled = editable
            if fill && !invalidFields.contains(key) {
                inputs[key]?.stringValue = draft.edits[key] ?? row?.saved ?? ""
                let tpc = draft.edits[key] ?? row?.saved
                toggles[key]?.selectItem(at: tpc == "0" ? 1 : 0)
            }
        }
        adb.isEnabled = client == nil && !busy; port.isEnabled = adb.isEnabled; serial.isEnabled = adb.isEnabled
        connect.isEnabled = !busy; discover.isEnabled = !busy && client == nil
        disconnect.isEnabled = client != nil && !busy; refresh.isEnabled = client != nil && !busy
        previewButton.isEnabled = valid && !draft.edits.isEmpty
        save.isEnabled = valid && draft.preview != nil
        discard.isEnabled = !busy && (!draft.edits.isEmpty || !invalidFields.isEmpty); monitoring.isEnabled = client != nil && !busy
        hashLabel.stringValue = "Saved INI SHA-1: \(draft.settings?.hash ?? "—") · not live output power"
        if let issue = draft.settings?.fileIssue { notice.stringValue = issue }
    }
    private func perform<T>(_ work: @escaping () throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        guard !busy else { return }
        guard let lease = SC3MaintenanceCoordinator.shared.acquire("RF Lab", critical: saving) else { status.stringValue = "Another SC3 maintenance operation is active; wait for its checked result."; if saving { saving = false; onEndWrite?() }; return }
        busy = true; update(); let identity = generation
        queue.async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async { [weak self] in
                SC3MaintenanceCoordinator.shared.release(lease)
                guard let self, self.generation == identity else { return }
                self.busy = false; done(result); self.update()
            }
        }
    }
    private func makeExecutor() throws -> SC3RFADBExecutor {
        guard let number = UInt16(port.stringValue) else { throw SC3RFError("Invalid ADB server port.") }
        return try SC3RFADBExecutor(executable: adb.stringValue, port: number, serial: serial.stringValue)
    }
    @objc private func discoverPressed() {
        guard let port = UInt16(port.stringValue), port > 0 else { status.stringValue = "Enter the existing ADB server port."; return }
        perform({ try SC3RFADBExecutor.devices(port: port) }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let devices): self.serial.removeAllItems(); self.serial.addItems(withObjectValues: devices); self.status.stringValue = "\(devices.count) existing transport(s). Select one explicitly, then Connect."
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
        }
    }
    @objc private func connectPressed() {
        guard !busy, allowDiscard() else { return }; stop(); draft = SC3RFDraft(); invalidFields.removeAll()
        do {
            let executor = try makeExecutor(); self.executor = executor
            status.stringValue = "Checking the selected SC3 and RAM tools… no settings are being saved."
            perform({ () throws -> (SC3RFClient, SC3RFSettings, SC3RFObservation) in
                try executor.validateClient()
                let client = SC3RFClient(executor: executor, resources: try SC3RFResources())
                try client.prepare(); return (client, try client.settings(), try client.observe())
            }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let (client, settings, observation)):
                    self.client = client; self.draft.settings = settings; self.show(observation)
                    self.status.stringValue = "Verified SC3 1.8.1 · RAM tools ready · current saved configuration read."
                    self.notice.stringValue = "Stage edits locally, preview the diff, then type APPLY to save."
                    self.update(fill: true); self.startTimer()
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            }
        } catch { status.stringValue = error.localizedDescription; update() }
    }
    @objc private func disconnectPressed() {
        guard !busy, allowDiscard() else { return }; stop(); draft = SC3RFDraft(); diff.string = "Disconnected."; telemetry.stringValue = "No current observation."
        status.stringValue = "RF Lab disconnected. Sumo control/video were not disconnected."; update(fill: true)
    }
    @objc private func refreshPressed() {
        guard let client, !busy, allowDiscard() else { return }
        perform({ try client.prepare(); return try client.settings() }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let settings): self.draft = SC3RFDraft(settings: settings); self.invalidFields.removeAll(); self.diff.string = "Preview the actual INI diff before saving."; self.notice.stringValue = "Saved settings reread; edits discarded."; self.update(fill: true)
            case .failure(let error): self.connectionFailed(error)
            }
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, SC3RFKey.allCases.indices.contains(field.tag) else { return }
        stage(SC3RFKey.allCases[field.tag], field.stringValue)
    }
    @objc private func tpcChanged() { stage(.tpc, toggles[.tpc]?.indexOfSelectedItem == 1 ? "0" : "1") }
    @objc private func unsetPressed(_ sender: NSButton) { stage(SC3RFKey.allCases[sender.tag], "unset"); update(fill: true) }
    private func stage(_ key: SC3RFKey, _ value: String) {
        guard !busy, client != nil else { return }
        do { try draft.stage(key, value: value); invalidFields.remove(key); notice.stringValue = "Local edits only · \(draft.edits.count) pending setting(s)." }
        catch { draft.invalidatePreview(); invalidFields.insert(key); notice.stringValue = error.localizedDescription }
        diff.string = "Preview required after editing."; update()
    }
    @objc private func discardPressed() { draft.discard(); invalidFields.removeAll(); notice.stringValue = "Local edits discarded."; diff.string = "No reviewed changes."; update(fill: true) }
    @objc private func previewPressed() {
        guard let client, let settings = draft.settings, !busy, invalidFields.isEmpty else { return }
        let pairs = draft.pairs
        perform({ try client.preview(hash: settings.hash, pairs: pairs) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                do { try self.draft.acceptPreview(text, hash: settings.hash, pairs: pairs); self.diff.string = text; self.notice.stringValue = "Diff ready. Review all changes before Save." }
                catch { self.notice.stringValue = error.localizedDescription }
            case .failure(let error): self.notice.stringValue = "Preview refused: \(error.localizedDescription) Refresh/review if the INI changed."
            }
        }
    }
    @objc private func savePressed() {
        guard let client, let reviewed = draft.preview, reviewed.pairs == draft.pairs, !busy, invalidFields.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "Save these reviewed SC3 INI changes?"
        alert.informativeText = "This persistently changes the SC3 INI and preserves recovery backups. It may disrupt the link after later activation. No reboot or radio reload will run. Type APPLY to save exactly the displayed diff."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); field.placeholderString = "Type APPLY"; alert.accessoryView = field
        alert.addButton(withTitle: "Save reviewed changes"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, field.stringValue == "APPLY" else { return }
        guard onBeginWrite?() ?? true else { notice.stringValue = "Another device operation is active; wait and review before saving."; return }
        let approval = field.stringValue; saving = true
        perform({ try client.apply(reviewed, approval: approval) }) { [weak self] result in
            guard let self else { return }; self.saving = false; self.onEndWrite?()
            switch result {
            case .success(let outcome):
                self.notice.stringValue = outcome.message; self.draft = SC3RFDraft(settings: outcome.settings)
                self.diff.string = reviewed.diff; self.update(fill: true)
                if outcome.settings == nil { self.client = nil; self.timer?.invalidate() }
            case .failure(let error): self.connectionFailed(error)
            }
        }
    }
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }
    }
    @objc private func monitoringPressed() { if monitoring.state == .on { poll() } }
    private func poll() {
        guard monitoring.state == .on, let client, !busy, window?.isVisible == true,
              !((window?.firstResponder as? NSTextView)?.isEditable == true) else { return }
        perform({ try client.observe() }) { [weak self] result in
            switch result { case .success(let observation): self?.show(observation); case .failure(let error): self?.connectionFailed(error) }
        }
    }
    private func connectionFailed(_ error: Error) {
        notice.stringValue = error.localizedDescription; stop()
        draft.discard(); previous = nil; telemetry.stringValue = "Observation unavailable · reconnect and reread settings."
    }
    private func show(_ o: SC3RFObservation) {
        telemetry.stringValue = "\(o.peer == nil ? "NOT ASSOCIATED" : "ASSOCIATED") · SSID: \(o.ssid ?? "—") · peer: \(o.peer ?? "—")\n" +
            "Receive RSSI: \(o.signal ?? "—") dBm    A0: \(o.a0 ?? "—")    A1: \(o.a1 ?? "—")    Noise: \(o.noise ?? "—")    SNR: \(o.snr ?? "—")\n" +
            "PHY TX / RX: \(o.txPHY ?? "—") / \(o.rxPHY ?? "—") Mbps    Observed TX / RX: \(o.traffic(since: previous))\n" +
            "Driver retries / failed: \(o.retries ?? "—") / \(o.failures ?? "—")    Interface errors TX / RX: \(o.txErrors ?? "—") / \(o.rxErrors ?? "—")\n" +
            "SC3 TX-power driver readback: \(o.txPower ?? "—") dBm · saved configuration is separate"
        previous = o
    }

    static func fixture(settings: SC3RFSettings, observation: SC3RFObservation, client: SC3RFClient) throws -> SC3RFWindow {
        let panel = SC3RFWindow(); panel.client = client; panel.draft.settings = settings
        panel.status.stringValue = "Fixture preview · no hardware connection or setting writes"
        panel.show(observation); panel.update(fill: true)
        panel.stage(.cap, "20"); panel.stage(.tpc, "0"); panel.update(fill: true)
        let pairs = panel.draft.pairs
        let text = "Base INI SHA-1: \(settings.hash)\n--- saved INI\n+++ pending INI\n+gTxPowerCap=20\n+gAllowTPCfromAP=0\nPreview only; no INI setting saved, radio reload or reboot performed.\n"
        try panel.draft.acceptPreview(text, hash: settings.hash, pairs: pairs); panel.diff.string = text; panel.update()
        return panel
    }
    static func interactionSelfTest(settings: SC3RFSettings, client: SC3RFClient) -> Bool {
        let panel = SC3RFWindow()
        guard panel.saved.values.allSatisfy({ $0.stringValue == "Saved: — (not read)" }) else { return false }
        panel.client = client; panel.draft.settings = settings; panel.update(fill: true)
        panel.stage(.cap, "20"); panel.stage(.sar2, "22"); panel.stage(.sar5, "23"); panel.stage(.tpc, "0"); panel.stage(.flex, "2")
        guard panel.draft.edits.count == 5, panel.previewButton.isEnabled, !panel.save.isEnabled else { return false }
        panel.stage(.flex, "bad")
        guard panel.draft.edits.count == 5, !panel.previewButton.isEnabled, panel.inputs[.flex]?.isEnabled == true else { return false }
        panel.stage(.flex, "3"); panel.busy = true; panel.update()
        guard !panel.previewButton.isEnabled, !panel.disconnect.isEnabled else { return false }
        panel.busy = false; panel.discardPressed()
        return panel.draft.edits.isEmpty && !panel.save.isEnabled
    }
    static func cancellationSelfTest() -> Bool {
        let panel = SC3RFWindow(), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        var callback = false
        panel.perform({ release.wait(); finished.signal(); return true }) { _ in callback = true }
        panel.stop(); release.signal()
        guard finished.wait(timeout: .now() + 2) == .success else { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        return !callback && !panel.busy && panel.client == nil
    }
    func scrollFixtureToPreview() {
        if let preview = diff.enclosingScrollView { _ = preview.scrollToVisible(preview.bounds) }
    }
}
