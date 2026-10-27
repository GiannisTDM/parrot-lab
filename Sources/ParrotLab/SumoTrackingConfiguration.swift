import AppKit

enum SumoTrackingMode: String, Codable, CaseIterable {
    case person, legs, cat
    var title: String {
        switch self { case .person: return "Person"; case .legs: return "Person · legs / close"; case .cat: return "Cat" }
    }
    var subject: String { self == .cat ? "cat" : "person" }
    var driveCeiling: Double { self == .cat ? 20 : 40 }
    var turnCeiling: Double { self == .cat ? 30 : 50 }
}

enum SumoTrackingPreset: String, CaseIterable {
    case gentle, responsive, cinematic

    var title: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .gentle: return "Low speed and soft corrections."
        case .responsive: return "Quicker corrections within this subject's limits."
        case .cinematic: return "Slow, smooth movement for a steadier picture."
        }
    }
}

struct SumoTrackingConfiguration: Codable, Equatable {
    var mode: SumoTrackingMode = .person
    var turnResponse: Double = 0.60
    var driveResponse: Double = 0.80
    var maximumTurn: Double = 24
    var maximumDrive: Double = 30
    var smoothness: Double = 0.65
    var persistence: Double = 1.5
    var targetScale: Double = 1
    private static let key = "ParrotLab.SumoTracking.V2"

    static func defaults(for mode: SumoTrackingMode) -> Self {
        var value = Self(); value.mode = mode
        if mode == .cat {
            value.turnResponse = 0.45; value.driveResponse = 0.55
            value.maximumTurn = 20; value.maximumDrive = 15; value.smoothness = 0.75
        }
        return value
    }
    /// Presets affect motion only. Distance and target memory remain the user's choices.
    func applying(_ preset: SumoTrackingPreset) -> Self {
        var value = sanitized
        switch preset {
        case .responsive:
            let standard = Self.defaults(for: mode)
            value.turnResponse = standard.turnResponse; value.driveResponse = standard.driveResponse
            value.maximumTurn = standard.maximumTurn; value.maximumDrive = standard.maximumDrive
            value.smoothness = standard.smoothness
        case .gentle:
            value.turnResponse = 0.35; value.driveResponse = 0.45
            value.maximumTurn = mode == .cat ? 14 : 18
            value.maximumDrive = mode == .cat ? 10 : 18
            value.smoothness = 0.82
        case .cinematic:
            value.turnResponse = 0.25; value.driveResponse = 0.35
            value.maximumTurn = mode == .cat ? 10 : 14
            value.maximumDrive = mode == .cat ? 8 : 14
            value.smoothness = 0.94
        }
        return value.sanitized
    }
    /// Derived rather than persisted, so existing V2 tuning remains valid.
    var preset: SumoTrackingPreset? {
        let current = sanitized
        return SumoTrackingPreset.allCases.first { preset in
            let candidate = current.applying(preset)
            let pairs = [(current.turnResponse, candidate.turnResponse),
                         (current.driveResponse, candidate.driveResponse),
                         (current.maximumTurn, candidate.maximumTurn),
                         (current.maximumDrive, candidate.maximumDrive),
                         (current.smoothness, candidate.smoothness)]
            return pairs.allSatisfy { abs($0.0 - $0.1) < 0.000_001 }
        }
    }
    var sanitized: Self {
        var value = self
        let fallback = Self.defaults(for: mode)
        func bound(_ number: Double, _ range: ClosedRange<Double>, _ replacement: Double) -> Double {
            number.isFinite ? min(range.upperBound, max(range.lowerBound, number)) : replacement
        }
        value.turnResponse = bound(turnResponse, 0.1...2, fallback.turnResponse)
        value.driveResponse = bound(driveResponse, 0.1...2, fallback.driveResponse)
        value.maximumTurn = bound(maximumTurn, 0...mode.turnCeiling, fallback.maximumTurn)
        value.maximumDrive = bound(maximumDrive, 0...mode.driveCeiling, fallback.maximumDrive)
        value.smoothness = bound(smoothness, 0...1, fallback.smoothness)
        value.persistence = bound(persistence, 0...3, fallback.persistence)
        value.targetScale = bound(targetScale, 0.5...1.5, fallback.targetScale)
        return value
    }
    static func load(mode requestedMode: SumoTrackingMode? = nil, defaults: UserDefaults = .standard) -> Self {
        let mode = requestedMode ?? SumoTrackingMode(rawValue: defaults.string(forKey: key + ".mode") ?? "") ?? .person
        guard let data = defaults.data(forKey: key + "." + mode.rawValue),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return .defaults(for: mode) }
        value.mode = mode
        return value.sanitized
    }
    func save(defaults: UserDefaults = .standard) {
        let value = sanitized
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.key + "." + value.mode.rawValue)
        defaults.set(value.mode.rawValue, forKey: Self.key + ".mode")
    }
    static func selfTest() -> Bool {
        let name = "ParrotLab.SumoTuningTest." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: name) else { return false }
        defer { defaults.removePersistentDomain(forName: name) }
        var value = Self.defaults(for: .legs)
        value.turnResponse = 1.3; value.maximumTurn = 17; value.persistence = 2.2
        value.save(defaults: defaults)
        guard Self.load(defaults: defaults) == value else { return false }
        var cat = Self.defaults(for: .cat)
        cat.maximumDrive = 100; cat.maximumTurn = 100; cat.turnResponse = .nan
        cat.smoothness = -1; cat.persistence = .infinity
        let safe = cat.sanitized
        guard safe.maximumDrive == 20, safe.maximumTurn == 30, safe.turnResponse == 0.45,
              safe.smoothness == 0, safe.persistence == 1.5 else { return false }
        safe.save(defaults: defaults)
        guard Self.load(mode: .legs, defaults: defaults) == value, Self.load(defaults: defaults) == safe else { return false }
        // V2 data written before presets existed must retain every tuning value.
        let oldJSON = Data("{\"mode\":\"cat\",\"turnResponse\":0.7,\"driveResponse\":0.6,\"maximumTurn\":19,\"maximumDrive\":13,\"smoothness\":0.8,\"persistence\":2.4,\"targetScale\":1.2}".utf8)
        defaults.set(oldJSON, forKey: key + ".cat")
        let migrated = Self.load(mode: .cat, defaults: defaults)
        guard migrated.turnResponse == 0.7, migrated.maximumDrive == 13,
              migrated.persistence == 2.4, migrated.targetScale == 1.2, migrated.preset == nil else { return false }
        for mode in SumoTrackingMode.allCases {
            var custom = Self.defaults(for: mode)
            custom.persistence = 2.3; custom.targetScale = 1.3
            for preset in SumoTrackingPreset.allCases {
                let result = custom.applying(preset)
                guard result.mode == mode, result.persistence == 2.3, result.targetScale == 1.3,
                      result.maximumDrive <= mode.driveCeiling, result.maximumTurn <= mode.turnCeiling,
                      result.preset == preset else { return false }
                result.save(defaults: defaults)
                guard Self.load(mode: mode, defaults: defaults) == result else { return false }
                var adjusted = result; adjusted.turnResponse += 0.03
                guard adjusted.preset == nil else { return false }
            }
        }
        return true
    }
}

final class SumoTrackingPresetView: NSStackView {
    var onChange: ((SumoTrackingConfiguration) -> Void)?
    private(set) var configuration: SumoTrackingConfiguration
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let detail = NSTextField(wrappingLabelWithString: "")

    init(configuration: SumoTrackingConfiguration) {
        self.configuration = configuration.sanitized
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 5
        let label = NSTextField(labelWithString: "Movement")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        popup.addItems(withTitles: SumoTrackingPreset.allCases.map(\.title) + ["Custom"])
        popup.menu?.autoenablesItems = false
        popup.target = self; popup.action = #selector(changed)
        popup.setAccessibilityLabel("Follow movement preset")
        popup.toolTip = "Choose how Follow responds. Adjust individual controls under Advanced."
        let row = NSStackView(views: [label, popup]); row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 274).isActive = true
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        detail.widthAnchor.constraint(equalToConstant: 274).isActive = true
        addArrangedSubview(row); addArrangedSubview(detail)
        update(configuration)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ configuration: SumoTrackingConfiguration) {
        self.configuration = configuration.sanitized
        let preset = self.configuration.preset
        popup.selectItem(withTitle: preset?.title ?? "Custom")
        // Custom describes advanced adjustments; it is not a fourth motion profile.
        popup.lastItem?.isEnabled = false
        detail.stringValue = preset?.detail ?? "Your Advanced movement settings."
    }
    @objc private func changed() {
        guard let preset = SumoTrackingPreset.allCases.first(where: { $0.title == popup.titleOfSelectedItem }) else {
            update(configuration); return
        }
        update(configuration.applying(preset))
        onChange?(configuration)
    }
    static func selfTest() -> Bool {
        _ = NSApplication.shared
        let view = Self(configuration: .defaults(for: .cat))
        var changes = 0
        view.onChange = { _ in changes += 1 }
        var config = SumoTrackingConfiguration.defaults(for: .legs)
        config.targetScale = 1.2; config.persistence = 2.5
        view.update(config)
        guard changes == 0, view.popup.titleOfSelectedItem == "Responsive" else { return false }
        view.popup.selectItem(withTitle: "Cinematic"); view.changed()
        guard changes == 1, view.configuration.preset == .cinematic,
              view.configuration.targetScale == 1.2, view.configuration.persistence == 2.5 else { return false }
        config.turnResponse = 0.9
        view.update(config)
        guard changes == 1, view.popup.titleOfSelectedItem == "Custom", view.popup.lastItem?.isEnabled == false else { return false }
        view.changed()
        return changes == 1 && view.configuration == config
    }
}

/// Inline controls stay in the flight window, so tuning need not interrupt Follow.
final class SumoTrackingTuningView: NSStackView {
    var onChange: ((SumoTrackingConfiguration) -> Void)?
    private(set) var configuration: SumoTrackingConfiguration
    private var sliders: [NSSlider] = []
    private var values: [NSTextField] = []
    private let names = ["Turning response", "Turning limit", "Distance response", "Drive limit", "Smoothness", "Target memory", "Subject size"]

    init(configuration: SumoTrackingConfiguration) {
        self.configuration = configuration.sanitized
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 5
        for (index, name) in names.enumerated() {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 10.5)
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            let spacer = NSView()
            let row = NSStackView(views: [label, spacer, value]); row.spacing = 6
            row.widthAnchor.constraint(equalToConstant: 274).isActive = true
            addArrangedSubview(row)
            let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(changed(_:)))
            slider.tag = index; slider.isContinuous = true
            slider.setAccessibilityLabel(name)
            slider.toolTip = ["Higher values turn toward side-to-side motion more quickly.",
                              "Maximum automatic turning command.",
                              "Higher values correct distance more quickly.",
                              "Maximum automatic forward and reverse command; the main drive slider also applies.",
                              "Higher values soften acceleration to reduce blurred camera frames.",
                              "Pause movement and try to recover the same nearby target for this long. Zero stops at the first loss.",
                              "Relative to the size captured by Follow: larger means a closer following distance."][index]
            slider.widthAnchor.constraint(equalToConstant: 274).isActive = true
            sliders.append(slider); values.append(value); addArrangedSubview(slider)
        }
        let reset = NSButton(title: "Reset this mode", target: self, action: #selector(resetValues))
        reset.bezelStyle = .inline; reset.font = .systemFont(ofSize: 11)
        addArrangedSubview(reset)
        update(configuration)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ configuration: SumoTrackingConfiguration) {
        self.configuration = configuration.sanitized
        let config = self.configuration
        let ranges: [ClosedRange<Double>] = [0.1...2, 0...config.mode.turnCeiling, 0.1...2, 0...config.mode.driveCeiling, 0...1, 0...3, 0.5...1.5]
        let numbers = [config.turnResponse, config.maximumTurn, config.driveResponse, config.maximumDrive, config.smoothness, config.persistence, config.targetScale]
        for index in sliders.indices {
            sliders[index].minValue = ranges[index].lowerBound; sliders[index].maxValue = ranges[index].upperBound
            sliders[index].doubleValue = numbers[index]
            values[index].stringValue = index == 5 ? String(format: "%.1f s", numbers[index]) : String(format: "%.0f%%", numbers[index] * ([0, 2, 4, 6].contains(index) ? 100 : 1))
        }
    }
    @objc private func changed(_ slider: NSSlider) {
        var config = configuration
        switch slider.tag {
        case 0: config.turnResponse = slider.doubleValue
        case 1: config.maximumTurn = slider.doubleValue
        case 2: config.driveResponse = slider.doubleValue
        case 3: config.maximumDrive = slider.doubleValue
        case 4: config.smoothness = slider.doubleValue
        case 5: config.persistence = slider.doubleValue
        case 6: config.targetScale = slider.doubleValue
        default: return
        }
        update(config); onChange?(configuration)
    }
    @objc private func resetValues() { update(.defaults(for: configuration.mode)); onChange?(configuration) }
    static func selfTest() -> Bool {
        _ = NSApplication.shared
        let view = Self(configuration: .defaults(for: .cat))
        var changes = 0
        view.onChange = { _ in changes += 1 }
        view.update(.defaults(for: .legs))
        guard changes == 0, view.sliders[1].maxValue == 50 else { return false }
        view.sliders[0].doubleValue = 0.2; view.changed(view.sliders[0])
        return changes == 1 && view.configuration.turnResponse == 0.2 && view.values[0].stringValue == "20%"
    }
}
