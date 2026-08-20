import Foundation

enum VideoReceiveMode: Int, CaseIterable {
    case compatibility
    case experimental1080p

    static let experimentalDragonProfile = "-V 1 -f 30 -R off -S 0 -I off -o"

    var menuTitle: String {
        switch self {
        case .compatibility:
            return "Compatibility · Recovery"
        case .experimental1080p:
            return "1080p Lab · FrameInfo"
        }
    }

    var statusLabel: String {
        switch self {
        case .compatibility: return "COMPAT"
        case .experimental1080p: return "1080P LAB"
        }
    }

    var prefersVideoToolbox: Bool { self == .experimental1080p }
    var expectedDragonProfile: String? {
        self == .experimental1080p ? Self.experimentalDragonProfile : nil
    }

    static func selfTest() -> Bool {
        allCases.count == 2 &&
            compatibility.prefersVideoToolbox == false &&
            experimental1080p.prefersVideoToolbox &&
            experimental1080p.expectedDragonProfile == "-V 1 -f 30 -R off -S 0 -I off -o"
    }
}

struct VideoMetadataPresence: Equatable {
    var hasLegacyFrameInfoSEI = false
    var hasRTPHeaderExtensions = false
}
