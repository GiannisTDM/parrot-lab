import CryptoKit
import Foundation

enum BebopToolPackage: String {
    case dragonLab
    case persistentTelnet
    case rfModSuite
    case sc2Discovery
    case sc2DriverPatch

    static let ftpHost = "192.168.42.1"
    static let ftpPort = 21
    static let remoteDirectory = "internal_000"

    var displayName: String {
        switch self {
        case .dragonLab: return "Dragon Lab"
        case .persistentTelnet: return "Persistent Bebop Telnet"
        case .rfModSuite: return "RF/MOD Suite"
        case .sc2Discovery: return "SC2 Address Discovery"
        case .sc2DriverPatch: return "SC2 Driver Patch"
        }
    }

    fileprivate var assets: [BebopToolAsset] {
        switch self {
        case .dragonLab:
            return [
                BebopToolAsset(
                    sourceRelativePath: "patched/dpd1830",
                    remoteName: "dragon-prog-1080p-mode1-30fps"
                ),
                BebopToolAsset(
                    sourceRelativePath: "tools/parrotlab_dragon_video.sh",
                    remoteName: "parrotlab_dragon_video.sh"
                )
            ]
        case .persistentTelnet:
            return [
                BebopToolAsset(
                    sourceRelativePath: "tools/install_bebop2_persistent_telnet.sh",
                    remoteName: "install_bebop2_persistent_telnet.sh"
                )
            ]
        case .rfModSuite:
            return [
                BebopToolAsset(
                    sourceRelativePath: "tools/parrot_rf_lab.sh",
                    remoteName: "parrot_rf_lab.sh"
                )
            ]
        case .sc2Discovery:
            return [
                BebopToolAsset(
                    sourceRelativePath: "tools/parrotlab_find_sc2_ip.sh",
                    remoteName: "parrotlab_find_sc2_ip.sh"
                )
            ]
        case .sc2DriverPatch:
            return [
                BebopToolAsset(
                    sourceRelativePath: "sc2/install.sh",
                    remoteName: "install_sc2_apple_ncm.sh"
                ),
                BebopToolAsset(
                    sourceRelativePath: "sc2/apple_mac_ncm.ko",
                    remoteName: "apple_mac_ncm.ko"
                )
            ]
        }
    }
}

private struct BebopToolAsset {
    let sourceRelativePath: String
    let remoteName: String
}

struct BebopInstalledAsset {
    let assetName: String
    let remoteName: String
    let byteCount: Int
    let sha256: String
    let md5: String

    var devicePath: String {
        "/data/ftp/\(BebopToolPackage.remoteDirectory)/\(remoteName)"
    }
}

struct BebopToolInstallResult {
    let package: BebopToolPackage
    let host: String
    let assets: [BebopInstalledAsset]
}

enum BebopToolInstallerError: LocalizedError {
    case alreadyRunning
    case missingAsset(String)
    case oversizedAsset(String)
    case invalidFTPURL
    case invalidHost
    case commandFailed(String)
    case verificationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Another Bebop upload is already running."
        case .missingAsset(let name):
            return "The bundled file \(name) is missing. Reinstall Parrot Lab and try again."
        case .oversizedAsset(let name):
            return "The bundled file \(name) exceeds the 50 MB installer safety limit."
        case .invalidFTPURL:
            return "Could not construct the device FTP address."
        case .invalidHost:
            return "The FTP host is empty or contains invalid characters."
        case .commandFailed(let message):
            return message
        case .verificationFailed(let name):
            return "FTP verification failed for \(name). Run the upload again before using it."
        case .cancelled:
            return "The upload was cancelled."
        }
    }
}

/// Uploads app-owned lab files to the stock, anonymous Bebop FTP service.
/// It never writes outside FTP-visible `internal_000` and verifies every
/// upload by downloading it again and comparing a SHA-256 digest.
final class BebopToolInstaller: @unchecked Sendable {
    static let maximumAssetBytes = 50 * 1_024 * 1_024

    var onProgress: ((String) -> Void)?

    private let queue = DispatchQueue(label: "parrotlab.bebop-tool-installer", qos: .userInitiated)
    private let processLock = NSLock()
    private var currentProcess: Process?
    private var cancelled = false
    private(set) var isInstalling = false

    func install(
        _ package: BebopToolPackage,
        host: String = BebopToolPackage.ftpHost,
        completion: @escaping (Result<BebopToolInstallResult, Error>) -> Void
    ) {
        guard !isInstalling else {
            completion(.failure(BebopToolInstallerError.alreadyRunning))
            return
        }
        isInstalling = true
        processLock.withLock { cancelled = false }

        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.performInstall(package, host: host) }
            DispatchQueue.main.async {
                self.isInstalling = false
                completion(result)
            }
        }
    }

    func cancel() {
        processLock.withLock {
            cancelled = true
            if let currentProcess, currentProcess.isRunning {
                currentProcess.terminate()
            }
        }
    }

    private func performInstall(_ package: BebopToolPackage, host: String) throws -> BebopToolInstallResult {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidHost(host) else { throw BebopToolInstallerError.invalidHost }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParrotLab-FTP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        var installed: [BebopInstalledAsset] = []
        for (index, asset) in package.assets.enumerated() {
            try checkCancellation()
            let localURL = try Self.resolve(asset)
            let sourceData = try Data(contentsOf: localURL, options: .mappedIfSafe)
            guard sourceData.count <= Self.maximumAssetBytes else {
                throw BebopToolInstallerError.oversizedAsset(asset.remoteName)
            }
            let sourceSHA256 = Self.hex(SHA256.hash(data: sourceData))
            let sourceMD5 = Self.hex(Insecure.MD5.hash(data: sourceData))
            let remoteName = asset.remoteName
            let remoteURL = try Self.ftpURL(host: host, remoteName: remoteName)

            let uploadArguments = [
                "--fail", "--silent", "--show-error", "--ftp-pasv",
                "--connect-timeout", "8", "--max-time", "180",
                "--upload-file", localURL.path, remoteURL.absoluteString
            ]

            report("Uploading \(index + 1)/\(package.assets.count): \(asset.remoteName)")
            try runCurl(uploadArguments)

            try checkCancellation()
            report("Verifying \(index + 1)/\(package.assets.count): \(asset.remoteName)")
            let verificationURL = temporaryDirectory.appendingPathComponent(remoteName)
            try runCurl([
                "--fail", "--silent", "--show-error", "--ftp-pasv",
                "--connect-timeout", "8", "--max-time", "180",
                "--output", verificationURL.path, remoteURL.absoluteString
            ])
            let uploadedData = try Data(contentsOf: verificationURL, options: .mappedIfSafe)
            guard sourceData.count == uploadedData.count,
                  sourceSHA256 == Self.hex(SHA256.hash(data: uploadedData)) else {
                throw BebopToolInstallerError.verificationFailed(asset.remoteName)
            }
            installed.append(BebopInstalledAsset(
                assetName: asset.remoteName,
                remoteName: remoteName,
                byteCount: sourceData.count,
                sha256: sourceSHA256,
                md5: sourceMD5
            ))
        }

        report("Verified \(installed.count) file\(installed.count == 1 ? "" : "s") on \(host)")
        return BebopToolInstallResult(package: package, host: host, assets: installed)
    }

    private func runCurl(_ arguments: [String]) throws {
        try checkCancellation()
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        processLock.withLock { currentProcess = process }
        defer { processLock.withLock { currentProcess = nil } }

        do {
            try process.run()
        } catch {
            throw BebopToolInstallerError.commandFailed("Could not start the macOS FTP client: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        try checkCancellation()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BebopToolInstallerError.commandFailed(
                detail?.isEmpty == false ? detail! : "Bebop FTP transfer failed (curl \(process.terminationStatus))."
            )
        }
    }

    private func checkCancellation() throws {
        if processLock.withLock({ cancelled }) {
            throw BebopToolInstallerError.cancelled
        }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onProgress?(message) }
    }

    private static func resolve(_ asset: BebopToolAsset) throws -> URL {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("DeviceTools", isDirectory: true)
            .appendingPathComponent(asset.remoteName),
           FileManager.default.isReadableFile(atPath: bundled.path) {
            return bundled
        }

        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = sourceDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let developmentAsset = projectDirectory.appendingPathComponent(asset.sourceRelativePath)
        guard FileManager.default.isReadableFile(atPath: developmentAsset.path) else {
            throw BebopToolInstallerError.missingAsset(asset.remoteName)
        }
        return developmentAsset
    }

    private static func ftpURL(host: String, remoteName: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "ftp"
        components.host = host
        components.port = BebopToolPackage.ftpPort
        components.path = "/\(BebopToolPackage.remoteDirectory)/\(remoteName)"
        guard let url = components.url else { throw BebopToolInstallerError.invalidFTPURL }
        return url
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func selfTest() -> Bool {
        guard let url = try? ftpURL(host: BebopToolPackage.ftpHost, remoteName: "parrot_rf_lab.sh"),
              url.absoluteString == "ftp://192.168.42.1:21/internal_000/parrot_rf_lab.sh" else {
            return false
        }
        let sample = Data("Parrot Lab".utf8)
        guard hex(SHA256.hash(data: sample)).count == 64,
              hex(Insecure.MD5.hash(data: sample)).count == 32 else {
            return false
        }
        return BebopToolPackage.dragonLab.assets.allSatisfy { (try? resolve($0)) != nil } &&
            BebopToolPackage.persistentTelnet.assets.allSatisfy { (try? resolve($0)) != nil } &&
            BebopToolPackage.rfModSuite.assets.allSatisfy { (try? resolve($0)) != nil } &&
            BebopToolPackage.sc2Discovery.assets.allSatisfy { (try? resolve($0)) != nil } &&
            BebopToolPackage.sc2DriverPatch.assets.allSatisfy { (try? resolve($0)) != nil }
    }
}
