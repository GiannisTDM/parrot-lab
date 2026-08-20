import Foundation

final class FFmpegVideoDecoder {
    var onFrame: ((Data, Int, Int) -> Void)?
    var onDebug: ((String) -> Void)?

    private let width: Int
    private let height: Int
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    // Input and output must never share a serial queue: FFmpeg can block an
    // input write while it waits for us to drain decoded frames from stdout.
    private let writeQueue = DispatchQueue(label: "parrotlab.ffmpeg-video.write")
    private let readQueue = DispatchQueue(label: "parrotlab.ffmpeg-video.read")
    private let stateLock = NSLock()
    private var outputBuffer = Data()
    private var pendingInput = BoundedDataQueue(maxBytes: 50 * 1_024 * 1_024)
    private var pendingFrame = LatestDecodedFrameSlot()
    private var inputDrainScheduled = false
    private var frameDeliveryScheduled = false
    private var running = false

    init?(width: Int, height: Int) {
        guard let executable = Self.findExecutable() else { return nil }
        self.width = width
        self.height = height
        process.executableURL = executable
        process.arguments = [
            "-hide_banner", "-loglevel", "fatal",
            "-fflags", "nobuffer", "-flags", "low_delay",
            "-probesize", "32768", "-analyzeduration", "0",
            "-f", "h264", "-i", "pipe:0",
            "-an", "-sn", "-dn",
            "-f", "rawvideo", "-pix_fmt", "rgba", "pipe:1"
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
    }

    func start() -> Bool {
        do {
            try process.run()
        } catch {
            onDebug?("Could not start FFmpeg decoder: \(error.localizedDescription)")
            return false
        }
        stateLock.lock()
        running = true
        stateLock.unlock()
        let frameBytes = width * height * 4
        readQueue.async { [weak self] in
            self?.readOutput(frameBytes: frameBytes)
        }
        process.terminationHandler = { [weak self] process in
            self?.onDebug?("FFmpeg video decoder exited with status \(process.terminationStatus)")
        }
        onDebug?("FFmpeg recovery decoder started for \(width)x\(height)")
        return true
    }

    func feed(nalUnits: [Data]) {
        var annexB = Data()
        let startCode = Data([0, 0, 0, 1])
        for nalu in nalUnits {
            annexB.append(startCode)
            annexB.append(nalu)
        }
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        pendingInput.append(annexB)
        let shouldSchedule = !inputDrainScheduled && !pendingInput.isEmpty
        if shouldSchedule { inputDrainScheduled = true }
        stateLock.unlock()

        if shouldSchedule {
            writeQueue.async { [weak self] in self?.drainInput() }
        }
    }

    func stop() {
        stateLock.lock()
        running = false
        pendingInput.removeAll()
        pendingFrame.removeAll()
        stateLock.unlock()
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? outputPipe.fileHandleForReading.close()
    }

    deinit { stop() }

    private func drainInput() {
        while true {
            stateLock.lock()
            guard running, let data = pendingInput.popFirst() else {
                inputDrainScheduled = false
                stateLock.unlock()
                return
            }
            stateLock.unlock()

            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                onDebug?("FFmpeg input failed: \(error.localizedDescription)")
                stateLock.lock()
                running = false
                pendingInput.removeAll()
                inputDrainScheduled = false
                stateLock.unlock()
                return
            }
        }
    }

    private func readOutput(frameBytes: Int) {
        let handle = outputPipe.fileHandleForReading
        while isRunning {
            let data = handle.readData(ofLength: 256 * 1_024)
            if data.isEmpty { break }
            autoreleasepool {
                outputBuffer.append(data)
                while outputBuffer.count >= frameBytes {
                    let frame = Data(outputBuffer.prefix(frameBytes))
                    outputBuffer.removeFirst(frameBytes)
                    enqueueLatestFrame(frame)
                }
            }
        }
        outputBuffer.removeAll(keepingCapacity: false)
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func enqueueLatestFrame(_ data: Data) {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        pendingFrame.replace(with: DecodedFrame(data: data, width: width, height: height))
        let shouldSchedule = !frameDeliveryScheduled
        if shouldSchedule { frameDeliveryScheduled = true }
        stateLock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.deliverLatestFrame() }
        }
    }

    private func deliverLatestFrame() {
        stateLock.lock()
        guard running, let frame = pendingFrame.take() else {
            frameDeliveryScheduled = false
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        onFrame?(frame.data, frame.width, frame.height)

        stateLock.lock()
        let shouldContinue = running && !pendingFrame.isEmpty
        if !shouldContinue { frameDeliveryScheduled = false }
        stateLock.unlock()
        if shouldContinue {
            DispatchQueue.main.async { [weak self] in self?.deliverLatestFrame() }
        }
    }

    static func bufferingSelfTest() -> Bool {
        var queue = BoundedDataQueue(maxBytes: 8)
        queue.append(Data([1, 1, 1, 1]))
        queue.append(Data([2, 2, 2, 2]))
        queue.append(Data([3, 3, 3, 3]))
        guard queue.byteCount == 8,
              queue.droppedItems == 1,
              queue.popFirst()?.first == 2,
              queue.popFirst()?.first == 3,
              queue.isEmpty else { return false }

        var slot = LatestDecodedFrameSlot()
        slot.replace(with: DecodedFrame(data: Data([1]), width: 1, height: 1))
        slot.replace(with: DecodedFrame(data: Data([2]), width: 2, height: 2))
        return slot.droppedFrames == 1 && slot.take()?.data == Data([2]) && slot.isEmpty
    }

    private static func findExecutable() -> URL? {
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("ffmpeg-parrotlab"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

private struct DecodedFrame {
    let data: Data
    let width: Int
    let height: Int
}

private struct LatestDecodedFrameSlot {
    private(set) var frame: DecodedFrame?
    private(set) var droppedFrames = 0
    var isEmpty: Bool { frame == nil }

    mutating func replace(with newFrame: DecodedFrame) {
        if frame != nil { droppedFrames += 1 }
        frame = newFrame
    }

    mutating func take() -> DecodedFrame? {
        defer { frame = nil }
        return frame
    }

    mutating func removeAll() { frame = nil }
}

private struct BoundedDataQueue {
    let maxBytes: Int
    private var items: [Data] = []
    private(set) var byteCount = 0
    private(set) var droppedItems = 0
    var isEmpty: Bool { items.isEmpty }

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    mutating func append(_ data: Data) {
        guard data.count <= maxBytes else {
            droppedItems += 1
            return
        }
        while byteCount + data.count > maxBytes, !items.isEmpty {
            byteCount -= items.removeFirst().count
            droppedItems += 1
        }
        items.append(data)
        byteCount += data.count
    }

    mutating func popFirst() -> Data? {
        guard !items.isEmpty else { return nil }
        let data = items.removeFirst()
        byteCount -= data.count
        return data
    }

    mutating func removeAll() {
        items.removeAll(keepingCapacity: false)
        byteCount = 0
    }
}
