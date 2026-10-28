import Foundation
import CoreImage
import CoreVideo
import Vision

/// One inference per semantic cycle. The short-lived helper and its masks die
/// with that frame; the gallery retains only small numeric featureprints.
final class SumoForegroundMask {
    private var imageForBox: ((CGRect) -> CGImage?)?
    private static let context = CIContext(options: [.cacheIntermediates: false])

    init(pixelBuffer: CVPixelBuffer) {
        if #available(macOS 14, *) {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            let request = VNGenerateForegroundInstanceMaskRequest()
            SumoVisionCompute.configure(request)
            do {
                try SumoVisionCompute.perform(request, with: handler)
                guard let result = request.results?.first, !result.allInstances.isEmpty else { return }
                imageForBox = { box in
                    guard let instance = Self.select(in: result.instanceMask, box: box),
                          result.allInstances.contains(instance),
                          let mask = try? result.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler)
                    else { return nil }
                    return Self.compose(image: CIImage(cvPixelBuffer: pixelBuffer), mask: CIImage(cvPixelBuffer: mask), box: box)
                }
            } catch { /* Masking is optional; original crops remain available. */ }
        }
    }

    func image(for box: CGRect) -> CGImage? { imageForBox?(box) }

    private static func select(in buffer: CVPixelBuffer, box: CGRect) -> Int? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        return select(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), box: box) { x, y in
            Int(base[y * rowBytes + x])
        }
    }

    /// Instance masks use top-left raster rows; tracking boxes are bottom-left.
    /// Reject merged bedding/animal masks, tiny fragments and ambiguous animals.
    static func select(width: Int, height: Int, box: CGRect, pixel: (Int, Int) -> Int) -> Int? {
        guard width > 0, height > 0, width <= 4096, height <= 4096, SumoTargetSearch.valid(box) else { return nil }
        let x0 = max(0, Int(floor(box.minX * CGFloat(width))))
        let x1 = min(width, Int(ceil(box.maxX * CGFloat(width))))
        let y0 = max(0, Int(floor((1 - box.maxY) * CGFloat(height))))
        let y1 = min(height, Int(ceil((1 - box.minY) * CGFloat(height))))
        guard x1 > x0, y1 > y0 else { return nil }
        var total = [Int](repeating: 0, count: 256), inside = total
        for y in 0..<height {
            for x in 0..<width {
                let id = pixel(x, y)
                guard (1...255).contains(id) else { continue }
                total[id] += 1
                if x >= x0, x < x1, y >= y0, y < y1 { inside[id] += 1 }
            }
        }
        let area = Double((x1 - x0) * (y1 - y0))
        let ranked = (1...255).compactMap { id -> (Int, Double)? in
            guard total[id] > 0, inside[id] >= 12 else { return nil }
            let coverage = Double(inside[id]) / area, containment = Double(inside[id]) / Double(total[id])
            guard (0.12...0.95).contains(coverage), containment >= 0.55 else { return nil }
            return (id, sqrt(coverage) * containment)
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first else { return nil }
        if ranked.count > 1, best.1 - ranked[1].1 < 0.12 { return nil }
        return best.0
    }

    private static func compose(image: CIImage, mask: CIImage, box: CGRect) -> CGImage? {
        guard SumoTargetSearch.valid(box) else { return nil }
        let extent = image.extent
        let crop = CGRect(x: extent.minX + box.minX * extent.width, y: extent.minY + box.minY * extent.height,
                          width: box.width * extent.width, height: box.height * extent.height).integral.intersection(extent)
        guard !crop.isNull, !crop.isEmpty else { return nil }
        let background = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let composed = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background,
                                                                          kCIInputMaskImageKey: mask])
        return context.createCGImage(composed, from: crop)
    }

    static func selfTest() -> Bool {
        let roi = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        func cat(_ x: Int, _ y: Int) -> Int { (6..<14).contains(x) && (6..<14).contains(y) ? 1 : 0 }
        guard select(width: 20, height: 20, box: roi, pixel: cat) == 1,
              select(width: 20, height: 20, box: roi, pixel: { _, _ in 1 }) == nil,
              select(width: 20, height: 20, box: roi, pixel: { _, _ in 0 }) == nil,
              select(width: 20, height: 20, box: roi, pixel: { x, y in
                  (6..<10).contains(x) && (6..<14).contains(y) ? 1 : (10..<14).contains(x) && (6..<14).contains(y) ? 2 : 0
              }) == nil else { return false }
        // Bottom-left boxes must select the corresponding top raster rows.
        guard select(width: 20, height: 20, box: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5), pixel: { x, y in
            (6..<14).contains(x) && (2..<8).contains(y) ? 2 : 0
        }) == 2 else { return false }
        let extent = CGRect(x: 0, y: 0, width: 32, height: 32)
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: extent)
        let mask = CIImage(color: .white).cropped(to: CGRect(x: 8, y: 8, width: 16, height: 16))
            .composited(over: CIImage(color: .black).cropped(to: extent))
        guard let image = compose(image: source, mask: mask, box: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return false }
        // Check compositing through a known RGBA context, independent of the
        // renderer's native CGImage pixel channel order/color profile.
        var rgba = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let rendered = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: extent); return true
        }
        let center = (16 * 32 + 16) * 4, corner = (2 * 32 + 2) * 4
        return rendered && rgba[center] > 240 && rgba[center + 1] < 10 && rgba[center + 2] < 10 &&
            abs(Int(rgba[corner]) - Int(rgba[corner + 1])) < 3 && rgba[corner] > 110 && rgba[corner] < 210
    }
}
