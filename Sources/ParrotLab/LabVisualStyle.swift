import AppKit
import QuartzCore

enum LabVisualStyle {
    static let accent = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.96, alpha: 1)
    static let panel = NSColor(srgbRed: 0.075, green: 0.095, blue: 0.12, alpha: 0.96)
    static let raisedPanel = NSColor(srgbRed: 0.09, green: 0.12, blue: 0.15, alpha: 0.98)
    static let border = NSColor.white.withAlphaComponent(0.09)
    static let mutedText = NSColor.white.withAlphaComponent(0.48)

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
        gradient.colors = [
            NSColor(srgbRed: 0.025, green: 0.035, blue: 0.05, alpha: 1).cgColor,
            NSColor(srgbRed: 0.045, green: 0.065, blue: 0.085, alpha: 1).cgColor,
            NSColor(srgbRed: 0.025, green: 0.03, blue: 0.04, alpha: 1).cgColor
        ]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer = gradient
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }
}

final class LabPanelView: NSView {
    init(emphasized: Bool = false, cornerRadius: CGFloat = 14) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = (emphasized ? LabVisualStyle.raisedPanel : LabVisualStyle.panel).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = LabVisualStyle.border.cgColor
    }

    required init?(coder: NSCoder) { nil }
}

final class LabFlippedView: NSView {
    override var isFlipped: Bool { true }
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
