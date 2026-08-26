import Darwin
import Foundation
import Network

struct SC2USBDiscoveryResult {
    let host: String
    let interfaceName: String
    let localAddress: String
    let serviceName: String
    let servicePort: UInt16
}

enum SC2USBDiscoveryError: LocalizedError {
    case noUSBInterface
    case controllerNotReachable([String])

    var errorDescription: String? {
        switch self {
        case .noUSBInterface:
            return "No active macOS network interface was found on the SC2 USB subnet (192.168.53.0/24). Connect the controller by USB and enable USB networking first."
        case .controllerNotReachable(let candidates):
            return "An SC2 USB subnet was present, but no controller service answered at \(candidates.joined(separator: ", ")). Check the USB networking mode and try again."
        }
    }
}

final class SC2USBDiscovery {
    var onProgress: ((String) -> Void)?

    private struct Candidate {
        let host: String
        let interfaceName: String
        let localAddress: String
    }

    private let queue = DispatchQueue(label: "parrotlab.sc2-usb-discovery")
    private var discoveryID: UUID?
    private var activeConnection: NWConnection?

    func discover(completion: @escaping (Result<SC2USBDiscoveryResult, Error>) -> Void) {
        let identifier = UUID()
        queue.async { [weak self] in
            guard let self else { return }
            self.activeConnection?.cancel()
            self.activeConnection = nil
            self.discoveryID = identifier
            let candidates = Self.usbCandidates()
            guard !candidates.isEmpty else {
                self.finish(.failure(SC2USBDiscoveryError.noUSBInterface), id: identifier, completion: completion)
                return
            }
            for candidate in candidates {
                self.report("SC2 USB candidate: \(candidate.interfaceName) local \(candidate.localAddress) → \(candidate.host)")
            }
            self.probe(candidates: candidates, candidateIndex: 0, serviceIndex: 0, id: identifier, completion: completion)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.discoveryID = nil
            self?.activeConnection?.cancel()
            self?.activeConnection = nil
        }
    }

    private func probe(
        candidates: [Candidate],
        candidateIndex: Int,
        serviceIndex: Int,
        id: UUID,
        completion: @escaping (Result<SC2USBDiscoveryResult, Error>) -> Void
    ) {
        guard discoveryID == id else { return }
        let services: [(UInt16, String)] = [(23, "Telnet"), (21, "FTP"), (44_444, "ARDiscovery")]
        guard candidateIndex < candidates.count else {
            finish(
                .failure(SC2USBDiscoveryError.controllerNotReachable(candidates.map(\.host))),
                id: id,
                completion: completion
            )
            return
        }
        if serviceIndex >= services.count {
            probe(
                candidates: candidates,
                candidateIndex: candidateIndex + 1,
                serviceIndex: 0,
                id: id,
                completion: completion
            )
            return
        }

        let candidate = candidates[candidateIndex]
        let service = services[serviceIndex]
        guard let port = NWEndpoint.Port(rawValue: service.0) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(candidate.host), port: port, using: .tcp)
        activeConnection = connection
        var completed = false
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.discoveryID == id, !completed else { return }
            completed = true
            connection.cancel()
            self.probe(
                candidates: candidates,
                candidateIndex: candidateIndex,
                serviceIndex: serviceIndex + 1,
                id: id,
                completion: completion
            )
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.discoveryID == id, !completed else { return }
            switch state {
            case .ready:
                completed = true
                timeout.cancel()
                connection.cancel()
                let result = SC2USBDiscoveryResult(
                    host: candidate.host,
                    interfaceName: candidate.interfaceName,
                    localAddress: candidate.localAddress,
                    serviceName: service.1,
                    servicePort: service.0
                )
                self.finish(.success(result), id: id, completion: completion)
            case .failed:
                completed = true
                timeout.cancel()
                connection.cancel()
                self.probe(
                    candidates: candidates,
                    candidateIndex: candidateIndex,
                    serviceIndex: serviceIndex + 1,
                    id: id,
                    completion: completion
                )
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 1, execute: timeout)
    }

    private func finish(
        _ result: Result<SC2USBDiscoveryResult, Error>,
        id: UUID,
        completion: @escaping (Result<SC2USBDiscoveryResult, Error>) -> Void
    ) {
        guard discoveryID == id else { return }
        discoveryID = nil
        activeConnection?.cancel()
        activeConnection = nil
        DispatchQueue.main.async { completion(result) }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onProgress?(message) }
    }

    private static func usbCandidates() -> [Candidate] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var results: [Candidate] = []
        var seen = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entryPointer = cursor {
            let entry = entryPointer.pointee
            defer { cursor = entry.ifa_next }
            guard let addressPointer = entry.ifa_addr,
                  addressPointer.pointee.sa_family == sa_family_t(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0,
                  (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let localAddress = ipv4String(addressPointer) else { continue }

            let components = localAddress.split(separator: ".")
            guard components.count == 4,
                  components[0] == "192", components[1] == "168", components[2] == "53" else {
                continue
            }
            let host = "\(components[0]).\(components[1]).\(components[2]).1"
            guard host != localAddress else { continue }
            let interfaceName = String(cString: entry.ifa_name)
            let key = "\(interfaceName)|\(host)"
            guard seen.insert(key).inserted else { continue }
            results.append(Candidate(host: host, interfaceName: interfaceName, localAddress: localAddress))
        }
        return results.sorted {
            if $0.host != $1.host { return $0.host < $1.host }
            return $0.interfaceName < $1.interfaceName
        }
    }

    private static func ipv4String(_ pointer: UnsafeMutablePointer<sockaddr>) -> String? {
        var address = UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }
}
