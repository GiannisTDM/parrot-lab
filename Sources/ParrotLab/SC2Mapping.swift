import AppKit

// Protocol authority: Parrot-Developers/arsdk-xml/xml/mapper.xml, feature 138.
// Physical IDs: captured SC2 /etc/mppd/mapping_bebop_2.cfg. Never grab sticks
// or change co-piloting ownership to implement these controller-side mappings.
enum SC2MappingKind: UInt16, Hashable {
    case button = 7, axis = 8, inversion = 15
}

struct SC2MappingEntry: Equatable {
    let kind: SC2MappingKind
    let uid: UInt32
    let product: UInt16
    let action: UInt32
    let axis: Int32
    let buttons: UInt32
    let inverted: Bool
    let flags: UInt8
}

enum SC2MappingEvent: Equatable {
    case activeProduct(UInt16)
    case entry(SC2MappingEntry)
}

enum SC2MappingChange: Equatable {
    case button(action: UInt32, buttons: UInt32)
    case axis(action: UInt32, axis: Int32, buttons: UInt32)
    case inversion(axis: Int32, inverted: Bool)

    func matches(_ entry: SC2MappingEntry) -> Bool {
        guard entry.flags & 4 == 0 else { return false }
        if entry.flags & 8 != 0 {
            switch self {
            case let .button(action, buttons): return entry.kind == .button && entry.action == action && buttons == 0
            case let .axis(action, axis, _): return entry.kind == .axis && entry.action == action && axis == -1
            case .inversion: return false
            }
        }
        switch self {
        case let .button(action, buttons):
            return entry.kind == .button && entry.action == action && entry.buttons == buttons
        case let .axis(action, axis, buttons):
            return entry.kind == .axis && entry.action == action && entry.axis == axis && entry.buttons == buttons
        case let .inversion(axis, inverted):
            return entry.kind == .inversion && entry.axis == axis && entry.inverted == inverted
        }
    }
}

enum SC2MappingProtocol {
    static func command(product: UInt16, change: SC2MappingChange) -> Data? {
        // Zero means all products for some mapper commands: never emit it.
        guard [0x0901, 0x0902, 0x090c].contains(product) else { return nil }
        var payload: Data
        switch change {
        case let .button(action, buttons):
            guard action <= 36, buttons & 0x80 == 0 else { return nil } // START is not mappable.
            payload = Data([138, 0, 5, 0]); append(product, to: &payload)
            append(action, to: &payload); append(buttons, to: &payload)
        case let .axis(action, axis, buttons):
            guard action <= 22, (-1...4).contains(axis), buttons & 0x80 == 0 else { return nil }
            payload = Data([138, 0, 6, 0]); append(product, to: &payload)
            append(action, to: &payload); append(UInt32(bitPattern: axis), to: &payload)
            append(buttons, to: &payload)
        case let .inversion(axis, inverted):
            guard (0...4).contains(axis) else { return nil }
            payload = Data([138, 0, 14, 0]); append(product, to: &payload)
            append(UInt32(bitPattern: axis), to: &payload); payload.append(inverted ? 1 : 0)
        }
        return payload
    }

    static func decode(_ bytes: Data) -> SC2MappingEvent? {
        let b = Array(bytes)
        guard b.count >= 4, b[0] == 138, b[1] == 0, b[3] == 0 else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 {
            UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        }
        if b[2] == 16, b.count == 6 { return .activeProduct(u16(4)) }
        guard let kind = SC2MappingKind(rawValue: UInt16(b[2])) else { return nil }
        let length = kind == .button ? 19 : (kind == .axis ? 23 : 16)
        guard b.count == length else { return nil }
        let flags = b[length - 1]
        if kind == .inversion, flags & 4 == 0, b[14] > 1 { return nil }
        return .entry(SC2MappingEntry(kind: kind, uid: u32(4), product: u16(8),
            action: u32(10), axis: kind == .axis ? Int32(bitPattern: u32(14)) : (kind == .inversion ? Int32(bitPattern: u32(10)) : -1),
            buttons: kind == .button ? u32(14) : (kind == .axis ? u32(18) : 0),
            inverted: kind == .inversion && b[14] == 1, flags: flags))
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    static func selfTest() -> Bool {
        guard command(product: 0x090c, change: .axis(action: 17, axis: 3, buttons: 0)) == Data([138,0,6,0,12,9,17,0,0,0,3,0,0,0,0,0,0,0]),
              command(product: 0x0901, change: .button(action: 0, buttons: 2)) == Data([138,0,5,0,1,9,0,0,0,0,2,0,0,0]),
              command(product: 0x0902, change: .inversion(axis: 1, inverted: true)) == Data([138,0,14,0,2,9,1,0,0,0,1]),
              command(product: 0, change: .inversion(axis: 1, inverted: true)) == nil,
              command(product: 0x0901, change: .button(action: 0, buttons: 128)) == nil,
              decode(Data([138,0,16,0,1,9])) == .activeProduct(0x0901) else { return false }
        let packet = Data([138,0,8,0,1,0,0,0,1,9,17,0,0,0,3,0,0,0,0,0,0,0,3])
        guard case let .entry(entry) = decode(packet),
              SC2MappingChange.axis(action: 17, axis: 3, buttons: 0).matches(entry) else { return false }
        for count in 0..<packet.count { if decode(packet.prefix(count)) != nil { return false } }
        var state = SC2MappingState()
        state.consume(.activeProduct(0x0901)); state.consume(.entry(entry))
        guard state.entry(.axis, action: 17)?.axis == 3, state.completed.contains(.axis) else { return false }
        var removed = Array(packet); removed[22] = 8
        guard let removal = decode(Data(removed)) else { return false }
        state.consume(removal)
        guard case let .entry(tombstone) = removal,
              SC2MappingChange.axis(action: 17, axis: -1, buttons: 0).matches(tombstone),
              !SC2MappingChange.axis(action: 17, axis: 3, buttons: 0).matches(tombstone) else { return false }
        return state.entry(.axis, action: 17) == nil && !SC2MappingChange.button(action: 0, buttons: 1).matches(entry)
    }
}

struct SC2MappingState: Equatable {
    var activeProduct: UInt16?
    var entries: [SC2MappingKind: [UInt32: SC2MappingEntry]] = [:]
    var completed: Set<SC2MappingKind> = []

    mutating func consume(_ event: SC2MappingEvent) {
        switch event {
        case let .activeProduct(product): activeProduct = product
        case let .entry(item):
            if item.flags & 1 != 0 { entries[item.kind] = [:]; completed.remove(item.kind) }
            if item.flags & 4 != 0 { entries[item.kind] = [:] }
            else if item.flags & 8 != 0 { entries[item.kind]?.removeValue(forKey: item.uid) }
            else { entries[item.kind, default: [:]][item.uid] = item }
            if item.flags & 6 != 0 { completed.insert(item.kind) }
        }
    }

    func entry(_ kind: SC2MappingKind, action: UInt32) -> SC2MappingEntry? {
        entries[kind]?.values.first { $0.product == activeProduct && $0.action == action }
    }
    var ready: Bool { activeProduct != nil && completed.isSuperset(of: [.axis, .button, .inversion]) }
    var hasActiveAssignments: Bool {
        [SC2MappingKind.axis, .button].contains { kind in
            entries[kind]?.values.contains { $0.product == activeProduct } == true
        }
    }
}

/// Edits SC2's own mapper, distinct from Mac keyboard/GameController mappings.
final class SC2MappingWindowController: NSWindowController {
    var onReload: (() -> Void)?
    var onChange: ((SC2MappingChange) -> Void)?
    private let status = NSTextField(wrappingLabelWithString: "Connect through a SkyController 2, then Reload.")
    private let rows = NSStackView()
    private var changes: [ObjectIdentifier: (NSPopUpButton) -> SC2MappingChange?] = [:]
    private var lastState: SC2MappingState?
    private var lastGround = false
    private var lastEnabled = false

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 550, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "SkyController 2 · Stick & Button Mapping"
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        super.init(window: panel)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = LabBackgroundView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView?.appearance = NSAppearance(named: .darkAqua)
        panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
        ])
        status.font = .systemFont(ofSize: 12); status.maximumNumberOfLines = 5
        root.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        root.addArrangedSubview(NSButton(title: "Reload from SC2", target: self, action: #selector(reload)))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = LabFlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 10; rows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows); scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor), rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor), rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        panel.minSize = NSSize(width: 550, height: 600); panel.center()
    }
    required init?(coder: NSCoder) { nil }
    @objc private func reload() { onReload?() }
    @objc private func selected(_ sender: NSPopUpButton) {
        if let change = changes[ObjectIdentifier(sender)]?(sender) { onChange?(change) }
    }

    func refresh(state: SC2MappingState, ground: Bool, enabled: Bool, message: String) {
        status.stringValue = message
        guard state != lastState || ground != lastGround || enabled != lastEnabled else { return }
        lastState = state; lastGround = ground; lastEnabled = enabled
        for child in rows.arrangedSubviews { rows.removeArrangedSubview(child); child.removeFromSuperview() }
        changes.removeAll()
        func heading(_ text: String) {
            let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 13, weight: .semibold)
            rows.addArrangedSubview(label)
        }
        func picker(_ title: String, choices: [(String, Int)], current: Int,
                    change: @escaping (Int) -> SC2MappingChange) {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 190).isActive = true
            let popup = NSPopUpButton(); popup.widthAnchor.constraint(equalToConstant: 280).isActive = true
            var options = choices
            if !options.contains(where: { $0.1 == current }) { options.append(("Existing combination / ID \(current)", current)) }
            for option in options { popup.addItem(withTitle: option.0); popup.lastItem?.tag = option.1 }
            popup.selectItem(withTag: current); popup.isEnabled = enabled
            popup.target = self; popup.action = #selector(selected(_:))
            popup.setAccessibilityLabel(title)
            changes[ObjectIdentifier(popup)] = { change($0.selectedTag()) }
            row.addArrangedSubview(label); row.addArrangedSubview(popup); rows.addArrangedSubview(row)
        }
        heading("Sticks — applies immediately on the SC2")
        let axisChoices = [("Unmapped", -1), ("Left stick · horizontal", 0), ("Left stick · vertical", 1),
                           ("Right stick · horizontal", 2), ("Right stick · vertical", 3), ("Camera wheel", 4)]
        let axes: [(UInt32, String)] = ground ? [(17, "Forward / reverse"), (16, "Steering")]
            : [(16, "Roll"), (17, "Pitch"), (18, "Yaw"), (19, "Throttle / gaz"), (20, "Camera pan"), (21, "Camera tilt")]
        for (action, name) in axes {
            let existing = state.entry(.axis, action: action)
            let buttons = existing?.buttons ?? 0
            picker(name + (buttons == 0 ? "" : " + modifier"), choices: axisChoices, current: Int(existing?.axis ?? -1)) {
                .axis(action: action, axis: Int32($0), buttons: buttons)
            }
        }
        heading("Physical axis direction")
        for (name, axis) in axisChoices where axis >= 0 {
            let current = state.entry(.inversion, action: UInt32(axis))?.inverted == true ? 1 : 0
            picker(name, choices: [("Normal", 0), ("Inverted", 1)], current: current) {
                .inversion(axis: Int32(axis), inverted: $0 == 1)
            }
        }
        heading("Buttons")
        let buttons = [("Unmapped", 0), ("A", 1), ("B · Home", 2), ("C · Takeoff / land", 4),
                       ("X · Record", 8), ("Y · Picture", 16), ("L1", 32), ("R1", 64),
                       ("Left stick click", 256), ("Right stick click", 512), ("L2", 1024), ("R2", 2048)]
        let actions: [(UInt32, String)] = ground ? [(0, "High jump"), (16, "Long jump")]
            : [(17, "Takeoff / land"), (16, "Return home"), (18, "Drone video record"), (19, "Drone picture"),
               (27, "Center camera"), (26, "Emergency motor stop")]
        for (action, name) in actions {
            let current = Int(state.entry(.button, action: action)?.buttons ?? 0)
            // Emergency is intentionally not assigned automatically.
            picker(name, choices: buttons, current: current) { .button(action: action, buttons: UInt32($0)) }
        }
    }
}
