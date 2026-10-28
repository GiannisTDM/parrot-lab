import Foundation

enum SumoAudioTheme: Int32, CaseIterable {
    case `default` = 0
    case robot = 1
    case insect = 2
    case monster = 3

    var title: String {
        switch self {
        case .default: return "Default"
        case .robot: return "Robot"
        case .insect: return "Insect"
        case .monster: return "Monster"
        }
    }
}

/// Public ARSDK JumpingSumo.AudioSettings/AudioSettingsState, project 3.
/// These commands configure the built-in sounds; they do not play custom audio.
enum SumoAudioProtocol {
    static func volumeCommand(_ volume: UInt8) -> Data {
        Data([3, 12, 0, 0, min(volume, 100)])
    }

    static func themeCommand(_ theme: SumoAudioTheme) -> Data {
        let raw = UInt32(bitPattern: theme.rawValue)
        return Data([3, 12, 1, 0]) + Data((0..<4).map {
            UInt8(truncatingIfNeeded: raw >> ($0 * 8))
        })
    }

    static func decode(_ data: Data) -> ARSDKTelemetryEvent? {
        guard data.count >= 4, data[0] == 3, data[1] == 13, data[3] == 0 else {
            return nil
        }
        switch data[2] {
        case 0:
            guard data.count == 5, data[4] <= 100 else { return nil }
            return .sumoAudioVolume(data[4])
        case 1:
            guard data.count == 8 else { return nil }
            let raw = (0..<4).reduce(UInt32(0)) {
                $0 | UInt32(data[4 + $1]) << ($1 * 8)
            }
            guard let theme = SumoAudioTheme(rawValue: Int32(bitPattern: raw)) else {
                return nil
            }
            return .sumoAudioTheme(theme)
        default:
            return nil
        }
    }

    static func selfTest() -> Bool {
        // Fixtures match Parrot's jpsumo.xml classes 12/13. Enum arguments
        // occupy four little-endian bytes; volume is one unsigned byte.
        guard volumeCommand(0) == Data([3, 12, 0, 0, 0]),
              volumeCommand(100) == Data([3, 12, 0, 0, 100]),
              volumeCommand(255) == volumeCommand(100) else { return false }
        for theme in SumoAudioTheme.allCases {
            let raw = UInt8(theme.rawValue)
            guard themeCommand(theme) == Data([3, 12, 1, 0, raw, 0, 0, 0]),
                  ARSDKTelemetryProtocol.decode(Data([3, 13, 1, 0, raw, 0, 0, 0])) ==
                    .sumoAudioTheme(theme) else { return false }
        }
        guard ARSDKTelemetryProtocol.decode(Data([3, 13, 0, 0, 75])) == .sumoAudioVolume(75) else {
            return false
        }
        let invalid = [
            Data(), Data([3]), Data([3, 13, 0]), Data([3, 13, 0, 0]),
            Data([3, 13, 0, 0, 101]), Data([3, 13, 0, 0, 80, 0]),
            Data([3, 13, 1, 0, 1]), Data([3, 13, 1, 0, 1, 0, 0]),
            Data([3, 13, 1, 0, 4, 0, 0, 0]), Data([3, 13, 1, 0, 0, 1, 0, 0]),
            Data([3, 13, 1, 0, 255, 255, 255, 255]),
            Data([3, 13, 2, 0, 0]), Data([3, 13, 0, 1, 0]),
            Data([1, 13, 0, 0, 80]), Data([3, 12, 0, 0, 80])
        ]
        guard invalid.allSatisfy({ decode($0) == nil }) else { return false }

        // An in-memory mux endpoint verifies the actual client uses the
        // acknowledged command channel and never emits Sumo audio on Bebops.
        let client = ARSDKCommandClient()
        let captured = PacketCapture()
        client.connectMux(product: .jumpingSumo, send: { captured.append($0) }) { _ in }
        client.setSumoVolume(70)
        client.setSumoAudioTheme(.monster)
        _ = client.diagnosticSummary // Wait for queued commands without pumping UI callbacks.
        let expected = [
            ARSDKPhotoProtocol.frame(type: 4, id: 11, sequence: 1, payload: volumeCommand(70)),
            ARSDKPhotoProtocol.frame(type: 4, id: 11, sequence: 2, payload: themeCommand(.monster))
        ]
        guard captured.commandPackets == expected else {
            client.stop()
            _ = client.diagnosticSummary
            return false
        }
        client.connectMux(product: .bebop2, send: { captured.append($0) }) { _ in }
        client.setSumoVolume(80)
        client.setSumoAudioTheme(.robot)
        _ = client.diagnosticSummary
        let bebopRejected = captured.commandPackets == expected
        client.connectMux(product: .jumpingSumo, send: { captured.append($0) }) { _ in }
        client.stop()
        client.setSumoVolume(20)
        client.setSumoAudioTheme(.insect)
        _ = client.diagnosticSummary
        return bebopRejected && captured.commandPackets == expected
    }

    private final class PacketCapture {
        private let lock = NSLock()
        private var storage: [Data] = []

        var commandPackets: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return storage.filter { $0.count >= 7 && $0[0] == 4 && $0[1] == 11 }
        }

        func append(_ packet: Data) {
            lock.lock()
            storage.append(packet)
            lock.unlock()
        }
    }
}
