import Foundation

/// Acknowledged, bounded script transfer through SC2's shell -> telnet -> Sumo.
/// No persistent controller changes or FTP forwarding. Only fixed app-owned
/// Sumo scripts and the supplied B29 staging asset use this channel.
final class SumoBridgeUploader {
    private let telnet = TelnetClient()
    private var timer: Timer?
    private var completion: ((Result<BebopToolInstallResult, Error>) -> Void)?
    private var commands: [String] = []
    private var nextIndex = 0
    private var shellReady = false
    private var marker = ""
    private var result: BebopToolInstallResult?
    private var lastACKAt: TimeInterval = 0
    private var deadline: TimeInterval = 0
    var onProgress: ((String) -> Void)?

    static func uploadCommands(data: Data, asset: BebopInstalledAsset, token: UUID, firstIndex: Int = 0) -> [String] {
        let prefix = "__SUMO_UPLOAD_\(token.uuidString)__="
        let stage = "/data/ftp/internal_000/.parrotlab-\(token.uuidString).sh"
        var commands = ["[ -x /bin/DragonStarter.sh ] && [ -d /data/ftp/internal_000 ] && : > \(stage) && echo \(prefix)\(firstIndex) || echo \(prefix)ERROR"]
        let bytes = Array(data)
        for start in stride(from: 0, to: bytes.count, by: 128) {
            let octal = bytes[start..<min(start + 128, bytes.count)].map { String(format: "\\0%03o", $0) }.joined()
            let index = firstIndex + commands.count
            commands.append("printf '%b' '\(octal)' >> \(stage) && echo \(prefix)\(index) || echo \(prefix)ERROR")
        }
        commands.append("D=$(md5sum \(stage)); D=${D%% *}; " +
            "if [ \"$D\" = \(asset.md5) ] && chmod 755 \(stage) && mv \(stage) \(asset.devicePath); then " +
            "echo \(prefix)\(firstIndex + commands.count); else echo \(prefix)ERROR; fi")
        return commands
    }

    func install(_ package: BebopToolPackage, bridgeHost: String, sumoHost: String,
                 completion: @escaping (Result<BebopToolInstallResult, Error>) -> Void) {
        guard self.completion == nil else { completion(.failure(BebopToolInstallerError.alreadyRunning)); return }
        do {
            let assets = try BebopToolInstaller.sumoAssets(package)
            let token = UUID()
            marker = "__SUMO_UPLOAD_\(token.uuidString)__="
            commands = []
            for (data, asset) in assets {
                commands += Self.uploadCommands(data: data, asset: asset, token: token, firstIndex: commands.count)
            }
            nextIndex = 0
            shellReady = false
            self.completion = completion
            result = BebopToolInstallResult(package: package, host: sumoHost, assets: assets.map { $0.1 })
            onProgress?("Uploading \(package.displayName) through SC2 \(bridgeHost):23 → Sumo \(sumoHost):23; verifying each remote MD5")
            telnet.onDebug = { [weak self] message in self?.onProgress?(message) }
            telnet.onLine = { [weak self] line in self?.receive(line) }
            telnet.onState = { [weak self] state in
                guard let self, self.completion != nil else { return }
                if case .failed(let message) = state { self.finish(.failure(BebopToolInstallerError.commandFailed(message))) }
                if state == .ready { self.shellReady = true }
                if state == .stopped, self.shellReady {
                    self.finish(.failure(BebopToolInstallerError.commandFailed("Sumo shell closed before the upload was verified. No device command was issued.")))
                }
            }
            lastACKAt = ProcessInfo.processInfo.systemUptime; deadline = lastACKAt + 900
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now > self.deadline || now - self.lastACKAt > 45 else { return }
                self.finish(.failure(BebopToolInstallerError.commandFailed("Sumo bridge upload timed out. No device command was issued.")))
            }
            telnet.connect(host: sumoHost, startupCommand: commands[0], viaSC2: bridgeHost)
        } catch { completion(.failure(error)) }
    }

    private func receive(_ line: String) {
        guard completion != nil, let payload = SC2TelemetryParser.deviceMarkerPayload(marker, in: line) else { return }
        if payload == "ERROR" {
            finish(.failure(BebopToolInstallerError.commandFailed("Sumo rejected the bridge upload or its checksum. Check /bin/DragonStarter.sh and internal_000 on Sumo.")))
            return
        }
        guard payload == String(nextIndex) else { return }
        lastACKAt = ProcessInfo.processInfo.systemUptime
        nextIndex += 1
        if nextIndex % 128 == 0 { onProgress?("Sumo upload: \(nextIndex)/\(commands.count) acknowledged blocks") }
        if nextIndex == commands.count, let result {
            finish(.success(result))
        } else if nextIndex < commands.count {
            telnet.sendCommand(commands[nextIndex])
        }
    }

    func cancel() { finish(.failure(BebopToolInstallerError.cancelled)) }

    private func finish(_ result: Result<BebopToolInstallResult, Error>) {
        guard let completion else { return }
        self.completion = nil
        timer?.invalidate()
        timer = nil
        telnet.stop()
        commands.removeAll()
        self.result = nil
        completion(result)
    }

    static func selfTest() -> Bool {
        let sample = Data([0, 10, 13, 39, 36, 255])
        let asset = BebopInstalledAsset(assetName: "start_sumo_b29.sh", remoteName: "start_sumo_b29.sh", byteCount: 6, sha256: "", md5: String(repeating: "a", count: 32))
        let commands = uploadCommands(data: sample, asset: asset, token: UUID())
        let binary = Data((0..<384).map { UInt8(truncatingIfNeeded: $0) })
        let continued = uploadCommands(data: binary, asset: asset, token: UUID(), firstIndex: commands.count)
        return continued.count == 5 && continued[0].contains("=3 ||") &&
            continued.last?.contains("=7;") == true &&
            continued.allSatisfy { $0.count < 1024 } &&
            uploadCommands(data: binary, asset: asset, token: UUID(), firstIndex: 10_000).allSatisfy { $0.count < 1024 } &&
            commands.count == 3 && commands[1].contains("\\0000\\0012\\0015\\0047\\0044\\0377") &&
            commands.allSatisfy { $0.count < 1024 } && commands[2].contains("md5sum") &&
            commands[0].contains("[ -x /bin/DragonStarter.sh ]") && !commands.joined().contains("B29 ")
    }
}
