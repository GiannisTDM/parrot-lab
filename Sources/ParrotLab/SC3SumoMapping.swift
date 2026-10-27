import AppKit

/// Sumo's native backend receives these logical axes after the stock SC3 mapper.
/// This profile never edits the shared mapping_anafi4k.cfg file.
enum SC3SumoMappingAxis: UInt8, Codable, CaseIterable {
    case roll = 1, pitch = 2, yaw = 3, gaz = 4

    var title: String {
        switch self {
        case .roll: return "Roll · right stick horizontal by default"
        case .pitch: return "Pitch · right stick vertical by default"
        case .yaw: return "Yaw · left stick horizontal by default"
        case .gaz: return "Gaz · left stick vertical by default"
        }
    }
}

enum SC3SumoMappingButton: UInt8, Codable, CaseIterable {
    case returnHome = 16, takeoff = 17, disabled = 255

    var title: String {
        switch self {
        case .returnHome: return "Return home button · action 16"
        case .takeoff: return "Takeoff button · action 17"
        case .disabled: return "Unassigned"
        }
    }
}

struct SC3SumoMappingProfile: Codable, Equatable {
    var driveAxis: SC3SumoMappingAxis = .pitch
    var steeringAxis: SC3SumoMappingAxis = .roll
    var invertDrive = false
    var invertSteering = false
    var driveDeadzone: UInt8 = 0
    var steeringDeadzone: UInt8 = 0
    var driveRange: UInt8 = 100
    var steeringRange: UInt8 = 100
    var highJump: SC3SumoMappingButton = .takeoff
    var longJump: SC3SumoMappingButton = .returnHome

    static let defaults = SC3SumoMappingProfile()

    enum Invalid: Error, LocalizedError {
        case axes, deadzone, range, buttons, packet
        var errorDescription: String? {
            switch self {
            case .axes: return "Drive and steering must use different logical axes."
            case .deadzone: return "Deadzone must be between 0 and 30 percent."
            case .range: return "Output range must be between 1 and 100 percent."
            case .buttons: return "High and long jump must use different buttons."
            case .packet: return "This is not a valid version 1 Sumo mapping profile."
            }
        }
    }

    func validate() throws {
        guard driveAxis != steeringAxis else { throw Invalid.axes }
        guard driveDeadzone <= 30, steeringDeadzone <= 30 else { throw Invalid.deadzone }
        guard (1...100).contains(driveRange), (1...100).contains(steeringRange) else { throw Invalid.range }
        guard highJump != longJump || highJump == .disabled else { throw Invalid.buttons }
    }

    /// Proposed v2 extension profile. This is not an ARSDK mapper command.
    /// SMC2 + schema + axes + invert flags + deadzones + ranges + buttons + CRC16.
    func packet() throws -> Data {
        try validate()
        var bytes: [UInt8] = [0x53, 0x4d, 0x43, 0x32, 1, driveAxis.rawValue, steeringAxis.rawValue,
            (invertDrive ? 1 : 0) | (invertSteering ? 2 : 0), driveDeadzone, steeringDeadzone,
            driveRange, steeringRange, highJump.rawValue, longJump.rawValue]
        let crc = Self.crc16(bytes)
        bytes.append(UInt8(truncatingIfNeeded: crc)); bytes.append(UInt8(truncatingIfNeeded: crc >> 8))
        return Data(bytes)
    }

    init() {}

    init(packet: Data) throws {
        let bytes = Array(packet)
        guard bytes.count == 16, Array(bytes[0..<5]) == [0x53, 0x4d, 0x43, 0x32, 1], bytes[7] & ~3 == 0,
              let drive = SC3SumoMappingAxis(rawValue: bytes[5]),
              let steer = SC3SumoMappingAxis(rawValue: bytes[6]),
              let high = SC3SumoMappingButton(rawValue: bytes[12]),
              let long = SC3SumoMappingButton(rawValue: bytes[13]),
              Self.crc16(Array(bytes[0..<14])) == UInt16(bytes[14]) | UInt16(bytes[15]) << 8 else {
            throw Invalid.packet
        }
        driveAxis = drive; steeringAxis = steer
        invertDrive = bytes[7] & 1 != 0; invertSteering = bytes[7] & 2 != 0
        driveDeadzone = bytes[8]; steeringDeadzone = bytes[9]
        driveRange = bytes[10]; steeringRange = bytes[11]
        highJump = high; longJump = long
        try validate()
    }

    private static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 == 0 ? crc << 1 : (crc << 1) ^ 0x1021 }
        }
        return crc
    }

    /// Matches the bounded integer arithmetic in the proposed controller extension.
    func output(axes: [Int]) throws -> (drive: Int, steering: Int) {
        try validate()
        guard axes.count == 4, axes.allSatisfy({ (-128...127).contains($0) }) else { throw Invalid.axes }
        func scaled(_ axis: SC3SumoMappingAxis, _ inverted: Bool, _ deadzone: UInt8, _ range: UInt8) -> Int {
            let value = max(-100, min(100, axes[Int(axis.rawValue) - 1]))
            let magnitude = abs(value)
            guard magnitude > Int(deadzone) else { return 0 }
            let output = (magnitude - Int(deadzone)) * Int(range) / (100 - Int(deadzone))
            return (value < 0 ? -output : output) * (inverted ? -1 : 1)
        }
        return (scaled(driveAxis, invertDrive, driveDeadzone, driveRange),
                scaled(steeringAxis, invertSteering, steeringDeadzone, steeringRange))
    }
}

/// Local draft storage only. Saving a draft never means it was applied to SC3.
enum SC3SumoMappingDraftStore {
    private static func packet(at url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // An imported file is untrusted. Read only enough to reject an oversized file.
        var data = Data()
        while data.count < 17 {
            let part = try file.read(upToCount: 17 - data.count) ?? Data()
            if part.isEmpty { break }
            data.append(part)
        }
        guard data.count == 16 else { throw SC3SumoMappingProfile.Invalid.packet }
        return data
    }

    static func load(_ url: URL) throws -> SC3SumoMappingProfile {
        try SC3SumoMappingProfile(packet: packet(at: url))
    }

    static func save(_ profile: SC3SumoMappingProfile, to url: URL) throws {
        let data = try profile.packet()
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let previous = try packet(at: url)
            _ = try SC3SumoMappingProfile(packet: previous)
            try previous.write(to: url.appendingPathExtension("previous"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }

    static func restorePrevious(at url: URL) throws -> SC3SumoMappingProfile {
        let previous = try load(url.appendingPathExtension("previous"))
        try save(previous, to: url)
        return previous
    }
}

struct SC3SumoMappingSnapshot: Equatable {
    var generation: UInt64 = 0
    var appliedProfile: SC3SumoMappingProfile?
    /// Set only after a Sumo-specific extension reports support and reads back its profile.
    var canApply = false
    var message = "Native v1c has fixed assignments. A verified Sumo-specific v2 mapping interface is required to apply changes."
}

/// Native controller assignments; deliberately separate from Mac input mapping.
/// A candidate can be prepared offline. Apply stays unavailable without a verified extension.
final class SC3SumoMappingWindowController: NSWindowController {
    var onApply: ((SC3SumoMappingProfile, UInt64) -> Void)? { didSet { candidateChanged() } }
    var onReload: (() -> Void)? { didSet { reload.isEnabled = onReload != nil } }
    private let status = NSTextField(wrappingLabelWithString: "")
    private let current = NSTextField(wrappingLabelWithString: "")
    private let validation = NSTextField(wrappingLabelWithString: "")
    private let drive = NSPopUpButton(), steer = NSPopUpButton()
    private let high = NSPopUpButton(), long = NSPopUpButton()
    private let invertDrive = NSButton(checkboxWithTitle: "Invert drive", target: nil, action: nil)
    private let invertSteer = NSButton(checkboxWithTitle: "Invert steering", target: nil, action: nil)
    private let driveDeadzone = NSSlider(value: 0, minValue: 0, maxValue: 30, target: nil, action: nil)
    private let steerDeadzone = NSSlider(value: 0, minValue: 0, maxValue: 30, target: nil, action: nil)
    private let driveRange = NSSlider(value: 100, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let steerRange = NSSlider(value: 100, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let apply = NSButton(title: "Apply to SC3", target: nil, action: nil)
    private let reload = NSButton(title: "Read controller assignments", target: nil, action: nil)
    private var snapshot = SC3SumoMappingSnapshot()

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "SkyController 3 · Native Sumo Controls"
        panel.isReleasedWhenClosed = false; panel.appearance = NSAppearance(named: .darkAqua)
        super.init(window: panel)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor)
        ])
        func label(_ text: String, bold: Bool = false) {
            let item = NSTextField(wrappingLabelWithString: text)
            item.font = .systemFont(ofSize: bold ? 13 : 12, weight: bold ? .semibold : .regular)
            root.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        }
        label("Native SC3 controls", bold: true)
        label("These assignments run on the controller. Mac keyboard and external gamepad mappings are separate.")
        for item in [current, status] {
            item.font = .systemFont(ofSize: 12); root.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        }
        reload.target = self; reload.action = #selector(reloadPressed); reload.isEnabled = false
        root.addArrangedSubview(reload)
        label("Candidate profile · changes are not applied automatically", bold: true)
        for popup in [drive, steer] {
            for axis in SC3SumoMappingAxis.allCases { popup.addItem(withTitle: axis.title); popup.lastItem?.tag = Int(axis.rawValue) }
        }
        for popup in [high, long] {
            for button in SC3SumoMappingButton.allCases { popup.addItem(withTitle: button.title); popup.lastItem?.tag = Int(button.rawValue) }
        }
        func row(_ title: String, _ control: NSView) {
            let text = NSTextField(labelWithString: title); text.font = .systemFont(ofSize: 12)
            text.widthAnchor.constraint(equalToConstant: 130).isActive = true
            let stack = NSStackView(views: [text, control]); stack.spacing = 10
            root.addArrangedSubview(stack)
            stack.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            control.setAccessibilityLabel(title)
        }
        row("Drive source", drive); row("Steering source", steer)
        root.addArrangedSubview(NSStackView(views: [invertDrive, invertSteer]))
        row("Drive deadzone", driveDeadzone); row("Steering deadzone", steerDeadzone)
        row("Drive range", driveRange); row("Steering range", steerRange)
        row("High jump", high); row("Long jump", long)
        for control in [drive, steer, high, long, invertDrive, invertSteer, driveDeadzone, steerDeadzone, driveRange, steerRange] as [NSControl] {
            control.target = self; control.action = #selector(candidateChanged)
        }
        validation.font = .systemFont(ofSize: 12); root.addArrangedSubview(validation)
        validation.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        apply.target = self; apply.action = #selector(applyPressed)
        let defaults = NSButton(title: "Use v1c defaults", target: self, action: #selector(defaultsPressed))
        let save = NSButton(title: "Save candidate…", target: self, action: #selector(savePressed))
        let load = NSButton(title: "Open candidate…", target: self, action: #selector(loadPressed))
        root.addArrangedSubview(NSStackView(views: [apply, defaults, save, load]))
        label("Only logical axes and the two existing jump actions are represented. Physical button remapping and ANAFI profiles are not changed.")
        panel.minSize = NSSize(width: 650, height: 680); panel.center()
        fill(.defaults); refresh(snapshot)
    }
    required init?(coder: NSCoder) { nil }

    func refresh(_ state: SC3SumoMappingSnapshot) {
        if state.generation != snapshot.generation || state.appliedProfile != snapshot.appliedProfile {
            fill(state.appliedProfile ?? .defaults)
        }
        snapshot = state; status.stringValue = state.message
        let profile = state.appliedProfile ?? .defaults
        current.stringValue = "\(state.appliedProfile == nil ? "Known v1c defaults · not read back" : "Controller readback")\nDrive: \(profile.driveAxis.title) · steering: \(profile.steeringAxis.title)\nHIGH: \(profile.highJump.title) · LONG: \(profile.longJump.title)"
        candidateChanged()
    }

    private func fill(_ profile: SC3SumoMappingProfile) {
        drive.selectItem(withTag: Int(profile.driveAxis.rawValue)); steer.selectItem(withTag: Int(profile.steeringAxis.rawValue))
        high.selectItem(withTag: Int(profile.highJump.rawValue)); long.selectItem(withTag: Int(profile.longJump.rawValue))
        invertDrive.state = profile.invertDrive ? .on : .off; invertSteer.state = profile.invertSteering ? .on : .off
        driveDeadzone.integerValue = Int(profile.driveDeadzone); steerDeadzone.integerValue = Int(profile.steeringDeadzone)
        driveRange.integerValue = Int(profile.driveRange); steerRange.integerValue = Int(profile.steeringRange)
    }

    private func candidate() throws -> SC3SumoMappingProfile {
        var profile = SC3SumoMappingProfile()
        guard let driveAxis = SC3SumoMappingAxis(rawValue: UInt8(clamping: drive.selectedTag())),
              let steering = SC3SumoMappingAxis(rawValue: UInt8(clamping: steer.selectedTag())),
              let highJump = SC3SumoMappingButton(rawValue: UInt8(clamping: high.selectedTag())),
              let longJump = SC3SumoMappingButton(rawValue: UInt8(clamping: long.selectedTag())) else {
            throw SC3SumoMappingProfile.Invalid.packet
        }
        profile.driveAxis = driveAxis; profile.steeringAxis = steering
        profile.highJump = highJump; profile.longJump = longJump
        profile.invertDrive = invertDrive.state == .on; profile.invertSteering = invertSteer.state == .on
        profile.driveDeadzone = UInt8(clamping: driveDeadzone.integerValue); profile.steeringDeadzone = UInt8(clamping: steerDeadzone.integerValue)
        profile.driveRange = UInt8(clamping: driveRange.integerValue); profile.steeringRange = UInt8(clamping: steerRange.integerValue)
        try profile.validate(); return profile
    }

    @objc private func candidateChanged() {
        do {
            let profile = try candidate()
            validation.stringValue = "Deadzone \(profile.driveDeadzone)% / \(profile.steeringDeadzone)% · range \(profile.driveRange)% / \(profile.steeringRange)%"
            validation.textColor = .secondaryLabelColor
            apply.isEnabled = snapshot.canApply && snapshot.appliedProfile != nil && onApply != nil && profile != snapshot.appliedProfile
        } catch {
            validation.stringValue = error.localizedDescription; validation.textColor = .systemOrange; apply.isEnabled = false
        }
    }

    @objc private func reloadPressed() { onReload?() }
    @objc private func defaultsPressed() { fill(.defaults); candidateChanged() }
    @objc private func applyPressed() {
        guard snapshot.canApply, snapshot.appliedProfile != nil, let profile = try? candidate() else { return }
        apply.isEnabled = false
        onApply?(profile, snapshot.generation)
    }
    @objc private func savePressed() {
        guard let profile = try? candidate() else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Sumo-native-candidate.sc3sumomap"
        panel.message = "Save a validated candidate. This does not apply it to the controller."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SC3SumoMappingDraftStore.save(profile, to: url)
            status.stringValue = "Candidate saved locally. Controller assignments are unchanged."
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func loadPressed() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            fill(try SC3SumoMappingDraftStore.load(url)); candidateChanged()
            status.stringValue = "Candidate opened locally. Controller assignments are unchanged."
        } catch { status.stringValue = error.localizedDescription }
    }
}

enum SC3SumoMappingSelfTest {
    static func run() -> Bool {
        do {
            let defaults = SC3SumoMappingProfile.defaults
            let packet = try defaults.packet()
            guard packet == Data([0x53, 0x4d, 0x43, 0x32, 1, 2, 1, 0, 0, 0, 100, 100, 17, 16, 0xe4, 0x47]),
                  try SC3SumoMappingProfile(packet: packet) == defaults else { return false }
            for length in 0..<16 {
                do { _ = try SC3SumoMappingProfile(packet: packet.prefix(length)); return false } catch {}
            }
            do { _ = try SC3SumoMappingProfile(packet: packet + Data([0])); return false } catch {}
            for index in 0..<16 {
                var corrupt = packet; corrupt[index] ^= 1
                do { _ = try SC3SumoMappingProfile(packet: corrupt); return false } catch {}
            }
            for roll in stride(from: -128, through: 127, by: 7) {
                for pitch in stride(from: -128, through: 127, by: 9) {
                    let output = try defaults.output(axes: [roll, pitch, 127, -128])
                    guard output.drive == max(-100, min(100, pitch)), output.steering == max(-100, min(100, roll)) else { return false }
                }
            }
            var candidate = defaults; candidate.invertDrive = true; candidate.driveDeadzone = 20; candidate.driveRange = 40
            guard try candidate.output(axes: [0, 20, 0, 0]).drive == 0,
                  try candidate.output(axes: [0, 100, 0, 0]).drive == -40,
                  try candidate.output(axes: [0, -128, 0, 0]).drive == 40,
                  try SC3SumoMappingProfile(packet: candidate.packet()) == candidate else { return false }
            candidate.highJump = .returnHome
            do { _ = try candidate.packet(); return false } catch {}
            candidate.highJump = .disabled; candidate.longJump = .disabled
            _ = try candidate.packet()
            candidate.driveAxis = candidate.steeringAxis
            do { _ = try candidate.packet(); return false } catch {}
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ParrotLab-SC3Mapping-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("candidate.sc3sumomap")
            try SC3SumoMappingDraftStore.save(defaults, to: url)
            candidate = defaults; candidate.steeringRange = 33
            try SC3SumoMappingDraftStore.save(candidate, to: url)
            guard try SC3SumoMappingDraftStore.load(url) == candidate,
                  try SC3SumoMappingDraftStore.restorePrevious(at: url) == defaults,
                  try SC3SumoMappingDraftStore.load(url) == defaults else { return false }
            // A bad local candidate must not replace a good file or its backup.
            let before = try Data(contentsOf: url)
            let backupBefore = try Data(contentsOf: url.appendingPathExtension("previous"))
            candidate.driveRange = 0
            do { try SC3SumoMappingDraftStore.save(candidate, to: url); return false } catch {}
            guard try Data(contentsOf: url) == before,
                  try Data(contentsOf: url.appendingPathExtension("previous")) == backupBefore else { return false }
            let oversized = folder.appendingPathComponent("oversized.sc3sumomap")
            try (packet + Data(repeating: 0, count: 4096)).write(to: oversized)
            do { _ = try SC3SumoMappingDraftStore.load(oversized); return false } catch {}
            return true
        } catch { return false }
    }
}
