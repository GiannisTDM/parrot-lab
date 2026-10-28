import AppKit

/// Settings for Sumo's own built-in sounds. Incoming telemetry never sends commands.
final class SumoSoundView: NSStackView {
    var onVolume: ((UInt8) -> Void)?
    var onTheme: ((SumoAudioTheme) -> Void)?

    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let volumeSlider = NSSlider(value: 50, minValue: 0, maxValue: 100,
                                        target: nil, action: nil)
    private let volumeValue = NSTextField(labelWithString: "—")
    private let stateLabel = NSTextField(wrappingLabelWithString: "Connect to Sumo to change its sounds.")
    private var connected = false
    private var confirmedVolume: UInt8?
    private var confirmedTheme: SumoAudioTheme?
    private var pendingVolume: UInt8?
    private var pendingTheme: SumoAudioTheme?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .leading
        spacing = 7
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 274).isActive = true

        themePopup.addItem(withTitle: "Choose theme…")
        themePopup.item(at: 0)?.tag = -1
        themePopup.item(at: 0)?.isEnabled = false
        for theme in SumoAudioTheme.allCases {
            themePopup.addItem(withTitle: theme.title)
            themePopup.lastItem?.tag = Int(theme.rawValue)
        }
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        themePopup.controlSize = .small
        let themeRow = NSStackView(views: [label("Personality"), themePopup])
        themeRow.alignment = .centerY
        themeRow.spacing = 8
        addArrangedSubview(themeRow)
        themeRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        themePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        volumeValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        volumeValue.textColor = LabVisualStyle.mutedText
        volumeValue.alignment = .right
        let volumeRow = NSStackView(views: [label("Speaker volume"), NSView(), volumeValue])
        volumeRow.alignment = .centerY
        addArrangedSubview(volumeRow)
        volumeRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        volumeSlider.controlSize = .small
        volumeSlider.isContinuous = false // Commit once when the user releases the slider.
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        addArrangedSubview(volumeSlider)
        volumeSlider.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        stateLabel.font = .systemFont(ofSize: 10)
        stateLabel.textColor = LabVisualStyle.mutedText
        addArrangedSubview(stateLabel)
        stateLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let note = NSTextField(wrappingLabelWithString:
            "Original Sumo supports built-in personalities. Custom voice clips are unavailable through its SDK.")
        note.font = .systemFont(ofSize: 10)
        note.textColor = LabVisualStyle.mutedText
        addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        setConnected(false)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    func setConnected(_ isConnected: Bool) {
        connected = isConnected
        themePopup.isEnabled = isConnected
        volumeSlider.isEnabled = isConnected
        if !isConnected {
            confirmedVolume = nil
            confirmedTheme = nil
            pendingVolume = nil
            pendingTheme = nil
            themePopup.selectItem(at: 0)
            volumeSlider.doubleValue = 50
            volumeValue.stringValue = "—"
        }
        refreshState()
    }

    func apply(volume: UInt8) {
        guard connected, volume <= 100 else { return }
        confirmedVolume = volume
        if pendingVolume == volume { pendingVolume = nil }
        if pendingVolume == nil {
            volumeSlider.integerValue = Int(volume)
            volumeValue.stringValue = "\(volume)%"
        }
        refreshState()
    }

    func apply(theme: SumoAudioTheme) {
        guard connected else { return }
        confirmedTheme = theme
        if pendingTheme == theme { pendingTheme = nil }
        if pendingTheme == nil { themePopup.selectItem(withTag: Int(theme.rawValue)) }
        refreshState()
    }

    @objc private func volumeChanged() {
        guard connected, let onVolume else { return }
        let value = UInt8(clamping: min(100, max(0, volumeSlider.integerValue)))
        guard pendingVolume != value,
              pendingVolume != nil || confirmedVolume != value else { return }
        pendingVolume = value
        volumeValue.stringValue = "\(value)%"
        refreshState()
        onVolume(value)
    }

    @objc private func themeChanged() {
        guard connected, let onTheme,
              let tag = themePopup.selectedItem?.tag,
              let theme = SumoAudioTheme(rawValue: Int32(clamping: tag)),
              pendingTheme != theme,
              pendingTheme != nil || confirmedTheme != theme else { return }
        pendingTheme = theme
        refreshState()
        onTheme(theme)
    }

    private func refreshState() {
        if !connected {
            stateLabel.stringValue = "Connect to Sumo to change its sounds."
        } else if pendingVolume != nil || pendingTheme != nil {
            stateLabel.stringValue = "Change sent · waiting for Sumo confirmation."
        } else if confirmedVolume != nil && confirmedTheme != nil {
            stateLabel.stringValue = "Sound settings confirmed by Sumo."
        } else {
            stateLabel.stringValue = "Waiting for Sumo sound settings."
        }
    }

    private func label(_ title: String) -> NSTextField {
        let view = NSTextField(labelWithString: title)
        view.font = .systemFont(ofSize: 11)
        return view
    }

    static func selfTest() -> Bool {
        _ = NSApplication.shared
        let view = SumoSoundView()
        var volumes: [UInt8] = []
        var themes: [SumoAudioTheme] = []
        view.onVolume = { volumes.append($0) }
        view.onTheme = { themes.append($0) }
        guard !view.volumeSlider.isEnabled, !view.themePopup.isEnabled,
              !view.volumeSlider.isContinuous else { return false }
        view.apply(volume: 20)
        view.apply(theme: .robot)
        view.volumeSlider.integerValue = 70
        view.volumeChanged()
        view.themePopup.selectItem(withTag: 1)
        view.themeChanged()
        guard volumes.isEmpty, themes.isEmpty, view.confirmedVolume == nil,
              view.confirmedTheme == nil else { return false }

        view.setConnected(true)
        view.apply(volume: 35)
        view.apply(theme: .insect)
        view.setConnected(true) // Frequent status refreshes preserve confirmed settings.
        guard volumes.isEmpty, themes.isEmpty, view.volumeSlider.integerValue == 35,
              view.themePopup.selectedTag() == 2,
              view.stateLabel.stringValue == "Sound settings confirmed by Sumo." else { return false }
        view.volumeSlider.integerValue = 60
        view.volumeChanged()
        view.volumeChanged()
        view.themePopup.selectItem(withTag: 3)
        view.themeChanged()
        view.themeChanged()
        guard volumes == [60], themes == [.monster], view.pendingVolume == 60,
              view.pendingTheme == .monster else { return false }
        view.apply(volume: 35) // Older telemetry must not overwrite a pending adjustment.
        view.apply(theme: .insect)
        guard view.pendingVolume == 60, view.volumeSlider.integerValue == 60,
              view.pendingTheme == .monster, view.themePopup.selectedTag() == 3 else { return false }
        view.apply(volume: 60)
        view.apply(theme: .monster)
        guard view.pendingVolume == nil, view.pendingTheme == nil,
              volumes == [60], themes == [.monster] else { return false }
        view.setConnected(false)
        view.apply(volume: 80)
        view.apply(theme: .robot)
        view.volumeChanged()
        view.themeChanged()
        view.setConnected(true)
        return volumes == [60] && themes == [.monster] && view.confirmedVolume == nil &&
            view.confirmedTheme == nil && view.themePopup.selectedTag() == -1 &&
            view.volumeValue.stringValue == "—" &&
            view.stateLabel.stringValue == "Waiting for Sumo sound settings."
    }
}
