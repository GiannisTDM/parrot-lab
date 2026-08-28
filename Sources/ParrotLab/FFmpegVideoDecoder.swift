import Foundation
import CoreMedia

final class FFmpegVideoDecoder {
    var onFrame: ((Data, Int, Int, VideoFrameTiming, VerifiedVideoFrameMotion?) -> Void)?
    /// Fired for every complete raw frame emitted by FFmpeg, before the
    /// latest-frame slot can coalesce frames waiting for the main thread.
    var onDecodedFrame: (() -> Void)?
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
    private var pendingTimings: [(VideoFrameTiming, VerifiedVideoFrameMotion?)] = []
    private var pendingTimingHead = 0
    private var lastOutputTiming: VideoFrameTiming?
    private var inputDrainScheduled = false
    private var frameDeliveryScheduled = false
    private var running = false

    init?(width: Int, height: Int) {
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, !pixelOverflow, !byteOverflow,
              let executable = BundledFFmpeg.executableURL() else { return nil }
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
        // The child owns duplicated copies of these ends after launch. Closing
        // the unused parent copies lets stdout deliver EOF when FFmpeg exits.
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
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

    func feed(
        nalUnits: [Data],
        timing: VideoFrameTiming? = nil,
        motion: VerifiedVideoFrameMotion? = nil
    ) {
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
        if let timing {
            pendingTimings.append((timing, motion))
            let maximumPendingTimings = 300
            if pendingTimings.count - pendingTimingHead > maximumPendingTimings {
                pendingTimingHead += 1
                if pendingTimingHead >= 256 {
                    pendingTimings.removeFirst(pendingTimingHead)
                    pendingTimingHead = 0
                }
            }
        }
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
        pendingTimings.removeAll(keepingCapacity: false)
        pendingTimingHead = 0
        lastOutputTiming = nil
        stateLock.unlock()
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        // Do not close stdout from underneath readOutput(). FileHandle raises
        // an Objective-C exception when a blocking read races a close. Queue
        // the close behind the reader, which will leave after FFmpeg exits and
        // the pipe reports EOF.
        let outputHandle = outputPipe.fileHandleForReading
        readQueue.async {
            try? outputHandle.close()
        }
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
            let receivedData = autoreleasepool { () -> Bool in
                // FileHandle bridges an NSData for every read. The read must
                // happen inside this pool—not immediately before it—or a
                // long-lived decoder queue can retain hundreds of MB/s of
                // autoreleased chunks until the stream is stopped.
                let data: Data
                do {
                    data = try handle.read(upToCount: 256 * 1_024) ?? Data()
                } catch {
                    onDebug?("FFmpeg output ended: \(error.localizedDescription)")
                    return false
                }
                guard !data.isEmpty else { return false }
                // Never use append/removeFirst as a byte stream here. At
                // High-resolution FFmpeg output can emit hundreds of MB/s of RGBA, and Data can
                // retain the consumed prefix/capacity even while its logical
                // count remains small. This assembler owns exactly one fixed
                // frame buffer and hands completed buffers downstream.
                for frame in outputAccumulator.append(data) {
                    onDecodedFrame?()
                    let timing = takeNextOutputTiming()
                    enqueueLatestFrame(frame, timing: timing.0, motion: timing.1)
                }
                return true
            }
            if !receivedData { break }
        }
        outputAccumulator.reset()
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func takeNextOutputTiming() -> (VideoFrameTiming, VerifiedVideoFrameMotion?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if pendingTimingHead < pendingTimings.count {
            let value = pendingTimings[pendingTimingHead]
            pendingTimingHead += 1
            if pendingTimingHead >= 256, pendingTimingHead * 2 >= pendingTimings.count {
                pendingTimings.removeFirst(pendingTimingHead)
                pendingTimingHead = 0
            }
            lastOutputTiming = value.0
            return value
        }
        let previous = lastOutputTiming
        let fallback = VideoFrameTiming(
            rtpTimestamp: previous?.rtpTimestamp ?? 0,
            presentationTime: previous.map {
                CMTimeAdd($0.presentationTime, $0.nominalDuration)
            } ?? .zero,
            nominalDuration: previous?.nominalDuration ?? CMTime(value: 3_000, timescale: 90_000)
        )
        lastOutputTiming = fallback
        return (fallback, nil)
    }

    private func enqueueLatestFrame(
        _ data: Data,
        timing: VideoFrameTiming,
        motion: VerifiedVideoFrameMotion?
    ) {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        pendingFrame.replace(with: DecodedFrame(
            data: data,
            width: width,
            height: height,
            timing: timing,
            motion: motion
        ))
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

        onFrame?(frame.data, frame.width, frame.height, frame.timing, frame.motion)

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
    let timing: VideoFrameTiming
    let motion: VerifiedVideoFrameMotion?

    init(
        data: Data,
        width: Int,
        height: Int,
        timing: VideoFrameTiming = VideoFrameTiming(
            rtpTimestamp: 0,
            presentationTime: .zero,
            nominalDuration: CMTime(value: 3_000, timescale: 90_000)
        ),
        motion: VerifiedVideoFrameMotion? = nil
    ) {
        self.data = data
        self.width = width
        self.height = height
        self.timing = timing
        self.motion = motion
    }
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
