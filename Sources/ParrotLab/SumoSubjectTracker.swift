import Foundation
import CoreVideo
import CoreMedia
import Vision

struct SumoSubjectObservation {
    let box: CGRect?
    let confidence: Float
    let frameSize: CGSize
    let sampledAt: TimeInterval
    let latency: TimeInterval
    let lost: Bool
    let recovering: Bool
    let referenceScale: CGFloat
    let quality: SumoTrackingQuality

    init(box: CGRect?, confidence: Float, frameSize: CGSize, sampledAt: TimeInterval,
         latency: TimeInterval, lost: Bool, recovering: Bool = false, referenceScale: CGFloat = 1,
         quality: SumoTrackingQuality = .unknown) {
        self.box = box; self.confidence = confidence; self.frameSize = frameSize
        self.sampledAt = sampledAt; self.latency = latency; self.lost = lost; self.recovering = recovering
        self.referenceScale = referenceScale.isFinite && (0.125...8).contains(referenceScale) ? referenceScale : 1
        self.quality = quality
    }
}

/// Geometry-only memory: never extrapolates a motion command while the image is uncertain.
private struct SumoTargetMemory {
    struct Candidate {
        let box: CGRect
        let confidence: Float
    }
    private(set) var lastBox: CGRect?
    private(set) var lastSeen: TimeInterval?
    private(set) var expired = false
    private(set) var recovering = false

    static func valid(_ box: CGRect) -> Bool {
        SumoTargetSearch.valid(box)
    }
    static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        SumoTargetSearch.overlap(lhs, rhs)
    }
    static func consistent(_ box: CGRect, with reference: CGRect) -> Bool {
        guard valid(box), valid(reference) else { return false }
        let widthRatio = box.width / reference.width, heightRatio = box.height / reference.height
        guard (0.4...2.5).contains(widthRatio), (0.5...2).contains(heightRatio) else { return false }
        return abs(box.midX - reference.midX) <= max(0.18, reference.width * 0.9) &&
            abs(box.midY - reference.midY) <= max(0.15, reference.height * 0.6)
    }
    mutating func beginFrame(at time: TimeInterval, persistence: TimeInterval) -> Bool {
        if recovering, let lastSeen,
           !time.isFinite || time - lastSeen >= Self.duration(persistence) { expired = true }
        return !expired
    }
    mutating func accept(_ box: CGRect, at time: TimeInterval, persistence: TimeInterval = 1.5) {
        guard beginFrame(at: time, persistence: persistence), Self.valid(box), time.isFinite else { return }
        lastBox = box; lastSeen = time; recovering = false
    }
    mutating func missing(at time: TimeInterval, persistence: TimeInterval) -> (lost: Bool, recovering: Bool) {
        guard let lastSeen else { return (false, false) }
        recovering = true
        if !time.isFinite || time - lastSeen >= Self.duration(persistence) { expired = true }
        return (expired, !expired)
    }
    static func duration(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(3, max(0, value)) : 1.5
    }
    func select(_ candidates: [Candidate]) -> Candidate? {
        guard !expired else { return nil }
        var unique: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            guard Self.valid(candidate.box), candidate.confidence.isFinite, candidate.confidence >= 0.55,
                  !unique.contains(where: { Self.overlap($0.box, candidate.box) > 0.6 }) else { continue }
            unique.append(candidate)
        }
        guard let reference = lastBox else {
            return unique.max { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
        }
        let ranked = unique.filter { Self.consistent($0.box, with: reference) }.map { candidate in
            let distance = hypot(candidate.box.midX - reference.midX, candidate.box.midY - reference.midY)
            let score = Self.overlap(candidate.box, reference) + CGFloat(candidate.confidence) * 0.15 - distance
            return (candidate, score)
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first else { return nil }
        // Nearby lookalikes are not an identity signal. Wait instead of picking
        // another person/cat when two distinct candidates fit about equally.
        if ranked.count > 1, best.1 - ranked[1].1 < 0.18,
           Self.overlap(best.0.box, ranked[1].0.box) < 0.3 { return nil }
        return best.0
    }
}

/// One Vision job and one retained frame at a time. Nothing runs on the drone.
/// Brief losses preserve the selected target, but never yield a predicted box.
final class SumoSubjectTracker {
    var onResult: ((SumoSubjectObservation) -> Void)?
    private let queue = DispatchQueue(label: "parrotlab.sumo.vision", qos: .userInitiated)
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var running = false, busy = false
    private var lastSubmitted: TimeInterval = 0
    private var mostRecentFrameAt: TimeInterval?
    private var requestedMode: SumoTrackingMode = .person
    private var requestedSeed: CGRect?
    private var requestedSelectionPoint: CGPoint?
    private var persistence: TimeInterval = 1.5
    private var failureEpoch: UInt64?
    private var computeLabel = "Automatic"
    private var workerSummary = "waiting"
    // Worker-queue ownership below this point.
    private var workerEpoch: UInt64 = 0
    private var mode: SumoTrackingMode = .person
    private var tracking: VNTrackObjectRequest?
    private var sequence = VNSequenceRequestHandler()
    private var memory = SumoTargetMemory()
    private var seed: CGRect?
    private var invalidSeed = false
    private var selectionPoint: CGPoint?
    private var lastDetection: TimeInterval = -.infinity
    private var acquiredWithLegs = false
    private var appearance = SumoAppearanceGallery()
    private var search = SumoTargetSearch()
    private var semanticAnchored = false
    private var referenceScale: CGFloat = 1
    private var confirmation = SumoRecoveryConfirmation()
    private var blurMonitor = SumoBlurMonitor()

    var latestFrameAt: TimeInterval? {
        lock.lock(); defer { lock.unlock() }; return mostRecentFrameAt
    }
    var diagnosticSummary: String {
        lock.lock(); defer { lock.unlock() }
        return "epoch=\(epoch) running=\(running) busy=\(busy) mode=\(requestedMode.rawValue) \(workerSummary) compute=\(computeLabel)"
    }
    static func isValidSelection(_ box: CGRect) -> Bool { SumoTargetMemory.valid(box) }
    static func isValidSelectionPoint(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
    }
    private static func containsSelection(_ box: CGRect, point: CGPoint?) -> Bool {
        guard let point, isValidSelectionPoint(point) else { return false }
        return point.x >= box.minX && point.x <= box.maxX && point.y >= box.minY && point.y <= box.maxY
    }

    func start(mode: SumoTrackingMode = .person, persistence: TimeInterval = 1.5, seed: CGRect? = nil,
               selectionPoint: CGPoint? = nil) {
        lock.lock()
        epoch &+= 1; running = true; lastSubmitted = 0; mostRecentFrameAt = nil; requestedMode = mode
        self.persistence = SumoTargetMemory.duration(persistence)
        // Preserve an explicit invalid selection so it can be rejected. Turning
        // it into nil would silently start automatic acquisition of a new target.
        requestedSeed = seed
        requestedSelectionPoint = selectionPoint
        lock.unlock()
    }
    func updatePersistence(_ duration: TimeInterval) {
        lock.lock(); persistence = SumoTargetMemory.duration(duration); lock.unlock()
    }
    func stop() {
        lock.lock(); epoch &+= 1; running = false; mostRecentFrameAt = nil; let token = epoch; lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let stopped = !self.running && self.epoch == token; self.lock.unlock()
            guard stopped else { return }
            self.tracking = nil; self.sequence = VNSequenceRequestHandler(); self.memory = SumoTargetMemory()
            self.appearance = SumoAppearanceGallery(); self.search = SumoTargetSearch()
            self.referenceScale = 1; self.semanticAnchored = false
            self.confirmation.reset(); self.blurMonitor.reset(); self.selectionPoint = nil
            self.lock.lock(); self.workerSummary = "stopped gallery=0"; self.lock.unlock()
        }
    }
    func observe(_ frame: ProcessedVideoFrame) {
        guard !frame.isSynthetic, frame.processingLatencyMilliseconds.isFinite,
              (0...250).contains(frame.processingLatencyMilliseconds) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard running else { lock.unlock(); return }
        // Camera arrival health is separate from a potentially slow Vision job.
        // Rejected synthetic/stale frames never refresh this watchdog timestamp.
        mostRecentFrameAt = now
        // Leave headroom above Sumo's common 15 fps feed, without queueing frames.
        guard !busy, now - lastSubmitted >= 1.0 / 20 else { lock.unlock(); return }
        busy = true; lastSubmitted = now; let token = epoch; lock.unlock()
        let sampledAt = now - frame.processingLatencyMilliseconds / 1000
        queue.async { [weak self] in self?.process(frame, token: token, sampledAt: sampledAt) }
    }
    private func process(_ frame: ProcessedVideoFrame, token: UInt64, sampledAt now: TimeInterval) {
        defer {
            lock.lock()
            busy = false
            if epoch == token {
                let state = memory.expired ? "expired" : memory.recovering ? "searching" : memory.lastBox == nil ? "acquiring" : "tracked"
                workerSummary = "state=\(state) gallery=\(appearance.signatures.count) foreground=\(appearance.foregroundCount) semantic=\(semanticAnchored) recoveryMatches=\(confirmation.matches) scale=\(String(format: "%.2f", Double(referenceScale)))"
            }
            lock.unlock()
        }
        guard current(token) else { return }
        lock.lock()
        let duration = persistence, nextMode = requestedMode, nextSeed = requestedSeed, nextPoint = requestedSelectionPoint
        lock.unlock()
        if workerEpoch != token {
            workerEpoch = token; tracking = nil; sequence = VNSequenceRequestHandler()
            memory = SumoTargetMemory(); mode = nextMode; seed = nextSeed
            appearance = SumoAppearanceGallery(); search = SumoTargetSearch()
            semanticAnchored = false; referenceScale = 1
            selectionPoint = nextPoint; confirmation.reset(); blurMonitor.reset()
            invalidSeed = (nextSeed.map { !Self.isValidSelection($0) } ?? false) ||
                (nextPoint.map { !Self.isValidSelectionPoint($0) } ?? false)
            acquiredWithLegs = mode == .legs; lastDetection = -.infinity
        }
        let frameSize = CGSize(width: frame.width, height: frame.height)
        let quality = blurMonitor.update(pixelBuffer: frame.pixelBuffer, box: memory.lastBox ?? seed, at: now)
        if invalidSeed {
            deliver(.init(box: nil, confidence: 0, frameSize: frameSize,
                sampledAt: now, latency: ProcessInfo.processInfo.systemUptime - now, lost: true, quality: quality), token: token)
            return
        }
        autoreleasepool {
            let previousTracking = tracking
            let previousSequence = sequence
            let manualSeedFrame = seed != nil
            var requestFailed = false
            var identityRejected = false
            var candidate: SumoTargetMemory.Candidate?
            var trackedObservation: VNDetectedObjectObservation?
            var interimLost: Bool?
            var pendingSignature: SumoAppearanceSignature?
            var pendingSemantic = false
            var pendingLegs = acquiredWithLegs
            var pendingScale = referenceScale
            var pendingRebase = false
            var pendingAnchorReset = false
            var recoverySignature: SumoAppearanceSignature?
            var mask: SumoForegroundMask?
            var maskAttempted = false
            func appearanceSignature(_ box: CGRect) -> SumoAppearanceSignature? {
                guard let raw = try? signature(in: frame, box: box) else { return nil }
                // Mask inference is optional and bounded to one per cycle. A
                // late raw embedding falls back instead of extending the job.
                guard ProcessInfo.processInfo.systemUptime - now < 0.25 else { return raw }
                if !maskAttempted { maskAttempted = true; mask = SumoForegroundMask(pixelBuffer: frame.pixelBuffer) }
                guard let image = mask?.image(for: box), let foreground = try? signature(in: image) else { return raw }
                return raw.addingForeground(foreground)
            }
            func reportWeakness() {
                guard memory.lastBox != nil else { return }
                let time = ProcessInfo.processInfo.systemUptime
                let state = memory.missing(at: time, persistence: duration)
                if state.lost { tracking = nil }
                interimLost = state.lost
                deliver(.init(box: nil, confidence: 0, frameSize: frameSize,
                    sampledAt: now, latency: time - now, lost: state.lost, recovering: state.recovering,
                    referenceScale: referenceScale, quality: quality), token: token)
            }
            if !memory.beginFrame(at: now, persistence: duration) { tracking = nil; seed = nil }
            do {
                if let seed {
                    // Explicit selections support partial bodies and feet. A
                    // later semantic refinement may remove surrounding bedding.
                    self.seed = nil
                    let selected = SumoTargetMemory.Candidate(box: seed, confidence: 1)
                    try beginTracking(selected, frame: frame)
                    candidate = selected
                    pendingAnchorReset = true
                } else if let tracking {
                    try sequence.perform([tracking], on: frame.pixelBuffer, orientation: .up)
                    let reference = memory.recovering ? confirmation.referenceBox ?? memory.lastBox : memory.lastBox
                    if let observation = tracking.results?.first as? VNDetectedObjectObservation,
                       observation.confidence >= 0.55, SumoTargetMemory.valid(observation.boundingBox),
                       reference.map({ SumoTargetMemory.consistent(observation.boundingBox, with: $0) }) ?? true {
                        candidate = .init(box: observation.boundingBox, confidence: observation.confidence)
                        trackedObservation = observation
                    }
                }
                // Neutralize BEFORE a recovery inference can spend time on the
                // frame. Search predictions never become driving observations.
                if candidate == nil { reportWeakness() }
                let recovering = memory.recovering
                let interval = recovering ? 0.15 : 0.4
                // Establish an explicitly selected optical model before cold
                // semantic/embedding inference can consume the frame budget.
                if !manualSeedFrame, !memory.expired, now - lastDetection >= interval {
                    lastDetection = now
                    let detected = try detect(in: frame)
                    // Bound learned requests as well as retained descriptors.
                    // Near candidates first during healthy correction; recovery
                    // considers the whole image, using appearance to rank them.
                    let reference = candidate?.box ?? memory.lastBox
                    let detectedCandidates = Array(detected.candidates.filter {
                        SumoTargetMemory.valid($0.box) && $0.confidence.isFinite && $0.confidence >= 0.55 &&
                            (memory.lastBox != nil || selectionPoint == nil || Self.containsSelection($0.box, point: selectionPoint))
                    }.sorted { lhs, rhs in
                        if !recovering, let reference {
                            return SumoTargetMemory.overlap(lhs.box, reference) > SumoTargetMemory.overlap(rhs.box, reference)
                        }
                        return lhs.confidence > rhs.confidence
                    }.prefix(4))
                    var selected: SumoTargetMemory.Candidate?
                    var selectedSignature: SumoAppearanceSignature?
                    if memory.lastBox == nil, candidate == nil {
                        selected = memory.select(detectedCandidates)
                        if let selected { selectedSignature = appearanceSignature(selected.box) }
                        pendingAnchorReset = true
                    } else if !recovering, !semanticAnchored, let tracked = candidate?.box,
                              let index = SumoTargetSearch.initialSemanticCorrection(detectedCandidates.map(\.box), tracked: tracked) {
                        selected = detectedCandidates[index]
                        selectedSignature = appearanceSignature(detectedCandidates[index].box)
                        // Initial manual crops often contain much more background
                        // than the animal. Establish a clean semantic anchor.
                        pendingAnchorReset = true
                    } else if semanticAnchored || (mode == .legs && !recovering) {
                        let signatures = detectedCandidates.map { appearanceSignature($0.box) }
                        let matches = zip(detectedCandidates, signatures).map { detected, signature in
                            SumoTargetSearch.Candidate(box: detected.box, confidence: detected.confidence,
                                appearanceDistance: signature.flatMap { appearance.distance(to: $0) })
                        }
                        let selection: Int?
                        if appearance.isEmpty {
                            // Unsupported/failed descriptors may retry learning
                            // from a strict nearby semantic match; they must not
                            // unlock a wide geometry-only target replacement.
                            var nearbyMemory = memory
                            if nearbyMemory.lastBox == nil, let reference {
                                nearbyMemory.accept(reference, at: now, persistence: duration)
                            }
                            let nearby = nearbyMemory.select(detectedCandidates)
                            selection = nearby.flatMap { nearby in
                                detectedCandidates.firstIndex { $0.box == nearby.box && $0.confidence == nearby.confidence }
                            }
                        } else {
                            selection = search.select(matches, at: now, recovering: recovering, requiresAppearance: true)
                        }
                        if recovering, selection == nil, SumoTargetSearch.hasAmbiguousRecovery(matches) {
                            candidate = nil; trackedObservation = nil; tracking = nil
                            identityRejected = true; reportWeakness()
                        }
                        if let index = selection {
                            selected = detectedCandidates[index]; selectedSignature = signatures[index]
                        }
                    }
                    if let choice = selected {
                        // Rebase only against a good track from THIS image.
                        // Comparing to an old recovery box would erase actual
                        // distance changes while the subject was out of view.
                        if !recovering, let tracked = candidate?.box {
                            if let scale = SumoTargetSearch.rebasedScale(referenceScale, tracked: tracked, semantic: choice.box) {
                                pendingScale = scale; pendingRebase = true
                            } else { selectedSignature = nil; selected = nil }
                        }
                    }
                    if let selected {
                        try beginTracking(selected, frame: frame)
                        trackedObservation = nil
                        candidate = selected; pendingSignature = selectedSignature
                        pendingSemantic = true; pendingLegs = detected.legs
                    } else if let tracked = candidate, !appearance.isEmpty,
                              let signature = appearanceSignature(tracked.box) {
                        // The object tracker reports texture confidence, not cat
                        // identity. A high-confidence curtain must still fail.
                        let strictMatch = appearance.distance(to: signature).map { $0 <= 0.72 } ?? false
                        let plausibleContinuation = tracked.confidence >= 0.65 && appearance.isPlausibleTrack(signature)
                        if !strictMatch && !plausibleContinuation {
                            candidate = nil; trackedObservation = nil
                            identityRejected = true
                            tracking = nil; sequence = VNSequenceRequestHandler()
                            reportWeakness()
                        }
                    }
                    // A semantic miss alone is not a lost target: low-angle,
                    // noisy views can hide the cat label while the optical
                    // track and learned appearance remain sound. Such frames
                    // may continue tracking, but never update the gallery.
                }
                if !manualSeedFrame, !pendingSemantic, appearance.isEmpty, let candidate {
                    pendingSignature = appearanceSignature(candidate.box)
                    pendingAnchorReset = true
                }
                if memory.recovering, let proposed = candidate {
                    recoverySignature = pendingSignature ?? appearanceSignature(proposed.box)
                    // A newly recovered semantic box already passed the strict
                    // gallery search. The old optical model must independently
                    // match the remembered appearance before it can confirm.
                    if !appearance.isEmpty, !pendingSemantic,
                       !(recoverySignature.map { appearance.isPlausibleTrack($0) } ?? false) {
                        candidate = nil; trackedObservation = nil; tracking = nil
                        identityRejected = true; reportWeakness()
                    }
                }
            } catch {
                requestFailed = true
                tracking = nil; sequence = VNSequenceRequestHandler()
                candidate = nil
                lock.lock(); failureEpoch = token; lock.unlock()
            }
            let completedAt = ProcessInfo.processInfo.systemUptime
            let latency = completedAt - now
            let activeSession = current(token)
            if !SumoRecoveryConfirmation.isFresh(sampledAt: now, at: completedAt) || !activeSession {
                candidate = nil
                if latency.isFinite, latency > 0.4, activeSession, !requestFailed, !identityRejected,
                   !memory.expired, let previousTracking {
                    // No slow-frame observation, appearance or scale is
                    // committed, but keep the last good optical model when a
                    // semantic refresh merely exceeded its deadline.
                    tracking = previousTracking; sequence = previousSequence
                } else {
                    tracking = nil; sequence = VNSequenceRequestHandler()
                }
            }
            if !memory.beginFrame(at: ProcessInfo.processInfo.systemUptime, persistence: duration) {
                candidate = nil; tracking = nil
            }
            if let candidate {
                if let trackedObservation { tracking?.inputObservation = trackedObservation }
                if memory.recovering, !confirmation.observe(box: candidate.box, signature: recoverySignature, at: now) {
                    // Keep a provisional optical model, but do not refresh the
                    // deadline, teach appearance, change scale or issue motion.
                    deliver(.init(box: nil, confidence: 0, frameSize: frameSize, sampledAt: now,
                        latency: latency, lost: false, recovering: true, referenceScale: referenceScale,
                        quality: quality), token: token)
                    return
                }
                // Commit appearance/scale only after age and session validation.
                if pendingAnchorReset { appearance.reset(to: pendingSignature) }
                else if pendingSemantic, let pendingSignature { appearance.learn(pendingSignature) }
                if pendingSemantic {
                    semanticAnchored = true; acquiredWithLegs = pendingLegs
                }
                referenceScale = pendingScale
                search.observe(candidate.box, at: now, rebased: pendingRebase)
                memory.accept(candidate.box, at: now, persistence: duration)
                confirmation.reset(); selectionPoint = nil
                deliver(.init(box: candidate.box, confidence: candidate.confidence,
                    frameSize: frameSize, sampledAt: now, latency: latency, lost: false,
                    referenceScale: referenceScale, quality: quality), token: token)
            } else {
                confirmation.reset()
                let state = memory.missing(at: ProcessInfo.processInfo.systemUptime, persistence: duration)
                if state.lost { tracking = nil }
                if interimLost != state.lost {
                    deliver(.init(box: nil, confidence: 0, frameSize: frameSize,
                        sampledAt: now, latency: latency, lost: state.lost, recovering: state.recovering,
                        referenceScale: referenceScale, quality: quality), token: token)
                }
            }
        }
    }
    private func signature(in frame: ProcessedVideoFrame, box: CGRect) throws -> SumoAppearanceSignature? {
        guard SumoTargetMemory.valid(box) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        if #available(macOS 14, *) { request.revision = VNGenerateImageFeaturePrintRequestRevision2 }
        request.regionOfInterest = box
        request.imageCropAndScaleOption = .scaleFill
        configure(request)
        try SumoVisionCompute.perform(request, with: VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .up))
        guard let result = request.results?.first else { return nil }
        return SumoAppearanceSignature(featurePrint: result)
    }
    private func signature(in image: CGImage) throws -> SumoAppearanceSignature? {
        let request = VNGenerateImageFeaturePrintRequest()
        if #available(macOS 14, *) { request.revision = VNGenerateImageFeaturePrintRequestRevision2 }
        request.imageCropAndScaleOption = .scaleFill
        configure(request)
        try SumoVisionCompute.perform(request, with: VNImageRequestHandler(cgImage: image, orientation: .up))
        return request.results?.first.flatMap { SumoAppearanceSignature(featurePrint: $0) }
    }
    private func configure(_ request: VNRequest) {
        let label = SumoVisionCompute.configure(request)
        lock.lock(); computeLabel = label; lock.unlock()
    }
    private func beginTracking(_ candidate: SumoTargetMemory.Candidate, frame: ProcessedVideoFrame) throws {
        let observation = VNDetectedObjectObservation(boundingBox: candidate.box)
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
        sequence = VNSequenceRequestHandler()
        try sequence.perform([request], on: frame.pixelBuffer, orientation: .up)
        tracking = request
    }
    private func detect(in frame: ProcessedVideoFrame) throws -> (candidates: [SumoTargetMemory.Candidate], legs: Bool) {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .up)
        if mode == .cat {
            let animals = VNRecognizeAnimalsRequest()
            configure(animals)
            try SumoVisionCompute.perform(animals, with: handler)
            let candidates = (animals.results ?? []).compactMap { observation -> SumoTargetMemory.Candidate? in
                guard let label = observation.labels.first,
                      Self.isCat(identifier: label.identifier), label.confidence >= 0.65 else { return nil }
                return .init(box: observation.boundingBox, confidence: min(observation.confidence, label.confidence))
            }
            return (candidates, false)
        }
        // Keep the representation fixed after acquisition; switching from a full
        // body to just ankles would otherwise look like a sudden distance change.
        if mode == .person, !acquiredWithLegs {
            let rectangles = VNDetectHumanRectanglesRequest()
            rectangles.upperBodyOnly = false
            configure(rectangles)
            try SumoVisionCompute.perform(rectangles, with: handler)
            let candidates = (rectangles.results ?? []).filter { $0.confidence >= 0.6 }.map {
                SumoTargetMemory.Candidate(box: $0.boundingBox, confidence: $0.confidence)
            }
            if !candidates.isEmpty || memory.lastBox != nil { return (candidates, false) }
        }
        let pose = VNDetectHumanBodyPoseRequest()
        configure(pose)
        try SumoVisionCompute.perform(pose, with: handler)
        let candidates = (pose.results ?? []).compactMap { observation -> SumoTargetMemory.Candidate? in
            let names: [VNHumanBodyPoseObservation.JointName] = [.leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
            let points = names.compactMap { try? observation.recognizedPoint($0) }.filter { $0.confidence >= 0.35 }
            // At least three joints across two levels, rather than one isolated
            // feature, are required before treating a shape as lower body.
            guard points.count >= 3,
                  let minX = points.map({ $0.location.x }).min(), let maxX = points.map({ $0.location.x }).max(),
                  let minY = points.map({ $0.location.y }).min(), let maxY = points.map({ $0.location.y }).max(),
                  maxY - minY >= 0.08 else { return nil }
            let paddingX = max(0.035, (maxX - minX) * 0.25), paddingY = max(0.025, (maxY - minY) * 0.12)
            let box = CGRect(x: max(0, minX - paddingX), y: max(0, minY - paddingY),
                width: min(1, maxX + paddingX) - max(0, minX - paddingX),
                height: min(1, maxY + paddingY) - max(0, minY - paddingY))
            let confidence = points.map(\.confidence).reduce(0, +) / Float(points.count)
            return .init(box: box, confidence: confidence)
        }
        if !candidates.isEmpty { return (candidates, true) }
        if mode == .legs {
            let rectangles = VNDetectHumanRectanglesRequest()
            rectangles.upperBodyOnly = false
            configure(rectangles)
            try SumoVisionCompute.perform(rectangles, with: handler)
            let lowerBodies = (rectangles.results ?? []).filter { $0.confidence >= 0.6 }.map { observation in
                let full = observation.boundingBox
                return SumoTargetMemory.Candidate(box: CGRect(x: full.minX, y: full.minY,
                    width: full.width, height: full.height * 0.55), confidence: observation.confidence)
            }
            return (lowerBodies, true)
        }
        return ([], true)
    }
    private static func isCat(identifier: String) -> Bool {
        identifier.caseInsensitiveCompare(VNAnimalIdentifier.cat.rawValue) == .orderedSame
    }
    private func current(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return running && epoch == token
    }
    private func deliver(_ result: SumoSubjectObservation, token: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.current(token) else { return }; self.onResult?(result)
        }
    }

    static func selfTest() -> Bool {
        guard SumoTargetSearch.selfTest(), SumoRecoveryConfirmation.selfTest(), SumoForegroundMask.selfTest() else { return false }
        typealias Candidate = SumoTargetMemory.Candidate
        let initial = CGRect(x: 0.35, y: 0.2, width: 0.2, height: 0.5)
        let moved = CGRect(x: 0.43, y: 0.2, width: 0.2, height: 0.49)
        var memory = SumoTargetMemory()
        guard memory.missing(at: 1, persistence: 1.5) == (false, false),
              memory.select([Candidate(box: initial, confidence: 0.9)])?.box == initial,
              memory.select([Candidate(box: initial, confidence: .nan)]) == nil,
              !SumoTargetMemory.valid(.init(x: .nan, y: 0, width: 0.2, height: 0.5)),
              !SumoTargetMemory.valid(.init(x: -0.01, y: 0, width: 0.2, height: 0.5)),
              !SumoTargetMemory.valid(.init(x: 0, y: 0, width: 0, height: 0.5)),
              isCat(identifier: "Cat"), !isCat(identifier: "Dog"), !isCat(identifier: "catfish") else { return false }
        memory.accept(initial, at: 10)
        guard memory.missing(at: 10.4, persistence: 1.5) == (false, true),
              memory.lastBox == initial,
              memory.select([Candidate(box: .init(x: 0.75, y: 0.2, width: 0.2, height: 0.5), confidence: 1)]) == nil,
              memory.select([Candidate(box: moved, confidence: 0.9)])?.box == moved else { return false }
        memory.accept(moved, at: 10.5)
        guard memory.missing(at: 11.9, persistence: 1.5) == (false, true),
              memory.missing(at: 12, persistence: 1.5) == (true, false),
              memory.select([Candidate(box: moved, confidence: 1)]) == nil else { return false }
        var ambiguous = SumoTargetMemory()
        ambiguous.accept(CGRect(x: 0.35, y: 0.2, width: 0.3, height: 0.5), at: 0)
        let left = Candidate(box: .init(x: 0.27, y: 0.2, width: 0.2, height: 0.5), confidence: 0.9)
        let right = Candidate(box: .init(x: 0.53, y: 0.2, width: 0.2, height: 0.5), confidence: 0.9)
        guard ambiguous.select([left, right]) == nil,
              SumoTargetMemory.duration(.nan) == 1.5,
              SumoTargetMemory.duration(-1) == 0,
              SumoTargetMemory.duration(100) == 3 else { return false }
        var deadline = SumoTargetMemory()
        deadline.accept(initial, at: 10)
        guard deadline.missing(at: 10.1, persistence: 1.5) == (false, true),
              deadline.beginFrame(at: 11.49, persistence: 1.5),
              !deadline.beginFrame(at: 11.5, persistence: 1.5) else { return false }
        deadline.accept(moved, at: 11.5)
        guard deadline.expired, deadline.lastBox == initial,
              deadline.select([Candidate(box: moved, confidence: 1)]) == nil else { return false }
        var disabled = SumoTargetMemory()
        disabled.accept(initial, at: 10, persistence: 0)
        guard disabled.beginFrame(at: 11, persistence: 0) else { return false }
        disabled.accept(moved, at: 11, persistence: 0)
        guard disabled.lastBox == moved, !disabled.recovering,
              disabled.missing(at: 11.1, persistence: 0) == (true, false) else { return false }
        disabled.accept(initial, at: 11.1, persistence: 0)
        guard disabled.lastBox == moved else { return false }
        // Provisional recovery matches cannot extend the user-selected memory
        // deadline. Even a third otherwise valid match must lose at expiry.
        var recoveringMemory = SumoTargetMemory(), recoveryGate = SumoRecoveryConfirmation()
        recoveringMemory.accept(initial, at: 20)
        guard recoveringMemory.missing(at: 20.1, persistence: 0.25) == (false, true),
              !recoveryGate.observe(box: initial, signature: nil, at: 20.1),
              !recoveryGate.observe(box: moved, signature: nil, at: 20.167),
              recoveryGate.referenceBox == moved,
              recoveringMemory.lastSeen == 20,
              !recoveringMemory.beginFrame(at: 20.25, persistence: 0.25) else { return false }
        // Inference may start before expiry and finish after it. Fresh source
        // pixels alone cannot override the original target-memory deadline.
        var completionMemory = SumoTargetMemory(), completionGate = SumoRecoveryConfirmation()
        completionMemory.accept(initial, at: 100)
        guard completionMemory.missing(at: 100.1, persistence: 0.3) == (false, true),
              !completionGate.observe(box: initial, signature: nil, at: 100.12),
              !completionGate.observe(box: initial, signature: nil, at: 100.19),
              completionMemory.beginFrame(at: 100.26, persistence: 0.3),
              SumoRecoveryConfirmation.isFresh(sampledAt: 100.26, at: 100.31),
              !completionMemory.beginFrame(at: 100.31, persistence: 0.3),
              completionGate.matches == 2, completionMemory.lastSeen == 100 else { return false }
        // A stale third completion must be discarded/reset, even when the
        // separate target-memory deadline would otherwise permit recovery.
        var slowMemory = SumoTargetMemory(), slowGate = SumoRecoveryConfirmation()
        slowMemory.accept(initial, at: 200)
        _ = slowMemory.missing(at: 200.1, persistence: 1.5)
        _ = slowGate.observe(box: initial, signature: nil, at: 200.12)
        _ = slowGate.observe(box: initial, signature: nil, at: 200.19)
        guard slowMemory.beginFrame(at: 200.7, persistence: 1.5), slowGate.matches == 2,
              !SumoRecoveryConfirmation.isFresh(sampledAt: 200.26, at: 200.7) else { return false }
        slowGate.reset()
        guard slowGate.matches == 0, slowMemory.lastSeen == 200 else { return false }
        let click = CGPoint(x: 0.45, y: 0.5)
        guard isValidSelectionPoint(click), containsSelection(initial, point: click),
              !containsSelection(initial.offsetBy(dx: 0.4, dy: 0), point: click),
              !isValidSelectionPoint(CGPoint(x: .nan, y: 0.5)),
              !isValidSelectionPoint(CGPoint(x: -0.01, y: 0.5)) else { return false }
        let offClick = Candidate(box: CGRect(x: 0, y: 0, width: 0.3, height: 0.9), confidence: 0.99)
        let clickCandidates = [offClick, Candidate(box: initial, confidence: 0.8)]
        let emptyMemory = SumoTargetMemory()
        guard emptyMemory.select(clickCandidates.filter { containsSelection($0.box, point: click) })?.box == initial,
              emptyMemory.select(clickCandidates.filter { containsSelection($0.box, point: CGPoint(x: 0.95, y: 0.95)) }) == nil else { return false }
        // A manual box rejected by the shared predicate must fail closed,
        // rather than silently selecting an automatically detected subject.
        let invalid = CGRect(x: 0.4, y: 0.2, width: 0.02, height: 0.3)
        guard isValidSelection(initial), !isValidSelection(invalid),
              !isValidSelection(CGRect(x: 0.4, y: 0.2, width: 0.025, height: 0.025)),
              SumoSubjectObservation(box: initial, confidence: 1, frameSize: .zero, sampledAt: 0,
                                     latency: 0, lost: false, referenceScale: .nan).referenceScale == 1 else { return false }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                                  nil, &buffer) == kCVReturnSuccess, let buffer else { return false }
        func frame(latency: Double = 0, synthetic: Bool = false) -> ProcessedVideoFrame {
            .init(pixelBuffer: buffer,
                timing: .init(rtpTimestamp: 0, presentationTime: .zero, nominalDuration: CMTime(value: 1, timescale: 15)),
                sequenceNumber: 1, processingLatencyMilliseconds: latency, isSynthetic: synthetic, targetFrameRate: 15)
        }
        let invalidTracker = SumoSubjectTracker()
        var invalidResult: SumoSubjectObservation?
        invalidTracker.onResult = { invalidResult = $0 }
        invalidTracker.start(mode: .legs, seed: invalid)
        invalidTracker.observe(frame())
        let invalidDeadline = ProcessInfo.processInfo.systemUptime + 2
        while invalidResult == nil, ProcessInfo.processInfo.systemUptime < invalidDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        invalidTracker.stop()
        guard let invalidResult, invalidResult.lost, invalidResult.box == nil else { return false }
        let invalidClickTracker = SumoSubjectTracker()
        var invalidClickResult: SumoSubjectObservation?
        invalidClickTracker.onResult = { invalidClickResult = $0 }
        invalidClickTracker.start(mode: .cat, selectionPoint: CGPoint(x: .infinity, y: 0.5))
        invalidClickTracker.observe(frame())
        let clickDeadline = ProcessInfo.processInfo.systemUptime + 2
        while invalidClickResult == nil, ProcessInfo.processInfo.systemUptime < clickDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        invalidClickTracker.stop()
        guard let invalidClickResult, invalidClickResult.lost, invalidClickResult.box == nil else { return false }
        let arrivals = SumoSubjectTracker()
        arrivals.start()
        arrivals.lock.lock(); arrivals.busy = true; arrivals.lock.unlock()
        arrivals.observe(frame())
        guard let arrival = arrivals.latestFrameAt else { return false }
        arrivals.observe(frame(latency: 251)); arrivals.observe(frame(synthetic: true))
        guard arrivals.latestFrameAt == arrival else { return false }
        arrivals.stop()
        guard arrivals.latestFrameAt == nil else { return false }
        arrivals.observe(frame())
        guard arrivals.latestFrameAt == nil else { return false }
        arrivals.start()
        guard arrivals.latestFrameAt == nil else { return false }
        arrivals.lock.lock(); arrivals.busy = false; arrivals.lock.unlock()
        arrivals.stop()
        // Events already queued on the main loop must not escape stop/restart.
        let tracker = SumoSubjectTracker()
        var staleDelivered = false
        tracker.onResult = { _ in staleDelivered = true }
        tracker.start(mode: .legs, seed: initial)
        tracker.deliver(.init(box: initial, confidence: 0.9, frameSize: .init(width: 640, height: 480),
                             sampledAt: 0, latency: 0, lost: false), token: 1)
        tracker.stop(); tracker.start(mode: .cat)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        tracker.stop()
        return !staleDelivered
    }

    static func visionSmokeTest() -> Bool {
        guard featurePrintSmokeTest() else { return false }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
                                  attributes, &buffer) == kCVReturnSuccess, let buffer else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            _ = base.initializeMemory(as: UInt8.self, repeating: 0,
                                      count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        // Exercise every request type without requiring a synthetic image to
        // contain a recognizable person/cat. Actual recognition needs footage.
        let cases: [(SumoTrackingMode, CGRect?)] = [(.person, nil), (.legs, nil), (.cat, nil),
            (.legs, CGRect(x: 0.3, y: 0.1, width: 0.3, height: 0.6))]
        for (mode, seed) in cases {
            let tracker = SumoSubjectTracker()
            var result: SumoSubjectObservation?
            tracker.onResult = { result = $0 }
            tracker.start(mode: mode, seed: seed)
            tracker.observe(.init(pixelBuffer: buffer,
                timing: .init(rtpTimestamp: 0, presentationTime: .zero, nominalDuration: CMTime(value: 1, timescale: 8)),
                sequenceNumber: 1, processingLatencyMilliseconds: 0, isSynthetic: false, targetFrameRate: 8))
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while result == nil, ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            tracker.lock.lock(); let failed = tracker.failureEpoch == 1; tracker.lock.unlock()
            tracker.stop()
            guard let result, !failed, !result.lost,
                  seed != nil || result.box == nil else { return false }
        }
        return true
    }

    private static func featurePrintSmokeTest() -> Bool {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32BGRA,
                                  nil, &buffer) == kCVReturnSuccess, let buffer else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<120 {
                for x in 0..<160 {
                    let offset = y * rowBytes + x * 4
                    base[offset] = UInt8((x * 7 + y * 3) % 256)
                    base[offset + 1] = UInt8((x / 10 + y / 10) % 2 == 0 ? 230 : 30)
                    base[offset + 2] = UInt8((y * 5) % 256)
                    base[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        do {
            var signatures: [SumoAppearanceSignature] = []
            for _ in 0..<2 {
                let request = VNGenerateImageFeaturePrintRequest()
                if #available(macOS 14, *) { request.revision = VNGenerateImageFeaturePrintRequestRevision2 }
                request.regionOfInterest = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                SumoVisionCompute.configure(request)
                try SumoVisionCompute.perform(request, with: VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up))
                guard let result = request.results?.first, let signature = SumoAppearanceSignature(featurePrint: result) else { return false }
                signatures.append(signature)
            }
            guard let distance = signatures[0].distance(to: signatures[1]), distance < 0.01 else { return false }
            var gallery = SumoAppearanceGallery(); gallery.reset(to: signatures[0]); gallery.learn(signatures[1])
            return gallery.signatures.count == 2 && (gallery.distance(to: signatures[1]) ?? 1) < 0.01
        } catch { return false }
    }
}
