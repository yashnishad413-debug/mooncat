import AppKit
import QuartzCore

// MARK: - Controller

final class PetController: NSObject {
    enum State { case idle, walking, sleeping, playing, happy, curious, box, carried }

    static let baseSize = NSSize(width: 260, height: 290)
    static let pixelScale: CGFloat = 0.40      // points per sprite pixel at size 1.0

    // Window / view
    let window: PetWindow
    let view: CatView

    // Layers (all share the sprite's size; anchored at the cat's feet)
    let shadow = CAShapeLayer()
    let pop = CALayer()        // pose-change "pop"
    let bobber = CALayer()     // hop / bounce
    let flipper = CALayer()    // left/right mirroring
    let sprite = CALayer()     // the artwork, breathing / tilt

    // Settings (live views onto Settings.shared)
    var scale: CGFloat { return CGFloat(Settings.shared.scale) }
    var follow: Bool {
        get { return Settings.shared.follow }
        set { Settings.shared.follow = newValue }
    }
    var footY: CGFloat
    private var appliedScale: CGFloat
    private var appliedScreenID: Int

    // Position of the cat's feet in screen coordinates
    var pos = CGPoint.zero
    var lift: CGFloat = 0
    var spriteSize = CGSize(width: 150, height: 150)

    // State
    var state: State = .idle {
        didSet { if oldValue != state { stateChanged() } }
    }
    var stateBeforeDrag: State = .idle
    var currentPose: Pose? = nil
    var currentFlip = false

    // Timing / input tracking
    var lastTick: CFTimeInterval = 0
    var lastMouse = CGPoint.zero
    var lastMouseMove: CFTimeInterval = 0
    var activeTime: CGFloat = 0
    var mouseOver = false
    var hoverTime: CGFloat = 0
    var curiousAway: CGFloat = 0
    var nextPlayTime: CFTimeInterval = 0
    var happyUntil: CFTimeInterval = 0
    var lastHeart: CFTimeInterval = 0
    var playFrom = CGPoint.zero
    var playTo = CGPoint.zero
    var playT: CGFloat = 0
    var grabOffset = CGPoint.zero
    var zFlip = false
    var fileDragActive = false
    var lastDragChange = 0
    lazy var stashWindow: StashWindowController = StashWindowController()
    lazy var preferences: PreferencesWindowController = PreferencesWindowController()
    lazy var quickSearch: QuickSearchPanelController = QuickSearchPanelController()

    var timer: Timer?
    var zTimer: Timer?
    var autoForgetTimer: Timer?
    var autoForgetBusy = false
    var yawnWork: DispatchWorkItem?
    var statusItem: NSStatusItem?
    var hatLayer: CALayer?
    var appliedLook = ""
    var perchWindowID: CGWindowID?
    var perchFalling = false

    override init() {
        let d = UserDefaults.standard
        let sc = CGFloat(Settings.shared.scale)
        let size = NSSize(width: PetController.baseSize.width * sc,
                          height: PetController.baseSize.height * sc)

        window = PetWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered,
                           defer: false)
        view = CatView(frame: NSRect(origin: .zero, size: size))
        footY = 16 * sc
        appliedScale = sc
        appliedScreenID = Settings.shared.screenID

        super.init()

        // Window setup: transparent, floating, on every Space, never steals focus.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = view

        view.controller = self
        view.wantsLayer = true
        view.registerForDraggedTypes(StashDrop.draggedTypes)
        buildLayers()

        // Restore or choose a starting position (bottom-right corner).
        if d.object(forKey: "posX") != nil, d.object(forKey: "posY") != nil {
            pos = CGPoint(x: d.double(forKey: "posX"), y: d.double(forKey: "posY"))
        } else if let s = NSScreen.main {
            let vf = s.visibleFrame
            pos = CGPoint(x: vf.maxX - 160, y: vf.minY + 8)
        }

        let now = CACurrentMediaTime()
        lastTick = now
        lastMouse = NSEvent.mouseLocation
        lastMouseMove = now
        nextPlayTime = now + Settings.shared.firstPlayDelay

        stateChanged()
        pos = clampPoint(pos)
        applyFrame()
        window.orderFrontRegardless()

        let t = Timer(timeInterval: Settings.shared.tickInterval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t

        setupStatusItem()

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: Settings.didChange, object: nil)

        setupHotKey()
        scheduleAutoForget()
        setupModules()
    }

    // MARK: Live settings

    @objc func settingsChanged(_ note: Notification) {
        if scale != appliedScale {
            appliedScale = scale
            applyScale()
        }
        if Settings.shared.screenID != appliedScreenID {
            appliedScreenID = Settings.shared.screenID
            if let s = Settings.shared.preferredScreen() {
                let vf = s.visibleFrame
                pos = CGPoint(x: vf.midX, y: vf.minY + 8)
            }
        }
        if Cosmetics.shared.lookKey != appliedLook { layoutSprite() }
        pos = clampPoint(pos)
        applyFrame()
    }

    // MARK: Layers

    func buildLayers() {
        guard let root = view.layer else { return }
        shadow.fillColor = NSColor.black.withAlphaComponent(0.25).cgColor
        root.addSublayer(shadow)
        root.addSublayer(pop)
        pop.addSublayer(bobber)
        bobber.addSublayer(flipper)
        flipper.addSublayer(sprite)
        sprite.contentsGravity = .resize
        sprite.magnificationFilter = .linear
        sprite.minificationFilter = .trilinear
    }

    func layoutSprite() {
        guard let pose = currentPose, let img = SpriteBank.shared.image(pose.rawValue) else { return }
        let k = PetController.pixelScale * scale
        let w = CGFloat(img.width) * k
        let h = CGFloat(img.height) * k
        spriteSize = CGSize(width: w, height: h)
        let midX = view.bounds.width / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [pop, bobber, flipper, sprite] {
            l.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            l.anchorPoint = CGPoint(x: 0.5, y: 0)
        }
        pop.position = CGPoint(x: midX, y: footY)
        for l in [bobber, flipper, sprite] {
            l.position = CGPoint(x: w / 2, y: 0)
        }
        sprite.contents = Cosmetics.shared.image(img, pose: pose.rawValue, tint: Settings.shared.furTint)
        appliedLook = Cosmetics.shared.lookKey
        updateHat()
        flipper.transform = currentFlip ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity

        let sw = w * 0.65
        let sh = 16 * scale
        shadow.bounds = CGRect(x: 0, y: 0, width: sw, height: sh)
        shadow.position = CGPoint(x: midX, y: footY + 2)
        shadow.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: sw, height: sh), transform: nil)
        CATransaction.commit()
    }

    /// Puts the chosen hat (if any) on her head for the current pose.
    func updateHat() {
        hatLayer?.removeFromSuperlayer()
        hatLayer = nil
        guard let pose = currentPose,
              let l = Cosmetics.shared.hatLayer(Settings.shared.hat, pose: pose.rawValue, spriteSize: spriteSize) else { return }
        sprite.addSublayer(l)
        hatLayer = l
    }

    func show(_ p: Pose, toward right: Bool) {
        let flip: Bool
        switch p.facing {
        case .front: flip = false
        case .right: flip = !right
        case .left: flip = right
        }
        if p == currentPose && flip == currentFlip { return }
        let poseChanged = (p != currentPose)
        currentPose = p
        currentFlip = flip
        layoutSprite()
        if poseChanged { popAnimation() }
    }

    func popAnimation() {
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 0.9
        a.toValue = 1.0
        a.duration = 0.22
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pop.add(a, forKey: "pop")
    }

    func loop(_ layer: CALayer, _ keyPath: String, from: Double, to: Double,
              duration: CFTimeInterval, repeats: Float = Float.infinity) {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.autoreverses = true
        a.repeatCount = repeats
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: keyPath)
    }

    func applyAnimations() {
        sprite.removeAllAnimations()
        bobber.removeAllAnimations()
        switch state {
        case .idle, .box:
            loop(sprite, "transform.scale.y", from: 1.0, to: 1.03, duration: 1.5)
        case .sleeping:
            loop(sprite, "transform.scale.y", from: 1.0, to: 1.05, duration: 2.8)
        case .walking:
            loop(bobber, "transform.translation.y", from: 0, to: 8 * Double(scale), duration: 0.14)
            loop(sprite, "transform.rotation.z", from: -0.05, to: 0.05, duration: 0.14)
        case .happy:
            loop(bobber, "transform.translation.y", from: 0, to: 16 * Double(scale), duration: 0.18, repeats: 4)
        case .curious:
            loop(sprite, "transform.rotation.z", from: -0.06, to: 0.07, duration: 0.7)
        case .carried:
            loop(sprite, "transform.rotation.z", from: -0.07, to: 0.07, duration: 0.25)
        case .playing:
            break
        }
    }

    // MARK: State changes

    func stateChanged() {
        zTimer?.invalidate()
        zTimer = nil
        yawnWork?.cancel()
        yawnWork = nil
        if state != .curious { Sounds.shared.stopPurr() }
        let mouse = NSEvent.mouseLocation
        switch state {
        case .idle:
            show(.look, toward: mouse.x >= pos.x)
        case .walking:
            show(.follow, toward: mouse.x >= pos.x)
        case .sleeping:
            if SpriteBank.shared.image(Pose.yawn.rawValue) != nil {
                // A yawn first, if sprites/yawn.png exists.
                show(.yawn, toward: true)
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, self.state == .sleeping else { return }
                    self.show(.sleep, toward: true)
                }
                yawnWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            } else {
                show(.sleep, toward: true)
            }
            zTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { [weak self] _ in
                self?.spawnZ()
            }
            spawnZ()
        case .playing:
            show(.play, toward: playTo.x > playFrom.x)
        case .happy:
            show(.happy, toward: true)
            heartBurst()
            Sounds.shared.play(.meow)
        case .curious:
            curiousAway = 0
            show(.curious, toward: true)
            Sounds.shared.startPurr()
        case .box:
            show(.box, toward: true)
        case .carried:
            show(.curious, toward: true)
        }
        applyAnimations()
    }

    // MARK: Main loop

    @objc func tick() {
        let now = CACurrentMediaTime()
        var dt = now - lastTick
        lastTick = now
        if dt > 0.1 { dt = 0.1 }
        let d = CGFloat(dt)

        let mouse = NSEvent.mouseLocation
        if gap(mouse, lastMouse) > 2 {
            lastMouseMove = now
            lastMouse = mouse
            activeTime += d
        } else if now - lastMouseMove > 1 {
            activeTime = 0
        }

        // Is the user dragging files around? If so the cat comes to meet them.
        let dragPB = NSPasteboard(name: .drag)
        if (NSEvent.pressedMouseButtons & 1) != 0 {
            if dragPB.changeCount != lastDragChange {
                lastDragChange = dragPB.changeCount
                fileDragActive = dragPB.canReadObject(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true])
            }
        } else {
            fileDragActive = false
            lastDragChange = dragPB.changeCount
        }

        updateHover(mouse, d)

        let body = CGPoint(x: pos.x, y: pos.y + spriteSize.height * 0.5)
        lift = 0

        // During a focus session she naps and ignores the cursor.
        let focusing = Pomodoro.shared.phase == .work
        if focusing && state != .sleeping && state != .carried && state != .happy && state != .box {
            state = .sleeping
        }

        switch state {
        case .idle:
            if abs(mouse.x - pos.x) > 24 { show(.look, toward: mouse.x >= pos.x) }
            let dd = gap(mouse, body)
            let st = Settings.shared
            if (follow || fileDragActive) && dd > CGFloat(fileDragActive ? st.followDistanceDrag : st.followDistance) * scale {
                state = .walking
            } else if hoverTime > CGFloat(st.curiousHoverDelay) {
                state = .curious
            } else if now - lastMouseMove > st.sleepDelay * MoodCenter.shared.sleepDelayMultiplier {
                state = .sleeping
            } else if st.playFrequency > 0 && now > nextPlayTime {
                startPlay(now)
            }

        case .walking:
            let vx = mouse.x - body.x
            let vy = mouse.y - body.y
            let dd = hypot(vx, vy)
            let stop = CGFloat(fileDragActive ? Settings.shared.stopDistanceDrag : Settings.shared.stopDistance) * scale
            if dd <= stop || !(follow || fileDragActive) {
                state = .idle
                nextPlayTime = now + Settings.shared.playAfterWalkDelay
            } else {
                let st = Settings.shared
                let lo = CGFloat(st.walkSpeedMin)
                let speed = min(max(lo + dd * CGFloat(st.walkSpeedFactor), lo), CGFloat(st.walkSpeedMax)) * CGFloat(MoodCenter.shared.speedMultiplier)
                let step = min(speed * d, dd - stop)
                pos.x += vx / dd * step
                pos.y += vy / dd * step
                if abs(vx) > 24 { show(.follow, toward: vx >= 0) }
            }

        case .sleeping:
            let near = gap(mouse, body) < CGFloat(Settings.shared.wakeDistance) * scale && now - lastMouseMove < 0.5
            if !focusing && (near || activeTime > CGFloat(Settings.shared.wakeActiveTime) || fileDragActive) {
                activeTime = 0
                lastMouseMove = now
                state = .idle
            }

        case .playing:
            playT += d / CGFloat(Settings.shared.pounceDuration)
            let u = min(playT, 1)
            let e = u * u * (3 - 2 * u)
            pos.x = playFrom.x + (playTo.x - playFrom.x) * e
            pos.y = playFrom.y + (playTo.y - playFrom.y) * e
            lift = sin(u * CGFloat.pi) * CGFloat(Settings.shared.pounceHeight) * scale
            if playT >= 1 {
                lift = 0
                LaserGame.shared.registerLanding(at: CGPoint(x: pos.x, y: pos.y + spriteSize.height * 0.5))
                floater("✨", size: 22,
                        color: .white,
                        at: CGPoint(x: view.bounds.width / 2, y: footY + spriteSize.height * 0.9),
                        drift: CGPoint(x: 0, y: 30), duration: 0.9)
                nextPlayTime = now + Settings.shared.randomPlayInterval()
                state = .idle
            }

        case .happy:
            if now - lastHeart > Settings.shared.heartInterval {
                lastHeart = now
                heart()
            }
            if now > happyUntil {
                lastMouseMove = now
                state = .idle
            }

        case .curious:
            if mouseOver { curiousAway = 0 } else { curiousAway += d }
            if curiousAway > 0.5 {
                hoverTime = 0
                state = .idle
            }

        case .box, .carried:
            break
        }

        updatePerch(d)
        pos = clampPoint(pos)
        applyFrame()
    }

    /// Optional: sit on top of other windows (Preferences-free toggle in her menu, off by default).
    /// She only perches while idle or asleep, and only if a window top is within 50 pt of her feet.
    func updatePerch(_ d: CGFloat) {
        let resting = state == .idle || state == .sleeping
        guard Settings.shared.perchEnabled, resting, !LaserGame.shared.isRunning else {
            perchWindowID = nil
            perchFalling = false
            return
        }
        let floorY = (Settings.shared.preferredScreen() ?? NSScreen.main)?.visibleFrame.minY ?? 0

        if let id = perchWindowID {
            if let spot = Perch.shared.spot(windowID: id),
               pos.x >= spot.frame.minX + 8, pos.x <= spot.frame.maxX - 8 {
                pos.y = Perch.eased(current: pos.y, target: spot.topY, dt: d)
            } else {
                // The window closed, moved out from under her, or hid: she drops to the floor.
                perchWindowID = nil
                perchFalling = pos.y > floorY + 1
            }
        } else if perchFalling {
            pos.y = Perch.eased(current: pos.y, target: floorY, dt: d, maxSpeed: 900)
            if pos.y <= floorY + 0.5 { perchFalling = false }
        } else if let spot = Perch.shared.spot(nearX: pos.x, feetY: pos.y) {
            perchWindowID = spot.windowID
        }
    }

    func startPlay(_ now: CFTimeInterval) {
        let st = Settings.shared
        let dx = CGFloat.random(in: -CGFloat(st.pounceRangeX)...CGFloat(st.pounceRangeX))
        let dy = CGFloat.random(in: -CGFloat(st.pounceRangeY)...CGFloat(st.pounceRangeY))
        let target = clampPoint(CGPoint(x: pos.x + dx, y: pos.y + dy))
        nextPlayTime = now + st.randomPlayInterval()
        if gap(target, pos) < CGFloat(st.pounceMinDistance) { return }
        playFrom = pos
        playTo = target
        playT = 0
        state = .playing
    }

    // MARK: Geometry

    func spriteScreenRect() -> CGRect {
        let f = window.frame
        return CGRect(x: f.midX - spriteSize.width / 2,
                      y: f.minY + footY,
                      width: spriteSize.width,
                      height: spriteSize.height)
    }

    func updateHover(_ mouse: CGPoint, _ d: CGFloat) {
        let pad: CGFloat = fileDragActive ? -40 : -6   // easier to drop onto her
        mouseOver = spriteScreenRect().insetBy(dx: pad, dy: pad).contains(mouse)
        if mouseOver { hoverTime += d } else { hoverTime = 0 }
        // Clicks pass through the transparent window unless the cursor is on the cat.
        let wantIgnore = !(mouseOver || state == .carried)
        if window.ignoresMouseEvents != wantIgnore {
            window.ignoresMouseEvents = wantIgnore
        }
    }

    func clampPoint(_ p: CGPoint) -> CGPoint {
        let screens = NSScreen.screens
        let home = Settings.shared.preferredScreen()
        guard let screen = home ?? screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main ?? screens.first else {
            return p
        }
        let vf = screen.visibleFrame
        let half = spriteSize.width * 0.35
        let x = min(max(p.x, vf.minX + half), vf.maxX - half)
        let maxY = max(vf.minY, vf.maxY - spriteSize.height - 6)
        let y = min(max(p.y, vf.minY), maxY)
        return CGPoint(x: x, y: y)
    }

    func applyFrame() {
        let f = window.frame
        let ox = (pos.x - f.width / 2).rounded()
        let oy = (pos.y - footY + lift).rounded()
        if abs(ox - f.origin.x) > 0.01 || abs(oy - f.origin.y) > 0.01 {
            window.setFrameOrigin(CGPoint(x: ox, y: oy))
        }
    }

    func applyScale() {
        footY = 16 * scale
        window.setContentSize(NSSize(width: PetController.baseSize.width * scale,
                                     height: PetController.baseSize.height * scale))
        layoutSprite()
    }

    func savePosition() {
        let d = UserDefaults.standard
        d.set(Double(pos.x), forKey: "posX")
        d.set(Double(pos.y), forKey: "posY")
    }

    // MARK: Floating hearts and Zzz

    func floater(_ text: String, size: CGFloat, color: NSColor, at p: CGPoint,
                 drift: CGPoint, duration: CFTimeInterval) {
        guard let root = view.layer else { return }
        let l = CATextLayer()
        l.string = text
        l.fontSize = size
        l.alignmentMode = .center
        l.foregroundColor = color.cgColor
        l.contentsScale = window.backingScaleFactor
        l.bounds = CGRect(x: 0, y: 0, width: size * 2, height: size * 1.5)
        l.position = p
        l.opacity = 0
        root.addSublayer(l)

        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }

        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: p)
        move.toValue = NSValue(point: CGPoint(x: p.x + drift.x, y: p.y + drift.y))

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [NSNumber(value: 0.0), NSNumber(value: 1.0), NSNumber(value: 1.0), NSNumber(value: 0.0)]
        fade.keyTimes = [NSNumber(value: 0.0), NSNumber(value: 0.15), NSNumber(value: 0.6), NSNumber(value: 1.0)]

        let g = CAAnimationGroup()
        g.animations = [move, fade]
        g.duration = duration
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        l.add(g, forKey: "float")
        CATransaction.commit()
    }

    func heart() {
        let jitter = CGFloat.random(in: -45...45)
        floater("💗", size: 22, color: .white,
                at: CGPoint(x: view.bounds.width / 2 + jitter, y: footY + spriteSize.height * 0.8),
                drift: CGPoint(x: CGFloat.random(in: -20...20), y: 70), duration: 1.3)
    }

    func heartBurst() {
        heart()
        heart()
        heart()
    }

    func spawnZ() {
        zFlip.toggle()
        let lavender = NSColor(calibratedRed: 0.86, green: 0.82, blue: 1.0, alpha: 1.0)
        floater(zFlip ? "Z" : "z", size: zFlip ? 24 : 18, color: lavender,
                at: CGPoint(x: view.bounds.width / 2 - 40, y: footY + spriteSize.height * 0.8),
                drift: CGPoint(x: 28, y: 55), duration: 2.4)
    }

    // MARK: Dragging

    func beginDrag(mouse: CGPoint) {
        grabOffset = CGPoint(x: pos.x - mouse.x, y: pos.y - mouse.y)
    }

    func drag(to mouse: CGPoint) {
        if state != .carried {
            stateBeforeDrag = state
            state = .carried
        }
        pos = clampPoint(CGPoint(x: mouse.x + grabOffset.x, y: mouse.y + grabOffset.y))
        lift = 0
        applyFrame()
    }

    func endDrag(clicked: Bool) {
        if clicked {
            CosmeticsUnlocks.recordPet()
            pet()
            return
        }
        if state == .carried {
            state = (stateBeforeDrag == .box) ? .box : .idle
        }
        lastMouseMove = CACurrentMediaTime()
        nextPlayTime = CACurrentMediaTime() + Settings.shared.playAfterDragDelay
        savePosition()
    }

    // MARK: Actions

    func pet() {
        let now = CACurrentMediaTime()
        happyUntil = now + 1.5
        lastHeart = now
        if state == .happy {
            heartBurst()
        } else {
            state = .happy
        }
    }

    @objc func petAction() {
        CosmeticsUnlocks.recordPet()
        pet()
    }

    @objc func toggleSleep() {
        if state == .sleeping { state = .idle } else { state = .sleeping }
    }

    @objc func toggleBox() {
        if state == .box { pet() } else { state = .box }
    }

    @objc func toggleFollow() {
        follow.toggle()
    }

    @objc func setSize(_ sender: NSMenuItem) {
        Settings.shared.scale = Double(sender.tag) / 100.0
    }

    @objc func openPreferences() {
        preferences.show()
    }

    @objc func toggleLaunchAtLogin() {
        let want = !LoginItem.isEnabled
        if case .failure(let error) = LoginItem.set(want) {
            let a = NSAlert()
            a.messageText = "I couldn't change the login setting."
            a.informativeText = error.localizedDescription
            a.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        } else if want && LoginItem.needsApproval {
            LoginItem.openSystemSettings()
        }
    }

    @objc func quit() {
        savePosition()
        NSApp.terminate(nil)
    }

    // MARK: Treasure Box (file stash)

    func fileHover(_ on: Bool) {
        if on {
            if state == .idle || state == .walking || state == .sleeping { state = .curious }
        } else if state == .curious {
            state = .idle
        }
    }

    func receiveFiles(_ urls: [URL]) {
        // Ask after the drag session has fully finished.
        DispatchQueue.main.async { [weak self] in
            self?.askToStore(urls)
        }
    }

    func catImage() -> NSImage? {
        guard let cg = SpriteBank.shared.image("happy") else { return nil }
        let h: CGFloat = 80
        let w = h * CGFloat(cg.width) / CGFloat(cg.height)
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    func askToStore(_ urls: [URL]) {
        defer { StashDrop.cleanup(urls) }   // temp files made from dropped text, links or images
        let alert = NSAlert()
        if urls.count == 1 {
            alert.messageText = "Want me to keep “\(urls[0].lastPathComponent)” safe?"
        } else {
            alert.messageText = "Want me to keep these \(urls.count) items safe?"
        }
        alert.informativeText = "I'll tuck a copy into my Treasure Box. Ask me for it any time from my right-click menu."
        alert.addButton(withTitle: "Store it")
        alert.addButton(withTitle: "No thanks")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also move the original to the Trash"
        if let img = catImage() { alert.icon = img }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let moveOriginal = (alert.suppressionButton?.state == .on)

        guard response == .alertFirstButtonReturn else {
            if state == .curious { state = .idle }
            return
        }

        var stored = 0
        for u in urls {
            if Stash.shared.add(u, moveOriginal: moveOriginal) != nil { stored += 1 }
        }
        stashWindow.reload()

        if stored < urls.count {
            let a = NSAlert()
            a.messageText = "I couldn't store \(urls.count - stored) item(s)."
            a.informativeText = "They may be unreadable, or the disk may be full."
            a.runModal()
        }
        if stored > 0 {
            pet()
            floater("📦", size: 26, color: .white,
                    at: CGPoint(x: view.bounds.width / 2, y: footY + spriteSize.height * 0.9),
                    drift: CGPoint(x: 0, y: 40), duration: 1.4)
        } else if state == .curious {
            state = .idle
        }
    }

    @objc func openStash() {
        stashWindow.onAdd = { [weak self] urls in self?.askToStore(urls) }
        stashWindow.show()
    }

    @objc func addFilesAction() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Give to the cat"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { askToStore(panel.urls) }
    }

    @objc func openStashItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = Stash.shared.items.first(where: { $0.id == id }) else { return }
        do {
            NSWorkspace.shared.open(try Stash.shared.openableURL(for: item))
        } catch {
            let a = NSAlert()
            a.messageText = "I couldn't open that."
            a.informativeText = error.localizedDescription
            a.alertStyle = .warning
            activateApp()
            a.runModal()
        }
    }

    @objc func revealStashFolder() {
        NSWorkspace.shared.open(Stash.shared.root)
    }

    func makeStashMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(makeItem("Open Treasure Box…", #selector(openStash)))
        m.addItem(makeItem("Add files…", #selector(addFilesAction)))
        m.addItem(makeItem("Paste from clipboard", #selector(pasteIntoBox)))
        m.addItem(makeItem("Show folder in Finder", #selector(revealStashFolder)))
        let items = Stash.shared.items.filter { !$0.isFolder }
        if !items.isEmpty {
            m.addItem(NSMenuItem.separator())
            for item in items.prefix(8) {
                let it = makeItem(item.name, #selector(openStashItem(_:)))
                it.representedObject = item.id
                m.addItem(it)
            }
        }
        return m
    }

    // MARK: Modules (reminders, focus timer, watchers, laser game, Finder service)

    func setupModules() {
        Log.info("MoonCat started")
        CosmeticsUnlocks.recordLaunch()
        Notifier.install()
        StashTemp.cleanup()     // decrypted leftovers from a crash

        // Finder: right-click a file ▸ Services ▸ Send to Moon Cat
        StashServiceProvider.shared.onFiles = { [weak self] urls in self?.receiveFiles(urls) }
        NSApp.servicesProvider = StashServiceProvider.shared
        NSUpdateDynamicServices()

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            StashTemp.cleanup()
        }

        // Reminders
        ReminderStore.shared.onFire = { [weak self] r in self?.reminderFired(r) }
        ReminderStore.shared.start()

        // Focus timer
        Pomodoro.shared.onPhaseChange = { [weak self] phase in
            guard let self = self else { return }
            if phase == .off && self.state == .sleeping { self.state = .idle }
            self.updateStatusTitle()
        }
        Pomodoro.shared.onPhaseEnd = { [weak self] _ in
            Sounds.shared.play(.chime)
            self?.pet()
        }
        Pomodoro.shared.onTick = { [weak self] _ in self?.updateStatusTitle() }

        // Laser game
        NotificationCenter.default.addObserver(self, selector: #selector(laserChanged),
                                               name: LaserGame.changed, object: nil)

        // System watchers
        DownloadsWatcher.shared.onFinished = { [weak self] in
            guard Pomodoro.shared.phase != .work else { return }
            self?.pet()
        }
        DownloadsWatcher.shared.start()
        BatteryWatcher.shared.start()

        // Chat: she perks up when Moon answers.
        ChatWindowController.shared.onCatReply = { [weak self] _ in self?.pet() }

        MoonCatUpdater.shared.start()
        WelcomeWindowController.showIfFirstRun()
    }

    @objc func openChat() { Log.info("Menu: Chat with Moon"); ChatWindowController.shared.show() }
    @objc func changePassword() { Vault.shared.changePasswordInteractive() }
    @objc func openCosmetics() { CosmeticsWindowController.shared.show() }
    @objc func showAbout() { AboutWindowController.shared.show() }
    @objc func showWelcome() { WelcomeWindowController.shared.show() }
    @objc func showLog() { Log.revealInFinder() }
    @objc func checkForUpdates() { MoonCatUpdater.shared.checkForUpdates() }
    @objc func togglePerch() {
        Settings.shared.perchEnabled = !Settings.shared.perchEnabled
        perchWindowID = nil
        perchFalling = false
    }

    func reminderFired(_ r: Reminder) {
        pet()
        floater("⏰", size: 28, color: .white,
                at: CGPoint(x: view.bounds.width / 2, y: footY + spriteSize.height * 0.9),
                drift: CGPoint(x: 0, y: 50), duration: 1.6)
        Sounds.shared.play(.chime)
        if Notifier.shared.denied {
            // Banners are switched off for MoonCat, so say it here.
            let a = NSAlert()
            a.messageText = r.displayTitle
            a.informativeText = "Reminder from Moon Cat. (Notifications are off for MoonCat in System Settings, so I'm telling you here.)"
            activateApp()
            a.runModal()
        }
    }

    @objc func remindMe() { ReminderStore.promptAndAdd() }
    @objc func showReminders() { ReminderStore.showList() }

    @objc func toggleFocus() {
        if Pomodoro.shared.isRunning {
            Pomodoro.shared.stop()
        } else {
            Pomodoro.shared.start()
        }
    }

    @objc func pasteIntoBox() {
        let urls = StashDrop.files(from: NSPasteboard.general)
        if urls.isEmpty {
            NSSound.beep()
            return
        }
        askToStore(urls)
    }

    // MARK: Laser game

    @objc func toggleLaser() {
        let game = LaserGame.shared
        if game.isRunning {
            game.stop()
            return
        }
        if state == .sleeping || state == .box { state = .idle }
        game.onPounceRequest = { [weak self] point in self?.pounce(to: point) }
        game.onFinish = { [weak self] score in self?.laserFinished(score) }
        game.start()
    }

    /// Pounce so that her body lands on `target` (a screen point), reusing the normal pounce animation.
    func pounce(to target: CGPoint) {
        if state == .carried || state == .box { return }
        let dest = clampPoint(CGPoint(x: target.x, y: target.y - spriteSize.height * 0.5))
        if gap(dest, pos) < 30 { return }
        playFrom = pos
        playTo = dest
        playT = 0
        nextPlayTime = CACurrentMediaTime() + 5
        if state == .playing {
            show(.play, toward: dest.x > playFrom.x)
        } else {
            state = .playing
        }
    }

    func laserFinished(_ score: Int) {
        pet()
        floater(score == 1 ? "Caught 1!" : "Caught \(score)!", size: 18, color: .white,
                at: CGPoint(x: view.bounds.width / 2, y: footY + spriteSize.height * 0.95),
                drift: CGPoint(x: 0, y: 50), duration: 2.2)
        updateStatusTitle()
    }

    @objc func laserChanged() { updateStatusTitle() }

    // MARK: Menu-bar title (laser score or focus timer; otherwise the moon)

    func updateStatusTitle() {
        var title = ""
        if LaserGame.shared.isRunning {
            title = "🎯 \(LaserGame.shared.score)"
        } else if Pomodoro.shared.isRunning {
            let icon = Pomodoro.shared.phase == .work ? "🍅" : "☕️"
            title = "\(icon) \(Pomodoro.clock(Pomodoro.shared.remaining))"
        }
        if statusItem?.button?.title != title { statusItem?.button?.title = title }
        statusItem?.button?.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
    }

    // MARK: Global shortcut and Quick Search

    func setupHotKey() {
        HotKey.shared.onTrigger = { [weak self] in self?.quickSearch.toggle() }
        HotKey.shared.register()
    }

    @objc func openQuickSearch() {
        quickSearch.show()
    }

    @objc func startVeil() {
        Veil.shared.startSelecting()
    }

    @objc func checkVeil() {
        Veil.shared.diagnose()
    }

    @objc func liftVeils() {
        Veil.shared.removeAll()
    }

    @objc func openConverter() {
        ConverterWindowController.shared.show()
    }

    // MARK: Auto-forget (offer to clear out old Treasure Box items)

    /// Checks once shortly after launch, then looks again every hour; the hourly look only
    /// does anything when a day has passed since the last check.
    func scheduleAutoForget() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.runAutoForgetCheck(force: true)
        }
        autoForgetTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.runAutoForgetCheck(force: false)
        }
    }

    func runAutoForgetCheck(force: Bool) {
        let st = Settings.shared
        guard st.autoForgetEnabled, !autoForgetBusy else { return }
        let now = Date().timeIntervalSince1970
        if !force && now - st.autoForgetLastCheck < 24 * 3600 { return }
        st.autoForgetLastCheck = now

        let days = st.autoForgetDays
        let stale = Stash.shared.staleItems(olderThanDays: days)
        if stale.isEmpty { return }

        autoForgetBusy = true
        defer { autoForgetBusy = false }

        let dayText = days == 1 ? "1 day" : "\(days) days"
        let alert = NSAlert()
        alert.messageText = stale.count == 1
            ? "1 item in the Treasure Box is older than \(dayText)."
            : "\(stale.count) items in the Treasure Box are older than \(dayText)."
        let oldest = stale.sorted { $0.date < $1.date }.prefix(5).map { "• " + $0.name }
        var info = oldest.joined(separator: "\n")
        if stale.count > oldest.count { info += "\n…and \(stale.count - oldest.count) more" }
        info += "\n\nNothing is deleted unless you choose Delete. Files elsewhere on your Mac aren't touched."
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Keep Them")
        alert.addButton(withTitle: stale.count == 1 ? "Delete 1 Item" : "Delete \(stale.count) Items")
        alert.buttons[1].hasDestructiveAction = true
        if let img = catImage() { alert.icon = img }

        activateApp()
        if alert.runModal() == .alertSecondButtonReturn {
            Stash.shared.removeMany(stale)
        }
    }

    // MARK: Menus

    func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(makeItem("Pet the cat", #selector(petAction)))
        menu.addItem(makeItem(state == .sleeping ? "Wake up" : "Let her sleep", #selector(toggleSleep)))
        menu.addItem(makeItem(state == .box ? "Come out of the box" : "Hide in the box", #selector(toggleBox)))
        menu.addItem(NSMenuItem.separator())

        let boxItem = NSMenuItem(title: "Treasure Box (\(Stash.shared.items.filter { !$0.isFolder }.count))", action: nil, keyEquivalent: "")
        boxItem.submenu = makeStashMenu()
        menu.addItem(boxItem)
        let searchHint = HotKey.shared.isRegistered ? "   " + HotKey.shared.displayString : ""
        menu.addItem(makeItem("Quick Search…" + searchHint, #selector(openQuickSearch)))
        menu.addItem(makeItem("Convert Files…", #selector(openConverter)))
        menu.addItem(makeItem("Moon Veil: hide part of the screen…", #selector(startVeil)))
        menu.addItem(makeItem("Moon Veil settings…", #selector(checkVeil)))
        if Veil.shared.count > 0 {
            let lift = NSMenuItem(title: "Lift a veil (\(Veil.shared.count))", action: nil, keyEquivalent: "")
            lift.submenu = Veil.shared.liftMenu()
            menu.addItem(lift)
        }
        menu.addItem(NSMenuItem.separator())

        menu.addItem(makeItem("Chat with Moon…", #selector(openChat)))
        menu.addItem(makeItem("Dress up…", #selector(openCosmetics)))
        menu.addItem(makeItem("Change MoonCat Password…", #selector(changePassword)))
        let perchItem = makeItem("Sit on my windows", #selector(togglePerch))
        perchItem.state = Settings.shared.perchEnabled ? .on : .off
        menu.addItem(perchItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(makeItem("Remind me…", #selector(remindMe)))
        menu.addItem(makeItem("Reminders…", #selector(showReminders)))
        menu.addItem(makeItem(Pomodoro.shared.isRunning ? "Stop focus" : "Start focus", #selector(toggleFocus)))
        menu.addItem(makeItem(LaserGame.shared.isRunning ? "Stop laser" : "Play laser", #selector(toggleLaser)))
        menu.addItem(NSMenuItem.separator())

        let followItem = makeItem("Follow my cursor", #selector(toggleFollow))
        followItem.state = follow ? .on : .off
        menu.addItem(followItem)

        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let sizes: [(String, Int)] = [("Small", 70), ("Medium", 100), ("Large", 140)]
        for (title, tag) in sizes {
            let it = makeItem(title, #selector(setSize(_:)))
            it.tag = tag
            it.state = abs(Double(scale) - Double(tag) / 100.0) < 0.01 ? .on : .off
            sub.addItem(it)
        }
        sizeItem.submenu = sub
        menu.addItem(sizeItem)

        let loginItem = makeItem("Launch at login", #selector(toggleLaunchAtLogin))
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(makeItem("Preferences…", #selector(openPreferences), key: ","))

        let helpItem = NSMenuItem(title: "About & help", action: nil, keyEquivalent: "")
        let help = NSMenu()
        help.addItem(makeItem("About Moon Cat", #selector(showAbout)))
        help.addItem(makeItem("Welcome guide…", #selector(showWelcome)))
        help.addItem(makeItem("Show log file", #selector(showLog)))
        if MoonCatUpdater.isAvailable { help.addItem(makeItem("Check for updates…", #selector(checkForUpdates))) }
        helpItem.submenu = help
        menu.addItem(helpItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Quit Moon Cat", #selector(quit), key: "q"))
    }

    func showMenu(event: NSEvent, in v: NSView) {
        let m = NSMenu()
        populate(m)
        NSMenu.popUpContextMenu(m, with: event, for: v)
    }

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.template()
        item.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }
}

extension PetController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }
}
