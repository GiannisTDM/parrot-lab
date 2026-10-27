import Foundation
import Darwin

/// The experimental, explicitly selected USB-network relay. This is neither
/// the stock mppd discovery endpoint nor SC3's ANAFI/libmux video path.
enum SC3SumoRelay {
    static let defaultHost = "192.168.53.1"
    static let discoveryPort: UInt16 = 44_446
    static let defaultCommandPort: UInt16 = 54_323
    static let keepaliveIntervalMilliseconds = 500
    static let maximumDiscoveryBytes = 8_191

    static func isValidHost(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        let first = value >> 24
        return first > 0 && first < 224 && value != UInt32.max
    }

    static func discoveryFailure(_ detail: String) -> Error {
        Failure(detail: detail)
    }

    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? {
            "SC3 Sumo relay discovery TCP 44446 failed: \(detail). " +
            "Check the SC3 USB network link and the separately started relay; " +
            "SC3 must already be associated with the Sumo Wi-Fi. Stock ANAFI TCP 44444 is not used."
        }
    }
}
