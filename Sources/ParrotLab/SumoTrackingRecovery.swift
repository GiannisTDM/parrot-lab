import Foundation

/// Reacquisition is evidence across fresh images, never a prediction. The
/// caller keeps the original target-memory deadline until this gate confirms.
struct SumoRecoveryConfirmation {
    private var firstAt: TimeInterval?
    private var lastAt: TimeInterval?
    private var lastBox: CGRect?
    private var signature: SumoAppearanceSignature?
    private(set) var matches = 0
    var referenceBox: CGRect? { lastBox }

    static func isFresh(sampledAt: TimeInterval, at time: TimeInterval) -> Bool {
        let age = time - sampledAt
        return sampledAt.isFinite && time.isFinite && age.isFinite && (0...0.4).contains(age)
    }

    mutating func reset() { self = Self() }

    mutating func observe(box: CGRect, signature: SumoAppearanceSignature?, at time: TimeInterval) -> Bool {
        guard time.isFinite, SumoTargetSearch.valid(box) else { reset(); return false }
        if let lastAt, let lastBox {
            let gap = time - lastAt
            let widthRatio = box.width / lastBox.width, heightRatio = box.height / lastBox.height
            let appearanceConsistent: Bool
            if let previous = self.signature, let signature {
                appearanceConsistent = (previous.distance(to: signature) ?? .infinity) <= 0.45
            } else { appearanceConsistent = true }
            if !(0.025...0.25).contains(gap) || !(0.7...1.45).contains(widthRatio) ||
                !(0.7...1.45).contains(heightRatio) || !appearanceConsistent ||
                hypot(box.midX - lastBox.midX, box.midY - lastBox.midY) > max(0.09, lastBox.width * 0.45) {
                reset()
            }
        }
        if firstAt == nil { firstAt = time }
        matches += 1; lastAt = time; lastBox = box; self.signature = signature
        return matches >= 3 && time - (firstAt ?? time) >= 0.12
    }

    static func selfTest() -> Bool {
        let box = CGRect(x: 0.3, y: 0.2, width: 0.2, height: 0.4)
        var confirmation = Self()
        // No descriptor/gallery is available: three separate consistent
        // optical observations are still required before resuming.
        guard !confirmation.observe(box: box, signature: nil, at: 1),
              !confirmation.observe(box: box.offsetBy(dx: 0.01, dy: 0), signature: nil, at: 1.067),
              confirmation.observe(box: box.offsetBy(dx: 0.02, dy: 0), signature: nil, at: 1.134) else { return false }
        confirmation.reset()
        guard !confirmation.observe(box: box, signature: nil, at: 2),
              !confirmation.observe(box: box, signature: nil, at: 2.3), confirmation.matches == 1,
              !confirmation.observe(box: box.offsetBy(dx: 0.3, dy: 0), signature: nil, at: 2.367),
              confirmation.matches == 1,
              !confirmation.observe(box: box, signature: nil, at: .nan), confirmation.matches == 0 else { return false }
        guard let a = SumoAppearanceSignature(elements: [Float](repeating: 1, count: 32)),
              let b = SumoAppearanceSignature(elements: [Float](repeating: -1, count: 32)) else { return false }
        guard !confirmation.observe(box: box, signature: a, at: 3),
              !confirmation.observe(box: box, signature: b, at: 3.067), confirmation.matches == 1 else { return false }
        confirmation.reset()
        // Repeated timestamps cannot manufacture multiple fresh observations.
        guard !confirmation.observe(box: box, signature: a, at: 4),
              !confirmation.observe(box: box, signature: a, at: 4), confirmation.matches == 1 else { return false }
        confirmation.reset()
        guard confirmation.matches == 0,
              isFresh(sampledAt: 10, at: 10.399),
              !isFresh(sampledAt: 10, at: 10.401),
              !isFresh(sampledAt: 10, at: 9.9),
              !isFresh(sampledAt: .nan, at: 10) else { return false }
        return true
    }
}
