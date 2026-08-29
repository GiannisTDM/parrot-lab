import Foundation

enum ParrotAircraftModel: String, Equatable, Codable {
    case unknown
    case bebopDrone
    case bebop2

    init(productID: UInt16) {
        switch productID {
        case 0x0901: self = .bebopDrone
        case 0x090c: self = .bebop2
        default: self = .unknown
        }
    }

    var productID: UInt16? {
        switch self {
        case .unknown: return nil
        case .bebopDrone: return 0x0901
        case .bebop2: return 0x090c
        }
    }

    var displayName: String {
        switch self {
        case .unknown: return "Bebop — detecting model"
        case .bebopDrone: return "Bebop Drone"
        case .bebop2: return "Bebop 2"
        }
    }

    var shortLabel: String {
        switch self {
        case .unknown: return "BEBOP"
        case .bebopDrone: return "BB1"
        case .bebop2: return "BB2"
        }
    }

    var mediaFilenameToken: String { shortLabel }

    var capabilities: ParrotAircraftCapabilities {
        ParrotAircraftCapabilities(model: self)
    }
}

struct ParrotAircraftCapabilities: Equatable {
    let model: ParrotAircraftModel

    var supportsSharedARDrone3Commands: Bool { true }
    var supportsStockCompatibilityVideo: Bool { true }
    var supportsStockFisheyePhoto: Bool { true }
    var supportsBB2DragonLab: Bool { model == .bebop2 }
    var supportsBB2CameraCalibration: Bool { model == .bebop2 }
    var supportsBB2PersistentTelnetInstall: Bool { model == .bebop2 }
    var supportsValidatedRFMod: Bool { model == .bebop2 }
}

/// Detects the direct-Wi-Fi product without guessing from an SSID or media
/// directory. Both products otherwise use the same 192.168.42.1 ARSDK route.
final class DirectAircraftProductDiscovery: NSObject, NetServiceBrowserDelegate {
    var onDetected: ((ParrotAircraftModel, String) -> Void)?
    var onLog: ((String) -> Void)?

    private let bebopDroneBrowser = NetServiceBrowser()
    private let bebop2Browser = NetServiceBrowser()
    private var active = false

    override init() {
        super.init()
        bebopDroneBrowser.delegate = self
        bebop2Browser.delegate = self
    }

    func start() {
        stop()
        active = true
        bebopDroneBrowser.searchForServices(ofType: "_arsdk-0901._udp.", inDomain: "local.")
        bebop2Browser.searchForServices(ofType: "_arsdk-090c._udp.", inDomain: "local.")
        onLog?("Discovering direct aircraft product via _arsdk-0901/_arsdk-090c Bonjour")
    }

    func stop() {
        active = false
        bebopDroneBrowser.stop()
        bebop2Browser.stop()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        guard active else { return }
        let model: ParrotAircraftModel
        if browser === bebopDroneBrowser {
            model = .bebopDrone
        } else if browser === bebop2Browser {
            model = .bebop2
        } else {
            return
        }
        stop()
        onDetected?(model, service.name)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard active else { return }
        onLog?("Direct aircraft Bonjour discovery unavailable: \(errorDict)")
    }
}

enum AircraftSupportSelfTest {
    static func run() -> Bool {
        ParrotAircraftModel(productID: 0x0901) == .bebopDrone &&
        ParrotAircraftModel(productID: 0x090c) == .bebop2 &&
        ParrotAircraftModel(productID: 0xffff) == .unknown &&
        ParrotAircraftModel.bebopDrone.capabilities.supportsSharedARDrone3Commands &&
        !ParrotAircraftModel.bebopDrone.capabilities.supportsBB2DragonLab &&
        ParrotAircraftModel.bebop2.capabilities.supportsBB2DragonLab &&
        !ParrotAircraftModel.unknown.capabilities.supportsValidatedRFMod
    }
}
