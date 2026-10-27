import Foundation
import CryptoKit
import Darwin

struct SC3RFResources {
    static let pins = ["parrot_sc3_rf_lab.sh": "8625c5fb49099da61ece7abd1b1bb4436e1904774d742604b62f18d125968e21",
                       "sc3-qca-rssi": "bf03655041c586e2e5bc31bdeccbb71ca2da9d3b0cbd42cee30ba186be8e3684"]
    let directory: URL
    let sha1: [String: String]
    init(directory: URL? = nil) throws {
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/SC3RFLab")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("DeviceTools/SC3RFLab")
        if directory == nil, Bundle.main.bundleURL.pathExtension == "app",
           bundled.map({ FileManager.default.fileExists(atPath: $0.path) }) != true { throw SC3RFError("The bundled SC3 RF Lab package is missing; reinstall the app.") }
        self.directory = directory ?? (bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? development)
        var sha1: [String: String] = [:]
        for (name, pin) in Self.pins {
            let url = self.directory.appendingPathComponent(name)
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 65_536 else { throw SC3RFError("Oversized RF Lab resource.") }
            let data = try Data(contentsOf: url)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == pin else { throw SC3RFError("RF Lab resource checksum mismatch: \(name)") }
            sha1[name] = SC3RFSettings.digest(data)
        }
        self.sha1 = sha1
    }
}

struct SC3RFCommandOutput { let stdout: String; let stderr: String }
protocol SC3RFExecuting: AnyObject {
    func run(_ arguments: [String], timeout: TimeInterval) throws -> SC3RFCommandOutput
    func cancel()
}

/// Exact selected transport, absolute executable, bounded non-TTY capture.
/// Numeric loopback -H prevents ADB's local daemon auto-start path. Check the
/// existing protocol version before every CLI invocation to avoid replacement.
final class SC3RFADBExecutor: SC3RFExecuting {
    let executable: String, port: UInt16, serial: String
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    init(executable: String, port: UInt16, serial: String) throws {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable),
              serial.hasSuffix(":9050"), SC3SumoRelay.isValidHost(String(serial.dropLast(5))), port > 0 else {
            throw SC3RFError("Choose an absolute ADB executable, server port and explicit SC3 IPv4:9050 transport.")
        }
        self.executable = executable; self.port = port; self.serial = serial
    }
    func cancel() { lock.withLock { cancelled = true; if process?.isRunning == true { process?.terminate() } } }
    private func check() throws { if lock.withLock({ cancelled }) { throw SC3RFError("RF Lab operation cancelled; no write is retried.") } }
    func validateClient() throws {
        let output = try launch(["version"], timeout: 3)
        guard output.stdout.hasPrefix("Android Debug Bridge version 1.0.41\n") else { throw SC3RFError("Select an ADB protocol 41 client; the existing server will not be replaced.") }
    }
    func run(_ arguments: [String], timeout: TimeInterval) throws -> SC3RFCommandOutput {
        try check()
        let server = try SC3ADBSocket(port: port); defer { server.close() }
        try server.service("host:version")
        guard try server.lengthString() == "0029" else { throw SC3RFError("Existing ADB server protocol differs; refusing to replace it.") }
        return try launch(["-H", "127.0.0.1", "-P", String(port), "-s", serial] + arguments, timeout: timeout)
    }
    static func devices(port: UInt16) throws -> [String] {
        // Read-only discovery never connects, selects the first device, or
        // invokes CLI daemon management. Selection remains an explicit UI act.
        let server = try SC3ADBSocket(port: port); defer { server.close() }
        try server.service("host:devices")
        return try server.lengthString().split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t")
            guard fields.count == 2, fields[1] == "device", fields[0].hasSuffix(":9050"),
                  SC3SumoRelay.isValidHost(String(fields[0].dropLast(5))) else { return nil }
            return String(fields[0])
        }
    }
    private func launch(_ arguments: [String], timeout: TimeInterval) throws -> SC3RFCommandOutput {
        try check()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parrotlab-rf-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = directory.appendingPathComponent("stdout"), err = directory.appendingPathComponent("stderr")
        for file in [out, err] { _ = FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        task.standardOutput = stdout; task.standardError = stderr; task.standardInput = FileHandle.nullDevice
        // Do not inherit ANDROID_SERIAL, ADB_SERVER_SOCKET or arbitrary tool hooks.
        task.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "NO_COLOR": "1"]
        try lock.withLock { guard !cancelled else { throw SC3RFError("Cancelled.") }; try task.run(); process = task }
        defer {
            if task.isRunning { kill(task.processIdentifier, SIGKILL); task.waitUntilExit() }
            lock.withLock { if process === task { process = nil } }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var limit = false
        while task.isRunning, ProcessInfo.processInfo.systemUptime < deadline, !lock.withLock({ cancelled }) {
            let sizes = try [out, err].map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max }
            if sizes[0] > 524_288 || sizes[1] > 65_536 { limit = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if task.isRunning {
            task.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.3
            while task.isRunning, ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
            throw SC3RFError(limit ? "RF Lab output exceeded its bound." : "RF Lab timed out or disconnected. The result is unknown; reread settings before any further save.")
        }
        try check()
        let outputFile = try FileHandle(forReadingFrom: out), errorFile = try FileHandle(forReadingFrom: err)
        defer { try? outputFile.close(); try? errorFile.close() }
        let output = try outputFile.read(upToCount: 524_289) ?? Data()
        let errors = try errorFile.read(upToCount: 65_537) ?? Data()
        guard output.count <= 524_288, errors.count <= 65_536,
              let text = String(data: output, encoding: .utf8), let errorText = String(data: errors, encoding: .utf8) else { throw SC3RFError("Invalid RF Lab output.") }
        guard task.terminationStatus == 0 else { throw SC3RFError(errorText.isEmpty ? "ADB failed; check the selected transport." : errorText) }
        return SC3RFCommandOutput(stdout: text, stderr: errorText)
    }
    static func processSelfTest() throws -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parrotlab-rf-executor-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture-adb")
        func script(_ text: String) throws {
            try Data(("#!/bin/sh\n" + text + "\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        try script("printf 'Android Debug Bridge version 1.0.41\\n'")
        let valid = try Self(executable: file.path, port: 5038, serial: "127.0.0.1:9050")
        try valid.validateClient() // version is local only: no ADB server or device.
        try script("exec /usr/bin/head -c 600000 /dev/zero")
        do { try valid.validateClient(); return false } catch {}
        try script("exec /bin/sleep 5")
        let cancelled = try Self(executable: file.path, port: 5038, serial: "127.0.0.1:9050")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cancelled.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        do { try cancelled.validateClient(); return false } catch {}
        return ProcessInfo.processInfo.systemUptime - start < 1.5
    }
}

struct SC3RFSaveResult {
    let confirmed: Bool
    let message: String
    let settings: SC3RFSettings?
}

final class SC3RFClient {
    static let remote = "/tmp/parrot-sc3-rf-lab-0.2.0"
    let executor: SC3RFExecuting
    let resources: SC3RFResources
    init(executor: SC3RFExecuting, resources: SC3RFResources) { self.executor = executor; self.resources = resources }
    static func decode(_ output: String, marker: String) throws -> (text: String, status: Int) {
        // exec-out is non-TTY. Preserve INI bytes exactly for the digest; a
        // global CRLF normalization would corrupt a legitimate saved-file hash.
        let normalized = output
        guard let range = normalized.range(of: "\n\(marker)=", options: .backwards) else { throw SC3RFError("Missing remote status; result unknown. Reread settings.") }
        let tail = String(normalized[range.upperBound...])
        guard tail.hasSuffix("\n"), tail.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }),
              (1...3).contains(tail.count - 1), let status = Int(tail.dropLast()), (0...255).contains(status) else { throw SC3RFError("Malformed remote status; result unknown.") }
        return (String(normalized[..<range.lowerBound]), status)
    }
    func remote(_ command: String, timeout: TimeInterval = 15) throws -> String {
        let marker = "APP_SC3_RF_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let errors = "/tmp/.parrotlab-rf-" + UUID().uuidString + ".stderr"
        let quoted = SC3SumoVideoInstaller.quote(errors)
        let wrapped = "umask 077; ( \(command) ) 2>\(quoted); app_status=$?; printf '\\n\(marker)=%s\\n' \"$app_status\""
        let output = try executor.run(["exec-out", wrapped], timeout: timeout)
        let decoded = try Self.decode(output.stdout, marker: marker)
        // Legacy exec-out does not separate the remote stderr stream. Fetch
        // its private file independently; never feed it to the JSON decoder.
        let errorMarker = marker + "_ERR"
        let errorOutput = try executor.run(["exec-out", "cat \(quoted); app_status=$?; rm -f \(quoted); printf '\\n\(errorMarker)=%s\\n' \"$app_status\""], timeout: 5)
        let remoteError = try Self.decode(errorOutput.stdout, marker: errorMarker)
        guard remoteError.status == 0 else { throw SC3RFError("Remote diagnostics were unavailable; result unknown.") }
        guard decoded.status == 0 else {
            throw SC3RFError(remoteError.text.isEmpty ? "SC3 command failed (\(decoded.status)). \(decoded.text)" : remoteError.text)
        }
        return decoded.text
    }
    static func validateIdentity(_ text: String) throws {
        guard text == "0\nmpp3\n1.8.1\n" else { throw SC3RFError("Requires the explicitly selected, already-rooted SC3 mpp3 on firmware 1.8.1. Nothing uploaded.") }
    }
    func prepare() throws {
        try Self.validateIdentity(remote("id -u; gprop ro.hardware; gprop ro.parrot.build.version"))
        let path = Self.remote
        let expected = resources.sha1.keys.sorted().map { "\(resources.sha1[$0]!)  \(path)/\($0)\n" }.joined()
        let existing = try remote("if test ! -L \(path) && test -d \(path); then sha1sum \(path)/parrot_sc3_rf_lab.sh \(path)/sc3-qca-rssi 2>/dev/null || true; fi")
        if existing != expected {
            guard try remote("test ! -L \(path) && test ! -L \(path)/parrot_sc3_rf_lab.sh && test ! -L \(path)/sc3-qca-rssi && mkdir -p \(path) && chmod 700 \(path) && echo RAM_READY") == "RAM_READY\n" else { throw SC3RFError("RF Lab RAM directory unavailable.") }
            for name in resources.sha1.keys.sorted() {
                _ = try executor.run(["push", resources.directory.appendingPathComponent(name).path, path + "/" + name], timeout: 10)
            }
            let check = try remote("sha1sum \(path)/parrot_sc3_rf_lab.sh \(path)/sc3-qca-rssi")
            guard check == expected else { throw SC3RFError("Uploaded RF Lab checksum mismatch; tools will not run.") }
        }
        guard try remote("chmod 700 \(path)/sc3-qca-rssi && \(path)/sc3-qca-rssi --self-test") == "SC3 QCA RSSI codec self-test passed\n" else { throw SC3RFError("SC3 RSSI helper self-test failed.") }
    }
    private func tool(_ arguments: [String]) throws -> String {
        guard arguments.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }) }) else { throw SC3RFError("Invalid RF Lab argument token.") }
        return try remote("NO_COLOR=1 /bin/sh \(Self.remote)/parrot_sc3_rf_lab.sh " + arguments.joined(separator: " "))
    }
    func settings() throws -> SC3RFSettings {
        let json = try tool(["settings"])
        let ini = try remote("cat /lib/firmware/wlan/qcom_cfg.ini")
        return try SC3RFSettings(json: Data(json.utf8), ini: Data(ini.utf8))
    }
    func observe() throws -> SC3RFObservation {
        try prepare() // Reboot deletes RAM tools; revalidate identity before replacing them.
        let snapshot = try tool(["snapshot"])
        let counters = try remote("cat /proc/net/dev")
        let uptime = try remote("cat /proc/uptime")
        return SC3RFObservation(snapshot: snapshot, counters: counters, uptime: uptime)
    }
    static func validatePairs(_ pairs: [String], hash: String) throws {
        guard SC3RFSettings.isHash(hash), !pairs.isEmpty, pairs.count <= 10, pairs.count % 2 == 0 else { throw SC3RFError("Invalid RF Lab change set.") }
        var keys = Set<SC3RFKey>()
        for index in stride(from: 0, to: pairs.count, by: 2) {
            guard let key = SC3RFKey(rawValue: pairs[index]), keys.insert(key).inserted,
                  try key.validate(pairs[index + 1]) == pairs[index + 1] else { throw SC3RFError("Invalid or repeated RF Lab setting.") }
        }
    }
    func preview(hash: String, pairs: [String]) throws -> String {
        try Self.validatePairs(pairs, hash: hash); try prepare()
        return try tool(["preview-changes", "--expect", hash] + pairs)
    }
    func apply(_ preview: SC3RFPreview, approval: String) throws -> SC3RFSaveResult {
        guard approval == "APPLY" else { throw SC3RFError("Save requires typing APPLY after reviewing the diff.") }
        try Self.validatePairs(preview.pairs, hash: preview.hash)
        try prepare()
        var confirmed = false, message = ""
        do {
            let output = try tool(["apply-changes", "--expect", preview.hash] + preview.pairs + ["--confirm", approval])
            guard output.contains("Saved. Backup: ") || output.contains("Nothing to apply.") else { throw SC3RFError("Save completion was not confirmed.") }
            confirmed = true; message = "Saved; activation not verified. No reboot or radio reload was performed."
        } catch { message = "Save not confirmed: \(error.localizedDescription) No automatic retry." }
        // Also reconcile after remote nonzero, missing trailer or timeout. Never
        // retry the write, and never equate a changed saved file with RF output.
        let refreshed: SC3RFSettings?
        do { refreshed = try settings() }
        catch {
            refreshed = nil
            if confirmed { message = "Save command reported success; saved-file verification is unavailable." }
            confirmed = false
            message += " Settings reread failed: \(error.localizedDescription) Reconnect and review before saving again."
        }
        if confirmed, let refreshed {
            let matches = stride(from: 0, to: preview.pairs.count, by: 2).allSatisfy { index in
                guard let key = SC3RFKey(rawValue: preview.pairs[index]) else { return false }
                let value = preview.pairs[index + 1]
                return value == "unset" ? refreshed.rows[key]?.source == "unset" : refreshed.rows[key]?.saved == value
            }
            if !matches || refreshed.fileIssue != nil { confirmed = false; message = "Save readback differs from the reviewed changes. Review the fresh settings; no automatic retry." }
        }
        return SC3RFSaveResult(confirmed: confirmed, message: message, settings: refreshed)
    }
}
