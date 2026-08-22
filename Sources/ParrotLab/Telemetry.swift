import Foundation

struct TelemetrySnapshot: Equatable {
    var updatedAt = Date()

    var sc2RSSI: Int?
    var reportedRSSI: Int?
    var chain0RSSI: Int?
    var chain1RSSI: Int?
    var noise: Int?
    var snr: Int? {
        guard let signal = chainAverage ?? reportedRSSI, let noise else { return nil }
        return signal - noise
    }
    var chainAverage: Int? {
        let values = [chain0RSSI, chain1RSSI].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    var txQuality: Int?
    var rxQuality: Int?
    var rxUseful: Int?
    var phyRateMbps: Double?

    var flightState = "UNKNOWN"
    var altitude: Double?
    var latitude: Double?
    var longitude: Double?
    var roll: Double?
    var pitch: Double?
    var yaw: Double?
    var horizontalSpeed: Double?
    var distanceFromHome: Double?
    var satelliteCount: Int?

    var sc2BatteryPercent: Int?
    var droneBatteryPercent: Int?
    var sc2TemperatureC: Int?
    var sc2PowerState: String?

    var videoBitrateKbps: Int?
    var videoFPS: Double?
    var videoPackets: UInt64 = 0
    var videoPacketsLost: UInt64 = 0
    var videoJitterMs: Double?

    var connectionLabel = "Disconnected"

    mutating func markUpdated() {
        updatedAt = Date()
    }
}

final class SC2TelemetryParser {
    private var homePosition: (latitude: Double, longitude: Double)?

    private let mppExpression = try! NSRegularExpression(
        pattern: #"rssi_mpp:\s*(-?\d+),\s*rssi:\s*(-?\d+),\s*state:([A-Z_]+),\s*altitude:([-+\d.]+),\s*latitude:([-+\d.]+),\s*longitude:([-+\d.]+),\s*roll:([-+\d.]+),\s*pitch:([-+\d.]+),\s*yaw:([-+\d.]+)"#
    )
    private let qualityExpression = try! NSRegularExpression(
        pattern: #"link_quality:\s*tx_quality=(-?\d+)%,\s*rx_quality=(-?\d+)%,\s*rx_useful=(-?\d+)%"#
    )
    private let healthExpression = try! NSRegularExpression(
        pattern: #"cpu:(-?\d+)°C,\s*battery:(\d+)%\s*\(([^)]+)\)"#
    )
    private let droneBatteryExpression = try! NSRegularExpression(
        pattern: #"__PARROTLAB_DRONE_BATTERY__\s*=\s*(\d{1,3})"#
    )
    private let nativeDroneBatteryExpression = try! NSRegularExpression(
        pattern: #"Battery percentage\s*:\s*(\d{1,3})"#
    )

    func reset() {
        homePosition = nil
    }

    @discardableResult
    func consume(line: String, into snapshot: inout TelemetrySnapshot) -> Bool {
        let clean = Self.stripANSI(from: line)
        var changed = false

        if let groups = captures(mppExpression, in: clean), groups.count == 9 {
            snapshot.sc2RSSI = Int(groups[0])
            snapshot.reportedRSSI = Int(groups[1])
            snapshot.flightState = groups[2]
            snapshot.altitude = validCoordinateLikeValue(groups[3])
            snapshot.latitude = validLatitude(groups[4])
            snapshot.longitude = validLongitude(groups[5])
            snapshot.roll = Double(groups[6])
            snapshot.pitch = Double(groups[7])
            snapshot.yaw = Double(groups[8])
            updateDistance(into: &snapshot)
            changed = true
        }

        if let groups = captures(qualityExpression, in: clean), groups.count == 3 {
            snapshot.txQuality = Self.validPercent(groups[0])
            snapshot.rxQuality = Self.validPercent(groups[1])
            snapshot.rxUseful = Self.validPercent(groups[2])
            changed = true
        }

        if let groups = captures(healthExpression, in: clean), groups.count == 3 {
            snapshot.sc2TemperatureC = Int(groups[0])
            snapshot.sc2BatteryPercent = Int(groups[1])
            snapshot.sc2PowerState = groups[2]
            changed = true
        }

        if let groups = captures(droneBatteryExpression, in: clean), groups.count == 1,
           let battery = Self.validPercent(groups[0]) {
            snapshot.droneBatteryPercent = battery
            changed = true
        } else if let groups = captures(nativeDroneBatteryExpression, in: clean),
                  groups.count == 1, let battery = Self.validPercent(groups[0]) {
            snapshot.droneBatteryPercent = battery
            changed = true
        }

        if let range = clean.range(of: "extra_cnt:") {
            let values = clean[range.upperBound...]
                .split(separator: ":")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if values.count >= 12 {
                snapshot.chain0RSSI = values[0]
                snapshot.chain1RSSI = values[1]
                snapshot.noise = values[11]
                changed = true
            }
        }

        if let range = clean.range(of: "evt_accu: 1: rate:") {
            let rates = clean[range.upperBound...]
                .split(separator: ":")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .filter { $0 > 0 }
            if let last = rates.last {
                snapshot.phyRateMbps = last / 1_000.0
                changed = true
            }
        }

        if changed { snapshot.markUpdated() }
        return changed
    }

    private func captures(_ expression: NSRegularExpression, in text: String) -> [String]? {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = expression.firstMatch(in: text, range: nsRange) else { return nil }
        return (1..<result.numberOfRanges).compactMap { index in
            guard let range = Range(result.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func validCoordinateLikeValue(_ value: String) -> Double? {
        guard let number = Double(value), abs(number) < 499 else { return nil }
        return number
    }

    private func validLatitude(_ value: String) -> Double? {
        guard let number = Double(value), (-90...90).contains(number) else { return nil }
        return number
    }

    private func validLongitude(_ value: String) -> Double? {
        guard let number = Double(value), (-180...180).contains(number) else { return nil }
        return number
    }

    private func updateDistance(into snapshot: inout TelemetrySnapshot) {
        guard let latitude = snapshot.latitude, let longitude = snapshot.longitude else {
            snapshot.distanceFromHome = nil
            return
        }
        if homePosition == nil {
            homePosition = (latitude, longitude)
        }
        guard let homePosition else { return }
        snapshot.distanceFromHome = Self.greatCircleDistance(
            latitude1: homePosition.latitude,
            longitude1: homePosition.longitude,
            latitude2: latitude,
            longitude2: longitude
        )
    }

    private static func greatCircleDistance(
        latitude1: Double,
        longitude1: Double,
        latitude2: Double,
        longitude2: Double
    ) -> Double {
        let radians = Double.pi / 180
        let deltaLatitude = (latitude2 - latitude1) * radians
        let deltaLongitude = (longitude2 - longitude1) * radians
        let a = pow(sin(deltaLatitude / 2), 2) +
            cos(latitude1 * radians) * cos(latitude2 * radians) *
            pow(sin(deltaLongitude / 2), 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    private static func validPercent(_ value: String) -> Int? {
        guard let number = Int(value), (0...100).contains(number) else { return nil }
        return number
    }

    static func stripANSI(from text: String) -> String {
        text.replacingOccurrences(
            of: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
    }

    /// Device shells echo commands before executing them. Accept a result
    /// marker only when it begins the returned line, never when it merely
    /// appears inside an echoed `if ... echo MARKER ...` command.
    static func deviceMarkerPayload(_ prefix: String, in line: String) -> String? {
        let clean = stripANSI(from: line)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix(prefix) else { return nil }
        let payload = clean.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }
}
