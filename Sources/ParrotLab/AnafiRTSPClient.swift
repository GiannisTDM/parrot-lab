import Foundation
import Network

final class AnafiCallbackEpoch {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func advance() -> UInt64 { lock.lock(); defer { lock.unlock() }; value &+= 1; return value }
    func contains(_ candidate: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return candidate == value }
    func retire(_ candidate: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard candidate == value else { return nil }
        value &+= 1; return value
    }
    func deliver(_ candidate: UInt64, _ action: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in if self?.contains(candidate) == true { action() } }
    }
}

enum AnafiRTSPItem: Equatable {
    case response(Int, [String: String], Data)
    case packet(UInt8, Data)
}

/// RTSP responses and interleaved RTP can arrive fragmented, coalesced, or in
/// the same TCP read. Parse lengths before consuming; never search RTP bytes
/// for text delimiters. Bound response buffering independently of video.
struct AnafiRTSPParser {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [AnafiRTSPItem] {
        buffer.append(data)
        var items: [AnafiRTSPItem] = []
        while !buffer.isEmpty {
            if buffer.first == 0x24 {
                guard buffer.count >= 4 else { break }
                let channel = buffer[1]
                let count = Int(buffer[2]) << 8 | Int(buffer[3])
                guard buffer.count >= count + 4 else { break }
                items.append(.packet(channel, buffer.subdata(in: 4..<(count + 4))))
                buffer = Data(buffer.dropFirst(count + 4))
            } else {
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 32_768 { throw error("RTSP response headers are too large") }
                    break
                }
                guard let text = String(data: buffer.prefix(end.lowerBound), encoding: .utf8) else {
                    throw error("Invalid RTSP response")
                }
                let lines = text.components(separatedBy: "\r\n")
                let statusParts = (lines.first ?? "").split(separator: " ")
                guard statusParts.first == "RTSP/1.0", statusParts.count >= 2,
                      let status = Int(statusParts[1]) else { throw error("Invalid RTSP status") }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                }
                let length: Int
                if let value = headers["content-length"] {
                    guard let count = Int(value), (0...262_144).contains(count) else { throw error("Invalid RTSP content length") }
                    length = count
                } else { length = 0 }
                let total = end.upperBound + length
                guard buffer.count >= total else { break }
                items.append(.response(status, headers, buffer.subdata(in: end.upperBound..<total)))
                buffer = Data(buffer.dropFirst(total))
            }
        }
        guard buffer.count <= 300_000 else { throw error("RTSP receive buffer exceeded its limit") }
        return items
    }
    private func error(_ message: String) -> NSError {
        NSError(domain: "ParrotLab.AnafiRTSP", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct AnafiSDP {
    let controlURL: URL
    let parameterSets: [Data]
    let payloadType: UInt8
    init?(body: Data, base: URL) {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var inVideo = false
        var pt: UInt8?
        var control: String?
        var parameters: [Data] = []
        for line in lines {
            if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video ") }
            guard inVideo else { continue }
            if line.hasPrefix("a=rtpmap:"), line.uppercased().contains("H264/90000") {
                pt = UInt8(line.dropFirst(9).split(separator: " ").first ?? "")
            }
            if line.hasPrefix("a=control:") { control = String(line.dropFirst(10)) }
            if line.hasPrefix("a=fmtp:"), let range = line.range(of: "sprop-parameter-sets=") {
                let value = line[range.upperBound...].split(separator: ";").first ?? ""
                parameters = value.split(separator: ",").compactMap { Data(base64Encoded: String($0).trimmingCharacters(in: .whitespaces)) }
            }
        }
        guard let pt, let control, control != "*" else { return nil }
        let url: URL?
        if control.hasPrefix("rtsp://"), let original = URL(string: control) {
            url = Self.rebase(original, onto: base)
        }
        else {
            let directory = base.absoluteString.hasSuffix("/") ? base : URL(string: base.absoluteString + "/")!
            url = URL(string: control, relativeTo: directory)?.absoluteURL
        }
        // A remote SDP cannot redirect the app to another host/protocol.
        guard let url, url.scheme == "rtsp", url.host == base.host,
              (url.port ?? 554) == (base.port ?? 554) else { return nil }
        controlURL = url; parameterSets = parameters; payloadType = pt
    }
    /// A proxied drone may advertise its own authority in Content-Base or
    /// track control. Keep its path, but always connect to the selected route.
    static func rebase(_ advertised: URL, onto endpoint: URL) -> URL? {
        guard advertised.scheme == "rtsp", var parts = URLComponents(url: advertised, resolvingAgainstBaseURL: true) else { return nil }
        parts.host = endpoint.host; parts.port = endpoint.port; parts.user = nil; parts.password = nil
        return parts.url
    }
}

/// Native TCP-interleaved RTSP feeding the existing RTP, VideoToolbox/Metal and
/// recording pipeline. No external player or debug service is involved.
final class AnafiRTSPClient {
    var onAccessUnit: ((H264AccessUnit) -> Void)?
    var onStats: ((RTPVideoStats) -> Void)?
    var onState: ((String, Bool) -> Void)?
    private let queue = DispatchQueue(label: "parrotlab.anafi.rtsp", qos: .userInitiated)
    private let epochs = AnafiCallbackEpoch()
    private let receiver = RTPH264Receiver()
    private var epoch: UInt64 = 0
    private var connection: NWConnection?
    private var parser = AnafiRTSPParser()
    private var url: URL?
    private var sdp: AnafiSDP?
    private var session: String?
    private var cseq = 0
    private var pending: (sequence: Int, method: String, sent: TimeInterval)?
    private var timer: DispatchSourceTimer?
    private var playing = false
    private var rtpChannel: UInt8 = 0
    private var lastPacket: TimeInterval = 0
    private var lastKeepalive: TimeInterval = 0
    private var timeoutInterval: TimeInterval = 60
    private var parameterSetsNeeded = true

    func start(url: URL) {
        let token = epochs.advance()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token) else { return }
            self.closeLocked(); self.epoch = token
            guard url.scheme == "rtsp", let host = url.host,
                  AnafiRoute.validHost(host), let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 554)) else {
                self.publish("Invalid ANAFI video address", false); return
            }
            self.url = url
            self.receiver.startMux()
            self.receiver.onAccessUnit = { [weak self] unit in
                guard let self, self.epochs.contains(token) else { return }
                self.onAccessUnit?(unit)
            }
            self.receiver.onStats = { [weak self] stats in
                guard let self, self.epochs.contains(token) else { return }; self.onStats?(stats)
            }
            let connection = NWConnection(host: .init(host), port: port, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection, self.epochs.contains(token), self.connection === connection else { return }
                switch state {
                case .ready: self.request("DESCRIBE", url: url, headers: ["Accept": "application/sdp"]); self.receive(token)
                case .failed(let error): self.fail(error.localizedDescription)
                default: break
                }
            }
            self.publish("Opening ANAFI live video…", false)
            self.lastPacket = ProcessInfo.processInfo.systemUptime
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick(token) }
            self.timer = timer; timer.resume()
            connection.start(queue: self.queue)
        }
    }
    func stop() {
        let token = epochs.advance()
        queue.async { [weak self] in
            guard let self, self.epochs.contains(token) else { return }
            // Best effort; closing TCP also releases the server's RTSP session.
            if self.playing, let url = self.url { self.request("TEARDOWN", url: url) }
            self.closeLocked(); self.epoch = token; self.publish("Video stopped", false)
        }
    }
    func stopAndWait() { stop(); queue.sync {} }
    private func closeLocked() {
        timer?.cancel(); timer = nil
        connection?.cancel(); connection = nil
        receiver.stop(); receiver.onAccessUnit = nil; receiver.onStats = nil
        parser = AnafiRTSPParser(); url = nil; sdp = nil; session = nil
        cseq = 0; pending = nil; playing = false; rtpChannel = 0
        timeoutInterval = 60; parameterSetsNeeded = true
    }
    private func request(_ method: String, url: URL, headers: [String: String] = [:]) {
        guard let connection else { return }
        cseq += 1
        var text = "\(method) \(url.absoluteString) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: ParrotLab\r\n"
        if let session { text += "Session: \(session)\r\n" }
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        pending = (cseq, method, ProcessInfo.processInfo.systemUptime)
        let token = epoch
        connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, self.epochs.contains(token) else { return }
            if let error { self.fail(error.localizedDescription) }
        })
    }
    private func receive(_ token: UInt64) {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.epochs.contains(token), self.connection === connection else { return }
            do {
                if let data {
                    for item in try self.parser.append(data) {
                        guard self.connection === connection else { return }
                        self.consume(item)
                    }
                }
            } catch { self.fail(error.localizedDescription); return }
            if let error { self.fail(error.localizedDescription); return }
            if complete { self.fail("ANAFI video connection closed"); return }
            self.receive(token)
        }
    }
    private func consume(_ item: AnafiRTSPItem) {
        switch item {
        case .packet(let channel, var packet):
            guard playing, channel == rtpChannel, packet.count >= 12, let sdp,
                  packet[1] & 0x7f == sdp.payloadType else { return }
            lastPacket = ProcessInfo.processInfo.systemUptime
            // The shared receiver expects payload type 96.
            packet[1] = (packet[1] & 0x80) | 96
            if parameterSetsNeeded, !sdp.parameterSets.isEmpty {
                parameterSetsNeeded = false
                let unit = H264AccessUnit(nalUnits: sdp.parameterSets, rtpTimestamp: 0, rtpHeaderExtensions: [])
                let token = epoch
                epochs.deliver(token) { [weak self] in self?.onAccessUnit?(unit) }
            }
            receiver.consumeMuxPacket(packet)
        case .response(let code, let headers, let body):
            guard let current = pending, Int(headers["cseq"] ?? "") == current.sequence, let url else {
                fail("Unexpected RTSP response sequence"); return
            }
            pending = nil
            guard (200...299).contains(code) else { fail("RTSP \(current.method) returned \(code)"); return }
            switch current.method {
            case "DESCRIBE":
                let advertised = headers["content-base"].flatMap(URL.init(string:)) ?? url
                guard let base = AnafiSDP.rebase(advertised, onto: url),
                      let sdp = AnafiSDP(body: body, base: base) else { fail("ANAFI did not offer a valid H.264 video track"); return }
                self.sdp = sdp
                request("SETUP", url: sdp.controlURL, headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"])
            case "SETUP":
                guard let value = headers["session"], let identifier = value.split(separator: ";").first,
                      let transport = headers["transport"], transport.uppercased().contains("RTP/AVP/TCP"),
                      let range = transport.range(of: "interleaved="),
                      let channel = UInt8(transport[range.upperBound...].split(separator: "-").first ?? "") else {
                    fail("ANAFI did not accept TCP video transport"); return
                }
                session = String(identifier); rtpChannel = channel
                if let range = value.range(of: "timeout="), let seconds = Double(value[range.upperBound...].split(separator: ";").first ?? "") {
                    timeoutInterval = max(4, min(120, seconds))
                }
                request("PLAY", url: url, headers: ["Range": "npt=0.000-"])
            case "PLAY":
                playing = true; lastPacket = ProcessInfo.processInfo.systemUptime; lastKeepalive = lastPacket
                publish("Live ANAFI video", true)
            default: break
            }
        }
    }
    private func tick(_ token: UInt64) {
        guard epochs.contains(token), connection != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let pending, now - pending.sent > 8 { fail("RTSP \(pending.method) timed out"); return }
        if now - lastPacket > 12 { fail("ANAFI video stopped responding; reconnect video"); return }
        if playing, pending == nil, now - lastKeepalive > timeoutInterval / 2, let url {
            lastKeepalive = now; request("OPTIONS", url: url)
        }
    }
    private func publish(_ message: String, _ live: Bool) {
        epochs.deliver(epoch) { [weak self] in self?.onState?(message, live) }
    }
    private func fail(_ message: String) {
        guard let token = epochs.retire(epoch) else { return }
        closeLocked(); epoch = token; publish(message, false)
    }
    deinit { timer?.cancel(); connection?.cancel(); receiver.stop() }
}
