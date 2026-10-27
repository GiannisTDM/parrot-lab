import Foundation
import CryptoKit
import CoreFoundation

enum SC3MaintenanceOperation: String, CaseIterable {
    case runtime = "runtime-check", bundle = "verify-bundle", prepare = "prepare-root", fastboot = "wait-fastboot"
    case boot = "boot-root", snapshot = "snapshot-root", inspect = "inspect-root", enable = "enable-root"
    case reboot = "return-stock", verify = "verify-root", disable = "disable-root", status = "sumo-status"
    case verifyADB = "verify-root-adb"
    case install = "sumo-install", futureOn = "sumo-enable", futureOff = "sumo-disable"
    case activate = "sumo-activate", stock = "sumo-stock", remove = "sumo-remove-hook"
    var critical: Bool { ![.runtime, .bundle, .prepare, .fastboot, .verify, .verifyADB, .status].contains(self) }
    var sumo: Bool { rawValue.hasPrefix("sumo-") }
    var deadline: TimeInterval { self == .snapshot ? 600 : self == .boot ? 150 : critical ? 300 : 90 }
    var terminal: String {
        switch self {
        case .runtime: return "runtime_ready"
        case .bundle: return "bundle_verified"
        case .prepare: return "prepared"
        case .fastboot: return "fastboot_ready"
        case .boot: return "ram_ready"
        case .snapshot, .inspect, .enable: return "phase_complete"
        case .reboot: return "reboot_requested"
        case .verify: return "debug_verified"
        case .verifyADB: return "root_verified"
        case .disable: return "root_disabled"
        case .status: return "sumo_status"
        default: return "sumo_complete"
        }
    }
    var explanation: String {
        switch self {
        case .prepare: return "All vehicles must be OFF. Keep only the same SC3 connected throughout normal and fastboot modes. Read its normal USB/network identity and create a new private session. Any SC3 1.8.1 / hardware 3 is accepted; serials are detected automatically. Physical validation of the root mechanism currently covers one controller."
        case .boot: return "All vehicles OFF. Boot the exact proven V5 into RAM once; no original boot/system/recovery image is flashed. V5 intentionally panics after about 90 seconds unless the tool creates its keep marker after verifying RAM root and identity; the panic requests a later reboot. Failure means STOP, never an automatic RAM-boot retry."
        case .snapshot: return "Read the data partition twice into this private session (about268 MB total); allow at least512 MiB free. These ECC-corrected main-area files are NOT a full NAND/OOB backup or tested whole-chip recovery. Do not interrupt a kernel data read."
        case .inspect: return "Attach only the data MTD as UBI, mount data read-only and archive its properties privately. UBI attachment can write housekeeping metadata. This is a separate storage consent."
        case .enable: return "Enable GLOBAL stock debug consumers and root TCP ADB on port9050 by creating only the proven absent property, with verification and clean unmount/detach. This is not just an app permission or native USB ADB interface. Use trusted/isolated links. Unofficial, not reset/update-proof and not a whole-chip recovery method."
        case .reboot: return "Request exactly ONE return to stock boot after clean storage teardown. A lost acknowledgement is unknown: wait for USB networking and verify, never resend reboot."
        case .disable: return "Remove only this session's matching absent→1 debug-property creation. Original absence provenance is mandatory. Existing ADB/debug consumers are not automatically stopped and no reboot is sent. Old installations without this tool's provenance cannot be force-removed."
        case .install: return "Sumo must be OFF. Install exact v1c, verified stock/init backups and its single startup hook; enable future loading. This persistently changes the init selector, but does NOT restart or reboot. No pairing, mapping, RF or robot commands. Unknown/newer v2/video setups are refused."
        case .futureOn: return "Sumo must be OFF. Enable future v1c loading only; the current session is unchanged."
        case .futureOff: return "Sumo must be OFF. Disable future v1c loading only; the current session is unchanged."
        case .activate: return "Sumo must be OFF. Activate the current-boot v1c overlay through the existing supervisor. Native mppd can associate with remembered peers. No drive/jump packet is injected. Video and mappings are separate features."
        case .stock: return "Sumo must be OFF. Disable future native loading and restore stock now. Restart only when required by an active overlay; an already-stock deliberately stopped service stays stopped. Backups and hook remain."
        case .remove: return "Sumo must be OFF. Restore stock now and the original init definition. Retain backups and unused selector because running init can cache its old command. No automatic reboot."
        default: return "Read-only verification. No enablement, reinstall, reboot or automatic mutation retry."
        }
    }
}

struct SC3MaintenanceConfiguration: Equatable {
    var python = "/opt/homebrew/bin/python3", adb = "/opt/homebrew/bin/adb", fastboot = "/opt/homebrew/bin/fastboot"
    var port = 5038, endpoint = "192.168.53.1:9050", stockSerial = "", fastbootSerial = ""
    func validate(for operation: SC3MaintenanceOperation) throws {
        guard [python, adb, fastboot].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
              (1024...65535).contains(port), endpoint.hasSuffix(":9050"), SC3SumoRelay.isValidHost(String(endpoint.dropLast(5))) else { throw SC3RFError("Choose absolute Python/platform-tools paths, the existing server port, and an explicit IPv4:9050 endpoint.") }
        func serial(_ value: String) -> Bool { (1...64).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isNumber || $0.isLetter) } }
        if !stockSerial.isEmpty, !serial(stockSerial) { throw SC3RFError("Invalid detected controller identity.") }
        if !fastbootSerial.isEmpty, !serial(fastbootSerial) { throw SC3RFError("Invalid detected fastboot identity.") }
    }
    func arguments(_ operation: SC3MaintenanceOperation, session: URL?, consent: Bool) throws -> [String] {
        try validate(for: operation)
        guard !operation.critical || consent else { throw SC3RFError("Explicit phase consent is required.") }
        var result = [operation.rawValue, "--adb", adb, "--fastboot", fastboot, "--adb-port", String(port), "--endpoint", endpoint]
        if !stockSerial.isEmpty { result += ["--stock-serial", stockSerial] }
        if !fastbootSerial.isEmpty { result += ["--fastboot-serial", fastbootSerial] }
        if let session { result += ["--session", session.path] }
        if operation.critical { result += ["--confirm-write"]; if operation.sumo { result += ["--sumo-off"] } }
        return result
    }
}

struct SC3MaintenanceEvent {
    let name: String
    let fields: [String: Any]
    init(_ line: Data) throws {
        guard line.count <= 65_536, let value = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let api = value["api"] as? NSNumber, CFGetTypeID(api) != CFBooleanGetTypeID(), api.doubleValue == 1, let name = value["event"] as? String,
              ["started", "prepared", "progress", "ram_ready", "phase_complete", "reboot_requested", "reboot_ack_unknown", "root_verified", "debug_verified", "root_disabled", "sumo_status", "sumo_complete", "sumo_contract", "bundle_verified", "completed", "error", "runtime_ready", "fastboot_ready"].contains(name) else { throw SC3RFError("Invalid maintenance JSON event; STOP.") }
        self.name = name; fields = value
    }
}

struct SC3MaintenanceTranscript {
    let operation: SC3MaintenanceOperation
    private(set) var started = false, completed = false, stopped = false
    private(set) var terminal = false, contract: Bool?, events: [SC3MaintenanceEvent] = []
    mutating func accept(_ event: SC3MaintenanceEvent) throws {
        guard !completed, !stopped else { throw SC3RFError("Event after final maintenance result; STOP.") }
        if event.name == "error" { stopped = true; events.append(event); return }
        if event.name == "started" {
            guard !started, event.fields["operation"] as? String == operation.rawValue else { throw SC3RFError("Maintenance operation/generation mismatch.") }; started = true
        } else {
            guard started else { throw SC3RFError("Maintenance event before started.") }
            if event.name == "completed" {
                guard terminal, event.fields["operation"] as? String == operation.rawValue else { throw SC3RFError("Incomplete or mismatched maintenance result.") }; completed = true
            } else if event.name == "sumo_status", operation.sumo {
                guard let variant = event.fields["variant"] as? String, ["stock", "native-sumo-v1c", "unknown"].contains(variant),
                      let sha = event.fields["executable_sha1"] as? String, SC3RFSettings.isHash(sha),
                      let service = event.fields["service"] as? String, !service.isEmpty, service.count <= 64,
                      let flag = event.fields["startup_enabled"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw SC3RFError("Native status fields missing; no state is inferred.") }
                if operation == .status { terminal = true }
            } else if event.name == "sumo_contract" {
                guard operation.sumo, let compatible = event.fields["compatible"] as? Bool else { throw SC3RFError("Missing v1c contract result.") }; contract = compatible
            } else if event.name == operation.terminal || (operation == .reboot && event.name == "reboot_ack_unknown") {
                if operation == .runtime {
                    guard let version = event.fields["python"] as? [Int], version.count == 3,
                          version[0] > 3 || (version[0] == 3 && version[1] >= 9), event.fields["zone"] as? String == "Europe/Athens" else { throw SC3RFError("Python3.9+ and Europe/Athens zoneinfo are required.") }
                }
                if operation == .prepare {
                    guard event.fields["firmware"] as? String == "1.8.1", event.fields["hardware"] as? String == "3", event.fields["model"] as? String == "Skycontroller 3" else { throw SC3RFError("Wrong prepared device/version.") }
                }
                if [.prepare, .verify, .verifyADB, .fastboot].contains(operation) {
                    let key = operation == .fastboot ? "serial" : "stock_serial"
                    guard let serial = event.fields[key] as? String, (1...64).contains(serial.count),
                          serial.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw SC3RFError("Missing detected controller identity.") }
                }
                if operation == .verify {
                    guard event.fields["rw_debuggable"] as? String == "1",
                          (event.fields["persist_debuggable"] is NSNull || event.fields["persist_debuggable"] as? String == "1"),
                          let adb = event.fields["adb_verified"] as? NSNumber, CFGetTypeID(adb) == CFBooleanGetTypeID(), !adb.boolValue,
                          event.fields["transport"] as? String == "HTTP properties", event.fields["firmware"] as? String == "1.8.1",
                          event.fields["hardware"] as? String == "3", event.fields["model"] as? String == "Skycontroller 3" else { throw SC3RFError("Web API did not confirm debug enablement.") }
                }
                if operation == .verifyADB {
                    guard let uid = event.fields["uid"] as? NSNumber, CFGetTypeID(uid) != CFBooleanGetTypeID(), uid.doubleValue == 0, event.fields["firmware"] as? String == "1.8.1" else { throw SC3RFError("Stock root verification failed.") }
                }
                if [.snapshot, .inspect, .enable].contains(operation), event.fields["phase"] as? String != operation.rawValue { throw SC3RFError("Storage phase mismatch.") }
                if operation.sumo && operation != .status {
                    let startup = event.fields["automatic_startup"] as? Bool
                    let expectedStartup: Bool? = [.install, .futureOn].contains(operation) ? true : operation == .activate ? nil : false
                    guard event.fields["action"] as? String == String(operation.rawValue.dropFirst(5)),
                          event.fields["movement_packets_sent"] as? Bool == false, event.fields["reboot_requested"] as? Bool == false,
                          startup == expectedStartup, (operation != .activate || event.fields["automatic_startup"] is NSNull),
                          event.fields["daemon_restart_possible"] as? Bool == [.activate, .stock, .remove].contains(operation) else { throw SC3RFError("Unexpected native-mod result.") }
                }
                terminal = true
            } else if event.name != "progress" { throw SC3RFError("Unexpected event for this maintenance phase.") }
        }
        events.append(event)
    }
    func validateExit(_ status: Int32) throws {
        guard status == 0, started, completed, terminal, !stopped,
              !operation.sumo || (contract == true && events.contains(where: { $0.name == "sumo_status" })) else { throw SC3RFError(events.last(where: { $0.name == "error" })?.fields["message"] as? String ?? "STOP / unknown outcome. Preserve evidence; no mutation is retried.") }
    }
}

struct SC3RootWizardState {
    enum Phase { case initial, manualFastboot, readyBoot, ramRoot, snapshots, inspected, enabled, awaitStock, verified, checkpoint }
    private(set) var phase = Phase.initial
    var session: URL?
    var runtimeReady = false, debugVerified = false, rootVerified = false
    var next: SC3MaintenanceOperation? {
        switch phase {
        case .initial: return .prepare
        case .manualFastboot: return .fastboot
        case .readyBoot: return .boot
        case .ramRoot: return .snapshot
        case .snapshots: return .inspect
        case .inspected: return .enable
        case .enabled: return .reboot
        case .awaitStock: return .verify
        case .verified, .checkpoint: return nil
        }
    }
    mutating func stop() { phase = .checkpoint; debugVerified = false; rootVerified = false }
    /// Local/runtime and pre-boot read failures can be repeated explicitly.
    /// A mutation failure still retires the workflow into an unknown checkpoint.
    @discardableResult
    mutating func failed(_ operation: SC3MaintenanceOperation) -> Bool {
        if operation == .runtime {
            runtimeReady = false; debugVerified = false; rootVerified = false; return true
        }
        if operation == .prepare, phase == .initial { session = nil; return true }
        if operation == .fastboot, phase == .manualFastboot { return true }
        stop(); return false
    }
    mutating func resumeCheckpoint(_ session: URL) { self.session = session; stop() }
    mutating func finished(_ operation: SC3MaintenanceOperation) {
        if [.prepare, .fastboot, .boot, .snapshot, .inspect, .enable, .reboot].contains(operation), next != operation { stop(); return }
        switch operation {
        case .runtime: runtimeReady = true
        case .prepare: phase = .manualFastboot
        case .fastboot: phase = .readyBoot
        case .boot: phase = .ramRoot
        case .snapshot: phase = .snapshots
        case .inspect: phase = .inspected
        case .enable: phase = .enabled
        case .reboot: phase = .awaitStock
        case .verify: phase = .verified; debugVerified = true; rootVerified = false
        case .verifyADB: phase = .verified; debugVerified = true; rootVerified = true
        case .disable: stop()
        default: break
        }
    }
}

/// Shared lease covers RF polling/saves, video installation and this wizard.
/// A retired callback can only release its own identity.
final class SC3MaintenanceCoordinator {
    static let shared = SC3MaintenanceCoordinator()
    private let lock = NSLock()
    private var lease: (UUID, String, Bool)?
    var busy: Bool { lock.withLock { lease != nil } }
    var critical: Bool { lock.withLock { lease?.2 == true } }
    func acquire(_ owner: String, critical: Bool) -> UUID? {
        lock.withLock { guard lease == nil else { return nil }; let id = UUID(); lease = (id, owner, critical); return id }
    }
    func release(_ id: UUID) { lock.withLock { if lease?.0 == id { lease = nil } } }
}

struct SC3MaintenanceResources {
    static let manifestHash = "f732b9b5b94df921c3c6c5623845b390e35a0125177cfa8cfc5afeeb06d16e76"
    static let entryHash = "5326cbef5bd0cd9b47dbca0c83c1f46ba8c15399aa651af63f757d1981247e78"
    let directory: URL
    init(directory: URL? = nil) throws {
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/SC3Maintenance")
        let bundle = Bundle.main.resourceURL?.appendingPathComponent("DeviceTools/SC3Maintenance")
        self.directory = directory ?? (Bundle.main.bundleURL.pathExtension == "app" ? bundle! : dev)
        let entry = try Data(contentsOf: self.directory.appendingPathComponent("entry.py"))
        guard SHA256.hash(data: entry).map({ String(format: "%02x", $0) }).joined() == Self.entryHash else { throw SC3RFError("Signed maintenance adapter differs; reinstall the app.") }
        let tools = self.directory.appendingPathComponent("tools"), manifest = tools.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifest)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Self.manifestHash,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let files = object["files"] as? [String: [String: Any]], files.count == 10 else { throw SC3RFError("Pinned maintenance manifest differs; reinstall the signed app.") }
        for (name, row) in files {
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), let size = row["bytes"] as? Int, (1...9_000_000).contains(size) else { throw SC3RFError("Invalid maintenance resource path/size.") }
            let file = tools.appendingPathComponent(name)
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]).isSymbolicLink != true,
                  try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == size else { throw SC3RFError("Maintenance resource missing or changed.") }
            let bytes = try Data(contentsOf: file)
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == row["sha256"] as? String else { throw SC3RFError("Maintenance resource integrity failure.") }
        }
    }
}

enum SC3MaintenancePrivateJSON {
    static func read(_ url: URL, limit: Int = 32_768) throws -> [String: Any] {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw SC3RFError("Private evidence must be a regular non-symlink file.") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SC3RFError("Invalid or oversized private evidence JSON.") }
        return row
    }
}
