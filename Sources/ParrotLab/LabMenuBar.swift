import AppKit

/// Native menus retain keyboard navigation, validation and standard checkmarks.
enum LabMenuBar {
    static let videoID = NSUserInterfaceItemIdentifier("lab.video")
    static let motionID = NSUserInterfaceItemIdentifier("lab.video.motion")
    static let groundMotionID = NSUserInterfaceItemIdentifier("lab.video.ground-motion")

    @discardableResult
    static func command(_ menu: NSMenu, _ title: String, _ action: Selector,
                        target: AnyObject? = nil, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = target
        if let symbol { item.image = icon(symbol) }
        return item
    }

    static func submenu(_ menu: NSMenu, _ title: String, symbol: String? = nil,
                        identifier: NSUserInterfaceItemIdentifier? = nil) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = identifier
        if let symbol { item.image = icon(symbol) }
        let child = NSMenu(title: title); child.minimumWidth = 220
        item.submenu = child; menu.addItem(item)
        return child
    }

    private static func icon(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        image.size = NSSize(width: 16, height: 16); image.isTemplate = true
        return image
    }

    static func make(delegate: AppDelegate) -> NSMenu {
        let main = NSMenu()
        let app = submenu(main, "Parrot Lab")
        command(app, "About Parrot Lab", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        command(app, "Settings…", #selector(AppDelegate.showSettings(_:)), target: delegate, key: ",")
        app.addItem(.separator())
        _ = submenu(app, "Services")
        app.addItem(.separator())
        command(app, "Hide Parrot Lab", #selector(NSApplication.hide(_:)), key: "h")
        command(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h")
            .keyEquivalentModifierMask = [.command, .option]
        command(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        command(app, "Quit Parrot Lab", #selector(NSApplication.terminate(_:)), key: "q")

        let edit = submenu(main, "Edit")
        command(edit, "Undo", Selector(("undo:")), key: "z")
        command(edit, "Redo", Selector(("redo:")), key: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        command(edit, "Cut", #selector(NSText.cut(_:)), key: "x")
        command(edit, "Copy", #selector(NSText.copy(_:)), key: "c")
        command(edit, "Paste", #selector(NSText.paste(_:)), key: "v")
        command(edit, "Select All", #selector(NSText.selectAll(_:)), key: "a")

        let view = submenu(main, "View")
        command(view, "Focus View", #selector(AppDelegate.toggleWorkspaceFocus(_:)), target: delegate, key: "f",
                symbol: "sidebar.right").keyEquivalentModifierMask = [.command, .shift]
        view.addItem(.separator())
        command(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let video = submenu(main, "Video", identifier: videoID)
        let enhancement = submenu(video, "Image Enhancement", symbol: "slider.horizontal.3")
        let names: [VideoEnhancementPreset: String] = [
            .off: "Off — Source Image", .denoise: "Denoise", .h264ArtifactRepair: "H.264 Artifact Repair",
            .clarity: "Clarity", .lowLight: "Low-Light Cleanup", .upscale2x: "High-Quality 2× Upscale",
            .upscaleClarity2x: "2× Upscale + Clarity"
        ]
        for preset in VideoEnhancementPreset.allCases {
            if preset == .denoise || preset == .upscale2x { enhancement.addItem(.separator()) }
            let item = command(enhancement, names[preset] ?? preset.menuTitle,
                               #selector(AppDelegate.selectVideoEnhancement(_:)), target: delegate)
            item.tag = preset.rawValue; item.state = preset == .off ? .on : .off
            item.toolTip = preset.menuTitle
        }
        let scaling = submenu(video, "MetalFX Scaling", symbol: "arrow.up.left.and.arrow.down.right")
        let scalingNames: [(VideoSpatialScalingMode, String)] = [
            (.off, "Off — Native Resolution"), (.metalFX2x, "2× Source Resolution"),
            (.metalFX720p, "720p"), (.metalFX1080p, "1080p"), (.metalFX1440p, "1440p"),
            (.metalFX1800p, "1800p"), (.metalFX2160p, "2160p / 4K")
        ]
        for (mode, name) in scalingNames {
            if mode == .metalFX720p { scaling.addItem(.separator()) }
            let item = command(scaling, name, #selector(AppDelegate.selectMetalFXSpatialScaling(_:)), target: delegate)
            item.tag = mode.rawValue; item.state = mode == .off ? .on : .off
            item.toolTip = mode.usesMetalFX ? "Apple MetalFX Spatial; preserves the camera's aspect ratio." : mode.menuTitle
            if mode.usesMetalFX && !MetalFXSpatialScalerRenderer.isSupported {
                item.isEnabled = false; item.toolTip = "MetalFX Spatial is not supported by this Mac."
            }
        }
        let motion = submenu(video, "Motion Correction", symbol: "waveform.path", identifier: motionID)
        let jello = command(motion, "Calibrated Jello Correction", #selector(AppDelegate.toggleCalibratedRollingShutter(_:)), target: delegate)
        jello.state = UserDefaults.standard.bool(forKey: "ParrotLab.Calibrated471RollingShutterV2") ? .on : .off
        jello.toolTip = "Bebop 2 firmware 4.7.1, calibrated 900p Temporal profile. Off by default."
        let ground = command(video, "Sumo Motion Smoothing", #selector(AppDelegate.toggleGroundTemporal720p45(_:)), target: delegate)
        ground.identifier = groundMotionID
        ground.toolTip = "Experimental 720p optical flow. Requires 30 FPS input for a 45 FPS target; adjust in Video Processing Settings."
        command(video, "Video Processing Settings…", #selector(AppDelegate.showVideoProcessingSettings(_:)), target: delegate)

        let tools = submenu(main, "Tools")
        delegate.populateToolsMenu(tools, ground: false)

        let window = submenu(main, "Window")
        command(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        command(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        command(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return main
    }

    static func install(on application: NSApplication, delegate: AppDelegate) {
        let menu = make(delegate: delegate)
        application.servicesMenu = menu.item(withTitle: "Parrot Lab")?.submenu?.item(withTitle: "Services")?.submenu
        application.windowsMenu = menu.item(withTitle: "Window")?.submenu
        application.mainMenu = menu
    }

    static func descendants(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map { descendants(of: $0) } ?? []) }
    }

    static func selfTest(delegate: AppDelegate) -> Bool {
        let main = make(delegate: delegate)
        guard main.items.map(\.title) == ["Parrot Lab", "Edit", "View", "Video", "Tools", "Window"],
              let video = main.item(withTitle: "Video")?.submenu else { return false }
        let enhancement = descendants(of: video).filter { $0.action == #selector(AppDelegate.selectVideoEnhancement(_:)) }
        let scaling = descendants(of: video).filter { $0.action == #selector(AppDelegate.selectMetalFXSpatialScaling(_:)) }
        guard Set(enhancement.map(\.tag)) == Set(VideoEnhancementPreset.allCases.map(\.rawValue)),
              Set(scaling.map(\.tag)) == Set(VideoSpatialScalingMode.allCases.map(\.rawValue)),
              enhancement.count == VideoEnhancementPreset.allCases.count,
              scaling.count == VideoSpatialScalingMode.allCases.count else { return false }
        func clean(_ menu: NSMenu) -> Bool {
            guard menu.items.first?.isSeparatorItem != true, menu.items.last?.isSeparatorItem != true else { return false }
            for (index, item) in menu.items.enumerated() {
                if item.isSeparatorItem, index > 0, menu.items[index - 1].isSeparatorItem { return false }
                if let child = item.submenu, !clean(child) { return false }
            }
            return true
        }
        var shortcuts = Set<String>()
        for item in descendants(of: main) where !item.keyEquivalent.isEmpty {
            let key = "\(item.keyEquivalent.lowercased())/\(item.keyEquivalentModifierMask.rawValue)"
            guard shortcuts.insert(key).inserted else { return false }
        }
        return clean(main)
    }
}
