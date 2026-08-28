import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import QuartzCore
import VideoToolbox

private final class DecodedVideoFrameContext {
    let timing: VideoFrameTiming
    let motion: VerifiedVideoFrameMotion?

    init(timing: VideoFrameTiming, motion: VerifiedVideoFrameMotion?) {
        self.timing = timing
        self.motion = motion
    }
}

struct VideoPipelineStats: Equatable {
    let decodedFPS: Double
    let displayRefreshFPS: Double
    let processedFPS: Double
    let processingDroppedFrames: UInt64
    let processingLatencyMilliseconds: Double
    let processedWidth: Int
    let processedHeight: Int
    let temporalHistoryDepth: Int
    let temporalHistoryAgeMilliseconds: Double
    let temporalMotionAvailable: Bool
    let temporalMotionConfidence: Double?
    let temporalReprojectionStatus: String
    let temporalFlowLatencyMilliseconds: Double?
    let temporalHistoryUsed: Bool
    let lastRTPTimestamp: UInt32?
    let motionAssociationOffsetMilliseconds: Double?
    let cameraCalibrationStatus: String
    let cameraReadoutStatus: String
    let rollingShutterStatus: String
}

enum VideoEnhancementPreset: Int, CaseIterable {
    case off
    case denoise
    case h264ArtifactRepair
    case clarity
    case lowLight
    case upscale2x
    case upscaleClarity2x

    var menuTitle: String {
        switch self {
        case .off: return "Off · Source Image"
        case .denoise: return "Denoise"
        case .h264ArtifactRepair: return "H.264 Artifact Repair · Color Blocks + Mosquito Noise"
        case .clarity: return "Clarity"
        case .lowLight: return "Low-Light Cleanup"
        case .upscale2x: return "High-Quality 2× Upscale"
        case .upscaleClarity2x: return "2× Upscale + Clarity"
        }
    }

    var statusLabel: String {
        switch self {
        case .off: return "OFF"
        case .denoise: return "DENOISE"
        case .h264ArtifactRepair: return "H264 REPAIR"
        case .clarity: return "CLARITY"
        case .lowLight: return "LOW LIGHT"
        case .upscale2x: return "2X UPSCALE"
        case .upscaleClarity2x: return "2X + CLARITY"
        }
    }
}

enum VideoSpatialScalingMode: Int, CaseIterable {
    case off = 0
    case metalFX2x = 1
    case metalFX1080p = 2
    case metalFX1440p = 3
    case metalFX1800p = 4
    case metalFX2160p = 5

    var menuTitle: String {
        switch self {
        case .off: return "Off · Native Resolution"
        case .metalFX2x: return "Apple MetalFX Spatial · 2×"
        case .metalFX1080p: return "Apple MetalFX Spatial · 1920 × 1080"
        case .metalFX1440p: return "Apple MetalFX Spatial · 2560 × 1440"
        case .metalFX1800p: return "Apple MetalFX Spatial · 3200 × 1800"
        case .metalFX2160p: return "Apple MetalFX Spatial · 3840 × 2160"
        }
    }

    var statusLabel: String {
        switch self {
        case .off: return "OFF"
        case .metalFX2x: return "METALFX 2X"
        case .metalFX1080p: return "METALFX 1080P"
        case .metalFX1440p: return "METALFX 1440P"
        case .metalFX1800p: return "METALFX 1800P"
        case .metalFX2160p: return "METALFX 4K"
        }
    }

    var usesMetalFX: Bool { self != .off }

    func outputDimensions(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        switch self {
        case .off:
            return (Self.even(sourceWidth), Self.even(sourceHeight))
        case .metalFX2x:
            return (Self.even(sourceWidth * 2), Self.even(sourceHeight * 2))
        case .metalFX1080p:
            return (1_920, 1_080)
        case .metalFX1440p:
            return (2_560, 1_440)
        case .metalFX1800p:
            return (3_200, 1_800)
        case .metalFX2160p:
            return (3_840, 2_160)
        }
    }

    private static func even(_ value: Int) -> Int { max(2, value & ~1) }
}

final class H264VideoView: NSView {
    var onDebug: ((String) -> Void)?
    var onFormat: ((Int, Int) -> Void)?
    var onCodedFormat: ((Int, Int) -> Void)?
    var onMetadataPresence: ((VideoMetadataPresence) -> Void)?
    var onFrameReady: (() -> Void)?
    var onPipelineStats: ((VideoPipelineStats) -> Void)?
    var onProcessedFrame: ((ProcessedVideoFrame) -> Void)?
    var receiveMode: VideoReceiveMode = .compatibility {
        didSet {
            guard receiveMode != oldValue else { return }
            reset()
        }
    }
    var enhancementPreset: VideoEnhancementPreset {
        get {
            enhancementLock.lock()
            defer { enhancementLock.unlock() }
            return storedEnhancementPreset
        }
        set {
            enhancementLock.lock()
            storedEnhancementPreset = newValue
            let scaling = storedSpatialScalingMode
            enhancementLock.unlock()
            processingPipeline.update(enhancement: newValue, scaling: scaling)
        }
    }
    var spatialScalingMode: VideoSpatialScalingMode {
        get {
            enhancementLock.lock()
            defer { enhancementLock.unlock() }
            return storedSpatialScalingMode
        }
        set {
            enhancementLock.lock()
            storedSpatialScalingMode = newValue
            let enhancement = storedEnhancementPreset
            enhancementLock.unlock()
            processingPipeline.update(enhancement: enhancement, scaling: newValue)
        }
    }
    var isMetalFXSpatialScalingSupported: Bool { processingPipeline.isMetalFXSupported }
    var rollingShutterConfiguration: RollingShutterProcessingConfiguration {
        get {
            enhancementLock.lock()
            defer { enhancementLock.unlock() }
            return storedRollingShutterConfiguration
        }
        set {
            enhancementLock.lock()
            storedRollingShutterConfiguration = newValue
            enhancementLock.unlock()
            processingPipeline.updateRollingShutterConfiguration(newValue)
        }
    }
    var temporalReconstructionConfiguration: TemporalReconstructionConfiguration {
        get {
            enhancementLock.lock()
            defer { enhancementLock.unlock() }
            return storedTemporalReconstructionConfiguration
        }
        set {
            enhancementLock.lock()
            storedTemporalReconstructionConfiguration = newValue
            enhancementLock.unlock()
            processingPipeline.updateTemporalReconstructionConfiguration(newValue)
        }
    }
    private let videoLayer = AVSampleBufferDisplayLayer()
    private let stillImageContext = CIContext(options: [.cacheIntermediates: false])
    private let softwareColorSpace = CGColorSpaceCreateDeviceRGB()
    private let enhancementLock = NSLock()
    private var storedEnhancementPreset = VideoEnhancementPreset.off
    private var storedSpatialScalingMode = VideoSpatialScalingMode.off
    private var storedRollingShutterConfiguration = RollingShutterProcessingConfiguration()
    private var storedTemporalReconstructionConfiguration = TemporalReconstructionConfiguration()
    private let processingPipeline = LiveVideoProcessingPipeline()
    private var formatDescription: CMVideoFormatDescription?
    private var visibleSourceRect: CGRect?
    private var rtpTimestampMapper = RTPVideoTimestampMapper()
    private var lastDroneVideoQuaternion: VideoMetadataQuaternion?
    private var lastFrameVideoQuaternion: VideoMetadataQuaternion?
    private var decompressionSession: VTDecompressionSession?
    private var softwareDecoder: FFmpegVideoDecoder?
    private var sps: Data?
    private var pps: Data?
    private var reportedParameterSets = false
    private var reportedFirstFrame = false
    private var dumpHandle: FileHandle?
    private var dumpedAccessUnits = 0
    private var reportedFirstDecodedFrame = false
    private var hardwareFallbackWorkItem: DispatchWorkItem?
    private var metadataPresence = VideoMetadataPresence()
    private var extensionDumpHandle: FileHandle?
    private var dumpedExtensionAccessUnits = 0
    private var latestProcessedPixelBuffer: CVPixelBuffer?
    private var displayFormatDescription: CMVideoFormatDescription?
    private var displayFormatKey: String?
    private let hardwareFrameLock = NSLock()
    private var pendingHardwareFrame: ProcessedVideoFrame?
    private var hardwareFrameDeliveryScheduled = false
    private let frameRateLock = NSLock()
    private var decodedFramesInWindow = 0
    private var displayedFramesInWindow = 0
    private var frameRateWindowStarted = Date()
    private var latestProcessingStats = LiveVideoProcessingStats(
        processedFPS: 0,
        droppedBeforeProcessing: 0,
        outputWidth: 0,
        outputHeight: 0,
        averageLatencyMilliseconds: 0,
        temporalHistoryDepth: 0,
        temporalHistoryAgeMilliseconds: 0,
        temporalMotionAvailable: false,
        temporalMotionConfidence: nil,
        temporalReprojectionStatus: "BYPASSED · NO FRAME MOTION",
        temporalFlowLatencyMilliseconds: nil,
        temporalHistoryUsed: false,
        lastRTPTimestamp: nil,
        motionAssociationOffsetMilliseconds: nil,
        cameraCalibrationStatus: Bebop900pCameraCalibration.profile.statusLabel,
        cameraReadoutStatus: "ROW LUT 31.167 ms · CURVED LEFT→RIGHT",
        rollingShutterStatus: "RS OFF · CALIBRATION AVAILABLE"
    )

    private static let legacyFrameInfoUUID = Data([
        0x97, 0x77, 0x08, 0x83, 0xc8, 0xd3, 0x40, 0x2e,
        0x9c, 0xf8, 0xb1, 0x0a, 0x41, 0xf9, 0x12, 0xd4
    ])

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.actions = ["contents": NSNull()]
        layer?.addSublayer(videoLayer)
        processingPipeline.onDebug = { [weak self] message in self?.onDebug?(message) }
        processingPipeline.onFrame = { [weak self] frame in
            guard let self else { return }
            self.onProcessedFrame?(frame)
            self.enqueueLatestHardwareFrame(frame)
        }
        processingPipeline.onStats = { [weak self] stats in
            guard let self else { return }
            self.frameRateLock.lock()
            self.latestProcessingStats = stats
            self.frameRateLock.unlock()
        }
        processingPipeline.update(enhancement: .off, scaling: .off)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        videoLayer.frame = bounds
    }

    func display(accessUnit: H264AccessUnit) {
        let nalUnits = accessUnit.nalUnits
        captureRTPHeaderExtensions(accessUnit)
        observeMetadata(in: accessUnit)
        for nalu in nalUnits {
            guard let byte = nalu.first else { continue }
            switch byte & 0x1f {
            case 7: sps = nalu
            case 8: pps = nalu
            default: break
            }
        }
        captureAnnexB(nalUnits)
        if formatDescription == nil { rebuildFormatDescription() }
        guard let formatDescription else { return }

        let frameNALs = nalUnits.filter {
            guard let byte = $0.first else { return false }
            return ![7, 8, 9].contains(Int(byte & 0x1f))
        }
        guard frameNALs.contains(where: {
            guard let byte = $0.first else { return false }
            return (1...5).contains(Int(byte & 0x1f))
        }) else { return }
        let frameTiming = rtpTimestampMapper.timing(for: accessUnit.rtpTimestamp)
        let verifiedMotion = accessUnit.videoMetadata.map {
            makeVerifiedMotion(metadata: $0, timing: frameTiming)
        }

        if softwareDecoder != nil {
            softwareDecoder?.feed(nalUnits: nalUnits, timing: frameTiming, motion: verifiedMotion)
            if !reportedFirstFrame {
                reportedFirstFrame = true
                onDebug?("First H.264 access unit sent to recovery decoder (NAL types: \(frameNALs.compactMap { $0.first.map { String($0 & 0x1f) } }.joined(separator: ",")))")
            }
            return
        }

        var sampleData = Data()
        for nalu in frameNALs {
            var size = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &size) { sampleData.append(contentsOf: $0) }
            sampleData.append(nalu)
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return }
        let replaceStatus = sampleData.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sampleData.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return }

        var timing = CMSampleTimingInfo(
            duration: frameTiming.nominalDuration,
            presentationTimeStamp: frameTiming.presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = sampleData.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           let first = (attachments as NSArray).firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
            // Bebop/ARStream2 uses periodic I-slices inside non-IDR type-1
            // NAL units instead of emitting type-5 IDRs.
            let isSync = frameNALs.contains { isRandomAccessNAL($0) }
            first[kCMSampleAttachmentKey_NotSync] = !isSync
            first[kCMSampleAttachmentKey_DependsOnOthers] = !isSync
        }

        decode(sampleBuffer, timing: frameTiming, motion: verifiedMotion)
        if !reportedFirstFrame {
            reportedFirstFrame = true
            onDebug?("First H.264 access unit queued (NAL types: \(frameNALs.compactMap { $0.first.map { String($0 & 0x1f) } }.joined(separator: ",")))")
        }
    }

    func reset() {
        hardwareFallbackWorkItem?.cancel()
        hardwareFallbackWorkItem = nil
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
        softwareDecoder?.stop()
        softwareDecoder = nil
        processingPipeline.reset()
        rtpTimestampMapper.reset()
        lastDroneVideoQuaternion = nil
        lastFrameVideoQuaternion = nil
        hardwareFrameLock.lock()
        pendingHardwareFrame = nil
        hardwareFrameDeliveryScheduled = false
        hardwareFrameLock.unlock()
        videoLayer.flushAndRemoveImage()
        latestProcessedPixelBuffer = nil
        displayFormatDescription = nil
        displayFormatKey = nil
        formatDescription = nil
        visibleSourceRect = nil
        sps = nil
        pps = nil
        reportedParameterSets = false
        reportedFirstFrame = false
        reportedFirstDecodedFrame = false
        try? dumpHandle?.close()
        dumpHandle = nil
        dumpedAccessUnits = 0
        metadataPresence = VideoMetadataPresence()
        try? extensionDumpHandle?.close()
        extensionDumpHandle = nil
        dumpedExtensionAccessUnits = 0
        frameRateLock.lock()
        decodedFramesInWindow = 0
        displayedFramesInWindow = 0
        frameRateWindowStarted = Date()
        latestProcessingStats = LiveVideoProcessingStats(
            processedFPS: 0,
            droppedBeforeProcessing: 0,
            outputWidth: 0,
            outputHeight: 0,
            averageLatencyMilliseconds: 0,
            temporalHistoryDepth: 0,
            temporalHistoryAgeMilliseconds: 0,
            temporalMotionAvailable: false,
            temporalMotionConfidence: nil,
            temporalReprojectionStatus: "BYPASSED · NO FRAME MOTION",
            temporalFlowLatencyMilliseconds: nil,
            temporalHistoryUsed: false,
            lastRTPTimestamp: nil,
            motionAssociationOffsetMilliseconds: nil,
            cameraCalibrationStatus: Bebop900pCameraCalibration.profile.statusLabel,
            cameraReadoutStatus: "ROW LUT 31.167 ms · CURVED LEFT→RIGHT",
            rollingShutterStatus: "RS OFF · CALIBRATION AVAILABLE"
        )
        frameRateLock.unlock()
    }

    private func rebuildFormatDescription() {
        guard let sps, let pps else { return }
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        if status == noErr {
            formatDescription = description
            if let description {
                let coded = CMVideoFormatDescriptionGetDimensions(description)
                let codedRect = CGRect(x: 0, y: 0, width: Int(coded.width), height: Int(coded.height))
                let clean = CMVideoFormatDescriptionGetCleanAperture(
                    description,
                    originIsAtTopLeft: false
                ).intersection(codedRect)
                visibleSourceRect = clean.isNull || clean.isEmpty ? codedRect : clean
            }
            rebuildDecompressionSession(description)
            if !reportedParameterSets {
                reportedParameterSets = true
                if let description {
                    let coded = CMVideoFormatDescriptionGetDimensions(description)
                    let presentation = CMVideoFormatDescriptionGetPresentationDimensions(
                        description,
                        usePixelAspectRatio: true,
                        useCleanAperture: true
                    )
                    let width = Int(presentation.width.rounded())
                    let height = Int(presentation.height.rounded())
                    onFormat?(width, height)
                    onCodedFormat?(Int(coded.width), Int(coded.height))
                    if receiveMode.is900p,
                       Int(coded.width) != 1_600 || !(900...912).contains(Int(coded.height)) {
                        onDebug?("900p receiver expected 1600x900/912 but SPS reports \(Int(coded.width))x\(Int(coded.height)); continuing safely")
                    }
                }
                onDebug?("H.264 SPS/PPS accepted")
            }
        } else {
            onDebug?("H.264 SPS/PPS rejected: OSStatus \(status)")
        }
    }

    private func makeVerifiedMotion(
        metadata: VideoMetadataV2,
        timing: VideoFrameTiming
    ) -> VerifiedVideoFrameMotion {
        let quaternionError = abs(metadata.droneQuaternion.norm - 1) +
            abs(metadata.frameQuaternion.norm - 1)
        let drone = metadata.droneQuaternion.preservingSignContinuity(
            after: lastDroneVideoQuaternion
        )
        let frame = metadata.frameQuaternion.preservingSignContinuity(
            after: lastFrameVideoQuaternion
        )
        lastDroneVideoQuaternion = drone
        lastFrameVideoQuaternion = frame
        return VerifiedVideoFrameMotion(
            sampleTime: timing.presentationTime,
            rtpTimestamp: metadata.rtpTimestamp,
            droneQuaternion: drone,
            frameQuaternion: frame,
            cameraPanRadians: metadata.cameraPanRadians,
            cameraTiltRadians: metadata.cameraTiltRadians,
            exposureDurationSeconds: metadata.exposureMilliseconds / 1_000,
            confidence: max(0, min(1, 1 - quaternionError * 10))
        )
    }

    private func rebuildDecompressionSession(_ description: CMFormatDescription?) {
        guard let description else { return }
        hardwareFallbackWorkItem?.cancel()
        hardwareFallbackWorkItem = nil
        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
            self.decompressionSession = nil
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        if receiveMode.prefersVideoToolbox,
           createVideoToolboxSession(description: description) {
            scheduleHardwareDecoderFallback(
                width: Int(dimensions.width),
                height: Int(dimensions.height)
            )
            return
        }

        if startSoftwareDecoder(width: Int(dimensions.width), height: Int(dimensions.height)) {
            return
        }
        _ = createVideoToolboxSession(description: description)
    }

    private func startSoftwareDecoder(width: Int, height: Int) -> Bool {
        softwareDecoder?.stop()
        softwareDecoder = nil
        if let decoder = FFmpegVideoDecoder(width: width, height: height) {
            decoder.onDebug = { [weak self] message in
                DispatchQueue.main.async { self?.onDebug?(message) }
            }
            decoder.onDecodedFrame = { [weak self] in
                self?.recordFrameRate(decoded: 1, displayed: 0)
            }
            decoder.onFrame = { [weak self] data, width, height, timing, motion in
                self?.handleSoftwareFrame(
                    data: data,
                    width: width,
                    height: height,
                    timing: timing,
                    motion: motion
                )
            }
            if decoder.start() {
                softwareDecoder = decoder
                if let sps, let pps { decoder.feed(nalUnits: [sps, pps]) }
                return true
            }
        }
        return false
    }

    private func createVideoToolboxSession(description: CMFormatDescription) -> Bool {
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, sourceFrameRefCon, status, _, imageBuffer, _, _ in
                guard let refCon else { return }
                let view = Unmanaged<H264VideoView>.fromOpaque(refCon).takeUnretainedValue()
                let context = sourceFrameRefCon.map {
                    Unmanaged<DecodedVideoFrameContext>.fromOpaque($0).takeRetainedValue()
                }
                view.handleDecodedFrame(
                    status: status,
                    imageBuffer: imageBuffer,
                    timing: context?.timing,
                    motion: context?.motion
                )
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: pixelAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        if status == noErr {
            decompressionSession = session
            onDebug?("VideoToolbox decompression session ready")
            return true
        } else {
            onDebug?("Could not create VideoToolbox decoder: OSStatus \(status)")
            return false
        }
    }

    private func scheduleHardwareDecoderFallback(width: Int, height: Int) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.reportedFirstDecodedFrame, self.softwareDecoder == nil else { return }
            self.onDebug?("VideoToolbox produced no frame in 3 seconds; switching the 900p receiver to the recovery decoder")
            if let decompressionSession = self.decompressionSession {
                VTDecompressionSessionInvalidate(decompressionSession)
                self.decompressionSession = nil
            }
            _ = self.startSoftwareDecoder(width: width, height: height)
        }
        hardwareFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func decode(
        _ sampleBuffer: CMSampleBuffer,
        timing: VideoFrameTiming,
        motion: VerifiedVideoFrameMotion?
    ) {
        guard let decompressionSession else { return }
        let frameContext = Unmanaged.passRetained(
            DecodedVideoFrameContext(timing: timing, motion: motion)
        )
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: frameContext.toOpaque(),
            infoFlagsOut: &infoFlags,
        )
        if status != noErr {
            frameContext.release()
            onDebug?("VideoToolbox rejected access unit: OSStatus \(status)")
        }
    }

    private func handleDecodedFrame(
        status: OSStatus,
        imageBuffer: CVImageBuffer?,
        timing: VideoFrameTiming?,
        motion: VerifiedVideoFrameMotion?
    ) {
        guard status == noErr, let imageBuffer, let timing else {
            DispatchQueue.main.async { [weak self] in
                self?.onDebug?("VideoToolbox frame decode failed: OSStatus \(status)")
            }
            return
        }
        recordFrameRate(decoded: 1, displayed: 0)
        processingPipeline.submit(DecodedVideoFrame(
            image: .pixelBuffer(imageBuffer),
            timing: timing,
            visibleRect: visibleSourceRect,
            verifiedMotion: motion
        ))
    }

    private func enqueueLatestHardwareFrame(_ frame: ProcessedVideoFrame) {
        hardwareFrameLock.lock()
        pendingHardwareFrame = frame
        let shouldSchedule = !hardwareFrameDeliveryScheduled
        if shouldSchedule { hardwareFrameDeliveryScheduled = true }
        hardwareFrameLock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.deliverLatestHardwareFrame() }
        }
    }

    private func deliverLatestHardwareFrame() {
        hardwareFrameLock.lock()
        let frame = pendingHardwareFrame
        pendingHardwareFrame = nil
        hardwareFrameLock.unlock()

        if let frame {
            hardwareFallbackWorkItem?.cancel()
            hardwareFallbackWorkItem = nil
            latestProcessedPixelBuffer = frame.pixelBuffer
            if videoLayer.status == .failed { videoLayer.flush() }
            if videoLayer.isReadyForMoreMediaData,
               let sampleBuffer = displaySampleBuffer(for: frame) {
                videoLayer.enqueue(sampleBuffer)
                recordFrameRate(decoded: 0, displayed: 1)
                if !reportedFirstDecodedFrame {
                    reportedFirstDecodedFrame = true
                    onDebug?("First processed IOSurface displayed: \(frame.width)x\(frame.height)")
                    onFrameReady?()
                }
            }
        }

        hardwareFrameLock.lock()
        let shouldContinue = pendingHardwareFrame != nil
        if !shouldContinue { hardwareFrameDeliveryScheduled = false }
        hardwareFrameLock.unlock()
        if shouldContinue {
            DispatchQueue.main.async { [weak self] in self?.deliverLatestHardwareFrame() }
        }
    }

    private func handleSoftwareFrame(
        data: Data,
        width: Int,
        height: Int,
        timing: VideoFrameTiming,
        motion: VerifiedVideoFrameMotion?
    ) {
        // FFmpegVideoDecoder coalesces delivery onto the main queue, keeping at
        // most one not-yet-presented RGBA frame alive.
        dispatchPrecondition(condition: .onQueue(.main))
        autoreleasepool {
            guard data.count == width * height * 4,
                  let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: width * 4,
                    space: softwareColorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                  ) else { return }

            processingPipeline.submit(DecodedVideoFrame(
                image: .cgImage(image),
                timing: timing,
                visibleRect: visibleSourceRect,
                verifiedMotion: motion
            ))
        }
    }

    /// Returns the most recent processed output frame without the HUD overlay.
    /// Its enhancement and MetalFX resolution match live display and normal
    /// recording at the moment the picture is taken. The image is immutable
    /// and safe to hand to the background image writer.
    func latestFrameImage() -> CGImage? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let latestProcessedPixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: latestProcessedPixelBuffer)
        return stillImageContext.createCGImage(
            image,
            from: image.extent.integral,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
    }

    private func displaySampleBuffer(for frame: ProcessedVideoFrame) -> CMSampleBuffer? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let key = "\(frame.width)x\(frame.height)-\(pixelFormat)"
        if displayFormatDescription == nil || displayFormatKey != key {
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescriptionOut: &description
            ) == noErr else { return nil }
            displayFormatDescription = description
            displayFormatKey = key
        }
        guard let displayFormatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: frame.timing.nominalDuration,
            presentationTimeStamp: frame.timing.presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: displayFormatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), let first = (attachments as NSArray).firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sampleBuffer
    }

    private func recordFrameRate(decoded: Int, displayed: Int) {
        frameRateLock.lock()
        decodedFramesInWindow += decoded
        displayedFramesInWindow += displayed
        let elapsed = Date().timeIntervalSince(frameRateWindowStarted)
        guard elapsed >= 1.0 else {
            frameRateLock.unlock()
            return
        }
        let stats = VideoPipelineStats(
            decodedFPS: Double(decodedFramesInWindow) / elapsed,
            displayRefreshFPS: Double(displayedFramesInWindow) / elapsed,
            processedFPS: latestProcessingStats.processedFPS,
            processingDroppedFrames: latestProcessingStats.droppedBeforeProcessing,
            processingLatencyMilliseconds: latestProcessingStats.averageLatencyMilliseconds,
            processedWidth: latestProcessingStats.outputWidth,
            processedHeight: latestProcessingStats.outputHeight,
            temporalHistoryDepth: latestProcessingStats.temporalHistoryDepth,
            temporalHistoryAgeMilliseconds: latestProcessingStats.temporalHistoryAgeMilliseconds,
            temporalMotionAvailable: latestProcessingStats.temporalMotionAvailable,
            temporalMotionConfidence: latestProcessingStats.temporalMotionConfidence,
            temporalReprojectionStatus: latestProcessingStats.temporalReprojectionStatus,
            temporalFlowLatencyMilliseconds: latestProcessingStats.temporalFlowLatencyMilliseconds,
            temporalHistoryUsed: latestProcessingStats.temporalHistoryUsed,
            lastRTPTimestamp: latestProcessingStats.lastRTPTimestamp,
            motionAssociationOffsetMilliseconds: latestProcessingStats.motionAssociationOffsetMilliseconds,
            cameraCalibrationStatus: latestProcessingStats.cameraCalibrationStatus,
            cameraReadoutStatus: latestProcessingStats.cameraReadoutStatus,
            rollingShutterStatus: latestProcessingStats.rollingShutterStatus
        )
        decodedFramesInWindow = 0
        displayedFramesInWindow = 0
        frameRateWindowStarted = Date()
        frameRateLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onPipelineStats?(stats) }
    }

    private func captureAnnexB(_ nalUnits: [Data]) {
        guard dumpedAccessUnits < 300 else { return }
        let url = URL(fileURLWithPath: "/tmp/parrotlab-capture.h264")
        let startCode = Data([0, 0, 0, 1])
        if dumpHandle == nil {
            guard let sps, let pps else { return }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            dumpHandle = try? FileHandle(forWritingTo: url)
            try? dumpHandle?.truncate(atOffset: 0)
            for parameterSet in [sps, pps] where !nalUnits.contains(parameterSet) {
                try? dumpHandle?.write(contentsOf: startCode)
                try? dumpHandle?.write(contentsOf: parameterSet)
            }
            onDebug?("Capturing 300 H.264 access units to \(url.path)")
        }
        for nalu in nalUnits {
            try? dumpHandle?.write(contentsOf: startCode)
            try? dumpHandle?.write(contentsOf: nalu)
        }
        dumpedAccessUnits += 1
        if dumpedAccessUnits == 300 {
            try? dumpHandle?.close()
            dumpHandle = nil
            onDebug?("H.264 diagnostic capture complete: \(url.path)")
        }
    }

    private func captureRTPHeaderExtensions(_ accessUnit: H264AccessUnit) {
        guard receiveMode.is900p,
              !accessUnit.rtpHeaderExtensions.isEmpty,
              dumpedExtensionAccessUnits < 300 else { return }
        let url = URL(fileURLWithPath: "/tmp/parrotlab-rtp-extensions.bin")
        if extensionDumpHandle == nil {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            extensionDumpHandle = try? FileHandle(forWritingTo: url)
            try? extensionDumpHandle?.truncate(atOffset: 0)
            onDebug?("Capturing capped raw RTP extensions to \(url.path)")
        }
        for extensionData in accessUnit.rtpHeaderExtensions {
            var timestamp = accessUnit.rtpTimestamp.bigEndian
            var length = UInt32(extensionData.count).bigEndian
            try? extensionDumpHandle?.write(contentsOf: Data(bytes: &timestamp, count: MemoryLayout.size(ofValue: timestamp)))
            try? extensionDumpHandle?.write(contentsOf: Data(bytes: &length, count: MemoryLayout.size(ofValue: length)))
            try? extensionDumpHandle?.write(contentsOf: extensionData)
        }
        dumpedExtensionAccessUnits += 1
        if dumpedExtensionAccessUnits == 300 {
            try? extensionDumpHandle?.close()
            extensionDumpHandle = nil
            onDebug?("RTP-extension diagnostic capture complete: \(url.path)")
        }
    }

    private func observeMetadata(in accessUnit: H264AccessUnit) {
        let previous = metadataPresence
        if !metadataPresence.hasLegacyFrameInfoSEI,
           Self.containsLegacyFrameInfoSEI(in: accessUnit.nalUnits) {
            metadataPresence.hasLegacyFrameInfoSEI = true
            onDebug?("Legacy Parrot FrameInfo V3 SEI detected")
        }
        if !metadataPresence.hasRTPHeaderExtensions,
           !accessUnit.rtpHeaderExtensions.isEmpty {
            metadataPresence.hasRTPHeaderExtensions = true
            onDebug?("RTP header-extension metadata detected")
        }
        if !metadataPresence.hasDecodedVideoMetadataV2,
           accessUnit.videoMetadata != nil {
            metadataPresence.hasDecodedVideoMetadataV2 = true
            onDebug?("Synchronized Parrot VideoMetadataV2 decoded from the RTP extension")
        }
        if metadataPresence != previous { onMetadataPresence?(metadataPresence) }
    }

    private static func containsLegacyFrameInfoSEI(in nalUnits: [Data]) -> Bool {
        nalUnits.contains { nalu in
            guard let header = nalu.first, header & 0x1f == 6 else { return false }
            return nalu.range(of: legacyFrameInfoUUID) != nil
        }
    }

    static func metadataSelfTest() -> Bool {
        let matchingSEI = Data([0x06, 0x05, 0x10]) + legacyFrameInfoUUID + Data([0x80])
        let wrongNALType = Data([0x01]) + legacyFrameInfoUUID
        return containsLegacyFrameInfoSEI(in: [matchingSEI]) &&
            !containsLegacyFrameInfoSEI(in: [wrongNALType]) &&
            !containsLegacyFrameInfoSEI(in: [Data([0x06, 0x01, 0x02])])
    }

    private func isRandomAccessNAL(_ nalu: Data) -> Bool {
        guard let header = nalu.first else { return false }
        let nalType = header & 0x1f
        if nalType == 5 { return true }
        guard nalType == 1 else { return false }

        // Convert the slice-header prefix from EBSP to RBSP.
        let source = [UInt8](nalu.dropFirst())
        var rbsp: [UInt8] = []
        rbsp.reserveCapacity(source.count)
        var zeroCount = 0
        for byte in source {
            if zeroCount >= 2, byte == 0x03 {
                zeroCount = 0
                continue
            }
            rbsp.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }

        var bitIndex = 0
        func readBit() -> Int? {
            guard bitIndex < rbsp.count * 8 else { return nil }
            let value = Int((rbsp[bitIndex / 8] >> UInt8(7 - bitIndex % 8)) & 1)
            bitIndex += 1
            return value
        }
        func readUE() -> Int? {
            var leadingZeros = 0
            while let bit = readBit(), bit == 0 {
                leadingZeros += 1
                guard leadingZeros < 31 else { return nil }
            }
            var suffix = 0
            for _ in 0..<leadingZeros {
                guard let bit = readBit() else { return nil }
                suffix = (suffix << 1) | bit
            }
            return (1 << leadingZeros) - 1 + suffix
        }

        guard readUE() != nil, let sliceType = readUE() else { return false }
        return sliceType % 5 == 2 || sliceType % 5 == 4
    }
}
