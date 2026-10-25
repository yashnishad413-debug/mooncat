import AppKit

/// Chat settings, in a small window of its own (menu: "Chat settings…").
final class ChatSettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = ChatSettingsWindowController()

    private let window: NSWindow
    private let enableCheck = NSButton(checkboxWithTitle: "Turn chat on", target: nil, action: nil)
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let baseURLField = NSTextField(string: "")
    private let modelField = NSTextField(string: "")
    private let keyField = NSSecureTextField(string: "")
    private let saveKeyButton = NSButton(title: "Save key", target: nil, action: nil)
    private let removeKeyButton = NSButton(title: "Remove key", target: nil, action: nil)
    private let keyStatus = NSTextField(labelWithString: "")
    private let findModelsButton = NSButton(title: "Find models", target: nil, action: nil)
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let testButton = NSButton(title: "Test connection", target: nil, action: nil)
    private let testStatus = NSTextField(wrappingLabelWithString: "")
    private let historySlider = NSSlider(value: 10, minValue: 0, maxValue: 30, target: nil, action: nil)
    private let historyLabel = NSTextField(labelWithString: "")
    private let personality = NSTextField(wrappingLabelWithString: "")
    private let personalityButton = NSButton(title: "Edit personality…", target: nil, action: nil)
    private let privacy = NSTextField(wrappingLabelWithString: "")
    private let testClient = ChatClient()

    private var grid: NSGridView!

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Chat settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        refresh()
    }

    func show() {
        refresh()
        activateApp()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private func build() {
        guard let content = window.contentView else { return }

        for k in ChatProviderKind.allCases { providerPopup.addItem(withTitle: k.title) }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        enableCheck.target = self
        enableCheck.action = #selector(enableChanged)

        for f in [baseURLField, modelField, keyField] {
            f.delegate = self
            f.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveKey)
        removeKeyButton.target = self
        removeKeyButton.action = #selector(removeKey)
        testButton.target = self
        testButton.action = #selector(testConnection)
        findModelsButton.target = self
        findModelsButton.action = #selector(findModels)
        modelPopup.target = self
        modelPopup.action = #selector(modelPicked)
        modelPopup.isHidden = true
        personalityButton.target = self
        personalityButton.action = #selector(editPersonality)
        historySlider.target = self
        historySlider.action = #selector(historyChanged)
        historySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        historyLabel.textColor = .secondaryLabelColor

        for t in [keyStatus, testStatus, hint, privacy, personality] {
            t.textColor = .secondaryLabelColor
            t.font = NSFont.systemFont(ofSize: 11)
            t.preferredMaxLayoutWidth = 320
        }
        privacy.stringValue = "Messages are sent to the provider you choose. Free tiers may log them, so don't type anything private. Ollama keeps everything on this Mac. The API key is stored encrypted, protected by your MoonCat password."
        personality.maximumNumberOfLines = 3
        personality.lineBreakMode = .byTruncatingTail

        func name(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.alignment = .right
            return t
        }
        let keyButtons = NSStackView(views: [saveKeyButton, removeKeyButton, keyStatus])
        keyButtons.spacing = 8
        let modelRow = NSStackView(views: [modelField, findModelsButton, modelPopup])
        modelRow.spacing = 8
        let historyRow = NSStackView(views: [historySlider, historyLabel])
        historyRow.spacing = 8

        let g = NSGridView(views: [
            [NSView(), enableCheck],
            [name("Provider"), providerPopup],
            [NSView(), hint],
            [name("Server"), baseURLField],
            [name("Model"), modelRow],
            [name("API key"), keyField],
            [NSView(), keyButtons],
            [name("Remember"), historyRow],
            [name("Personality"), personality],
            [NSView(), personalityButton],
            [NSView(), testButton],
            [NSView(), testStatus],
            [NSView(), privacy]
        ])
        g.translatesAutoresizingMaskIntoConstraints = false
        g.rowSpacing = 8
        g.columnSpacing = 10
        g.column(at: 0).xPlacement = .trailing
        grid = g
        content.addSubview(g)
        NSLayoutConstraint.activate([
            g.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            g.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            g.topAnchor.constraint(equalTo: content.topAnchor, constant: 18)
        ])
    }

    // MARK: State

    private var kind: ChatProviderKind {
        let i = max(0, providerPopup.indexOfSelectedItem)
        return ChatProviderKind.allCases[i]
    }

    private func hasKey(_ k: ChatProviderKind) -> Bool {
        return KeychainStore.exists(account: k.keyAccount)
    }

    private func refresh() {
        let st = Settings.shared
        enableCheck.state = st.chatEnabled ? .on : .off
        if let i = ChatProviderKind.allCases.firstIndex(of: st.chatProviderKind) { providerPopup.selectItem(at: i) }
        modelField.stringValue = st.chatModel
        baseURLField.stringValue = st.chatBaseURL
        historySlider.integerValue = st.chatHistoryCount
        historyLabel.stringValue = st.chatHistoryCount == 0 ? "nothing" : "last \(st.chatHistoryCount) messages"
        personality.stringValue = st.chatPersonality
        updateProviderUI()
    }

    private func updateProviderUI() {
        let k = kind
        hint.stringValue = k.keyHint
        let showKey = k.needsKey
        grid.row(at: 3).isHidden = !k.usesBaseURL     // server address
        grid.row(at: 5).isHidden = !showKey           // key field
        grid.row(at: 6).isHidden = !showKey           // save / remove
        keyStatus.stringValue = hasKey(k) ? "A key is saved." : "No key saved yet."
        keyField.placeholderString = hasKey(k) ? "(saved, type to replace)" : "paste your key"
        testStatus.stringValue = ""
    }

    // MARK: Actions

    @objc private func enableChanged() {
        Settings.shared.chatEnabled = enableCheck.state == .on
    }

    @objc private func providerChanged() {
        let k = kind
        let st = Settings.shared
        st.chatProviderKind = k
        // Different provider, different sensible defaults.
        st.chatModel = k.defaultModel
        st.chatBaseURL = k.defaultBaseURL
        modelField.stringValue = k.defaultModel
        baseURLField.stringValue = k.defaultBaseURL
        keyField.stringValue = ""
        updateProviderUI()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        let value = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if f === modelField { Settings.shared.chatModel = value }
        if f === baseURLField { Settings.shared.chatBaseURL = value }
    }

    @objc private func saveKey() {
        let value = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { keyStatus.stringValue = "Paste a key first."; return }
        do {
            try KeychainStore.save(value, account: kind.keyAccount)
            keyField.stringValue = ""
            updateProviderUI()
            keyStatus.stringValue = "Saved."
        } catch {
            keyStatus.stringValue = "Couldn't save the key (password needed)."
            Log.error("Chat key could not be saved")
        }
    }

    @objc private func removeKey() {
        try? KeychainStore.delete(account: kind.keyAccount)
        keyField.stringValue = ""
        updateProviderUI()
        keyStatus.stringValue = "Key removed."
    }

    @objc private func findModels() {
        Settings.shared.chatProviderKind = kind
        Settings.shared.chatBaseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyField.stringValue.isEmpty { saveKey() }
        testStatus.stringValue = "Looking for models…"
        findModelsButton.isEnabled = false
        testClient.listModels(kind: kind) { [weak self] names in
            guard let self = self else { return }
            self.findModelsButton.isEnabled = true
            if names.isEmpty {
                self.testStatus.stringValue = "Couldn't get a list. Check the key and server, then try again."
                self.modelPopup.isHidden = true
                return
            }
            self.testStatus.stringValue = "Found \(names.count) models. Pick one from the menu."
            self.modelPopup.removeAllItems()
            self.modelPopup.addItem(withTitle: "Pick…")
            for n in names { self.modelPopup.addItem(withTitle: n) }
            self.modelPopup.isHidden = false
        }
    }

    @objc private func modelPicked() {
        guard modelPopup.indexOfSelectedItem > 0, let t = modelPopup.titleOfSelectedItem else { return }
        modelField.stringValue = t
        Settings.shared.chatModel = t
        testStatus.stringValue = "Model set to \(t)."
    }

    @objc private func historyChanged() {
        Settings.shared.chatHistoryCount = historySlider.integerValue
        refresh()
    }

    @objc private func testConnection() {
        // Apply whatever is typed first.
        Settings.shared.chatModel = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.shared.chatBaseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyField.stringValue.isEmpty { saveKey() }
        guard Settings.shared.chatEnabled else {
            testStatus.stringValue = "Turn chat on first."
            return
        }
        testStatus.stringValue = "Testing…"
        testButton.isEnabled = false
        testClient.send([ChatMessage(role: .user, text: "Say hi in five words.")]) { [weak self] result in
            guard let self = self else { return }
            self.testButton.isEnabled = true
            switch result {
            case .success(let text): self.testStatus.stringValue = "Works. Moon says: " + text
            case .failure(let e): self.testStatus.stringValue = e.errorDescription ?? "Failed."
            }
        }
    }

    @objc private func editPersonality() {
        let alert = NSAlert()
        alert.messageText = "Moon's personality"
        alert.informativeText = "This is sent to the provider as instructions with every message."
        let sv = NSTextView.scrollableTextView()
        sv.frame = NSRect(x: 0, y: 0, width: 360, height: 120)
        let tv = sv.documentView as! NSTextView
        tv.string = Settings.shared.chatPersonality
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 12)
        sv.borderType = .bezelBorder
        alert.accessoryView = sv
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Reset to default")
        alert.addButton(withTitle: "Cancel")
        activateApp()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let t = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
            Settings.shared.chatPersonality = t.isEmpty ? Settings.defaultPersonality : t
        case .alertSecondButtonReturn:
            Settings.shared.chatPersonality = Settings.defaultPersonality
        default: break
        }
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        testClient.cancel()
    }
}
