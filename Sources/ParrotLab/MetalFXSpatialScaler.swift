import CoreGraphics
import CoreImage
import CoreVideo
import Metal
import MetalFX

/// Owns the MetalFX resources used by the live preview. The scaler and its
/// private textures are reused while the source dimensions stay unchanged so
/// the 30 FPS path does not continually allocate full-frame GPU resources.
final class MetalFXSpatialScalerRenderer {
    private struct CachedPipeline {
        let inputWidth: Int
        let inputHeight: Int
        let outputWidth: Int
        let outputHeight: Int
        let scaler: any MTLFXSpatialScaler
        let inputTexture: any MTLTexture
        let outputTexture: any MTLTexture
    }

    static var isSupported: Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let renderLock = NSLock()
    private var cachedPipeline: CachedPipeline?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              MTLFXSpatialScalerDescriptor.supportsDevice(device),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    func render2x(_ source: CIImage) -> CGImage? {
        let extent = source.extent.integral
        let inputWidth = Int(extent.width)
        let inputHeight = Int(extent.height)
        guard inputWidth > 0, inputHeight > 0 else { return nil }
        let outputWidth = inputWidth * 2
        let outputHeight = inputHeight * 2

        renderLock.lock()
        defer { renderLock.unlock() }

        guard let pipeline = pipeline(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        ), let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        // Normalize non-zero CI origins before writing into the fixed-size
        // Metal texture used by MetalFX.
        let normalized = source.transformed(by: CGAffineTransform(
            translationX: -extent.origin.x,
            y: -extent.origin.y
        ))
        context.render(
            normalized,
            to: pipeline.inputTexture,
            commandBuffer: commandBuffer,
            bounds: CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight),
            colorSpace: colorSpace
        )
        pipeline.scaler.colorTexture = pipeline.inputTexture
        pipeline.scaler.outputTexture = pipeline.outputTexture
        pipeline.scaler.inputContentWidth = inputWidth
        pipeline.scaler.inputContentHeight = inputHeight
        pipeline.scaler.encode(commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed,
              let output = CIImage(
                mtlTexture: pipeline.outputTexture,
                options: [.colorSpace: colorSpace]
              ) else { return nil }
        return context.createCGImage(
            output,
            from: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        )
    }

    /// Scales directly into an IOSurface-backed destination suitable for
    /// VideoToolbox encoding. MetalFX works in private textures, then Core
    /// Image performs the final GPU copy into the shared pixel buffer; no CPU
    /// pixel readback is required for the recording branch.
    func render(
        _ source: CIImage,
        outputWidth: Int,
        outputHeight: Int,
        to destination: CVPixelBuffer
    ) -> Bool {
        let extent = source.extent.integral
        let inputWidth = Int(extent.width)
        let inputHeight = Int(extent.height)
        guard inputWidth > 0, inputHeight > 0,
              outputWidth >= inputWidth,
              outputHeight >= inputHeight,
              CVPixelBufferGetWidth(destination) == outputWidth,
              CVPixelBufferGetHeight(destination) == outputHeight else { return false }

        renderLock.lock()
        defer { renderLock.unlock() }

        guard let pipeline = pipeline(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        ), let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        let normalized = source.transformed(by: CGAffineTransform(
            translationX: -extent.origin.x,
            y: -extent.origin.y
        ))
        context.render(
            normalized,
            to: pipeline.inputTexture,
            commandBuffer: commandBuffer,
            bounds: CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight),
            colorSpace: colorSpace
        )
        pipeline.scaler.colorTexture = pipeline.inputTexture
        pipeline.scaler.outputTexture = pipeline.outputTexture
        pipeline.scaler.inputContentWidth = inputWidth
        pipeline.scaler.inputContentHeight = inputHeight
        pipeline.scaler.encode(commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed,
              let output = CIImage(
                mtlTexture: pipeline.outputTexture,
                options: [.colorSpace: colorSpace]
              ) else { return false }
        context.render(
            output,
            to: destination,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            colorSpace: colorSpace
        )
        return true
    }

    private func pipeline(
        inputWidth: Int,
        inputHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> CachedPipeline? {
        if let cachedPipeline,
           cachedPipeline.inputWidth == inputWidth,
           cachedPipeline.inputHeight == inputHeight,
           cachedPipeline.outputWidth == outputWidth,
           cachedPipeline.outputHeight == outputHeight {
            return cachedPipeline
        }

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.colorTextureFormat = .rgba8Unorm
        descriptor.outputTextureFormat = .rgba8Unorm
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorProcessingMode = .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: device) else { return nil }

        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: descriptor.colorTextureFormat,
            width: inputWidth,
            height: inputHeight,
            mipmapped: false
        )
        inputDescriptor.storageMode = .private
        inputDescriptor.usage = scaler.colorTextureUsage.union([.shaderRead, .shaderWrite, .renderTarget])

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: descriptor.outputTextureFormat,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        outputDescriptor.storageMode = .private
        outputDescriptor.usage = scaler.outputTextureUsage.union([.shaderRead, .shaderWrite])

        guard let inputTexture = device.makeTexture(descriptor: inputDescriptor),
              let outputTexture = device.makeTexture(descriptor: outputDescriptor) else { return nil }
        let pipeline = CachedPipeline(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            scaler: scaler,
            inputTexture: inputTexture,
            outputTexture: outputTexture
        )
        cachedPipeline = pipeline
        return pipeline
    }
}
