import Foundation
import Network

enum RestreamVideoCodec: String, Equatable {
    case h264
    case jpeg
}

struct RestreamDescriptor: Equatable {
    let requestPort: UInt16
    let videoAddress: String?
    let videoPort: UInt16?
    let payloadType: UInt8?
    let codec: RestreamVideoCodec?
    let clockRate: Int?
    let response: String
}

final class RestreamProbe {
    var onDebug: ((String) -> Void)?

    private let queue = DispatchQueue(label: "parrotlab.restream-probe")
    private let queueKey = DispatchSpecificKey<Void>()
    private var connection: NWConnection?
    private var activeProbeID: UUID?
    private let callbackLock = NSLock()
    private var callbackProbeID: UUID?

    init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    func probe(host: String, ports: [UInt16] = [7711, 6007], completion: @escaping (Result<RestreamDescriptor, Error>) -> Void) {
        withQueueSync {
            cancelLocked()
            let probeID = UUID()
            activeProbeID = probeID
            callbackLock.lock()
            callbackProbeID = probeID
            callbackLock.unlock()
            probe(host: host, remainingPorts: ports, lastError: nil, probeID: probeID, completion: completion)
        }
    }

    func cancel() {
        withQueueSync { cancelLocked() }
    }

    private func cancelLocked() {
        activeProbeID = nil
        callbackLock.lock()
        callbackProbeID = nil
        callbackLock.unlock()
        connection?.cancel()
        connection = nil
    }

    private func withQueueSync(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { operation() }
        else { queue.sync(execute: operation) }
    }

    private func probe(
        host: String,
        remainingPorts: [UInt16],
        lastError: Error?,
        probeID: UUID,
        completion: @escaping (Result<RestreamDescriptor, Error>) -> Void
    ) {
        guard activeProbeID == probeID else { return }
        guard let port = remainingPorts.first else {
            let error = lastError ?? NSError(
                domain: "ParrotLab.Restream",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No SC2 restream endpoint responded"]
            )
            activeProbeID = nil
            connection = nil
            dispatchCompletion(.failure(error), id: probeID, completion: completion)
            return
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            probe(host: host, remainingPorts: Array(remainingPorts.dropFirst()), lastError: lastError, probeID: probeID, completion: completion)
            return
        }

        debug("Probing SC2 video endpoint \(host):\(port)")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        self.connection = connection
        var response = Data()
        var completed = false

        func tryNext(_ error: Error) {
            guard !completed, self.activeProbeID == probeID else { return }
            completed = true
            connection.cancel()
            self.connection = nil
            self.probe(
                host: host,
                remainingPorts: Array(remainingPorts.dropFirst()),
                lastError: error,
                probeID: probeID,
                completion: completion
            )
        }

        func finish(_ result: Result<RestreamDescriptor, Error>) {
            guard !completed, self.activeProbeID == probeID else { return }
            completed = true
            connection.cancel()
            self.connection = nil
            self.activeProbeID = nil
            dispatchCompletion(result, id: probeID, completion: completion)
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data { response.append(data) }
                guard response.count <= 1_048_576 else {
                    tryNext(NSError(
                        domain: "ParrotLab.Restream",
                        code: Int(port),
                        userInfo: [NSLocalizedDescriptionKey: "Oversized response from port \(port)"]
                    ))
                    return
                }
                if let error {
                    self.debug("Port \(port) did not respond: \(error.localizedDescription)")
                    tryNext(error)
                    return
                }
                let currentText = String(data: response, encoding: .utf8) ?? ""
                if isComplete || currentText.range(of: #"m=video\s+\d+"#, options: .regularExpression) != nil {
                    let text = String(data: response, encoding: .utf8) ?? ""
                    guard text.contains("200") || text.contains("m=video") else {
                        let error = NSError(
                            domain: "ParrotLab.Restream",
                            code: Int(port),
                            userInfo: [NSLocalizedDescriptionKey: "Unexpected response from port \(port)"]
                        )
                        tryNext(error)
                        return
                    }
                    let descriptor = Self.descriptor(from: text, requestPort: port)
                    self.debug("SC2 restream endpoint answered on port \(port)")
                    finish(.success(descriptor))
                    return
                }
                receive()
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET /video HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if let error { tryNext(error) }
                    else { receive() }
                })
            case .failed(let error):
                self.debug("Port \(port) failed: \(error.localizedDescription)")
                tryNext(error)
            default:
                break
            }
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + 2.0) {
            guard !completed, self.activeProbeID == probeID else { return }
            self.debug("Port \(port) timed out")
            tryNext(NSError(
                    domain: "ParrotLab.Restream",
                    code: Int(port),
                    userInfo: [NSLocalizedDescriptionKey: "Port \(port) timed out"]
                ))
        }
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }

    static func descriptor(from response: String, requestPort: UInt16) -> RestreamDescriptor {
        let payload = firstCapture(#"m=video\s+\d+\s+RTP/AVP\s+(\d+)"#, in: response).flatMap(UInt8.init)
        var codec: RestreamVideoCodec?
        var clockRate: Int?
        if let payload {
            let pattern = #"a=rtpmap:\#(payload)\s+([^\s/]+)/([0-9]+)"#
            if let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = expression.firstMatch(
                in: response,
                range: NSRange(response.startIndex..<response.endIndex, in: response)
               ), match.numberOfRanges >= 3,
               let codecRange = Range(match.range(at: 1), in: response),
               let rateRange = Range(match.range(at: 2), in: response) {
                switch response[codecRange].uppercased() {
                case "H264": codec = .h264
                case "JPEG", "MJPEG": codec = .jpeg
                default: codec = nil
                }
                clockRate = Int(response[rateRange])
            }
            // RTP payload type 26 is the RFC 2435 static JPEG assignment and
            // does not require an rtpmap attribute.
            if payload == 26, codec == nil {
                codec = .jpeg
                clockRate = 90_000
            }
        }
        return RestreamDescriptor(
            requestPort: requestPort,
            videoAddress: firstCapture(#"c=IN IP4\s+([^\s\r\n]+)"#, in: response),
            videoPort: firstCapture(#"m=video\s+(\d+)"#, in: response).flatMap(UInt16.init),
            payloadType: payload,
            codec: codec,
            clockRate: clockRate,
            response: response
        )
    }

    private func debug(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onDebug?(message) }
    }

    private func dispatchCompletion(
        _ result: Result<RestreamDescriptor, Error>,
        id: UUID,
        completion: @escaping (Result<RestreamDescriptor, Error>) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callbackLock.lock()
            let isCurrent = self.callbackProbeID == id
            self.callbackLock.unlock()
            guard isCurrent else { return }
            completion(result)
        }
    }
}
