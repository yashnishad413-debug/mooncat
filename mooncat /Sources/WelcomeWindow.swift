import AppKit

/// Shown once on first launch (and from the menu: "Welcome guide…").
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private let window: NSWindow
    private let loginCheck = NSButton(checkboxWithTitle: "Start Moon Cat when I log in", target: nil, action: nil)

    static func showIfFirstRun() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "welcomeShown") else { return }
        d.set(true, forKey: "welcomeShown")
        // Wait a moment so she has appeared first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { shared.show() }
    }

    func show() {
        loginCheck.state = LoginItem.isEnabled ? .on : .off
        activateApp()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Welcome to Moon Cat"
        Theme.style(window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
    }

    private func step(_ symbol: String, _ art: String, _ headline: String, _ text: String) -> NSView {
        let badge = ThemeCard()
        badge.fill = Theme.accent.withAlphaComponent(0.14)
        badge.stroke = .clear
        badge.radius = 9
        let img = NSImageView()
        img.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        img.contentTintColor = Theme.accent
        img.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        img.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(img)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 34),
            badge.heightAnchor.constraint(equalToConstant: 34),
            img.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            img.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        let head = NSTextField(labelWithString: headline)
        head.font = Theme.font(13, .semibold)
        let body = Theme.caption(text)
        body.preferredMaxLayoutWidth = 340
        let col = NSStackView(views: [head, body])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        let lead: NSView = (Art.imageView(art, height: 52) as NSView?) ?? badge
        let row = NSStackView(views: [lead, col])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func build() {
        guard let content = window.contentView else { return }
        let header = Theme.header(symbol: "moon.stars", title: "Meet Moon",
                                  subtitle: "A small cat that lives on your desktop.")

        let steps = NSStackView(views: [
            step("hand.tap", "welcome_pet", "Pet her", "Click to pet. Drag to carry her somewhere else."),
            step("tray.and.arrow.down", "welcome_stash", "Feed the Treasure Box", "Drop files, text, links or images on her to keep them."),
            step("magnifyingglass", "welcome_search", "Search anything", "Press \u{2325}\u{2318}Space to search the Treasure Box from any app."),
            step("cursorarrow.click.2", "welcome_menu", "Right-click for more", "Reminders, the focus timer, the laser game, file conversion and Moon Veil.")
        ])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 16
        let stepsCard = Theme.card(steps, padding: 18)

        loginCheck.target = self
        loginCheck.action = #selector(loginChanged)

        let done = NSButton(title: "Get started", target: self, action: #selector(close))
        Theme.primary(done)

        let flex = NSView()
        flex.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [loginCheck, flex, done])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        var top: NSView = header
        if let hero = Art.imageView("welcome_hero", height: 120) {
            let flex = NSView()
            flex.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [header, flex, hero])
            row.orientation = .horizontal
            row.alignment = .centerY
            top = row
        }
        let stack = NSStackView(views: [top, stepsCard, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.pad),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.pad),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stepsCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func loginChanged() {
        let want = loginCheck.state == .on
        if LoginItem.isEnabled != want, case .failure = LoginItem.set(want) {
            loginCheck.state = LoginItem.isEnabled ? .on : .off
        } else if want && LoginItem.needsApproval {
            LoginItem.openSystemSettings()
        }
    }

    @objc private func close() { window.close() }
}
