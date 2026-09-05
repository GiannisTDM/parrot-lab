import CoreVideo
import Foundation
import Metal
import Vision
import simd

struct TemporalReconstructionRenderResult {
    let usedHistory: Bool
    let generatedIntermediateFrame: Bool
    let totalLatencyMilliseconds: Double
    let flowLatencyMilliseconds: Double
    let status: String
}

/// Causal temporal reconstruction for decoded Bebop 900p and Sumo video.
///
/// The previous source and history are first rotated into the current camera
/// pose with the synchronized frame quaternion. Vision then estimates the
/// residual image motion that remains after Dragon stabilization and the IMU
/// prediction. The resolve shader rejects history using photometric residuals
/// and, in quality mode, forward/backward flow consistency.
final class TemporalReconstructionRenderer {
    private struct FlowPoolKey: Hashable {
        let width: Int
        let height: Int
    }
    private struct AlignmentUniforms {
        var previousQuaternion: SIMD4<Float>
        var currentQuaternion: SIMD4<Float>
        var intrinsics: SIMD4<Float>
        var dimensions: SIMD2<UInt32>
        var useIMUAlignment: UInt32
        var padding: UInt32 = 0
    }

    private struct ResolveUniforms {
        var dimensions: SIMD2<UInt32>
        var flowDimensions: SIMD2<UInt32>
        var historyWeight: Float
        var ghostRejection: Float
        var consistencyThresholdPixels: Float
        var useBidirectionalFlow: UInt32
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct AlignmentUniforms {
        float4 previousQuaternion;
        float4 currentQuaternion;
        float4 intrinsics;
        uint2 dimensions;
        uint useIMUAlignment;
        uint padding;
    };

    struct ResolveUniforms {
        uint2 dimensions;
        uint2 flowDimensions;
        float historyWeight;
        float ghostRejection;
        float consistencyThresholdPixels;
        uint useBidirectionalFlow;
    };

    kernel void downscaleTemporalFlowInput(
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]) {
        uint2 outputSize(destination.get_width(), destination.get_height());
        if (any(gid >= outputSize)) return;
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5f) / float2(outputSize);
        destination.write(source.sample(linearSampler, uv), gid);
    }

    float4 normalizedQuaternion(float4 value) {
        float lengthSquared = dot(value, value);
        return lengthSquared > 1.0e-8f ? value * rsqrt(lengthSquared) : float4(1, 0, 0, 0);
    }

    float4 quaternionMultiply(float4 a, float4 b) {
        return float4(
            a.x * b.x - a.y * b.y - a.z * b.z - a.w * b.w,
            a.x * b.y + a.y * b.x + a.z * b.w - a.w * b.z,
            a.x * b.z - a.y * b.w + a.z * b.x + a.w * b.y,
            a.x * b.w + a.y * b.z - a.z * b.y + a.w * b.x
        );
    }

    float3 rotateVector(float4 quaternion, float3 value) {
        float4 q = normalizedQuaternion(quaternion);
        float3 axis = q.yzw;
        return value + 2.0f * cross(axis, cross(axis, value) + q.x * value);
    }

    kernel void alignTemporalHistory(
        texture2d<float, access::sample> previousSource [[texture(0)]],
        texture2d<float, access::sample> previousHistory [[texture(1)]],
        texture2d<float, access::write> alignedSource [[texture(2)]],
        texture2d<float, access::write> alignedHistory [[texture(3)]],
        constant AlignmentUniforms& uniforms [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]) {
        if (any(gid >= uniforms.dimensions)) return;

        float2 sourcePixel = float2(gid);
        if (uniforms.useIMUAlignment != 0) {
            float4 previousConjugate = uniforms.previousQuaternion;
            previousConjugate.yzw = -previousConjugate.yzw;
            float4 relative = quaternionMultiply(
                normalizedQuaternion(previousConjugate),
                normalizedQuaternion(uniforms.currentQuaternion)
            );
            float3 currentRay = normalize(float3(
                1.0f,
                (float(gid.x) - uniforms.intrinsics.z) / uniforms.intrinsics.x,
                (float(gid.y) - uniforms.intrinsics.w) / uniforms.intrinsics.y
            ));
            float3 previousRay = rotateVector(relative, currentRay);
            if (previousRay.x <= 1.0e-5f) {
                alignedSource.write(float4(0), gid);
                alignedHistory.write(float4(0), gid);
                return;
            }
            sourcePixel = float2(
                uniforms.intrinsics.x * previousRay.y / previousRay.x + uniforms.intrinsics.z,
                uniforms.intrinsics.y * previousRay.z / previousRay.x + uniforms.intrinsics.w
            );
        }

        float2 dimensions = float2(uniforms.dimensions);
        bool valid = all(sourcePixel >= float2(0.0f)) && all(sourcePixel < dimensions - 1.0f);
        if (!valid) {
            alignedSource.write(float4(0), gid);
            alignedHistory.write(float4(0), gid);
            return;
        }
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (sourcePixel + 0.5f) / dimensions;
        alignedSource.write(previousSource.sample(linearSampler, uv), gid);
        alignedHistory.write(previousHistory.sample(linearSampler, uv), gid);
    }

    float luma(float3 rgb) {
        return dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
    }

    kernel void resolveTemporalHistory(
        texture2d<float, access::sample> currentSource [[texture(0)]],
        texture2d<float, access::sample> alignedPreviousSource [[texture(1)]],
        texture2d<float, access::sample> alignedPreviousHistory [[texture(2)]],
        texture2d<float, access::sample> backwardFlow [[texture(3)]],
        texture2d<float, access::sample> forwardFlow [[texture(4)]],
        texture2d<float, access::write> destination [[texture(5)]],
        constant ResolveUniforms& uniforms [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]) {
        if (any(gid >= uniforms.dimensions)) return;
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

        float2 dimensions = float2(uniforms.dimensions);
        float2 flowDimensions = max(float2(uniforms.flowDimensions), float2(1.0f));
        float2 uv = (float2(gid) + 0.5f) / dimensions;
        float2 flowScale = dimensions / flowDimensions;
        float2 backward = backwardFlow.sample(linearSampler, uv).xy * flowScale;
        float2 previousPixel = float2(gid) + backward;
        bool valid = all(previousPixel >= float2(0.0f)) && all(previousPixel < dimensions - 1.0f);

        float4 current = currentSource.sample(linearSampler, uv);
        if (!valid) {
            destination.write(current, gid);
            return;
        }

        float2 previousUV = (previousPixel + 0.5f) / dimensions;
        float4 previousSource = alignedPreviousSource.sample(linearSampler, previousUV);
        float4 previousHistory = alignedPreviousHistory.sample(linearSampler, previousUV);

        float lumaDifference = abs(luma(current.rgb) - luma(previousSource.rgb));
        float3 currentChroma = current.rgb - luma(current.rgb);
        float3 previousChroma = previousSource.rgb - luma(previousSource.rgb);
        float chromaDifference = length(currentChroma - previousChroma) * 0.35f;
        float residual = lumaDifference + chromaDifference;

        // Higher ghostRejection means a smaller acceptance threshold and a
        // stronger preference for the current frame around moving edges.
        float residualThreshold = mix(0.24f, 0.018f, clamp(uniforms.ghostRejection, 0.0f, 1.0f));
        float photometricConfidence = 1.0f - smoothstep(
            residualThreshold * 0.45f,
            residualThreshold,
            residual
        );

        float consistencyConfidence = 1.0f;
        if (uniforms.useBidirectionalFlow != 0) {
            float2 forward = forwardFlow.sample(linearSampler, previousUV).xy * flowScale;
            float consistencyError = length(backward + forward);
            float threshold = max(0.25f, uniforms.consistencyThresholdPixels);
            consistencyConfidence = 1.0f - smoothstep(threshold * 0.5f, threshold, consistencyError);
        }

        float confidence = clamp(photometricConfidence * consistencyConfidence, 0.0f, 1.0f);
        float historyWeight = clamp(uniforms.historyWeight * confidence, 0.0f, 0.92f);
        destination.write(mix(current, previousHistory, historyWeight), gid);
    }

    kernel void interpolateTemporalMidpoint(
        texture2d<float, access::sample> currentHistory [[texture(0)]],
        texture2d<float, access::sample> alignedPreviousHistory [[texture(1)]],
        texture2d<float, access::sample> backwardFlow [[texture(2)]],
        texture2d<float, access::sample> forwardFlow [[texture(3)]],
        texture2d<float, access::write> destination [[texture(4)]],
        constant ResolveUniforms& uniforms [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]) {
        if (any(gid >= uniforms.dimensions)) return;
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 dimensions = float2(uniforms.dimensions);
        float2 flowDimensions = max(float2(uniforms.flowDimensions), float2(1.0f));
        float2 uv = (float2(gid) + 0.5f) / dimensions;
        float2 flowScale = dimensions / flowDimensions;
        float2 backward = backwardFlow.sample(linearSampler, uv).xy * flowScale;
        float2 forward = forwardFlow.sample(linearSampler, uv).xy * flowScale;

        // The backward field is current -> previous and the forward field is
        // previous -> current. Sample each endpoint halfway along its motion.
        float2 currentPixel = float2(gid) - backward * 0.5f;
        float2 previousPixel = float2(gid) - forward * 0.5f;
        bool valid = all(currentPixel >= float2(0.0f)) &&
            all(previousPixel >= float2(0.0f)) &&
            all(currentPixel < dimensions - 1.0f) &&
            all(previousPixel < dimensions - 1.0f);
        float4 fallback = currentHistory.sample(linearSampler, uv);
        if (!valid) {
            destination.write(fallback, gid);
            return;
        }

        float4 current = currentHistory.sample(linearSampler, (currentPixel + 0.5f) / dimensions);
        float4 previous = alignedPreviousHistory.sample(linearSampler, (previousPixel + 0.5f) / dimensions);
        float threshold = max(0.5f, uniforms.consistencyThresholdPixels);
        float consistency = 1.0f - smoothstep(threshold * 0.5f, threshold, length(backward + forward));
        float residual = abs(luma(current.rgb) - luma(previous.rgb));
        float photometric = 1.0f - smoothstep(0.035f, 0.16f, residual);
        float confidence = clamp(consistency * photometric, 0.0f, 1.0f);
        destination.write(mix(fallback, mix(previous, current, 0.5f), confidence), gid);
    }
    """#

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let alignmentPipeline: any MTLComputePipelineState
    private let downscalePipeline: any MTLComputePipelineState
    private let resolvePipeline: any MTLComputePipelineState
    private let interpolationPipeline: any MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private var flowInputPools: [FlowPoolKey: CVPixelBufferPool] = [:]
    private var adaptiveFlowScale = 0.25
    private var flowScaleCeiling = 0.375
    private let flowQueue = DispatchQueue(
        label: "parrotlab.temporal-flow",
        qos: .userInteractive,
        attributes: .concurrent
    )

    private final class FlowResultBox {
        private let lock = NSLock()
        private var stored: Result<CVPixelBuffer, Error>?
        func set(_ value: Result<CVPixelBuffer, Error>) {
            lock.lock(); stored = value; lock.unlock()
        }
        func get() -> Result<CVPixelBuffer, Error>? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    init?(device: any MTLDevice) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let alignmentFunction = library.makeFunction(name: "alignTemporalHistory"),
              let downscaleFunction = library.makeFunction(name: "downscaleTemporalFlowInput"),
              let resolveFunction = library.makeFunction(name: "resolveTemporalHistory"),
              let interpolationFunction = library.makeFunction(name: "interpolateTemporalMidpoint"),
              let alignmentPipeline = try? device.makeComputePipelineState(function: alignmentFunction),
              let downscalePipeline = try? device.makeComputePipelineState(function: downscaleFunction),
              let resolvePipeline = try? device.makeComputePipelineState(function: resolveFunction),
              let interpolationPipeline = try? device.makeComputePipelineState(function: interpolationFunction) else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.alignmentPipeline = alignmentPipeline
        self.downscalePipeline = downscalePipeline
        self.resolvePipeline = resolvePipeline
        self.interpolationPipeline = interpolationPipeline
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else {
            return nil
        }
        textureCache = cache
    }

    func reconstruct(
        currentSource: CVPixelBuffer,
        previousSource: CVPixelBuffer,
        previousHistory: CVPixelBuffer,
        alignedSource: CVPixelBuffer,
        alignedHistory: CVPixelBuffer,
        destination: CVPixelBuffer,
        intermediateDestination: CVPixelBuffer?,
        previousMotion: VerifiedVideoFrameMotion?,
        currentMotion: VerifiedVideoFrameMotion?,
        configuration: TemporalReconstructionConfiguration
    ) -> TemporalReconstructionRenderResult {
        let started = CFAbsoluteTimeGetCurrent()
        guard matchingDimensions([
            currentSource, previousSource, previousHistory,
            alignedSource, alignedHistory, destination
        ]) else {
            return result(started, flow: 0, used: false, status: "TEMPORAL RESET · DIMENSIONS CHANGED")
        }

        // Ground reuses history directly: no pose prewarp, extra copies or GPU wait.
        guard configuration.flowOnlyGround || align(
            previousSource: previousSource,
            previousHistory: previousHistory,
            alignedSource: alignedSource,
            alignedHistory: alignedHistory,
            previousMotion: configuration.flowOnlyGround ? nil : previousMotion,
            currentMotion: configuration.flowOnlyGround ? nil : currentMotion
        ) else {
            return result(started, flow: 0, used: false, status: "TEMPORAL BYPASS · IMU ALIGNMENT FAILED")
        }

        let sourceWidth = CVPixelBufferGetWidth(currentSource)
        let sourceHeight = CVPixelBufferGetHeight(currentSource)
        if abs(flowScaleCeiling - configuration.flowResolutionScale) > 0.001 {
            flowScaleCeiling = configuration.flowResolutionScale
            adaptiveFlowScale = min(flowScaleCeiling, configuration.flowOnlyGround ? 0.5 : 0.25)
        }
        let effectiveFlowScale = min(configuration.flowResolutionScale, adaptiveFlowScale)
        let flowWidth = Self.flowDimension(sourceWidth, scale: effectiveFlowScale)
        let flowHeight = Self.flowDimension(sourceHeight, scale: effectiveFlowScale)
        guard let flowCurrent = makeBGRAFlowInput(width: flowWidth, height: flowHeight),
              let flowPrevious = makeBGRAFlowInput(width: flowWidth, height: flowHeight),
              downscale(currentSource, to: flowCurrent, and: alignedSource, to: flowPrevious) else {
            return result(started, flow: 0, used: false, status: "TEMPORAL BYPASS · FLOW INPUT FAILED")
        }

        let flowStarted = CFAbsoluteTimeGetCurrent()
        let flows: (backward: CVPixelBuffer, forward: CVPixelBuffer)
        let needsForwardFlow = configuration.usesBidirectionalFlow &&
            (configuration.flowOnlyGround || !configuration.generatesIntermediateFrames || intermediateDestination != nil)
        do {
            flows = try opticalFlowPair(
                current: flowCurrent,
                previous: flowPrevious,
                bidirectional: needsForwardFlow
            )
        } catch {
            return result(started, flow: 0, used: false, status: "TEMPORAL BYPASS · FLOW FAILED")
        }
        let backward = flows.backward
        let forward = flows.forward
        let flowLatency = (CFAbsoluteTimeGetCurrent() - flowStarted) * 1_000
        tuneFlowResolution(measuredLatencyMilliseconds: flowLatency)

        guard flowLatency <= configuration.latencyBudgetMilliseconds else {
            return result(
                started,
                flow: flowLatency,
                used: false,
                status: String(format: "TEMPORAL BUDGET · %.1f > %.1f ms", flowLatency, configuration.latencyBudgetMilliseconds)
            )
        }

        guard resolve(
            currentSource: currentSource,
            alignedSource: alignedSource,
            alignedHistory: alignedHistory,
            backwardFlow: backward,
            forwardFlow: forward,
            destination: destination,
            configuration: configuration,
            usesBidirectionalFlow: needsForwardFlow
        ) else {
            return result(started, flow: flowLatency, used: false, status: "TEMPORAL BYPASS · GPU RESOLVE FAILED")
        }
        let generatedIntermediate: Bool
        if configuration.generatesIntermediateFrames,
           configuration.usesBidirectionalFlow,
           let intermediateDestination {
            generatedIntermediate = interpolateMidpoint(
                currentHistory: destination,
                alignedHistory: alignedHistory,
                backwardFlow: backward,
                forwardFlow: forward,
                destination: intermediateDestination,
                configuration: configuration
            )
        } else {
            generatedIntermediate = false
        }
        return result(
            started,
            flow: flowLatency,
            used: true,
            status: String(
                format: "TEMPORAL ACTIVE · %@ · %@ %dx%d FLOW %.1f ms%@",
                configuration.flowOnlyGround ? "GROUND FLOW ONLY" : (previousMotion != nil && currentMotion != nil ? "IMU ALIGNED" : "FLOW ONLY"),
                needsForwardFlow ? "BIDIRECTIONAL" : "FORWARD-SPARING",
                flowWidth,
                flowHeight,
                flowLatency,
                generatedIntermediate ? " · MIDPOINT GENERATED" : ""
            ),
            generated: generatedIntermediate
        )
    }

    private func align(
        previousSource: CVPixelBuffer,
        previousHistory: CVPixelBuffer,
        alignedSource: CVPixelBuffer,
        alignedHistory: CVPixelBuffer,
        previousMotion: VerifiedVideoFrameMotion?,
        currentMotion: VerifiedVideoFrameMotion?
    ) -> Bool {
        let width = CVPixelBufferGetWidth(previousSource)
        let height = CVPixelBufferGetHeight(previousSource)
        guard let sourceTexture = bgraTexture(previousSource),
              let historyTexture = bgraTexture(previousHistory),
              let alignedSourceTexture = bgraTexture(alignedSource),
              let alignedHistoryTexture = bgraTexture(alignedHistory),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }

        let usesIMU = width == Bebop900pCameraCalibration.width &&
            height == Bebop900pCameraCalibration.height &&
            previousMotion != nil && currentMotion != nil
        var uniforms = AlignmentUniforms(
            previousQuaternion: Self.vector(previousMotion?.frameQuaternion),
            currentQuaternion: Self.vector(currentMotion?.frameQuaternion),
            intrinsics: SIMD4<Float>(
                Float(Bebop900pCameraCalibration.fx),
                Float(Bebop900pCameraCalibration.fy),
                Float(Bebop900pCameraCalibration.cx),
                Float(Bebop900pCameraCalibration.cy)
            ),
            dimensions: SIMD2<UInt32>(UInt32(width), UInt32(height)),
            useIMUAlignment: usesIMU ? 1 : 0
        )
        encoder.setComputePipelineState(alignmentPipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(historyTexture, index: 1)
        encoder.setTexture(alignedSourceTexture, index: 2)
        encoder.setTexture(alignedHistoryTexture, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<AlignmentUniforms>.stride, index: 0)
        dispatch(encoder, pipeline: alignmentPipeline, width: width, height: height)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    private func resolve(
        currentSource: CVPixelBuffer,
        alignedSource: CVPixelBuffer,
        alignedHistory: CVPixelBuffer,
        backwardFlow: CVPixelBuffer,
        forwardFlow: CVPixelBuffer,
        destination: CVPixelBuffer,
        configuration: TemporalReconstructionConfiguration,
        usesBidirectionalFlow: Bool
    ) -> Bool {
        let width = CVPixelBufferGetWidth(currentSource)
        let height = CVPixelBufferGetHeight(currentSource)
        let flowWidth = CVPixelBufferGetWidth(backwardFlow)
        let flowHeight = CVPixelBufferGetHeight(backwardFlow)
        guard let currentTexture = bgraTexture(currentSource),
              let alignedSourceTexture = bgraTexture(alignedSource),
              let alignedHistoryTexture = bgraTexture(alignedHistory),
              let backwardTexture = flowTexture(backwardFlow),
              let forwardTexture = flowTexture(forwardFlow),
              let destinationTexture = bgraTexture(destination),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }

        var uniforms = ResolveUniforms(
            dimensions: SIMD2<UInt32>(UInt32(width), UInt32(height)),
            flowDimensions: SIMD2<UInt32>(UInt32(flowWidth), UInt32(flowHeight)),
            historyWeight: Float(configuration.historyWeight),
            ghostRejection: Float(configuration.ghostRejection),
            consistencyThresholdPixels: Float(configuration.consistencyThresholdPixels),
            useBidirectionalFlow: usesBidirectionalFlow ? 1 : 0
        )
        encoder.setComputePipelineState(resolvePipeline)
        encoder.setTexture(currentTexture, index: 0)
        encoder.setTexture(alignedSourceTexture, index: 1)
        encoder.setTexture(alignedHistoryTexture, index: 2)
        encoder.setTexture(backwardTexture, index: 3)
        encoder.setTexture(forwardTexture, index: 4)
        encoder.setTexture(destinationTexture, index: 5)
        encoder.setBytes(&uniforms, length: MemoryLayout<ResolveUniforms>.stride, index: 0)
        dispatch(encoder, pipeline: resolvePipeline, width: width, height: height)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    private func downscale(
        _ firstSource: CVPixelBuffer,
        to firstDestination: CVPixelBuffer,
        and secondSource: CVPixelBuffer,
        to secondDestination: CVPixelBuffer
    ) -> Bool {
        guard let firstSourceTexture = bgraTexture(firstSource),
              let firstDestinationTexture = bgraTexture(firstDestination),
              let secondSourceTexture = bgraTexture(secondSource),
              let secondDestinationTexture = bgraTexture(secondDestination),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        for (source, destination) in [
            (firstSourceTexture, firstDestinationTexture),
            (secondSourceTexture, secondDestinationTexture)
        ] {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
            encoder.setComputePipelineState(downscalePipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            dispatch(
                encoder,
                pipeline: downscalePipeline,
                width: destination.width,
                height: destination.height
            )
            encoder.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    private func interpolateMidpoint(
        currentHistory: CVPixelBuffer,
        alignedHistory: CVPixelBuffer,
        backwardFlow: CVPixelBuffer,
        forwardFlow: CVPixelBuffer,
        destination: CVPixelBuffer,
        configuration: TemporalReconstructionConfiguration
    ) -> Bool {
        let width = CVPixelBufferGetWidth(currentHistory)
        let height = CVPixelBufferGetHeight(currentHistory)
        let flowWidth = CVPixelBufferGetWidth(backwardFlow)
        let flowHeight = CVPixelBufferGetHeight(backwardFlow)
        guard let currentTexture = bgraTexture(currentHistory),
              let historyTexture = bgraTexture(alignedHistory),
              let backwardTexture = flowTexture(backwardFlow),
              let forwardTexture = flowTexture(forwardFlow),
              let destinationTexture = bgraTexture(destination),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        var uniforms = ResolveUniforms(
            dimensions: SIMD2<UInt32>(UInt32(width), UInt32(height)),
            flowDimensions: SIMD2<UInt32>(UInt32(flowWidth), UInt32(flowHeight)),
            historyWeight: Float(configuration.historyWeight),
            ghostRejection: Float(configuration.ghostRejection),
            consistencyThresholdPixels: Float(configuration.consistencyThresholdPixels),
            useBidirectionalFlow: 1
        )
        encoder.setComputePipelineState(interpolationPipeline)
        encoder.setTexture(currentTexture, index: 0)
        encoder.setTexture(historyTexture, index: 1)
        encoder.setTexture(backwardTexture, index: 2)
        encoder.setTexture(forwardTexture, index: 3)
        encoder.setTexture(destinationTexture, index: 4)
        encoder.setBytes(&uniforms, length: MemoryLayout<ResolveUniforms>.stride, index: 0)
        dispatch(encoder, pipeline: interpolationPipeline, width: width, height: height)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    private func opticalFlowPair(
        current: CVPixelBuffer,
        previous: CVPixelBuffer,
        bidirectional: Bool
    ) throws -> (backward: CVPixelBuffer, forward: CVPixelBuffer) {
        guard bidirectional else {
            let backward = try opticalFlow(from: current, to: previous)
            return (backward, backward)
        }
        let backwardBox = FlowResultBox()
        let forwardBox = FlowResultBox()
        let group = DispatchGroup()
        group.enter()
        flowQueue.async { [weak self] in
            defer { group.leave() }
            guard let self else { return }
            backwardBox.set(Result { try self.opticalFlow(from: current, to: previous) })
        }
        group.enter()
        flowQueue.async { [weak self] in
            defer { group.leave() }
            guard let self else { return }
            forwardBox.set(Result { try self.opticalFlow(from: previous, to: current) })
        }
        group.wait()
        guard let backwardResult = backwardBox.get(),
              let forwardResult = forwardBox.get() else {
            throw NSError(domain: "ParrotLab.TemporalFlow", code: 2)
        }
        return (try backwardResult.get(), try forwardResult.get())
    }

    private func makeBGRAFlowInput(width: Int, height: Int) -> CVPixelBuffer? {
        let key = FlowPoolKey(width: width, height: height)
        let pool: CVPixelBufferPool
        if let cached = flowInputPools[key] {
            pool = cached
        } else {
            flowInputPools.removeAll(keepingCapacity: false)
            let poolAttributes: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 4
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
            flowInputPools[key] = created
            pool = created
        }
        let auxiliary: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: 6
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

    private func opticalFlow(from source: CVPixelBuffer, to target: CVPixelBuffer) throws -> CVPixelBuffer {
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: target, options: [:])
        request.computationAccuracy = .low
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
        if #available(macOS 13.0, *) { request.revision = VNGenerateOpticalFlowRequestRevision2 }
        let handler = VNImageRequestHandler(cvPixelBuffer: source, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else {
            throw NSError(domain: "ParrotLab.TemporalFlow", code: 1)
        }
        return observation.pixelBuffer
    }

    private func matchingDimensions(_ buffers: [CVPixelBuffer]) -> Bool {
        guard let first = buffers.first else { return false }
        let width = CVPixelBufferGetWidth(first)
        let height = CVPixelBufferGetHeight(first)
        return buffers.allSatisfy {
            CVPixelBufferGetWidth($0) == width && CVPixelBufferGetHeight($0) == height
        }
    }

    private func bgraTexture(_ pixelBuffer: CVPixelBuffer) -> (any MTLTexture)? {
        makeTexture(pixelBuffer, format: .bgra8Unorm)
    }

    private func flowTexture(_ pixelBuffer: CVPixelBuffer) -> (any MTLTexture)? {
        makeTexture(pixelBuffer, format: .rg16Float)
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer, format: MTLPixelFormat) -> (any MTLTexture)? {
        guard let textureCache else { return nil }
        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            format,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            0,
            &wrapped
        )
        guard status == kCVReturnSuccess, let wrapped else { return nil }
        return CVMetalTextureGetTexture(wrapped)
    }

    private func dispatch(
        _ encoder: any MTLComputeCommandEncoder,
        pipeline: any MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = min(pipeline.threadExecutionWidth, width)
        let threadHeight = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, height))
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
    }

    private func result(
        _ started: CFAbsoluteTime,
        flow: Double,
        used: Bool,
        status: String,
        generated: Bool = false
    ) -> TemporalReconstructionRenderResult {
        TemporalReconstructionRenderResult(
            usedHistory: used,
            generatedIntermediateFrame: generated,
            totalLatencyMilliseconds: (CFAbsoluteTimeGetCurrent() - started) * 1_000,
            flowLatencyMilliseconds: flow,
            status: status
        )
    }

    private static func vector(_ quaternion: VideoMetadataQuaternion?) -> SIMD4<Float> {
        let value = quaternion?.normalized ?? VideoMetadataQuaternion(w: 1, x: 0, y: 0, z: 0)
        return SIMD4<Float>(Float(value.w), Float(value.x), Float(value.y), Float(value.z))
    }

    private static func flowDimension(_ source: Int, scale: Double) -> Int {
        let scaled = Int((Double(source) * min(1, max(0.18, scale))).rounded())
        return max(32, min(source, scaled) & ~1)
    }

    private func tuneFlowResolution(measuredLatencyMilliseconds: Double) {
        // Reserve roughly half of a 30 fps frame budget for the rest of the
        // processing chain. Move down quickly after a miss and recover quality
        // slowly when the machine has sustained headroom.
        if measuredLatencyMilliseconds > 18 {
            let ratio = sqrt(16 / max(18, measuredLatencyMilliseconds))
            adaptiveFlowScale = max(0.18, adaptiveFlowScale * ratio)
        } else if measuredLatencyMilliseconds < 11 {
            adaptiveFlowScale = min(flowScaleCeiling, adaptiveFlowScale + 0.01)
        }
    }

    static func selfTest() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = TemporalReconstructionRenderer(device: device),
              let current = makeTestBuffer(width: 96, height: 54, value: 96),
              let previousSource = makeTestBuffer(width: 96, height: 54, value: 96),
              let previousHistory = makeTestBuffer(width: 96, height: 54, value: 160),
              let alignedSource = makeTestBuffer(width: 96, height: 54, value: 0),
              let alignedHistory = makeTestBuffer(width: 96, height: 54, value: 0),
              let destination = makeTestBuffer(width: 96, height: 54, value: 0) else { return false }
        var configuration = TemporalReconstructionConfiguration()
        configuration.isEnabled = true
        configuration.historyWeight = 0.5
        configuration.ghostRejection = 0
        configuration.latencyBudgetMilliseconds = 2_000
        configuration.usesBidirectionalFlow = false
        let result = renderer.reconstruct(
            currentSource: current,
            previousSource: previousSource,
            previousHistory: previousHistory,
            alignedSource: alignedSource,
            alignedHistory: alignedHistory,
            destination: destination,
            intermediateDestination: nil,
            previousMotion: nil,
            currentMotion: nil,
            configuration: configuration
        )
        guard result.usedHistory else { return false }
        CVPixelBufferLockBaseAddress(destination, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(destination)?.assumingMemoryBound(to: UInt8.self) else {
            return false
        }
        let stride = CVPixelBufferGetBytesPerRow(destination)
        let value = bytes[27 * stride + 48 * 4]
        guard (118...142).contains(value),
              let bidirectionalDestination = makeTestBuffer(width: 96, height: 54, value: 0),
              let intermediate = makeTestBuffer(width: 96, height: 54, value: 0) else { return false }
        configuration.usesBidirectionalFlow = true
        configuration.generatesIntermediateFrames = true
        configuration.flowResolutionScale = 0.5
        let generated = renderer.reconstruct(
            currentSource: current,
            previousSource: previousSource,
            previousHistory: previousHistory,
            alignedSource: alignedSource,
            alignedHistory: alignedHistory,
            destination: bidirectionalDestination,
            intermediateDestination: intermediate,
            previousMotion: nil,
            currentMotion: nil,
            configuration: configuration
        )
        return generated.usedHistory && generated.generatedIntermediateFrame
    }

    private static func makeTestBuffer(width: Int, height: Int, value: UInt8) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                base[offset] = value
                base[offset + 1] = value
                base[offset + 2] = value
                base[offset + 3] = 255
            }
        }
        return buffer
    }
}
