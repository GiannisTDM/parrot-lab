import Foundation

struct SumoFollowLease {
    let input: BebopPilotingInput
    let expiresAt: TimeInterval
    func value(at now: TimeInterval) -> BebopPilotingInput {
        guard now.isFinite, expiresAt.isFinite, now < expiresAt else { return .neutral }
        return .init(roll: min(SumoFollowControl.maximumTurn, max(-SumoFollowControl.maximumTurn, input.roll)),
                     pitch: min(SumoFollowControl.maximumDrive, max(-SumoFollowControl.maximumDrive, input.pitch)), yaw: 0, gaz: 0)
    }
}

enum SumoFollowControl {
    static let maximumDrive: Int8 = 40
    static let maximumTurn: Int8 = 50
    private static let retreatDeadband: CGFloat = 0.04

    /// Semantic detection can tighten a manually drawn box without the subject
    /// moving. Translate the held size into that new box representation first.
    static func referenceHeight(capturedHeight: CGFloat, capturedScale: CGFloat, currentScale: CGFloat,
                                targetScale: CGFloat = 1) -> CGFloat? {
        guard [capturedHeight, capturedScale, currentScale, targetScale].allSatisfy(\.isFinite),
              capturedHeight > 0, capturedHeight <= 1, capturedScale > 0, currentScale > 0, targetScale > 0 else { return nil }
        let reference = capturedHeight * (currentScale / capturedScale) * targetScale
        guard reference.isFinite, reference > 0 else { return nil }
        return min(0.98, reference)
    }

    static func input(box: CGRect, confidence: Float, desiredHeight: CGFloat,
                      configuration: SumoTrackingConfiguration = .defaults(for: .person),
                      referenceScaleRatio: CGFloat = 1, retreatHeight: CGFloat? = nil) -> BebopPilotingInput {
        let config = configuration.sanitized
        let values = [box.minX, box.minY, box.width, box.height, desiredHeight]
        guard values.allSatisfy(\.isFinite), confidence.isFinite, confidence >= 0.45,
              box.width > 0, box.height > 0, desiredHeight > 0, desiredHeight <= 1,
              box.minX >= 0, box.minY >= 0, box.maxX <= 1, box.maxY <= 1 else { return .neutral }
        let error = box.midX - 0.5
        func output(_ error: CGFloat, deadband: CGFloat, gain: CGFloat, limit: Double) -> Int8 {
            guard abs(error) > deadband, limit > 0 else { return 0 }
            let magnitude = Int(min(floor(limit), (abs(error) * gain).rounded()))
            return Int8(clamping: error > 0 ? magnitude : -magnitude)
        }
        let turn = output(error, deadband: 0.035, gain: 160 * config.turnResponse, limit: config.maximumTurn)
        guard let reference = referenceHeight(capturedHeight: desiredHeight, capturedScale: 1,
            currentScale: referenceScaleRatio, targetScale: config.targetScale) else { return .neutral }
        var drive = output(1 - box.height / reference, deadband: 0.10, gain: 85 * config.driveResponse, limit: config.maximumDrive)
        if let retreatHeight, retreatHeight.isFinite, retreatHeight > 0, retreatHeight <= 1.2 {
            let retreat = output(1 - retreatHeight / reference, deadband: retreatDeadband,
                                 gain: 85 * config.driveResponse, limit: config.maximumDrive)
            // The shorter lead may only make retreat earlier. It cannot make
            // the robot advance towards a subject or erase a real size error.
            if retreat < 0 { drive = min(drive, retreat) }
        }
        let alignment = max(0, min(1, (0.28 - abs(error)) / 0.20))
        return .init(roll: turn, pitch: drive < 0 ? drive : Int8((CGFloat(drive) * alignment).rounded()))
    }

    static func input(measurement: SumoFollowMeasurement, confidence: Float, desiredHeight: CGFloat,
                      configuration: SumoTrackingConfiguration = .defaults(for: .person),
                      referenceScaleRatio: CGFloat = 1) -> BebopPilotingInput {
        var result = input(box: measurement.box, confidence: confidence, desiredHeight: desiredHeight,
                           configuration: configuration, referenceScaleRatio: referenceScaleRatio,
                           retreatHeight: measurement.retreatHeight)
        if !measurement.distanceReliable {
            let reference = referenceHeight(capturedHeight: desiredHeight, capturedScale: 1,
                currentScale: referenceScaleRatio, targetScale: configuration.sanitized.targetScale)
            let canRetreat = measurement.retreatHeight.map { height in
                height.isFinite && height > 0 && height <= 1.2 &&
                    (reference.map { height > $0 * (1 + retreatDeadband) } ?? false)
            } ?? false
            result.pitch = canRetreat ? min(0, result.pitch) : 0
        }
        return result
    }

    static func selfTest() -> Bool {
        let centered = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.4)
        let far = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.2)
        var config = SumoTrackingConfiguration.defaults(for: .person)
        let refined = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.2)
        guard let translated = referenceHeight(capturedHeight: 0.4, capturedScale: 1, currentScale: 0.5), translated == 0.2,
              input(box: refined, confidence: 0.9, desiredHeight: translated) == .neutral,
              referenceHeight(capturedHeight: 0.2, capturedScale: 0.5, currentScale: 0.5) == 0.2,
              referenceHeight(capturedHeight: 0.4, capturedScale: .nan, currentScale: 1) == nil,
              referenceHeight(capturedHeight: 0.4, capturedScale: 0, currentScale: 1) == nil else { return false }
        var halfSize = config; halfSize.targetScale = 0.5
        guard referenceHeight(capturedHeight: 0.6, capturedScale: 1, currentScale: 2, targetScale: 0.5) == 0.6,
              input(box: CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.6), confidence: 0.9,
                    desiredHeight: 0.6, configuration: halfSize, referenceScaleRatio: 2) == .neutral else { return false }
        guard input(box: centered, confidence: 0.9, desiredHeight: 0.4) == .neutral,
              input(box: far, confidence: 0.9, desiredHeight: 0.4).pitch == 30,
              input(box: centered, confidence: 0.9, desiredHeight: 0.2).pitch == -30 else { return false }
        config.driveResponse = 0.2
        guard input(box: far, confidence: 0.9, desiredHeight: 0.4, configuration: config).pitch == 9 else { return false }
        config.maximumDrive = 0; config.maximumTurn = 0
        guard input(box: far, confidence: 0.9, desiredHeight: 0.4, configuration: config) == .neutral else { return false }
        for mode in SumoTrackingMode.allCases {
            for reference: CGFloat in [0.2, 0.4, 0.6] {
                let config = SumoTrackingConfiguration.defaults(for: mode)
                let smaller = CGRect(x: 0.4, y: 0, width: 0.2, height: reference * 0.75)
                let larger = CGRect(x: 0.4, y: 0, width: 0.2, height: reference * 1.25)
                let forward = input(box: smaller, confidence: 0.9, desiredHeight: reference, configuration: config)
                let reverse = input(box: larger, confidence: 0.9, desiredHeight: reference, configuration: config)
                let anticipated = input(box: smaller, confidence: 0.9, desiredHeight: reference,
                                        configuration: config, retreatHeight: min(1.2, reference * 2))
                guard forward.pitch > 0, reverse.pitch == -forward.pitch,
                      anticipated.pitch < 0, abs(Int(anticipated.pitch)) <= Int(config.maximumDrive),
                      abs(Int(forward.pitch)) <= Int(config.maximumDrive) else { return false }
            }
        }
        let side = input(box: CGRect(x: 0.8, y: 0, width: 0.1, height: 0.2), confidence: 0.9, desiredHeight: 0.4)
        guard side.roll == 24, side.pitch == 0,
              input(box: CGRect(x: 0.79, y: 0.1, width: 0.2, height: 0.5), confidence: 0.9,
                    desiredHeight: 0.4).pitch < 0,
              input(box: centered, confidence: 0.9, desiredHeight: 0.4, retreatHeight: 0.43).pitch < 0,
              input(box: centered, confidence: 0.9, desiredHeight: 0.4, retreatHeight: 0.2) == .neutral,
              input(box: centered, confidence: 0.9, desiredHeight: 0.4, retreatHeight: .nan) == .neutral,
              input(box: centered, confidence: 0.9, desiredHeight: 0.4, retreatHeight: 1.21) == .neutral,
              input(box: CGRect(x: 0.25, y: 0.01, width: 0.5, height: 0.98), confidence: 0.9,
                    desiredHeight: 0.98, retreatHeight: 1.10).pitch < 0,
              input(box: centered, confidence: .nan, desiredHeight: 0.4) == .neutral,
              input(box: centered, confidence: 0.2, desiredHeight: 0.4) == .neutral,
              input(box: centered, confidence: 0.9, desiredHeight: .nan) == .neutral,
              input(box: CGRect(x: -0.1, y: 0, width: 0.2, height: 0.3), confidence: 1, desiredHeight: 0.4) == .neutral else { return false }
        let lease = SumoFollowLease(input: .init(roll: 100, pitch: -100, yaw: 100, gaz: 100), expiresAt: 10.4)
        let reverse = lease.value(at: 10)
        guard reverse == .init(roll: 50, pitch: -40), lease.value(at: 10.4) == .neutral,
              lease.value(at: .nan) == .neutral,
              SumoFollowLease(input: reverse, expiresAt: .nan).value(at: 10) == .neutral,
              ARSDKPhotoCommand.jumpingSumoPCMD(flag: true, speed: reverse.pitch, turn: reverse.roll) == Data([3, 0, 0, 0, 1, 216, 50]) else { return false }
        return SumoFollowMotion.selfTest() && SumoFollowMeasurementFilter.selfTest() &&
            SumoApproachEstimator.selfTest() && SumoBlurMonitor.selfTest()
    }
}

/// Limit acceleration as well as speed: high turn gain alone can blur the next frame.
struct SumoFollowMotion {
    private var turn: Double = 0, drive: Double = 0
    private var restoredTurnFactor: Double = 1
    private var lastAt: TimeInterval?
    mutating func reset() { turn = 0; drive = 0; restoredTurnFactor = 1; lastAt = nil }
    mutating func update(_ target: BebopPilotingInput, configuration: SumoTrackingConfiguration,
                         at now: TimeInterval, turnFactor: Double = 1) -> BebopPilotingInput {
        guard now.isFinite else { reset(); return .neutral }
        let config = configuration.sanitized
        let elapsed = lastAt.map { now - $0 } ?? 0.05
        guard elapsed >= 0, elapsed <= 0.45 else { reset(); lastAt = now; return .neutral }
        let dt = min(0.15, elapsed)
        lastAt = now
        let requestedFactor = turnFactor.isFinite ? min(1, max(0.2, turnFactor)) : 0.2
        // Brake in this frame, but give the picture time to clear before accelerating.
        restoredTurnFactor = min(requestedFactor, restoredTurnFactor + dt * 0.65)
        let turnLimit = config.maximumTurn * restoredTurnFactor
        func approach(_ value: Double, _ desired: Double, _ rate: Double) -> Double {
            if desired == 0 { return 0 }
            return value + max(-rate * dt, min(rate * dt, desired - value))
        }
        let desiredTurn = max(-turnLimit, min(turnLimit, Double(target.roll) * restoredTurnFactor))
        turn = approach(turn, desiredTurn, (35 + (1 - config.smoothness) * 220) * config.turnResponse)
        // A retreat request must never keep applying yesterday's forward
        // acceleration. Brake first, then build reverse speed within the cap.
        if target.pitch < 0, drive > 0 { drive = 0 }
        let driveRate = (25 + (1 - config.smoothness) * 140) * config.driveResponse
        drive = approach(drive, Double(target.pitch), driveRate * (target.pitch < 0 ? 1.8 : 1))
        // A live limit reduction must take effect immediately, even mid-ramp.
        turn = max(-turnLimit, min(turnLimit, turn))
        drive = max(-config.maximumDrive, min(config.maximumDrive, drive))
        let integerTurnLimit = floor(turnLimit), integerDriveLimit = floor(config.maximumDrive)
        return .init(roll: Int8(max(-integerTurnLimit, min(integerTurnLimit, turn.rounded()))),
                     pitch: Int8(max(-integerDriveLimit, min(integerDriveLimit, drive.rounded()))))
    }
    static func selfTest() -> Bool {
        var motion = Self()
        var config = SumoTrackingConfiguration.defaults(for: .person)
        let target = BebopPilotingInput(roll: 24, pitch: 30)
        let first = motion.update(target, configuration: config, at: 10)
        guard first.roll > 0, first.roll < 10, first.pitch > 0, first.pitch < 10 else { return false }
        var value = first
        for step in 1...20 { value = motion.update(target, configuration: config, at: 10 + Double(step) * 0.05) }
        guard value == target else { return false }
        config.maximumDrive = 5; config.maximumTurn = 5
        let limited = motion.update(target, configuration: config, at: 11.05)
        guard limited == .init(roll: 5, pitch: 5) else { return false }
        guard motion.update(.neutral, configuration: config, at: 11.10) == .neutral else { return false }
        config = .defaults(for: .cat)
        config.maximumTurn = 100; config.maximumDrive = 100
        motion.reset()
        for step in 0...30 { value = motion.update(.init(roll: 100, pitch: 100), configuration: config, at: 20 + Double(step) * 0.05) }
        guard value.roll == 30, value.pitch == 20 else { return false }
        let blurred = motion.update(.init(roll: 100, pitch: 100), configuration: config, at: 21.55, turnFactor: 0.2)
        guard blurred.roll == 6, blurred.pitch == 20 else { return false }
        let firstRetreat = motion.update(.init(pitch: -20), configuration: config, at: 21.575)
        guard firstRetreat.pitch < 0, firstRetreat.pitch >= -20,
              motion.update(.neutral, configuration: config, at: 21.58) == .neutral else { return false }
        let clearing = motion.update(.init(roll: 100, pitch: 100), configuration: config, at: 21.60)
        guard clearing.roll > 0, clearing.roll < 10,
              motion.update(.neutral, configuration: config, at: 21.65, turnFactor: 0.2) == .neutral else { return false }
        config.maximumTurn = 2.9; config.maximumDrive = 3.9
        let fractional = motion.update(.init(roll: 100, pitch: 100), configuration: config, at: 21.70)
        guard abs(Int(fractional.roll)) <= 2, abs(Int(fractional.pitch)) <= 3 else { return false }
        guard motion.update(target, configuration: config, at: 21) == .neutral,
              motion.update(target, configuration: config, at: .nan) == .neutral else { return false }
        motion.reset()
        guard motion.update(.neutral, configuration: config, at: 12) == .neutral,
              motion.update(target, configuration: config, at: 13) == .neutral else { return false }
        return true
    }
}

struct SumoFollowMeasurement {
    let box: CGRect
    let distanceReliable: Bool
    var retreatHeight: CGFloat? = nil
}

/// Keep steering tied to the visible center, while rejecting pose/clipping-driven
/// size changes. Heights live in a canonical representation across box refinement.
struct SumoFollowMeasurementFilter {
    private struct PendingChange {
        let pose: Bool
        let startedAt: TimeInterval
        var height: CGFloat
        var aspect: CGFloat
        var samples: Int
    }
    private var lastAt: TimeInterval?
    private var height: CGFloat?
    private var sourceHeight: CGFloat = 0
    private var aspect: CGFloat = 1
    private var poseCompensation: CGFloat = 1
    private var stableSamples = 0
    private var pending: PendingChange?
    private var approach = SumoApproachEstimator()
    private var referenceScale: CGFloat?

    mutating func reset() { self = Self() }

    /// A brief occlusion invalidates timing/confirmation, not the learned pose
    /// representation of this same subject. Full target changes use reset().
    mutating func pause() { lastAt = nil; stableSamples = 0; pending = nil; approach.reset() }

    mutating func update(box: CGRect, referenceScale: CGFloat, at now: TimeInterval) -> SumoFollowMeasurement {
        guard now.isFinite, [box.minX, box.minY, box.width, box.height, referenceScale].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0, box.minX >= 0, box.minY >= 0, box.maxX <= 1, box.maxY <= 1,
              (0.125...8).contains(referenceScale) else {
            reset(); return .init(box: box, distanceReliable: false)
        }
        let rawHeight = box.height / referenceScale
        let rawAspect = box.width / box.height
        let dt = lastAt.map { now - $0 }
        if height == nil || dt.map({ $0 <= 0 || $0 > 0.45 }) == true {
            reset(); lastAt = now; height = rawHeight; sourceHeight = rawHeight; aspect = rawAspect
            self.referenceScale = referenceScale
            _ = approach.update(box: box, calibratedHeight: rawHeight, referenceScale: referenceScale, at: now)
            stableSamples = 1
            return .init(box: box, distanceReliable: false)
        }
        lastAt = now
        if let previousScale = self.referenceScale, abs(log(referenceScale / previousScale)) > 0.000_01 {
            // Canonical height already accounts for this semantic refinement;
            // its changed aspect must not become a new pose or approach trend.
            approach.reset(); pending = nil; aspect = rawAspect
        }
        self.referenceScale = referenceScale
        func output(_ reliable: Bool, retreat: CGFloat? = nil) -> SumoFollowMeasurement {
            let filteredHeight = min(1, max(0.001, (height ?? rawHeight) * referenceScale))
            let filtered = CGRect(x: box.minX, y: min(1 - filteredHeight, max(0, box.midY - filteredHeight / 2)),
                                  width: box.width, height: filteredHeight)
            let retreatHeight = retreat.map { min(1.2, $0 * referenceScale) }
            return .init(box: filtered, distanceReliable: reliable, retreatHeight: retreatHeight)
        }
        // Cropped bodies and tails at the edge are not distance measurements.
        guard box.minX > 0.012, box.minY > 0.012, box.maxX < 0.988, box.maxY < 0.988 else {
            stableSamples = 0; pending = nil
            let retreat = approach.update(box: box, calibratedHeight: rawHeight * poseCompensation,
                                          referenceScale: referenceScale, at: now)
            return output(false, retreat: retreat)
        }
        let poseChange = abs(log(rawAspect / aspect)) > log(1.28)
        let scaleJump = abs(log(rawHeight / max(0.001, sourceHeight))) > log(1.35)
        if poseChange || scaleJump {
            approach.reset()
            if var candidate = pending, candidate.pose == poseChange,
               abs(log(rawHeight / candidate.height)) < log(1.15),
               abs(log(rawAspect / candidate.aspect)) < log(1.12) {
                candidate.samples += 1; candidate.height = rawHeight; candidate.aspect = rawAspect
                pending = candidate
                if candidate.samples >= 3, now - candidate.startedAt >= 0.14 {
                    if poseChange {
                        // A crouch/turn changes shape without proving a distance change.
                        // Rebase only after the new shape has remained consistent.
                        poseCompensation = min(4, max(0.25, (height ?? rawHeight) / rawHeight))
                    }
                    aspect = rawAspect; sourceHeight = rawHeight; pending = nil
                }
            } else {
                pending = .init(pose: poseChange, startedAt: now, height: rawHeight, aspect: rawAspect, samples: 1)
            }
            stableSamples = 0
            return output(false)
        }
        pending = nil
        sourceHeight = rawHeight
        aspect += (rawAspect - aspect) * 0.03
        let alpha = 1 - exp(-max(0, dt ?? 0) / 0.24)
        if let previous = height {
            height = exp(log(previous) + alpha * log(rawHeight * poseCompensation / previous))
        }
        stableSamples += 1
        let retreat = approach.update(box: box, calibratedHeight: rawHeight * poseCompensation,
                                      referenceScale: referenceScale, at: now)
        return output(stableSamples >= 3, retreat: retreat)
    }

    static func selfTest() -> Bool {
        func box(_ height: CGFloat, width: CGFloat? = nil, x: CGFloat = 0.4) -> CGRect {
            .init(x: x, y: 0.2, width: width ?? height / 2, height: height)
        }
        var filter = Self()
        guard !filter.update(box: box(0.4), referenceScale: 1, at: 10).distanceReliable else { return false }
        _ = filter.update(box: box(0.4), referenceScale: 1, at: 10.08)
        guard filter.update(box: box(0.4), referenceScale: 1, at: 10.16).distanceReliable else { return false }
        // Semantic refinement changes the box representation, not the held distance.
        let rebased = filter.update(box: box(0.2), referenceScale: 0.5, at: 10.24)
        guard rebased.distanceReliable, abs(rebased.box.height - 0.2) < 0.00001 else { return false }
        // Current horizontal center is never delayed by the size filter.
        let moved = filter.update(box: box(0.2, x: 0.7), referenceScale: 0.5, at: 10.32)
        guard moved.box.midX == 0.75 else { return false }
        // A single partial/pose box cannot command a sudden drive correction.
        guard !filter.update(box: box(0.1, width: 0.1), referenceScale: 0.5, at: 10.40).distanceReliable,
              !filter.update(box: .init(x: 0.4, y: 0, width: 0.1, height: 0.1), referenceScale: 0.5, at: 10.48).distanceReliable else { return false }
        filter.reset()
        for step in 0...3 { _ = filter.update(box: box(0.4), referenceScale: 1, at: 20 + Double(step) * 0.08) }
        // A sustained crouch is rebased, rather than chased forwards.
        var crouched: SumoFollowMeasurement?
        for step in 4...11 { crouched = filter.update(box: box(0.2, width: 0.2), referenceScale: 1, at: 20 + Double(step) * 0.08) }
        guard let crouched, crouched.distanceReliable, abs(crouched.box.height - 0.4) < 0.001 else { return false }
        filter.pause()
        let firstRecovered = filter.update(box: box(0.2, width: 0.2), referenceScale: 1, at: 22)
        let secondRecovered = filter.update(box: box(0.2, width: 0.2), referenceScale: 1, at: 22.08)
        let recovered = filter.update(box: box(0.2, width: 0.2), referenceScale: 1, at: 22.16)
        guard !firstRecovered.distanceReliable, !secondRecovered.distanceReliable, recovered.distanceReliable,
              abs(recovered.box.height - 0.4) < 0.001,
              SumoFollowControl.input(box: recovered.box, confidence: 0.9, desiredHeight: 0.4).pitch == 0 else { return false }
        // Retaining pose correction must not freeze genuine distance changes.
        var closer = recovered
        for step in 1...10 { closer = filter.update(box: box(0.2 + CGFloat(step) * 0.01, width: 0.2 + CGFloat(step) * 0.01), referenceScale: 1, at: 22.16 + Double(step) * 0.08) }
        guard closer.distanceReliable, closer.box.height > 0.53,
              SumoFollowControl.input(box: closer.box, confidence: 0.9, desiredHeight: 0.4).pitch < 0 else { return false }
        var further = closer
        for step in 1...15 { further = filter.update(box: box(0.3 - CGFloat(step) * 0.01, width: 0.3 - CGFloat(step) * 0.01), referenceScale: 1, at: 22.96 + Double(step) * 0.08) }
        guard further.distanceReliable, further.box.height < 0.36,
              SumoFollowControl.input(box: further.box, confidence: 0.9, desiredHeight: 0.4).pitch > 0 else { return false }
        filter.reset()
        var growing: SumoFollowMeasurement?
        for step in 0...12 { growing = filter.update(box: box(0.25 + CGFloat(step) * 0.012), referenceScale: 1, at: 30 + Double(step) * 0.08) }
        guard let growing, growing.distanceReliable, growing.box.height > 0.34, growing.box.height < 0.394,
              !filter.update(box: box(0.4), referenceScale: 1, at: 35).distanceReliable,
              !filter.update(box: box(0.4), referenceScale: 1, at: 34).distanceReliable,
              !filter.update(box: box(0.4), referenceScale: .nan, at: 35.1).distanceReliable else { return false }
        filter.reset()
        for step in 0...3 { _ = filter.update(box: box(0.4), referenceScale: 1, at: 40 + Double(step) * 0.06) }
        _ = filter.update(box: box(0.406), referenceScale: 1, at: 40.24)
        let comingCloser = filter.update(box: box(0.412), referenceScale: 1, at: 40.30)
        guard let earlyHeight = comingCloser.retreatHeight, earlyHeight > 0.416,
              comingCloser.box.height < 0.412,
              SumoFollowControl.input(box: comingCloser.box, confidence: 0.9, desiredHeight: 0.4).pitch == 0,
              SumoFollowControl.input(box: comingCloser.box, confidence: 0.9, desiredHeight: 0.4,
                                      retreatHeight: earlyHeight).pitch < 0 else { return false }
        filter.reset()
        for step in 0...3 { _ = filter.update(box: box(0.4), referenceScale: 1, at: 45 + Double(step) * 0.06) }
        let singleJump = filter.update(box: box(0.412), referenceScale: 1, at: 45.24)
        guard singleJump.retreatHeight == 0.412,
              SumoFollowControl.input(box: singleJump.box, confidence: 0.9, desiredHeight: 0.4,
                                      retreatHeight: singleJump.retreatHeight).pitch == 0 else { return false }
        // A cropped startup or pose-only growth never gets the raw/lead path.
        filter.reset()
        for step in 0...4 {
            let clipped = filter.update(box: box(0.3, x: 0), referenceScale: 1, at: 50 + Double(step) * 0.06)
            guard !clipped.distanceReliable, clipped.retreatHeight == nil else { return false }
        }
        filter.reset()
        for step in 0...3 { _ = filter.update(box: box(0.4, x: 0.03), referenceScale: 1, at: 60 + Double(step) * 0.06) }
        let closeEdge = filter.update(box: box(0.44, x: 0.005), referenceScale: 1, at: 60.24)
        guard !closeEdge.distanceReliable, let edgeHeight = closeEdge.retreatHeight,
              edgeHeight >= 0.44,
              SumoFollowControl.input(measurement: closeEdge, confidence: 0.9, desiredHeight: 0.4).pitch < 0,
              SumoFollowControl.input(measurement: closeEdge, confidence: 0.9, desiredHeight: 0.6).pitch == 0,
              SumoFollowControl.input(measurement: .init(box: box(0.6), distanceReliable: false, retreatHeight: 0.3),
                                      confidence: 0.9, desiredHeight: 0.4).pitch == 0 else { return false }
        filter.pause()
        guard filter.update(box: box(0.46), referenceScale: 1, at: 60.30).retreatHeight == nil else { return false }
        filter.reset()
        for step in 0...3 { _ = filter.update(box: box(0.4), referenceScale: 1, at: 70 + Double(step) * 0.06) }
        let poseOnly = filter.update(box: box(0.44, width: 0.2), referenceScale: 1, at: 70.24)
        guard poseOnly.retreatHeight == nil,
              filter.update(box: box(0.22, width: 0.1), referenceScale: 0.5, at: 70.30).retreatHeight == nil else { return false }
        return true
    }
}
