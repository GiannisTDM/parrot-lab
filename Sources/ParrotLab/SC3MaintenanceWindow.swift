import AppKit

final class SC3MaintenanceWindow: NSWindowController, NSWindowDelegate {
    var onBegin: (() -> Bool)?
    var onEnd: (() -> Void)?
    private let runner = SC3MaintenanceProcess()
    private var state = SC3RootWizardState()
    private var boundConfiguration: SC3MaintenanceConfiguration?
    private var contractOK = false, failed = false
    private var mutationAttempted = false
    private var everVerifiedRoot = false
    private var lastSession: URL?
    private var detectedStock = "", detectedFastboot = ""
    private let newIdentity = NSButton(title: "Use another controller (preserve earlier evidence)", target: nil, action: nil)
    private let python = NSTextField(string: "/opt/homebrew/bin/python3"), adb = NSTextField(string: "/opt/homebrew/bin/adb"), fastboot = NSTextField(string: "/opt/homebrew/bin/fastboot")
    private let port = NSTextField(string: "5038"), endpoint = NSTextField(string: "192.168.53.1:9050")
    private let stockSerial = NSTextField(wrappingLabelWithString: "Detected during identity check"), fastbootSerial = NSTextField(wrappingLabelWithString: "Detected after manual fastboot entry")
    private let vehiclesOff = NSButton(checkboxWithTitle: "All vehicles are powered OFF; only the selected SC3 is connected", target: nil, action: nil)
    private let sumoOff = NSButton(checkboxWithTitle: "The Sumo is powered OFF before native daemon maintenance", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Check runtimes first. Nothing runs automatically when this panel opens.")
    private let phase = NSTextField(wrappingLabelWithString: "Keep only the same SC3 connected. Serials are detected automatically. Already enabled? Use Verify debug via web.")
    private let evidence = NSTextField(wrappingLabelWithString: "No private session selected.")
    private let modStatus = NSTextField(wrappingLabelWithString: "Root verification and native status have not been read.")
    private let runtime = NSButton(title: "Check runtimes & signed bundle", target: nil, action: nil)
    private let next = NSButton(title: "Prepare root session…", target: nil, action: nil)
    private let verify = NSButton(title: "Verify debug via web", target: nil, action: nil)
    private let verifyADB = NSButton(title: "Check ADB root access (optional)", target: nil, action: nil)
    private let prior = NSButton(title: "Open prior session…", target: nil, action: nil)
    private let reveal = NSButton(title: "Reveal private session", target: nil, action: nil)
    private let disable = NSButton(title: "Disable recorded root property…", target: nil, action: nil)
    private let readStatus = NSButton(title: "Read native status", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel read-only check", target: nil, action: nil)
    private var mutations: [SC3MaintenanceOperation: NSButton] = [:]

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 850, height: 850), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "SkyController 3 · Maintenance"; panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua); panel.backgroundColor = LabVisualStyle.panel
        super.init(window: panel); panel.delegate = self
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(scroll)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 22, right: 22); root.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = root
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor), scroll.topAnchor.constraint(equalTo: panel.contentView!.topAnchor), scroll.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor), root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), root.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)])
        func add(_ view: NSView) { root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44).isActive = true }
        func label(_ text: String, heading: Bool = false) {
            let item = NSTextField(wrappingLabelWithString: text); item.font = .systemFont(ofSize: heading ? 15 : 12, weight: heading ? .semibold : .regular)
            if !heading { item.textColor = .secondaryLabelColor }; add(item)
        }
        func row(_ text: String, _ field: NSTextField) {
            let title = NSTextField(labelWithString: text); title.widthAnchor.constraint(equalToConstant: 130).isActive = true
            field.setAccessibilityLabel(text); add(NSStackView(views: [title, field]))
        }
        label("Owner maintenance · retail SC3 1.8.1 / hardware3", heading: true)
        label("Separate from native Sumo video/mappings and RF Lab. Disconnect the app's vehicle session and stop video first; return to Air/Ground if using MiniDrone/ANAFI. No controller changes occur during app integration tests.")
        row("Python 3.9+", python); row("ADB executable", adb); row("Fastboot executable", fastboot)
        row("Existing ADB port", port); row("Selected USB IP:port", endpoint)
        row("Stock serial", stockSerial); row("Fastboot serial", fastbootSerial)
        add(runtime); add(status)
        label("Root setup · one explicit phase at a time", heading: true)
        label("Unofficial procedure. Enables global debug consumers and root TCP ADB/9050 over USB networking, not just app permission or a native USB ADB interface. Use trusted/isolated links. Not reset/update-proof; no tested whole-chip recovery. Original boot/system/recovery images are not flashed.")
        add(vehiclesOff); add(phase); add(next)
        add(NSStackView(views: [verify, prior, reveal])); add(newIdentity); add(evidence); add(disable)
        label("Sensitive evidence stays in a private Application Support session, excluded from app diagnostic exports. Preserve failed phases, locks and markers; no auto-cleanup or mutation retry. A 268 MB ECC-corrected data pair is not a NAND/OOB backup.")
        label("Native Sumo manager · exact v1c only", heading: true)
        add(verifyADB)
        label("Web verification completes root setup. Native daemon tools and property removal separately require working ADB with UID 0; a web result does not claim shell access.")
        add(sumoOff); add(readStatus); modStatus.font = .monospacedSystemFont(ofSize: 12, weight: .regular); add(modStatus)
        let titles: [(SC3MaintenanceOperation, String)] = [(.install, "Install v1c for future starts…"), (.activate, "Activate v1c now…"), (.futureOn, "Enable future loading…"), (.futureOff, "Disable future loading…"), (.stock, "Restore stock now…"), (.remove, "Remove startup hook…")]
        for (op, title) in titles {
            let button = NSButton(title: title, target: self, action: #selector(modPressed(_:))); button.identifier = NSUserInterfaceItemIdentifier(op.rawValue)
            mutations[op] = button; add(button)
        }
        label("Install does not restart/reboot. Activation is separate; remembered peers may associate when mppd starts. Stock restore retains backups; hook removal retains the unused selector for cached init. No video, robot-connection or mapping success is implied. Active v2/video extensions and unknown hashes are STOP, never a downgrade. No relay, pairing, RF, firmware or robot commands are added.")
        add(cancel)
        for (button, action) in [(runtime, #selector(runtimePressed)), (next, #selector(nextPressed)), (verify, #selector(verifyPressed)), (verifyADB, #selector(verifyADBPressed)), (prior, #selector(priorPressed)), (reveal, #selector(revealPressed)), (disable, #selector(disablePressed)), (readStatus, #selector(statusPressed)), (cancel, #selector(cancelPressed))] { button.target = self; button.action = action }
        for check in [vehiclesOff, sumoOff] { check.target = self; check.action = #selector(update) }
        newIdentity.target = self; newIdentity.action = #selector(newIdentityPressed)
        panel.minSize = NSSize(width: 800, height: 650); panel.center(); update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func configuration() throws -> SC3MaintenanceConfiguration {
        guard let number = Int(port.stringValue) else { throw SC3RFError("Invalid existing ADB port.") }
        return SC3MaintenanceConfiguration(python: python.stringValue, adb: adb.stringValue, fastboot: fastboot.stringValue, port: number, endpoint: endpoint.stringValue, stockSerial: detectedStock, fastbootSerial: detectedFastboot)
    }
    @objc private func update() {
        let idle = !runner.isBusy
        for field in [python, adb, fastboot] { field.isEnabled = idle }
        for field in [port, endpoint] { field.isEnabled = idle && state.session == nil }
        runtime.isEnabled = idle
        next.isEnabled = idle && state.runtimeReady && state.next != nil && vehiclesOff.state == .on && !failed
        verify.isEnabled = idle && state.runtimeReady
        verifyADB.isEnabled = idle && state.runtimeReady
        prior.isEnabled = idle; reveal.isEnabled = state.session != nil || lastSession != nil
        newIdentity.isEnabled = idle && ((!mutationAttempted && !everVerifiedRoot) || (state.debugVerified && !failed))
        disable.isEnabled = idle && state.runtimeReady && state.rootVerified && hasRemovalProvenance && vehiclesOff.state == .on
        readStatus.isEnabled = idle && state.rootVerified
        for button in mutations.values { button.isEnabled = idle && state.rootVerified && contractOK && sumoOff.state == .on }
        cancel.isEnabled = runner.isBusy && !runner.isCritical
        next.title = state.debugVerified ? "Debug enablement verified" : state.next.map { title($0) } ?? "STOP · use a read-only checkpoint"
        evidence.stringValue = state.session.map { "Private session: \($0.path)\nOriginal snapshots/provenance stay here; no export or automatic deletion." } ?? "No matching root-enablement provenance. Older installations cannot be force-disabled."
    }
    private func title(_ operation: SC3MaintenanceOperation) -> String {
        switch operation {
        case .prepare: return "1 · Check identity & prepare private session…"
        case .fastboot: return "2 · Detect connected fastboot controller"
        case .boot: return "3 · Boot V5 into RAM once…"
        case .snapshot: return "4 · Capture the data pair…"
        case .inspect: return "5 · Inspect storage / archive properties…"
        case .enable: return "6 · Enable persistent debug…"
        case .reboot: return "7 · Return to stock once…"
        case .verify: return "8 · Verify debug via web"
        case .verifyADB: return "Check ADB root access (optional)"
        case .disable: return "Disable recorded root property…"
        default: return mutations[operation]?.title ?? operation.rawValue
        }
    }
    private var hasRemovalProvenance: Bool {
        guard let session = state.session,
              let row = try? SC3MaintenancePrivateJSON.read(session.appendingPathComponent("inspection.json")), row["state"] as? String == "ABSENT",
              FileManager.default.fileExists(atPath: session.appendingPathComponent("enabled.json").path) else { return false }
        return true // The backend independently verifies snapshots/archive/receipt before removal.
    }
    @objc private func runtimePressed() { run(.runtime, consent: false) }
    @objc private func nextPressed() {
        guard let next = state.next, vehiclesOff.state == .on, !failed else { return }
        do {
            let config = try configuration(); try config.validate(for: next)
            guard boundConfiguration == config else { throw SC3RFError("Check runtimes with these selected identities first.") }
        } catch { status.stringValue = error.localizedDescription; return }
        let needsConsent = next.critical || next == .prepare
        guard !needsConsent || confirm(next) else { return }
        if next == .prepare, state.session == nil {
            do {
                let parent = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Parrot Lab/SC3 Maintenance", isDirectory: true)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
                var url = parent; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? url.setResourceValues(values)
                state.session = parent.appendingPathComponent("sc3-session-" + UUID().uuidString); lastSession = state.session
            } catch { status.stringValue = error.localizedDescription; return }
        }
        run(next, consent: next.critical)
    }
    private func confirm(_ operation: SC3MaintenanceOperation) -> Bool {
        let alert = NSAlert(); alert.messageText = title(operation); alert.informativeText = operation.explanation
        alert.addButton(withTitle: operation.critical ? "Confirm this phase" : "Prepare session"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc private func verifyPressed() { run(.verify, consent: false) }
    @objc private func verifyADBPressed() { run(.verifyADB, consent: false) }
    @objc private func statusPressed() { run(.status, consent: false) }
    @objc private func disablePressed() { guard hasRemovalProvenance, vehiclesOff.state == .on, confirm(.disable) else { return }; run(.disable, consent: true) }
    @objc private func modPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let operation = SC3MaintenanceOperation(rawValue: id), state.rootVerified, contractOK, sumoOff.state == .on, confirm(operation) else { return }
        run(operation, consent: true)
    }
    @objc private func revealPressed() { if let session = state.session ?? lastSession { NSWorkspace.shared.activateFileViewerSelecting([session]) } }
    @objc private func newIdentityPressed() {
        guard !runner.isBusy, (!mutationAttempted && !everVerifiedRoot) || (state.debugVerified && !failed) else { return }
        lastSession = state.session ?? lastSession; state = SC3RootWizardState(); boundConfiguration = nil; failed = false; contractOK = false
        mutationAttempted = false; everVerifiedRoot = false; detectedStock = ""; detectedFastboot = ""
        stockSerial.stringValue = "Detected during identity check"; fastbootSerial.stringValue = "Detected after manual fastboot entry"
        vehiclesOff.state = .off; sumoOff.state = .off
        phase.stringValue = "Keep only the same SC3 connected. Serials are detected automatically. Already enabled? Use Verify debug via web."
        status.stringValue = "Fresh read-only identity check selected. Earlier folders are preserved; no root phase has been replayed."; update()
    }
    @objc private func priorPressed() {
        guard !runner.isBusy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose this tool's private session. It opens as a read-only checkpoint; no root phase is replayed."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory, (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw SC3RFError("Select an owned private session directory (0700).") }
            let row = try SC3MaintenancePrivateJSON.read(directory.appendingPathComponent("session.json"))
            guard row["format"] as? String == "sc3-app-session-v1",
                  row["firmware"] as? String == "1.8.1", row["hardware"] as? String == "3", let serial = row["stock_serial"] as? String,
                  let address = row["endpoint"] as? String, let server = row["adb_port"] as? Int else { throw SC3RFError("Not a matching API-v1 session; no provenance is invented.") }
            detectedStock = serial; detectedFastboot = row["fastboot_serial"] as? String ?? ""
            stockSerial.stringValue = serial; fastbootSerial.stringValue = detectedFastboot.isEmpty ? "Recorded by fastboot checkpoint if reached" : detectedFastboot
            endpoint.stringValue = address; port.stringValue = String(server)
            state.resumeCheckpoint(directory); failed = true; contractOK = false
            mutationAttempted = true; lastSession = directory
            status.stringValue = "STOP / prior evidence opened. Verify a stock checkpoint; locks/markers are preserved."
            update()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func cancelPressed() { runner.cancelReadOnly() }
    private func checkFailed(_ operation: SC3MaintenanceOperation, message: String) {
        if operation == .prepare { lastSession = state.session ?? lastSession }
        let repeatable = state.failed(operation)
        failed = !repeatable; contractOK = false
        if operation == .runtime { boundConfiguration = nil }
        if repeatable {
            let instruction = operation == .runtime ? "Check the runtime paths and repeat this local check." : operation == .prepare ? "Check the SC3 USB link/address, then repeat step 1. Any partial host evidence is preserved." : "Keep one SC3 connected in fastboot and repeat step 2. No RAM boot was sent."
            status.stringValue = "Check unavailable: \(message)\n\(instruction)"
        } else {
            status.stringValue = [.verify, .verifyADB].contains(operation) ? "Verification unavailable: \(message)\nRepeat only this read-only check when the link is ready. Do not repeat steps 1–7." : "STOP / unknown outcome: \(message)\nPreserve the session and request a checkpoint. No mutation is retried."
        }
        update()
    }
    private func run(_ operation: SC3MaintenanceOperation, consent: Bool) {
        guard !runner.isBusy else { return }
        do {
            let config = try configuration(); try config.validate(for: operation)
            if operation == .snapshot, let session = state.session {
                let free = (try FileManager.default.attributesOfFileSystem(forPath: session.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
                guard free >= 512 * 1_024 * 1_024 else { throw SC3RFError("At least512 MiB of free private host storage is required before the data pair.") }
            }
            if operation != .runtime, boundConfiguration != config { throw SC3RFError("Check the selected runtimes/configuration again before using the controller.") }
            guard let lease = SC3MaintenanceCoordinator.shared.acquire("root/native manager", critical: operation.critical) else { throw SC3RFError("Another SC3 maintenance task is active; wait for its checked result.") }
            let ownsVehicleBlock = operation.critical
            guard !ownsVehicleBlock || (onBegin?() ?? true) else { SC3MaintenanceCoordinator.shared.release(lease); throw SC3RFError("Disconnect the app's vehicle session and stop video first. Another device task may also be active.") }
            if operation.critical { mutationAttempted = true }
            let session = operation.sumo || operation == .runtime ? nil : state.session
            status.stringValue = "\(operation.rawValue) · checking; no overall percentage is inferred."
            let started = runner.start(operation, config: config, session: session, consent: consent, event: { [weak self] event in
                self?.show(event)
            }, warning: { [weak self] message in
                self?.checkFailed(operation, message: message)
            }) { [weak self] result in
                SC3MaintenanceCoordinator.shared.release(lease)
                guard let self else { return }; if ownsVehicleBlock { self.onEnd?() }
                switch result {
                case .success(let transcript):
                    self.state.finished(operation)
                    if [.verify, .verifyADB].contains(operation) { self.everVerifiedRoot = true; self.failed = false }
                    var checked = config
                    for event in transcript.events {
                        if ["prepared", "root_verified", "debug_verified"].contains(event.name), let serial = event.fields["stock_serial"] as? String { self.detectedStock = serial; self.stockSerial.stringValue = serial; checked.stockSerial = serial }
                        if event.name == "fastboot_ready", let serial = event.fields["serial"] as? String { self.detectedFastboot = serial; self.fastbootSerial.stringValue = serial; checked.fastbootSerial = serial }
                    }
                    self.boundConfiguration = checked
                    self.status.stringValue = operation == .verify ? "Web API confirms rw.debuggable = 1. Debug enablement verified; ADB access was not tested." : operation == .verifyADB ? "ADB UID 0, original adbd, debug flags and required boot checks verified." : "\(operation.rawValue) completed; no further mutation is automatic."
                    if transcript.events.contains(where: { $0.name == "reboot_ack_unknown" }) { self.status.stringValue = "Reboot acknowledgement UNKNOWN. Do not resend; wait for USB networking and verify stock." }
                    if operation == .prepare { self.phase.stringValue = "Keep this same SC3 connected. Enter fastboot manually: power off via holder; open holder and tap populated RTH six times around startup. RGB cycling is only an indication. Detect the single connected controller; never use a software reset/recovery guess." }
                    else if operation == .boot { self.phase.stringValue = "RAM root and guarded keep marker verified. Persistent storage has not yet been attached." }
                    else if operation == .reboot { self.phase.stringValue = "Wait for normal USB networking. Reboot was requested once; acknowledgement may be unknown. Use read-only stock verification; never resend reboot." }
                    else if operation == .verify { self.phase.stringValue = "Setup verified through a fresh web response from this SC3. No ADB reconnect/reset or further root operation was sent. Native tools can separately check ADB access below." }
                    else if operation == .verifyADB { self.phase.stringValue = "ADB root access verified separately. Native daemon autostart, Sumo association and video remain separate checks." }
                    if let contract = transcript.contract { self.contractOK = contract }
                case .failure(let error):
                    self.checkFailed(operation, message: error.localizedDescription)
                }
                self.update()
            }
            if !started { SC3MaintenanceCoordinator.shared.release(lease); if ownsVehicleBlock { onEnd?() } }
            update()
        } catch { status.stringValue = error.localizedDescription; update() }
    }
    private func show(_ event: SC3MaintenanceEvent) {
        if event.name == "progress" { status.stringValue = event.fields["detail"] as? String ?? "Checking current phase…" }
        if event.name == "sumo_contract" {
            contractOK = event.fields["compatible"] as? Bool == true
            modStatus.stringValue += "\nRunning binary: \(event.fields["active_variant"] as? String ?? "unknown")\nRunning SHA-1: \(event.fields["active_sha1"] as? String ?? "unknown")\nV1c manager compatible: \(contractOK ? "yes" : "NO · preserve newer/unknown setup")"
        }
        if event.name == "sumo_status" {
            modStatus.stringValue = "Visible executable: \(event.fields["variant"] as? String ?? "unknown")\nSHA-1: \(event.fields["executable_sha1"] as? String ?? "unknown")\nActual service: \(event.fields["service"] as? String ?? "unknown")\nFuture native loading: \(event.fields["startup_enabled"] as? Bool == true ? "enabled" : "disabled")\nVideo / Sumo association are not established by this status."
        }
        if event.name == "sumo_complete" {
            status.stringValue = "Native command reported completion; reading actual service/executable/startup state. No reboot or robot/video success is implied."
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !runner.isCritical else { status.stringValue = "Critical phase still active. Wait; preserve evidence and request a checkpoint rather than interrupting storage/reboot work."; return false }
        runner.cancelReadOnly(); return true
    }
    func stopReadOnly() { runner.cancelReadOnly() }
    static func automaticIdentitySelfTest() -> Bool {
        _ = NSApplication.shared
        let panel = SC3MaintenanceWindow()
        guard !panel.stockSerial.isEditable, !panel.fastbootSerial.isEditable,
              let config = try? panel.configuration(),
              let arguments = try? config.arguments(.prepare, session: nil, consent: false),
              !arguments.contains("--stock-serial"), !arguments.contains("--fastboot-serial") else { return false }
        let old = URL(fileURLWithPath: "/private/previous-controller-session")
        panel.state.runtimeReady = true; panel.state.session = old; panel.vehiclesOff.state = .on
        panel.checkFailed(.prepare, message: "fixture HTTP timeout")
        guard panel.lastSession == old, panel.state.session == nil, panel.next.isEnabled,
              panel.endpoint.isEnabled, !panel.failed else { return false }
        panel.state.session = old; panel.state.finished(.prepare)
        panel.checkFailed(.fastboot, message: "fixture device absent")
        guard panel.state.next == .fastboot, panel.state.session == old, panel.next.isEnabled else { return false }
        panel.state.session = old; panel.state.finished(.verify)
        panel.mutationAttempted = true; panel.everVerifiedRoot = true
        panel.detectedStock = "OTHERCONTROLLER"; panel.detectedFastboot = "abcd5678"
        panel.vehiclesOff.state = .on; panel.sumoOff.state = .on
        panel.update()
        guard panel.newIdentity.isEnabled, panel.state.debugVerified, !panel.state.rootVerified,
              !panel.readStatus.isEnabled, !panel.disable.isEnabled else { return false }
        panel.state.finished(.verifyADB); panel.update()
        guard panel.state.rootVerified, panel.readStatus.isEnabled else { return false }
        panel.newIdentityPressed()
        guard panel.state.phase == .initial, panel.lastSession == old, panel.state.session == nil,
              !panel.state.rootVerified, panel.detectedStock.isEmpty, panel.detectedFastboot.isEmpty,
              panel.vehiclesOff.state == .off, panel.sumoOff.state == .off else { return false }
        panel.mutationAttempted = true; panel.failed = true; panel.state.stop(); panel.update()
        guard !panel.newIdentity.isEnabled else { return false }
        panel.newIdentityPressed()
        return panel.state.phase == .checkpoint
    }
}
