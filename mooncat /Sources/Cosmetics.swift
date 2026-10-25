import AppKit
import CoreGraphics
import QuartzCore

// MARK: - Fur tint

enum FurTint: String, CaseIterable {
    case natural, ginger, silver, rose, lavender, mint

    var title: String {
        switch self {
        case .natural: return "Natural"
        case .ginger: return "Ginger"
        case .silver: return "Silver"
        case .rose: return "Rose"
        case .lavender: return "Lavender"
        case .mint: return "Mint"
        }
    }

    var color: NSColor {
        switch self {
        case .natural: return .white
        case .ginger: return NSColor(calibratedRed: 0.95, green: 0.52, blue: 0.18, alpha: 1)
        case .silver: return NSColor(calibratedRed: 0.62, green: 0.66, blue: 0.74, alpha: 1)
        case .rose: return NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.62, alpha: 1)
        case .lavender: return NSColor(calibratedRed: 0.62, green: 0.50, blue: 0.95, alpha: 1)
        case .mint: return NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.62, alpha: 1)
        }
    }
}

// MARK: - Hats

enum Hat: String, CaseIterable {
    case bare, party, bow, beanie, topHat, crown

    var title: String {
        switch self {
        case .bare: return "No hat"
        case .party: return "Party hat"
        case .bow: return "Bow"
        case .beanie: return "Beanie"
        case .topHat: return "Top hat"
        case .crown: return "Crown"
        }
    }
}

// MARK: - Settings

extension Settings {
    var furTint: FurTint {
        get { return FurTint(rawValue: UserDefaults.standard.string(forKey: "furTint") ?? "") ?? .natural }
        set { storeExtra(newValue.rawValue, "furTint") }
    }
    var hat: Hat {
        get { return Hat(rawValue: UserDefaults.standard.string(forKey: "hat") ?? "") ?? .bare }
        set { storeExtra(newValue.rawValue, "hat") }
    }
    static let cosmeticsDefaults: [String: Any] = ["furTint": "natural", "hat": "bare"]
}

// MARK: - Unlocks

/// Hats are earned by using the app. Counters are kept in UserDefaults.
enum CosmeticsUnlocks {
    private static let petsKey = "cosmetics.pets"
    private static let daysKey = "cosmetics.days"

    static var pets: Int { return UserDefaults.standard.integer(forKey: petsKey) }
    static var daysUsed: Int { return (UserDefaults.standard.stringArray(forKey: daysKey) ?? []).count }

    static func recordPet() {
        UserDefaults.standard.set(pets + 1, forKey: petsKey)
    }

    /// Call at launch: counts each distinct calendar day once.
    static func recordLaunch() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let today = f.string(from: Date())
        var days = UserDefaults.standard.stringArray(forKey: daysKey) ?? []
        if !days.contains(today) {
            days.append(today)
            if days.count > 400 { days.removeFirst(days.count - 400) }
            UserDefaults.standard.set(days, forKey: daysKey)
        }
    }

    static func isUnlocked(_ hat: Hat) -> Bool {
        switch hat {
        case .bare, .party, .bow: return true
        case .beanie: return daysUsed >= 3
        case .topHat: return pets >= 50
        case .crown: return Stash.shared.items.count >= 15 && daysUsed >= 7
        }
    }

    static func hint(_ hat: Hat) -> String {
        switch hat {
        case .bare, .party, .bow: return ""
        case .beanie: return "Use MoonCat on 3 different days (\(min(daysUsed, 3))/3)."
        case .topHat: return "Pet her 50 times (\(min(pets, 50))/50)."
        case .crown: return "Keep 15 things in the Treasure Box and use MoonCat on 7 days."
        }
    }
}

// MARK: - Rendering

final class Cosmetics {
    static let shared = Cosmetics()
    private var tintCache: [String: CGImage] = [:]
    private init() {}

    func clearCache() { tintCache.removeAll() }

    /// A string that changes whenever the look changes (used to know when to redraw).
    var lookKey: String { return Settings.shared.furTint.rawValue + "|" + Settings.shared.hat.rawValue }

    /// The sprite recoloured for the chosen fur tint. Uses the "color" blend (keeps the shading and
    /// outlines, replaces the hue) plus a faint lift so dark fur still shows the colour.
    func image(_ base: CGImage, pose: String, tint: FurTint) -> CGImage {
        if tint == .natural { return base }
        let key = "\(pose)|\(tint.rawValue)|\(base.width)x\(base.height)"
        if let c = tintCache[key] { return c }

        let w = base.width, h = base.height
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let c = tint.color.usingColorSpace(.deviceRGB) ?? tint.color

        ctx.draw(base, in: rect)
        ctx.setBlendMode(.color)
        ctx.setFillColor(c.withAlphaComponent(0.85).cgColor)
        ctx.fill(rect)
        ctx.setBlendMode(.plusLighter)
        ctx.setFillColor(c.withAlphaComponent(0.16).cgColor)
        ctx.fill(rect)
        // Put the original transparency back (the fills above also coloured the empty background).
        ctx.setBlendMode(.destinationIn)
        ctx.draw(base, in: rect)

        guard let out = ctx.makeImage() else { return base }
        tintCache[key] = out
        return out
    }

    /// Where the top of her head is for each pose, as fractions of the sprite (x from the left of the
    /// ORIGINAL artwork, y from the bottom) and how wide the hat should be, as a fraction of sprite width.
    /// Tweak these numbers if a hat sits too high or low on a pose.
    private static let heads: [String: (x: CGFloat, y: CGFloat, width: CGFloat, tilt: CGFloat)] = [
        "look":    (0.58, 0.80, 0.30, 0.0),
        "follow":  (0.75, 0.60, 0.24, -0.25),
        "play":    (0.22, 0.60, 0.20, 0.35),
        "happy":   (0.53, 0.84, 0.32, 0.0),
        "sleep":   (0.29, 0.76, 0.18, 0.3),
        "curious": (0.70, 0.74, 0.30, -0.15),
        "yawn":    (0.53, 0.84, 0.32, 0.0)
    ]

    /// A hat layer for this pose, or nil (no hat chosen, or the pose has no head to wear it, like the box).
    func hatLayer(_ hat: Hat, pose: String, spriteSize: CGSize) -> CALayer? {
        guard hat != .bare, let head = Cosmetics.heads[pose] else { return nil }
        let w = max(20, spriteSize.width * head.width)
        let h = w * 0.9
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.1)
        layer.position = CGPoint(x: spriteSize.width * head.x, y: spriteSize.height * head.y)
        layer.setAffineTransform(CGAffineTransform(rotationAngle: head.tilt))
        draw(hat, into: layer, w: w, h: h)
        return layer
    }

    private func shape(_ path: CGPath, fill: NSColor, stroke: NSColor? = nil, into parent: CALayer) {
        let s = CAShapeLayer()
        s.frame = parent.bounds
        s.path = path
        s.fillColor = fill.cgColor
        if let st = stroke {
            s.strokeColor = st.cgColor
            s.lineWidth = max(1, parent.bounds.width * 0.025)
            s.lineJoin = .round
        }
        parent.addSublayer(s)
    }

    private func draw(_ hat: Hat, into l: CALayer, w: CGFloat, h: CGFloat) {
        let ink = NSColor(calibratedWhite: 0.12, alpha: 0.9)
        switch hat {
        case .bare:
            break

        case .party:
            let cone = CGMutablePath()
            cone.move(to: CGPoint(x: w * 0.18, y: 0))
            cone.addLine(to: CGPoint(x: w * 0.5, y: h * 0.98))
            cone.addLine(to: CGPoint(x: w * 0.82, y: 0))
            cone.closeSubpath()
            shape(cone, fill: NSColor.systemPink, stroke: ink, into: l)
            for (i, c) in [NSColor.systemYellow, NSColor.systemTeal].enumerated() {
                let y = h * (0.22 + 0.24 * CGFloat(i))
                let stripe = CGMutablePath()
                let half = w * (0.30 - 0.12 * (y / h))
                stripe.addRect(CGRect(x: w * 0.5 - half, y: y, width: half * 2, height: h * 0.07))
                shape(stripe, fill: c, into: l)
            }
            let pom = CGPath(ellipseIn: CGRect(x: w * 0.42, y: h * 0.9, width: w * 0.16, height: w * 0.16), transform: nil)
            shape(pom, fill: NSColor.systemYellow, stroke: ink, into: l)

        case .bow:
            let left = CGMutablePath()
            left.move(to: CGPoint(x: w * 0.5, y: h * 0.3))
            left.addCurve(to: CGPoint(x: w * 0.08, y: h * 0.62), control1: CGPoint(x: w * 0.3, y: h * 0.62), control2: CGPoint(x: w * 0.1, y: h * 0.7))
            left.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.3), control1: CGPoint(x: w * 0.1, y: h * 0.1), control2: CGPoint(x: w * 0.3, y: h * 0.1))
            let right = CGMutablePath()
            right.move(to: CGPoint(x: w * 0.5, y: h * 0.3))
            right.addCurve(to: CGPoint(x: w * 0.92, y: h * 0.62), control1: CGPoint(x: w * 0.7, y: h * 0.62), control2: CGPoint(x: w * 0.9, y: h * 0.7))
            right.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.3), control1: CGPoint(x: w * 0.9, y: h * 0.1), control2: CGPoint(x: w * 0.7, y: h * 0.1))
            shape(left, fill: NSColor.systemPink, stroke: ink, into: l)
            shape(right, fill: NSColor.systemPink, stroke: ink, into: l)
            let knot = CGPath(ellipseIn: CGRect(x: w * 0.4, y: h * 0.2, width: w * 0.2, height: w * 0.2), transform: nil)
            shape(knot, fill: NSColor(calibratedRed: 0.9, green: 0.25, blue: 0.5, alpha: 1), stroke: ink, into: l)

        case .beanie:
            let dome = CGMutablePath()
            dome.move(to: CGPoint(x: w * 0.12, y: h * 0.18))
            dome.addCurve(to: CGPoint(x: w * 0.88, y: h * 0.18), control1: CGPoint(x: w * 0.1, y: h * 1.0), control2: CGPoint(x: w * 0.9, y: h * 1.0))
            dome.closeSubpath()
            shape(dome, fill: NSColor.systemTeal, stroke: ink, into: l)
            let band = CGPath(roundedRect: CGRect(x: w * 0.08, y: 0, width: w * 0.84, height: h * 0.22),
                              cornerWidth: h * 0.08, cornerHeight: h * 0.08, transform: nil)
            shape(band, fill: NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.9, alpha: 1), stroke: ink, into: l)
            let pom = CGPath(ellipseIn: CGRect(x: w * 0.4, y: h * 0.82, width: w * 0.2, height: w * 0.2), transform: nil)
            shape(pom, fill: NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.9, alpha: 1), stroke: ink, into: l)

        case .topHat:
            let brim = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h * 0.12),
                              cornerWidth: h * 0.05, cornerHeight: h * 0.05, transform: nil)
            let body = CGPath(rect: CGRect(x: w * 0.18, y: h * 0.1, width: w * 0.64, height: h * 0.8), transform: nil)
            shape(body, fill: NSColor(calibratedWhite: 0.14, alpha: 1), stroke: ink, into: l)
            let ribbon = CGPath(rect: CGRect(x: w * 0.18, y: h * 0.14, width: w * 0.64, height: h * 0.14), transform: nil)
            shape(ribbon, fill: NSColor.systemRed, into: l)
            shape(brim, fill: NSColor(calibratedWhite: 0.1, alpha: 1), stroke: ink, into: l)

        case .crown:
            let c = CGMutablePath()
            c.move(to: CGPoint(x: w * 0.1, y: 0))
            c.addLine(to: CGPoint(x: w * 0.06, y: h * 0.7))
            c.addLine(to: CGPoint(x: w * 0.3, y: h * 0.42))
            c.addLine(to: CGPoint(x: w * 0.5, y: h * 0.8))
            c.addLine(to: CGPoint(x: w * 0.7, y: h * 0.42))
            c.addLine(to: CGPoint(x: w * 0.94, y: h * 0.7))
            c.addLine(to: CGPoint(x: w * 0.9, y: 0))
            c.closeSubpath()
            shape(c, fill: NSColor(calibratedRed: 1, green: 0.8, blue: 0.2, alpha: 1), stroke: ink, into: l)
            for (i, col) in [NSColor.systemRed, NSColor.systemBlue, NSColor.systemGreen].enumerated() {
                let gem = CGPath(ellipseIn: CGRect(x: w * (0.22 + 0.25 * CGFloat(i)), y: h * 0.1, width: w * 0.12, height: w * 0.12), transform: nil)
                shape(gem, fill: col, into: l)
            }
        }
    }
}

// MARK: - Window

final class CosmeticsWindowController: NSObject, NSWindowDelegate {
    static let shared = CosmeticsWindowController()

    private let window: NSWindow
    private let tintPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hatNote = NSTextField(wrappingLabelWithString: "")

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Dress up Moon"
        Theme.style(window)
        window.isReleasedWhenClosed = false
        window.delegate = self

        tintPopup.target = self
        tintPopup.action = #selector(tintChanged)
        hatPopup.target = self
        hatPopup.action = #selector(hatChanged)
        hatPopup.autoenablesItems = false
        hatNote.textColor = .secondaryLabelColor
        hatNote.font = NSFont.systemFont(ofSize: 11)
        hatNote.preferredMaxLayoutWidth = 260

        func name(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.alignment = .right
            return t
        }
        let grid = NSGridView(views: [
            [name("Fur colour"), tintPopup],
            [name("Hat"), hatPopup],
            [NSView(), hatNote]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        let header = Theme.header(symbol: "sparkles", title: "Dress up Moon",
                                  subtitle: "Pick a fur colour and a hat.")
        let gridCard = Theme.card(grid, padding: 18)
        var top: NSView = header
        if let hero = Art.imageView("dressup_hero", height: 96) {
            let flex = NSView()
            flex.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [header, flex, hero])
            row.orientation = .horizontal
            row.alignment = .centerY
            top = row
        }
        if let c = window.contentView {
            top.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(top)
            c.addSubview(gridCard)
            NSLayoutConstraint.activate([
                top.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: Theme.pad),
                top.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -Theme.pad),
                top.topAnchor.constraint(equalTo: c.topAnchor, constant: 8),
                gridCard.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: Theme.pad),
                gridCard.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -Theme.pad),
                gridCard.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 14)
            ])
        }
    }

    func show() {
        refresh()
        activateApp()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        tintPopup.removeAllItems()
        for t in FurTint.allCases { tintPopup.addItem(withTitle: t.title) }
        if let i = FurTint.allCases.firstIndex(of: Settings.shared.furTint) { tintPopup.selectItem(at: i) }

        hatPopup.removeAllItems()
        for h in Hat.allCases {
            let unlocked = CosmeticsUnlocks.isUnlocked(h)
            hatPopup.addItem(withTitle: unlocked ? h.title : h.title + " (locked)")
            hatPopup.lastItem?.isEnabled = unlocked
            hatPopup.lastItem?.toolTip = unlocked ? nil : CosmeticsUnlocks.hint(h)
        }
        if let i = Hat.allCases.firstIndex(of: Settings.shared.hat) { hatPopup.selectItem(at: i) }

        let locked = Hat.allCases.filter { !CosmeticsUnlocks.isUnlocked($0) }
        hatNote.stringValue = locked.isEmpty ? "Everything is unlocked." :
            locked.map { "\($0.title): " + CosmeticsUnlocks.hint($0) }.joined(separator: "\n")
    }

    @objc private func tintChanged() {
        let i = max(0, tintPopup.indexOfSelectedItem)
        Settings.shared.furTint = FurTint.allCases[i]
    }

    @objc private func hatChanged() {
        let i = max(0, hatPopup.indexOfSelectedItem)
        let h = Hat.allCases[i]
        if CosmeticsUnlocks.isUnlocked(h) { Settings.shared.hat = h }
    }
}
