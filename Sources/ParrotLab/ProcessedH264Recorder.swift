import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct ProcessedRecordingStats: Equatable {
    let width: Int
    let height: Int
    let targetFPS: Int
    let bitrateMbps: Double
    let encodedFrames: UInt64
    let encodedFPS: Double
    let droppedBeforeEncoder: UInt64
    let droppedByEncoder: UInt64
    let encoderInFlight: Int
    let diskQueueBytes: Int
}

/// Encodes the processed IOSurface-backed frame branch. Both the pre-encoder
/// latest-frame slot and the disk queue are bounded; recorder pressure can
/// reduce recording cadence but can never queue latency in the live display.
final class ProcessedH264Recorder {
    var onFinished: ((H264RecordingResult) -> Void)?
    var onStats: ((ProcessedRecordingStats) -> Void)?

    private enum State {
        case idle
        case recording
        case finishing
    }

    private let stateLock = NSLock()
    private let encoderQueue = DispatchQueue(
        label: "parrotlab.processed-h264-encoder",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let ioQueue = DispatchQueue(
        label: "parrotlab.processed-h264-writer",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let maximumEncoderFramesInFlight = 3
    private let maximumPendingDiskBytes = 16 * 1_024 * 1_024
    private var state = State.idle
    private var pendingFrame: ProcessedVideoFrame?
    private var encoderDrainScheduled = false
    private var encoderFinishScheduled = false
    private var encoderFinished = false
    private var compressionSession: VTCompressionSession?
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var encoderBitrate = 0
    private var targetFPS = 30
    private var firstSourcePTS: CMTime?
    private var lastSourcePTS: CMTime?
    private var lastSourceDuration: CMTime?
    private var lastSubmittedPTS: CMTime?
    private var firstFrameSubmitted = false
    private var framesInFlight = 0
    private var encodedFrames: UInt64 = 0
    private var droppedBeforeEncoder: UInt64 = 0
    private var droppedByEncoder: UInt64 = 0
    private var pendingChunks: [Data] = []
    private var pendingChunkHead = 0
    private var pendingDiskBytes = 0
    private var ioDrainScheduled = false
    private var handle: FileHandle?
    private var directoryURL: URL?
    private var temporaryURL: URL?
    private var startedAt: Date?
    private var endedAt: Date?
    private var bytesWritten: UInt64 = 0
    private var finishError: String?
    private var lastStatsEmission = Date.distantPast
    private var statsWindowStarted = Date()
    private var encodedFramesInStatsWindow = 0

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
            throw processedRecordingError("Could not create \(temporaryURL.lastPathComponent)")
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
            throw processedRecordingError("A recording is already active")
        }
        state = .recording
        pendingFrame = nil
        encoderDrainScheduled = false
        encoderFinishScheduled = false
        encoderFinished = false
        compressionSession = nil
        encoderWidth = 0
        encoderHeight = 0
        encoderBitrate = 0
        targetFPS = 30
        firstSourcePTS = nil
        lastSourcePTS = nil
        lastSourceDuration = nil
        lastSubmittedPTS = nil
        firstFrameSubmitted = false
        framesInFlight = 0
        encodedFrames = 0
        droppedBeforeEncoder = 0
        droppedByEncoder = 0
        pendingChunks.removeAll(keepingCapacity: true)
        pendingChunkHead = 0
        pendingDiskBytes = 0
        ioDrainScheduled = false
        handle = newHandle
        directoryURL = directory
        self.temporaryURL = temporaryURL
        startedAt = date
        endedAt = nil
        bytesWritten = 0
        finishError = nil
        lastStatsEmission = .distantPast
        statsWindowStarted = date
        encodedFramesInStatsWindow = 0
        stateLock.unlock()
        return temporaryURL
    }

    func observe(_ frame: ProcessedVideoFrame) {
        stateLock.lock()
        guard state == .recording else {
            stateLock.unlock()
            return
        }
        if pendingFrame != nil { droppedBeforeEncoder += 1 }
        pendingFrame = frame
        let shouldSchedule = !encoderDrainScheduled
        if shouldSchedule { encoderDrainScheduled = true }
        stateLock.unlock()
        if shouldSchedule {
            encoderQueue.async { [weak self] in self?.drainEncoder() }
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
        pendingFrame = nil
        scheduleEncoderFinishLocked()
        stateLock.unlock()
    }

    func stopAndWait() {
        stop()
        encoderQueue.sync {}
        ioQueue.sync {}
    }

    private func drainEncoder() {
        while true {
            stateLock.lock()
            guard state == .recording,
                  framesInFlight < maximumEncoderFramesInFlight,
                  let frame = pendingFrame else {
                encoderDrainScheduled = false
                stateLock.unlock()
                return
            }
            pendingFrame = nil
            stateLock.unlock()

            guard ensureCompressionSession(for: frame) else {
                failAndFinish("VideoToolbox could not create the processed H.264 encoder")
                return
            }
            guard frame.width == encoderWidth, frame.height == encoderHeight else {
                failAndFinish(
                    "Processed output changed from \(encoderWidth)x\(encoderHeight) to \(frame.width)x\(frame.height) during recording"
                )
                return
            }

            let origin: CMTime
            stateLock.lock()
            if firstSourcePTS == nil { firstSourcePTS = frame.timing.presentationTime }
            origin = firstSourcePTS ?? frame.timing.presentationTime
            var outputPTS = CMTimeSubtract(frame.timing.presentationTime, origin)
            if let lastSubmittedPTS, CMTimeCompare(outputPTS, lastSubmittedPTS) <= 0 {
                outputPTS = CMTimeAdd(lastSubmittedPTS, frame.timing.nominalDuration)
            }
            lastSubmittedPTS = outputPTS
            lastSourcePTS = frame.timing.presentationTime
            lastSourceDuration = frame.timing.nominalDuration
            let forceKeyFrame = !firstFrameSubmitted
            firstFrameSubmitted = true
            framesInFlight += 1
            stateLock.unlock()

            let frameProperties: CFDictionary? = forceKeyFrame
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
                : nil
            let status = VTCompressionSessionEncodeFrame(
                compressionSession!,
                imageBuffer: frame.pixelBuffer,
                presentationTimeStamp: outputPTS,
                duration: frame.timing.nominalDuration,
                frameProperties: frameProperties,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
            if status != noErr {
                stateLock.lock()
                framesInFlight = max(0, framesInFlight - 1)
                stateLock.unlock()
                failAndFinish("VideoToolbox rejected a processed frame (OSStatus \(status))")
                return
            }
        }
    }

    private func ensureCompressionSession(for frame: ProcessedVideoFrame) -> Bool {
        if compressionSession != nil { return true }
        let width = frame.width
        let height = frame.height
        let bitrate = Self.qualityPriorityBitrate(width: width, height: height, fps: targetFPS)
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refCon, _, status, infoFlags, sampleBuffer in
                guard let refCon else { return }
                let recorder = Unmanaged<ProcessedH264Recorder>
                    .fromOpaque(refCon).takeUnretainedValue()
                recorder.handleEncodedFrame(
                    status: status,
                    infoFlags: infoFlags,
                    sampleBuffer: sampleBuffer
                )
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { return false }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
            (kVTCompressionPropertyKey_ExpectedFrameRate, targetFPS as CFNumber),
            (kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, (targetFPS * 2) as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        ]
        for (key, value) in properties {
            guard VTSessionSetProperty(session, key: key, value: value) == noErr else {
                VTCompressionSessionInvalidate(session)
                return false
            }
        }
        let byteLimit = max(1, bitrate / 8 * 2)
        let dataRateLimits = [byteLimit, 1] as CFArray
        guard VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: dataRateLimits
        ) == noErr,
        VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            return false
        }
        compressionSession = session
        encoderWidth = width
        encoderHeight = height
        encoderBitrate = bitrate
        return true
    }

    private func handleEncodedFrame(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?
    ) {
        stateLock.lock()
        framesInFlight = max(0, framesInFlight - 1)
        stateLock.unlock()

        if status != noErr {
            failAndFinish("Processed H.264 encoding failed (OSStatus \(status))")
            return
        }
        if infoFlags.contains(.frameDropped) {
            stateLock.lock()
            droppedByEncoder += 1
            let shouldResumeEncoder = state == .recording && pendingFrame != nil && !encoderDrainScheduled
            if shouldResumeEncoder { encoderDrainScheduled = true }
            emitStatsLockedIfNeeded(force: true)
            stateLock.unlock()
            if shouldResumeEncoder {
                encoderQueue.async { [weak self] in self?.drainEncoder() }
            }
            return
        }
        guard let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer),
              let annexB = Self.annexBData(sampleBuffer: sampleBuffer) else {
            failAndFinish("VideoToolbox returned an unusable processed H.264 sample")
            return
        }

        stateLock.lock()
        guard state != .idle else {
            stateLock.unlock()
            return
        }
        if pendingDiskBytes + annexB.count > maximumPendingDiskBytes {
            stateLock.unlock()
            failAndFinish("Recording stopped because the bounded disk queue reached 16 MiB")
            return
        }
        pendingChunks.append(annexB)
        pendingDiskBytes += annexB.count
        encodedFrames += 1
        encodedFramesInStatsWindow += 1
        scheduleIODrainLocked()
        let shouldResumeEncoder = state == .recording && pendingFrame != nil && !encoderDrainScheduled
        if shouldResumeEncoder { encoderDrainScheduled = true }
        emitStatsLockedIfNeeded()
        stateLock.unlock()

        if shouldResumeEncoder {
            encoderQueue.async { [weak self] in self?.drainEncoder() }
        }
    }

    private func failAndFinish(_ message: String) {
        stateLock.lock()
        if finishError == nil { finishError = message }
        if state == .recording {
            state = .finishing
            endedAt = Date()
            pendingFrame = nil
        }
        scheduleEncoderFinishLocked()
        stateLock.unlock()
    }

    private func scheduleEncoderFinishLocked() {
        guard !encoderFinishScheduled else { return }
        encoderFinishScheduled = true
        encoderQueue.async { [weak self] in self?.finishEncoder() }
    }

    private func finishEncoder() {
        if let compressionSession {
            let status = VTCompressionSessionCompleteFrames(
                compressionSession,
                untilPresentationTimeStamp: .invalid
            )
            if status != noErr {
                stateLock.lock()
                finishError = finishError ?? "Could not flush the processed H.264 encoder (OSStatus \(status))"
                stateLock.unlock()
            }
            VTCompressionSessionInvalidate(compressionSession)
            self.compressionSession = nil
        }
        stateLock.lock()
        encoderFinished = true
        scheduleIODrainLocked()
        stateLock.unlock()
    }

    private func scheduleIODrainLocked() {
        guard !ioDrainScheduled else { return }
        ioDrainScheduled = true
        ioQueue.async { [weak self] in self?.drainIO() }
    }

    private func popChunkLocked() -> Data? {
        guard pendingChunkHead < pendingChunks.count else { return nil }
        let data = pendingChunks[pendingChunkHead]
        pendingChunkHead += 1
        pendingDiskBytes -= data.count
        if pendingChunkHead >= 256, pendingChunkHead * 2 >= pendingChunks.count {
            pendingChunks.removeFirst(pendingChunkHead)
            pendingChunkHead = 0
        }
        return data
    }

    private func drainIO() {
        while true {
            stateLock.lock()
            if let chunk = popChunkLocked(), let handle {
                stateLock.unlock()
                do {
                    try handle.write(contentsOf: chunk)
                    stateLock.lock()
                    bytesWritten += UInt64(chunk.count)
                    stateLock.unlock()
                } catch {
                    stateLock.lock()
                    finishError = finishError ?? "Disk write failed: \(error.localizedDescription)"
                    if state == .recording {
                        state = .finishing
                        endedAt = Date()
                    }
                    pendingChunks.removeAll(keepingCapacity: false)
                    pendingChunkHead = 0
                    pendingDiskBytes = 0
                    scheduleEncoderFinishLocked()
                    stateLock.unlock()
                }
                continue
            }

            guard state == .finishing, encoderFinished else {
                ioDrainScheduled = false
                stateLock.unlock()
                return
            }
            let resultState = takeFinalizationStateLocked()
            stateLock.unlock()
            finalizeFile(resultState)
            return
        }
    }

    private struct FinalizationState {
        let handle: FileHandle?
        let directory: URL?
        let temporary: URL?
        let startedAt: Date
        let endedAt: Date
        let sourceDuration: TimeInterval?
        let bytesWritten: UInt64
        let encodedFrames: UInt64
        var errorDescription: String?
    }

    private func takeFinalizationStateLocked() -> FinalizationState {
        let sourceDuration: TimeInterval?
        if let firstSourcePTS, let lastSourcePTS {
            sourceDuration = CMTimeGetSeconds(
                CMTimeAdd(
                    CMTimeSubtract(lastSourcePTS, firstSourcePTS),
                    lastSourceDuration ?? CMTime(value: 3_000, timescale: 90_000)
                )
            )
        } else {
            sourceDuration = nil
        }
        let result = FinalizationState(
            handle: handle,
            directory: directoryURL,
            temporary: temporaryURL,
            startedAt: startedAt ?? Date(),
            endedAt: endedAt ?? Date(),
            sourceDuration: sourceDuration,
            bytesWritten: bytesWritten,
            encodedFrames: encodedFrames,
            errorDescription: finishError
        )
        handle = nil
        directoryURL = nil
        temporaryURL = nil
        startedAt = nil
        endedAt = nil
        firstSourcePTS = nil
        lastSourcePTS = nil
        lastSourceDuration = nil
        lastSubmittedPTS = nil
        pendingChunks.removeAll(keepingCapacity: false)
        pendingChunkHead = 0
        pendingDiskBytes = 0
        pendingFrame = nil
        state = .idle
        ioDrainScheduled = false
        encoderDrainScheduled = false
        encoderFinishScheduled = false
        encoderFinished = false
        return result
    }

    private func finalizeFile(_ initial: FinalizationState) {
        var state = initial
        do {
            try state.handle?.synchronize()
            try state.handle?.close()
        } catch {
            state.errorDescription = state.errorDescription ?? "Could not finish the file: \(error.localizedDescription)"
        }
        let wallDuration = state.endedAt.timeIntervalSince(state.startedAt)
        let duration = max(0, state.sourceDuration ?? wallDuration)
        if state.encodedFrames == 0 {
            state.errorDescription = state.errorDescription ?? "No processed frames were encoded while recording"
        }
        var resultURL = state.temporary ?? MediaFileNamer.temporaryVideoURL(
            directory: state.directory ?? MediaFileNamer.defaultDirectory,
            date: state.startedAt
        )
        if let directory = state.directory, let temporary = state.temporary {
            let completed = MediaFileNamer.completedVideoURL(
                directory: directory,
                date: state.startedAt,
                duration: duration
            )
            do {
                try FileManager.default.moveItem(at: temporary, to: completed)
                resultURL = completed
            } catch {
                state.errorDescription = state.errorDescription ?? "Could not apply the final filename: \(error.localizedDescription)"
            }
        }
        let result = H264RecordingResult(
            url: resultURL,
            duration: duration,
            bytesWritten: state.bytesWritten,
            errorDescription: state.errorDescription
        )
        DispatchQueue.main.async { [weak self] in self?.onFinished?(result) }
    }

    private func emitStatsLockedIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastStatsEmission) >= 1 else { return }
        lastStatsEmission = now
        let statsElapsed = max(0.001, now.timeIntervalSince(statsWindowStarted))
        let stats = ProcessedRecordingStats(
            width: encoderWidth,
            height: encoderHeight,
            targetFPS: targetFPS,
            bitrateMbps: Double(encoderBitrate) / 1_000_000,
            encodedFrames: encodedFrames,
            encodedFPS: Double(encodedFramesInStatsWindow) / statsElapsed,
            droppedBeforeEncoder: droppedBeforeEncoder,
            droppedByEncoder: droppedByEncoder,
            encoderInFlight: framesInFlight,
            diskQueueBytes: pendingDiskBytes
        )
        statsWindowStarted = now
        encodedFramesInStatsWindow = 0
        DispatchQueue.main.async { [weak self] in self?.onStats?(stats) }
    }

    private static func qualityPriorityBitrate(width: Int, height: Int, fps: Int) -> Int {
        // About 0.32 bits/pixel/frame, clamped to practical quality-priority
        // limits for 900p through UHD output.
        let estimated = Int(Double(width * height * fps) * 0.32)
        return min(80_000_000, max(12_000_000, estimated))
    }

    private static func annexBData(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        var nalHeaderLength: Int32 = 4
        var parameterSetCount = 0
        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetSize = 0
        _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: &parameterSetPointer,
            parameterSetSizeOut: &parameterSetSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )

        var output = Data()
        let isSync: Bool = {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ), let first = (attachments as NSArray).firstObject as? NSDictionary else { return false }
            return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        }()
        if isSync {
            for index in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                ) == noErr, let pointer, size > 0 else { continue }
                output.append(contentsOf: [0, 0, 0, 1])
                output.append(pointer, count: size)
            }
        }

        let dataLength = CMBlockBufferGetDataLength(blockBuffer)
        var avcc = Data(count: dataLength)
        let copyStatus = avcc.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: dataLength,
                destination: bytes.baseAddress!
            )
        }
        guard copyStatus == kCMBlockBufferNoErr,
              let converted = convertLengthPrefixedNALs(avcc, lengthFieldBytes: Int(nalHeaderLength)) else {
            return nil
        }
        output.append(converted)
        return output
    }

    static func convertLengthPrefixedNALs(_ data: Data, lengthFieldBytes: Int) -> Data? {
        guard (1...4).contains(lengthFieldBytes) else { return nil }
        var offset = 0
        var output = Data()
        while offset < data.count {
            guard offset + lengthFieldBytes <= data.count else { return nil }
            var length = 0
            for byte in data[offset..<(offset + lengthFieldBytes)] {
                length = (length << 8) | Int(byte)
            }
            offset += lengthFieldBytes
            guard length > 0, offset + length <= data.count else { return nil }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(data[offset..<(offset + length)])
            offset += length
        }
        return output
    }

    static func selfTest() -> Bool {
        let avcc = Data([0, 0, 0, 3, 0x65, 0xaa, 0xbb, 0, 0, 0, 2, 0x41, 0xcc])
        return convertLengthPrefixedNALs(avcc, lengthFieldBytes: 4) ==
            Data([0, 0, 0, 1, 0x65, 0xaa, 0xbb, 0, 0, 0, 1, 0x41, 0xcc]) &&
            convertLengthPrefixedNALs(Data([0, 0, 0, 9, 0x65]), lengthFieldBytes: 4) == nil
    }
}

private func processedRecordingError(_ message: String) -> NSError {
    NSError(
        domain: "ParrotLab.ProcessedH264Recorder",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
