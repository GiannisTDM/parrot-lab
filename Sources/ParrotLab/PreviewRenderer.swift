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

    static func renderApplication(to path: String, groundMode: Bool = false) -> Bool {
        let controller = MainViewController()
        let appView = controller.view
        controller.setGroundModeForPreview(groundMode)
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
