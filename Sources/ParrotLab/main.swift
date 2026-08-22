import AppKit

if CommandLine.arguments.contains("--self-test") {
    exit(ParrotLabSelfTest.run())
}

if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
   CommandLine.arguments.indices.contains(index + 1) {
    exit(PreviewRenderer.render(to: CommandLine.arguments[index + 1]) ? 0 : 1)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-app-preview"),
   CommandLine.arguments.indices.contains(index + 1) {
    exit(PreviewRenderer.renderApplication(to: CommandLine.arguments[index + 1]) ? 0 : 1)
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
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Quit Parrot Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu

let toolsItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
let toolsMenu = NSMenu(title: "Tools")
let installDragonItem = NSMenuItem(
    title: "Install/Update Dragon Lab on Bebop 2",
    action: #selector(AppDelegate.installDragonLabOnBebop2(_:)),
    keyEquivalent: ""
)
installDragonItem.target = delegate
toolsMenu.addItem(installDragonItem)
let enableBebopTelnetItem = NSMenuItem(
    title: "Enable Persistent Telnet on Bebop 2…",
    action: #selector(AppDelegate.enablePersistentTelnetOnBebop2(_:)),
    keyEquivalent: ""
)
enableBebopTelnetItem.target = delegate
toolsMenu.addItem(enableBebopTelnetItem)
let uploadRFBebopItem = NSMenuItem(
    title: "Upload RF/MOD Suite",
    action: #selector(AppDelegate.uploadRFModSuiteToBebop2(_:)),
    keyEquivalent: ""
)
uploadRFBebopItem.target = delegate
toolsMenu.addItem(uploadRFBebopItem)
let uploadRFSC2Item = NSMenuItem(
    title: "Upload RF/MOD Suite to SkyController 2",
    action: #selector(AppDelegate.uploadRFModSuiteToSkyController2(_:)),
    keyEquivalent: ""
)
uploadRFSC2Item.target = delegate
toolsMenu.addItem(uploadRFSC2Item)
toolsMenu.addItem(NSMenuItem.separator())
let installSC2DriverItem = NSMenuItem(
    title: "Install/Update SC2 Driver Patch",
    action: #selector(AppDelegate.installSC2DriverPatch(_:)),
    keyEquivalent: ""
)
installSC2DriverItem.target = delegate
toolsMenu.addItem(installSC2DriverItem)
toolsItem.submenu = toolsMenu
menu.addItem(toolsItem)
application.mainMenu = menu

application.run()
