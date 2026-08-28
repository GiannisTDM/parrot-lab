import Foundation

enum DragonVideoResolution: Int, CaseIterable {
    case stock480
    case stock720
    case modified900
    case temporal900

    var menuTitle: String {
        switch self {
        case .stock480: return "Stock · 856 × 480"
        case .stock720: return "Stock · 1280 × 720"
        case .modified900: return "900p Modified · 1600 × 900"
        case .temporal900: return "900p Temporal · 1600 × 900"
        }
    }

    var scriptToken: String {
        switch self {
        case .stock480: return "stock480"
        case .stock720: return "stock720"
        case .modified900: return "modified900"
        case .temporal900: return "temporal900"
        }
    }

    var statusLabel: String {
        switch self {
        case .stock480: return "480P"
        case .stock720: return "720P"
        case .modified900: return "900P MODIFIED"
        case .temporal900: return "900P TEMPORAL"
        }
    }

    var recommendedBitrateKbps: Int {
        switch self {
        case .stock480: return 2_500
        case .stock720: return 5_000
        case .modified900: return 1_000
        case .temporal900: return 12_000
        }
    }

    var receiverMode: VideoReceiveMode {
        switch self {
        case .modified900: return .modified900
        case .temporal900: return .temporal900
        case .stock480, .stock720: return .compatibility
        }
    }
}

struct DragonVideoProfile: Equatable {
    static let helperPath = "/data/ftp/internal_000/parrotlab_dragon_video.sh"
    static let bitrateRange = 1_000...16_000

    let resolution: DragonVideoResolution
    let bitrateKbps: Int
    let locksBitrate: Bool

    init?(resolution: DragonVideoResolution, bitrateKbps: Int, locksBitrate: Bool) {
        guard Self.bitrateRange.contains(bitrateKbps), bitrateKbps.isMultiple(of: 500) else {
            return nil
        }
        self.resolution = resolution
        self.bitrateKbps = bitrateKbps
        self.locksBitrate = locksBitrate
    }

    var bitrateLabel: String {
        String(format: "%.1f Mbps", Double(bitrateKbps) / 1_000.0)
    }

    var launchSummary: String {
        "\(resolution.statusLabel) · \(bitrateLabel)" + (locksBitrate ? " LOCKED" : " MAX")
    }

    var applyCommand: String {
        let rateMode = locksBitrate ? "constant" : "adaptive"
        return "sh \(Self.helperPath) apply \(resolution.scriptToken) \(bitrateKbps) \(rateMode) LANDED; exit"
    }

    static let restoreCommand = "sh \(helperPath) restore LANDED; exit"
    static let statusCommand = "sh \(helperPath) status; exit"

    static func selfTest() -> Bool {
        guard let profile = DragonVideoProfile(
            resolution: .temporal900,
            bitrateKbps: 12_000,
            locksBitrate: false
        ) else { return false }
        return profile.applyCommand ==
            "sh /data/ftp/internal_000/parrotlab_dragon_video.sh apply temporal900 12000 adaptive LANDED; exit" &&
            profile.launchSummary == "900P TEMPORAL · 12.0 Mbps MAX" &&
            DragonVideoProfile(resolution: .modified900, bitrateKbps: 1_000, locksBitrate: false)?.applyCommand ==
                "sh /data/ftp/internal_000/parrotlab_dragon_video.sh apply modified900 1000 adaptive LANDED; exit" &&
            DragonVideoProfile(resolution: .temporal900, bitrateKbps: 8_250, locksBitrate: false) == nil &&
            DragonVideoProfile(resolution: .temporal900, bitrateKbps: 16_500, locksBitrate: false) == nil &&
            DragonCustomLaunch.selfTest()
    }
}

enum DragonCustomLaunchError: LocalizedError {
    case empty
    case tooLong
    case tooManyArguments
    case unsupportedCharacters

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter at least one Dragon argument."
        case .tooLong:
            return "Custom Dragon arguments are limited to 512 UTF-8 bytes."
        case .tooManyArguments:
            return "Custom Dragon launches are limited to 64 whitespace-separated arguments."
        case .unsupportedCharacters:
            return "Use only letters, numbers, spaces, and these argument characters: - _ . / : + , = @"
        }
    }
}

struct DragonCustomLaunch: Equatable {
    static let maximumBytes = 512
    static let maximumArguments = 64

    let arguments: String

    init(arguments rawArguments: String) throws {
        let normalized = rawArguments
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { throw DragonCustomLaunchError.empty }
        guard normalized.utf8.count <= Self.maximumBytes else { throw DragonCustomLaunchError.tooLong }
        guard normalized.split(separator: " ").count <= Self.maximumArguments else {
            throw DragonCustomLaunchError.tooManyArguments
        }

        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/+,=@ "
        )
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw DragonCustomLaunchError.unsupportedCharacters
        }
        arguments = normalized
    }

    var applyCommand: String {
        // Validation above excludes quotes and shell metacharacters, so a
        // single quoted argument is safe and works on stock BusyBox without
        // requiring a base64 executable on the drone.
        return "sh \(DragonVideoProfile.helperPath) custom '\(arguments)' LANDED; exit"
    }

    static func selfTest() -> Bool {
        guard let launch = try? DragonCustomLaunch(
            arguments: "  -V 1  -f 30 -R off -S 0 -I off -o  "
        ) else { return false }
        return launch.arguments == "-V 1 -f 30 -R off -S 0 -I off -o" &&
            launch.applyCommand.hasPrefix(
                "sh /data/ftp/internal_000/parrotlab_dragon_video.sh custom "
            ) &&
            launch.applyCommand.hasSuffix(" LANDED; exit") &&
            (try? DragonCustomLaunch(arguments: "-V 1; reboot")) == nil &&
            (try? DragonCustomLaunch(arguments: String(repeating: "x", count: 513))) == nil
    }
}
