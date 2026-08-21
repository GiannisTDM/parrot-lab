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
        snapshot.roll = -0.063
        snapshot.pitch = 0.035
        snapshot.yaw = 1.92
        snapshot.sc2BatteryPercent = 83
        snapshot.droneBatteryPercent = 74
        snapshot.sc2TemperatureC = 55
        snapshot.sc2PowerState = "DISCHARGING"
        snapshot.videoBitrateKbps = 4_860
        snapshot.videoPackets = 18_442
        snapshot.videoPacketsLost = 3
        snapshot.videoJitterMs = 2.7
        hud.update(snapshot: snapshot)
        hud.displayIfNeeded()

        return writePNG(of: hud, to: path)
    }

    static func renderApplication(to path: String) -> Bool {
        let controller = MainViewController()
        let appView = controller.view
        appView.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
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
