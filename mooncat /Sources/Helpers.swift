import AppKit

// MARK: - Small helpers

func gap(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    return hypot(a.x - b.x, a.y - b.y)
}

/// Brings MoonCat to the front. macOS 14 replaced `activate(ignoringOtherApps:)` with `activate()`.
func activateApp() {
    if #available(macOS 14.0, *) {
        NSApp.activate()
    } else {
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Hands focus back to another app (used when Quick Search is dismissed with Esc).
func reactivate(_ app: NSRunningApplication) {
    if #available(macOS 14.0, *) {
        _ = app.activate(from: NSRunningApplication.current, options: [])
    } else {
        _ = app.activate(options: [])
    }
}

// MARK: - Theme (one look for every Moon Cat window)
//
// Cool graphite neutrals, one teal accent, rounded display type, one corner radius for cards.
// Everything is dynamic, so light and dark mode both work without extra code.

enum Theme {
    static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    /// The single accent colour.
    static let accent = dynamic(light: (0.06, 0.52, 0.48), dark: (0.30, 0.80, 0.72))
    /// Window background.
    static let canvas = dynamic(light: (0.955, 0.961, 0.972), dark: (0.100, 0.106, 0.122))
    /// Cards sitting on the canvas.
    static let surface = dynamic(light: (0.995, 0.996, 0.998), dark: (0.150, 0.158, 0.178))

    static let cardRadius: CGFloat = 14
    static let pad: CGFloat = 22

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, rounded: Bool = false) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if rounded, let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) {
            return f
        }
        return base
    }

    /// Seamless title bar, calm background, draggable from anywhere on the background.
    static func style(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.backgroundColor = canvas
        window.isMovableByWindowBackground = true
    }

    static func title(_ s: String, size: CGFloat = 22) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font(size, .semibold, rounded: true)
        t.textColor = .labelColor
        return t
    }

    static func caption(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = font(12)
        t.textColor = .secondaryLabelColor
        return t
    }

    static func sectionLabel(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font(12, .medium)
        t.textColor = .secondaryLabelColor
        return t
    }

    /// A rounded surface that wraps `inner` with padding.
    static func card(_ inner: NSView, padding: CGFloat = 16) -> NSView {
        let box = ThemeCard()
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: padding),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -padding),
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: padding),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -padding)
        ])
        return box
    }

    /// Icon badge + title + subtitle, used at the top of a window.
    static func header(symbol: String, title: String, subtitle: String) -> NSView {
        let badge = ThemeCard()
        badge.fill = accent.withAlphaComponent(0.14)
        badge.stroke = .clear
        badge.radius = 12
        badge.translatesAutoresizingMaskIntoConstraints = false
        let img = NSImageView()
        img.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        img.contentTintColor = accent
        img.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        img.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(img)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 44),
            badge.heightAnchor.constraint(equalToConstant: 44),
            img.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            img.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        let text = NSStackView(views: [Theme.title(title), Theme.caption(subtitle)])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [badge, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return row
    }

    /// The main call-to-action button.
    static func primary(_ b: NSButton) {
        b.bezelStyle = .rounded
        b.bezelColor = accent
        b.contentTintColor = .white
        b.controlSize = .large
        b.keyEquivalent = "\r"
    }
}

final class ThemeCard: NSView {
    var fill: NSColor = Theme.surface { didSet { needsDisplay = true } }
    var stroke: NSColor = NSColor.separatorColor { didSet { needsDisplay = true } }
    var radius: CGFloat = Theme.cardRadius { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { return false }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        fill.setFill()
        p.fill()
        stroke.setStroke()
        p.lineWidth = 1
        p.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Art (illustrations bundled in Resources as art_<name>.png or .jpg)
//
// Every call returns nil when the file is missing, so windows simply fall back to their plain look.

enum Art {
    /// Every art_* picture in the app's Resources, keyed by name without "art_" or extension.
    /// A trailing " 2" (added when a copy lands next to the original) is ignored.
    private static let index: [String: URL] = {
        var out: [String: URL] = [:]
        guard let dir = Bundle.main.resourceURL,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return out
        }
        for u in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let ext = u.pathExtension.lowercased()
            guard ext == "png" || ext == "jpg" else { continue }
            var base = u.deletingPathExtension().lastPathComponent
            guard base.hasPrefix("art_") else { continue }
            while let r = base.range(of: " [0-9]+$", options: .regularExpression) { base.removeSubrange(r) }
            base.removeFirst(4)
            if out[base] == nil { out[base] = u }
        }
        return out
    }()

    static func image(_ name: String) -> NSImage? {
        guard let u = index[name] else { return nil }
        return NSImage(contentsOf: u)
    }

    /// A picture shown at a fixed height, keeping its proportions.
    static func imageView(_ name: String, height: CGFloat) -> NSImageView? {
        guard let img = image(name) else { return nil }
        let v = NSImageView()
        v.image = img
        v.imageScaling = .scaleProportionallyUpOrDown
        v.translatesAutoresizingMaskIntoConstraints = false
        let ratio = img.size.width / max(1, img.size.height)
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        v.widthAnchor.constraint(equalToConstant: height * ratio).isActive = true
        return v
    }

    /// A rounded picture that fills a fixed rectangle (cropping the edges if needed).
    static func banner(_ name: String, width: CGFloat, height: CGFloat) -> NSView? {
        guard let img = image(name),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let v = NSView()
        v.wantsLayer = true
        v.translatesAutoresizingMaskIntoConstraints = false
        v.layer?.cornerRadius = Theme.cardRadius
        v.layer?.masksToBounds = true
        v.layer?.contents = cg
        v.layer?.contentsGravity = .resizeAspectFill
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }
}

/// A picture with a short line under it, laid over a list when the list is empty. Clicks pass through.
final class ArtEmptyView: NSView {
    private let picture = NSImageView()
    private let label = Theme.caption("")
    private var shownName = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.preferredMaxLayoutWidth = 260
        let stack = NSStackView(views: [picture, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            picture.widthAnchor.constraint(equalToConstant: 150),
            picture.heightAnchor.constraint(equalToConstant: 150)
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { return nil }

    func update(art name: String, text: String, visible: Bool) {
        guard visible, let img = Art.image(name) else { isHidden = true; return }
        picture.image = img
        label.stringValue = text
        isHidden = false
    }
}

/// A top-left-origin view, used as the document of a scroll view so content starts at the top.
final class ThemeFlippedView: NSView {
    override var isFlipped: Bool { return true }
}
