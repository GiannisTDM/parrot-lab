import Foundation
import Darwin

enum SC3SumoVideoInstallerSelfTest {
    static func run() -> Bool {
        do {
            let assets = try SC3SumoVideoAssets.load()
            guard assets.files.count == 4, assets.hashes["startup-v1c.sh"] == "0be1f74b8829fb66d07a8401fd7330b4a5016d87",
                  assets.hashes["libsc3-sumo-native-v2f.so"] == "e18ff6ef07d172e53886e02a4f23118da7e0a1a5",
                  SC3SumoVideoInstaller.quote("a'b") == "'a'\\''b'" else { return false }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SC3-assets-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data("{\"version\":1,\"files\":{}}".utf8).write(to: directory.appendingPathComponent("manifest.json"))
            do { _ = try SC3SumoVideoAssets.load(directory: directory); return false } catch {}
            guard try workflow(assets, failure: .none), try workflow(assets, failure: .badAcknowledgement),
                  try workflow(assets, failure: .remoteFailure), try workflow(assets, failure: .oversizedOutput) else { return false }
            let fixture = try SC3VideoADBFake()
            defer { fixture.stop() }
            let installer = SC3SumoVideoInstaller()
            var called = false
            guard installer.perform(.status, host: "127.0.0.1", serverPorts: [fixture.port], assets: assets,
                                    completion: { _ in called = true }) else { return false }
            installer.cancel(); installer.finishPendingForSelfTest()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            guard !called, !installer.isBusy, !fixture.commands.contains(where: { $0.contains("&& sh ") }) else { return false }
            // Retire a completion already queued behind this blocked main loop.
            guard installer.perform(.status, host: "127.0.0.1", serverPorts: [fixture.port], assets: assets,
                                    completion: { _ in called = true }) else { return false }
            installer.finishPendingForSelfTest(); installer.cancel()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            return !called && !installer.isBusy
        } catch { fputs("SC3 video installer self-test: \(error)\n", stderr); return false }
    }
    private static func workflow(_ assets: SC3SumoVideoAssets, failure: SC3VideoADBFake.Failure) throws -> Bool {
        let fixture = try SC3VideoADBFake(failure: failure); defer { fixture.stop() }
        let installer = SC3SumoVideoInstaller()
        var result: Result<String, Error>?
        guard installer.perform(.install, host: "127.0.0.1", serverPorts: [fixture.port], assets: assets,
                                completion: { result = $0 }) else { return false }
        guard !installer.perform(.restore, host: "127.0.0.1", serverPorts: [fixture.port], assets: assets,
                                 completion: { _ in }) else { return false }
        let end = Date().addingTimeInterval(8)
        while result == nil, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard let result, !installer.isBusy else { installer.cancel(); return false }
        switch result {
        case .success(let text):
            guard failure == .none, text.contains("video_startup=enabled"),
                  fixture.files.count == 4 else { return false }
            for (path, data) in fixture.files {
                guard assets.files[URL(fileURLWithPath: path).lastPathComponent] == data else { return false }
            }
        case .failure(let error):
            guard failure != .none else { fputs("SC3 mock install: \(error)\n", stderr); return false }
            if failure == .remoteFailure, !error.localizedDescription.contains("fixture refusal") { return false }
        }
        return fixture.services.allSatisfy {
            $0.hasPrefix("host:connect:127.0.0.1:9050") || $0.hasPrefix("host:transport:127.0.0.1:9050") || $0 == "sync:" || $0.hasPrefix("shell:")
        }
    }
}

private final class SC3VideoADBFake {
    enum Failure { case none, badAcknowledgement, remoteFailure, oversizedOutput }
    let port: UInt16
    private let fd: Int32
    private let queue = DispatchQueue(label: "parrotlab.sc3.adb.fixture")
    private let lock = NSLock()
    private var active = true, client: Int32 = -1
    private var stored: [String: Data] = [:], requests: [String] = [], shells: [String] = []
    private let failure: Failure
    var files: [String: Data] { lock.withLock { stored } }
    var services: [String] { lock.withLock { requests } }
    var commands: [String] { lock.withLock { shells } }
    init(failure: Failure = .none) throws {
        self.failure = failure
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        fd = descriptor
        guard descriptor >= 0 else { throw SC3VideoMaintenanceError("mock socket") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard bound == 0, named == 0, listen(fd, 8) == 0 else { Darwin.close(fd); throw SC3VideoMaintenanceError("mock listen") }
        port = UInt16(bigEndian: address.sin_port)
        queue.async { [weak self] in self?.serve() }
    }
    func stop() {
        let closing = lock.withLock { () -> Bool in
            guard active else { return false }; active = false
            if client >= 0 { _ = shutdown(client, SHUT_RDWR) }
            return true
        }
        if closing { _ = shutdown(fd, SHUT_RDWR); Darwin.close(fd); queue.sync {} }
    }
    private func serve() {
        while lock.withLock({ active }) {
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { return }
            lock.withLock { client = connection }
            var timeout = timeval(tv_sec: 2, tv_usec: 0), one: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            handle(connection)
            lock.withLock { client = -1; Darwin.close(connection) }
        }
    }
    private func read(_ fd: Int32, _ size: Int) -> Data? {
        guard (0...131_072).contains(size) else { return nil }
        var data = Data(count: size), valid = true
        data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < size {
                let count = recv(fd, bytes.baseAddress!.advanced(by: offset), size - offset, 0)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { valid = false; break }; offset += count
            }
        }
        return valid ? data : nil
    }
    @discardableResult private func send(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                // Deliberately segment acknowledgements and output.
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), min(257, bytes.count - offset), 0)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return false }; offset += count
            }
            return true
        }
    }
    private func request(_ fd: Int32) -> String? {
        guard let header = read(fd, 4), let text = String(data: header, encoding: .ascii),
              let count = Int(text, radix: 16), let data = read(fd, count), let request = String(data: data, encoding: .utf8) else { return nil }
        lock.withLock { requests.append(request) }; return request
    }
    private func handle(_ fd: Int32) {
        guard let first = request(fd) else { return }
        if failure == .badAcknowledgement { send(fd, Data("NOPE".utf8)); return }
        guard send(fd, Data("OKAY".utf8)) else { return }
        if first.hasPrefix("host:connect:") {
            let value = Data("already connected".utf8)
            send(fd, Data(String(format: "%04x", value.count).utf8) + value); return
        }
        guard first.hasPrefix("host:transport:"), let second = request(fd), send(fd, Data("OKAY".utf8)) else { return }
        if second == "sync:" {
            var path = "", data = Data()
            while let header = read(fd, 8) {
                let kind = String(data: header.prefix(4), encoding: .ascii)
                let size = header.dropFirst(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                switch kind {
                case "SEND":
                    guard let bytes = read(fd, Int(size)), let name = String(data: bytes, encoding: .utf8), name.hasSuffix(",33152") else { return }
                    path = String(name.dropLast(6))
                case "DATA": guard let bytes = read(fd, Int(size)) else { return }; data.append(bytes)
                case "DONE": lock.withLock { stored[path] = data }; guard send(fd, SC3ADBSocket.syncPacket("OKAY", 0)) else { return }
                case "QUIT": return
                default: return
                }
            }
        } else if second.hasPrefix("shell:") {
            lock.withLock { shells.append(second) }
            guard let range = second.range(of: "PL_SC3_[A-F0-9]{32}", options: .regularExpression) else { return }
            let marker = String(second[range])
            let helper = second.contains("&& sh ")
            if helper, failure == .oversizedOutput { send(fd, Data(repeating: 65, count: 131_073)); return }
            let output = helper ? (failure == .remoteFailure ? "fixture refusal" : "video_startup=enabled\nnative_startup=enabled\nvideo_active=yes") : ""
            let code = helper && failure == .remoteFailure ? 7 : 0
            send(fd, Data((output + "\n" + marker + "=\(code)\n").utf8))
        }
    }
}
