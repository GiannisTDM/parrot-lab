import AppKit

final class VideoHUDView: NSView {
    let videoView = H264VideoView(frame: .zero)
    let overlayView = HUDOverlayView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        videoView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        addSubview(overlayView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(snapshot: TelemetrySnapshot) {
        overlayView.snapshot = snapshot
    }

    func setGroundMode(_ enabled: Bool) {
        overlayView.isGroundMode = enabled
    }
}

final class HUDOverlayView: NSView {
    var subjectObservation: SumoSubjectObservation? { didSet { needsDisplay = true } }
    var subjectLabel = "Person" { didSet { needsDisplay = true } }
    var trackingPresentationState: SumoTrackingPresentationState = .idle { didSet { needsDisplay = true } }
    var clickSelectionEnabled = false {
        didSet { if clickSelectionEnabled != oldValue, !clickSelectionEnabled { cancelSubjectGesture() } }
    }
    var selectingSubject = false {
        didSet {
            if selectingSubject != oldValue { cancelSubjectGesture() }
        }
    }
    var selectionFrameSize = CGSize.zero {
        didSet {
            if selectionFrameSize != oldValue {
                cancelSubjectGesture()
            }
            needsDisplay = true
        }
    }
    var onBeginSubjectInteraction: (() -> Void)?
    var onSelectSubject: ((CGRect) -> Void)?
    var onClickSubject: ((CGPoint) -> Void)?
    private var selectionStart: CGPoint?
    private var selectionEnd: CGPoint?
    private var selectionMoved = false
    var isGroundMode = false {
        didSet {
            if !isGroundMode { cancelSubjectGesture() }
            needsDisplay = true
        }
    }
    var snapshot = TelemetrySnapshot() {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }
    private var acceptsSubjectGesture: Bool { selectingSubject || (clickSelectionEnabled && isGroundMode) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsSubjectGesture, !isHidden, alphaValue > 0,
              let imageRect = Self.imageRect(in: bounds, frameSize: selectionFrameSize),
              imageRect.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { cancelSubjectGesture() }
        super.setFrameSize(newSize)
    }

    override func mouseDown(with event: NSEvent) {
        beginSubjectGesture(at: convert(event.locationInWindow, from: nil))
    }

    private func beginSubjectGesture(at point: CGPoint) {
        cancelSubjectGesture()
        guard acceptsSubjectGesture,
              let imageRect = Self.imageRect(in: bounds, frameSize: selectionFrameSize) else { return }
        guard imageRect.contains(point) else { return }
        selectionStart = point
        selectionEnd = point
        needsDisplay = true
        // Stop any active following before a drag can hold the old target's
        // motion command. A callback may disable selection, so do not restore
        // gesture state after calling it.
        onBeginSubjectInteraction?()
    }

    override func mouseDragged(with event: NSEvent) {
        updateSubjectGesture(at: convert(event.locationInWindow, from: nil))
    }

    private func updateSubjectGesture(at point: CGPoint) {
        guard acceptsSubjectGesture, let start = selectionStart else { return }
        selectionEnd = point
        if hypot(point.x - start.x, point.y - start.y) > 6 { selectionMoved = true }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        finishSubjectGesture(at: convert(event.locationInWindow, from: nil))
    }

    private func cancelSubjectGesture() {
        selectionStart = nil
        selectionEnd = nil
        selectionMoved = false
        needsDisplay = true
    }

    private func finishSubjectGesture(at end: CGPoint) {
        guard acceptsSubjectGesture, let start = selectionStart else { cancelSubjectGesture(); return }
        let moved = selectionMoved || hypot(end.x - start.x, end.y - start.y) > 6
        let wasSelecting = selectingSubject
        cancelSubjectGesture()
        if let box = Self.normalizedSelection(from: start, to: end, in: bounds, frameSize: selectionFrameSize) {
            if wasSelecting { selectingSubject = false }
            onSelectSubject?(box)
        } else if !wasSelecting, !moved, clickSelectionEnabled, isGroundMode,
                  let point = Self.normalizedPoint(end, in: bounds, frameSize: selectionFrameSize) {
            onClickSubject?(point)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        drawVignette(context)
        drawConnectionHeader()
        if snapshot.videoDecodedFPS == nil { drawWaitingState() }
        if !isGroundMode, snapshot.videoDecodedFPS != nil { drawArtificialHorizon(context) }
        if snapshot.connectionLabel.localizedCaseInsensitiveContains("live") || snapshot.droneBatteryPercent != nil {
            drawRFPanel()
            if isGroundMode { drawGroundPanel() } else { drawFlightPanel() }
        }
        drawVideoPanel()
        if snapshot.videoDecodedFPS != nil { drawCenterReticle(context) }
        if let observation = subjectObservation, let box = observation.box,
           let imageRect = Self.imageRect(in: bounds, frameSize: observation.frameSize) {
            let rect = NSRect(x: imageRect.minX + box.minX * imageRect.width,
                              y: imageRect.minY + box.minY * imageRect.height,
                              width: box.width * imageRect.width, height: box.height * imageRect.height)
            let color = trackingPresentationState.color
            color.setStroke()
            let outline = NSBezierPath(rect: rect); outline.lineWidth = 2; outline.stroke()
            drawText("\(subjectLabel) \(String(format: "%.0f%%", Double(observation.confidence) * 100))",
                     at: CGPoint(x: rect.minX + 4, y: rect.maxY + 3), font: .systemFont(ofSize: 11, weight: .semibold), color: color)
        }
        if isGroundMode, trackingPresentationState != .idle {
            drawPill(trackingPresentationState.title.uppercased(),
                     at: CGPoint(x: bounds.minX + 18, y: bounds.minY + 47),
                     color: trackingPresentationState.color)
        }
        if selectingSubject || selectionStart != nil { drawSubjectSelection() }
    }

    private func drawSubjectSelection() {
        if let imageRect = Self.imageRect(in: bounds, frameSize: selectionFrameSize),
           let start = selectionStart, let end = selectionEnd {
            let rect = Self.dragRect(from: start, to: end, constrainedTo: imageRect)
            LabVisualStyle.accent.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: rect).fill()
            LabVisualStyle.accent.setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 2
            outline.setLineDash([5, 3], count: 2, phase: 0)
            outline.stroke()
        }
        guard selectingSubject else { return }
        let prompt = "Drag around your target · Escape cancels"
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        let width = prompt.size(withAttributes: [.font: font]).width + 18
        drawPill(prompt, at: CGPoint(x: bounds.midX - width / 2, y: bounds.minY + 48),
                 color: LabVisualStyle.accent)
    }

    private static func imageRect(in bounds: CGRect, frameSize: CGSize) -> CGRect? {
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height,
               frameSize.width, frameSize.height].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0,
              frameSize.width > 0, frameSize.height > 0 else { return nil }
        let scale = min(bounds.width / frameSize.width, bounds.height / frameSize.height)
        let width = frameSize.width * scale
        let height = frameSize.height * scale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height)
    }

    private static func dragRect(from start: CGPoint, to end: CGPoint,
                                 constrainedTo imageRect: CGRect) -> CGRect {
        let clipped = CGPoint(x: min(imageRect.maxX, max(imageRect.minX, end.x)),
                              y: min(imageRect.maxY, max(imageRect.minY, end.y)))
        return CGRect(x: min(start.x, clipped.x), y: min(start.y, clipped.y),
                      width: abs(clipped.x - start.x), height: abs(clipped.y - start.y))
    }

    private static func normalizedPoint(_ point: CGPoint, in bounds: CGRect, frameSize: CGSize) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              let imageRect = imageRect(in: bounds, frameSize: frameSize), imageRect.contains(point) else { return nil }
        return CGPoint(x: (point.x - imageRect.minX) / imageRect.width,
                       y: (point.y - imageRect.minY) / imageRect.height)
    }

    private static func normalizedSelection(from start: CGPoint, to end: CGPoint,
                                             in bounds: CGRect, frameSize: CGSize) -> CGRect? {
        guard [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite),
              let imageRect = imageRect(in: bounds, frameSize: frameSize),
              imageRect.contains(start) else { return nil }
        let selection = dragRect(from: start, to: end, constrainedTo: imageRect)
        guard selection.width >= 12, selection.height >= 12 else { return nil }
        let box = CGRect(x: (selection.minX - imageRect.minX) / imageRect.width,
                         y: (selection.minY - imageRect.minY) / imageRect.height,
                         width: selection.width / imageRect.width,
                         height: selection.height / imageRect.height)
        guard SumoSubjectTracker.isValidSelection(box) else { return nil }
        return box
    }

    static func subjectSelectionSelfTest() -> Bool {
        let square = CGRect(x: 0, y: 0, width: 800, height: 800)
        let wide = CGSize(width: 1600, height: 800)
        let tall = CGSize(width: 800, height: 1600)
        // Wide image has top/bottom letterboxes; tall image has side margins.
        guard imageRect(in: square, frameSize: wide) == CGRect(x: 0, y: 200, width: 800, height: 400),
              imageRect(in: square, frameSize: tall) == CGRect(x: 200, y: 0, width: 400, height: 800),
              normalizedSelection(from: CGPoint(x: 200, y: 300), to: CGPoint(x: 600, y: 500),
                                  in: square, frameSize: wide) == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
              normalizedSelection(from: CGPoint(x: 500, y: 600), to: CGPoint(x: 300, y: 200),
                                  in: square, frameSize: tall) == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
              normalizedSelection(from: CGPoint(x: 400, y: 400), to: CGPoint(x: 900, y: 900),
                                  in: square, frameSize: wide) == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
              normalizedSelection(from: CGPoint(x: 300, y: 400), to: CGPoint(x: 700, y: 600),
                                  in: square.offsetBy(dx: 100, dy: 100), frameSize: wide) ==
                CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) else { return false }
        let invalid = [
            (CGPoint(x: 50, y: 50), CGPoint(x: 300, y: 400), square, wide),
            (CGPoint(x: 50, y: 50), CGPoint(x: 300, y: 100), square, wide),
            (CGPoint(x: 400, y: 400), CGPoint(x: 405, y: 410), square, wide),
            (CGPoint(x: 400, y: 400), CGPoint(x: 420, y: 420), square, CGSize(width: 800, height: 800)),
            (CGPoint(x: 400, y: 400), CGPoint(x: 450, y: 400), square, wide),
            (CGPoint(x: CGFloat.nan, y: 400), CGPoint(x: 450, y: 450), square, wide),
            (CGPoint(x: 400, y: 400), CGPoint(x: CGFloat.infinity, y: 450), square, wide),
            (CGPoint(x: 400, y: 400), CGPoint(x: 450, y: 450), square, CGSize.zero),
            (CGPoint(x: 400, y: 400), CGPoint(x: 450, y: 450), square, CGSize(width: -1, height: 800)),
            (CGPoint(x: 400, y: 400), CGPoint(x: 450, y: 450), CGRect.zero, wide)
        ]
        guard invalid.allSatisfy({ normalizedSelection(from: $0.0, to: $0.1, in: $0.2, frameSize: $0.3) == nil }),
              normalizedPoint(CGPoint(x: 200, y: 300), in: square, frameSize: wide) == CGPoint(x: 0.25, y: 0.25),
              normalizedPoint(CGPoint(x: 300, y: 200), in: square, frameSize: tall) == CGPoint(x: 0.25, y: 0.25),
              normalizedPoint(CGPoint(x: 300, y: 400), in: square.offsetBy(dx: 100, dy: 100), frameSize: wide) == CGPoint(x: 0.25, y: 0.25),
              normalizedPoint(CGPoint(x: 100, y: 100), in: square, frameSize: wide) == nil,
              normalizedPoint(CGPoint(x: CGFloat.nan, y: 400), in: square, frameSize: wide) == nil else { return false }
        _ = NSApplication.shared
        let view = Self(frame: square)
        view.selectionFrameSize = wide
        var clicks: [CGPoint] = []
        var boxes: [CGRect] = []
        var begins = 0
        var callbackWasModal = true
        view.onBeginSubjectInteraction = { begins += 1 }
        view.onClickSubject = { clicks.append($0) }
        view.onSelectSubject = { [weak view] in boxes.append($0); callbackWasModal = view?.selectingSubject ?? true }
        let start = CGPoint(x: 200, y: 300)
        let end = CGPoint(x: 600, y: 500)
        // All unrelated video modes retain click-through behavior by default.
        view.beginSubjectGesture(at: start); view.finishSubjectGesture(at: start)
        guard clicks.isEmpty, begins == 0, view.hitTest(start) == nil else { return false }
        view.clickSelectionEnabled = true
        view.beginSubjectGesture(at: start); view.finishSubjectGesture(at: start)
        guard clicks.isEmpty, begins == 0 else { return false }
        view.isGroundMode = true
        view.beginSubjectGesture(at: start); view.finishSubjectGesture(at: start)
        guard clicks == [CGPoint(x: 0.25, y: 0.25)], begins == 1 else { return false }
        view.beginSubjectGesture(at: CGPoint(x: 100, y: 100)); view.finishSubjectGesture(at: start)
        guard clicks.count == 1, begins == 1 else { return false }
        view.beginSubjectGesture(at: start); view.updateSubjectGesture(at: end); view.finishSubjectGesture(at: end)
        guard boxes == [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)], begins == 2, !callbackWasModal else { return false }
        // A failed drag must not become a subject click, even when the pointer returns.
        view.beginSubjectGesture(at: start)
        view.updateSubjectGesture(at: CGPoint(x: 205, y: 310))
        view.finishSubjectGesture(at: start)
        guard clicks.count == 1, boxes.count == 1 else { return false }
        view.beginSubjectGesture(at: start); view.clickSelectionEnabled = false; view.finishSubjectGesture(at: end)
        guard boxes.count == 1, begins == 4 else { return false }
        // Modal rectangle selection remains available independently of default clicks.
        view.selectingSubject = true
        view.beginSubjectGesture(at: start); view.finishSubjectGesture(at: start)
        guard clicks.count == 1, view.selectingSubject else { return false }
        view.beginSubjectGesture(at: start)
        view.selectionFrameSize = CGSize(width: 1600, height: 800) // Equal metadata must not cancel.
        view.finishSubjectGesture(at: end)
        guard boxes.count == 2, !callbackWasModal, !view.selectingSubject else { return false }
        view.clickSelectionEnabled = true
        view.beginSubjectGesture(at: start); view.selectionFrameSize = tall; view.finishSubjectGesture(at: end)
        guard boxes.count == 2 else { return false }
        view.beginSubjectGesture(at: CGPoint(x: 300, y: 300)); view.isGroundMode = false; view.finishSubjectGesture(at: end)
        guard boxes.count == 2, clicks.count == 1 else { return false }
        view.isGroundMode = true
        view.beginSubjectGesture(at: CGPoint(x: 300, y: 300)); view.setFrameSize(NSSize(width: 700, height: 800))
        view.finishSubjectGesture(at: end)
        guard boxes.count == 2, clicks.count == 1, begins == 9 else { return false }
        // Disabling selection inside the begin callback must also cancel the
        // already-started gesture rather than restoring it afterwards.
        view.onBeginSubjectInteraction = { [weak view] in view?.clickSelectionEnabled = false }
        view.beginSubjectGesture(at: CGPoint(x: 300, y: 300)); view.finishSubjectGesture(at: end)
        return boxes.count == 2 && clicks.count == 1
    }

    private func drawVignette(_ context: CGContext) {
        let colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.28).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.55, 1.0]) else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            startRadius: 0,
            endCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            endRadius: max(bounds.width, bounds.height) * 0.7,
            options: []
        )
    }

    private func drawConnectionHeader() {
        let color: NSColor = snapshot.connectionLabel.contains("Live") ? .systemGreen : .systemOrange
        drawPill(snapshot.connectionLabel.uppercased(), at: CGPoint(x: 18, y: bounds.height - 36), color: color)
        let route = snapshot.connectionRouteLabel
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let width = route.size(withAttributes: [.font: font]).width
        drawText(
            route,
            at: CGPoint(x: bounds.width - width - 20, y: bounds.height - 31),
            font: font,
            color: NSColor.white.withAlphaComponent(0.72)
        )
    }

    private func drawWaitingState() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let iconCenter = NSPoint(x: center.x, y: center.y + 53)
        for radius: CGFloat in [41, 58, 76] {
            LabVisualStyle.accent.withAlphaComponent(radius == 41 ? 0.12 : 0.045).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: iconCenter.x - radius, y: iconCenter.y - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = 1
            ring.stroke()
        }
        LabVisualStyle.accent.withAlphaComponent(0.72).setStroke()
        let camera = NSBezierPath(roundedRect: NSRect(x: iconCenter.x - 21, y: iconCenter.y - 12, width: 31, height: 24), xRadius: 5, yRadius: 5)
        camera.lineWidth = 1.5
        camera.stroke()
        let lens = NSBezierPath()
        lens.move(to: NSPoint(x: iconCenter.x + 10, y: iconCenter.y + 5))
        lens.line(to: NSPoint(x: iconCenter.x + 23, y: iconCenter.y + 12))
        lens.line(to: NSPoint(x: iconCenter.x + 23, y: iconCenter.y - 12))
        lens.line(to: NSPoint(x: iconCenter.x + 10, y: iconCenter.y - 5))
        lens.lineWidth = 1.5
        lens.stroke()
        let connected = snapshot.connectionLabel.localizedCaseInsensitiveContains("live")
        let title = connected ? "Waiting for your camera" : "Live view is ready"
        let subtitle = connected ? "Start video, or wait for the stream to arrive." : "Connect your \(isGroundMode ? "Sumo" : "Bebop") to open live view."
        for (text, y, font, color) in [
            (title, center.y - 49, NSFont.systemFont(ofSize: 19, weight: .medium), NSColor.white.withAlphaComponent(0.8)),
            (subtitle, center.y - 75, NSFont.systemFont(ofSize: 11, weight: .regular), LabVisualStyle.mutedText)
        ] {
            let width = text.size(withAttributes: [.font: font]).width
            drawText(text, at: CGPoint(x: center.x - width / 2, y: y), font: font, color: color)
        }
    }

    private func panelBackdrop(_ rect: NSRect) {
        NSColor.black.withAlphaComponent(snapshot.videoDecodedFPS == nil ? 0.16 : 0.38).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
    }

    private func drawArtificialHorizon(_ context: CGContext) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let roll = snapshot.roll ?? 0
        let pitch = snapshot.pitch ?? 0
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(-roll))
        context.translateBy(x: 0, y: CGFloat(pitch * 150.0))
        context.setStrokeColor(LabVisualStyle.accent.withAlphaComponent(0.78).cgColor)
        context.setLineWidth(1.4)
        context.move(to: CGPoint(x: -92, y: 0))
        context.addLine(to: CGPoint(x: -22, y: 0))
        context.move(to: CGPoint(x: 22, y: 0))
        context.addLine(to: CGPoint(x: 92, y: 0))
        context.strokePath()

        for degree in stride(from: -20, through: 20, by: 10) where degree != 0 {
            let y = CGFloat(degree) * 2.2
            let halfWidth: CGFloat = degree % 20 == 0 ? 42 : 28
            context.move(to: CGPoint(x: -halfWidth, y: y))
            context.addLine(to: CGPoint(x: halfWidth, y: y))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawCenterReticle(_ context: CGContext) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: center.x - 19, y: center.y))
        context.addLine(to: CGPoint(x: center.x - 6, y: center.y))
        context.addLine(to: CGPoint(x: center.x, y: center.y - 5))
        context.addLine(to: CGPoint(x: center.x + 6, y: center.y))
        context.addLine(to: CGPoint(x: center.x + 19, y: center.y))
        context.strokePath()
    }

    private func drawRFPanel() {
        let x: CGFloat = 28
        panelBackdrop(NSRect(x: 16, y: bounds.height - 206, width: 184, height: 151))
        var y = bounds.height - 78
        drawText("SIGNAL", at: CGPoint(x: x, y: y), font: .systemFont(ofSize: 10, weight: .semibold), color: LabVisualStyle.accent)
        y -= 24
        drawSignalRow(label: "A0", value: snapshot.chain0RSSI, x: x, y: y)
        y -= 22
        drawSignalRow(label: "A1", value: snapshot.chain1RSSI, x: x, y: y)
        y -= 22
        drawSignalRow(label: "AVG", value: snapshot.chainAverage ?? snapshot.reportedRSSI, x: x, y: y)
        y -= 24
        drawText("SNR \(formatted(snapshot.snr, suffix: " dB"))  ·  \(formatted(snapshot.rxQuality, suffix: "%")) link", at: CGPoint(x: x, y: y), font: mono(10), color: NSColor.white.withAlphaComponent(0.72))
    }

    private func drawFlightPanel() {
        let x = bounds.width - 178
        panelBackdrop(NSRect(x: x - 12, y: bounds.height - 263, width: 174, height: 208))
        var y = bounds.height - 78
        drawText("FLIGHT", at: CGPoint(x: x, y: y), font: .monospacedSystemFont(ofSize: 11, weight: .bold), color: LabVisualStyle.accent)
        y -= 27
        drawText(snapshot.flightState, at: CGPoint(x: x, y: y), font: .monospacedSystemFont(ofSize: 17, weight: .bold), color: flightColor)
        y -= 30
        drawText("ALT  \(formatted(snapshot.altitude, digits: 1, suffix: " m"))", at: CGPoint(x: x, y: y), font: mono(13), color: .white)
        y -= 22
        drawText("DIST \(formatted(snapshot.distanceFromHome, digits: 0, suffix: " m"))", at: CGPoint(x: x, y: y), font: mono(13), color: .white)
        y -= 22
        if let battery = snapshot.droneBatteryPercent {
            drawText("DRONE \(battery)%", at: CGPoint(x: x, y: y), font: mono(13), color: batteryColor(battery))
        } else {
            drawText("DRONE —", at: CGPoint(x: x, y: y), font: mono(13), color: .white)
        }

        if let battery = snapshot.sc2BatteryPercent {
            y -= 31
            drawText("SC2  \(battery)%", at: CGPoint(x: x, y: y), font: mono(13), color: batteryColor(battery))
        }
        if let temperature = snapshot.sc2TemperatureC {
            y -= 21
            drawText("CPU  \(temperature)°C", at: CGPoint(x: x, y: y), font: mono(12), color: temperature >= 75 ? .systemRed : .white)
        }
    }

    private func drawGroundPanel() {
        let x = bounds.width - 178
        panelBackdrop(NSRect(x: x - 12, y: bounds.height - 190, width: 174, height: 135))
        var y = bounds.height - 78
        drawText("GROUND", at: CGPoint(x: x, y: y), font: .monospacedSystemFont(ofSize: 11, weight: .bold), color: LabVisualStyle.accent)
        y -= 27
        drawText("JUMPING SUMO", at: CGPoint(x: x, y: y), font: .monospacedSystemFont(ofSize: 15, weight: .bold), color: .white)
        y -= 31
        if let battery = snapshot.droneBatteryPercent {
            drawText("BATTERY \(battery)%", at: CGPoint(x: x, y: y), font: mono(13), color: batteryColor(battery))
        } else {
            drawText("BATTERY —", at: CGPoint(x: x, y: y), font: mono(13), color: .white)
        }
        y -= 24
        drawText(snapshot.connectionRouteLabel.contains("SC2") ? "VIA SKYCONTROLLER 2" : "DIRECT WI-FI", at: CGPoint(x: x, y: y), font: mono(10), color: NSColor.white.withAlphaComponent(0.64))
    }

    private func drawVideoPanel() {
        let y: CGFloat = 22
        let output = snapshot.videoProcessedHeight.map { "\($0)p" } ?? "Output —"
        let text = "\(isGroundMode ? "MJPEG" : "H.264")  /  \(output)  /  \(fps(snapshot.videoDisplayRefreshFPS)) fps"
        drawText(text, at: CGPoint(x: 22, y: y), font: mono(10), color: NSColor.white.withAlphaComponent(0.68))
    }

    private func fps(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "—"
    }

    private func drawSignalRow(label: String, value: Int?, x: CGFloat, y: CGFloat) {
        let color = signalColor(value)
        drawText(label, at: CGPoint(x: x, y: y), font: mono(12), color: NSColor.white.withAlphaComponent(0.8))
        let barRect = CGRect(x: x + 32, y: y + 1, width: 88, height: 8)
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4).fill()
        if let value {
            let fraction = min(1, max(0, CGFloat(value + 70) / 70.0))
            color.setFill()
            NSBezierPath(roundedRect: CGRect(x: barRect.minX, y: barRect.minY, width: barRect.width * fraction, height: barRect.height), xRadius: 4, yRadius: 4).fill()
        }
        drawText(formatted(value, suffix: ""), at: CGPoint(x: x + 128, y: y), font: mono(12), color: color)
    }

    private func drawPill(_ text: String, at point: CGPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: color
        ]
        let size = text.size(withAttributes: attributes)
        let rect = CGRect(x: point.x, y: point.y, width: size.width + 18, height: 22)
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
        text.draw(at: CGPoint(x: rect.minX + 9, y: rect.minY + 4), withAttributes: attributes)
    }

    private func drawText(_ text: String, at point: CGPoint, font: NSFont, color: NSColor) {
        text.draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func signalColor(_ value: Int?) -> NSColor {
        guard let value else { return .secondaryLabelColor }
        if value <= -60 { return .systemRed }
        if value <= -40 { return blend(.systemRed, .systemYellow, fraction: CGFloat(value + 60) / 20) }
        if value <= -20 { return blend(.systemYellow, .systemGreen, fraction: CGFloat(value + 40) / 20) }
        if value <= -5 { return blend(.systemGreen, .systemCyan, fraction: CGFloat(value + 20) / 15) }
        return .systemCyan
    }

    private func blend(_ from: NSColor, _ to: NSColor, fraction: CGFloat) -> NSColor {
        from.blended(withFraction: min(1, max(0, fraction)), of: to) ?? to
    }

    private var flightColor: NSColor {
        switch snapshot.flightState {
        case "FLYING", "HOVERING": return .systemGreen
        case "EMERGENCY": return .systemRed
        case "LANDING", "TAKINGOFF": return .systemYellow
        default: return .white
        }
    }

    private func batteryColor(_ value: Int) -> NSColor {
        value <= 15 ? .systemRed : value <= 30 ? .systemYellow : .systemGreen
    }

    private func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .medium) }
    private func formatted(_ value: Int?, suffix: String) -> String { value.map { "\($0)\(suffix)" } ?? "—" }
    private func formatted(_ value: Double?, digits: Int, suffix: String) -> String {
        value.map { String(format: "%.*f%@", digits, $0, suffix) } ?? "—"
    }
    private func angle(_ radians: Double?) -> String {
        guard let radians else { return "    —" }
        return String(format: "%6.1f°", radians * 180.0 / .pi)
    }
}
