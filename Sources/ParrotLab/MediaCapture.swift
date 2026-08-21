import AppKit
import ImageIO
import UniformTypeIdentifiers

enum PictureFileFormat: Int, CaseIterable {
    case png
    case jpeg

    var menuTitle: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpeg"
        }
    }

    var uniformType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        }
    }
}

enum MediaFileNamer {
    static var defaultDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return movies.appendingPathComponent("Parrot Lab", isDirectory: true)
    }

    static func pictureURL(
        directory: URL,
        date: Date = Date(),
        format: PictureFileFormat,
        timeZone: TimeZone = .current
    ) -> URL {
        uniqueURL(
            directory.appendingPathComponent(
                "PictureBB2-\(dateStamp(date, timeZone: timeZone)).\(format.fileExtension)"
            )
        )
    }

    static func temporaryVideoURL(
        directory: URL,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> URL {
        uniqueURL(directory.appendingPathComponent(
            "VideoBB2-\(dateStamp(date, timeZone: timeZone))-recording.h264"
        ))
    }

    static func completedVideoURL(
        directory: URL,
        date: Date,
        duration: TimeInterval,
        timeZone: TimeZone = .current
    ) -> URL {
        uniqueURL(directory.appendingPathComponent(
            "VideoBB2-\(dateStamp(date, timeZone: timeZone))-\(durationStamp(duration)).h264"
        ))
    }

    static func durationStamp(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%02dh%02dm%02ds", hours, minutes, seconds)
            : String(format: "%02dm%02ds", minutes, seconds)
    }

    static func selfTest() -> Bool {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        guard dateStamp(date, timeZone: TimeZone(secondsFromGMT: 0)!) == "2023-11-14_22-13-20",
              durationStamp(65) == "01m05s",
              durationStamp(3_723) == "01h02m03s" else { return false }
        return true
    }

    private static func dateStamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    private static func uniqueURL(_ proposed: URL) -> URL {
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
}

enum StillImageWriter {
    static func write(_ image: CGImage, to url: URL, format: PictureFileFormat) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.uniformType.identifier as CFString,
            1,
            nil
        ) else {
            throw captureError("Could not create the image destination")
        }
        let properties: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.94]
            : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw captureError("Could not finish writing the image")
        }
    }

    static func selfTest() -> Bool {
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setFillColor(NSColor.systemCyan.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = context.makeImage() else { return false }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrotlab-image-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for format in PictureFileFormat.allCases {
                let url = directory.appendingPathComponent("test.\(format.fileExtension)")
                try write(image, to: url, format: format)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      CGImageSourceGetCount(source) == 1 else { return false }
            }
            return true
        } catch {
            return false
        }
    }
}

struct H264RecordingResult {
    let url: URL
    let duration: TimeInterval
    let bytesWritten: UInt64
    let errorDescription: String?
}

/// Writes complete Annex-B access units independently of the display path.
/// The queue is capped so a slow or disconnected disk cannot recreate the
/// unbounded-memory failure that the live decoder was designed to avoid.
final class H264StreamRecorder {
    var onFinished: ((H264RecordingResult) -> Void)?

    private enum State {
        case idle
        case recording
        case finishing
    }

    private let stateLock = NSLock()
    private let ioQueue = DispatchQueue(label: "parrotlab.h264-recorder", qos: .utility)
    private let maximumPendingBytes = 50 * 1_024 * 1_024
    private var state = State.idle
    private var pendingChunks: [Data] = []
    private var pendingHead = 0
    private var pendingBytes = 0
    private var drainScheduled = false
    private var handle: FileHandle?
    private var directoryURL: URL?
    private var temporaryURL: URL?
    private var startedAt: Date?
    private var endedAt: Date?
    private var bytesWritten: UInt64 = 0
    private var recordedAccessUnits = 0
    private var finishError: String?
    private var cachedSPS: Data?
    private var cachedPPS: Data?

    var isRecording: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state == .recording
    }

    var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state != .idle
    }

    @discardableResult
    func start(directory: URL, at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = MediaFileNamer.temporaryVideoURL(directory: directory, date: date)
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw captureError("Could not create \(temporaryURL.lastPathComponent)")
        }
        let newHandle: FileHandle
        do {
            newHandle = try FileHandle(forWritingTo: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        stateLock.lock()
        guard state == .idle else {
            stateLock.unlock()
            try? newHandle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw captureError("A recording is already active")
        }
        state = .recording
        handle = newHandle
        directoryURL = directory
        self.temporaryURL = temporaryURL
        startedAt = date
        endedAt = nil
        bytesWritten = 0
        recordedAccessUnits = 0
        finishError = nil
        pendingChunks.removeAll(keepingCapacity: true)
        pendingHead = 0
        pendingBytes = 0
        if let cachedSPS { enqueueLocked(Self.annexBData(for: [cachedSPS])) }
        if let cachedPPS { enqueueLocked(Self.annexBData(for: [cachedPPS])) }
        scheduleDrainLocked()
        stateLock.unlock()
        return temporaryURL
    }

    func observe(_ accessUnit: H264AccessUnit) {
        stateLock.lock()
        for nalu in accessUnit.nalUnits {
            guard let first = nalu.first else { continue }
            switch first & 0x1f {
            case 7: cachedSPS = nalu
            case 8: cachedPPS = nalu
            default: break
            }
        }
        guard state == .recording else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let annexB = Self.annexBData(for: accessUnit.nalUnits)
        stateLock.lock()
        guard state == .recording else {
            stateLock.unlock()
            return
        }
        if pendingBytes + annexB.count > maximumPendingBytes {
            finishError = "Recording stopped because the disk writer fell 50 MiB behind"
            endedAt = Date()
            state = .finishing
        } else {
            enqueueLocked(annexB)
            recordedAccessUnits += 1
        }
        scheduleDrainLocked()
        stateLock.unlock()
    }

    static func selfTest() -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrotlab-recording-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = H264StreamRecorder()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try recorder.start(directory: directory)
            let accessUnit = H264AccessUnit(
                nalUnits: [Data([0x67, 0x11]), Data([0x68, 0x22]), Data([0x61, 0x33, 0x44])],
                rtpTimestamp: 90_000,
                rtpHeaderExtensions: []
            )
            recorder.observe(accessUnit)
            recorder.stopAndWait()
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "h264" }
            guard files.count == 1,
                  !files[0].lastPathComponent.contains("recording") else { return false }
            return try Data(contentsOf: files[0]) == annexBData(for: accessUnit.nalUnits)
        } catch {
            return false
        }
    }

    func stop() {
        stateLock.lock()
        guard state == .recording else {
            stateLock.unlock()
            return
        }
        state = .finishing
        endedAt = Date()
        scheduleDrainLocked()
        stateLock.unlock()
    }

    func stopAndWait() {
        stop()
        ioQueue.sync {}
    }

    func resetParameterSets() {
        stateLock.lock()
        if state == .idle {
            cachedSPS = nil
            cachedPPS = nil
        }
        stateLock.unlock()
    }

    private func enqueueLocked(_ data: Data) {
        guard !data.isEmpty else { return }
        pendingChunks.append(data)
        pendingBytes += data.count
    }

    private func popLocked() -> Data? {
        guard pendingHead < pendingChunks.count else { return nil }
        let chunk = pendingChunks[pendingHead]
        pendingHead += 1
        pendingBytes -= chunk.count
        if pendingHead >= 256, pendingHead * 2 >= pendingChunks.count {
            pendingChunks.removeFirst(pendingHead)
            pendingHead = 0
        }
        return chunk
    }

    private func scheduleDrainLocked() {
        guard !drainScheduled else { return }
        drainScheduled = true
        ioQueue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            stateLock.lock()
            if let chunk = popLocked(), let handle {
                stateLock.unlock()
                do {
                    try handle.write(contentsOf: chunk)
                    stateLock.lock()
                    bytesWritten += UInt64(chunk.count)
                    stateLock.unlock()
                } catch {
                    stateLock.lock()
                    finishError = "Disk write failed: \(error.localizedDescription)"
                    endedAt = endedAt ?? Date()
                    state = .finishing
                    pendingChunks.removeAll(keepingCapacity: false)
                    pendingHead = 0
                    pendingBytes = 0
                    stateLock.unlock()
                }
                continue
            }

            guard state == .finishing else {
                drainScheduled = false
                stateLock.unlock()
                return
            }

            let handle = self.handle
            let directory = directoryURL
            let temporary = temporaryURL
            let started = startedAt ?? Date()
            let ended = endedAt ?? Date()
            let written = bytesWritten
            let accessUnits = recordedAccessUnits
            var errorDescription = finishError
            self.handle = nil
            directoryURL = nil
            temporaryURL = nil
            startedAt = nil
            endedAt = nil
            recordedAccessUnits = 0
            pendingChunks.removeAll(keepingCapacity: false)
            pendingHead = 0
            pendingBytes = 0
            state = .idle
            drainScheduled = false
            stateLock.unlock()

            do {
                try handle?.synchronize()
                try handle?.close()
            } catch {
                errorDescription = errorDescription ?? "Could not finish the file: \(error.localizedDescription)"
            }

            let duration = ended.timeIntervalSince(started)
            if accessUnits == 0 {
                errorDescription = errorDescription ?? "No H.264 access units were received while recording"
            }
            var resultURL = temporary ?? MediaFileNamer.temporaryVideoURL(
                directory: directory ?? MediaFileNamer.defaultDirectory,
                date: started
            )
            if let directory, let temporary {
                let completed = MediaFileNamer.completedVideoURL(
                    directory: directory,
                    date: started,
                    duration: duration
                )
                do {
                    try FileManager.default.moveItem(at: temporary, to: completed)
                    resultURL = completed
                } catch {
                    errorDescription = errorDescription ?? "Could not apply the final filename: \(error.localizedDescription)"
                }
            }
            let result = H264RecordingResult(
                url: resultURL,
                duration: duration,
                bytesWritten: written,
                errorDescription: errorDescription
            )
            DispatchQueue.main.async { [weak self] in self?.onFinished?(result) }
            return
        }
    }

    private static func annexBData(for nalUnits: [Data]) -> Data {
        let startCode = Data([0, 0, 0, 1])
        var output = Data()
        output.reserveCapacity(nalUnits.reduce(0) { $0 + $1.count + startCode.count })
        for nalu in nalUnits {
            output.append(startCode)
            output.append(nalu)
        }
        return output
    }
}

private func captureError(_ message: String) -> NSError {
    NSError(
        domain: "ParrotLab.MediaCapture",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
