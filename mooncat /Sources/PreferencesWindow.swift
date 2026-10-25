import AppKit

/// Preferences window, built entirely in code. Every control writes to
/// `Settings.shared`, and the cat reacts live through `Settings.didChange`.
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow

    private let followCheck = NSButton(checkboxWithTitle: "Follow my cursor", target: nil, action: nil)
    private let followDistance = NSSlider(value: 260, minValue: 100, maxValue: 600, target: nil, action: nil)
    private let followLabel = NSTextField(labelWithString: "")
    private let stopDistance = NSSlider(value: 150, minValue: 40, maxValue: 300, target: nil, action: nil)
    private let stopLabel = NSTextField(labelWithString: "")
    private let sleepDelay = NSSlider(value: 75, minValue: 10, maxValue: 600, target: nil, action: nil)
    private let sleepLabel = NSTextField(labelWithString: "")
    private let playFrequency = NSSlider(value: 1, minValue: 0, maxValue: 3, target: nil, action: nil)
    private let playLabel = NSTextField(labelWithString: "")
    private let sizeSlider = NSSlider(value: 1, minValue: 0.5, maxValue: 2, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")
    private let screenPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let soundsCheck = NSButton(checkboxWithTitle: "Sounds", target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let volumeSlider = NSSlider(value: 0.7, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeLabel = NSTextField(labelWithString: "")
    private let moodCheck = NSButton(checkboxWithTitle: "Mood follows time of day and battery", target: nil, action: nil)
    private let workSlider = NSSlider(value: 25, minValue: 5, maxValue: 90, target: nil, action: nil)
    private let workLabel = NSTextField(labelWithString: "")
    private let breakSlider = NSSlider(value: 5, minValue: 1, maxValue: 30, target: nil, action: nil)
    private let breakLabel = NSTextField(labelWithString: "")
    private let longBreakSlider = NSSlider(value: 15, minValue: 5, maxValue: 60, target: nil, action: nil)
    private let longBreakLabel = NSTextField(labelWithString: "")
    private let loginStatus = NSTextField(wrappingLabelWithString: "")

    private let shortcutButton = ShortcutRecorderButton(title: "", target: nil, action: nil)
    private let shortcutResetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let shortcutStatus = NSTextField(wrappingLabelWithString: "")
    private var shortcutNote: (text: String, isError: Bool)?

    private let forgetCheck = NSButton(checkboxWithTitle: "Offer to forget old items", target: nil, action: nil)
    private let forgetSlider = NSSlider(value: 90, minValue: 1, maxValue: 365, target: nil, action: nil)
    private let forgetLabel = NSTextField(labelWithString: "")
    private let forgetHint = NSTextField(wrappingLabelWithString: "")

    private var screenIDs: [Int] = []

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered,
                          defer: false)
        super.init()
        window.title = "Moon Cat Preferences"
        Theme.style(window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        refresh()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)
        nc.addObserver(self, selector: #selector(settingsChanged), name: LoginItem.didChange, object: nil)
        nc.addObserver(self, selector: #selector(settingsChanged), name: HotKey.statusDidChange, object: nil)
        nc.addObserver(self, selector: #selector(screensChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: Layout

    private func build() {
        for s in [followDistance, stopDistance, sleepDelay, playFrequency, sizeSlider, forgetSlider,
                  volumeSlider, workSlider, breakSlider, longBreakSlider] {
            s.target = self
            s.action = #selector(sliderChanged(_:))
            s.isContinuous = true
            s.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
        for b in [followCheck, soundsCheck, loginCheck, forgetCheck, moodCheck] {
            b.target = self
            b.action = #selector(checkChanged(_:))
        }
        screenPopup.target = self
        screenPopup.action = #selector(screenChanged(_:))

        for l in [followLabel, stopLabel, sleepLabel, playLabel, sizeLabel, forgetLabel,
                  volumeLabel, workLabel, breakLabel, longBreakLabel] {
            l.alignment = .left
            l.textColor = .secondaryLabelColor
            l.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
        loginStatus.textColor = .secondaryLabelColor
        loginStatus.font = NSFont.systemFont(ofSize: 11)
        loginStatus.preferredMaxLayoutWidth = 240

        // Global shortcut: click the button, then press the new combination.
        shortcutButton.bezelStyle = .rounded
        shortcutButton.target = self
        shortcutButton.action = #selector(shortcutClicked)
        shortcutButton.widthAnchor.constraint(equalToConstant: 140).isActive = true
        shortcutButton.onCapture = { [weak self] code, mods in self?.applyShortcut(code: code, modifiers: mods) }
        shortcutButton.onRecordingChanged = { [weak self] on in self?.shortcutRecordingChanged(on) }
        shortcutButton.onHint = { [weak self] message in self?.setShortcutNote(message, isError: true) }
        shortcutResetButton.bezelStyle = .rounded
        shortcutResetButton.target = self
        shortcutResetButton.action = #selector(resetShortcut)
        let shortcutRow = NSStackView(views: [shortcutButton, shortcutResetButton])
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 8
        shortcutStatus.font = NSFont.systemFont(ofSize: 11)
        shortcutStatus.preferredMaxLayoutWidth = 240

        forgetHint.stringValue = "When on, I'll tell you how many items are older than this, and only delete them if you say so."
        forgetHint.textColor = .secondaryLabelColor
        forgetHint.font = NSFont.systemFont(ofSize: 11)
        forgetHint.preferredMaxLayoutWidth = 240

        func name(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.alignment = .right
            return t
        }
        let blank = NSView()

        var rows: [[NSView]] = [
            [name("Size"), sizeSlider, sizeLabel],
            [name("Follow distance"), followDistance, followLabel],
            [name("Stop distance"), stopDistance, stopLabel],
            [name("Falls asleep after"), sleepDelay, sleepLabel],
            [name("Play frequency"), playFrequency, playLabel],
            [name("She lives on"), screenPopup, blank],
            [name("Shortcut"), shortcutRow, NSView()],
            [name(""), shortcutStatus, NSView()],
            [name(""), followCheck, NSView()],
            [name(""), soundsCheck, NSView()],
            [name("Volume"), volumeSlider, volumeLabel],
            [name(""), moodCheck, NSView()],
            [name(""), loginCheck, NSView()],
            [name(""), loginStatus, NSView()]
        ]
        let focusHeaderRow = rows.count
        let focusHeader = NSTextField(labelWithString: "Focus timer")
        focusHeader.font = Theme.font(14, .semibold, rounded: true)
        focusHeader.textColor = Theme.accent
        rows.append([focusHeader, NSView(), NSView()])
        rows.append([name("Focus"), workSlider, workLabel])
        rows.append([name("Short break"), breakSlider, breakLabel])
        rows.append([name("Long break"), longBreakSlider, longBreakLabel])
        let headerRow = rows.count
        let header = NSTextField(labelWithString: "Treasure Box")
        header.font = Theme.font(14, .semibold, rounded: true)
        header.textColor = Theme.accent
        rows.append([header, NSView(), NSView()])
        rows.append([name(""), forgetCheck, NSView()])
        rows.append([name("Forget after"), forgetSlider, forgetLabel])
        rows.append([name(""), forgetHint, NSView()])

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 9
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: headerRow).mergeCells(in: NSRange(location: 0, length: 3))
        grid.row(at: headerRow).topPadding = 10
        grid.cell(atColumnIndex: 0, rowIndex: headerRow).xPlacement = .leading
        grid.row(at: focusHeaderRow).mergeCells(in: NSRange(location: 0, length: 3))
        grid.row(at: focusHeaderRow).topPadding = 10
        grid.cell(atColumnIndex: 0, rowIndex: focusHeaderRow).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false

        guard let content = window.contentView else { return }
        let gridCard = Theme.card(grid, padding: 20)
        // The settings scroll, so the window never grows taller than the screen.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let doc = ThemeFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(gridCard)
        scroll.documentView = doc
        content.addSubview(scroll)
        content.addSubview(reset)
        NSLayoutConstraint.activate([
            gridCard.topAnchor.constraint(equalTo: doc.topAnchor),
            gridCard.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            gridCard.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            gridCard.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor)
        ])
        var scrollTop = scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 8)
        var heroHeight: CGFloat = 0
        if let hero = Art.banner("prefs_hero", width: 540 - 2 * Theme.pad, height: 110) {
            content.addSubview(hero)
            NSLayoutConstraint.activate([
                hero.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
                hero.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.pad)
            ])
            scrollTop = scroll.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 14)
            heroHeight = 110 + 14
        }
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        let fit = gridCard.fittingSize.height
        let scrollH = max(220, min(fit, screenH - 140 - heroHeight - 70))
        NSLayoutConstraint.activate([
            scrollTop,
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.pad),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.pad),
            scroll.heightAnchor.constraint(equalToConstant: scrollH),
            reset.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 16),
            reset.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.pad),
            reset.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Theme.pad)
        ])
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 540, height: content.fittingSize.height))
    }

    // MARK: Showing

    func show() {
        shortcutNote = nil
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Window delegate (stop recording a shortcut if the window goes away)

    func windowDidResignKey(_ notification: Notification) {
        if shortcutButton.isRecording { shortcutButton.endRecording() }
    }

    func windowWillClose(_ notification: Notification) {
        if shortcutButton.isRecording { shortcutButton.endRecording() }
    }

    // MARK: Syncing controls from Settings

    @objc private func settingsChanged() { refresh() }
    @objc private func screensChanged() { refresh() }

    private func refresh() {
        let s = Settings.shared
        followCheck.state = s.follow ? .on : .off
        followDistance.doubleValue = s.followDistance
        followLabel.stringValue = "\(Int(s.followDistance)) px"
        stopDistance.doubleValue = s.stopDistance
        stopLabel.stringValue = "\(Int(s.stopDistance)) px"
        sleepDelay.doubleValue = s.sleepDelay
        sleepLabel.stringValue = Self.durationText(s.sleepDelay)
        playFrequency.doubleValue = s.playFrequency
        playLabel.stringValue = s.playFrequency < 0.05 ? "Never" : String(format: "%.1f×", s.playFrequency)
        sizeSlider.doubleValue = s.scale
        sizeLabel.stringValue = "\(Int((s.scale * 100).rounded()))%"
        soundsCheck.state = s.soundsEnabled ? .on : .off
        volumeSlider.doubleValue = s.soundVolume
        volumeSlider.isEnabled = s.soundsEnabled
        volumeLabel.stringValue = "\(Int((s.soundVolume * 100).rounded()))%"
        moodCheck.state = s.moodEnabled ? .on : .off
        workSlider.doubleValue = Double(s.pomodoroWorkMinutes)
        workLabel.stringValue = "\(s.pomodoroWorkMinutes) min"
        breakSlider.doubleValue = Double(s.pomodoroBreakMinutes)
        breakLabel.stringValue = "\(s.pomodoroBreakMinutes) min"
        longBreakSlider.doubleValue = Double(s.pomodoroLongBreakMinutes)
        longBreakLabel.stringValue = "\(s.pomodoroLongBreakMinutes) min"

        if !shortcutButton.isRecording {
            shortcutButton.title = HotKey.shared.displayString
        }
        updateShortcutStatus()

        forgetCheck.state = s.autoForgetEnabled ? .on : .off
        forgetSlider.doubleValue = Double(s.autoForgetDays)
        forgetSlider.isEnabled = s.autoForgetEnabled
        forgetLabel.stringValue = s.autoForgetDays == 1 ? "1 day" : "\(s.autoForgetDays) days"

        rebuildScreenPopup()

        loginCheck.state = (LoginItem.isEnabled || LoginItem.needsApproval) ? .on : .off
        loginStatus.stringValue = LoginItem.statusText
    }

    private func rebuildScreenPopup() {
        screenPopup.removeAllItems()
        screenIDs = [0]
        screenPopup.addItem(withTitle: "Automatic (any screen)")
        for screen in NSScreen.screens {
            screenIDs.append(Settings.displayID(of: screen))
            screenPopup.addItem(withTitle: screen.localizedName)
        }
        let current = Settings.shared.screenID
        if let idx = screenIDs.firstIndex(of: current) {
            screenPopup.selectItem(at: idx)
        } else {
            // The chosen display is unplugged: show automatic, but keep the setting.
            screenPopup.selectItem(at: 0)
        }
    }

    private static func durationText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 120 { return "\(s) sec" }
        return String(format: "%.1f min", Double(s) / 60.0)
    }

    // MARK: Actions

    @objc private func sliderChanged(_ sender: NSSlider) {
        let s = Settings.shared
        if sender === sizeSlider {
            s.scale = (sender.doubleValue * 20).rounded() / 20      // steps of 5%
        } else if sender === followDistance {
            s.followDistance = sender.doubleValue.rounded()
            // Stop distance must stay comfortably below follow distance.
            if s.stopDistance > s.followDistance - 20 { s.stopDistance = max(40, s.followDistance - 20) }
        } else if sender === stopDistance {
            s.stopDistance = sender.doubleValue.rounded()
            if s.followDistance < s.stopDistance + 20 { s.followDistance = min(600, s.stopDistance + 20) }
        } else if sender === sleepDelay {
            s.sleepDelay = sender.doubleValue.rounded()
        } else if sender === playFrequency {
            let v = (sender.doubleValue * 10).rounded() / 10
            s.playFrequency = v < 0.1 ? 0 : v
        } else if sender === forgetSlider {
            s.autoForgetDays = Int(sender.doubleValue.rounded())
        } else if sender === volumeSlider {
            s.soundVolume = (sender.doubleValue * 20).rounded() / 20
        } else if sender === workSlider {
            s.pomodoroWorkMinutes = Int(sender.doubleValue.rounded())
        } else if sender === breakSlider {
            s.pomodoroBreakMinutes = Int(sender.doubleValue.rounded())
        } else if sender === longBreakSlider {
            s.pomodoroLongBreakMinutes = Int(sender.doubleValue.rounded())
        }
    }

    @objc private func checkChanged(_ sender: NSButton) {
        let on = sender.state == .on
        if sender === followCheck {
            Settings.shared.follow = on
        } else if sender === soundsCheck {
            Settings.shared.soundsEnabled = on
        } else if sender === moodCheck {
            Settings.shared.moodEnabled = on
        } else if sender === forgetCheck {
            Settings.shared.autoForgetEnabled = on
        } else if sender === loginCheck {
            if case .failure(let error) = LoginItem.set(on) {
                let a = NSAlert()
                a.messageText = "I couldn't change the login setting."
                a.informativeText = error.localizedDescription
                a.alertStyle = .warning
                a.beginSheetModal(for: window, completionHandler: nil)
            } else if on && LoginItem.needsApproval {
                LoginItem.openSystemSettings()
            }
            refresh()
        }
    }

    @objc private func screenChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0 && i < screenIDs.count else { return }
        Settings.shared.screenID = screenIDs[i]
    }

    // MARK: Shortcut

    @objc private func shortcutClicked() {
        if shortcutButton.isRecording {
            shortcutButton.endRecording()
        } else {
            shortcutNote = nil
            shortcutButton.beginRecording()
            window.makeFirstResponder(shortcutButton)
        }
    }

    /// While recording, the old shortcut is switched off so that pressing it again can be recorded.
    private func shortcutRecordingChanged(_ recording: Bool) {
        if recording {
            HotKey.shared.unregister()
        } else {
            HotKey.shared.register()
        }
        refresh()
    }

    private func applyShortcut(code: Int, modifiers: Int) {
        let text = HotKey.displayString(keyCode: code, modifiers: modifiers)
        switch HotKey.shared.rebind(keyCode: code, modifiers: modifiers) {
        case .ok:
            shortcutNote = nil
        case .taken:
            shortcutNote = ("\(text) is already taken by macOS or another app. Pick a different shortcut; the old one is still active.", true)
        case .failed(let err):
            shortcutNote = ("macOS would not register \(text) (error \(err)). Pick a different shortcut.", true)
        }
        refresh()
    }

    @objc private func resetShortcut() {
        if shortcutButton.isRecording { shortcutButton.endRecording() }
        applyShortcut(code: Settings.defaultHotKeyCode, modifiers: Settings.defaultHotKeyModifiers)
    }

    private func setShortcutNote(_ text: String, isError: Bool) {
        shortcutNote = (text, isError)
        updateShortcutStatus()
    }

    private func updateShortcutStatus() {
        if let note = shortcutNote {
            shortcutStatus.stringValue = note.text
            shortcutStatus.textColor = note.isError ? .systemRed : .secondaryLabelColor
            return
        }
        if shortcutButton.isRecording {
            shortcutStatus.stringValue = "Press the new shortcut. It needs ⌘, ⌥ or ⌃. Esc cancels."
            shortcutStatus.textColor = .secondaryLabelColor
            return
        }
        switch HotKey.shared.status {
        case .registered:
            shortcutStatus.stringValue = "Press it anywhere to search the Treasure Box."
            shortcutStatus.textColor = .secondaryLabelColor
        case .unregistered:
            shortcutStatus.stringValue = "The shortcut is not active right now."
            shortcutStatus.textColor = .secondaryLabelColor
        case .taken:
            shortcutStatus.stringValue = "This shortcut is already taken by macOS or another app, so it is not active. Record a different one."
            shortcutStatus.textColor = .systemRed
        case .failed(let err):
            shortcutStatus.stringValue = "macOS would not register this shortcut (error \(err)). Record a different one."
            shortcutStatus.textColor = .systemRed
        }
    }

    @objc private func resetDefaults() {
        let a = NSAlert()
        a.messageText = "Reset all preferences to their defaults?"
        a.informativeText = "This does not change your launch-at-login setting or your Treasure Box."
        a.addButton(withTitle: "Reset")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { Settings.shared.resetToDefaults() }
        }
    }
}

// MARK: - Shortcut recorder

/// A button that records a key combination. Click it, press the new shortcut (it must include
/// ⌘, ⌥ or ⌃), or press Esc to cancel. Pure AppKit: it listens with a local key monitor, which
/// only sees MoonCat's own key events and needs no Accessibility permission.
final class ShortcutRecorderButton: NSButton {
    /// Called with the key code and the Carbon modifier mask once a valid combination is pressed.
    var onCapture: ((Int, Int) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var onHint: ((String) -> Void)?
    private(set) var isRecording = false
    private var monitor: Any?

    func beginRecording() {
        if isRecording { return }
        isRecording = true
        title = "Type shortcut…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, self.isRecording else { return event }
            return self.handle(event) ? nil : event
        }
        onRecordingChanged?(true)
    }

    func endRecording() {
        if !isRecording { return }
        isRecording = false
        removeMonitor()
        onRecordingChanged?(false)
    }

    private func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 && flags.isEmpty {          // Esc cancels
            endRecording()
            return true
        }
        if event.isARepeat { return true }
        if flags.intersection([.command, .option, .control]).isEmpty {
            onHint?("Include ⌘, ⌥ or ⌃, so the shortcut does not get in the way of typing.")
            return true
        }
        let code = Int(event.keyCode)
        let mods = HotKey.carbonModifiers(from: flags)
        isRecording = false
        removeMonitor()
        onCapture?(code, mods)
        onRecordingChanged?(false)
        return true
    }

    deinit {
        removeMonitor()
    }
}
