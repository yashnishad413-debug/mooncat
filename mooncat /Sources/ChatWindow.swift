import AppKit

/// "Chat with Moon". Nothing is sent anywhere unless chat is enabled in Chat settings and you press Send.
/// The conversation lives in memory only: closing the app (or pressing Clear) forgets it.
final class ChatWindowController: NSObject, NSWindowDelegate {
    static let shared = ChatWindowController()

    /// Called with each reply so the cat can react.
    var onCatReply: ((String) -> Void)?

    private let window: NSWindow
    private let transcript: NSTextView
    private let scroll: NSScrollView
    private let input = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Chat settings…", target: nil, action: nil)
    private let client = ChatClient()
    private let storageToggle = NSButton(checkboxWithTitle: "Let Moon use the Treasure Box", target: nil, action: nil)
    private var generation = 0
    private var pendingAlert: NSAlert?
    private var status = "Moon is thinking…"

    private var messages: [ChatMessage] = []
    private var waiting = false
    private var errorLine: String?

    private override init() {
        let sv = NSTextView.scrollableTextView()
        scroll = sv
        transcript = sv.documentView as! NSTextView
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Chat with Moon"
        Theme.style(window)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 360)
        window.delegate = self
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)
    }

    private var placed = false

    func show() {
        Log.info("Chat window: show requested")
        render()
        activateApp()
        if !placed { window.center(); placed = true }
        if window.isMiniaturized { window.deminiaturize(nil) }
        // The cat floats above other windows; keep the chat above them too so it can't open hidden.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if input.isEnabled { window.makeFirstResponder(input) }
        Log.info("Chat window: visible=\(window.isVisible) frame=\(NSStringFromRect(window.frame))")
    }

    // MARK: Layout

    private func build() {
        guard let content = window.contentView else { return }

        transcript.isEditable = false
        transcript.isRichText = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 6, height: 8)

        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        input.placeholderString = "Say something to Moon…"
        input.target = self
        input.action = #selector(sendPressed)
        input.translatesAutoresizingMaskIntoConstraints = false
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for (b, sel) in [(sendButton, #selector(sendPressed)), (stopButton, #selector(stopPressed)),
                         (clearButton, #selector(clearPressed)), (settingsButton, #selector(openSettings))] {
            b.target = self
            b.action = sel
            b.bezelStyle = .rounded
        }
        sendButton.keyEquivalent = "\r"
        storageToggle.target = self
        storageToggle.action = #selector(storageToggled)
        storageToggle.font = NSFont.systemFont(ofSize: 11)

        let row = NSStackView(views: [input, sendButton, stopButton])
        row.spacing = 8
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [settingsButton, spacer, clearButton])
        bottom.spacing = 8
        // The toggle gets its own row: all four in one row were wider than the window.
        Theme.primary(sendButton)
        let transcriptCard = Theme.card(scroll, padding: 4)
        let stack = NSStackView(views: [transcriptCard, row, bottom, storageToggle])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            transcriptCard.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    // MARK: Rendering

    private func bubble(_ text: String, mine: Bool) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.alignment = mine ? .right : .left
        p.paragraphSpacing = 8
        p.lineBreakMode = .byWordWrapping
        let color: NSColor = mine ? Theme.accent : .labelColor
        let label = mine ? "You" : "Moon"
        let head = NSAttributedString(string: label + "\n", attributes: [
            .font: Theme.font(10, .semibold, rounded: true), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p])
        let body = NSAttributedString(string: text + "\n", attributes: [
            .font: Theme.font(13.5), .foregroundColor: color, .paragraphStyle: p])
        let out = NSMutableAttributedString(attributedString: head)
        out.append(body)
        return out
    }

    private func note(_ text: String, error: Bool = false) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.paragraphSpacing = 8
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: error ? NSColor.systemRed : NSColor.secondaryLabelColor,
            .paragraphStyle: p])
    }

    private func render() {
        let enabled = Settings.shared.chatEnabled
        let out = NSMutableAttributedString()
        if !enabled {
            out.append(note("Chat is off. Press “Chat settings…” to turn it on. Nothing is sent anywhere while it's off."))
        } else if messages.isEmpty {
            if let pic = Art.image("chat_empty") {
                let att = NSTextAttachment()
                att.image = pic
                let h: CGFloat = 130
                att.bounds = CGRect(x: 0, y: 0, width: h * pic.size.width / max(1, pic.size.height), height: h)
                let p = NSMutableParagraphStyle()
                p.alignment = .center
                p.paragraphSpacing = 6
                let holder = NSMutableAttributedString(attachment: att)
                holder.append(NSAttributedString(string: "\n"))
                holder.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: holder.length))
                out.append(holder)
            }
            out.append(note("Say hi. Messages go to the provider you chose in Chat settings."))
        }
        for m in messages { out.append(bubble(m.text, mine: m.role == .user)) }
        if waiting { out.append(note(status)) }
        if let e = errorLine { out.append(note(e, error: true)) }
        transcript.textStorage?.setAttributedString(out)
        transcript.scrollToEndOfDocument(nil)

        input.isEnabled = enabled && !waiting
        sendButton.isEnabled = enabled && !waiting
        stopButton.isEnabled = waiting
        clearButton.isEnabled = !messages.isEmpty
        let canTools = ChatClient.supportsTools(Settings.shared.chatProviderKind)
        storageToggle.isEnabled = enabled && canTools && !waiting
        storageToggle.state = Settings.shared.chatStorageAccess && canTools ? .on : .off
        storageToggle.toolTip = canTools
            ? "Sends folder and file names, tags and notes to your chat provider. Locked items are never shared. Moving, renaming and deleting always ask first."
            : "Storage tools need Gemini or an OpenAI-style provider."
    }

    @objc private func settingsChanged() {
        if window.isVisible { render() }
    }

    // MARK: Actions

    @objc private func sendPressed() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !waiting, Settings.shared.chatEnabled else { return }
        input.stringValue = ""
        errorLine = nil
        messages.append(ChatMessage(role: .user, text: text))
        waiting = true
        render()

        status = "Moon is thinking…"
        // The new message plus the last N earlier ones.
        let n = max(0, Settings.shared.chatHistoryCount)
        let outgoing = Array(messages.suffix(n + 1))
        if Settings.shared.chatStorageAccess && ChatClient.supportsTools(Settings.shared.chatProviderKind) {
            sendWithTools(outgoing)
            return
        }
        client.send(outgoing) { [weak self] result in
            self?.handle(result)
        }
    }

    private func handle(_ result: Result<String, ChatError>) {
        waiting = false
        switch result {
        case .success(let reply):
            messages.append(ChatMessage(role: .assistant, text: reply))
            onCatReply?(reply)
        case .failure(let err):
            errorLine = err.errorDescription
        }
        render()
        window.makeFirstResponder(input)
    }

    // MARK: Storage tools

    @objc private func storageToggled() {
        Settings.shared.chatStorageAccess = storageToggle.state == .on
    }

    private func sendWithTools(_ outgoing: [ChatMessage]) {
        generation += 1
        let gen = generation
        let session = ToolSession(kind: Settings.shared.chatProviderKind, history: outgoing)
        let system = Settings.shared.chatPersonality + "\n\n" + StashTools.instructions + "\n\n" + StashTools.snapshot()
        client.runTools(session, system: system, execute: { [weak self] call, reply in
            self?.execute(call, generation: gen, reply: reply)
        }, completion: { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            self.handle(result)
        })
    }

    private func execute(_ call: ToolCall, generation gen: Int, reply: @escaping (String) -> Void) {
        guard generation == gen else { return }
        status = "Moon is using the box (\(call.name))…"
        render()
        if call.name == "convert_items" {
            status = "Moon is converting…"
            render()
            StashTools.runConvert(call.args) { [weak self] text in
                guard let self = self, self.generation == gen else { return }
                reply(text)
            }
            return
        }
        guard StashTools.needsConfirm(call.name) else {
            reply(StashTools.run(call.name, call.args))
            return
        }
        let isDelete = call.name == "delete_items"
        let alert = NSAlert()
        alert.messageText = "Let Moon do this?"
        alert.informativeText = StashTools.describe(call.name, call.args)
        alert.alertStyle = isDelete ? .critical : .warning
        alert.addButton(withTitle: isDelete ? "Delete" : "Allow")
        alert.addButton(withTitle: "Don't Allow")
        if isDelete {   // Return must never delete by accident
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
        }
        pendingAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            self.pendingAlert = nil
            if self.generation != gen { return }
            if response == .alertFirstButtonReturn {
                reply(StashTools.run(call.name, call.args))
            } else {
                reply("The user said no. Nothing was changed.")
            }
        }
    }

    /// Abandons a tool conversation: late replies are ignored and any open confirm sheet closes.
    private func abandonTools() {
        generation += 1
        if let a = pendingAlert {
            pendingAlert = nil
            window.endSheet(a.window)
        }
    }

    @objc private func stopPressed() {
        abandonTools()
        client.cancel()
        waiting = false
        errorLine = "Stopped."
        render()
    }

    @objc private func clearPressed() {
        abandonTools()
        client.cancel()
        waiting = false
        messages.removeAll()
        errorLine = nil
        render()
    }

    @objc private func openSettings() {
        ChatSettingsWindowController.shared.show()
    }

    func windowWillClose(_ notification: Notification) {
        abandonTools()
        client.cancel()
        waiting = false
    }
}
