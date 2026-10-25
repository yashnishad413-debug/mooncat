import AppKit

final class AboutWindowController: NSObject, NSWindowDelegate {
    static let shared = AboutWindowController()

    private let window: NSWindow
    private let statsLabel = NSTextField(labelWithString: "")

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "About Moon Cat"
        Theme.style(window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
    }

    func show() {
        refreshStats()
        activateApp()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        guard let content = window.contentView else { return }

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let title = NSTextField(labelWithString: "Moon Cat")
        title.font = Theme.font(26, .semibold, rounded: true)

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.textColor = .secondaryLabelColor

        versionLabel.font = Theme.font(12)
        let credit = NSTextField(wrappingLabelWithString: "A little cat that lives on your desktop. Made by Yash.")
        credit.alignment = .center
        credit.font = Theme.font(13)
        credit.preferredMaxLayoutWidth = 260

        statsLabel.textColor = Theme.accent
        statsLabel.font = Theme.font(12, .medium)

        let reveal = NSButton(title: "Show log file", target: self, action: #selector(revealLog))
        reveal.bezelStyle = .rounded

        let hero: NSView = Art.banner("about_hero", width: 296, height: 150) ?? icon
        let stack = NSStackView(views: [hero, title, versionLabel, credit, statsLabel, reveal])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(16, after: hero)
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(18, after: credit)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 30)
        ])
    }

    private func refreshStats() {
        statsLabel.stringValue = "Petted \(CosmeticsUnlocks.pets) times, \(CosmeticsUnlocks.daysUsed) days together"
    }

    @objc private func revealLog() { Log.revealInFinder() }
}
