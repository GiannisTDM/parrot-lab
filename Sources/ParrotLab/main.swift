import AppKit

if CommandLine.arguments.contains("--self-test-sc3-maintenance") {
    exit(SC3MaintenanceSelfTest.run() && MainViewController.sc3OwnerMaintenanceSelfTest() && AppDelegate.toolsMenuSelfTest() ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test-sc3-rf") {
    exit(SC3RFSelfTest.run() ? 0 : 1)
}
if let index = CommandLine.arguments.firstIndex(of: "--render-sc3-rf"), CommandLine.arguments.indices.contains(index + 1) {
    do { let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching(); try SC3RFSelfTest.render(to: CommandLine.arguments[index + 1]); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of: "--check-sc3-rf"), CommandLine.arguments.indices.contains(index + 3),
   let port = UInt16(CommandLine.arguments[index + 2]) {
    do {
        let executor = try SC3RFADBExecutor(executable: CommandLine.arguments[index + 1], port: port, serial: CommandLine.arguments[index + 3])
        try executor.validateClient()
        let client = SC3RFClient(executor: executor, resources: try SC3RFResources())
        try client.prepare(); let before = try client.settings()
        let observed = try client.observe()
        let preview = try client.preview(hash: before.hash, pairs: ["gTxPowerCap", "20", "TxPower2g", "20", "TxPower5g", "20", "gAllowTPCfromAP", "0", "gFlexConnectPowerFactor", "1"])
        let after = try client.settings()
        guard before.hash == after.hash else { throw SC3RFError("INI changed during the read-only check.") }
        print("SC3 identity, RAM tools, settings, observation and preview passed; INI SHA-1 unchanged: \(after.hash). No apply/reboot/reload.")
        print("Associated: \(observed.peer != nil); chain values present: \(observed.a0 != nil)/\(observed.a1 != nil). Preview length: \(preview.utf8.count) bytes.")
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

if let index = CommandLine.arguments.firstIndex(of: "--check-sc3-video-startup"),
   CommandLine.arguments.indices.contains(index + 1) {
    let installer = SC3SumoVideoInstaller()
    var completed: Result<String, Error>?
    let started = installer.perform(.check, host: CommandLine.arguments[index + 1]) { completed = $0 }
    let deadline = Date().addingTimeInterval(90)
    while started, completed == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    switch completed {
    case .success(let message): print(message); exit(0)
    case .failure(let error): fputs("\(error.localizedDescription)\n", stderr)
    case nil: installer.cancel(); fputs("SC3 video preflight did not complete\n", stderr)
    }
    exit(1)
}

if CommandLine.arguments.contains("--self-test-sc3-video-installer") {
    let passed = SC3SumoVideoInstallerSelfTest.run() && AppDelegate.sc3SumoMenuSelfTest()
    print(passed ? "SC3 video installer and menu tests passed" : "SC3 video installer tests failed")
    exit(passed ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test-sc3-sumo-native") {
    let passed = SC3SumoNativeSelfTest.run() && SC3SumoMappingSelfTest.run()
    print(passed ? "Native SC3 Sumo host self-tests passed" : "Native SC3 Sumo self-tests failed")
    exit(passed ? 0 : 1)
}

if let index = CommandLine.arguments.firstIndex(of: "--probe-native-sc3"),
   CommandLine.arguments.indices.contains(index + 1) {
    func probeArgument(_ flag: String) -> String? {
        guard let at = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(at + 1) else { return nil }
        return CommandLine.arguments[at + 1]
    }
    let duration = probeArgument("--native-probe-seconds").flatMap(TimeInterval.init) ?? 4
    let jpeg = probeArgument("--native-probe-jpeg").map { URL(fileURLWithPath: $0) }
    exit(SC3SumoNativeSelfTest.probe(host: CommandLine.arguments[index + 1], duration: duration, jpegOutput: jpeg) ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test-sc3-sumo") {
    let checks = [("route and stale-state gate", SumoRelayDriveGate.selfTest()),
                  ("relay sockets and reconnect", SC3SumoRelaySelfTest.run()),
                  ("route UI and input loss", MainViewController.sc3SumoRouteInteractionSelfTest()),
                  ("relay tools/settings", AppDelegate.sc3SumoMenuSelfTest()),
                  ("input admission", FlightControlSelfTest.run())]
    for (name, passed) in checks where !passed { fputs("SC3 Sumo self-test failed: \(name)\n", stderr) }
    let passed = checks.allSatisfy { $0.1 }
    print(passed ? "Experimental SC3 Sumo route self-tests passed" : "SC3 Sumo self-tests failed")
    exit(passed ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test-sumo-follow") {
    let checks = [("control/expiry", SumoFollowControl.selfTest()),
                  ("tuning persistence", SumoTrackingConfiguration.selfTest()),
                  ("tuning controls", SumoTrackingTuningView.selfTest()),
                  ("motion presets", SumoTrackingPresetView.selfTest()),
                  ("tracking memory/cancellation", SumoSubjectTracker.selfTest()),
                  ("Vision compute devices", SumoVisionCompute.selfTest()),
                  ("target selection", HUDOverlayView.subjectSelectionSelfTest()),
                  ("Follow focus", MainViewController.sumoFollowInteractionSelfTest()),
                  ("Vision", SumoSubjectTracker.visionSmokeTest())]
    for (name, passed) in checks where !passed { fputs("Sumo following self-test failed: \(name)\n", stderr) }
    let passed = checks.allSatisfy { $0.1 }
    print(passed ? "Sumo following control, focus, expiry and cancellation self-tests passed" : "Sumo following self-tests failed")
    exit(passed ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test-sumo-compute") {
    let passed = SumoVisionCompute.selfTest()
    print(SumoVisionCompute.summary)
    print(passed ? "Sumo Vision compute-device checks passed" : "Sumo Vision compute-device checks failed")
    exit(passed ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test-sumo-audio") {
    let passed = SumoAudioProtocol.selfTest() && SumoSoundView.selfTest()
    print(passed ? "Sumo audio protocol, reliable transport and controls self-tests passed" : "Sumo audio self-tests failed")
    exit(passed ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test-sumo-swap") {
    exit(SumoDragonSwapSelfTest.run() ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test-ui") {
    let checks = [("Menus", AppDelegate.toolsMenuSelfTest()),
                  ("Settings", AppDelegate.settingsInteractionSelfTest()), ("Transitions", LabMotion.selfTest())]
    for (name, passed) in checks where !passed { fputs("UI self-test failed: \(name)\n", stderr) }
    let passed = checks.allSatisfy { $0.1 }
    print(passed ? "Menu, settings and transition self-tests passed" : "UI self-tests failed")
    exit(passed ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test-sc3-mux") {
    exit(SC3MuxSelfTest.run() ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test-anafi") {
    exit(AnafiSelfTest.run() ? 0 : 1)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-anafi-preview"),
   CommandLine.arguments.indices.contains(index + 1) {
    exit(PreviewRenderer.renderAnafi(to: CommandLine.arguments[index + 1]) ? 0 : 1)
}

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

if CommandLine.arguments.contains("--self-test-sc2-mux") {
    let passed = SC2MuxSelfTest.run()
    print(passed ? "SC2 libmux self-tests passed" : "SC2 libmux self-tests failed")
    exit(passed ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test") {
    exit(ParrotLabSelfTest.run())
}

if let index = CommandLine.arguments.firstIndex(of: "--render-sc2-mapping-preview"),
   CommandLine.arguments.indices.contains(index + 1) {
    exit(PreviewRenderer.renderSC2Mappings(to: CommandLine.arguments[index + 1]) ? 0 : 1)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-settings-preview"),
   CommandLine.arguments.indices.contains(index + 1) {
    exit(PreviewRenderer.renderSettings(
        to: CommandLine.arguments[index + 1],
        miniDrone: ProcessInfo.processInfo.environment["PARROTLAB_PREVIEW_MINIDRONE"] == "1"
    ) ? 0 : 1)
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

LabMenuBar.install(on: application, delegate: delegate)

application.run()
