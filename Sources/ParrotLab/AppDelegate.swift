import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var controller: MainViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let brandIcon = LabVisualStyle.brandIcon() {
            NSApp.applicationIconImage = brandIcon
        }
        let controller = MainViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.controller = controller
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func installDragonLabOnBebop2(_ sender: Any?) {
        controller?.installDragonLabOnBebop2()
    }

    @objc func enablePersistentTelnetOnBebop2(_ sender: Any?) {
        controller?.enablePersistentTelnetOnBebop2()
    }

    @objc func uploadRFModSuiteToBebop2(_ sender: Any?) {
        controller?.uploadRFModSuiteToBebop2()
    }

    @objc func uploadRFModSuiteToSkyController2(_ sender: Any?) {
        controller?.uploadRFModSuiteToSkyController2()
    }

    @objc func configureRFPowerMod(_ sender: Any?) {
        controller?.configureRFPowerMod()
    }

    @objc func selectVideoEnhancement(_ sender: Any?) {
        guard let selectedItem = sender as? NSMenuItem else { return }
        controller?.setVideoEnhancement(rawValue: selectedItem.tag)
        if let items = selectedItem.menu?.items {
            for item in items where item.action == #selector(AppDelegate.selectVideoEnhancement(_:)) {
                item.state = item === selectedItem ? .on : .off
            }
        }
    }

    @objc func installSC2DriverPatch(_ sender: Any?) {
        controller?.installSC2DriverPatch()
    }

    @objc func findSC2HostThroughBebop(_ sender: Any?) {
        controller?.findSC2HostThroughBebop()
    }

    @objc func findSC2USBHost(_ sender: Any?) {
        controller?.findSC2USBHost()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.prepareForTermination()
    }
}
