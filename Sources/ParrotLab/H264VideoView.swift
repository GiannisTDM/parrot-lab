import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import QuartzCore
import VideoToolbox

struct VideoPipelineStats: Equatable {
    let decodedFPS: Double
    let displayRefreshFPS: Double
}

enum VideoEnhancementPreset: Int, CaseIterable {
    case off
    case denoise
    case clarity
    case lowLight
    case upscale2x
    case upscaleClarity2x

    var menuTitle: String {
        switch self {
        case .off: return "Off · Source Image"
        case .denoise: return "Denoise"
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
        case .clarity: return "CLARITY"
        case .lowLight: return "LOW LIGHT"
        case .upscale2x: return "2X UPSCALE"
        case .upscaleClarity2x: return "2X + CLARITY"
        }
    }
}

final class H264VideoView: NSView {
    var onDebug: ((String) -> Void)?
    var onFormat: ((Int, Int) -> Void)?
    var onMetadataPresence: ((VideoMetadataPresence) -> Void)?
    var onFrameReady: (() -> Void)?
    var onPipelineStats: ((VideoPipelineStats) -> Void)?
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
            enhancementLock.unlock()
        }
    }
    private let videoLayer = CALayer()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let softwareColorSpace = CGColorSpaceCreateDeviceRGB()
    private let enhancementLock = NSLock()
    private var storedEnhancementPreset = VideoEnhancementPreset.off
    private var formatDescription: CMVideoFormatDescription?
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
    private var latestDecodedFrame: CGImage?
    private let hardwareFrameLock = NSLock()
    private var pendingHardwareFrame: CGImage?
    private var hardwareFrameDeliveryScheduled = false
    private let frameRateLock = NSLock()
    private var decodedFramesInWindow = 0
    private var displayedFramesInWindow = 0
    private var frameRateWindowStarted = Date()

    private static let legacyFrameInfoUUID = Data([
        0x97, 0x77, 0x08, 0x83, 0xc8, 0xd3, 0x40, 0x2e,
        0x9c, 0xf8, 0xb1, 0x0a, 0x41, 0xf9, 0x12, 0xd4
    ])

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.actions = ["contents": NSNull()]
        layer?.addSublayer(videoLayer)
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
        softwareDecoder?.feed(nalUnits: nalUnits)

        let frameNALs = nalUnits.filter {
            guard let byte = $0.first else { return false }
            return ![7, 8, 9].contains(Int(byte & 0x1f))
        }
        guard !frameNALs.isEmpty else { return }

        if softwareDecoder != nil {
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
            duration: .invalid,
            presentationTimeStamp: .invalid,
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

        decode(sampleBuffer)
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
        hardwareFrameLock.lock()
        pendingHardwareFrame = nil
        hardwareFrameDeliveryScheduled = false
        hardwareFrameLock.unlock()
        videoLayer.contents = nil
        latestDecodedFrame = nil
        formatDescription = nil
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
            rebuildDecompressionSession(description)
            if !reportedParameterSets {
                reportedParameterSets = true
                if let description {
                    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                    let width = Int(dimensions.width)
                    let height = Int(dimensions.height)
                    onFormat?(width, height)
                    if receiveMode == .experimental1080p,
                       width != 1_920 || !(1_080...1_088).contains(height) {
                        onDebug?("1080p Lab expected 1920x1080/1088 but SPS reports \(width)x\(height); continuing safely")
                    }
                }
                onDebug?("H.264 SPS/PPS accepted")
            }
        } else {
            onDebug?("H.264 SPS/PPS rejected: OSStatus \(status)")
        }
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
            decoder.onFrame = { [weak self] data, width, height in
                self?.handleSoftwareFrame(data: data, width: width, height: height)
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
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard let refCon else { return }
                let view = Unmanaged<H264VideoView>.fromOpaque(refCon).takeUnretainedValue()
                view.handleDecodedFrame(status: status, imageBuffer: imageBuffer)
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
            self.onDebug?("VideoToolbox produced no frame in 3 seconds; switching 1080p Lab to recovery decoder")
            if let decompressionSession = self.decompressionSession {
                VTDecompressionSessionInvalidate(decompressionSession)
                self.decompressionSession = nil
            }
            _ = self.startSoftwareDecoder(width: width, height: height)
        }
        hardwareFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func decode(_ sampleBuffer: CMSampleBuffer) {
        guard let decompressionSession else { return }
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags,
        )
        if status != noErr {
            onDebug?("VideoToolbox rejected access unit: OSStatus \(status)")
        }
    }

    private func handleDecodedFrame(status: OSStatus, imageBuffer: CVImageBuffer?) {
        guard status == noErr, let imageBuffer else {
            DispatchQueue.main.async { [weak self] in
                self?.onDebug?("VideoToolbox frame decode failed: OSStatus \(status)")
            }
            return
        }
        recordFrameRate(decoded: 1, displayed: 0)
        let cgImage = autoreleasepool { () -> CGImage? in
            let image = CIImage(cvImageBuffer: imageBuffer)
            return renderEnhanced(image)
        }
        guard let cgImage else { return }
        enqueueLatestHardwareFrame(cgImage)
    }

    private func enqueueLatestHardwareFrame(_ image: CGImage) {
        hardwareFrameLock.lock()
        pendingHardwareFrame = image
        let shouldSchedule = !hardwareFrameDeliveryScheduled
        if shouldSchedule { hardwareFrameDeliveryScheduled = true }
        hardwareFrameLock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.deliverLatestHardwareFrame() }
        }
    }

    private func deliverLatestHardwareFrame() {
        hardwareFrameLock.lock()
        let image = pendingHardwareFrame
        pendingHardwareFrame = nil
        hardwareFrameLock.unlock()

        if let image {
            hardwareFallbackWorkItem?.cancel()
            hardwareFallbackWorkItem = nil
            latestDecodedFrame = image
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.contents = image
            CATransaction.commit()
            recordFrameRate(decoded: 0, displayed: 1)
            if !reportedFirstDecodedFrame {
                reportedFirstDecodedFrame = true
                onDebug?("First decoded video frame displayed: \(image.width)x\(image.height)")
                onFrameReady?()
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

    private func handleSoftwareFrame(data: Data, width: Int, height: Int) {
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

            let displayedImage: CGImage
            if enhancementPreset == .off {
                displayedImage = image
            } else {
                displayedImage = renderEnhanced(CIImage(cgImage: image)) ?? image
            }

            // Commit each replacement explicitly so Core Animation does not
            // accumulate full-resolution CGImages in an implicit transaction.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            latestDecodedFrame = displayedImage
            videoLayer.contents = displayedImage
            CATransaction.commit()
            recordFrameRate(decoded: 0, displayed: 1)
            if !reportedFirstDecodedFrame {
                reportedFirstDecodedFrame = true
                onDebug?("First software-decoded video frame displayed: \(displayedImage.width)x\(displayedImage.height)")
                onFrameReady?()
            }
        }
    }

    private func renderEnhanced(_ source: CIImage) -> CGImage? {
        let preset = enhancementPreset
        var image = source

        func applying(_ name: String, values: [String: Any]) {
            guard let filter = CIFilter(name: name) else { return }
            filter.setValue(image, forKey: kCIInputImageKey)
            for (key, value) in values { filter.setValue(value, forKey: key) }
            if let output = filter.outputImage { image = output }
        }

        switch preset {
        case .off:
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
        case .upscale2x:
            applying("CILanczosScaleTransform", values: [kCIInputScaleKey: 2.0, kCIInputAspectRatioKey: 1.0])
        case .upscaleClarity2x:
            applying("CINoiseReduction", values: ["inputNoiseLevel": 0.012, "inputSharpness": 0.45])
            applying("CISharpenLuminance", values: [kCIInputSharpnessKey: 0.34, kCIInputRadiusKey: 1.0])
            applying("CILanczosScaleTransform", values: [kCIInputScaleKey: 2.0, kCIInputAspectRatioKey: 1.0])
        }

        return ciContext.createCGImage(image, from: image.extent.integral)
    }

    /// Returns the most recently decoded source frame without the HUD overlay.
    /// The image is immutable and safe to hand to the background image writer.
    func latestFrameImage() -> CGImage? {
        dispatchPrecondition(condition: .onQueue(.main))
        return latestDecodedFrame
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
            displayRefreshFPS: Double(displayedFramesInWindow) / elapsed
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
        guard receiveMode == .experimental1080p,
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
