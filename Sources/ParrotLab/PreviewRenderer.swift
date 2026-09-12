import AppKit

enum PreviewRenderer {
    static func render(to path: String) -> Bool {
        let hud = VideoHUDView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        hud.layoutSubtreeIfNeeded()

        var snapshot = TelemetrySnapshot()
        snapshot.connectionLabel = "Live SC2"
        snapshot.chain0RSSI = -42
        snapshot.chain1RSSI = -45
        snapshot.noise = -91
        snapshot.rxQuality = 94
        snapshot.rxUseful = 98
        snapshot.phyRateMbps = 65
        snapshot.flightState = "FLYING"
        snapshot.altitude = 19.1
        snapshot.distanceFromHome = 47
        snapshot.horizontalSpeed = 6.4
        snapshot.satelliteCount = 14
        snapshot.gpsFixed = true
        snapshot.latitude = 38.246639
        snapshot.longitude = 21.734574
        snapshot.roll = -0.063
        snapshot.pitch = 0.035
        snapshot.yaw = 1.92
        snapshot.sc2BatteryPercent = 83
        snapshot.droneBatteryPercent = 74
        snapshot.sc2TemperatureC = 55
        snapshot.sc2PowerState = "DISCHARGING"
        snapshot.videoBitrateKbps = 4_860
        snapshot.videoEncodedAUFPS = 29.9
        snapshot.videoUniqueTimestampFPS = 30.0
        snapshot.videoDecodedFPS = 29.8
        snapshot.videoDisplayRefreshFPS = 29.5
        snapshot.videoPackets = 18_442
        snapshot.videoDuplicatePackets = 127
        snapshot.videoPacketsLost = 3
        snapshot.videoJitterMs = 2.7
        hud.update(snapshot: snapshot)
        hud.displayIfNeeded()

        return writePNG(of: hud, to: path)
    }

    static func renderApplication(to path: String, groundMode: Bool = false, miniDrone: Bool = false) -> Bool {
        let controller = MainViewController()
        let appView = controller.view
        controller.setGroundModeForPreview(groundMode)
        if miniDrone { controller.enterMiniDroneMode() }
        let compact = ProcessInfo.processInfo.environment["PARROTLAB_PREVIEW_COMPACT"] == "1"
        appView.frame = NSRect(x: 0, y: 0, width: compact ? 1180 : 1440, height: compact ? 720 : 900)
        let expanded = ProcessInfo.processInfo.environment["PARROTLAB_PREVIEW_EXPANDED"] == "1"
        let focus = ProcessInfo.processInfo.environment["PARROTLAB_PREVIEW_FOCUS"] == "1"
        func exercisePresentation(_ view: NSView) {
            if expanded, let disclosure = view as? LabDisclosureButton, !disclosure.expanded {
                disclosure.performClick(nil)
            }
            if let button = view as? NSButton,
               (expanded && button.title == "Activity") || (focus && button.title == "Focus") {
                button.performClick(nil)
            }
            view.subviews.forEach(exercisePresentation)
        }
        exercisePresentation(appView)
        appView.layoutSubtreeIfNeeded()
        appView.displayIfNeeded()
        return writePNG(of: appView, to: path)
    }

    static func renderSC2Mappings(to path: String) -> Bool {
        _ = NSApplication.shared
        let panel = SC2MappingWindowController()
        var state = SC2MappingState()
        let ground = ProcessInfo.processInfo.environment["PARROTLAB_PREVIEW_GROUND"] == "1"
        let product: UInt16 = ground ? 0x0901 : 0x090c
        state.activeProduct = product
        state.completed = [.axis, .button, .inversion]
        for (action, axis) in [(16, 2), (17, 3), (18, 0), (19, 1), (21, 4)] {
            state.consume(.entry(SC2MappingEntry(kind: .axis, uid: UInt32(action), product: product,
                action: UInt32(action), axis: Int32(axis), buttons: 0, inverted: false, flags: 0)))
        }
        for (action, button) in [(0, 1), (16, 2), (17, 4), (18, 8), (19, 16)] {
            state.consume(.entry(SC2MappingEntry(kind: .button, uid: UInt32(action), product: product,
                action: UInt32(action), axis: -1, buttons: UInt32(button), inverted: false, flags: 0)))
        }
        panel.refresh(state: state, ground: ground, enabled: true,
            message: ground
                ? "Controller mapping loaded. Bank 0x0901. Sumo shares this bank with Bebop 1; changes affect both. Center sticks and keep the vehicle stationary. Remaps run on SC2, not the Mac."
                : "Controller mapping loaded. Bank 0x090C. Center sticks and keep the vehicle stationary. Remaps run on SC2, not the Mac.")
        guard let view = panel.window?.contentView else { return false }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        return writePNG(of: view, to: path)
    }

    private static func writePNG(of view: NSView, to path: String) -> Bool {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            print(path)
            return true
        } catch {
            fputs("Preview render failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }
}
