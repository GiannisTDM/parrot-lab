import Foundation
import CryptoKit

enum SC3RFKey: String, CaseIterable {
    case cap = "gTxPowerCap", sar2 = "TxPower2g", sar5 = "TxPower5g"
    case tpc = "gAllowTPCfromAP", flex = "gFlexConnectPowerFactor"
    var range: ClosedRange<Int> { self == .tpc ? 0...1 : self == .flex ? 0...9 : 1...30 }
    var driverDefault: Int { self == .cap ? 128 : self == .tpc ? 1 : self == .flex ? 0 : 30 }
    var title: String {
        switch self {
        case .cap: return "P1 · Host power cap"
        case .sar2: return "P2 · 2.4 GHz SAR / thermal"
        case .sar5: return "P3 · 5 GHz SAR / thermal"
        case .tpc: return "P4 · Accept AP TPC requests"
        case .flex: return "P7 · FlexConnect factor"
        }
    }
    var defaultLabel: String { self == .cap ? "128 sentinel (not dBm)" : self == .tpc ? "ON (1)" : String(driverDefault) }
    func validate(_ value: String) throws -> String {
        if value == "unset" { return value }
        if self == .tpc, value == "on" || value == "off" { return value == "on" ? "1" : "0" }
        guard !value.isEmpty, value.count <= 2, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let integer = Int(value), range.contains(integer) else { throw SC3RFError("Invalid value for \(rawValue); use \(range.lowerBound)…\(range.upperBound) or driver default.") }
        return String(integer)
    }
}

struct SC3RFError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SC3RFSettings: Equatable {
    struct Row: Decodable, Equatable {
        let key: String, kind: String
        let min: Int, max: Int, driver_default: Int
        let saved: String?
        let source: String
        let within_editor_range: Bool, unset_allowed: Bool
    }
    private struct Document: Decodable {
        let schema: String, version: String, ini_sha1: String, settings: [Row]
        let saved_is_live_output: Bool, radio_reload_performed: Bool
    }
    let hash: String
    let rows: [SC3RFKey: Row]
    let rawSaved: [SC3RFKey: String]
    let fileIssue: String?
    static func digest(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func isHash(_ text: String) -> Bool { text.count == 40 && text.allSatisfy { "0123456789abcdef".contains($0) } }

    init(json: Data, ini: Data) throws {
        guard json.count <= 32_768, ini.count <= 262_144 else { throw SC3RFError("SC3 settings exceed the size limit.") }
        // JSONDecoder accepts duplicate object keys; reject those before decoding.
        try SC3RFJSON.validate(json)
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              Set(object.keys) == Set(["schema", "version", "ini_sha1", "settings", "saved_is_live_output", "radio_reload_performed"]),
              let rawRows = object["settings"] as? [[String: Any]], rawRows.allSatisfy({
                  Set($0.keys) == Set(["key", "kind", "min", "max", "driver_default", "saved", "source", "within_editor_range", "unset_allowed"])
              }) else { throw SC3RFError("Unexpected SC3 settings fields.") }
        let document = try JSONDecoder().decode(Document.self, from: json)
        guard document.schema == "sc3-rf-settings-v1", document.version == "0.2.0",
              Self.isHash(document.ini_sha1), Self.digest(ini) == document.ini_sha1,
              !document.saved_is_live_output, !document.radio_reload_performed,
              document.settings.count == SC3RFKey.allCases.count else { throw SC3RFError("Unexpected SC3 settings schema or changed INI; refresh before editing.") }
        var values: [SC3RFKey: Row] = [:]
        for row in document.settings {
            guard let key = SC3RFKey(rawValue: row.key), values[key] == nil,
                  row.kind == (key == .tpc ? "toggle" : "integer"), row.min == key.range.lowerBound,
                  row.max == key.range.upperBound, row.driver_default == key.driverDefault, row.unset_allowed,
                  ["explicit", "unset", "invalid"].contains(row.source) else { throw SC3RFError("Unexpected SC3 setting row.") }
            if row.source == "explicit" {
                guard let saved = row.saved, (1...32).contains(saved.count), saved.allSatisfy({ $0.isASCII && $0.isNumber }),
                      row.within_editor_range == (Int(saved).map { key.range.contains($0) } ?? false) else { throw SC3RFError("Invalid saved SC3 setting.") }
            } else {
                guard row.saved == nil, row.within_editor_range == (row.source == "unset") else { throw SC3RFError("Inconsistent default/invalid SC3 setting.") }
            }
            values[key] = row
        }
        guard let text = String(data: ini, encoding: .utf8), !text.contains("\0") else { throw SC3RFError("Invalid SC3 INI encoding.") }
        var parsed: [SC3RFKey: String] = [:], ended = false, ends = 0, issue: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "END" { ends += 1; ended = true; continue }
            if ended { issue = "Active content after END; saving is blocked." }
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let key = SC3RFKey(rawValue: pair[0].replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")) else { continue }
            if parsed[key] != nil { issue = "Duplicate \(key.rawValue); saving is blocked." }
            parsed[key] = String(pair[1].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespaces)
        }
        if ends != 1 { issue = "INI needs exactly one END marker; saving is blocked." }
        for key in SC3RFKey.allCases {
            let row = values[key]!
            if row.source == "invalid" { issue = "Invalid saved \(key.rawValue); resolve it explicitly in the existing tool." }
            else if row.saved != parsed[key] { issue = "Settings and INI disagree; saving is blocked." }
        }
        hash = document.ini_sha1; rows = values; rawSaved = parsed; fileIssue = issue
    }
}

/// A small structural scanner to reject duplicate JSON keys, including escaped aliases.
/// Full type/number validation remains with JSONDecoder.
enum SC3RFJSON {
    static func validate(_ data: Data) throws {
        let bytes = Array(data); var index = 0
        func spaces() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        func string() throws -> String {
            let start = index; index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 { index += 1; return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                index += 1
            }
            throw SC3RFError("Truncated settings JSON.")
        }
        func value(_ depth: Int) throws {
            guard depth < 12 else { throw SC3RFError("Settings JSON too deeply nested.") }
            spaces(); guard index < bytes.count else { throw SC3RFError("Truncated settings JSON.") }
            if bytes[index] == 34 { _ = try string(); return }
            if bytes[index] == 123 || bytes[index] == 91 {
                let object = bytes[index] == 123, end: UInt8 = object ? 125 : 93
                index += 1; spaces(); var keys = Set<String>()
                if index < bytes.count, bytes[index] == end { index += 1; return }
                while index < bytes.count {
                    if object {
                        guard bytes[index] == 34 else { throw SC3RFError("Malformed settings JSON key.") }
                        guard keys.insert(try string()).inserted else { throw SC3RFError("Duplicate settings JSON key.") }
                        spaces(); guard index < bytes.count, bytes[index] == 58 else { throw SC3RFError("Malformed settings JSON.") }; index += 1
                    }
                    try value(depth + 1); spaces()
                    guard index < bytes.count else { throw SC3RFError("Truncated settings JSON.") }
                    if bytes[index] == end { index += 1; return }
                    guard bytes[index] == 44 else { throw SC3RFError("Malformed settings JSON.") }; index += 1; spaces()
                }
                throw SC3RFError("Truncated settings JSON.")
            }
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw SC3RFError("Malformed settings JSON value.") }
        }
        try value(0); spaces(); guard index == bytes.count else { throw SC3RFError("Trailing settings JSON.") }
    }
}

struct SC3RFPreview: Equatable {
    let hash: String
    let pairs: [String]
    let diff: String
}

struct SC3RFDraft {
    var settings: SC3RFSettings?
    private(set) var edits: [SC3RFKey: String] = [:]
    private(set) var preview: SC3RFPreview?
    mutating func stage(_ key: SC3RFKey, value: String) throws {
        guard let settings, settings.fileIssue == nil else { throw SC3RFError("Read valid settings first.") }
        let normalized = try key.validate(value)
        let saved = settings.rows[key]!.saved
        if normalized == (saved ?? "unset") { edits.removeValue(forKey: key) } else { edits[key] = normalized }
        preview = nil
    }
    mutating func discard() { edits.removeAll(); preview = nil }
    mutating func invalidatePreview() { preview = nil }
    var pairs: [String] { SC3RFKey.allCases.flatMap { key in edits[key].map { [key.rawValue, $0] } ?? [] } }
    mutating func acceptPreview(_ text: String, hash: String, pairs: [String]) throws {
        guard settings?.hash == hash, self.pairs == pairs, !pairs.isEmpty,
              text.hasPrefix("Base INI SHA-1: \(hash)\n"),
              text.hasSuffix("Preview only; no INI setting saved, radio reload or reboot performed.\n"),
              !text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }) else { throw SC3RFError("Invalid or stale SC3 preview.") }
        preview = SC3RFPreview(hash: hash, pairs: pairs, diff: text)
    }
}

struct SC3RFObservation {
    let peer: String?, ssid: String?, signal: String?, a0: String?, a1: String?
    let txPHY: String?, rxPHY: String?, txPower: String?, noise: String?, snr: String?
    let retries: String?, failures: String?
    let rxBytes: UInt64?, txBytes: UInt64?, rxErrors: String?, txErrors: String?, uptime: Double?
    init(snapshot: String, counters: String, uptime: String) {
        func section(_ start: String, _ end: String) -> String {
            guard let a = snapshot.range(of: start), let b = snapshot.range(of: end, range: a.upperBound..<snapshot.endIndex) else { return "" }
            return String(snapshot[a.upperBound..<b.lowerBound])
        }
        let link = section("\nNetlink link:\n", "\nNetlink station:\n")
        let station = section("\nNetlink station:\n", "\nVendor chain reply:\n")
        let chain = section("\nVendor chain reply:\n", "\nINI digest:")
        func match(_ pattern: String, _ text: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        peer = match("^Connected to ([0-9A-Fa-f:]{17}) ", link)
        ssid = peer == nil ? nil : match("^[ \\t]*SSID: (.*)$", link).map {
            String(String.UnicodeScalarView($0.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })).prefix(128).description
        }
        signal = peer == nil ? nil : match("^[ \\t]*signal: (-?[0-9]+)", link)
        a0 = peer == nil ? nil : match("^chain0_dbm=(-?[0-9]+)$", chain)
        a1 = peer == nil ? nil : match("^chain1_dbm=(-?[0-9]+)$", chain)
        txPHY = peer == nil ? nil : (match("^[ \\t]*tx bitrate: ([0-9.]+)", station) ?? match("^[ \\t]*tx bitrate: ([0-9.]+)", link))
        rxPHY = peer == nil ? nil : (match("^[ \\t]*rx bitrate: ([0-9.]+)", station) ?? match("^[ \\t]*rx bitrate: ([0-9.]+)", link))
        txPower = peer == nil ? nil : match("SC3 TX-power readback: (-?[0-9]+) dBm", snapshot)
        noise = peer == nil ? nil : match("noise: (-?[0-9]+) dBm", snapshot)
        snr = peer == nil ? nil : match("SNR: (-?[0-9]+) dB", snapshot)
        retries = peer == nil ? nil : match("^[ \\t]*tx retries: ([0-9]+)", station)
        failures = peer == nil ? nil : match("^[ \\t]*tx failed: ([0-9]+)", station)
        let fields = counters.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("wlan0:") }?
            .split(whereSeparator: { $0 == ":" || $0.isWhitespace }).dropFirst().map(String.init) ?? []
        rxBytes = fields.count == 16 ? UInt64(fields[0]) : nil; txBytes = fields.count == 16 ? UInt64(fields[8]) : nil
        rxErrors = fields.count == 16 ? UInt64(fields[2]).map(String.init) : nil
        txErrors = fields.count == 16 ? UInt64(fields[10]).map(String.init) : nil
        self.uptime = uptime.split(separator: " ").first.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    func traffic(since previous: Self?) -> String {
        guard let previous, peer != nil, peer == previous.peer, let now = uptime, let before = previous.uptime,
              now > before, now - before < 30, let rx = rxBytes, let tx = txBytes,
              let prx = previous.rxBytes, let ptx = previous.txBytes, rx >= prx, tx >= ptx else { return "— / — Mbps" }
        return String(format: "%.2f / %.2f Mbps", Double(tx - ptx) * 8 / (now - before) / 1e6, Double(rx - prx) * 8 / (now - before) / 1e6)
    }
}
