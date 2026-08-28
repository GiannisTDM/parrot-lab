import CoreMedia
import CoreVideo
import Foundation
import Metal

/// Calibrated inverse warp for the 4.7.1 1600x900 GPU-reprojected stream.
/// The input and output stay in IOSurface-backed BGRA buffers; the live path
/// never performs a CPU image readback.
final class RollingShutterMetalRenderer {
    private struct Uniforms {
        var previousQuaternion: SIMD4<Float>
        var currentQuaternion: SIMD4<Float>
        var referenceQuaternion: SIMD4<Float>
        var timing: SIMD4<Float>
        var intrinsics: SIMD4<Float>
        var limits: SIMD4<Float>
        var dimensions: SIMD4<UInt32>
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 previousQuaternion;
        float4 currentQuaternion;
        float4 referenceQuaternion;
        float4 timing;
        float4 intrinsics;
        float4 limits;
        uint4 dimensions;
    };

    constexpr sampler linearSampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::linear
    );

    float4 normalizedQuaternion(float4 value) {
        float lengthSquared = dot(value, value);
        return lengthSquared > 1.0e-12f ? value * rsqrt(lengthSquared) : float4(1, 0, 0, 0);
    }

    float4 quaternionSlerp(float4 start, float4 end, float fraction) {
        float4 a = normalizedQuaternion(start);
        float4 b = normalizedQuaternion(end);
        float cosine = dot(a, b);
        if (cosine < 0.0f) {
            b = -b;
            cosine = -cosine;
        }
        float t = clamp(fraction, 0.0f, 1.0f);
        if (cosine > 0.9995f) {
            return normalizedQuaternion(mix(a, b, t));
        }
        float angle = acos(clamp(cosine, -1.0f, 1.0f));
        float sine = sin(angle);
        return normalizedQuaternion(
            a * (sin((1.0f - t) * angle) / sine) +
            b * (sin(t * angle) / sine)
        );
    }

    float3 rotateActive(float4 quaternion, float3 vector) {
        float4 q = normalizedQuaternion(quaternion);
        float3 imaginary = q.yzw;
        return vector + 2.0f * cross(imaginary, cross(imaginary, vector) + q.x * vector);
    }

    float4 conjugated(float4 q) {
        return float4(q.x, -q.y, -q.z, -q.w);
    }

    float rowFraction(float rowStart, constant Uniforms &uniforms) {
        float exposure = uniforms.timing.x;
        float interval = max(uniforms.timing.y, 1.0e-6f);
        float readout = uniforms.timing.z;
        float irqDelay = uniforms.timing.w;
        float offsetFromEOF = -(readout - rowStart) - exposure * 0.5f - irqDelay;
        return clamp(1.0f + offsetFromEOF / interval, 0.0f, 1.0f);
    }

    kernel void rollingShutterWarp(
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        texture2d<float, access::sample> cameraRays [[texture(2)]],
        texture2d<float, access::sample> rowTiming [[texture(3)]],
        texture2d<float, access::sample> validity [[texture(4)]],
        constant Uniforms &uniforms [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint2 size = uniforms.dimensions.xy;
        if (gid.x >= size.x || gid.y >= size.y) return;

        float2 dimensions = float2(size);
        float2 destinationCoordinate = (float2(gid) + 0.5f) / dimensions;
        float4 original = source.sample(linearSampler, destinationCoordinate);
        float destinationValidity = validity.sample(linearSampler, destinationCoordinate).r;
        if (destinationValidity < 0.01f) {
            destination.write(original, gid);
            return;
        }

        // Camera rays are FRD: +X forward, +Y right, +Z down. frame_quat is
        // already the active camera/view FRD -> global NED rotation.
        float3 targetRay = normalize(cameraRays.sample(linearSampler, destinationCoordinate).xyz);
        float rowStart = rowTiming.sample(linearSampler, destinationCoordinate).x;
        float2 sourcePixel = float2(gid);
        float sourceValidity = destinationValidity;
        bool projected = true;

        // The first pass estimates the source coordinate using destination
        // timing; the second uses the calibrated timing at that projected
        // coordinate, avoiding a linear-output-row approximation.
        for (uint iteration = 0; iteration < 2; ++iteration) {
            float alpha = rowFraction(rowStart, uniforms);
            float4 rowQuaternion = quaternionSlerp(
                uniforms.previousQuaternion,
                uniforms.currentQuaternion,
                alpha
            );
            float maximumAngle = uniforms.limits.x;
            float angularDistance = 2.0f * acos(clamp(
                abs(dot(normalizedQuaternion(rowQuaternion), normalizedQuaternion(uniforms.referenceQuaternion))),
                0.0f,
                1.0f
            ));
            if (maximumAngle > 0.0f && angularDistance > maximumAngle) {
                rowQuaternion = quaternionSlerp(
                    uniforms.referenceQuaternion,
                    rowQuaternion,
                    maximumAngle / angularDistance
                );
            }

            float3 globalRay = rotateActive(uniforms.referenceQuaternion, targetRay);
            float3 sourceRay = rotateActive(conjugated(rowQuaternion), globalRay);
            if (sourceRay.x <= 0.02f) {
                projected = false;
                break;
            }
            sourcePixel = float2(
                uniforms.intrinsics.z + uniforms.intrinsics.x * sourceRay.y / sourceRay.x,
                uniforms.intrinsics.w + uniforms.intrinsics.y * sourceRay.z / sourceRay.x
            );
            if (sourcePixel.x < 0.0f || sourcePixel.y < 0.0f ||
                sourcePixel.x > dimensions.x - 1.0f || sourcePixel.y > dimensions.y - 1.0f) {
                projected = false;
                break;
            }
            float2 projectedCoordinate = (sourcePixel + 0.5f) / dimensions;
            sourceValidity = validity.sample(linearSampler, projectedCoordinate).r;
            rowStart = rowTiming.sample(linearSampler, projectedCoordinate).x;
        }

        if (!projected || sourceValidity < 0.01f) {
            destination.write(original, gid);
            return;
        }
        float2 sourceCoordinate = (sourcePixel + 0.5f) / dimensions;
        float4 corrected = source.sample(linearSampler, sourceCoordinate);
        float calibratedWeight = smoothstep(0.05f, 0.95f, min(destinationValidity, sourceValidity));
        destination.write(mix(original, corrected, calibratedWeight), gid);
    }
    """#

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private var textureCache: CVMetalTextureCache

    init?(device: any MTLDevice) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let function = library.makeFunction(name: "rollingShutterWarp"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        ) == kCVReturnSuccess, let cache else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        textureCache = cache
    }

    func render(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        calibration: Bebop900pCalibrationTextureSet,
        previousMotion: VerifiedVideoFrameMotion,
        currentMotion: VerifiedVideoFrameMotion,
        frameIntervalSeconds: Double,
        irqDelaySeconds: Double,
        maximumCorrectionAngleDegrees: Double
    ) -> Bool {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width == Bebop900pCameraCalibration.width,
              height == Bebop900pCameraCalibration.height,
              CVPixelBufferGetWidth(destination) == width,
              CVPixelBufferGetHeight(destination) == height,
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_32BGRA,
              frameIntervalSeconds.isFinite,
              frameIntervalSeconds > 0.005,
              frameIntervalSeconds < 0.2 else { return false }

        guard let sourceReference = makeTexture(from: source, width: width, height: height),
              let destinationReference = makeTexture(from: destination, width: width, height: height),
              let sourceTexture = CVMetalTextureGetTexture(sourceReference),
              let destinationTexture = CVMetalTextureGetTexture(destinationReference),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }

        let center = Bebop900pCameraCalibration.sample(
            x: Bebop900pCameraCalibration.cx,
            y: Bebop900pCameraCalibration.cy
        )
        let exposure = max(0, currentMotion.exposureDurationSeconds)
        let referenceOffset = -(
            Bebop900pCameraCalibration.activeReadoutSeconds -
                Double(center.sensorRowStartSeconds)
        ) - exposure * 0.5 - irqDelaySeconds
        let referenceFraction = max(0, min(1, 1 + referenceOffset / frameIntervalSeconds))
        let reference = VideoMetadataQuaternion.slerp(
            from: previousMotion.frameQuaternion,
            to: currentMotion.frameQuaternion,
            fraction: referenceFraction
        )
        var uniforms = Uniforms(
            previousQuaternion: Self.vector(previousMotion.frameQuaternion.normalized),
            currentQuaternion: Self.vector(currentMotion.frameQuaternion.normalized),
            referenceQuaternion: Self.vector(reference),
            timing: SIMD4<Float>(
                Float(exposure),
                Float(frameIntervalSeconds),
                Float(Bebop900pCameraCalibration.activeReadoutSeconds),
                Float(max(0, irqDelaySeconds))
            ),
            intrinsics: SIMD4<Float>(
                Float(Bebop900pCameraCalibration.fx),
                Float(Bebop900pCameraCalibration.fy),
                Float(Bebop900pCameraCalibration.cx),
                Float(Bebop900pCameraCalibration.cy)
            ),
            limits: SIMD4<Float>(
                Float(maximumCorrectionAngleDegrees * .pi / 180), 0, 0, 0
            ),
            dimensions: SIMD4<UInt32>(UInt32(width), UInt32(height), 0, 0)
        )

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(destinationTexture, index: 1)
        encoder.setTexture(calibration.rayTexture, index: 2)
        encoder.setTexture(calibration.rowTimingTexture, index: 3)
        encoder.setTexture(calibration.validityTexture, index: 4)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    static func selfTest() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = RollingShutterMetalRenderer(device: device),
              let calibration = Bebop900pCalibrationTextureSet(device: device),
              let source = makeTestBuffer(),
              let destination = makeTestBuffer(fill: 0) else { return false }
        let identity = VideoMetadataQuaternion(w: 1, x: 0, y: 0, z: 0)
        let previous = VerifiedVideoFrameMotion(
            sampleTime: .zero,
            rtpTimestamp: 0,
            droneQuaternion: identity,
            frameQuaternion: identity,
            cameraPanRadians: 0,
            cameraTiltRadians: 0,
            exposureDurationSeconds: 0.005,
            confidence: 1
        )
        let current = VerifiedVideoFrameMotion(
            sampleTime: CMTime(value: 3_003, timescale: 90_000),
            rtpTimestamp: 3_003,
            droneQuaternion: identity,
            frameQuaternion: identity,
            cameraPanRadians: 0,
            cameraTiltRadians: 0,
            exposureDurationSeconds: 0.005,
            confidence: 1
        )
        guard renderer.render(
            source: source,
            destination: destination,
            calibration: calibration,
            previousMotion: previous,
            currentMotion: current,
            frameIntervalSeconds: 3_003.0 / 90_000.0,
            irqDelaySeconds: 0,
            maximumCorrectionAngleDegrees: 6
        ) else { return false }
        CVPixelBufferLockBaseAddress(destination, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(destination) else { return false }
        let offset = (Bebop900pCameraCalibration.height / 2) * CVPixelBufferGetBytesPerRow(destination) +
            (Bebop900pCameraCalibration.width / 2) * 4
        let pixel = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        return (0..<4).allSatisfy { abs(Int(pixel[$0]) - 127) <= 1 }
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> CVMetalTexture? {
        var reference: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &reference
        ) == kCVReturnSuccess else { return nil }
        return reference
    }

    private static func vector(_ value: VideoMetadataQuaternion) -> SIMD4<Float> {
        SIMD4<Float>(Float(value.w), Float(value.x), Float(value.y), Float(value.z))
    }

    private static func makeTestBuffer(fill: UInt8 = 127) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            Bebop900pCameraCalibration.width,
            Bebop900pCameraCalibration.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(fill), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
