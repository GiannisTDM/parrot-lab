import Foundation

enum ParrotVideoCodec: Equatable {
    case h264
    case mjpeg
}

enum ParrotCommandFamily: Equatable {
    case arDrone3
    case jumpingSumo
    case unknown
}

enum ParrotProductModel: String, Equatable, Codable {
    case unknown
    case bebopDrone
    case bebop2
    case jumpingSumo

    init(productID: UInt16) {
        switch productID {
        case 0x0901: self = .bebopDrone
        case 0x0902: self = .jumpingSumo
        case 0x090c: self = .bebop2
        default: self = .unknown
        }
    }

    var productID: UInt16? {
        switch self {
        case .unknown: return nil
        case .bebopDrone: return 0x0901
        case .jumpingSumo: return 0x0902
        case .bebop2: return 0x090c
        }
    }

    var displayName: String {
        switch self {
        case .unknown: return "Parrot product — detecting model"
        case .bebopDrone: return "Bebop Drone"
        case .bebop2: return "Bebop 2"
        case .jumpingSumo: return "Jumping Sumo"
        }
    }

    var shortLabel: String {
        switch self {
        case .unknown: return "PARROT"
        case .bebopDrone: return "BB1"
        case .bebop2: return "BB2"
        case .jumpingSumo: return "SUMO"
        }
    }

    var mediaFilenameToken: String { shortLabel }
    var isGroundProduct: Bool { self == .jumpingSumo }

    var capabilities: ParrotProductCapabilities {
        ParrotProductCapabilities(model: self)
    }
}

struct ParrotProductCapabilities: Equatable {
    let model: ParrotProductModel

    var commandFamily: ParrotCommandFamily {
        switch model {
        case .bebopDrone, .bebop2: return .arDrone3
        case .jumpingSumo: return .jumpingSumo
        case .unknown: return .unknown
        }
    }

    var videoCodec: ParrotVideoCodec { model == .jumpingSumo ? .mjpeg : .h264 }
    var supportsSharedARDrone3Commands: Bool { model == .bebopDrone || model == .bebop2 }
    var supportsJumpingSumoCommands: Bool { model == .jumpingSumo }
    var supportsStockCompatibilityVideo: Bool { model != .unknown }
    var usesARStream1Video: Bool { model == .bebopDrone || model == .jumpingSumo }
    var supportsStockFisheyePhoto: Bool { model == .bebopDrone || model == .bebop2 }
    var supportsBebopCalibration: Bool { model == .bebopDrone || model == .bebop2 }
    var supportsFlightNavigation: Bool { model == .bebopDrone || model == .bebop2 }
    var supportsGroundDriving: Bool { model == .jumpingSumo }
    var supportsBB2DragonLab: Bool { model == .bebop2 }
    var supportsBB2CameraCalibration: Bool { model == .bebop2 }
    var supportsBB2PersistentTelnetInstall: Bool { model == .bebop2 }
    var supportsValidatedRFMod: Bool { model == .bebop2 }
}

enum ParrotVideoSource: Equatable {
    case directARStream1(ParrotVideoCodec)
    case directARStream2H264
    case skyControllerRestream
}

enum ParrotSessionRouting {
    static func routeAfterDetection(
        current: ARSDKConnectionRoute,
        product _: ParrotProductModel
    ) -> ARSDKConnectionRoute {
        current
    }

    static func videoSource(
        route: ARSDKConnectionRoute,
        product: ParrotProductModel
    ) -> ParrotVideoSource {
        if route == .skyController { return .skyControllerRestream }
        if product.capabilities.usesARStream1Video {
            return .directARStream1(product.capabilities.videoCodec)
        }
        return .directARStream2H264
    }
}

/// Detects direct-Wi-Fi products without guessing from an SSID. All products
/// use the same 192.168.42.1 ARDiscovery route; the Bonjour product ID selects
/// the command and video backend before media starts arriving.
final class DirectParrotProductDiscovery: NSObject, NetServiceBrowserDelegate {
    var onDetected: ((ParrotProductModel, String) -> Void)?
    var onLog: ((String) -> Void)?

    private let bebopDroneBrowser = NetServiceBrowser()
    private let jumpingSumoBrowser = NetServiceBrowser()
    private let bebop2Browser = NetServiceBrowser()
    private var active = false

    override init() {
        super.init()
        bebopDroneBrowser.delegate = self
        jumpingSumoBrowser.delegate = self
        bebop2Browser.delegate = self
    }

    func start() {
        stop()
        active = true
        bebopDroneBrowser.searchForServices(ofType: "_arsdk-0901._udp.", inDomain: "local.")
        jumpingSumoBrowser.searchForServices(ofType: "_arsdk-0902._udp.", inDomain: "local.")
        bebop2Browser.searchForServices(ofType: "_arsdk-090c._udp.", inDomain: "local.")
        onLog?("Discovering direct Parrot product via _arsdk-0901/_arsdk-0902/_arsdk-090c Bonjour")
    }

    func stop() {
        active = false
        bebopDroneBrowser.stop()
        jumpingSumoBrowser.stop()
        bebop2Browser.stop()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        guard active else { return }
        let model: ParrotProductModel
        if browser === bebopDroneBrowser {
            model = .bebopDrone
        } else if browser === jumpingSumoBrowser {
            model = .jumpingSumo
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
        onLog?("Direct product Bonjour discovery unavailable: \(errorDict)")
    }
}

enum ProductSupportSelfTest {
    static func run() -> Bool {
        ParrotProductModel(productID: 0x0901) == .bebopDrone &&
        ParrotProductModel(productID: 0x0902) == .jumpingSumo &&
        ParrotProductModel(productID: 0x090c) == .bebop2 &&
        ParrotProductModel(productID: 0xffff) == .unknown &&
        ParrotProductModel.bebopDrone.capabilities.supportsSharedARDrone3Commands &&
        ParrotProductModel.bebopDrone.capabilities.supportsBebopCalibration &&
        ParrotProductModel.bebopDrone.capabilities.usesARStream1Video &&
        ParrotProductModel.jumpingSumo.capabilities.usesARStream1Video &&
        ParrotProductModel.jumpingSumo.capabilities.videoCodec == .mjpeg &&
        ParrotProductModel.jumpingSumo.capabilities.commandFamily == .jumpingSumo &&
        !ParrotProductModel.jumpingSumo.capabilities.supportsFlightNavigation &&
        !ParrotProductModel.jumpingSumo.capabilities.supportsBebopCalibration &&
        !ParrotProductModel.jumpingSumo.capabilities.supportsValidatedRFMod &&
        !ParrotProductModel.bebop2.capabilities.usesARStream1Video &&
        ParrotProductModel.bebop2.capabilities.supportsBebopCalibration &&
        ParrotProductModel.bebop2.capabilities.supportsBB2DragonLab &&
        !ParrotProductModel.unknown.capabilities.supportsValidatedRFMod &&
        ParrotSessionRouting.routeAfterDetection(
            current: .skyController,
            product: .jumpingSumo
        ) == .skyController &&
        ParrotSessionRouting.videoSource(
            route: .directProduct,
            product: .jumpingSumo
        ) == .directARStream1(.mjpeg) &&
        ParrotSessionRouting.videoSource(
            route: .skyController,
            product: .jumpingSumo
        ) == .skyControllerRestream &&
        ParrotSessionRouting.videoSource(
            route: .skyController,
            product: .bebop2
        ) == .skyControllerRestream
    }
}
