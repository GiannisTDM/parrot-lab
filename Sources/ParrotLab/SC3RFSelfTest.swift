import AppKit

enum SC3RFSelfTest {
    static let ini = "# representative baseline\nTxPower2g=10\nTxPower5g=10\nEND\n"
    static func json(ini: String, saved: [SC3RFKey: String] = [.sar2: "10", .sar5: "10"], invalid: SC3RFKey? = nil) throws -> Data {
        let rows: [[String: Any]] = SC3RFKey.allCases.map { key in
            ["key": key.rawValue, "kind": key == .tpc ? "toggle" : "integer", "min": key.range.lowerBound,
             "max": key.range.upperBound, "driver_default": key.driverDefault,
             "saved": invalid == key ? NSNull() : saved[key].map { $0 as Any } ?? NSNull(),
             "source": invalid == key ? "invalid" : saved[key] == nil ? "unset" : "explicit",
             "within_editor_range": invalid == key ? false : saved[key].flatMap(Int.init).map { key.range.contains($0) } ?? (saved[key] == nil), "unset_allowed": true]
        }
        return try JSONSerialization.data(withJSONObject: ["schema": "sc3-rf-settings-v1", "version": "0.2.0",
            "ini_sha1": SC3RFSettings.digest(Data(ini.utf8)), "settings": rows,
            "saved_is_live_output": false, "radio_reload_performed": false], options: [.sortedKeys])
    }
    static func settings() throws -> SC3RFSettings { try SC3RFSettings(json: json(ini: ini), ini: Data(ini.utf8)) }
    static let snapshot = """
    SC3 TX-power readback: 14 dBm (driver statistic, not measured EIRP)
    Driver RSSI: -42 dBm | noise: -- dBm | SNR: -- dB

    Netlink link:
    Connected to aa:bb:cc:dd:ee:ff (on wlan0)
      SSID: JumpingSumo_example
      signal: -42 dBm
      tx bitrate: 65.0 MBit/s

    Netlink station:
      tx retries: 0
      tx failed: 0

    Vendor chain reply:
    chain0_dbm=-44
    chain1_dbm=-46

    INI digest: fixture
    """
    static func observation(bytes: UInt64 = 1000, uptime: String = "100.0 0.0\n", idle: Bool = false) -> SC3RFObservation {
        SC3RFObservation(snapshot: idle ? snapshot.replacingOccurrences(of: "Connected to", with: "Not connected to") : snapshot,
            counters: "wlan0: \(bytes) 1 0 0 0 0 0 0 \(bytes * 2) 2 0 0 0 0 0 0\n", uptime: uptime)
    }
    static func run() -> Bool {
        do {
            func expect(_ value: Bool, _ reason: String) throws { if !value { throw SC3RFError("RF Lab self-test: " + reason) } }
            func refuses(_ work: () throws -> Void) -> Bool { do { try work(); return false } catch { return true } }
            let resources = try SC3RFResources(), baseline = try settings()
            try expect(baseline.fileIssue == nil && baseline.rows[.cap]?.saved == nil && baseline.rows[.sar2]?.saved == "10", "null / explicit saved values")
            for change in ["\"version\":\"0.2.0\"": "\"version\":\"0.3.0\"", "\"saved\":\"10\"": "\"saved\":10", "\"schema\":": "\"surprise\":true,\"schema\":"] {
                let text = String(data: try json(ini: ini), encoding: .utf8)!.replacingOccurrences(of: change.key, with: change.value)
                try expect(refuses { _ = try SC3RFSettings(json: Data(text.utf8), ini: Data(ini.utf8)) }, "schema surprise")
            }
            try expect(refuses { try SC3RFJSON.validate(Data("{\"schema\":1,\"sch\\u0065ma\":2}".utf8)) }, "escaped duplicate JSON keys")
            for bad in [ini.replacingOccurrences(of: "END", with: "TxPower2g=10\nEND"), ini + "gAllowTPCfromAP=1\n", ini.replacingOccurrences(of: "END", with: "END\nEND")] {
                let settings = try SC3RFSettings(json: json(ini: bad), ini: Data(bad.utf8))
                try expect(settings.fileIssue != nil, "ambiguous file blocks save")
            }
            let unusualINI = ini.replacingOccurrences(of: "END", with: "gTxPowerCap=128\nEND")
            let unusual = try SC3RFSettings(json: json(ini: unusualINI, saved: [.cap: "128", .sar2: "10", .sar5: "10"]), ini: Data(unusualINI.utf8))
            try expect(unusual.rows[.cap]?.saved == "128" && unusual.fileIssue == nil, "preserve sentinel without clamping")
            var unusualDraft = SC3RFDraft(settings: unusual); try unusualDraft.stage(.sar2, value: "20")
            try expect(unusualDraft.pairs == ["TxPower2g", "20"] && unusualDraft.settings?.rows[.cap]?.saved == "128", "editing another key preserves unusual baseline")
            let invalidINI = ini.replacingOccurrences(of: "TxPower2g=10", with: "TxPower2g=oops")
            let invalid = try SC3RFSettings(json: json(ini: invalidINI, invalid: .sar2), ini: Data(invalidINI.utf8))
            try expect(invalid.fileIssue != nil, "invalid source blocks save")
            var draft = SC3RFDraft(settings: baseline)
            for key in SC3RFKey.allCases { try draft.stage(key, value: key == .tpc ? "off" : "2") }
            try expect(draft.edits.count == 5, "five-field staging")
            let pairs = draft.pairs
            let previewText = "Base INI SHA-1: \(baseline.hash)\n--- saved\n+++ pending\n+gTxPowerCap=2\nPreview only; no INI setting saved, radio reload or reboot performed.\n"
            try draft.acceptPreview(previewText, hash: baseline.hash, pairs: pairs)
            try expect(draft.preview?.pairs == pairs, "exact preview pairs")
            try draft.stage(.cap, value: "unset")
            try expect(draft.preview == nil && draft.edits[.cap] == nil, "unset absent and invalidate diff")
            try draft.stage(.sar2, value: "30"); try expect(draft.edits[.sar2] == "30", "explicit default differs from unset")
            try draft.stage(.sar2, value: "unset"); try expect(draft.edits[.sar2] == "unset", "unset action")
            try expect(refuses { try draft.acceptPreview(previewText, hash: String(repeating: "0", count: 40), pairs: pairs) }, "stale preview hash")
            draft.discard(); try expect(draft.edits.isEmpty && draft.preview == nil, "cancel / discard")
            for pairs in [["gEnableCloseLoop", "0"], ["gTxPowerCap", "31"], ["gAllowTPCfromAP", "2"], ["gFlexConnectPowerFactor", "10"], ["gTxPowerCap", "1;reboot"], ["gTxPowerCap", "1", "gTxPowerCap", "2"]] {
                try expect(refuses { try SC3RFClient.validatePairs(pairs, hash: baseline.hash) }, "allowlist bounds and duplicate keys")
            }
            for text in ["{}", "{}\nMARK=0\njunk", "{}\nMARK=bad\n", "{}\nMARK=0\n\n"] {
                try expect(refuses { _ = try SC3RFClient.decode(text, marker: "MARK") }, "missing / malformed status")
            }
            let decoded = try SC3RFClient.decode("{}\nMARK=7\n", marker: "MARK")
            try expect(decoded.status == 7 && decoded.text == "{}", "remote nonzero distinct from local exit")
            let crlf = try SC3RFClient.decode("line\r\n\nMARK=0\n", marker: "MARK")
            try expect(crlf.text == "line\r\n", "non-TTY status stripping preserves INI bytes")
            let crlfINI = ini.replacingOccurrences(of: "\n", with: "\r\n")
            try expect(try SC3RFSettings(json: json(ini: crlfINI), ini: Data(crlfINI.utf8)).fileIssue == nil, "CRLF INI digest and rows")
            for identity in ["2000\nmpp3\n1.8.1\n", "0\nanafi\n1.8.1\n", "0\nmpp3\n1.8.2\n"] {
                let executor = SC3RFFixture(resources: resources); executor.identity = identity
                let client = SC3RFClient(executor: executor, resources: resources)
                try expect(refuses { try client.prepare() } && executor.pushes == 0, "identity checked before upload")
            }
            let executor = SC3RFFixture(resources: resources), client = SC3RFClient(executor: SC3RFFixture(resources: resources), resources: resources)
            let testClient = SC3RFClient(executor: executor, resources: resources)
            try testClient.prepare(); try expect(executor.pushes == 2, "missing helper restored only to RAM")
            try testClient.prepare(); try expect(executor.pushes == 2, "existing pinned tools reused")
            executor.refusePreview = true
            try expect(refuses { _ = try testClient.preview(hash: baseline.hash, pairs: ["gTxPowerCap", "20"]) }, "stale hash error / separate stderr")
            executor.refusePreview = false
            let text = try testClient.preview(hash: baseline.hash, pairs: ["gTxPowerCap", "20"])
            var saveDraft = SC3RFDraft(settings: baseline); try saveDraft.stage(.cap, value: "20")
            try saveDraft.acceptPreview(text, hash: baseline.hash, pairs: saveDraft.pairs)
            let reviewed = saveDraft.preview!
            try expect(refuses { _ = try testClient.apply(reviewed, approval: "") } && executor.writes == 0, "no invented APPLY")
            executor.timeoutWrite = true
            let outcome = try testClient.apply(reviewed, approval: "APPLY")
            try expect(!outcome.confirmed && outcome.settings?.hash != baseline.hash && executor.writes == 1, "write timeout reconciles once, never retries")
            executor.timeoutWrite = false; executor.failReadback = true
            let missing = try testClient.apply(reviewed, approval: "APPLY")
            try expect(!missing.confirmed && missing.settings == nil && executor.writes == 2, "unavailable readback blocks further save")
            executor.failReadback = false; executor.ignoreWrite = true
            let mismatch = try testClient.apply(reviewed, approval: "APPLY")
            try expect(!mismatch.confirmed && mismatch.settings?.hash == baseline.hash, "remote success still requires matching readback")
            let o = observation(), next = observation(bytes: 501_000, uptime: "102.0 0\n"), idle = observation(idle: true)
            try expect(o.a0 == "-44" && o.a1 == "-46" && o.rxPHY == nil && o.noise == nil && o.snr == nil && o.retries == "0", "real versus unavailable metrics")
            try expect(next.traffic(since: o) == "4.00 / 2.00 Mbps" && idle.signal == nil && idle.a0 == nil && idle.traffic(since: o) == "— / — Mbps", "traffic deltas and disconnect reset")
            try expect(SC3RFWindow.interactionSelfTest(settings: baseline, client: client), "native staged editor interaction")
            try expect(SC3RFWindow.cancellationSelfTest(), "closed panel retires pending callbacks")
            try expect(try SC3RFADBExecutor.processSelfTest(), "bounded process capture and cancellation")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sc3-rf-assets-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            for name in SC3RFResources.pins.keys { try FileManager.default.copyItem(at: resources.directory.appendingPathComponent(name), to: directory.appendingPathComponent(name)) }
            try Data("bad".utf8).write(to: directory.appendingPathComponent("sc3-qca-rssi"))
            try expect(refuses { _ = try SC3RFResources(directory: directory) }, "resource integrity")
            print("SC3 RF Lab schema, staging, status, identity, resources and reconciliation tests passed (host fixtures)")
            return true
        } catch { fputs("\(error.localizedDescription)\n", stderr); return false }
    }

    static func render(to path: String) throws {
        let client = SC3RFClient(executor: SC3RFFixture(resources: try SC3RFResources()), resources: try SC3RFResources())
        let panel = try SC3RFWindow.fixture(settings: settings(), observation: observation(), client: client)
        guard let view = panel.window?.contentView else { throw SC3RFError("Missing RF panel.") }
        panel.window?.orderFront(nil)
        panel.window?.makeFirstResponder(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        func capture(_ path: String) throws {
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SC3RFError("Cannot render RF panel.") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SC3RFError("Cannot encode RF preview.") }
            try png.write(to: URL(fileURLWithPath: path))
            // Native control layers do not all participate in cacheDisplay.
            if let number = panel.window?.windowNumber, number > 0 {
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(number), path]
                capture.standardOutput = FileHandle.nullDevice; capture.standardError = FileHandle.nullDevice
                try capture.run(); capture.waitUntilExit()
            }
        }
        try capture(path)
        panel.scrollFixtureToPreview(); RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try capture(URL(fileURLWithPath: path).deletingPathExtension().path + "-preview.png")
        panel.window?.orderOut(nil); panel.stop()
    }
}

/// Scripted legacy ADB fixture: local success can hide a remote nonzero.
/// No network, actual ADB, radio, mount or persistent device file is used.
private final class SC3RFFixture: SC3RFExecuting {
    let resources: SC3RFResources
    var identity = "0\nmpp3\n1.8.1\n"
    var pushes = 0, writes = 0
    var installed = false, refusePreview = false, timeoutWrite = false, failReadback = false
    var changed = false
    var ignoreWrite = false
    private var error = ""
    init(resources: SC3RFResources) { self.resources = resources }
    func cancel() {}
    func run(_ arguments: [String], timeout: TimeInterval) throws -> SC3RFCommandOutput {
        if arguments.first == "push" { pushes += 1; if pushes == 2 { installed = true }; return .init(stdout: "", stderr: "pushed") }
        guard arguments.first == "exec-out", arguments.count == 2 else { throw SC3RFError("Unexpected fixture command") }
        let command = arguments[1]
        let regex = try NSRegularExpression(pattern: "APP_SC3_RF_[A-Z0-9]+(?:_ERR)?")
        guard let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)), let range = Range(match.range, in: command) else { throw SC3RFError("Missing fixture marker") }
        let marker = String(command[range]); var text = "", status = 0
        if marker.hasSuffix("_ERR") { text = error; error = "" }
        else if command.contains("id -u") { text = identity }
        else if command.contains("sha1sum") { if installed { text = resources.sha1.keys.sorted().map { "\(resources.sha1[$0]!)  \(SC3RFClient.remote)/\($0)\n" }.joined() } }
        else if command.contains("RAM_READY") { text = "RAM_READY\n" }
        else if command.contains("--self-test") { text = "SC3 QCA RSSI codec self-test passed\n" }
        else if command.contains("apply-changes") {
            writes += 1; changed = !ignoreWrite
            if timeoutWrite { throw SC3RFError("Simulated write timeout; result unknown.") }
            text = "Saved. Backup: /fixture/original\n"
        } else if command.contains("preview-changes") {
            if refusePreview { error = "Active INI changed since app preview\n"; status = 1 }
            else { text = "Base INI SHA-1: \(try SC3RFSelfTest.settings().hash)\n--- saved\n+++ pending\n+gTxPowerCap=20\nPreview only; no INI setting saved, radio reload or reboot performed.\n" }
        } else if command.contains(" settings") {
            if failReadback { throw SC3RFError("Readback unavailable") }
            let ini = changed ? SC3RFSelfTest.ini.replacingOccurrences(of: "END", with: "gTxPowerCap=20\nEND") : SC3RFSelfTest.ini
            text = String(data: try SC3RFSelfTest.json(ini: ini, saved: changed ? [.cap: "20", .sar2: "10", .sar5: "10"] : [.sar2: "10", .sar5: "10"]), encoding: .utf8)!
        } else if command.contains("cat /lib/firmware/wlan/qcom_cfg.ini") { text = changed ? SC3RFSelfTest.ini.replacingOccurrences(of: "END", with: "gTxPowerCap=20\nEND") : SC3RFSelfTest.ini }
        else { throw SC3RFError("Unexpected fixture shell: " + command) }
        return .init(stdout: text + "\n\(marker)=\(status)\n", stderr: "")
    }
}
