import CoreVideo
import Foundation
import Metal

/// A deliberately conservative, bounded H.264 damage-repair pass.
///
/// The spatial stage looks for chroma that is coherent inside a damaged block
/// but inconsistent with several surrounding samples. It also performs a
/// small edge-aware cleanup for mosquito noise. The temporal stage only uses
/// one prior repaired frame and accepts it when luma/chroma are close, so it
/// cannot build an unbounded history or add pipeline latency.
final class H264ArtifactRepairRenderer {
    private struct Uniforms {
        var dimensions: SIMD2<UInt32>
        var hasPrevious: UInt32
        var padding: UInt32 = 0
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        uint2 dimensions;
        uint hasPrevious;
        uint padding;
    };

    float luma(float3 rgb) {
        return dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
    }

    float3 chroma(float3 rgb) {
        return rgb - luma(rgb);
    }

    float4 samplePixel(texture2d<float, access::sample> texture, float2 pixel, float2 dimensions) {
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return texture.sample(linearSampler, (clamp(pixel, float2(0), dimensions - 1) + 0.5f) / dimensions);
    }

    kernel void repairH264Artifacts(
        texture2d<float, access::sample> currentTexture [[texture(0)]],
        texture2d<float, access::sample> previousTexture [[texture(1)]],
        texture2d<float, access::write> destination [[texture(2)]],
        constant Uniforms& uniforms [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]) {
        if (any(gid >= uniforms.dimensions)) return;

        float2 dimensions = float2(uniforms.dimensions);
        float2 p = float2(gid);
        float4 current = samplePixel(currentTexture, p, dimensions);
        float currentLuma = luma(current.rgb);
        float3 currentChroma = chroma(current.rgb);

        // Edge-aware local estimate: removes ringing/mosquito speckles while
        // refusing samples across real high-contrast edges.
        constexpr float2 localOffsets[8] = {
            float2(-1, 0), float2(1, 0), float2(0, -1), float2(0, 1),
            float2(-2, 0), float2(2, 0), float2(0, -2), float2(0, 2)
        };
        float3 localRGB = current.rgb;
        float localWeight = 1.0f;
        float localLumaSpread = 0.0f;
        for (uint index = 0; index < 8; ++index) {
            float3 sampleRGB = samplePixel(currentTexture, p + localOffsets[index], dimensions).rgb;
            float difference = abs(luma(sampleRGB) - currentLuma);
            float weight = 1.0f - smoothstep(0.018f, 0.075f, difference);
            localRGB += sampleRGB * weight;
            localWeight += weight;
            localLumaSpread = max(localLumaSpread, difference);
        }
        float3 localMean = localRGB / max(localWeight, 1.0f);

        // Surrounding samples lie beyond a typical damaged 8/16-pixel area.
        // Requiring their chroma to agree avoids treating ordinary green
        // foliage or a legitimate colored object as corruption.
        constexpr float2 contextOffsets[8] = {
            float2(-12, 0), float2(12, 0), float2(0, -12), float2(0, 12),
            float2(-10, -10), float2(10, -10), float2(-10, 10), float2(10, 10)
        };
        float3 contextRGB = float3(0);
        float3 contextChroma[8];
        for (uint index = 0; index < 8; ++index) {
            float3 value = samplePixel(currentTexture, p + contextOffsets[index], dimensions).rgb;
            contextRGB += value;
            contextChroma[index] = chroma(value);
        }
        contextRGB /= 8.0f;
        float3 contextC = chroma(contextRGB);
        float contextVariance = 0.0f;
        for (uint index = 0; index < 8; ++index) {
            contextVariance += length(contextChroma[index] - contextC);
        }
        contextVariance /= 8.0f;

        float chromaOutlier = length(currentChroma - contextC);
        float localCoherence = 1.0f - smoothstep(0.025f, 0.11f, length(currentChroma - chroma(localMean)));
        float contextCoherence = 1.0f - smoothstep(0.035f, 0.15f, contextVariance);
        // Corrupted chroma can also distort apparent luma substantially (the
        // classic bright-green decoder block), so luma is only a weak veto.
        float lumaCompatibility = 1.0f - smoothstep(0.18f, 0.58f, abs(currentLuma - luma(contextRGB)));
        float blockScore = smoothstep(0.11f, 0.34f, chromaOutlier) *
            localCoherence * contextCoherence * lumaCompatibility;

        float greenExcess = current.g - max(current.r, current.b);
        float contextGreenExcess = contextRGB.g - max(contextRGB.r, contextRGB.b);
        float isolatedGreen = smoothstep(0.16f, 0.42f, greenExcess - contextGreenExcess) *
            contextCoherence * lumaCompatibility;
        float artifactScore = clamp(max(blockScore, isolatedGreen), 0.0f, 1.0f);

        float smoothRegion = 1.0f - smoothstep(0.018f, 0.085f, localLumaSpread);
        float mosquitoStrength = 0.22f * smoothRegion;
        float repairedLuma = mix(currentLuma, luma(localMean), mosquitoStrength * 0.28f);
        float3 repairedChroma = mix(currentChroma, chroma(localMean), mosquitoStrength);
        repairedChroma = mix(repairedChroma, contextC, artifactScore * 0.88f);
        float3 repaired = clamp(float3(repairedLuma) + repairedChroma, 0.0f, 1.0f);

        if (uniforms.hasPrevious != 0) {
            float3 previous = samplePixel(previousTexture, p, dimensions).rgb;
            float previousLuma = luma(previous);
            float3 previousChroma = chroma(previous);
            float temporalDifference = abs(previousLuma - repairedLuma) +
                0.40f * length(previousChroma - repairedChroma);
            float stableConfidence = 1.0f - smoothstep(0.018f, 0.075f, temporalDifference);
            float previousContextFit = 1.0f - smoothstep(0.08f, 0.24f, length(previousChroma - contextC));
            float temporalWeight = 0.20f * stableConfidence * smoothRegion;
            temporalWeight = max(temporalWeight, artifactScore * previousContextFit * 0.78f);
            repaired = mix(repaired, previous, clamp(temporalWeight, 0.0f, 0.82f));
        }

        destination.write(float4(repaired, current.a), gid);
    }
    """#

    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    init?(device: any MTLDevice) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let function = library.makeFunction(name: "repairH264Artifacts"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else {
            return nil
        }
        textureCache = cache
    }

    func render(current: CVPixelBuffer, previous: CVPixelBuffer?, destination: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(current)
        let height = CVPixelBufferGetHeight(current)
        guard width == CVPixelBufferGetWidth(destination),
              height == CVPixelBufferGetHeight(destination),
              previous.map({ CVPixelBufferGetWidth($0) == width && CVPixelBufferGetHeight($0) == height }) ?? true,
              let currentTexture = texture(current),
              let previousTexture = texture(previous ?? current),
              let destinationTexture = texture(destination),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }

        var uniforms = Uniforms(
            dimensions: SIMD2<UInt32>(UInt32(width), UInt32(height)),
            hasPrevious: previous == nil ? 0 : 1
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(currentTexture, index: 0)
        encoder.setTexture(previousTexture, index: 1)
        encoder.setTexture(destinationTexture, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let threadWidth = min(pipeline.threadExecutionWidth, width)
        let threadHeight = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, height))
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    private func texture(_ pixelBuffer: CVPixelBuffer) -> (any MTLTexture)? {
        guard let textureCache else { return nil }
        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            0,
            &wrapped
        )
        guard status == kCVReturnSuccess, let wrapped else { return nil }
        return CVMetalTextureGetTexture(wrapped)
    }

    static func selfTest() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = H264ArtifactRepairRenderer(device: device),
              let current = makeTestBuffer(width: 64, height: 64, color: (100, 100, 100)),
              let previous = makeTestBuffer(width: 64, height: 64, color: (100, 100, 100)),
              let destination = makeTestBuffer(width: 64, height: 64, color: (0, 0, 0)) else { return false }
        CVPixelBufferLockBaseAddress(current, [])
        if let base = CVPixelBufferGetBaseAddress(current)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRow(current)
            for y in 24..<40 {
                for x in 24..<40 {
                    let offset = y * stride + x * 4
                    base[offset] = 20
                    base[offset + 1] = 240
                    base[offset + 2] = 20
                    base[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(current, [])
        guard renderer.render(current: current, previous: previous, destination: destination) else { return false }
        CVPixelBufferLockBaseAddress(destination, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(destination)?.assumingMemoryBound(to: UInt8.self) else {
            return false
        }
        let offset = 32 * CVPixelBufferGetBytesPerRow(destination) + 32 * 4
        let passed = base[offset + 1] < 205 && abs(Int(base[offset + 1]) - Int(base[offset + 2])) < 75
        if !passed {
            fputs("H.264 repair probe BGR=\(base[offset]),\(base[offset + 1]),\(base[offset + 2])\n", stderr)
        }
        return passed
    }

    private static func makeTestBuffer(
        width: Int,
        height: Int,
        color: (blue: UInt8, green: UInt8, red: UInt8)
    ) -> CVPixelBuffer? {
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
                base[offset] = color.blue
                base[offset + 1] = color.green
                base[offset + 2] = color.red
                base[offset + 3] = 255
            }
        }
        return buffer
    }
}
