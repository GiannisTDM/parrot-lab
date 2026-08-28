import CoreGraphics
import Foundation
import Metal
import simd

/// The one camera/Dragon configuration for which the supplied calibration is
/// valid. Keeping this as a named profile prevents the numbers from silently
/// leaking into stock, 4.4.2, `-R off`, or differently positioned streams.
enum Bebop900pCameraCalibrationProfile: String, Equatable {
    case firmware471GPUFixedRaised

    var statusLabel: String {
        switch self {
        case .firmware471GPUFixedRaised:
            return "4.7.1 · 900P GPU · FIXED RAISED"
        }
    }
}

enum VideoQuaternionAction: String, Equatable {
    case unconfirmed
    case active
    case passive
}

enum VideoQuaternionHandedness: String, Equatable {
    case unconfirmed
    case rightHanded
    case leftHanded
}

enum VideoQuaternionComposition: String, Equatable {
    case unconfirmed
    case frameViewOnly
    case droneThenFrameView
    case frameViewThenDrone
}

struct VideoQuaternionConvention: Equatable {
    var action = VideoQuaternionAction.unconfirmed
    var handedness = VideoQuaternionHandedness.unconfirmed
    var composition = VideoQuaternionComposition.unconfirmed

    var isConfirmed: Bool {
        action != .unconfirmed &&
            handedness != .unconfirmed &&
            composition != .unconfirmed
    }
}

enum VideoFrameTimestampAnchor: String, Equatable {
    case unconfirmed
    case frameEOF
    case firstRowStart
    case frameMidpoint
    case exposureMidpoint
}

struct Bebop900pCalibrationSample: Equatable {
    let cameraRay: SIMD3<Float>
    let orientedFisheyePixel: SIMD2<Float>
    let nativeSensorPixel: SIMD2<Float>
    let sensorRowStartSeconds: Float
    let sensorRowPhase: Float
    let isValid: Bool
}

struct Bebop900pCalibrationLookup {
    let width: Int
    let height: Int
    let cameraRays: [SIMD4<Float>]
    let rowTiming: [SIMD2<Float>]
    let validity: [UInt8]
    let validFraction: Double
    let minimumValidRowStartMilliseconds: Double
    let maximumValidRowStartMilliseconds: Double
    let zeroMotionSafe16By9Crop: CGRect
}

/// Grounded calibration supplied from the 2026-08-27 4.7.1 capture set.
/// Coordinates passed to `sample` are in the visible 1600x900 image before
/// any Parrot Lab scaling.
enum Bebop900pCameraCalibration {
    static let profile = Bebop900pCameraCalibrationProfile.firmware471GPUFixedRaised
    static let width = 1_600
    static let height = 900

    static let fx = 992.353924683669
    static let fy = 991.225523926404
    static let cx = 799.5
    static let cy = 449.5

    static let orientedFisheyeCenter = SIMD2<Double>(1_651, 2_054)
    static let fisheyeRadius = 1_920.0
    static let sensorXRange = 2_096.0...3_439.0
    static let sensorYRange = 610.0...2_721.0
    static let activeSensorRows = 2_112.0
    static let linePeriodSeconds = 14.7571e-6
    static let activeReadoutSeconds = activeSensorRows * linePeriodSeconds
    static let blankingSeconds = 2.198e-3
    static let completeFrameSeconds = 33.365e-3

    private static let rotation: [[Double]] = [
        [0.999980182650, 0.003157123588, 0.005446730934],
        [0.000708186495, 0.803265961758, -0.595620091293],
        [-0.006255619802, 0.595612144983, 0.803247807323]
    ]
    private static let radialCoefficients = SIMD4<Double>(
        1.146386991675,
        -0.116403884578,
        0.046260013567,
        -0.076243120663
    )

    static func sample(x: Double, y: Double) -> Bebop900pCalibrationSample {
        let openCVRay = normalized(SIMD3<Double>((x - cx) / fx, (y - cy) / fy, 1))
        // Standardized metadata uses camera FRD (forward, right, down), while
        // the calibrated fisheye projection was solved in OpenCV
        // (right, down, forward) coordinates.
        let cameraFRDRay = SIMD3<Double>(openCVRay.z, openCVRay.x, openCVRay.y)
        let oriented = SIMD3<Double>(
            rotation[0][0] * openCVRay.x + rotation[0][1] * openCVRay.y + rotation[0][2] * openCVRay.z,
            rotation[1][0] * openCVRay.x + rotation[1][1] * openCVRay.y + rotation[1][2] * openCVRay.z,
            rotation[2][0] * openCVRay.x + rotation[2][1] * openCVRay.y + rotation[2][2] * openCVRay.z
        )
        let theta = acos(max(-1, min(1, oriented.z)))
        let t = theta / (.pi / 2)
        let t2 = t * t
        let rho = fisheyeRadius * (
            radialCoefficients.x * t +
                radialCoefficients.y * t * t2 +
                radialCoefficients.z * t * t2 * t2 +
                radialCoefficients.w * t * t2 * t2 * t2
        )
        let radialLength = hypot(oriented.x, oriented.y)
        let fisheye: SIMD2<Double>
        if radialLength > 1e-12 {
            fisheye = orientedFisheyeCenter + SIMD2<Double>(
                rho * oriented.x / radialLength,
                rho * oriented.y / radialLength
            )
        } else {
            fisheye = orientedFisheyeCenter
        }

        // EXIF orientation 8 / oriented-JPEG coordinates back to native sensor.
        let sensor = SIMD2<Double>(4_351 - fisheye.y, fisheye.x - 16)
        let rowIndex = sensor.y - sensorYRange.lowerBound
        let rowStart = rowIndex * linePeriodSeconds
        let rowPhase = rowIndex / activeSensorRows
        let circleOffset = fisheye - orientedFisheyeCenter
        let isInsideFisheye = hypot(circleOffset.x, circleOffset.y) <= fisheyeRadius
        let valid = isInsideFisheye &&
            sensorXRange.contains(sensor.x) && sensorYRange.contains(sensor.y)

        return Bebop900pCalibrationSample(
            cameraRay: SIMD3<Float>(
                Float(cameraFRDRay.x),
                Float(cameraFRDRay.y),
                Float(cameraFRDRay.z)
            ),
            orientedFisheyePixel: SIMD2<Float>(Float(fisheye.x), Float(fisheye.y)),
            nativeSensorPixel: SIMD2<Float>(Float(sensor.x), Float(sensor.y)),
            sensorRowStartSeconds: Float(rowStart),
            sensorRowPhase: Float(rowPhase),
            isValid: valid
        )
    }

    static func makeLookup(width lookupWidth: Int = width, height lookupHeight: Int = height) -> Bebop900pCalibrationLookup {
        precondition(lookupWidth > 0 && lookupHeight > 0)
        let count = lookupWidth * lookupHeight
        var rays = [SIMD4<Float>]()
        var timing = [SIMD2<Float>]()
        var validity = [UInt8]()
        rays.reserveCapacity(count)
        timing.reserveCapacity(count)
        validity.reserveCapacity(count)
        var validCount = 0
        var minimumRowStart = Double.greatestFiniteMagnitude
        var maximumRowStart = -Double.greatestFiniteMagnitude

        for lookupY in 0..<lookupHeight {
            let sourceY = lookupHeight == 1
                ? cy
                : Double(lookupY) * Double(height - 1) / Double(lookupHeight - 1)
            for lookupX in 0..<lookupWidth {
                let sourceX = lookupWidth == 1
                    ? cx
                    : Double(lookupX) * Double(width - 1) / Double(lookupWidth - 1)
                let value = sample(x: sourceX, y: sourceY)
                let mask: Float = value.isValid ? 1 : 0
                rays.append(SIMD4<Float>(
                    value.cameraRay.x,
                    value.cameraRay.y,
                    value.cameraRay.z,
                    mask
                ))
                timing.append(SIMD2<Float>(value.sensorRowStartSeconds, value.sensorRowPhase))
                validity.append(value.isValid ? 255 : 0)
                if value.isValid {
                    validCount += 1
                    let rowStart = Double(value.sensorRowStartSeconds)
                    minimumRowStart = min(minimumRowStart, rowStart)
                    maximumRowStart = max(maximumRowStart, rowStart)
                }
            }
        }

        if validCount == 0 {
            minimumRowStart = 0
            maximumRowStart = 0
        }
        return Bebop900pCalibrationLookup(
            width: lookupWidth,
            height: lookupHeight,
            cameraRays: rays,
            rowTiming: timing,
            validity: validity,
            validFraction: Double(validCount) / Double(count),
            minimumValidRowStartMilliseconds: minimumRowStart * 1_000,
            maximumValidRowStartMilliseconds: maximumRowStart * 1_000,
            zeroMotionSafe16By9Crop: largestCenteredValid16By9Crop(
                validity: validity,
                width: lookupWidth,
                height: lookupHeight
            )
        )
    }

    static func selfTest() -> Bool {
        let center = sample(x: cx, y: cy)
        let left = sample(x: 0, y: cy)
        let right = sample(x: Double(width - 1), y: cy)
        let compactLookup = makeLookup(width: 17, height: 11)
        let horizontalFOV = 2 * atan(Double(width) / (2 * fx)) * 180 / Double.pi
        let verticalFOV = 2 * atan(Double(height) / (2 * fy)) * 180 / Double.pi
        return abs(horizontalFOV - 77.749) < 0.01 &&
            abs(verticalFOV - 48.835) < 0.01 &&
            abs(center.cameraRay.x - 1) < 0.001 &&
            abs(center.cameraRay.y) < 0.01 &&
            abs(center.cameraRay.z) < 0.01 &&
            right.cameraRay.y > 0 &&
            abs(activeReadoutSeconds * 1_000 - 31.167) < 0.002 &&
            abs(Double(center.sensorRowStartSeconds) * 1_000 - 15.245) < 0.01 &&
            Double(left.sensorRowStartSeconds) * 1_000 < 1 &&
            Double(right.sensorRowStartSeconds) * 1_000 > 29 &&
            center.isValid && left.isValid && right.isValid &&
            compactLookup.cameraRays.count == 187 &&
            compactLookup.rowTiming.count == 187 &&
            compactLookup.validity.count == 187 &&
            compactLookup.validFraction > 0.75 && compactLookup.validFraction < 0.85 &&
            compactLookup.zeroMotionSafe16By9Crop.width > 0 &&
            compactLookup.zeroMotionSafe16By9Crop.height > 0
    }

    private static func normalized(_ value: SIMD3<Double>) -> SIMD3<Double> {
        let magnitude = sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
        return value / magnitude
    }

    private static func largestCenteredValid16By9Crop(
        validity: [UInt8],
        width: Int,
        height: Int
    ) -> CGRect {
        guard validity.count == width * height else { return .zero }
        let integralWidth = width + 1
        var invalidIntegral = [Int64](repeating: 0, count: integralWidth * (height + 1))
        for y in 0..<height {
            var rowInvalid: Int64 = 0
            for x in 0..<width {
                if validity[y * width + x] == 0 { rowInvalid += 1 }
                invalidIntegral[(y + 1) * integralWidth + x + 1] =
                    invalidIntegral[y * integralWidth + x + 1] + rowInvalid
            }
        }
        func invalidCount(x: Int, y: Int, width: Int, height: Int) -> Int64 {
            let right = x + width
            let bottom = y + height
            return invalidIntegral[bottom * integralWidth + right] -
                invalidIntegral[y * integralWidth + right] -
                invalidIntegral[bottom * integralWidth + x] +
                invalidIntegral[y * integralWidth + x]
        }

        for candidateHeight in stride(from: height, through: 1, by: -1) {
            let candidateWidth = Int((Double(candidateHeight) * 16 / 9).rounded(.down))
            guard candidateWidth > 0, candidateWidth <= width else { continue }
            let x = (width - candidateWidth) / 2
            let y = (height - candidateHeight) / 2
            if invalidCount(x: x, y: y, width: candidateWidth, height: candidateHeight) == 0 {
                return CGRect(x: x, y: y, width: candidateWidth, height: candidateHeight)
            }
        }
        return .zero
    }
}

/// GPU-resident, immutable calibration maps. They are allocated lazily only
/// when rolling-shutter correction is explicitly requested for the matching
/// source profile.
final class Bebop900pCalibrationTextureSet {
    let rayTexture: any MTLTexture
    let rowTimingTexture: any MTLTexture
    let validityTexture: any MTLTexture
    let validFraction: Double
    let minimumRowStartMilliseconds: Double
    let maximumRowStartMilliseconds: Double
    let zeroMotionSafe16By9Crop: CGRect

    init?(device: any MTLDevice) {
        let lookup = Bebop900pCameraCalibration.makeLookup()
        guard let rayTexture = Self.makeTexture(
            device: device,
            pixelFormat: .rgba32Float,
            width: lookup.width,
            height: lookup.height
        ), let rowTimingTexture = Self.makeTexture(
            device: device,
            pixelFormat: .rg32Float,
            width: lookup.width,
            height: lookup.height
        ), let validityTexture = Self.makeTexture(
            device: device,
            pixelFormat: .r8Unorm,
            width: lookup.width,
            height: lookup.height
        ) else { return nil }

        let region = MTLRegionMake2D(0, 0, lookup.width, lookup.height)
        lookup.cameraRays.withUnsafeBytes { bytes in
            rayTexture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: lookup.width * MemoryLayout<SIMD4<Float>>.stride
            )
        }
        lookup.rowTiming.withUnsafeBytes { bytes in
            rowTimingTexture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: lookup.width * MemoryLayout<SIMD2<Float>>.stride
            )
        }
        lookup.validity.withUnsafeBytes { bytes in
            validityTexture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: lookup.width
            )
        }
        self.rayTexture = rayTexture
        self.rowTimingTexture = rowTimingTexture
        self.validityTexture = validityTexture
        validFraction = lookup.validFraction
        minimumRowStartMilliseconds = lookup.minimumValidRowStartMilliseconds
        maximumRowStartMilliseconds = lookup.maximumValidRowStartMilliseconds
        zeroMotionSafe16By9Crop = lookup.zeroMotionSafe16By9Crop
    }

    static func selfTest() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
              let textures = Bebop900pCalibrationTextureSet(device: device) else { return false }
        return textures.rayTexture.width == Bebop900pCameraCalibration.width &&
            textures.rayTexture.height == Bebop900pCameraCalibration.height &&
            textures.rowTimingTexture.pixelFormat == .rg32Float &&
            textures.validityTexture.pixelFormat == .r8Unorm &&
            textures.validFraction > 0.75 && textures.validFraction < 0.85 &&
            textures.minimumRowStartMilliseconds >= 0 &&
            textures.maximumRowStartMilliseconds <= 31.2 &&
            textures.zeroMotionSafe16By9Crop.width > 0 &&
            textures.zeroMotionSafe16By9Crop.height > 0
    }

    private static func makeTexture(
        device: any MTLDevice,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int
    ) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        return device.makeTexture(descriptor: descriptor)
    }
}
