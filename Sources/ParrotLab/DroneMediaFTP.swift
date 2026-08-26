import AppKit
import Foundation

struct DroneRemotePhoto: Hashable {
    let path: String
    let filename: String
}

enum DroneMediaFTPError: LocalizedError {
    case command(String)
    case noMediaDirectory
    case photoTimeout

    var errorDescription: String? {
        switch self {
        case .command(let detail): return "Drone FTP failed: \(detail)"
        case .noMediaDirectory: return "No Bebop media directory was found below internal_000."
        case .photoTimeout: return "The drone reported success, but its new JPEG did not appear on FTP in time."
        }
    }
}

final class DroneMediaFTP {
    static let stockHost = "192.168.42.1"
    private let queue = DispatchQueue(label: "parrotlab.drone-media-ftp", qos: .utility)

    func snapshot(completion: @escaping (Result<Set<DroneRemotePhoto>, Error>) -> Void) {
        queue.async {
            let result = Result { try self.enumeratePhotos() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func downloadNewPhoto(
        excluding baseline: Set<DroneRemotePhoto>,
        to directory: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        queue.async {
            let deadline = Date().addingTimeInterval(25)
            var result: Result<URL, Error> = .failure(DroneMediaFTPError.photoTimeout)
            while Date() < deadline {
                do {
                    let current = try self.enumeratePhotos()
                    if let photo = Self.selectNewPhoto(baseline: baseline, current: current) {
                        result = .success(try self.download(photo, to: directory))
                        break
                    }
                } catch {
                    result = .failure(error)
                }
                Thread.sleep(forTimeInterval: 1)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func selectNewPhoto(
        baseline: Set<DroneRemotePhoto>,
        current: Set<DroneRemotePhoto>
    ) -> DroneRemotePhoto? {
        current.subtracting(baseline).sorted { $0.path < $1.path }.last
    }

    private func enumeratePhotos() throws -> Set<DroneRemotePhoto> {
        let products = try list(path: "internal_000")
        var foundMediaDirectory = false
        var result = Set<DroneRemotePhoto>()
        for product in products where !product.isEmpty && product != "." && product != ".." {
            let mediaPath = "internal_000/\(product)/media"
            guard let names = try? list(path: mediaPath) else { continue }
            foundMediaDirectory = true
            for name in names {
                let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                guard ext == "jpg" || ext == "jpeg" else { continue }
                result.insert(DroneRemotePhoto(path: "\(mediaPath)/\(name)", filename: name))
            }
        }
        // A freshly formatted aircraft may not create the product media
        // directory until its first photo. An empty baseline remains valid.
        _ = foundMediaDirectory
        return result
    }

    private func list(path: String) throws -> [String] {
        let data = try runCurl([
            "--fail", "--silent", "--show-error", "--ftp-pasv", "--list-only",
            "--connect-timeout", "6", "--max-time", "12", ftpURL(path: path, directory: true)
        ])
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \ .isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func download(_ photo: DroneRemotePhoto, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueURL(directory.appendingPathComponent(photo.filename))
        let temporary = directory.appendingPathComponent(".parrotlab-\(UUID().uuidString).jpeg")
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try runCurl([
            "--fail", "--silent", "--show-error", "--ftp-pasv",
            "--connect-timeout", "8", "--max-time", "120",
            "--output", temporary.path, ftpURL(path: photo.path, directory: false)
        ])
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func runCurl(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch {
            throw DroneMediaFTPError.command(error.localizedDescription)
        }
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DroneMediaFTPError.command(detail.isEmpty ? "curl \(process.terminationStatus)" : detail)
        }
        return outputData
    }

    private func ftpURL(path: String, directory: Bool) -> String {
        var components = URLComponents()
        components.scheme = "ftp"
        components.host = Self.stockHost
        components.port = 21
        components.path = "/" + path + (directory ? "/" : "")
        return components.url!.absoluteString
    }

    private func uniqueURL(_ proposed: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let directory = proposed.deletingLastPathComponent()
        let stem = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        for suffix in 2...9_999 {
            let candidate = directory.appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(stem)-\(UUID().uuidString)").appendingPathExtension(ext)
    }

    static func selfTest() -> Bool {
        let old = DroneRemotePhoto(path: "internal_000/Bebop_Drone/media/old.jpg", filename: "old.jpg")
        let newA = DroneRemotePhoto(path: "internal_000/Bebop_Drone/media/new-a.jpg", filename: "new-a.jpg")
        let newB = DroneRemotePhoto(path: "internal_000/Bebop_2/media/new-b.jpeg", filename: "new-b.jpeg")
        return selectNewPhoto(baseline: [old], current: [old]) == nil &&
            selectNewPhoto(baseline: [old], current: [old, newA]) == newA &&
            selectNewPhoto(baseline: [old], current: [old, newA, newB]) != nil
    }
}
