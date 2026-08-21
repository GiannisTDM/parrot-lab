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
    private var outputAccumulator: FixedFrameAccumulator
    private var pendingInput = BoundedDataQueue(maxBytes: 50 * 1_024 * 1_024)
    private var pendingFrame = LatestDecodedFrameSlot()
    private var inputDrainScheduled = false
    private var frameDeliveryScheduled = false
    private var running = false

    init?(width: Int, height: Int) {
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, !pixelOverflow, !byteOverflow,
              let executable = Self.findExecutable() else { return nil }
        self.width = width
        self.height = height
        outputAccumulator = FixedFrameAccumulator(frameBytes: byteCount)
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
        readQueue.async { [weak self] in
            self?.readOutput()
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

    private func readOutput() {
        let handle = outputPipe.fileHandleForReading
        while isRunning {
            let data = handle.readData(ofLength: 256 * 1_024)
            if data.isEmpty { break }
            autoreleasepool {
                // Never use append/removeFirst as a byte stream here. At
                // 1080p30 FFmpeg emits about 249 MB/s of RGBA, and Data can
                // retain the consumed prefix/capacity even while its logical
                // count remains small. This assembler owns exactly one fixed
                // frame buffer and hands completed buffers downstream.
                for frame in outputAccumulator.append(data) {
                    enqueueLatestFrame(frame)
                }
            }
        }
        outputAccumulator.reset()
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
        guard slot.droppedFrames == 1,
              slot.take()?.data == Data([2]),
              slot.isEmpty else { return false }

        var accumulator = FixedFrameAccumulator(frameBytes: 4)
        guard accumulator.append(Data([0, 1])).isEmpty else { return false }
        let frames = accumulator.append(Data([2, 3, 4, 5, 6, 7, 8]))
        return frames == [Data([0, 1, 2, 3]), Data([4, 5, 6, 7])]
            && accumulator.bufferedByteCount == 1
            && accumulator.allocatedByteCount == 4
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

private struct FixedFrameAccumulator {
    let frameBytes: Int
    private var buffer: Data
    private var writeOffset = 0

    var bufferedByteCount: Int { writeOffset }
    var allocatedByteCount: Int { buffer.count }

    init(frameBytes: Int) {
        precondition(frameBytes > 0)
        self.frameBytes = frameBytes
        buffer = Data(count: frameBytes)
    }

    mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        if buffer.count != frameBytes { buffer = Data(count: frameBytes) }

        var completedFrames: [Data] = []
        data.withUnsafeBytes { sourceBytes in
            guard let sourceBase = sourceBytes.baseAddress else { return }
            var sourceOffset = 0
            while sourceOffset < sourceBytes.count {
                let copyCount = min(
                    frameBytes - writeOffset,
                    sourceBytes.count - sourceOffset
                )
                buffer.withUnsafeMutableBytes { destinationBytes in
                    destinationBytes.baseAddress!
                        .advanced(by: writeOffset)
                        .copyMemory(
                            from: sourceBase.advanced(by: sourceOffset),
                            byteCount: copyCount
                        )
                }
                sourceOffset += copyCount
                writeOffset += copyCount

                if writeOffset == frameBytes {
                    completedFrames.append(buffer)
                    buffer = Data(count: frameBytes)
                    writeOffset = 0
                }
            }
        }
        return completedFrames
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        writeOffset = 0
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
