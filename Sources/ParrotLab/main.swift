import AppKit

if CommandLine.arguments.contains("--self-test-settings") {
    let passed = AppDelegate.settingsInteractionSelfTest()
    print(passed ? "Settings interaction self-tests passed" : "Settings interaction self-tests failed")
    exit(passed ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test-minidrone") {
    let passed = MiniDroneSelfTest.run()
    if passed { print("MiniDrone packet and transport self-tests passed") }
    exit(passed ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test") {
    exit(ParrotLabSelfTest.run())
}

if let index = CommandLine.arguments.firstIndex(of: "--render-sc2-mapping-preview"),
   CommandLine.arguments.indices.contains(index + 1) {
    exit(PreviewRenderer.renderSC2Mappings(to: CommandLine.arguments[index + 1]) ? 0 : 1)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
   CommandLine.arguments.indices.contains(index + 1) {
    exit(PreviewRenderer.render(to: CommandLine.arguments[index + 1]) ? 0 : 1)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-app-preview"),
   CommandLine.arguments.indices.contains(index + 1) {
    exit(PreviewRenderer.renderApplication(to: CommandLine.arguments[index + 1]) ? 0 : 1)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-minidrone-preview"),
   CommandLine.arguments.indices.contains(index + 1) {
    exit(PreviewRenderer.renderApplication(to: CommandLine.arguments[index + 1], miniDrone: true) ? 0 : 1)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-ground-preview"),
   CommandLine.arguments.indices.contains(index + 1) {
    exit(PreviewRenderer.renderApplication(
        to: CommandLine.arguments[index + 1],
        groundMode: true
    ) ? 0 : 1)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)

let menu = NSMenu()
let appItem = NSMenuItem(title: "Parrot Lab", action: nil, keyEquivalent: "")
menu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About Parrot Lab", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
let settingsItem = NSMenuItem(
    title: "Settings…",
    action: #selector(AppDelegate.showSettings(_:)),
    keyEquivalent: ","
)
settingsItem.target = delegate
appMenu.addItem(settingsItem)
appMenu.addItem(NSMenuItem.separator())
let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
let servicesMenu = NSMenu(title: "Services")
servicesItem.submenu = servicesMenu
appMenu.addItem(servicesItem)
application.servicesMenu = servicesMenu
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Hide Parrot Lab", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
let hideOthersItem = appMenu.addItem(
    withTitle: "Hide Others",
    action: #selector(NSApplication.hideOtherApplications(_:)),
    keyEquivalent: "h"
)
hideOthersItem.keyEquivalentModifierMask = [.command, .option]
appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Quit Parrot Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu

let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
redoItem.keyEquivalentModifierMask = [.command, .shift]
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
menu.addItem(editItem)

let toolsItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
let toolsMenu = NSMenu(title: "Tools")
delegate.populateToolsMenu(toolsMenu, ground: false)
toolsItem.submenu = toolsMenu
menu.addItem(toolsItem)

let enhancementItem = NSMenuItem(title: "Image Enhancement", action: nil, keyEquivalent: "")
let enhancementMenu = NSMenu(title: "Image Enhancement")
for preset in VideoEnhancementPreset.allCases {
    let item = NSMenuItem(
        title: preset.menuTitle,
        action: #selector(AppDelegate.selectVideoEnhancement(_:)),
        keyEquivalent: ""
    )
    item.tag = preset.rawValue
    item.target = delegate
    item.state = preset == .off ? .on : .off
    enhancementMenu.addItem(item)
}
enhancementItem.submenu = enhancementMenu
menu.addItem(enhancementItem)

let motionCorrectionItem = NSMenuItem(title: "Motion Correction", action: nil, keyEquivalent: "")
let motionCorrectionMenu = NSMenu(title: "Motion Correction")
let rollingShutterItem = NSMenuItem(
    title: "4.7.1 900p Calibrated Jello Correction",
    action: #selector(AppDelegate.toggleCalibratedRollingShutter(_:)),
    keyEquivalent: ""
)
rollingShutterItem.target = delegate
rollingShutterItem.state = UserDefaults.standard.bool(
    forKey: "ParrotLab.Calibrated471RollingShutterV2"
) ? .on : .off
rollingShutterItem.toolTip = "Off by default. Enabling it confirms the calibrated 4.7.1 900p Temporal source profile."
motionCorrectionMenu.addItem(rollingShutterItem)
motionCorrectionItem.submenu = motionCorrectionMenu
menu.addItem(motionCorrectionItem)

let metalFXItem = NSMenuItem(title: "MetalFX Spatial", action: nil, keyEquivalent: "")
let metalFXMenu = NSMenu(title: "MetalFX Spatial")
for mode in VideoSpatialScalingMode.allCases {
    let item = NSMenuItem(
        title: mode.menuTitle,
        action: #selector(AppDelegate.selectMetalFXSpatialScaling(_:)),
        keyEquivalent: ""
    )
    item.tag = mode.rawValue
    item.target = delegate
    item.state = mode == .off ? .on : .off
    if mode.usesMetalFX && !MetalFXSpatialScalerRenderer.isSupported {
        item.isEnabled = false
        item.toolTip = "MetalFX Spatial is not supported by this Mac"
    }
    metalFXMenu.addItem(item)
}
metalFXItem.submenu = metalFXMenu
menu.addItem(metalFXItem)

let videoItem = NSMenuItem(title: "Video", action: nil, keyEquivalent: "")
let videoMenu = NSMenu(title: "Video")
let sumoTemporalItem = NSMenuItem(
    title: "Sumo · 720p + 30→45 FPS Optical Flow",
    action: #selector(AppDelegate.toggleGroundTemporal720p45(_:)),
    keyEquivalent: ""
)
sumoTemporalItem.target = delegate
sumoTemporalItem.toolTip = "Image-only temporal cleanup, confidence/occlusion rejection and one generated frame per two real frames. Preserves aspect ratio; requires 30 FPS input for the 45 FPS target. Tune in Settings."
videoMenu.addItem(sumoTemporalItem)
videoMenu.addItem(.separator())
let convertVideoItem = NSMenuItem(
    title: "Convert Finished H.264 to MP4…",
    action: #selector(AppDelegate.convertFinishedH264ToMP4(_:)),
    keyEquivalent: ""
)
convertVideoItem.target = delegate
videoMenu.addItem(convertVideoItem)
videoMenu.addItem(.separator())
let rawArchiveItem = NSMenuItem(
    title: "Archive Untouched Incoming H.264 (Developer)",
    action: #selector(AppDelegate.toggleRawH264Archive(_:)),
    keyEquivalent: ""
)
rawArchiveItem.target = delegate
rawArchiveItem.state = UserDefaults.standard.bool(
    forKey: "ParrotLab.ArchiveRawIncomingH264"
) ? .on : .off
rawArchiveItem.toolTip = "Simultaneously saves the unprocessed Bebop stream as RawVideoBB2…h264"
videoMenu.addItem(rawArchiveItem)
videoItem.submenu = videoMenu
menu.addItem(videoItem)

let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(
    withTitle: "Minimize",
    action: #selector(NSWindow.performMiniaturize(_:)),
    keyEquivalent: "m"
)
windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
windowMenu.addItem(.separator())
windowMenu.addItem(
    withTitle: "Bring All to Front",
    action: #selector(NSApplication.arrangeInFront(_:)),
    keyEquivalent: ""
)
windowItem.submenu = windowMenu
menu.addItem(windowItem)
application.windowsMenu = windowMenu
application.mainMenu = menu

application.run()
