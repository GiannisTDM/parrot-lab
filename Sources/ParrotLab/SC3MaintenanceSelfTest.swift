import AppKit

enum SC3MaintenanceSelfTest {
    static func event(_ name: String, _ fields: [String: Any] = [:]) throws -> SC3MaintenanceEvent {
        var object = fields; object["api"] = 1; object["event"] = name
        return try SC3MaintenanceEvent(JSONSerialization.data(withJSONObject: object))
    }
    private static func rejects(_ block: () throws -> Void) -> Bool { do { try block(); return false } catch { return true } }
    private static func expect(_ result: Bool, _ reason: String) throws { if !result { throw SC3RFError("Maintenance self-test: " + reason) } }
    private static func spin(_ condition: () -> Bool, seconds: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }
    static func run() -> Bool {
        do {
            let resources = try SC3MaintenanceResources()
            try expect(SC3MaintenanceWindow.automaticIdentitySelfTest(), "automatic identity UI and separate-controller reset")
            var config = SC3MaintenanceConfiguration()
            let session = URL(fileURLWithPath: "/private/session with spaces")
            let args = try config.arguments(.install, session: nil, consent: true)
            try expect(args.contains("--confirm-write") && args.contains("--sumo-off") && !args.contains("reboot"), "install is explicit and separate from restart")
            try expect(rejects { _ = try config.arguments(.enable, session: session, consent: false) }, "every critical phase needs consent")
            try expect(try config.arguments(.snapshot, session: session, consent: true).contains(session.path), "spaces remain one argv element")
            for operation in [SC3MaintenanceOperation.prepare, .fastboot, .verify] {
                let arguments = try config.arguments(operation, session: session, consent: false)
                try expect(!arguments.contains("--stock-serial") && !arguments.contains("--fastboot-serial") && !arguments.contains("--experimental-device"), "no manual identity or spare-only flags")
            }
            config.stockSerial = "a;reboot"
            try expect(rejects { try config.validate(for: .prepare) }, "serial injection")
            config.stockSerial = "OTHER"; config.fastbootSerial = "OTHERFAST"
            try config.validate(for: .prepare)
            try expect(try config.arguments(.prepare, session: session, consent: false).contains("OTHERFAST"), "any detected matching controller accepted")
            config.endpoint = "host:9050"
            try expect(rejects { try config.validate(for: .verify) }, "numeric explicit endpoint")
            var wizard = SC3RootWizardState()
            wizard.finished(.runtime)
            for operation in [SC3MaintenanceOperation.prepare, .fastboot, .boot, .snapshot, .inspect, .enable, .reboot, .verify] {
                try expect(wizard.next == operation, "root phase order")
                wizard.finished(operation)
            }
            try expect(wizard.debugVerified && !wizard.rootVerified && wizard.next == nil, "web check completes setup without claiming ADB UID0")
            wizard.finished(.verifyADB)
            try expect(wizard.rootVerified, "optional ADB proof is separate")
            wizard.stop(); try expect(wizard.next == nil && !wizard.rootVerified, "unknown state cannot replay RAM/storage")
            var outOfOrder = SC3RootWizardState(); outOfOrder.finished(.enable)
            try expect(outOfOrder.phase == .checkpoint, "out-of-order write stops wizard")
            var checks = SC3RootWizardState(); checks.runtimeReady = true; checks.session = session
            try expect(checks.failed(.prepare) && checks.phase == .initial && checks.next == .prepare && checks.session == nil,
                       "HTTP identity failure allows a fresh explicit check without replaying mutations")
            checks.session = session; checks.finished(.prepare)
            try expect(checks.failed(.fastboot) && checks.phase == .manualFastboot && checks.next == .fastboot && checks.session == session,
                       "missing/ambiguous fastboot detection remains at the read-only step")
            try expect(checks.failed(.runtime) && !checks.runtimeReady && checks.phase == .manualFastboot,
                       "runtime failure preserves the phase and requires another runtime check")
            checks.finished(.fastboot)
            try expect(!checks.failed(.boot) && checks.phase == .checkpoint && checks.next == nil,
                       "a RAM boot failure still cannot be replayed")
            _ = checks.failed(.runtime); checks.finished(.runtime)
            try expect(checks.phase == .checkpoint && checks.next == nil,
                       "rechecking runtimes cannot revive an unknown mutation")
            var web = SC3MaintenanceTranscript(operation: .verify)
            try web.accept(event("started", ["operation": "verify-root"]))
            let webFields: [String: Any] = ["stock_serial": "OTHER", "firmware": "1.8.1", "hardware": "3", "model": "Skycontroller 3", "rw_debuggable": "1", "persist_debuggable": NSNull(), "transport": "HTTP properties", "adb_verified": false]
            var disabledWeb = webFields; disabledWeb["rw_debuggable"] = "0"
            try expect(rejects { try web.accept(event("debug_verified", disabledWeb)) }, "web runtime flag must be enabled")
            var fabricatedADB = webFields; fabricatedADB["adb_verified"] = true
            try expect(rejects { try web.accept(event("debug_verified", fabricatedADB)) }, "web result cannot claim ADB proof")
            try web.accept(event("debug_verified", webFields))
            try web.accept(event("completed", ["operation": "verify-root"])); try web.validateExit(0)
            var transcript = SC3MaintenanceTranscript(operation: .verifyADB)
            try expect(rejects { try transcript.accept(event("root_verified", ["uid": 0, "firmware": "1.8.1", "stock_serial": "OTHER"])) }, "no unsolicited success")
            try transcript.accept(event("started", ["operation": "verify-root-adb"]))
            try expect(rejects { try transcript.accept(event("root_verified", ["uid": 2000, "firmware": "1.8.1", "stock_serial": "OTHER"])) }, "non-root cannot verify")
            try expect(rejects { try transcript.accept(event("root_verified", ["uid": 0, "firmware": "1.8.1"])) }, "detected identity must be present")
            try transcript.accept(event("root_verified", ["uid": 0, "firmware": "1.8.1", "stock_serial": "OTHER"]))
            try expect(rejects { try transcript.validateExit(0) }, "local exit0 is insufficient")
            try transcript.accept(event("completed", ["operation": "verify-root-adb"]))
            try transcript.validateExit(0)
            try expect(rejects { try transcript.accept(event("progress")) }, "no late events after completion")
            for (firmware, hardware, model) in [("1.8.2", "3", "Skycontroller 3"), ("1.7.0", "3", "Skycontroller 3"), ("1.8.1", "2", "Skycontroller 3"), ("1.8.1", "3", "Skycontroller 2")] {
                var t = SC3MaintenanceTranscript(operation: .prepare)
                try t.accept(event("started", ["operation": "prepare-root"]))
                try expect(rejects { try t.accept(event("prepared", ["firmware": firmware, "hardware": hardware, "model": model])) }, "wrong device/version stops")
            }
            try expect(rejects { _ = try SC3MaintenanceEvent(Data("{\"api\":true,\"event\":\"completed\"}".utf8)) }, "boolean is not API version1")
            try expect(rejects { _ = try SC3MaintenanceEvent(Data("{\"api\":1.5,\"event\":\"completed\"}".utf8)) }, "fractional API version refused")
            for (version, zone) in [([3, 8, 20], "Europe/Athens"), ([3, 12, 0], "missing")] {
                var t = SC3MaintenanceTranscript(operation: .runtime)
                try t.accept(event("started", ["operation": "runtime-check"]))
                try expect(rejects { try t.accept(event("runtime_ready", ["python": version, "zone": zone])) }, "runtime/zoneinfo requirements enforced")
            }
            var reboot = SC3MaintenanceTranscript(operation: .reboot)
            try reboot.accept(event("started", ["operation": "return-stock"]))
            try reboot.accept(event("reboot_ack_unknown"))
            try reboot.accept(event("completed", ["operation": "return-stock"]))
            try reboot.validateExit(0)
            try expect(reboot.events.contains { $0.name == "reboot_ack_unknown" }, "unknown acknowledgement remains explicit")
            for (operation, startup, restart) in [(SC3MaintenanceOperation.install, true, false), (.futureOn, true, false), (.futureOff, false, false), (.activate, true, true), (.stock, false, true), (.remove, false, true)] {
                var t = SC3MaintenanceTranscript(operation: operation)
                try t.accept(event("started", ["operation": operation.rawValue]))
                try t.accept(event("sumo_contract", ["compatible": true]))
                try t.accept(event("sumo_complete", ["action": String(operation.rawValue.dropFirst(5)), "automatic_startup": operation == .activate ? NSNull() : startup as Any, "daemon_restart_possible": restart, "reboot_requested": false, "movement_packets_sent": false]))
                try expect(rejects { try t.accept(event("completed", ["operation": "wrong"])) }, "operation mismatch")
                try t.accept(event("sumo_status", ["variant": "stock", "executable_sha1": "52398949fe32b46b0251b2c7f63942593c068d62", "service": "stopped", "startup_enabled": startup]))
                try t.accept(event("completed", ["operation": operation.rawValue])); try t.validateExit(0)
                try expect(t.events.first(where: { $0.name == "sumo_complete" })?.fields["daemon_restart_possible"] as? Bool == restart, "startup/restart semantics remain distinct")
            }
            let coordinator = SC3MaintenanceCoordinator()
            guard let lease = coordinator.acquire("fixture", critical: true) else { return false }
            try expect(coordinator.acquire("second", critical: false) == nil && coordinator.critical, "maintenance serialized")
            coordinator.release(UUID()); try expect(coordinator.busy, "stale callback cannot release new lease")
            coordinator.release(lease); try expect(!coordinator.busy, "lease releases once")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maintenance fixture " + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let evidence = directory.appendingPathComponent("receipt.json")
            try Data("{}".utf8).write(to: evidence); _ = try SC3MaintenancePrivateJSON.read(evidence)
            try Data(repeating: 32, count: 40_000).write(to: evidence)
            try expect(rejects { _ = try SC3MaintenancePrivateJSON.read(evidence) }, "bounded private metadata reads")
            let executable = directory.appendingPathComponent("fake python with spaces")
            func script(_ body: String) throws {
                try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }
            var fixture = SC3MaintenanceConfiguration(python: executable.path, adb: "/usr/bin/true", fastboot: "/usr/bin/true", stockSerial: "PI040443CA0A194914", fastbootSerial: "17d9849f")
            let runner = SC3MaintenanceProcess()
            var result: Result<SC3MaintenanceTranscript, Error>?, warnings = 0
            func launch(_ operation: SC3MaintenanceOperation) throws {
                result = nil
                try expect(runner.start(operation, config: fixture, session: nil, consent: operation.critical, resources: resources, event: { _ in }, warning: { _ in warnings += 1 }, completion: { result = $0 }), "single owned process")
            }
            try script("printf '%s\\n' '{\"api\":1,\"event\":\"started\",\"operation\":\"runtime-check\"}' '{\"api\":1,\"event\":\"runtime_ready\",\"python\":[3,9,0],\"zone\":\"Europe/Athens\"}' '{\"api\":1,\"event\":\"completed\",\"operation\":\"runtime-check\"}'")
            try launch(.runtime); try expect(spin({ result != nil }), "async JSONL completion")
            if case .failure(let error) = result { throw error }
            try script("printf bad-json; exec /bin/sleep 0.15")
            try launch(.runtime); try expect(spin({ result != nil }), "truncated JSON failure")
            if case .success = result { throw SC3RFError("Truncated JSON accepted") }
            try script("exec /bin/sleep 5")
            try launch(.runtime); runner.triggerDeadlineForSelfTest()
            try expect(spin({ result != nil }) && warnings > 0, "bounded read-only timeout/cancellation")
            let survived = directory.appendingPathComponent("critical-finished")
            try script("/bin/sleep 0.15\n/usr/bin/touch '\(survived.path)'\n")
            try launch(.enable); runner.cancelReadOnly(); runner.triggerDeadlineForSelfTest()
            try expect(spin({ result != nil }) && FileManager.default.fileExists(atPath: survived.path), "critical timeout/cancel never kills storage host work")
            fixture.python = directory.appendingPathComponent("missing runtime").path
            try launch(.runtime); try expect(spin({ result != nil }), "missing runtime completes with error")
            if case .success = result { throw SC3RFError("Missing runtime accepted") }
            fixture.python = executable.path
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
            try launch(.runtime); try expect(spin({ result != nil }), "runtime permissions are checked")
            if case .success = result { throw SC3RFError("Non-executable runtime accepted") }
            print("SC3 maintenance JSONL, phases, identity, consent, serialization, timeout and process tests passed (host fixtures only)")
            return true
        } catch { fputs("\(error.localizedDescription)\n", stderr); return false }
    }
}
