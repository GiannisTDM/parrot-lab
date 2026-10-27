import AppKit
import QuartzCore

enum LabThemeMode {
    case air
    case ground
    case miniDrone
}

/// Short, user-triggered transitions only. Never animate telemetry or video frames.
enum LabMotion {
    static let workspaceDuration: TimeInterval = 0.26
    private static let revealAnimationKey = "lab.reveal"
    private static let workspaceFadeKey = "lab.workspace.fade"
    private static let workspaceSettleKey = "lab.workspace.settle"

    static func duration(for view: NSView) -> TimeInterval {
        duration(isVisible: view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor,
                 reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private static func duration(isVisible: Bool, reduceMotion: Bool) -> TimeInterval {
        isVisible && !reduceMotion ? 0.16 : 0
    }

    static func layout(in view: NSView, changes: () -> Void) {
        let root = view.window?.contentView ?? view
        root.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration(for: view)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = context.duration > 0
            changes()
            root.layoutSubtreeIfNeeded()
        }
    }

    static func reveal(_ view: NSView) {
        let interval = duration(for: view)
        guard interval > 0 else {
            cancelReveal(view)
            return
        }
        view.wantsLayer = true
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = view.layer?.animation(forKey: revealAnimationKey) != nil
            ? (view.layer?.presentation()?.opacity ?? 0) : 0
        animation.toValue = view.layer?.opacity ?? 1
        animation.duration = interval
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // The model remains fully visible, including after rapid repeated toggles.
        view.layer?.add(animation, forKey: revealAnimationKey)
    }

    fileprivate static func cancelReveal(_ view: NSView) {
        view.layer?.removeAnimation(forKey: revealAnimationKey)
    }

    private static func cancelWorkspaceTransition(_ view: NSView) {
        view.layer?.removeAnimation(forKey: workspaceFadeKey)
        view.layer?.removeAnimation(forKey: workspaceSettleKey)
    }

    /// Crossfade only interface chrome, never a captured or frozen video surface.
    /// Model state changes synchronously so controls remain correct mid-transition.
    static func workspace(in root: NSView, chrome: [NSView], enteringGround: Bool,
                          changes: () -> Void) {
        guard duration(for: root) > 0 else {
            // A new synchronous change must also stop an earlier transition,
            // including when Reduce Motion was enabled during that transition.
            chrome.forEach(cancelWorkspaceTransition)
            changes()
            root.layoutSubtreeIfNeeded()
            return
        }
        root.layoutSubtreeIfNeeded()
        let visibleChrome = chrome.filter { !$0.isHiddenOrHasHiddenAncestor }
        chrome.filter { $0.isHiddenOrHasHiddenAncestor }.forEach(cancelWorkspaceTransition)
        for panel in visibleChrome {
            panel.wantsLayer = true
            let dissolve = CATransition()
            dissolve.type = .fade
            dissolve.duration = workspaceDuration
            dissolve.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.layer?.add(dissolve, forKey: workspaceFadeKey)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = workspaceDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            changes()
            root.layoutSubtreeIfNeeded()
        }
        for panel in visibleChrome {
            let settle = CABasicAnimation(keyPath: "transform.translation.y")
            let direction: CGFloat = enteringGround ? -1 : 1
            settle.fromValue = panel.layer?.animation(forKey: workspaceSettleKey) != nil
                ? panel.layer?.presentation()?.value(forKeyPath: "transform.translation.y")
                : direction * 5
            settle.toValue = 0
            settle.duration = workspaceDuration
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.layer?.add(settle, forKey: workspaceSettleKey)
        }
    }

    static func theme(_ layer: CALayer, key: String, value: Any, in view: NSView) {
        let previous = (layer.presentation() ?? layer).value(forKeyPath: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
        let animationKey = "lab.theme.\(key)"
        layer.removeAnimation(forKey: animationKey)
        guard let previous, duration(for: view) > 0 else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = previous
        animation.toValue = value
        animation.duration = workspaceDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: animationKey)
    }

    /// No clock or visible window is required: verify final model state and
    /// cleanup when an interrupted transition must become synchronous.
    static func selfTest() -> Bool {
        _ = NSApplication.shared
        guard duration(isVisible: true, reduceMotion: false) == 0.16,
              duration(isVisible: true, reduceMotion: true) == 0,
              duration(isVisible: false, reduceMotion: false) == 0 else { return false }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let panel = NSView(frame: root.bounds)
        root.addSubview(panel)
        panel.wantsLayer = true
        guard let layer = panel.layer else { return false }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 30
        layer.add(animation, forKey: revealAnimationKey)
        layer.add(animation, forKey: "unrelated")
        reveal(panel)
        guard layer.animation(forKey: revealAnimationKey) == nil,
              layer.animation(forKey: "unrelated") != nil else { return false }
        layer.add(animation, forKey: workspaceFadeKey)
        layer.add(animation, forKey: workspaceSettleKey)
        var changed = false
        workspace(in: root, chrome: [panel], enteringGround: true) { changed = true }
        guard changed, layer.animation(forKey: workspaceFadeKey) == nil,
              layer.animation(forKey: workspaceSettleKey) == nil,
              layer.animation(forKey: "unrelated") != nil else { return false }
        layer.add(animation, forKey: "lab.theme.opacity")
        theme(layer, key: "opacity", value: Float(0.8), in: panel)
        guard layer.opacity == 0.8, layer.animation(forKey: "lab.theme.opacity") == nil else { return false }
        return LabDisclosureButton.transitionSelfTest()
    }
}

enum LabVisualStyle {
    private static let airAccent = NSColor(srgbRed: 0.30, green: 0.86, blue: 0.62, alpha: 1)
    private static let groundAccent = NSColor(srgbRed: 0.94, green: 0.64, blue: 0.39, alpha: 1)
    private(set) static var themeMode = LabThemeMode.air

    static var accent: NSColor {
        if themeMode == .miniDrone { return NSColor(srgbRed: 0.75, green: 0.65, blue: 0.96, alpha: 1) }
        return themeMode == .ground ? groundAccent : airAccent
    }
    static var panel: NSColor {
        if themeMode == .miniDrone { return NSColor(srgbRed: 0.105, green: 0.088, blue: 0.14, alpha: 1) }
        return themeMode == .ground
            ? NSColor(srgbRed: 0.108, green: 0.094, blue: 0.082, alpha: 1)
            : NSColor(srgbRed: 0.075, green: 0.085, blue: 0.09, alpha: 1)
    }
    static var raisedPanel: NSColor {
        if themeMode == .miniDrone { return NSColor(srgbRed: 0.15, green: 0.12, blue: 0.195, alpha: 1) }
        return themeMode == .ground
            ? NSColor(srgbRed: 0.15, green: 0.124, blue: 0.103, alpha: 1)
            : NSColor(srgbRed: 0.11, green: 0.125, blue: 0.13, alpha: 1)
    }
    static let border = NSColor.white.withAlphaComponent(0.09)
    static let mutedText = NSColor.white.withAlphaComponent(0.59)

    static var backgroundColors: [CGColor] {
        if themeMode == .miniDrone {
            return [NSColor(srgbRed: 0.06, green: 0.04, blue: 0.095, alpha: 1).cgColor,
                    NSColor(srgbRed: 0.095, green: 0.065, blue: 0.145, alpha: 1).cgColor,
                    NSColor(srgbRed: 0.045, green: 0.03, blue: 0.07, alpha: 1).cgColor]
        }
        if themeMode == .ground {
            return [
                NSColor(srgbRed: 0.055, green: 0.037, blue: 0.025, alpha: 1).cgColor,
                NSColor(srgbRed: 0.095, green: 0.060, blue: 0.035, alpha: 1).cgColor,
                NSColor(srgbRed: 0.040, green: 0.027, blue: 0.020, alpha: 1).cgColor
            ]
        }
        return [
            NSColor(srgbRed: 0.035, green: 0.045, blue: 0.05, alpha: 1).cgColor,
            NSColor(srgbRed: 0.045, green: 0.055, blue: 0.06, alpha: 1).cgColor,
            NSColor(srgbRed: 0.025, green: 0.035, blue: 0.04, alpha: 1).cgColor
        ]
    }

    static func applyTheme(_ mode: LabThemeMode, to root: NSView) {
        let previousAccent = accent
        themeMode = mode
        recolor(root, replacing: previousAccent)
    }

    private static func recolor(_ view: NSView, replacing previousAccent: NSColor) {
        if let panel = view as? LabPanelView { panel.refreshTheme() }
        if let background = view as? LabBackgroundView { background.refreshTheme() }
        if let background = view as? LabFlippedBackgroundView { background.refreshTheme() }
        if let label = view as? NSTextField, label.textColor?.isEqual(previousAccent) == true {
            label.textColor = accent
        }
        if let button = view as? NSButton {
            if button.contentTintColor?.isEqual(previousAccent) == true { button.contentTintColor = accent }
            if button.bezelColor?.isEqual(previousAccent) == true { button.bezelColor = accent }
        }
        if let slider = view as? NSSlider { slider.trackFillColor = accent }
        view.needsDisplay = true
        view.layer?.setNeedsDisplay()
        view.subviews.forEach { recolor($0, replacing: previousAccent) }
    }

    static func brandIcon() -> NSImage? {
        let candidates = [
            Bundle.main.url(forResource: "ParrotLabIcon", withExtension: "png"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/ParrotLabIcon.png")
        ]
        return candidates.compactMap { $0 }.lazy.compactMap(NSImage.init(contentsOf:)).first
    }
}

final class LabBackgroundView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradient.colors = LabVisualStyle.backgroundColors
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer = gradient
    }

    required init?(coder: NSCoder) { nil }

    func refreshTheme() {
        LabMotion.theme(gradient, key: "colors", value: LabVisualStyle.backgroundColors, in: self)
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }
}

final class LabPanelView: NSView {
    private var emphasized = false

    init(emphasized: Bool = false, cornerRadius: CGFloat = 14) {
        self.emphasized = emphasized
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = (emphasized ? LabVisualStyle.raisedPanel : LabVisualStyle.panel).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = LabVisualStyle.border.cgColor
    }

    required init?(coder: NSCoder) { nil }

    func refreshTheme() {
        if let layer {
            LabMotion.theme(layer, key: "backgroundColor",
                            value: (emphasized ? LabVisualStyle.raisedPanel : LabVisualStyle.panel).cgColor, in: self)
        }
        layer?.borderColor = LabVisualStyle.border.cgColor
    }
}

/// A small disclosure control that keeps native keyboard and accessibility behavior.
final class LabDisclosureButton: NSButton {
    private let label: String
    private let contentViews: [NSView]
    private(set) var expanded: Bool

    init(title: String, views: [NSView], expanded: Bool = false) {
        label = title
        contentViews = views
        self.expanded = expanded
        super.init(frame: .zero)
        target = self
        action = #selector(toggleDisclosure)
        isBordered = false
        alignment = .left
        font = .systemFont(ofSize: 11, weight: .semibold)
        contentTintColor = LabVisualStyle.mutedText
        imagePosition = .imageLeading
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func toggleDisclosure() {
        LabMotion.layout(in: self) {
            expanded.toggle()
            refresh()
        }
        if expanded { contentViews.forEach { LabMotion.reveal($0) } }
    }

    private func refresh() {
        title = label
        image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        contentViews.forEach {
            $0.isHidden = !expanded
            if !expanded { LabMotion.cancelReveal($0) }
        }
        setAccessibilityLabel(label)
        setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
    }

    fileprivate static func transitionSelfTest() -> Bool {
        let content = NSView()
        content.wantsLayer = true
        let button = LabDisclosureButton(title: "Camera options", views: [content])
        guard !button.expanded, content.isHidden else { return false }
        for _ in 0..<20 {
            button.toggleDisclosure()
            guard button.expanded, !content.isHidden else { return false }
            let interruptedReveal = CABasicAnimation(keyPath: "opacity")
            interruptedReveal.fromValue = 0
            interruptedReveal.toValue = 1
            interruptedReveal.duration = 30
            content.layer?.add(interruptedReveal, forKey: "lab.reveal")
            button.toggleDisclosure()
            guard !button.expanded, content.isHidden,
                  content.layer?.animation(forKey: "lab.reveal") == nil else { return false }
        }
        return true
    }
}

/// Two large, readable values with a single contextual line underneath.
final class LabMetricPairView: NSView {
    private let leftCaption = NSTextField(labelWithString: "")
    private let rightCaption = NSTextField(labelWithString: "")
    private let leftValue = NSTextField(labelWithString: "—")
    private let rightValue = NSTextField(labelWithString: "—")
    private let detail = NSTextField(labelWithString: "Waiting for connection")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 274).isActive = true
        heightAnchor.constraint(equalToConstant: 83).isActive = true
        for caption in [leftCaption, rightCaption] {
            caption.font = .systemFont(ofSize: 9, weight: .semibold)
            caption.textColor = LabVisualStyle.mutedText
        }
        for value in [leftValue, rightValue] {
            value.font = .monospacedDigitSystemFont(ofSize: 24, weight: .medium)
            value.textColor = .white
        }
        detail.font = .systemFont(ofSize: 10.5, weight: .regular)
        detail.textColor = LabVisualStyle.mutedText
        detail.lineBreakMode = .byTruncatingTail
        for field in [leftCaption, rightCaption, leftValue, rightValue, detail] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            leftCaption.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftCaption.topAnchor.constraint(equalTo: topAnchor),
            rightCaption.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 8),
            rightCaption.topAnchor.constraint(equalTo: topAnchor),
            leftValue.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftValue.topAnchor.constraint(equalTo: leftCaption.bottomAnchor, constant: 5),
            leftValue.trailingAnchor.constraint(lessThanOrEqualTo: centerXAnchor),
            rightValue.leadingAnchor.constraint(equalTo: rightCaption.leadingAnchor),
            rightValue.topAnchor.constraint(equalTo: leftValue.topAnchor),
            rightValue.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: leftValue.bottomAnchor, constant: 8)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(left: String, value: String, right: String, otherValue: String, detail text: String, color: NSColor = .white) {
        // Telemetry calls this frequently; unchanged text should not invalidate
        // AppKit's layout while the video is being presented.
        if leftCaption.stringValue != left { leftCaption.stringValue = left }
        if leftValue.stringValue != value { leftValue.stringValue = value }
        if leftValue.textColor?.isEqual(color) != true { leftValue.textColor = color }
        if rightCaption.stringValue != right { rightCaption.stringValue = right }
        if rightValue.stringValue != otherValue { rightValue.stringValue = otherValue }
        if detail.stringValue != text {
            detail.stringValue = text
            detail.toolTip = text
        }
    }
}

final class LabFlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class LabFlippedBackgroundView: NSView {
    private let gradient = CAGradientLayer()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradient.colors = LabVisualStyle.backgroundColors
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer = gradient
    }

    required init?(coder: NSCoder) { nil }

    func refreshTheme() {
        LabMotion.theme(gradient, key: "colors", value: LabVisualStyle.backgroundColors, in: self)
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }
}

/// AppKit's frameless text-field cell pins its text to the top when the view
/// is taller than the font. Keep both display and field-editor rectangles on
/// the optical vertical center used by the surrounding buttons and popups.
final class LabVerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        let naturalSize = cellSize(forBounds: rect)
        let excessHeight = drawingRect.height - naturalSize.height
        if excessHeight > 0 {
            drawingRect.origin.y += floor(excessHeight / 2)
            drawingRect.size.height -= excessHeight
        }
        return drawingRect
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}
