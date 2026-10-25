import AppKit

/// A 30-second laser-pointer game. A small red dot follows the cursor and she pounces toward it.
/// The game ends after 30 seconds, or when you choose "Stop laser" in her menu.
final class LaserGame {
    static let shared = LaserGame()
    /// Posted when the game starts, stops, or the score changes.
    static let changed = Notification.Name("MoonCatLaserGameChanged")

    static let duration: TimeInterval = 30
    /// How close (in points) her body must land to the dot to count as a catch.
    static let catchRadius: CGFloat = 120

    private var panel: NSPanel?
    private var timer: Timer?
    private var endTime: CFTimeInterval = 0
    private var lastRequest: CFTimeInterval = 0

    private(set) var score = 0 {
        didSet {
            if score != oldValue { NotificationCenter.default.post(name: LaserGame.changed, object: self) }
        }
    }

    var isRunning: Bool { return panel != nil }

    /// Asks the cat to pounce toward a screen point (at most once every 1.2 s).
    var onPounceRequest: ((CGPoint) -> Void)?
    /// Called with the final score when the game ends.
    var onFinish: ((Int) -> Void)?

    private init() {}

    func start() {
        guard !isRunning else { return }
        score = 0

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 24, height: 24),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = LaserDotView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let loc = NSEvent.mouseLocation
        p.setFrameOrigin(NSPoint(x: loc.x - 12, y: loc.y - 12))
        p.orderFrontRegardless()
        panel = p

        endTime = CACurrentMediaTime() + LaserGame.duration
        lastRequest = 0

        let t = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t

        NotificationCenter.default.post(name: LaserGame.changed, object: self)
    }

    @objc private func tick() {
        guard let p = panel else { return }
        let now = CACurrentMediaTime()
        if now >= endTime {
            stop()
            return
        }
        let loc = NSEvent.mouseLocation
        p.setFrameOrigin(NSPoint(x: loc.x - 12, y: loc.y - 12))
        if now - lastRequest >= 1.2 {
            lastRequest = now
            onPounceRequest?(loc)
        }
    }

    func stop() {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        let finalScore = score
        NotificationCenter.default.post(name: LaserGame.changed, object: self)
        onFinish?(finalScore)
    }

    /// Called by the cat when a pounce ends, with the centre of her body.
    func registerLanding(at catCenter: CGPoint) {
        guard isRunning else { return }
        let m = NSEvent.mouseLocation
        if hypot(catCenter.x - m.x, catCenter.y - m.y) <= LaserGame.catchRadius { score += 1 }
    }
}

private final class LaserDotView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let glow = NSColor.systemRed.withAlphaComponent(0.35)
        glow.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6)).fill()
        NSColor.white.withAlphaComponent(0.8).setFill()
        NSBezierPath(ovalIn: NSRect(x: 10, y: 10, width: 4, height: 4)).fill()
    }
}
