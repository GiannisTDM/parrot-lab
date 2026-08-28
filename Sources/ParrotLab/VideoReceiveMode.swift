import Foundation

enum VideoReceiveMode: Int, CaseIterable {
    case compatibility
    case modified900
    case temporal900

    static let modifiedDragonProfile = "-V 2 -q 1000 -o"
    static let temporalDragonProfile = "-V 2 -f 30 -R gpu -S 0 -q 12000 -o"

    var menuTitle: String {
        switch self {
        case .compatibility:
            return "Compatibility · Recovery"
        case .modified900:
            return "900p Modified · FrameInfo"
        case .temporal900:
            return "900p Temporal · FrameInfo"
        }
    }

    var statusLabel: String {
        switch self {
        case .compatibility: return "COMPAT"
        case .modified900: return "900P MODIFIED"
        case .temporal900: return "900P TEMPORAL"
        }
    }

    var is900p: Bool { self != .compatibility }
    var prefersVideoToolbox: Bool { is900p }
    var expectedDragonProfile: String? {
        switch self {
        case .compatibility: return nil
        case .modified900: return Self.modifiedDragonProfile
        case .temporal900: return Self.temporalDragonProfile
        }
    }

    static func selfTest() -> Bool {
        allCases.count == 3 &&
            compatibility.prefersVideoToolbox == false &&
            modified900.prefersVideoToolbox && temporal900.prefersVideoToolbox &&
            modified900.expectedDragonProfile == "-V 2 -q 1000 -o" &&
            temporal900.expectedDragonProfile == "-V 2 -f 30 -R gpu -S 0 -q 12000 -o"
    }
}

struct VideoMetadataPresence: Equatable {
    var hasLegacyFrameInfoSEI = false
    var hasRTPHeaderExtensions = false
    var hasDecodedVideoMetadataV2 = false
}
