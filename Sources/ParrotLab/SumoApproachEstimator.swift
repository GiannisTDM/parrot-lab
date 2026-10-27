import Foundation

/// A short, reverse-only size lead. Every result belongs to a visible current
/// target; this history is never used to move while tracking is missing.
struct SumoApproachEstimator {
    private struct Sample {
        let box: CGRect
        let height: CGFloat
        let at: TimeInterval
    }
    private var samples: [Sample] = []
    private var last: Sample?
    private var referenceScale: CGFloat?
    private var trustedFullSamples = 0
    private var trustedAspect: CGFloat = 1
    private var lastFull: Sample?

    mutating func reset() { self = Self() }

    mutating func update(box: CGRect, calibratedHeight: CGFloat, referenceScale scale: CGFloat,
                         at now: TimeInterval) -> CGFloat? {
        guard now.isFinite, [box.minX, box.minY, box.width, box.height, calibratedHeight, scale].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0, box.minX >= 0, box.minY >= 0, box.maxX <= 1, box.maxY <= 1,
              calibratedHeight > 0, (0.125...8).contains(scale) else { reset(); return nil }
        let full = box.minX > 0.012 && box.minY > 0.012 && box.maxX < 0.988 && box.maxY < 0.988
        let sample = Sample(box: box, height: calibratedHeight, at: now)
        func similarGeometry(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            abs(lhs.midX - rhs.midX) <= max(0.12, rhs.width * 0.55) &&
                abs(lhs.midY - rhs.midY) <= max(0.12, rhs.height * 0.45) &&
                (0.72...1.4).contains(lhs.width / rhs.width) &&
                (0.72...1.4).contains(lhs.height / rhs.height)
        }
        let changedRepresentation = referenceScale.map { abs(log(scale / $0)) > 0.000_01 } ?? false
        if let previous = last {
            let dt = now - previous.at
            if changedRepresentation || dt <= 0 || dt > 0.25 || !similarGeometry(box, previous.box) {
                reset()
            }
        }
        referenceScale = scale
        let previous = last
        last = sample
        let aspect = box.width / box.height
        if full {
            // A shape discontinuity cannot prove approach. Start collecting a
            // new history; the caller's pose filter retains distance authority.
            if trustedFullSamples > 0, abs(log(aspect / trustedAspect)) > log(1.18) {
                samples = []; trustedFullSamples = 0; lastFull = nil
            }
            if trustedFullSamples == 0 { trustedAspect = aspect }
            trustedFullSamples = min(3, trustedFullSamples + 1)
            trustedAspect += (aspect - trustedAspect) * 0.04
            lastFull = sample
        } else {
            // A crop is only a lower bound on size. It is usable for retreat
            // after an uninterrupted, geometrically compatible full view.
            guard trustedFullSamples >= 3, let lastFull,
                  similarGeometry(box, lastFull.box),
                  abs(log(aspect / trustedAspect)) <= log(1.25),
                  calibratedHeight >= lastFull.height * 0.9 else { reset(); return nil }
        }
        samples.removeAll { now - $0.at > 0.35 }
        samples.append(sample)
        if samples.count > 6 { samples.removeFirst(samples.count - 6) }
        guard trustedFullSamples >= 3, let first = samples.first, samples.count >= 3,
              now - first.at >= 0.10 else { return nil }
        let hGrowth = log(box.height / first.box.height)
        let wGrowth = log(box.width / first.box.width)
        // Do not turn a stand-up, crouch or changing tail crop into a fast
        // distance correction. Small aspect jitter keeps the old filtered path.
        let largestChange = max(abs(hGrowth), abs(wGrowth))
        let anisotropic = largestChange > log(1.04) && abs(hGrowth - wGrowth) > log(1.045) &&
            min(abs(hGrowth), abs(wGrowth)) < largestChange * 0.45
        if anisotropic { return nil }
        let monotonic = zip(samples, samples.dropFirst()).allSatisfy { earlier, later in
            later.box.height >= earlier.box.height * 0.99 && later.box.width >= earlier.box.width * 0.99
        }
        let increasingPairs = zip(samples, samples.dropFirst()).filter { earlier, later in
            later.box.height > earlier.box.height * 1.003 && later.box.width > earlier.box.width * 1.003
        }.count
        var lead: CGFloat = 1
        if monotonic, increasingPairs >= 2, hGrowth > log(1.025), wGrowth > log(1.025),
           abs(hGrowth - wGrowth) <= log(1.08),
           min(hGrowth, wGrowth) >= max(hGrowth, wGrowth) * 0.6 {
            let rate = min(hGrowth, wGrowth) / (now - first.at)
            // A fresh clipped box must still show growth before borrowing the
            // preceding full observations' trend. Static crops never coast.
            let growingNow = previous.map {
                box.width > $0.box.width * 1.003 || box.height > $0.box.height * 1.003
            } ?? false
            if full || growingNow { lead += min(0.20, max(0, exp(rate * 0.18) - 1)) }
        }
        // Sizes beyond the image are permitted only by this bounded observed
        // growth lead; they allow retreat when the held size is already ~98%.
        return min(1.2 / scale, calibratedHeight * lead)
    }

    static func selfTest() -> Bool {
        func box(_ height: CGFloat, width: CGFloat? = nil, x: CGFloat? = nil, y: CGFloat = 0.2) -> CGRect {
            let width = width ?? height / 2
            return .init(x: x ?? 0.5 - width / 2, y: y, width: width, height: height)
        }
        var estimator = Self()
        guard estimator.update(box: box(0.4), calibratedHeight: 0.4, referenceScale: 1, at: 10) == nil,
              estimator.update(box: box(0.4), calibratedHeight: 0.4, referenceScale: 1, at: 10.06) == nil,
              estimator.update(box: box(0.4), calibratedHeight: 0.4, referenceScale: 1, at: 10.12) == 0.4 else { return false }
        _ = estimator.update(box: box(0.41), calibratedHeight: 0.41, referenceScale: 1, at: 10.18)
        let approaching = estimator.update(box: box(0.42), calibratedHeight: 0.42, referenceScale: 1, at: 10.24)
        guard let approaching, approaching > 0.43, approaching <= 0.42 * 1.2 else { return false }
        let edge = box(0.44, x: 0.005)
        // Moving to the opposite edge cannot reuse a center-target history.
        guard estimator.update(box: edge, calibratedHeight: 0.44, referenceScale: 1, at: 10.30) == nil else { return false }
        estimator.reset()
        for step in 0...3 {
            _ = estimator.update(box: box(0.4), calibratedHeight: 0.4,
                                 referenceScale: 1, at: 15 + Double(step) * 0.06)
        }
        // One isotropic box-size jump is not a confirmed approach trend.
        guard estimator.update(box: box(0.412), calibratedHeight: 0.412,
                               referenceScale: 1, at: 15.24) == 0.412 else { return false }
        estimator.reset()
        for step in 0...3 {
            _ = estimator.update(box: box(0.4, x: 0.03), calibratedHeight: 0.4,
                                 referenceScale: 1, at: 20 + Double(step) * 0.06)
        }
        guard let cropped = estimator.update(box: box(0.44, x: 0.005), calibratedHeight: 0.44,
                                              referenceScale: 1, at: 20.24), cropped >= 0.44 else { return false }
        estimator.reset()
        for step in 0...4 {
            guard estimator.update(box: box(0.6, x: 0), calibratedHeight: 0.6,
                                   referenceScale: 1, at: 30 + Double(step) * 0.06) == nil else { return false }
        }
        estimator.reset()
        for step in 0...2 {
            _ = estimator.update(box: box(0.4), calibratedHeight: 0.4, referenceScale: 1, at: 40 + Double(step) * 0.06)
        }
        guard estimator.update(box: box(0.44, width: 0.2), calibratedHeight: 0.44,
                               referenceScale: 1, at: 40.18) == nil,
              estimator.update(box: box(0.22, width: 0.1), calibratedHeight: 0.44,
                               referenceScale: 0.5, at: 40.24) == nil else { return false }
        // No trend survives pause/time reversal/long gaps or an invalid box.
        estimator.reset()
        for step in 0...2 {
            _ = estimator.update(box: box(0.4), calibratedHeight: 0.4, referenceScale: 1, at: 50 + Double(step) * 0.06)
        }
        guard estimator.update(box: box(0.44), calibratedHeight: 0.44, referenceScale: 1, at: 50.5) == nil,
              estimator.update(box: box(0.46), calibratedHeight: 0.46, referenceScale: 1, at: 50.4) == nil,
              estimator.update(box: box(.nan), calibratedHeight: 0.4, referenceScale: 1, at: 50.6) == nil else { return false }
        estimator.reset()
        for step in 0...3 {
            let height: CGFloat = step.isMultiple(of: 2) ? 0.4 : 0.404
            let value = estimator.update(box: box(height), calibratedHeight: height,
                                         referenceScale: 1, at: 60 + Double(step) * 0.06)
            if let value, value > 0.41 { return false }
        }
        estimator.reset()
        var nearFrame: CGFloat?
        for step in 0...3 {
            let h = 0.84 + CGFloat(step) * 0.045
            nearFrame = estimator.update(box: box(h, y: 0.015), calibratedHeight: h,
                                         referenceScale: 1, at: 70 + Double(step) * 0.06)
        }
        guard let nearFrame, nearFrame > 1.02, nearFrame <= 1.2 else { return false }
        return true
    }
}
