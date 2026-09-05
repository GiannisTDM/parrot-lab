import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal

/// RTP's 90 kHz clock is the source of truth for decoded, processed, displayed,
/// and recorded video timing. `presentationTime` is normalized to the first
/// access unit after each receiver reset while `rtpTimestamp` preserves the
/// original 32-bit value for diagnostics.
struct VideoFrameTiming: Equatable {
    let rtpTimestamp: UInt32
    let presentationTime: CMTime
    let nominalDuration: CMTime
}

struct RTPVideoTimestampMapper {
    private var wrapCount: UInt64 = 0
    private var lastRawTimestamp: UInt32?
    private var firstExtendedTimestamp: UInt64?
    private var lastExtendedTimestamp: UInt64?
    private var cadenceSamples: [UInt64] = []
    private var nominalDurationTicks: UInt64 = 3_000

    mutating func timing(for rawTimestamp: UInt32) -> VideoFrameTiming {
        if let lastRawTimestamp,
           lastRawTimestamp > rawTimestamp,
           lastRawTimestamp &- rawTimestamp > UInt32.max / 2 {
            wrapCount += 1
        }
        lastRawTimestamp = rawTimestamp

        let extended = UInt64(rawTimestamp) + wrapCount * (UInt64(UInt32.max) + 1)
        if let lastExtendedTimestamp, extended > lastExtendedTimestamp {
            let delta = extended - lastExtendedTimestamp
            // Accept ordinary 20...90 fps cadence, but reject timestamp gaps
            // caused by missing frames. A short median suppresses the normal
            // +/- one-tick rounding around Bebop's observed 3003-tick cadence.
            if (1_000...4_500).contains(delta) {
                cadenceSamples.append(delta)
                if cadenceSamples.count > 15 { cadenceSamples.removeFirst() }
                nominalDurationTicks = cadenceSamples.sorted()[cadenceSamples.count / 2]
            }
        }
        lastExtendedTimestamp = extended
        if firstExtendedTimestamp == nil { firstExtendedTimestamp = extended }
        let origin = firstExtendedTimestamp ?? extended
        let relative = extended >= origin ? extended - origin : 0
        return VideoFrameTiming(
            rtpTimestamp: rawTimestamp,
            presentationTime: CMTime(value: Int64(relative), timescale: 90_000),
            nominalDuration: CMTime(value: Int64(nominalDurationTicks), timescale: 90_000)
        )
    }

    mutating func reset() {
        wrapCount = 0
        lastRawTimestamp = nil
        firstExtendedTimestamp = nil
        lastExtendedTimestamp = nil
        cadenceSamples.removeAll(keepingCapacity: true)
        nominalDurationTicks = 3_000
    }

    static func selfTest() -> Bool {
        var mapper = RTPVideoTimestampMapper()
        let first = mapper.timing(for: 90_000)
        let second = mapper.timing(for: 93_000)
        guard first.presentationTime == .zero,
              second.presentationTime == CMTime(value: 3_000, timescale: 90_000) else { return false }

        mapper.reset()
        _ = mapper.timing(for: 90_000)
        let ntscCadence = mapper.timing(for: 93_003)
        guard ntscCadence.nominalDuration == CMTime(value: 3_003, timescale: 90_000) else {
            return false
        }

        mapper.reset()
        _ = mapper.timing(for: UInt32.max - 999)
        let wrapped = mapper.timing(for: 2_000)
        return CMTimeCompare(
            wrapped.presentationTime,
            CMTime(value: 3_000, timescale: 90_000)
        ) == 0
    }
}

/// Frame-synchronized motion decoded from the 56-byte VideoMetadataV2 block
/// carried by the same RTP access unit. `sampleTime` is the exported V4L2 DMA
/// completion/EOF timestamp. frameQuaternion is the active displayed camera
/// FRD -> global NED rotation; droneQuaternion is retained for diagnostics and
/// is deliberately not composed into it.
struct VerifiedVideoFrameMotion {
    let sampleTime: CMTime
    let rtpTimestamp: UInt32
    let droneQuaternion: VideoMetadataQuaternion
    let frameQuaternion: VideoMetadataQuaternion
    let cameraPanRadians: Double
    let cameraTiltRadians: Double
    let exposureDurationSeconds: Double
    let confidence: Double
}

struct RollingShutterProcessingConfiguration: Equatable {
    var isEnabled = false
    var calibrationProfile: Bebop900pCameraCalibrationProfile? = .firmware471GPUFixedRaised
    var quaternionConvention = VideoQuaternionConvention(
        action: .active,
        handedness: .rightHanded,
        composition: .frameViewOnly
    )
    var timestampAnchor = VideoFrameTimestampAnchor.frameEOF
    var maximumStabilizationAngleDegrees = 6.0
    /// Small software IRQ timestamp delay from physical EOF. Zero is the
    /// grounded first-order value and may later be refined from measurements.
    var irqDelaySeconds = 0.0
}

struct TemporalReconstructionConfiguration: Equatable {
    var isEnabled = false
    /// Ground uses image motion only; never apply aircraft calibration or IMU data.
    var flowOnlyGround = false
    /// Maximum contribution from reprojected history in confident regions.
    var historyWeight = 0.58
    /// 0 accepts larger residuals; 1 aggressively rejects possible ghosts.
    var ghostRejection = 0.68
    /// Maximum forward/backward flow disagreement before history is rejected.
    var consistencyThresholdPixels = 2.0
    /// Flow results slower than this are discarded and history is reset.
    var latencyBudgetMilliseconds = 65.0
    var usesBidirectionalFlow = true
    /// Residual flow is estimated after IMU alignment, so full source
    /// resolution is unnecessary. The vectors are scaled back to source pixels
    /// by the Metal resolve pass.
    var flowResolutionScale = 0.375
    /// Inserts one motion-compensated midpoint after every two decoded source
    /// frames: 30 real + 15 generated = a bounded 45 fps output timeline.
    var generatesIntermediateFrames = false

    static var ground720p45: Self {
        var value = Self()
        value.flowOnlyGround = true
        value.historyWeight = 0.38
        value.ghostRejection = 0.8
        value.consistencyThresholdPixels = 1.5
        value.latencyBudgetMilliseconds = 30
        value.flowResolutionScale = 0.5
        value.generatesIntermediateFrames = true
        return value
    }

    func supportsSource(width: Int, height: Int) -> Bool {
        flowOnlyGround
            ? (32...1920).contains(width) && (32...1080).contains(height)
            : width == Bebop900pCameraCalibration.width && height == Bebop900pCameraCalibration.height
    }

    func permitsInterpolation(duration: CMTime, gap: Double) -> Bool {
        guard generatesIntermediateFrames, usesBidirectionalFlow else { return false }
        guard flowOnlyGround else { return true }
        let cadence = CMTimeGetSeconds(duration)
        // Do not invent a 45 FPS claim for stock 15 FPS or interpolate across loss.
        return cadence.isFinite && (1.0 / 36...1.0 / 24).contains(cadence)
            && gap.isFinite && gap > 0 && gap <= 1.0 / 20
    }
}

enum DecodedVideoImage {
    case pixelBuffer(CVPixelBuffer)
    case cgImage(CGImage)
}

struct DecodedVideoFrame {
    let image: DecodedVideoImage
    let timing: VideoFrameTiming
    let visibleRect: CGRect?
    let verifiedMotion: VerifiedVideoFrameMotion?
}

struct ProcessedVideoFrame {
    let pixelBuffer: CVPixelBuffer
    let timing: VideoFrameTiming
    let sequenceNumber: UInt64
    let processingLatencyMilliseconds: Double
    let isSynthetic: Bool
    let targetFrameRate: Int

    var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

struct LiveVideoProcessingStats: Equatable {
    let processedFPS: Double
    let droppedBeforeProcessing: UInt64
    let outputWidth: Int
    let outputHeight: Int
    let averageLatencyMilliseconds: Double
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

/// Latest-frame-only GPU processing. Decoder callbacks can replace the single
/// pending input, so expensive enhancement or scaling can never build latency
/// in the FPV path. Output buffers are IOSurface-backed and can be handed
/// directly to VideoToolbox without a CPU pixel copy.
final class LiveVideoProcessingPipeline {
    /// Offline regression: ground geometry, cadence, reset and generated output.
    static func groundTemporalSelfTest() -> Bool {
        var config = TemporalReconstructionConfiguration.ground720p45
        let duration = CMTime(value: 3000, timescale: 90000)
        guard config.flowOnlyGround, !config.isEnabled,
              config.supportsSource(width: 640, height: 480),
              config.supportsSource(width: 1280, height: 720),
              !config.supportsSource(width: 4096, height: 3320),
              !TemporalReconstructionConfiguration().supportsSource(width: 640, height: 480),
              config.permitsInterpolation(duration: duration, gap: 1.0 / 30),
              !config.permitsInterpolation(duration: CMTime(value: 6000, timescale: 90000), gap: 1.0 / 15),
              !config.permitsInterpolation(duration: duration, gap: 0.1) else { return false }
        let fourThree = VideoSpatialScalingMode.metalFX720p.outputDimensions(sourceWidth: 640, sourceHeight: 480)
        let widescreen = VideoSpatialScalingMode.metalFX720p.outputDimensions(sourceWidth: 1280, sourceHeight: 720)
        guard fourThree.width == 960, fourThree.height == 720,
              widescreen.width == 1280, widescreen.height == 720 else { return false }
        let pipeline = LiveVideoProcessingPipeline()
        config.isEnabled = true
        config.latencyBudgetMilliseconds = 2000 // Cold Vision initialization isn't a live budget test.
        pipeline.configuration.temporal = config
        let image = CIImage(color: CIColor(red: 0.35, green: 0.45, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 72))
        guard let source = pipeline.makePixelBuffer(width: 96, height: 72) else { return false }
        pipeline.ciContext.render(image, to: source)
        var lastPTS: CMTime?
        var synthetic = 0
        for index in 0..<7 {
            let output = pipeline.process(DecodedVideoFrame(
                image: .pixelBuffer(source),
                timing: VideoFrameTiming(rtpTimestamp: UInt32(index * 3000),
                    presentationTime: CMTime(value: Int64(index * 3000), timescale: 90000), nominalDuration: duration),
                visibleRect: nil, verifiedMotion: nil
            ))
            guard !output.isEmpty else { return false }
            for frame in output {
                guard frame.width == 960, frame.height == 720 else { return false }
                if let lastPTS, CMTimeCompare(frame.timing.presentationTime, lastPTS) <= 0 { return false }
                lastPTS = frame.timing.presentationTime
                if frame.isSynthetic { synthetic += 1 }
            }
        }
        guard synthetic == 3 else { return false }
        // A gap and a size change must seed fresh history, never warp stale frames.
        let gap = pipeline.applyTemporalReconstruction(to: image,
            timing: VideoFrameTiming(rtpTimestamp: 90000, presentationTime: CMTime(value: 1, timescale: 1), nominalDuration: duration),
            motion: nil, configuration: config)
        guard !gap.usedHistory, gap.intermediateImage == nil else { return false }
        let resized = pipeline.applyTemporalReconstruction(
            to: image.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48)),
            timing: VideoFrameTiming(rtpTimestamp: 93000, presentationTime: CMTime(value: 93000, timescale: 90000), nominalDuration: duration),
            motion: nil, configuration: config)
        guard !resized.usedHistory, resized.intermediateImage == nil else { return false }
        config.isEnabled = false
        return pipeline.applyTemporalReconstruction(to: image,
            timing: VideoFrameTiming(rtpTimestamp: 96000, presentationTime: CMTime(value: 96000, timescale: 90000), nominalDuration: duration),
            motion: nil, configuration: config).status == "TEMPORAL OFF"
    }

    var onFrame: ((ProcessedVideoFrame) -> Void)?
    var onStats: ((LiveVideoProcessingStats) -> Void)?
    var onDebug: ((String) -> Void)?

    private struct Configuration {
        var enhancement = VideoEnhancementPreset.off
        var scaling = VideoSpatialScalingMode.off
        var rollingShutter = RollingShutterProcessingConfiguration()
        var temporal = TemporalReconstructionConfiguration()
    }

    private struct PoolKey: Hashable {
        let width: Int
        let height: Int
    }

    private struct TemporalHistoryEntry {
        let timing: VideoFrameTiming
        let sourcePixelBuffer: CVPixelBuffer?
        let motion: VerifiedVideoFrameMotion?
    }

    private struct TemporalReconstructionState {
        let timing: VideoFrameTiming
        let source: CVPixelBuffer
        let history: CVPixelBuffer
        let motion: VerifiedVideoFrameMotion?
    }

    private let processingQueue = DispatchQueue(
        label: "parrotlab.live-video-processing",
        qos: .userInteractive,
        autoreleaseFrequency: .workItem
    )
    private let stateLock = NSLock()
    private let configurationLock = NSLock()
    private let metalDevice: (any MTLDevice)?
    private let rollingShutterRenderer: RollingShutterMetalRenderer?
    private let temporalRenderer: TemporalReconstructionRenderer?
    private let h264ArtifactRepairRenderer: H264ArtifactRepairRenderer?
    private let ciContext: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let metalFXRenderer = MetalFXSpatialScalerRenderer()
    private var configuration = Configuration()
    private var pendingInput: DecodedVideoFrame?
    private var processingScheduled = false
    private var droppedBeforeProcessing: UInt64 = 0
    private var sequenceNumber: UInt64 = 0
    private var pools: [PoolKey: CVPixelBufferPool] = [:]
    private var temporalHistory: [TemporalHistoryEntry] = []
    private var temporalReconstructionState: TemporalReconstructionState?
    private var temporalFrameGenerationPhase = 0
    private var h264ArtifactRepairHistory: CVPixelBuffer?
    private var lastTemporalConfiguration = TemporalReconstructionConfiguration()
    private var lastTemporalStatus = "TEMPORAL OFF"
    private var lastTemporalFlowLatencyMilliseconds: Double?
    private var lastTemporalHistoryUsed = false
    private let maximumTemporalHistoryDepth = 3
    private var statsWindowStarted = Date()
    private var processedInWindow = 0
    private var processingPassesInWindow = 0
    private var latencyInWindow = 0.0
    private var lastOutputWidth = 0
    private var lastOutputHeight = 0
    private var reportedMetalFXFallback = false
    private var calibrationTextureSet: Bebop900pCalibrationTextureSet?
    private var calibrationTextureLoadFailed = false
    private var reportedRollingShutterActive = false

    init() {
        let device = MTLCreateSystemDefaultDevice()
        metalDevice = device
        rollingShutterRenderer = device.flatMap { RollingShutterMetalRenderer(device: $0) }
        temporalRenderer = device.flatMap { TemporalReconstructionRenderer(device: $0) }
        h264ArtifactRepairRenderer = device.flatMap { H264ArtifactRepairRenderer(device: $0) }
        if let device {
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
    }

    var isMetalFXSupported: Bool { metalFXRenderer != nil }

    func update(
        enhancement: VideoEnhancementPreset,
        scaling: VideoSpatialScalingMode
    ) {
        configurationLock.lock()
        configuration.enhancement = enhancement
        configuration.scaling = scaling
        reportedMetalFXFallback = false
        configurationLock.unlock()
    }

    func updateRollingShutterConfiguration(_ value: RollingShutterProcessingConfiguration) {
        configurationLock.lock()
        configuration.rollingShutter = value
        reportedRollingShutterActive = false
        configurationLock.unlock()
    }

    func updateTemporalReconstructionConfiguration(_ value: TemporalReconstructionConfiguration) {
        configurationLock.lock()
        configuration.temporal = value
        configurationLock.unlock()
    }

    func submit(_ input: DecodedVideoFrame) {
        stateLock.lock()
        if pendingInput != nil { droppedBeforeProcessing += 1 }
        pendingInput = input
        let shouldSchedule = !processingScheduled
        if shouldSchedule { processingScheduled = true }
        stateLock.unlock()

        if shouldSchedule {
            processingQueue.async { [weak self] in self?.drainLatestFrames() }
        }
    }

    func reset() {
        stateLock.lock()
        pendingInput = nil
        droppedBeforeProcessing = 0
        stateLock.unlock()
        processingQueue.sync {
            temporalHistory.removeAll(keepingCapacity: false)
            temporalReconstructionState = nil
            temporalFrameGenerationPhase = 0
            h264ArtifactRepairHistory = nil
            lastTemporalConfiguration = TemporalReconstructionConfiguration()
            lastTemporalStatus = "TEMPORAL OFF"
            lastTemporalFlowLatencyMilliseconds = nil
            lastTemporalHistoryUsed = false
            pools.removeAll(keepingCapacity: false)
            sequenceNumber = 0
            processedInWindow = 0
            processingPassesInWindow = 0
            latencyInWindow = 0
            statsWindowStarted = Date()
            lastOutputWidth = 0
            lastOutputHeight = 0
        }
    }

    private func drainLatestFrames() {
        while true {
            stateLock.lock()
            guard let input = pendingInput else {
                processingScheduled = false
                stateLock.unlock()
                return
            }
            pendingInput = nil
            stateLock.unlock()

            autoreleasepool {
                for output in process(input) { onFrame?(output) }
            }
        }
    }

    private func process(_ input: DecodedVideoFrame) -> [ProcessedVideoFrame] {
        let started = CFAbsoluteTimeGetCurrent()
        configurationLock.lock()
        let configuration = self.configuration
        configurationLock.unlock()

        var image: CIImage
        var retainedSourceBuffer: CVPixelBuffer?
        switch input.image {
        case .pixelBuffer(let pixelBuffer):
            retainedSourceBuffer = pixelBuffer
            image = CIImage(cvPixelBuffer: pixelBuffer)
        case .cgImage(let cgImage):
            image = CIImage(cgImage: cgImage)
        }

        if let requestedRect = input.visibleRect {
            let visibleRect = requestedRect.intersection(image.extent)
            if !visibleRect.isNull, !visibleRect.isEmpty { image = image.cropped(to: visibleRect) }
        }
        let sourceExtent = image.extent.integral
        guard sourceExtent.width > 0, sourceExtent.height > 0 else { return [] }
        image = image.transformed(by: CGAffineTransform(
            translationX: -sourceExtent.origin.x,
            y: -sourceExtent.origin.y
        ))

        let previousMotion = temporalHistory.last?.motion
        observeTemporalHistory(
            timing: input.timing,
            sourcePixelBuffer: retainedSourceBuffer,
            motion: input.verifiedMotion
        )

        let calibratedSourceWidth = Int(sourceExtent.width.rounded())
        let calibratedSourceHeight = Int(sourceExtent.height.rounded())

        var rollingShutter = configuration.rollingShutter
        if configuration.temporal.flowOnlyGround { rollingShutter.isEnabled = false }
        let rollingShutterResult = applyRollingShutterCorrection(
            to: image,
            configuration: rollingShutter,
            previousMotion: previousMotion,
            currentMotion: input.verifiedMotion,
            sourceWidth: calibratedSourceWidth,
            sourceHeight: calibratedSourceHeight
        )
        image = rollingShutterResult.image
        let rollingShutterStatus = rollingShutterResult.status

        image = applyConservativeEnhancement(configuration.enhancement, to: image)
        image = applyH264ArtifactRepairIfNeeded(configuration.enhancement, to: image)
        let temporalResult = applyTemporalReconstruction(
            to: image,
            timing: input.timing,
            motion: configuration.temporal.flowOnlyGround ? nil : input.verifiedMotion,
            configuration: configuration.temporal
        )
        image = temporalResult.image
        lastTemporalStatus = temporalResult.status
        lastTemporalFlowLatencyMilliseconds = temporalResult.flowLatencyMilliseconds
        lastTemporalHistoryUsed = temporalResult.usedHistory
        let enhancedExtent = image.extent.integral
        let sourceWidth = Int(enhancedExtent.width.rounded())
        let sourceHeight = Int(enhancedExtent.height.rounded())
        let outputScaling: VideoSpatialScalingMode = configuration.temporal.flowOnlyGround && configuration.temporal.isEnabled
            ? .metalFX720p : configuration.scaling
        var outputDimensions = outputScaling.outputDimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        if outputScaling == .off,
           configuration.enhancement == .upscale2x || configuration.enhancement == .upscaleClarity2x {
            outputDimensions = (Self.even(sourceWidth * 2), Self.even(sourceHeight * 2))
        }
        let outputWidth = outputDimensions.width
        let outputHeight = outputDimensions.height
        guard outputWidth > 0, outputHeight > 0 else { return [] }

        var outputs: [ProcessedVideoFrame] = []
        let frameGenerationActive = configuration.temporal.isEnabled &&
            configuration.temporal.generatesIntermediateFrames &&
            configuration.temporal.usesBidirectionalFlow &&
            configuration.temporal.supportsSource(width: sourceWidth, height: sourceHeight) &&
            configuration.temporal.permitsInterpolation(duration: input.timing.nominalDuration,
                                                       gap: CMTimeGetSeconds(input.timing.nominalDuration)) &&
            !temporalResult.status.contains("BYPASS")
        let targetFrameRate = frameGenerationActive ? 45 : 30
        if let intermediateImage = temporalResult.intermediateImage,
           let intermediateTiming = temporalResult.intermediateTiming,
           let intermediateBuffer = renderOutput(
               intermediateImage,
               sourceWidth: sourceWidth,
               sourceHeight: sourceHeight,
               outputWidth: outputWidth,
               outputHeight: outputHeight,
               scaling: outputScaling,
               prefersFastScaling: !configuration.temporal.flowOnlyGround
           ) {
            sequenceNumber &+= 1
            outputs.append(ProcessedVideoFrame(
                pixelBuffer: intermediateBuffer,
                timing: intermediateTiming,
                sequenceNumber: sequenceNumber,
                processingLatencyMilliseconds: (CFAbsoluteTimeGetCurrent() - started) * 1_000,
                isSynthetic: true,
                targetFrameRate: targetFrameRate
            ))
        }

        guard let outputBuffer = renderOutput(
            image,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            scaling: outputScaling
        ) else {
            emitDebug("Processed-frame pool exhausted; dropping this frame without delaying live video")
            return outputs
        }

        sequenceNumber &+= 1
        let latency = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        let realTiming = targetFrameRate == 45
            ? VideoFrameTiming(
                rtpTimestamp: input.timing.rtpTimestamp,
                presentationTime: input.timing.presentationTime,
                nominalDuration: CMTime(value: 2_000, timescale: 90_000)
            )
            : input.timing
        outputs.append(ProcessedVideoFrame(
            pixelBuffer: outputBuffer,
            timing: realTiming,
            sequenceNumber: sequenceNumber,
            processingLatencyMilliseconds: latency,
            isSynthetic: false,
            targetFrameRate: targetFrameRate
        ))
        recordStats(
            latencyMilliseconds: latency,
            outputFrameCount: outputs.count,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            rollingShutterConfiguration: configuration.rollingShutter,
            rollingShutterStatus: rollingShutterStatus
        )
        return outputs
    }

    private func renderOutput(
        _ image: CIImage,
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        scaling: VideoSpatialScalingMode,
        prefersFastScaling: Bool = false
    ) -> CVPixelBuffer? {
        guard let outputBuffer = makePixelBuffer(width: outputWidth, height: outputHeight) else { return nil }
        if scaling.usesMetalFX,
           !prefersFastScaling,
           outputWidth >= sourceWidth,
           outputHeight >= sourceHeight,
           let metalFXRenderer,
           metalFXRenderer.render(
               image,
               outputWidth: outputWidth,
               outputHeight: outputHeight,
               to: outputBuffer
           ) {
            return outputBuffer
        }
        if scaling.usesMetalFX, !prefersFastScaling, !reportedMetalFXFallback {
            reportedMetalFXFallback = true
            emitDebug("MetalFX Spatial could not process the selected output; using GPU Lanczos scaling")
        }
        let normalized: CIImage
        if prefersFastScaling {
            let extent = image.extent.integral
            normalized = image.transformed(by: CGAffineTransform(
                scaleX: CGFloat(outputWidth) / extent.width,
                y: CGFloat(outputHeight) / extent.height
            ))
        } else {
            normalized = scaledImage(image, width: outputWidth, height: outputHeight)
        }
        ciContext.render(
            normalized,
            to: outputBuffer,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            colorSpace: colorSpace
        )
        return outputBuffer
    }

    private func applyConservativeEnhancement(
        _ preset: VideoEnhancementPreset,
        to source: CIImage
    ) -> CIImage {
        var image = source
        func applying(_ name: String, values: [String: Any]) {
            guard let filter = CIFilter(name: name) else { return }
            filter.setValue(image, forKey: kCIInputImageKey)
            for (key, value) in values { filter.setValue(value, forKey: key) }
            if let output = filter.outputImage { image = output }
        }

        switch preset {
        case .off, .h264ArtifactRepair, .upscale2x:
            break
        case .denoise:
            applying("CINoiseReduction", values: ["inputNoiseLevel": 0.025, "inputSharpness": 0.35])
        case .clarity:
            applying("CINoiseReduction", values: ["inputNoiseLevel": 0.012, "inputSharpness": 0.45])
            applying("CISharpenLuminance", values: [kCIInputSharpnessKey: 0.38, kCIInputRadiusKey: 1.1])
            applying("CIColorControls", values: [kCIInputContrastKey: 1.045, kCIInputSaturationKey: 1.02])
        case .lowLight:
            applying("CINoiseReduction", values: ["inputNoiseLevel": 0.035, "inputSharpness": 0.3])
            applying("CIHighlightShadowAdjust", values: ["inputShadowAmount": 0.42, "inputHighlightAmount": 0.82])
            applying("CIGammaAdjust", values: ["inputPower": 0.88])
            applying("CISharpenLuminance", values: [kCIInputSharpnessKey: 0.22, kCIInputRadiusKey: 0.9])
        case .upscaleClarity2x:
            applying("CINoiseReduction", values: ["inputNoiseLevel": 0.012, "inputSharpness": 0.45])
            applying("CISharpenLuminance", values: [kCIInputSharpnessKey: 0.34, kCIInputRadiusKey: 1.0])
        }
        return image
    }

    private func applyH264ArtifactRepairIfNeeded(
        _ preset: VideoEnhancementPreset,
        to image: CIImage
    ) -> CIImage {
        guard preset == .h264ArtifactRepair else {
            h264ArtifactRepairHistory = nil
            return image
        }
        let extent = image.extent.integral
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 0, height > 0,
              let renderer = h264ArtifactRepairRenderer,
              let current = makePixelBuffer(width: width, height: height),
              let destination = makePixelBuffer(width: width, height: height) else {
            h264ArtifactRepairHistory = nil
            return image
        }
        ciContext.render(
            image,
            to: current,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace
        )
        let previous = h264ArtifactRepairHistory.flatMap {
            CVPixelBufferGetWidth($0) == width && CVPixelBufferGetHeight($0) == height ? $0 : nil
        }
        guard renderer.render(current: current, previous: previous, destination: destination) else {
            h264ArtifactRepairHistory = nil
            return image
        }
        h264ArtifactRepairHistory = destination
        return CIImage(cvPixelBuffer: destination)
    }

    private func scaledImage(_ source: CIImage, width: Int, height: Int) -> CIImage {
        let extent = source.extent.integral
        guard Int(extent.width) != width || Int(extent.height) != height else { return source }
        let scaleX = CGFloat(width) / extent.width
        let scaleY = CGFloat(height) / extent.height
        guard abs(scaleX - scaleY) < 0.002,
              let filter = CIFilter(name: "CILanczosScaleTransform") else {
            return source.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(scaleX, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return filter.outputImage ?? source.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }

    private func applyTemporalReconstruction(
        to image: CIImage,
        timing: VideoFrameTiming,
        motion: VerifiedVideoFrameMotion?,
        configuration: TemporalReconstructionConfiguration
    ) -> (
        image: CIImage,
        intermediateImage: CIImage?,
        intermediateTiming: VideoFrameTiming?,
        status: String,
        flowLatencyMilliseconds: Double?,
        usedHistory: Bool
    ) {
        if configuration != lastTemporalConfiguration {
            temporalReconstructionState = nil
            temporalFrameGenerationPhase = 0
            lastTemporalConfiguration = configuration
        }
        guard configuration.isEnabled else {
            temporalReconstructionState = nil
            temporalFrameGenerationPhase = 0
            return (image, nil, nil, "TEMPORAL OFF", nil, false)
        }
        let extent = image.extent.integral
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard configuration.supportsSource(width: width, height: height) else {
            temporalReconstructionState = nil
            temporalFrameGenerationPhase = 0
            return (image, nil, nil, configuration.flowOnlyGround
                ? "GROUND FLOW BYPASS · SOURCE OUTSIDE 32…1920 × 32…1080"
                : "TEMPORAL BYPASS · REQUIRES 1600x900", nil, false)
        }
        guard let temporalRenderer,
              let currentSource = makePixelBuffer(width: width, height: height) else {
            temporalReconstructionState = nil
            temporalFrameGenerationPhase = 0
            return (image, nil, nil, "TEMPORAL BYPASS · GPU/POOL UNAVAILABLE", nil, false)
        }
        ciContext.render(
            image,
            to: currentSource,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace
        )

        if let previous = temporalReconstructionState,
           CVPixelBufferGetWidth(previous.source) != width || CVPixelBufferGetHeight(previous.source) != height {
            temporalReconstructionState = nil
            temporalFrameGenerationPhase = 0
        }
        guard let previous = temporalReconstructionState else {
            temporalReconstructionState = TemporalReconstructionState(
                timing: timing,
                source: currentSource,
                history: currentSource,
                motion: motion
            )
            return (CIImage(cvPixelBuffer: currentSource), nil, nil, "TEMPORAL WARMING · NEED PREVIOUS FRAME", nil, false)
        }
        let delta = CMTimeGetSeconds(CMTimeSubtract(timing.presentationTime, previous.timing.presentationTime))
        let maximumGap = configuration.flowOnlyGround ? 0.12 : max(0.2, CMTimeGetSeconds(timing.nominalDuration) * 6)
        guard delta.isFinite, delta > 0, delta <= maximumGap else {
            temporalReconstructionState = TemporalReconstructionState(
                timing: timing,
                source: currentSource,
                history: currentSource,
                motion: motion
            )
            temporalFrameGenerationPhase = 0
            return (CIImage(cvPixelBuffer: currentSource), nil, nil, "TEMPORAL RESET · TIMELINE DISCONTINUITY", nil, false)
        }
        temporalFrameGenerationPhase = (temporalFrameGenerationPhase + 1) % 2
        let shouldGenerateIntermediate = configuration.permitsInterpolation(
            duration: timing.nominalDuration, gap: delta
        ) && temporalFrameGenerationPhase == 0
        guard let alignedSource = configuration.flowOnlyGround ? previous.source : makePixelBuffer(width: width, height: height),
              let alignedHistory = configuration.flowOnlyGround ? previous.history : makePixelBuffer(width: width, height: height),
              let destination = makePixelBuffer(width: width, height: height) else {
            temporalReconstructionState = TemporalReconstructionState(
                timing: timing,
                source: currentSource,
                history: currentSource,
                motion: motion
            )
            return (CIImage(cvPixelBuffer: currentSource), nil, nil, "TEMPORAL DROP · INTERMEDIATE POOL EXHAUSTED", nil, false)
        }
        let intermediateDestination = shouldGenerateIntermediate
            ? makePixelBuffer(width: width, height: height)
            : nil

        let result = temporalRenderer.reconstruct(
            currentSource: currentSource,
            previousSource: previous.source,
            previousHistory: previous.history,
            alignedSource: alignedSource,
            alignedHistory: alignedHistory,
            destination: destination,
            intermediateDestination: intermediateDestination,
            previousMotion: previous.motion,
            currentMotion: motion,
            configuration: configuration
        )
        let resolved = result.usedHistory ? destination : currentSource
        temporalReconstructionState = TemporalReconstructionState(
            timing: timing,
            source: currentSource,
            history: resolved,
            motion: motion
        )
        let generatedImage = result.generatedIntermediateFrame
            ? intermediateDestination.map { CIImage(cvPixelBuffer: $0) }
            : nil
        let midpointTiming: VideoFrameTiming? = generatedImage.map { _ in
            let deltaTime = CMTimeSubtract(timing.presentationTime, previous.timing.presentationTime)
            return VideoFrameTiming(
                rtpTimestamp: timing.rtpTimestamp,
                presentationTime: CMTimeAdd(previous.timing.presentationTime, CMTimeMultiplyByRatio(
                    deltaTime,
                    multiplier: 1,
                    divisor: 2
                )),
                nominalDuration: CMTime(value: 2_000, timescale: 90_000)
            )
        }
        return (
            CIImage(cvPixelBuffer: resolved),
            generatedImage,
            midpointTiming,
            result.status,
            result.flowLatencyMilliseconds,
            result.usedHistory
        )
    }

    private func observeTemporalHistory(
        timing: VideoFrameTiming,
        sourcePixelBuffer: CVPixelBuffer?,
        motion: VerifiedVideoFrameMotion?
    ) {
        if let previous = temporalHistory.last {
            let delta = CMTimeSubtract(timing.presentationTime, previous.timing.presentationTime)
            let maximumGap = CMTimeMultiply(timing.nominalDuration, multiplier: 6)
            if !delta.isValid || CMTimeCompare(delta, .zero) <= 0 || CMTimeCompare(delta, maximumGap) > 0 {
                temporalHistory.removeAll(keepingCapacity: true)
            }
        }
        temporalHistory.append(TemporalHistoryEntry(
            timing: timing,
            sourcePixelBuffer: sourcePixelBuffer,
            motion: motion
        ))
        if temporalHistory.count > maximumTemporalHistoryDepth {
            temporalHistory.removeFirst(temporalHistory.count - maximumTemporalHistoryDepth)
        }
    }

    private var temporalHistoryAgeMilliseconds: Double {
        guard let first = temporalHistory.first,
              let last = temporalHistory.last else { return 0 }
        return max(0, CMTimeGetSeconds(
            CMTimeSubtract(last.timing.presentationTime, first.timing.presentationTime)
        ) * 1_000)
    }

    private func applyRollingShutterCorrection(
        to image: CIImage,
        configuration: RollingShutterProcessingConfiguration,
        previousMotion: VerifiedVideoFrameMotion?,
        currentMotion: VerifiedVideoFrameMotion?,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> (image: CIImage, status: String) {
        guard configuration.isEnabled else {
            return (image, "RS OFF · CALIBRATION AVAILABLE")
        }
        guard configuration.calibrationProfile == Bebop900pCameraCalibration.profile else {
            return (image, "RS BYPASSED · CALIBRATION PROFILE MISSING")
        }
        guard sourceWidth == Bebop900pCameraCalibration.width,
              sourceHeight == Bebop900pCameraCalibration.height else {
            return (image, "RS BYPASSED · REQUIRES VISIBLE 1600x900")
        }
        guard configuration.quaternionConvention == VideoQuaternionConvention(
            action: .active,
            handedness: .rightHanded,
            composition: .frameViewOnly
        ) else {
            return (image, "RS BYPASSED · REQUIRES ACTIVE FRAME_QUAT FRD→NED")
        }
        guard configuration.timestampAnchor == .frameEOF else {
            return (image, "RS BYPASSED · REQUIRES FRAME EOF TIMESTAMP")
        }
        guard let previousMotion, let currentMotion else {
            return (image, "RS WARMING · NEED CONSECUTIVE FRAME_QUAT")
        }
        let frameInterval = CMTimeGetSeconds(CMTimeSubtract(
            currentMotion.sampleTime,
            previousMotion.sampleTime
        ))
        guard frameInterval.isFinite, frameInterval > 0.005, frameInterval < 0.2 else {
            return (image, "RS BYPASSED · MOTION TIMELINE DISCONTINUITY")
        }
        guard currentMotion.confidence >= 0.8, previousMotion.confidence >= 0.8 else {
            return (image, "RS BYPASSED · FRAME_QUAT CONFIDENCE LOW")
        }
        guard ensureCalibrationTextures(),
              let calibrationTextureSet,
              let rollingShutterRenderer else {
            return (image, "RS BYPASSED · METAL WARP UNAVAILABLE")
        }
        guard let sourceBuffer = makePixelBuffer(width: sourceWidth, height: sourceHeight),
              let correctedBuffer = makePixelBuffer(width: sourceWidth, height: sourceHeight) else {
            return (image, "RS DROPPED · INTERMEDIATE POOL EXHAUSTED")
        }
        ciContext.render(
            image,
            to: sourceBuffer,
            bounds: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
            colorSpace: colorSpace
        )
        guard rollingShutterRenderer.render(
            source: sourceBuffer,
            destination: correctedBuffer,
            calibration: calibrationTextureSet,
            previousMotion: previousMotion,
            currentMotion: currentMotion,
            frameIntervalSeconds: frameInterval,
            irqDelaySeconds: configuration.irqDelaySeconds,
            maximumCorrectionAngleDegrees: configuration.maximumStabilizationAngleDegrees
        ) else {
            return (image, "RS BYPASSED · GPU WARP FAILED")
        }
        if !reportedRollingShutterActive {
            reportedRollingShutterActive = true
            emitDebug(
                "Rolling-shutter correction active: frame_quat FRD→NED, EOF anchor, calibrated curved row timing"
            )
        }
        return (
            CIImage(cvPixelBuffer: correctedBuffer),
            "RS ACTIVE · FRAME_QUAT/EOF · CALIBRATED CORE"
        )
    }

    private func ensureCalibrationTextures() -> Bool {
        if calibrationTextureSet != nil { return true }
        guard !calibrationTextureLoadFailed, let metalDevice else { return false }
        calibrationTextureSet = Bebop900pCalibrationTextureSet(device: metalDevice)
        if calibrationTextureSet == nil {
            calibrationTextureLoadFailed = true
            emitDebug("Could not create the 4.7.1 900p calibration textures")
            return false
        }
        if let calibrationTextureSet {
            emitDebug(String(
                format: "900p calibration LUT ready · %.2f%% valid · row timing %.3f…%.3f ms · zero-motion safe crop %.0fx%.0f",
                calibrationTextureSet.validFraction * 100,
                calibrationTextureSet.minimumRowStartMilliseconds,
                calibrationTextureSet.maximumRowStartMilliseconds,
                calibrationTextureSet.zeroMotionSafe16By9Crop.width,
                calibrationTextureSet.zeroMotionSafe16By9Crop.height
            ))
        }
        return true
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let key = PoolKey(width: width, height: height)
        let pool: CVPixelBufferPool
        if let cached = pools[key] {
            pool = cached
        } else {
            let poolAttributes: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 12
            ]
            let pixelAttributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttributes as CFDictionary,
                pixelAttributes as CFDictionary,
                &created
            ) == kCVReturnSuccess, let created else { return nil }
            pools[key] = created
            pool = created
        }

        let auxiliary: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: 18
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            auxiliary as CFDictionary,
            &buffer
        ) == kCVReturnSuccess else { return nil }
        return buffer
    }

    private func recordStats(
        latencyMilliseconds: Double,
        outputFrameCount: Int,
        outputWidth: Int,
        outputHeight: Int,
        rollingShutterConfiguration: RollingShutterProcessingConfiguration,
        rollingShutterStatus: String
    ) {
        processedInWindow += outputFrameCount
        processingPassesInWindow += 1
        latencyInWindow += latencyMilliseconds
        lastOutputWidth = outputWidth
        lastOutputHeight = outputHeight
        let elapsed = Date().timeIntervalSince(statsWindowStarted)
        guard elapsed >= 1 else { return }
        stateLock.lock()
        let dropped = droppedBeforeProcessing
        stateLock.unlock()
        let stats = LiveVideoProcessingStats(
            processedFPS: Double(processedInWindow) / elapsed,
            droppedBeforeProcessing: dropped,
            outputWidth: lastOutputWidth,
            outputHeight: lastOutputHeight,
            averageLatencyMilliseconds: latencyInWindow / Double(max(1, processingPassesInWindow)),
            temporalHistoryDepth: temporalHistory.count,
            temporalHistoryAgeMilliseconds: temporalHistoryAgeMilliseconds,
            temporalMotionAvailable: temporalHistory.last?.motion != nil,
            temporalMotionConfidence: temporalHistory.last?.motion?.confidence,
            temporalReprojectionStatus: lastTemporalStatus != "TEMPORAL OFF"
                ? lastTemporalStatus
                : rollingShutterStatus.hasPrefix("RS ACTIVE")
                ? "MOTION-COMPENSATED RS · FRAME_QUAT"
                : temporalHistory.last?.motion != nil
                ? "SYNC INPUT · RS NOT ACTIVE"
                : "BYPASSED · NO FRAME MOTION",
            temporalFlowLatencyMilliseconds: lastTemporalFlowLatencyMilliseconds,
            temporalHistoryUsed: lastTemporalHistoryUsed,
            lastRTPTimestamp: temporalHistory.last?.timing.rtpTimestamp,
            motionAssociationOffsetMilliseconds: temporalHistory.last?.motion != nil ? 0 : nil,
            cameraCalibrationStatus: rollingShutterConfiguration.calibrationProfile?.statusLabel
                ?? "NO CAMERA CALIBRATION",
            cameraReadoutStatus: String(
                format: "ROW LUT %.3f ms · CURVED LEFT→RIGHT",
                Bebop900pCameraCalibration.activeReadoutSeconds * 1_000
            ),
            rollingShutterStatus: rollingShutterStatus
        )
        processedInWindow = 0
        processingPassesInWindow = 0
        latencyInWindow = 0
        statsWindowStarted = Date()
        DispatchQueue.main.async { [weak self] in self?.onStats?(stats) }
    }

    private func emitDebug(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onDebug?(message) }
    }

    private static func even(_ value: Int) -> Int { max(2, value & ~1) }
}
