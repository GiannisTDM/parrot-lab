import Foundation
import CoreVideo
import Vision

/// Small, normalized copies of Vision's image embeddings. No camera frames are
/// retained by the appearance memory, and embeddings never cross sessions.
struct SumoAppearanceSignature {
    private let elements: [Float]
    private var foregroundElements: [Float]?
    var hasForeground: Bool { foregroundElements != nil }

    init?(elements: [Float]) {
        guard (16...4096).contains(elements.count), elements.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(elements.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0.000001 else { return nil }
        self.elements = elements.map { Float(Double($0) / norm) }
    }

    init?(featurePrint: VNFeaturePrintObservation) {
        guard featurePrint.elementType == .float, (16...4096).contains(featurePrint.elementCount),
              featurePrint.data.count == featurePrint.elementCount * MemoryLayout<Float>.size else { return nil }
        let values = featurePrint.data.withUnsafeBytes { bytes in
            (0..<featurePrint.elementCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        self.init(elements: values)
    }

    func distance(to other: Self) -> Double? {
        // A masked query must never be compared to an unmasked anchor. Keep
        // the raw descriptor as a fallback when either mask was unavailable.
        let lhs = foregroundElements != nil && other.foregroundElements != nil ? foregroundElements! : elements
        let rhs = foregroundElements != nil && other.foregroundElements != nil ? other.foregroundElements! : other.elements
        guard lhs.count == rhs.count else { return nil }
        let squared = zip(lhs, rhs).reduce(0.0) { sum, pair in
            let difference = Double(pair.0) - Double(pair.1)
            return sum + difference * difference
        }
        let value = sqrt(max(0, squared))
        return value.isFinite ? value : nil
    }

    func addingForeground(_ signature: Self?) -> Self {
        var copy = self
        copy.foregroundElements = signature?.elements
        return copy
    }
}

/// Retain the first trustworthy view plus three recent semantic confirmations.
/// A tracker repeating its own background mistake cannot teach the gallery.
struct SumoAppearanceGallery {
    private(set) var signatures: [SumoAppearanceSignature] = []
    var isEmpty: Bool { signatures.isEmpty }
    var foregroundCount: Int { signatures.filter(\.hasForeground).count }

    mutating func reset(to signature: SumoAppearanceSignature?) {
        signatures = signature.map { [$0] } ?? []
    }

    func distance(to signature: SumoAppearanceSignature) -> Double? {
        guard let anchor = signatures.first?.distance(to: signature), anchor <= 1.1 else { return nil }
        let distances = signatures.compactMap { $0.distance(to: signature) }
        guard let nearest = distances.min() else { return nil }
        // Permit pose changes, but do not allow successive updates to wander
        // indefinitely away from the originally selected appearance.
        return nearest + max(0, anchor - 0.65) * 0.6
    }

    /// Continuation has an additional observed, geometry-consistent optical
    /// track. Permit larger pose/exposure changes than a wide recovery search.
    /// These are conservative heuristics, not calibrated identity probabilities.
    func isPlausibleTrack(_ signature: SumoAppearanceSignature) -> Bool {
        guard let anchor = signatures.first?.distance(to: signature), anchor.isFinite, anchor <= 1.35,
              let nearest = signatures.compactMap({ $0.distance(to: signature) }).min(),
              nearest.isFinite, nearest <= 1.1 else { return false }
        return true
    }

    mutating func learn(_ signature: SumoAppearanceSignature) {
        guard !isEmpty else { reset(to: signature); return }
        guard let distance = distance(to: signature), distance <= 0.65 else { return }
        if signatures.count == 4 { signatures.remove(at: 1) }
        signatures.append(signature)
    }
}

/// Velocity predicts where to SEARCH only. Callers may issue movement only for
/// a fresh, observed box that passes semantic/appearance checks.
struct SumoTargetSearch {
    struct Candidate {
        let box: CGRect
        let confidence: Float
        let appearanceDistance: Double?
    }
    private(set) var lastBox: CGRect?
    private(set) var lastSeen: TimeInterval?
    private var velocity = CGVector.zero

    static func hasAmbiguousRecovery(_ candidates: [Candidate]) -> Bool {
        let plausible = candidates.filter { candidate in
            guard let distance = candidate.appearanceDistance else { return false }
            return valid(candidate.box) && candidate.confidence.isFinite && candidate.confidence >= 0.55 &&
                distance.isFinite && (0...0.72).contains(distance)
        }
        return plausible.enumerated().contains { index, candidate in
            plausible.dropFirst(index + 1).contains { overlap(candidate.box, $0.box) < 0.3 }
        }
    }

    mutating func observe(_ box: CGRect, at time: TimeInterval, rebased: Bool = false) {
        guard Self.valid(box), time.isFinite else { return }
        if !rebased, let previous = lastBox, let lastSeen {
            let interval = time - lastSeen
            if (0.025...0.5).contains(interval) {
                let dx = min(1, max(-1, (box.midX - previous.midX) / interval))
                let dy = min(1, max(-1, (box.midY - previous.midY) / interval))
                velocity = .init(dx: velocity.dx * 0.6 + dx * 0.4, dy: velocity.dy * 0.6 + dy * 0.4)
            }
        } else { velocity = .zero }
        lastBox = box; lastSeen = time
    }

    func select(_ candidates: [Candidate], at time: TimeInterval, recovering: Bool,
                requiresAppearance: Bool) -> Int? {
        guard time.isFinite else { return nil }
        // Broad recovery must never quietly become geometry-only when a model
        // request failed. Callers can separately use their strict nearby policy.
        guard !recovering || requiresAppearance else { return nil }
        guard let reference = lastBox, let lastSeen else {
            return candidates.indices.filter { Self.valid(candidates[$0].box) &&
                candidates[$0].confidence.isFinite && candidates[$0].confidence >= 0.55 }
                .max { candidates[$0].box.width * candidates[$0].box.height < candidates[$1].box.width * candidates[$1].box.height }
        }
        let age = max(0, time - lastSeen)
        let predictionTime = recovering ? min(0.75, age) : 0
        let predictedX = min(1, max(0, reference.midX + velocity.dx * predictionTime))
        let predictedY = min(1, max(0, reference.midY + velocity.dy * predictionTime))
        let radius = recovering ? min(1.1, max(0.22, reference.width * 1.3) + age * 0.4) : max(0.18, reference.width * 0.8)
        var ranked: [(index: Int, score: Double)] = []
        for (index, candidate) in candidates.enumerated() {
            guard Self.valid(candidate.box), candidate.confidence.isFinite, candidate.confidence >= 0.55 else { continue }
            let box = candidate.box
            let widthRatio = box.width / reference.width, heightRatio = box.height / reference.height
            guard (0.3...3.3).contains(widthRatio), (0.35...2.8).contains(heightRatio) else { continue }
            let distance = hypot(box.midX - predictedX, box.midY - predictedY)
            guard distance <= radius else { continue }
            var appearance = 0.0
            if let value = candidate.appearanceDistance {
                guard value.isFinite, (0...0.72).contains(value) else { continue }
                appearance = value
            } else if requiresAppearance { continue }
            let scalePenalty = abs(log(Double(heightRatio))) * 0.12
            let score = appearance + Double(distance / max(0.2, radius)) * 0.24 + scalePenalty - Double(candidate.confidence) * 0.08
            ranked.append((index, score))
        }
        ranked.sort { $0.score < $1.score }
        guard let best = ranked.first else { return nil }
        for other in ranked.dropFirst() {
            if Self.overlap(candidates[best.index].box, candidates[other.index].box) > 0.6 { continue }
            // Similar cats are not an identity signal. Pause rather than swap.
            if other.score - best.score < 0.10 { return nil }
            break
        }
        return best.index
    }

    static func valid(_ box: CGRect) -> Bool {
        [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) &&
            box.width >= 0.025 && box.height >= 0.025 && box.width * box.height >= 0.001 &&
            box.minX >= 0 && box.minY >= 0 && box.maxX <= 1 && box.maxY <= 1
    }

    static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        return area / max(0.0001, lhs.width * lhs.height + rhs.width * rhs.height - area)
    }

    /// A manual selection can include bedding/background. A first semantic
    /// correction may tighten it only when there is an unambiguous overlap.
    static func initialSemanticCorrection(_ candidates: [CGRect], tracked: CGRect) -> Int? {
        guard valid(tracked) else { return nil }
        let ranked = candidates.indices.compactMap { index -> (Int, CGFloat)? in
            let box = candidates[index]
            guard valid(box), (0.25...2.8).contains(box.width / tracked.width),
                  (0.25...2.8).contains(box.height / tracked.height),
                  tracked.insetBy(dx: -0.04, dy: -0.04).contains(CGPoint(x: box.midX, y: box.midY)) else { return nil }
            let overlap = overlap(box, tracked)
            return overlap >= 0.18 ? (index, overlap) : nil
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first else { return nil }
        if ranked.count > 1, best.1 - ranked[1].1 < 0.15,
           overlap(candidates[best.0], candidates[ranked[1].0]) < 0.4 { return nil }
        return best.0
    }

    static func rebasedScale(_ scale: CGFloat, tracked: CGRect, semantic: CGRect) -> CGFloat? {
        guard scale.isFinite, valid(tracked), valid(semantic),
              (0.25...4).contains(semantic.height / tracked.height) else { return nil }
        let value = scale * semantic.height / tracked.height
        return value.isFinite && (0.125...8).contains(value) ? value : nil
    }

    static func selfTest() -> Bool {
        let unit = [Float](repeating: 1, count: 32)
        var other = unit; for index in 0..<16 { other[index] = -1 }
        guard let a = SumoAppearanceSignature(elements: unit), let b = SumoAppearanceSignature(elements: other),
              a.distance(to: a) == 0, (a.distance(to: b) ?? 0) > 1,
              SumoAppearanceSignature(elements: [.nan] + Array(unit.dropFirst())) == nil,
              SumoAppearanceSignature(elements: Array(repeating: 0, count: 32)) == nil else { return false }
        // Raw and masked representations never cross. A missing mask uses the
        // original crop, while two valid masks can ignore different bedding.
        guard a.addingForeground(b).distance(to: a) == 0,
              a.addingForeground(b).distance(to: b.addingForeground(b)) == 0,
              (a.addingForeground(a).distance(to: a.addingForeground(b)) ?? 0) > 1 else { return false }
        var gallery = SumoAppearanceGallery()
        gallery.reset(to: a)
        for _ in 0..<20 { gallery.learn(a) }
        guard gallery.signatures.count == 4, gallery.distance(to: a) == 0,
              gallery.distance(to: b) == nil else { return false }
        gallery.reset(to: nil)
        guard gallery.isEmpty else { return false }
        var anchorElements = [Float](repeating: 0, count: 32); anchorElements[0] = 1
        var poseElements = anchorElements
        poseElements[0] = 0.5392; poseElements[1] = sqrt(1 - poseElements[0] * poseElements[0])
        var unrelatedElements = [Float](repeating: 0, count: 32); unrelatedElements[1] = 1
        guard let anchor = SumoAppearanceSignature(elements: anchorElements),
              let changedPose = SumoAppearanceSignature(elements: poseElements),
              let unrelated = SumoAppearanceSignature(elements: unrelatedElements) else { return false }
        gallery.reset(to: anchor)
        guard abs((anchor.distance(to: changedPose) ?? 0) - 0.96) < 0.001,
              gallery.isPlausibleTrack(changedPose),
              (gallery.distance(to: changedPose) ?? 0) > 0.72,
              !gallery.isPlausibleTrack(unrelated) else { return false }
        // Continuation alone cannot teach the appearance memory a new pose.
        gallery.learn(changedPose)
        guard gallery.signatures.count == 1 else { return false }
        var search = Self()
        let initial = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.3)
        search.observe(initial, at: 10)
        search.observe(initial.offsetBy(dx: 0.05, dy: 0), at: 10.1)
        let moved = Candidate(box: initial.offsetBy(dx: 0.4, dy: 0), confidence: 0.9, appearanceDistance: 0.15)
        let wrong = Candidate(box: initial, confidence: 0.99, appearanceDistance: 0.95)
        guard search.select([wrong, moved], at: 10.8, recovering: true, requiresAppearance: true) == 1,
              search.select([moved], at: 10.8, recovering: false, requiresAppearance: true) == nil,
              search.select([.init(box: initial, confidence: 1, appearanceDistance: nil)], at: 10.8,
                            recovering: true, requiresAppearance: true) == nil,
              search.select([.init(box: moved.box, confidence: 1, appearanceDistance: nil)], at: 10.8,
                            recovering: true, requiresAppearance: false) == nil,
              search.select([.init(box: initial, confidence: 1, appearanceDistance: .nan)], at: 10.8,
                            recovering: true, requiresAppearance: true) == nil else { return false }
        var ambiguous = Self(); ambiguous.observe(CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3), at: 1)
        let left = Candidate(box: CGRect(x: 0.25, y: 0.2, width: 0.2, height: 0.3), confidence: 0.9, appearanceDistance: 0.1)
        let right = Candidate(box: CGRect(x: 0.55, y: 0.2, width: 0.2, height: 0.3), confidence: 0.9, appearanceDistance: 0.1)
        guard ambiguous.select([left, right], at: 1.5, recovering: true, requiresAppearance: true) == nil,
              hasAmbiguousRecovery([left, right]), !hasAmbiguousRecovery([left, left]),
              !hasAmbiguousRecovery([left, wrong]) else { return false }
        let manual = CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.6)
        let refined = CGRect(x: 0.3, y: 0.2, width: 0.25, height: 0.3)
        guard initialSemanticCorrection([refined], tracked: manual) == 0,
              initialSemanticCorrection([initial.offsetBy(dx: 0.7, dy: 0)], tracked: manual) == nil,
              rebasedScale(1, tracked: manual, semantic: refined) == 0.5,
              rebasedScale(.nan, tracked: manual, semantic: refined) == nil,
              rebasedScale(0.125, tracked: manual, semantic: refined) == nil else { return false }
        // Tightening a selection must preserve the apparent distance error.
        guard let scale = rebasedScale(1, tracked: manual, semantic: refined),
              abs(refined.height / (manual.height * scale) - 1) < 0.00001 else { return false }
        return true
    }
}
