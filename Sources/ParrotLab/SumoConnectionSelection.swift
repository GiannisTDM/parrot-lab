import Foundation

enum SumoConnectionSelection: String, CaseIterable {
    case direct, sc2, sc3Native, sc3Relay
    static let preferenceKey = "ParrotLab.SumoConnectionRoute"
    static let relayHostKey = "ParrotLab.SumoSC3RelayHost"
    static let nativeHostKey = "ParrotLab.SumoSC3NativeHost"
    var title: String {
        switch self {
        case .direct: return "Direct Wi-Fi"
        case .sc2: return "SkyController 2"
        case .sc3Native: return "SC3 native · experimental"
        case .sc3Relay: return "SC3 USB relay · experimental"
        }
    }
    var route: ARSDKConnectionRoute {
        switch self {
        case .direct: return .directProduct
        case .sc2: return .skyController
        case .sc3Native: return .sumoSC3Native
        case .sc3Relay: return .sumoSC3Relay
        }
    }
    static func load(standalone: Bool, defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? (standalone ? .direct : .sc2)
    }
}

/// UI authorization is session-scoped. The client also enforces this on its
/// serial network queue, so a stalled UI cannot keep an old drive active.
struct SumoRelayDriveGate {
    static let freshnessInterval: TimeInterval = 3
    private(set) var armed = false
    private var hasState = false
    private var lastActivity: TimeInterval?
    mutating func reset() { self = Self() }
    mutating func disarm() { armed = false }
    mutating func receivedState(at now: TimeInterval) {
        guard now.isFinite else { return }
        hasState = true; receivedHeartbeat(at: now)
    }
    mutating func receivedHeartbeat(at now: TimeInterval) {
        guard now.isFinite else { return }
        lastActivity = max(lastActivity ?? now, now)
    }
    func isFresh(at now: TimeInterval) -> Bool {
        guard hasState, let lastActivity, now.isFinite else { return false }
        return (0...Self.freshnessInterval).contains(now - lastActivity)
    }
    mutating func arm(at now: TimeInterval, neutral: Bool, focused: Bool) -> Bool {
        armed = neutral && focused && isFresh(at: now)
        return armed
    }
    static func selfTest() -> Bool {
        var gate = Self()
        gate.receivedHeartbeat(at: 10)
        guard !gate.arm(at: 10, neutral: true, focused: true) else { return false }
        gate.receivedState(at: 10)
        guard !gate.arm(at: 10, neutral: false, focused: true),
              !gate.arm(at: 10, neutral: true, focused: false),
              gate.arm(at: 10, neutral: true, focused: true), !gate.isFresh(at: 13.01) else { return false }
        gate.disarm(); gate.receivedHeartbeat(at: 13.1)
        guard !gate.armed, gate.isFresh(at: 13.1) else { return false }
        gate.reset(); gate.receivedHeartbeat(at: 20)
        guard !gate.isFresh(at: 20), !gate.armed else { return false }
        let name = "ParrotLab.SumoRouteTest." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: name) else { return false }
        defer { defaults.removePersistentDomain(forName: name) }
        guard SumoConnectionSelection.load(standalone: true, defaults: defaults) == .direct,
              SumoConnectionSelection.load(standalone: false, defaults: defaults) == .sc2 else { return false }
        defaults.set(SumoConnectionSelection.sc3Relay.rawValue, forKey: SumoConnectionSelection.preferenceKey)
        return SC3SumoRelay.isValidHost("192.168.53.1") && SC3SumoRelay.isValidHost("127.0.0.1") &&
            !SC3SumoRelay.isValidHost("0.0.0.0") && !SC3SumoRelay.isValidHost("224.1.2.3") &&
            !SC3SumoRelay.isValidHost("255.255.255.255") && !SC3SumoRelay.isValidHost("relay.local") &&
            SumoConnectionSelection.load(standalone: true, defaults: defaults).route == .sumoSC3Relay &&
            SumoConnectionSelection.load(standalone: false, defaults: defaults).route == .sumoSC3Relay &&
            ParrotSessionRouting.videoSource(route: .sumoSC3Relay, product: .jumpingSumo) == .directARStream1(.mjpeg) &&
            ParrotSessionRouting.videoSource(route: .sumoSC3Native, product: .jumpingSumo) == .nativeSC3ARStream1 &&
            !ARSDKConnectionRoute.sumoSC3Native.usesDirectARNetworkVideo
    }
}
