import Foundation
import Darwin

/// Main-thread Bonjour resolution for the normal ARSDK production service.
final class AnafiDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onResult: ((String, UInt16) -> Void)?
    var onStatus: ((String) -> Void)?
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var timeout: Timer?
    private var active = false
    func search(route: AnafiRoute) {
        cancel(); active = true
        let browser = NetServiceBrowser(); self.browser = browser; browser.delegate = self
        browser.searchForServices(ofType: route.bonjourType, inDomain: "local.")
        onStatus?("Searching for \(route.title)…")
        timeout = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.cancel(); self?.onStatus?("No ARSDK service found. Check the Mac's network or enter the address manually.")
        }
    }
    func cancel() {
        active = false; timeout?.invalidate(); timeout = nil
        browser?.delegate = nil; browser?.stop(); browser = nil
        services.forEach { $0.delegate = nil; $0.stop() }; services.removeAll()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard active, self.browser === browser else { return }
        services.append(service); service.delegate = self; service.resolve(withTimeout: 4)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard active, services.contains(where: { $0 === sender }), (1...65535).contains(sender.port) else { return }
        for data in sender.addresses ?? [] {
            var address = sockaddr_in()
            guard data.count >= MemoryLayout<sockaddr_in>.size else { continue }
            withUnsafeMutableBytes(of: &address) { target in _ = data.copyBytes(to: target) }
            guard address.sin_family == AF_INET else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address.sin_addr, &text, socklen_t(text.count)) != nil else { continue }
            let host = String(cString: text), port = UInt16(sender.port)
            cancel(); onResult?(host, port); return
        }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard self.browser === browser else { return }; cancel(); onStatus?("Bonjour unavailable. Enter the device address manually.")
    }
    deinit { timeout?.invalidate(); browser?.stop(); services.forEach { $0.stop() } }
}
