import Foundation
import CryptoKit
import Darwin

enum SC3SumoVideoOperation: String { case status, check, install, restore }

struct SC3SumoVideoAssets {
    struct Entry: Decodable { let size: Int; let sha256: String; let sha1: String }
    struct Manifest: Decodable { let version: Int; let files: [String: Entry] }
    static let names: Set<String> = ["libsc3-sumo-native-v2f.so", "startup-v1c.sh", "startup-video.sh", "persist-video.sh"]
    let files: [String: Data]
    let hashes: [String: String]

    static func load(directory: URL? = nil) throws -> Self {
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/SC3SumoVideo")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("DeviceTools/SC3SumoVideo")
        let location = directory ?? (bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? development)
        let manifestURL = location.appendingPathComponent("manifest.json")
        guard (try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8192 else {
            throw SC3VideoMaintenanceError("The SC3 video manifest is too large")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1, Set(manifest.files.keys) == names else {
            throw SC3VideoMaintenanceError("The SC3 video package is incomplete")
        }
        var files: [String: Data] = [:], hashes: [String: String] = [:]
        for name in names {
            guard let entry = manifest.files[name], (1...131_072).contains(entry.size) else {
                throw SC3VideoMaintenanceError("Invalid SC3 video asset size")
            }
            let url = location.appendingPathComponent(name)
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == entry.size else {
                throw SC3VideoMaintenanceError("SC3 video asset size mismatch: \(name)")
            }
            let data = try Data(contentsOf: url)
            let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let sha1 = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard sha256 == entry.sha256, sha1 == entry.sha1 else {
                throw SC3VideoMaintenanceError("SC3 video asset checksum mismatch: \(name)")
            }
            files[name] = data; hashes[name] = sha1
        }
        return Self(files: files, hashes: hashes)
    }
}

struct SC3VideoMaintenanceError: LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}

/// Minimal ADB smart-socket client. Talks only to an existing loopback server;
/// it contains no daemon start/kill/version-negotiation or pairing operations.
/// ADB carries maintenance files/commands, never the video stream.
final class SC3ADBSocket {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SC3VideoMaintenanceError("Could not open the maintenance connection") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let flags = fcntl(fd, F_GETFL); _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var error: Int32 = 0, errorSize = socklen_t(MemoryLayout<Int32>.size)
        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard (result == 0 || errno == EINPROGRESS), poll(&pollFD, 1, 500) > 0,
              getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &errorSize) == 0, error == 0 else {
            Darwin.close(fd); closed = true
            throw SC3VideoMaintenanceError("No existing SC3 maintenance server on localhost:\(port). Open the existing ADB connection first.")
        }
        _ = fcntl(fd, F_SETFL, flags)
        var timeout = timeval(tv_sec: 5, tv_usec: 0), one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    func cancel() { lock.withLock { if !closed { _ = shutdown(fd, SHUT_RDWR) } } }
    func close() { lock.withLock { if !closed { closed = true; Darwin.close(fd) } } }
    deinit { close() }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SC3VideoMaintenanceError("SC3 maintenance write failed or timed out") }
                offset += count
            }
        }
    }
    func read(_ size: Int) throws -> Data {
        guard (0...524_288).contains(size) else { throw SC3VideoMaintenanceError("Invalid maintenance packet size") }
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < size {
                let count = recv(fd, bytes.baseAddress!.advanced(by: offset), size - offset, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SC3VideoMaintenanceError("SC3 maintenance read failed, closed or timed out") }
                offset += count
            }
        }
        return data
    }
    func lengthString() throws -> String {
        let header = try read(4)
        guard let value = String(data: header, encoding: .ascii), let size = Int(value, radix: 16), size <= 8192,
              let text = String(data: try read(size), encoding: .utf8) else {
            throw SC3VideoMaintenanceError("Malformed maintenance server response")
        }
        return text
    }
    func service(_ text: String) throws {
        let bytes = Data(text.utf8)
        guard bytes.count <= 65_535 else { throw SC3VideoMaintenanceError("Maintenance request too large") }
        try write(Data(String(format: "%04x", bytes.count).utf8) + bytes)
        let status = try read(4)
        if status == Data("FAIL".utf8) { throw SC3VideoMaintenanceError(try lengthString()) }
        guard status == Data("OKAY".utf8) else { throw SC3VideoMaintenanceError("Malformed maintenance acknowledgement") }
    }
    func stream() throws -> Data {
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = recv(fd, &bytes, bytes.count, 0)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard count >= 0 else { throw SC3VideoMaintenanceError("SC3 maintenance connection lost. Use Show Status before retrying; changes may have completed.") }
            if count == 0 { return result }
            guard result.count + count <= 131_072 else { throw SC3VideoMaintenanceError("Maintenance output exceeded its limit") }
            result.append(contentsOf: bytes.prefix(count))
        }
        throw SC3VideoMaintenanceError("SC3 maintenance timed out. Use Show Status before retrying.")
    }
    static func syncPacket(_ name: String, _ value: UInt32) -> Data {
        var result = Data(name.utf8); result.appendAnafiLE(value); return result
    }
}

final class SC3SumoVideoInstaller {
    private let queue = DispatchQueue(label: "parrotlab.sc3.video.install", qos: .utility)
    private let lock = NSLock()
    private var token: UUID?
    private var callbackGeneration: UInt64 = 0
    private var current: SC3ADBSocket?
    var isBusy: Bool { lock.withLock { token != nil } }
    func cancel() { lock.withLock { callbackGeneration &+= 1; token = nil; current?.cancel() } }
    func finishPendingForSelfTest() { queue.sync {} }

    @discardableResult
    func perform(_ operation: SC3SumoVideoOperation, host: String, serverPorts: [UInt16] = [5038, 5037],
                 assets: SC3SumoVideoAssets? = nil, completion: @escaping (Result<String, Error>) -> Void) -> Bool {
        let identity = UUID()
        guard SC3SumoRelay.isValidHost(host) else { return false }
        let generation = lock.withLock { () -> UInt64? in
            guard token == nil else { return nil }
            callbackGeneration &+= 1; token = identity; return callbackGeneration
        }
        guard let generation else { return false }
        queue.async { [weak self] in
            guard let self else { return }
            let result: Result<String, Error>
            do { result = .success(try self.run(operation, host: host, ports: serverPorts, assets: assets ?? SC3SumoVideoAssets.load(), identity: identity)) }
            catch { result = .failure(error) }
            let deliver = self.lock.withLock { () -> Bool in
                self.current?.close(); self.current = nil
                guard self.token == identity else { return false }; self.token = nil; return true
            }
            if deliver {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lock.withLock({ self.callbackGeneration == generation }) else { return }
                    completion(result)
                }
            }
        }
        return true
    }
    private func check(_ identity: UUID) throws {
        guard lock.withLock({ token == identity }) else { throw SC3VideoMaintenanceError("SC3 video operation cancelled") }
    }
    private func socket(_ port: UInt16, identity: UUID) throws -> SC3ADBSocket {
        try check(identity)
        let socket = try SC3ADBSocket(port: port)
        lock.withLock { current = socket }
        do { try check(identity) } catch { socket.close(); throw error }
        return socket
    }
    private func select(_ socket: SC3ADBSocket, host: String) throws {
        try socket.service("host:transport:\(host):9050")
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func shell(_ command: String, host: String, port: UInt16, identity: UUID) throws -> String {
        let socket = try socket(port, identity: identity); defer { socket.close() }
        try select(socket, host: host)
        let marker = "PL_SC3_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try socket.service("shell:( \(command) ); task_status=$?; printf '\\n\(marker)=%d\\n' \"$task_status\"")
        let data = try socket.stream()
        try check(identity)
        guard let text = String(data: data, encoding: .utf8), let range = text.range(of: "\n\(marker)=", options: .backwards),
              let status = Int(text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SC3VideoMaintenanceError("SC3 did not confirm completion. Use Show Status before retrying.")
        }
        let output = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else { throw SC3VideoMaintenanceError(output.isEmpty ? "SC3 refused the video operation (\(status))" : output) }
        return output
    }
    private func upload(_ data: Data, path: String, host: String, port: UInt16, identity: UUID) throws {
        let socket = try socket(port, identity: identity); defer { socket.close() }
        try select(socket, host: host); try socket.service("sync:")
        let name = Data("\(path),33152".utf8) // regular file, 0600
        try socket.write(SC3ADBSocket.syncPacket("SEND", UInt32(name.count)) + name)
        var offset = 0
        while offset < data.count {
            try check(identity)
            let end = min(data.count, offset + 65_536), part = data.subdata(in: offset..<end)
            try socket.write(SC3ADBSocket.syncPacket("DATA", UInt32(part.count)) + part); offset = end
        }
        try socket.write(SC3ADBSocket.syncPacket("DONE", 0))
        let response = try socket.read(8)
        guard response == SC3ADBSocket.syncPacket("OKAY", 0) else { throw SC3VideoMaintenanceError("SC3 maintenance upload failed") }
        try socket.write(SC3ADBSocket.syncPacket("QUIT", 0))
    }
    private func run(_ operation: SC3SumoVideoOperation, host: String, ports: [UInt16], assets: SC3SumoVideoAssets, identity: UUID) throws -> String {
        var selected: UInt16?, error: Error = SC3VideoMaintenanceError("Open the existing SC3 ADB maintenance connection first")
        for port in ports {
            try check(identity)
            do {
                let connection = try socket(port, identity: identity); defer { connection.close() }
                try connection.service("host:connect:\(host):9050")
                _ = try connection.lengthString(); selected = port; break
            } catch let failure { error = failure }
        }
        guard let port = selected else { throw error }
        let stage = "/tmp/parrotlab-sc3-video-" + identity.uuidString
        _ = try shell("umask 077; mkdir \(Self.quote(stage))", host: host, port: port, identity: identity)
        defer {
            if lock.withLock({ token == identity }) {
                let paths = SC3SumoVideoAssets.names.sorted().map { Self.quote(stage + "/" + $0) }.joined(separator: " ")
                _ = try? shell("rm -f \(paths); rmdir \(Self.quote(stage))", host: host, port: port, identity: identity)
            }
        }
        for name in SC3SumoVideoAssets.names.sorted() {
            guard let data = assets.files[name] else { throw SC3VideoMaintenanceError("Missing SC3 package file") }
            try upload(data, path: stage + "/" + name, host: host, port: port, identity: identity)
        }
        guard let helper = assets.hashes["persist-video.sh"], let wrapper = assets.hashes["startup-video.sh"] else {
            throw SC3VideoMaintenanceError("Missing SC3 package checksums")
        }
        let path = Self.quote(stage + "/persist-video.sh")
        let verify = "test \"$(sha1sum \(path) | cut -d ' ' -f 1)\" = \(Self.quote(helper))"
        return try shell("\(verify) && sh \(path) \(operation.rawValue) \(Self.quote(stage)) \(Self.quote(wrapper))", host: host, port: port, identity: identity)
    }
}
