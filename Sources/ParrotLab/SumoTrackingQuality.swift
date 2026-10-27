import Foundation
import CoreVideo

struct SumoTrackingQuality {
    let turnFactor: Double
    let sharpness: Double?
    let isBlurred: Bool
    static let unknown = Self(turnFactor: 1, sharpness: nil, isBlurred: false)
}

/// A small luminance-only edge measurement, evaluated on the tracking worker.
/// No frame is retained. Relative edge width avoids treating dark frames as blur;
/// a robust noise estimate prevents sensor grain from looking like recovered detail.
struct SumoBlurMonitor {
    private var baseline: Double?
    private var lastAt: TimeInterval?
    private var factor: Double = 1
    private var lastQuality = SumoTrackingQuality.unknown

    mutating func reset() { self = Self() }

    mutating func update(pixelBuffer: CVPixelBuffer, box: CGRect?, at now: TimeInterval) -> SumoTrackingQuality {
        guard now.isFinite else { reset(); return .unknown }
        let dt = lastAt.map { now - $0 } ?? 0
        guard dt >= 0, dt <= 0.5 else { reset(); lastAt = now; return .unknown }
        lastAt = now
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return lastQuality }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(pixelBuffer) else { return lastQuality }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width >= 32, height >= 32 else { return lastQuality }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = address.assumingMemoryBound(to: UInt8.self)
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let region: CGRect
        if let box, [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
           box.width > 0.04, box.height > 0.04, bounds.contains(box) {
            region = box.insetBy(dx: -0.06, dy: -0.06).intersection(bounds)
        } else { region = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8) }
        let x0 = Int(region.minX * Double(width))
        let y0 = Int((1 - region.maxY) * Double(height))
        let regionWidth = max(16, min(width - x0, Int(region.width * Double(width))))
        let regionHeight = max(16, min(height - y0, Int(region.height * Double(height))))
        let columns = min(160, regionWidth / 2), rows = min(112, regionHeight / 2)
        guard columns >= 10, rows >= 10 else { return lastQuality }
        var luma = [Double](repeating: 0, count: columns * rows)
        for y in 0..<rows {
            let sourceY = min(height - 2, y0 + y * regionHeight / rows)
            for x in 0..<columns {
                let sourceX = min(width - 2, x0 + x * regionWidth / columns)
                var total = 0.0
                for dy in 0...1 {
                    for dx in 0...1 {
                        let p = (sourceY + dy) * stride + (sourceX + dx) * 4
                        total += (Double(pixels[p + 2]) * 0.299 + Double(pixels[p + 1]) * 0.587 + Double(pixels[p]) * 0.114)
                    }
                }
                luma[y * columns + x] = total / 4
            }
        }
        var deviations: [Double] = []
        deviations.reserveCapacity((columns - 6) * (rows - 6))
        for y in 3..<(rows - 3) {
            for x in 3..<(columns - 3) {
                let p = y * columns + x
                deviations.append(abs(4 * luma[p] - luma[p - 1] - luma[p + 1] - luma[p - columns] - luma[p + columns]))
            }
        }
        deviations.sort()
        let noise = deviations[deviations.count / 2] / (0.6745 * sqrt(20))
        let threshold = max(7, noise * 4)
        let noiseEnergy = 2 * noise * noise
        var fine = 0.0, coarse = 0.0, edges = 0
        for y in 3..<(rows - 3) {
            for x in 3..<(columns - 3) {
                let p = y * columns + x
                let dx = luma[p + 3] - luma[p - 3], dy = luma[p + 3 * columns] - luma[p - 3 * columns]
                let horizontal = abs(dx) >= abs(dy)
                let broad = horizontal ? dx : dy
                guard abs(broad) >= threshold else { continue }
                let narrow = horizontal ? luma[p + 1] - luma[p - 1] : luma[p + columns] - luma[p - columns]
                fine += max(0, narrow * narrow - noiseEnergy)
                coarse += max(0, broad * broad - noiseEnergy)
                edges += 1
            }
        }
        // A previously detailed view becoming textureless may be severe blur.
        // It cannot be used as evidence for accelerating again.
        guard edges >= 24, coarse > 1 else {
            if baseline != nil {
                factor = min(factor, 0.2)
                lastQuality = .init(turnFactor: factor, sharpness: nil, isBlurred: true)
            }
            return lastQuality
        }
        let score = min(1, max(0, fine / coarse))
        let reference = max(score, (baseline ?? score) * exp(-dt / 180))
        baseline = reference
        let ratio = score / max(0.0001, reference)
        let requested = 0.2 + 0.8 * min(1, max(0, (ratio - 0.40) / 0.50))
        factor = min(requested, factor + dt * 0.65)
        lastQuality = .init(turnFactor: factor, sharpness: score, isBlurred: factor < 0.75)
        return lastQuality
    }

    static func selfTest() -> Bool {
        let width = 192, height = 144
        func fixture(blur: Bool, noise: Bool = false, flat: Bool = false) -> CVPixelBuffer? {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                  let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let pixels = address.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
            func crisp(_ x: Int, _ y: Int) -> Double { ((x / 24 + y / 24) % 2 == 0) ? 35 : 210 }
            for y in 0..<height {
                for x in 0..<width {
                    var value = flat ? 90 : crisp(x, y)
                    if blur {
                        var total = 0.0, weights = 0.0
                        for dy in -7...7 {
                            for dx in -7...7 {
                                let weight = exp(-Double(dx * dx + dy * dy) / 18)
                                total += crisp(max(0, min(width - 1, x + dx)), max(0, min(height - 1, y + dy))) * weight
                                weights += weight
                            }
                        }
                        value = total / weights
                    }
                    if noise { value += Double((x * 31 + y * 47) % 31 - 15) }
                    let byte = UInt8(max(0, min(255, value.rounded())))
                    let p = y * stride + x * 4
                    pixels[p] = byte; pixels[p + 1] = byte; pixels[p + 2] = byte; pixels[p + 3] = 255
                }
            }
            return buffer
        }
        guard let crisp = fixture(blur: false), let blur = fixture(blur: true), let noisyBlur = fixture(blur: true, noise: true),
              let flat = fixture(blur: false, flat: true) else { return false }
        var monitor = Self()
        let clear = monitor.update(pixelBuffer: crisp, box: nil, at: 10)
        let blurred = monitor.update(pixelBuffer: blur, box: nil, at: 10.08)
        let grainy = monitor.update(pixelBuffer: noisyBlur, box: nil, at: 10.16)
        guard clear.sharpness != nil, !clear.isBlurred, blurred.isBlurred, blurred.turnFactor < 0.65,
              grainy.turnFactor < 0.75 else { return false }
        let firstRecovery = monitor.update(pixelBuffer: crisp, box: nil, at: 10.24)
        guard firstRecovery.turnFactor > grainy.turnFactor, firstRecovery.turnFactor < 0.8 else { return false }
        var recovered = firstRecovery
        for step in 4...24 { recovered = monitor.update(pixelBuffer: crisp, box: nil, at: 10 + Double(step) * 0.08) }
        guard !recovered.isBlurred, recovered.turnFactor > 0.95,
              monitor.update(pixelBuffer: flat, box: nil, at: 11.98).isBlurred,
              monitor.update(pixelBuffer: crisp, box: nil, at: 9).sharpness == nil,
              monitor.update(pixelBuffer: crisp, box: nil, at: .nan).sharpness == nil else { return false }
        monitor.reset()
        return monitor.update(pixelBuffer: crisp, box: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1), at: 50).turnFactor == 1
    }
}
