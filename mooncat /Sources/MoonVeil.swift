import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

// MARK: - Moon Veil
//
// Pick a rectangle anywhere on the screen, over any app, and Moon draws a veil over it.
// A veil is an ordinary borderless window floating above everything, so the default look
// (frosted glass) needs no permission at all. It is a window on top of the screen, not an
// edit to the other app: the covered content is still there underneath and shows again
// when the veil is lifted.
//
// Because the veil is a real window, screenshots and "share my entire screen" capture it too.
// Sharing a single window of another app does not include it.
//
// "Adapt to app" is the only part that reads the screen. It is opt-in, asks first, and
// falls back to frosted (once, quietly) if macOS says no.

enum VeilStyle: String, CaseIterable {
    case frosted, paper, black, color, blend

    var title: String {
        switch self {
        case .frosted: return "Frosted glass"
        case .paper: return "Paper"
        case .black: return "Solid black"
        case .color: return "Solid colour"
        case .blend: return "Adapt to app (needs screen access)"
        }
    }
}

final class Veil: NSObject, NSMenuDelegate {
    static let shared = Veil()

    private override init() {
        super.init()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(environmentChanged),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(environmentChanged),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    private static let styleKey = "veilStyleV2"
    private static let colorKey = "veilColorV2"
    private var panels: [VeilPanel] = []
    private var selector: [VeilSelectorPanel] = []
    private weak var liftRoot: NSMenu?
    private var pendingRefresh: DispatchWorkItem?

    var count: Int { return panels.count }
    var isSelecting: Bool { return !selector.isEmpty }

    /// The look new veils start with. Frosted unless the user chose otherwise.
    var defaultStyle: VeilStyle {
        get { return VeilStyle(rawValue: UserDefaults.standard.string(forKey: Self.styleKey) ?? "") ?? .frosted }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.styleKey) }
    }

    /// The last solid colour chosen.
    var defaultColor: NSColor {
        get {
            if let a = UserDefaults.standard.array(forKey: Self.colorKey) as? [Double], a.count == 3 {
                return NSColor(srgbRed: CGFloat(a[0]), green: CGFloat(a[1]), blue: CGFloat(a[2]), alpha: 1)
            }
            return NSColor(srgbRed: 0.18, green: 0.20, blue: 0.27, alpha: 1)
        }
        set {
            if let c = newValue.usingColorSpace(.sRGB) {
                let parts: [Double] = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
                UserDefaults.standard.set(parts, forKey: Self.colorKey)
            }
        }
    }

    /// Set when the screen could not be read, so adaptive veils stop trying until the user asks again.
    fileprivate var matchBroken = false
    private var warned = false

    // MARK: Choosing an area

    /// Dims every screen and lets the user drag a rectangle. Esc cancels; hold ⇧ while letting go to keep choosing.
    func startSelecting() {
        if isSelecting { return }
        for screen in NSScreen.screens {
            let p = VeilSelectorPanel(screen: screen)
            p.selectorView.onPick = { [weak self] rect, keepGoing in
                self?.cover(rect)
                if !keepGoing { self?.stopSelecting() }
            }
            p.selectorView.onCancel = { [weak self] in self?.stopSelecting() }
            selector.append(p)
        }
        activateApp()
        for p in selector { p.orderFrontRegardless() }
        let preferred = selector.first(where: { $0.screen == NSScreen.main }) ?? selector.first
        preferred?.makeKey()
    }

    func stopSelecting() {
        selector.forEach { $0.orderOut(nil) }
        selector.removeAll()
    }

    // MARK: Veils

    func cover(_ screenRect: NSRect) {
        installPanicKey()
        if hiddenAll {
            hiddenAll = false
            panels.forEach { $0.orderFrontRegardless() }
        }
        var s = defaultStyle
        // Never start an adaptive veil that cannot read the screen: it would only ask for permission.
        if s == .blend {
            var ok = false
            if #available(macOS 14.0, *) { ok = CGPreflightScreenCaptureAccess() }
            if !ok { s = .frosted }
        }
        let p = VeilPanel(frame: screenRect.integral, style: s, color: defaultColor)
        panels.append(p)
        p.orderFrontRegardless()
    }

    func remove(_ p: VeilPanel) {
        p.orderOut(nil)
        panels.removeAll { $0 === p }
    }

    func removeAll() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        hiddenAll = false
    }

    /// Lets a veil's own menu (and the cat's menu) show above the veils while it is open.
    fileprivate func menuMode(_ on: Bool) {
        let level: NSWindow.Level = on ? .statusBar : .screenSaver
        panels.forEach { $0.level = level }
    }

    // MARK: Style choice

    /// Applies a style to one veil. "Adapt to app" first asks the user, because it needs Screen Recording.
    fileprivate func choose(_ s: VeilStyle, for panel: VeilPanel) {
        if s == .blend {
            guard enableAdaptive() else { return }
            matchBroken = false
            warned = false
        }
        defaultStyle = s
        panel.apply(s)
    }

    fileprivate func chosenColor(_ c: NSColor, for panel: VeilPanel) {
        defaultColor = c
        defaultStyle = .color
        panel.setFill(c)
    }

    /// True when adaptive mode can run right now. Otherwise explains it (once per click) and returns false.
    private func enableAdaptive() -> Bool {
        guard #available(macOS 14.0, *) else {
            showNote("“Adapt to app” needs macOS 14 or later. Frosted glass works on every version.")
            return false
        }
        if CGPreflightScreenCaptureAccess() { return true }
        let a = NSAlert()
        a.messageText = "Turn on adaptive mode?"
        a.informativeText = "An adaptive veil copies the colours around it, so Moon Cat has to look at the screen. macOS will ask for Screen Recording permission. Moon Cat only samples colours next to a veil; it never saves or sends pictures of your screen.\n\nAfter you allow it, quit and reopen Moon Cat, then choose “Adapt to app” again. Until then your veils stay frosted."
        a.addButton(withTitle: "Enable adaptive mode")
        a.addButton(withTitle: "Not now")
        activateApp()
        if a.runModal() == .alertFirstButtonReturn { _ = CGRequestScreenCaptureAccess() }
        return false
    }

    private func showNote(_ text: String) {
        let a = NSAlert()
        a.messageText = "Moon Veil"
        a.informativeText = text
        a.addButton(withTitle: "OK")
        activateApp()
        a.runModal()
    }

    // MARK: Event-driven refresh (adaptive veils only)

    @objc private func environmentChanged() {
        guard !matchBroken, panels.contains(where: { $0.style == .blend }) else { return }
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panels.forEach { $0.refreshMatch(auto: true) }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// An adaptive veil could not read the screen. It becomes frosted, so nothing is ever left uncovered,
    /// and the user hears about it once, with a notification rather than a blocking window.
    fileprivate func matchFailed(_ detail: String, denied: Bool, panel: VeilPanel) {
        Log.error("Moon Veil: could not match colours (denied: \(denied)): \(detail)")
        matchBroken = true
        if denied {
            for p in panels where p.style == .blend { p.apply(.frosted) }
            if defaultStyle == .blend { defaultStyle = .frosted }
        }
        panel.apply(.frosted)
        if warned { return }
        warned = true
        Notifier.shared.post(title: "Moon Veil stays frosted",
                             body: "Adaptive mode couldn't read the screen. Open “Moon Veil settings…” in the cat's menu to fix it.")
    }

    // MARK: Hide / show everything with one key

    private(set) var hiddenAll = false
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private static let hkSignature: OSType = 0x4D56454C        // "MVEL"
    private static let hkID: UInt32 = 7
    private static let okStatus: OSStatus = 0
    private static let notHandledStatus: OSStatus = -9874
    static let panicKeyText = "⌃⌥⌘V"

    /// Hides every veil, or brings them all back. Bound to ⌃⌥⌘V once a veil exists.
    func togglePanic() {
        if panels.isEmpty { return }
        hiddenAll.toggle()
        for p in panels {
            if hiddenAll { p.orderOut(nil) } else { p.orderFrontRegardless() }
        }
    }

    private func installPanicKey() {
        if hotKeyRef != nil { return }
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let me = Unmanaged.passUnretained(self).toOpaque()
            let st = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
                guard let event = event, let userData = userData else { return Veil.notHandledStatus }
                var id = EventHotKeyID()
                let err = GetEventParameter(event,
                                            EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID),
                                            nil,
                                            MemoryLayout<EventHotKeyID>.size,
                                            nil,
                                            &id)
                if err == Veil.okStatus && id.signature == Veil.hkSignature && id.id == Veil.hkID {
                    let owner = Unmanaged<Veil>.fromOpaque(userData).takeUnretainedValue()
                    DispatchQueue.main.async { owner.togglePanic() }
                    return Veil.okStatus
                }
                return Veil.notHandledStatus
            }, 1, &spec, me, &hotKeyHandler)
            if st != Veil.okStatus { hotKeyHandler = nil; return }
        }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Veil.hkSignature, id: Veil.hkID)
        let mods = UInt32(controlKey | optionKey | cmdKey)
        let st = RegisterEventHotKey(UInt32(kVK_ANSI_V), mods, id, GetApplicationEventTarget(), 0, &ref)
        if st == Veil.okStatus {
            hotKeyRef = ref
        } else {
            Log.error("Moon Veil: could not register the hide-all shortcut (status \(st))")
        }
    }

    // MARK: Lifting one veil from the cat's menu

    /// "Lift all", then one entry per veil. Pointing at an entry outlines that veil on screen.
    func liftMenu() -> NSMenu {
        let m = NSMenu(title: "Veils")
        m.autoenablesItems = false
        m.delegate = self
        liftRoot = m
        let all = NSMenuItem(title: "Lift all (\(panels.count))", action: #selector(liftAllAction), keyEquivalent: "")
        all.target = self
        all.tag = -1
        m.addItem(all)
        let hide = NSMenuItem(title: (hiddenAll ? "Show all veils" : "Hide all veils for now") + "   " + Veil.panicKeyText,
                              action: #selector(panicAction), keyEquivalent: "")
        hide.target = self
        hide.tag = -2
        m.addItem(hide)
        m.addItem(NSMenuItem.separator())
        for (i, p) in panels.enumerated() {
            let item = NSMenuItem(title: describe(p, index: i), action: nil, keyEquivalent: "")
            item.tag = i
            let sub = NSMenu()
            sub.autoenablesItems = false
            sub.delegate = self
            let lift = NSMenuItem(title: "Lift this veil", action: #selector(liftOne(_:)), keyEquivalent: "")
            lift.target = self
            lift.tag = i
            let through = NSMenuItem(title: "Let clicks pass through", action: #selector(toggleThrough(_:)), keyEquivalent: "")
            through.target = self
            through.tag = i
            through.state = p.clickThrough ? .on : .off
            sub.addItem(lift)
            sub.addItem(through)
            item.submenu = sub
            m.addItem(item)
        }
        return m
    }

    @objc private func liftAllAction() { removeAll() }
    @objc private func panicAction() { togglePanic() }

    @objc private func liftOne(_ sender: NSMenuItem) {
        if sender.tag >= 0 && sender.tag < panels.count { remove(panels[sender.tag]) }
    }

    @objc private func toggleThrough(_ sender: NSMenuItem) {
        if sender.tag >= 0 && sender.tag < panels.count { panels[sender.tag].clickThrough.toggle() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === liftRoot { menuMode(true) }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let item = item else { panels.forEach { $0.setHighlighted(false) }; return }
        for (i, p) in panels.enumerated() { p.setHighlighted(item.tag == -1 || item.tag == i) }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === liftRoot {
            panels.forEach { $0.setHighlighted(false) }
            menuMode(false)
        }
    }

    private func describe(_ p: VeilPanel, index: Int) -> String {
        let f = p.frame
        let center = CGPoint(x: f.midX, y: f.midY)
        let sf = (NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main ?? NSScreen.screens[0]).frame
        let fx = (center.x - sf.minX) / sf.width, fy = (center.y - sf.minY) / sf.height
        let h = fx < 0.34 ? "left" : (fx > 0.66 ? "right" : "middle")
        let v = fy > 0.66 ? "top" : (fy < 0.34 ? "bottom" : "middle")
        var place = "center"
        if h == "middle" && v != "middle" { place = v }
        else if v == "middle" && h != "middle" { place = h }
        else if h != "middle" { place = v + "-" + h }
        var text = "Veil \(index + 1): \(place), \(Int(f.width))×\(Int(f.height))"
        if let app = Veil.appName(at: center) { text += " over \(app)" }
        return text
    }

    /// The app whose window is under a point (screen coordinates), if any.
    private static func appName(at point: CGPoint) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != me,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(cgPoint),
                  let name = w[kCGWindowOwnerName as String] as? String else { continue }
            return name
        }
        return nil
    }

    // MARK: Settings and screen access

    /// Opens the Moon Veil window: screen access status, buttons to fix it, and the default look.
    func diagnose() {
        VeilAccessWindow.shared.show()
    }
}

// MARK: - A soft colour layer that follows light and dark mode

private final class VeilTintView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override var isOpaque: Bool { return false }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - The veil itself

final class VeilPanel: NSPanel {
    private let effect = NSVisualEffectView()
    private let tint = VeilTintView()
    private let moon = NSTextField(labelWithString: "🌙")
    private var grab = NSPoint.zero
    private var startFrame = NSRect.zero
    private var resizing = false
    private var edgeL = false, edgeR = false, edgeT = false, edgeB = false
    private var moved = false
    private var matched = false
    private var matchTask: Task<Void, Never>?
    private var matching = false
    private var matchID = UUID()
    private var sampler: NSColorSampler?
    private(set) var style: VeilStyle = .frosted
    private(set) var fill: NSColor = .black

    private static let cornerRadius: CGFloat = 12
    private static let edgeGrip: CGFloat = 9

    /// When on, mouse clicks and drags go to the app underneath (so you can drag files across a veil).
    var clickThrough = false { didSet { ignoresMouseEvents = clickThrough } }

    func setHighlighted(_ on: Bool) {
        guard let layer = contentView?.layer else { return }
        if on {
            layer.borderColor = NSColor.systemYellow.cgColor
            layer.borderWidth = 3
        } else {
            layer.borderColor = NSColor(white: 1, alpha: 0.28).cgColor
            layer.borderWidth = 1
        }
    }

    // Never steal focus from the app underneath.
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }

    init(frame: NSRect, style: VeilStyle, color: NSColor) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        fill = color
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let content = VeilContentView(frame: NSRect(origin: .zero, size: frame.size))
        content.owner = self
        content.autoresizingMask = [.width, .height]
        contentView = content

        effect.frame = content.bounds
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        content.addSubview(effect)

        tint.frame = content.bounds
        tint.autoresizingMask = [.width, .height]
        content.addSubview(tint)

        moon.font = NSFont.systemFont(ofSize: 22)
        moon.alphaValue = 0.55
        moon.sizeToFit()
        content.addSubview(moon)

        // A close button that appears when the pointer is over this veil.
        let close = NSButton(frame: NSRect(x: frame.width - 34, y: frame.height - 34, width: 22, height: 22))
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Lift this veil")
        close.imageScaling = .scaleProportionallyUpOrDown
        close.contentTintColor = .white
        let glow = NSShadow()
        glow.shadowColor = NSColor.black.withAlphaComponent(0.65)
        glow.shadowBlurRadius = 3
        glow.shadowOffset = .zero
        close.shadow = glow
        close.target = self
        close.action = #selector(removeThis)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        close.toolTip = "Lift this veil"
        close.isHidden = true
        content.addSubview(close)
        content.closeButton = close

        content.wantsLayer = true
        content.layer?.cornerRadius = VeilPanel.cornerRadius
        content.layer?.masksToBounds = true
        setHighlighted(false)
        apply(style)
        layoutMoon()
    }

    // MARK: Looks

    func apply(_ newStyle: VeilStyle) {
        style = newStyle
        matchTask?.cancel()
        matching = false
        contentView?.layer?.contents = nil
        contentView?.layer?.cornerRadius = VeilPanel.cornerRadius
        switch newStyle {
        case .frosted:
            showFrosted()
        case .paper:
            showSolid(NSColor(srgbRed: 0.96, green: 0.94, blue: 0.89, alpha: 1))
        case .black:
            showSolid(.black)
        case .color:
            showSolid(fill)
        case .blend:
            showFrosted()      // covers the spot right away, and stays like this if reading the screen fails
            refreshMatch()
        }
    }

    func setFill(_ c: NSColor) {
        fill = c
        apply(.color)
    }

    private func showFrosted() {
        matched = false
        effect.isHidden = false
        tint.color = NSColor.windowBackgroundColor.withAlphaComponent(0.5)
        layoutMoon()
    }

    private func showSolid(_ c: NSColor) {
        matched = false
        effect.isHidden = true
        tint.color = c
        layoutMoon()
    }

    private func showMatched(_ image: CGImage) {
        matched = true
        effect.isHidden = true
        tint.color = .clear
        if let layer = contentView?.layer {
            layer.cornerRadius = 0
            layer.contentsGravity = .resize
            layer.magnificationFilter = .linear
            layer.contents = image
        }
        layoutMoon()
    }

    /// Reads the colours around this veil from the screen and repaints it to match. Adaptive veils only.
    func refreshMatch(auto: Bool = false) {
        guard style == .blend else { return }
        guard #available(macOS 14.0, *) else {
            Veil.shared.matchFailed("Adaptive mode needs macOS 14 or later.", denied: false, panel: self)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            Veil.shared.matchFailed("macOS has not allowed Moon Cat to record the screen.", denied: true, panel: self)
            return
        }
        if auto && (matching || moved) { return }     // never interrupt a read or a drag
        matchTask?.cancel()
        let rect = frame
        let id = UUID()
        matchID = id
        matching = true
        matchTask = Task { @MainActor [weak self] in
            do {
                let image = try await ScreenMatch.fill(for: rect)
                guard let self = self else { return }
                if self.matchID == id { self.matching = false }
                guard !Task.isCancelled, self.style == .blend else { return }
                self.showMatched(image)
            } catch {
                guard let self = self else { return }
                if self.matchID == id { self.matching = false }
                guard !Task.isCancelled, self.style == .blend else { return }
                let code = (error as NSError).code
                Veil.shared.matchFailed(error.localizedDescription, denied: code == -3801, panel: self)
            }
        }
    }

    private func layoutMoon() {
        guard let c = contentView else { return }
        moon.setFrameOrigin(NSPoint(x: (c.bounds.width - moon.frame.width) / 2,
                                    y: (c.bounds.height - moon.frame.height) / 2))
        moon.isHidden = matched || c.bounds.width < 56 || c.bounds.height < 56
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        layoutMoon()
    }

    // MARK: Mouse: drag to move, drag any edge or corner to resize, double-click to lift

    fileprivate func veilMouseDown(_ event: NSEvent, in view: NSView) {
        if event.clickCount >= 2 { Veil.shared.remove(self); return }
        grab = NSEvent.mouseLocation
        moved = false
        startFrame = frame
        let p = view.convert(event.locationInWindow, from: nil)
        let g = VeilPanel.edgeGrip
        edgeL = p.x < g
        edgeR = p.x > view.bounds.width - g
        edgeB = p.y < g
        edgeT = p.y > view.bounds.height - g
        resizing = edgeL || edgeR || edgeB || edgeT
    }

    fileprivate func veilMouseDragged(_ event: NSEvent) {
        let m = NSEvent.mouseLocation
        let dx = m.x - grab.x, dy = m.y - grab.y
        if abs(dx) > 1 || abs(dy) > 1 { moved = true }
        let minSize: CGFloat = 40
        var f = startFrame
        if resizing {
            if edgeL { f.origin.x += dx; f.size.width -= dx }
            if edgeR { f.size.width += dx }
            if edgeB { f.origin.y += dy; f.size.height -= dy }
            if edgeT { f.size.height += dy }
            if f.size.width < minSize {
                f.size.width = minSize
                if edgeL { f.origin.x = startFrame.maxX - minSize }
            }
            if f.size.height < minSize {
                f.size.height = minSize
                if edgeB { f.origin.y = startFrame.maxY - minSize }
            }
        } else {
            f.origin.x += dx
            f.origin.y += dy
        }
        setFrame(f, display: true)
    }

    fileprivate func veilMouseUp() {
        if moved {
            moved = false
            if style == .blend { refreshMatch() }     // it may now sit over something with different colours
        }
    }

    // MARK: Right-click menu

    fileprivate func veilContextMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
            it.target = self
            m.addItem(it)
            return it
        }
        _ = add("Lift this veil", #selector(removeThis))
        _ = add("Lift all veils (\(Veil.shared.count))", #selector(removeEvery))
        _ = add("Hide all veils for now   \(Veil.panicKeyText)", #selector(panicNow))
        m.addItem(NSMenuItem.separator())
        for s in VeilStyle.allCases {
            let it = NSMenuItem(title: s.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s.rawValue
            it.state = style == s ? .on : .off
            m.addItem(it)
        }
        m.addItem(NSMenuItem.separator())
        _ = add("Pick colour from the screen (eyedropper)…", #selector(pickEyedropper))
        _ = add("Choose a colour…", #selector(chooseColor))
        if style == .blend { _ = add("Re-match colours now", #selector(rematch)) }
        m.addItem(NSMenuItem.separator())
        let through = add("Let clicks pass through (undo from the cat's menu)", #selector(makeClickThrough))
        through.state = .off
        _ = add("Cover another area…", #selector(coverMore))
        return m
    }

    @objc private func rematch() {
        Veil.shared.matchBroken = false
        refreshMatch()
    }
    @objc private func makeClickThrough() { clickThrough = true }
    @objc private func removeThis() { Veil.shared.remove(self) }
    @objc private func removeEvery() { Veil.shared.removeAll() }
    @objc private func panicNow() { Veil.shared.togglePanic() }
    @objc private func coverMore() { Veil.shared.startSelecting() }
    @objc private func pickStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let s = VeilStyle(rawValue: raw) {
            Veil.shared.choose(s, for: self)
        }
    }

    /// The system eyedropper. Click the app's background (just outside the veil) to take its colour.
    @objc private func pickEyedropper() {
        let s = NSColorSampler()
        sampler = s
        s.show { [weak self] picked in
            guard let self = self else { return }
            self.sampler = nil
            if let c = picked { Veil.shared.chosenColor(c, for: self) }
        }
    }

    @objc private func chooseColor() {
        let cp = NSColorPanel.shared
        cp.setTarget(self)
        cp.setAction(#selector(colorPanelChanged(_:)))
        cp.color = fill
        cp.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        activateApp()
        cp.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        Veil.shared.chosenColor(sender.color, for: self)
    }
}

private final class VeilContentView: NSView {
    weak var owner: VeilPanel?
    var closeButton: NSButton?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    override func mouseEntered(with event: NSEvent) { closeButton?.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton?.isHidden = true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
    override func mouseDown(with event: NSEvent) { owner?.veilMouseDown(event, in: self) }
    override func mouseDragged(with event: NSEvent) { owner?.veilMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { owner?.veilMouseUp() }
    override func rightMouseDown(with event: NSEvent) {
        guard let m = owner?.veilContextMenu() else { return }
        Veil.shared.menuMode(true)          // so the menu is not hidden behind the veils
        NSMenu.popUpContextMenu(m, with: event, for: self)
        Veil.shared.menuMode(false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        let g: CGFloat = 9
        let w = bounds.width, h = bounds.height
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(NSRect(x: 0, y: g, width: g, height: max(0, h - 2 * g)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - g, y: g, width: g, height: max(0, h - 2 * g)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: g, y: 0, width: max(0, w - 2 * g), height: g), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: g, y: h - g, width: max(0, w - 2 * g), height: g), cursor: .resizeUpDown)
        for (cx, cy) in [(CGFloat(0), CGFloat(0)), (w - g, 0), (0, h - g), (w - g, h - g)] {
            addCursorRect(NSRect(x: cx, y: cy, width: g, height: g), cursor: .crosshair)
        }
    }
}

// MARK: - Choosing the area

final class VeilSelectorPanel: NSPanel {
    let selectorView: VeilSelectorView

    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return false }

    init(screen: NSScreen) {
        selectorView = VeilSelectorView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = selectorView
        setFrame(screen.frame, display: false)
    }
}

final class VeilSelectorView: NSView {
    /// The chosen rectangle in screen coordinates, and whether ⇧ was held to keep going.
    var onPick: ((NSRect, Bool) -> Void)?
    var onCancel: (() -> Void)?

    private var start: NSPoint?
    private var current: NSPoint?
    fileprivate static let picture: NSImage? = Art.image("veil_selecting")

    override var acceptsFirstResponder: Bool { return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let s = start, let c = current else { return nil }
        return NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.28).setFill()
        bounds.fill()
        if let r = selection {
            NSGraphicsContext.current?.compositingOperation = .clear
            r.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let border = NSBezierPath(rect: r)
            border.lineWidth = 2
            NSColor.white.setStroke()
            border.stroke()
            let label = NSAttributedString(string: "\(Int(r.width)) × \(Int(r.height))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white])
            let size = label.size()
            let box = NSRect(x: r.minX, y: max(r.minY - size.height - 8, 4), width: size.width + 12, height: size.height + 4)
            NSColor(white: 0, alpha: 0.7).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 2))
        } else {
            let hint = NSAttributedString(string: "Drag over what you want to hide  ·  Esc to cancel  ·  hold ⇧ to cover several",
                attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white])
            let size = hint.size()
            let box = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 90, width: size.width + 28, height: size.height + 14)
            NSColor(white: 0, alpha: 0.7).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            hint.draw(at: NSPoint(x: box.minX + 14, y: box.minY + 7))
            if let pic = VeilSelectorView.picture {
                let h: CGFloat = 96
                let w = h * pic.size.width / max(1, pic.size.height)
                pic.draw(in: NSRect(x: bounds.midX - w / 2, y: box.minY - h - 8, width: w, height: h))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        defer { start = nil; current = nil; needsDisplay = true }
        guard let r = selection, r.width >= 16, r.height >= 16, let w = window else { return }
        let screenRect = w.convertToScreen(convert(r, to: nil))
        onPick?(screenRect, event.modifierFlags.contains(.shift))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

// MARK: - Matching the app's colours

/// Reads the pixels around a rectangle and builds a smooth patch in the same colours, so the
/// covered spot looks like blank space in that app (its theme, light or dark).
/// Reading the screen needs the Screen Recording permission.
@available(macOS 14.0, *)
enum ScreenMatch {
    private typealias C = (Float, Float, Float)

    static func fill(for rect: NSRect) async throws -> CGImage {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? NSScreen.screens.first(where: { $0.frame.intersects(rect) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw ConvertError.message("The veil is not on a screen.")
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ConvertError.message("Could not find that display.")
        }
        // Leave Moon Cat's own windows (the dimmer, the veils, the pet) out of the picture.
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = content.applications.filter { $0.processID == me }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width)
        config.height = Int(screen.frame.height)
        config.showsCursor = false
        let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try patch(from: shot, rect: rect, screenFrame: screen.frame)
    }

    private static func patch(from shot: CGImage, rect: NSRect, screenFrame: NSRect) throws -> CGImage {
        let W = shot.width, H = shot.height
        guard W > 4, H > 4, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let raw = ctx.data else {
            throw ConvertError.message("Could not read the screen picture.")
        }
        ctx.draw(shot, in: CGRect(x: 0, y: 0, width: W, height: H))
        let px = raw.bindMemory(to: UInt8.self, capacity: W * H * 4)

        // The veil's rectangle in picture pixels (top-left origin).
        let sx = CGFloat(W) / screenFrame.width, sy = CGFloat(H) / screenFrame.height
        var x0 = Int(((rect.minX - screenFrame.minX) * sx).rounded())
        var x1 = Int(((rect.maxX - screenFrame.minX) * sx).rounded())
        var y0 = Int(((screenFrame.maxY - rect.maxY) * sy).rounded())
        var y1 = Int(((screenFrame.maxY - rect.minY) * sy).rounded())
        x0 = max(0, min(W - 1, x0)); x1 = max(x0 + 1, min(W, x1))
        y0 = max(0, min(H - 1, y0)); y1 = max(y0 + 1, min(H, y1))
        let w = x1 - x0, h = y1 - y0

        func pixel(_ x: Int, _ y: Int) -> C {
            let i = (y * W + x) * 4
            return (Float(px[i]), Float(px[i + 1]), Float(px[i + 2]))
        }
        func median(_ v: [Float]) -> Float { return v.sorted()[v.count / 2] }
        func medianColor(_ list: [C]) -> C {
            return (median(list.map { $0.0 }), median(list.map { $0.1 }), median(list.map { $0.2 }))
        }
        func mix(_ a: C, _ b: C, _ t: Float) -> C {
            let k = 1 - t
            let r: Float = k * a.0 + t * b.0
            let g: Float = k * a.1 + t * b.1
            let bl: Float = k * a.2 + t * b.2
            return (r, g, bl)
        }
        /// Smooths a strip so a stray letter at the edge does not stain the patch.
        func smooth(_ p: [C], radius: Int) -> [C] {
            var out = p
            for i in 0..<p.count {
                out[i] = medianColor(Array(p[max(0, i - radius)...min(p.count - 1, i + radius)]))
            }
            return out
        }

        let band = 6, gap = 2
        // Strips of colour just outside each edge. nil when the rectangle touches the screen edge there.
        var top: [C]? = nil, bottom: [C]? = nil, left: [C]? = nil, right: [C]? = nil
        if y0 - gap >= 1 {
            let rows = Array(max(0, y0 - gap - band)..<(y0 - gap))
            top = smooth((0..<w).map { u in medianColor(rows.map { pixel(x0 + u, $0) }) }, radius: 8)
        }
        if y1 + gap < H {
            let rows = Array((y1 + gap)..<min(H, y1 + gap + band))
            bottom = smooth((0..<w).map { u in medianColor(rows.map { pixel(x0 + u, $0) }) }, radius: 8)
        }
        if x0 - gap >= 1 {
            let cols = Array(max(0, x0 - gap - band)..<(x0 - gap))
            left = smooth((0..<h).map { v in medianColor(cols.map { pixel($0, y0 + v) }) }, radius: 8)
        }
        if x1 + gap < W {
            let cols = Array((x1 + gap)..<min(W, x1 + gap + band))
            right = smooth((0..<h).map { v in medianColor(cols.map { pixel($0, y0 + v) }) }, radius: 8)
        }

        // Fallback when there is no border to copy from: the middle colour inside.
        var inside: C = (128, 128, 128)
        if top == nil && bottom == nil && left == nil && right == nil {
            var samples: [C] = []
            for yy in stride(from: y0, to: y1, by: max(1, h / 12)) {
                for xx in stride(from: x0, to: x1, by: max(1, w / 12)) { samples.append(pixel(xx, yy)) }
            }
            inside = medianColor(samples)
        }

        let ow = max(2, (w + 3) / 4), oh = max(2, (h + 3) / 4)
        var out = [UInt8](repeating: 255, count: ow * oh * 4)
        for j in 0..<oh {
            let v = (Float(j) + 0.5) / Float(oh)
            let iv = min(h - 1, Int(v * Float(h)))
            for i in 0..<ow {
                let u = (Float(i) + 0.5) / Float(ow)
                let iu = min(w - 1, Int(u * Float(w)))
                // Each edge pulls with a strength that falls off quickly with distance, so the patch
                // takes its colour from the nearest border instead of washing everything to one average.
                var r: Float = 0, g: Float = 0, bl: Float = 0, total: Float = 0
                func pull(_ col: C, _ dist: Int) {
                    let d = Float(dist + 1)
                    let k = 1 / (d * d)
                    r += col.0 * k; g += col.1 * k; bl += col.2 * k; total += k
                }
                if let e = left { pull(e[iv], iu) }
                if let e = right { pull(e[iv], w - 1 - iu) }
                if let e = top { pull(e[iu], iv) }
                if let e = bottom { pull(e[iu], h - 1 - iv) }
                let c: C = total > 0 ? (r / total, g / total, bl / total) : inside
                let o = (j * ow + i) * 4
                out[o] = UInt8(max(0, min(255, c.0.rounded())))
                out[o + 1] = UInt8(max(0, min(255, c.1.rounded())))
                out[o + 2] = UInt8(max(0, min(255, c.2.rounded())))
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let image = CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ow * 4,
                                  space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ConvertError.message("Could not build the veil.")
        }
        return image
    }
}

// MARK: - Moon Veil window: screen access and defaults

final class VeilAccessWindow: NSObject, NSWindowDelegate {
    static let shared = VeilAccessWindow()

    private let window: NSWindow
    private let dot = ThemeCard()
    private let statusArt = NSImageView()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let countLabel = NSTextField(labelWithString: "")
    private var activeObserver: NSObjectProtocol?
    private var mainStack: NSStackView?

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Moon Veil"
        Theme.style(window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func show() {
        refresh()
        activateApp()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func build() {
        guard let content = window.contentView else { return }
        let header = Theme.header(symbol: "eye.slash", title: "Moon Veil",
                                  subtitle: "Hide any part of your screen. Lift it any time.")

        // Screen access card
        dot.radius = 5
        dot.stroke = .clear
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        statusTitle.font = Theme.font(15, .semibold, rounded: true)
        let statusLeft = NSStackView(views: [dot, statusTitle])
        statusLeft.orientation = .horizontal
        statusLeft.alignment = .centerY
        statusLeft.spacing = 8
        statusArt.imageScaling = .scaleProportionallyUpOrDown
        statusArt.translatesAutoresizingMaskIntoConstraints = false
        statusArt.widthAnchor.constraint(equalToConstant: 84).isActive = true
        statusArt.heightAnchor.constraint(equalToConstant: 84).isActive = true
        let statusFlex = NSView()
        statusFlex.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [statusLeft, statusFlex, statusArt])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusDetail.font = Theme.font(12)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.preferredMaxLayoutWidth = 430

        let allow = button("Allow screen access", #selector(allowAccess))
        Theme.primary(allow)
        allow.controlSize = .regular
        let openBtn = button("Open System Settings", #selector(openSettings))
        let row1 = NSStackView(views: [allow, openBtn])
        row1.spacing = 8
        let row2 = NSStackView(views: [button("Check again", #selector(recheck)),
                                       button("Test capture", #selector(testCapture))])
        row2.spacing = 8
        let row3 = NSStackView(views: [button("Reset permission", #selector(resetPermission)),
                                       button("Restart Moon Cat", #selector(restartApp))])
        row3.spacing = 8
        note.font = Theme.font(12, .medium)
        note.textColor = Theme.accent
        note.preferredMaxLayoutWidth = 430
        note.isHidden = true

        let accessStack = NSStackView(views: [statusRow, statusDetail, row1, row2, row3, note])
        accessStack.orientation = .vertical
        accessStack.alignment = .leading
        accessStack.spacing = 12
        statusRow.widthAnchor.constraint(equalTo: accessStack.widthAnchor).isActive = true
        let accessCard = Theme.card(accessStack, padding: 18)

        // Looks card
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)
        for st in VeilStyle.allCases {
            stylePopup.addItem(withTitle: st.title)
            stylePopup.lastItem?.representedObject = st.rawValue
        }
        let styleLabel = Theme.sectionLabel("New veils start as")
        let styleRow = NSStackView(views: [styleLabel, stylePopup])
        styleRow.spacing = 10
        let shortcut = Theme.caption("Hide or show all veils at once: \(Veil.panicKeyText). Drag a veil to move it, drag any edge to resize it, double-click to lift it, right-click for more.")
        shortcut.preferredMaxLayoutWidth = 430
        countLabel.font = Theme.font(12, .medium)
        countLabel.textColor = .secondaryLabelColor
        let liftBtn = button("Lift all veils", #selector(liftAll))
        let flex = NSView()
        flex.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let liftRow = NSStackView(views: [countLabel, flex, liftBtn])
        liftRow.orientation = .horizontal
        liftRow.alignment = .centerY
        let looksStack = NSStackView(views: [styleRow, shortcut, liftRow])
        looksStack.orientation = .vertical
        looksStack.alignment = .leading
        looksStack.spacing = 12
        let looksCard = Theme.card(looksStack, padding: 18)

        let cover = button("Hide part of the screen…", #selector(startCover))
        Theme.primary(cover)
        cover.keyEquivalent = ""

        var parts: [NSView] = [header, accessCard, looksCard, cover]
        if let hero = Art.banner("veil_hero", width: 520 - 2 * Theme.pad, height: 140) { parts.insert(hero, at: 1) }
        let stack = NSStackView(views: parts)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.pad),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.pad),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            accessCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            looksCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            liftRow.widthAnchor.constraint(equalTo: looksStack.widthAnchor)
        ])
        mainStack = stack
        fitWindow()
    }

    /// Resizes the window to its content (the text changes as status messages appear).
    private func fitWindow() {
        guard let c = window.contentView, let st = mainStack else { return }
        c.layoutSubtreeIfNeeded()
        let chrome = window.frame.height - c.frame.height
        let newH = st.fittingSize.height + 8 + Theme.pad + chrome
        var f = window.frame
        f.origin.y += f.height - newH
        f.size = NSSize(width: f.width, height: newH)
        window.setFrame(f, display: true)
    }

    // MARK: State

    private func refresh() {
        let ok = CGPreflightScreenCaptureAccess()
        dot.fill = ok ? .systemGreen : .systemOrange
        statusArt.image = Art.image(ok ? "veil_access_on" : "veil_access_off")
        statusArt.isHidden = statusArt.image == nil
        statusTitle.stringValue = ok ? "Screen access is on" : "Screen access is off"
        statusDetail.stringValue = ok
            ? "“Adapt to app” can read the colours next to a veil. The other looks never need this."
            : "Only “Adapt to app” needs it. Frosted, Paper, Black and Solid colour work without it. To turn it on: press Allow, switch Moon Cat on in System Settings, then press Restart Moon Cat."
        if let i = VeilStyle.allCases.firstIndex(of: Veil.shared.defaultStyle) { stylePopup.selectItem(at: i) }
        let n = Veil.shared.count
        countLabel.stringValue = n == 0 ? "No veils on screen" : (n == 1 ? "1 veil on screen" : "\(n) veils on screen")
        fitWindow()
    }

    private func say(_ text: String) {
        note.stringValue = text
        note.isHidden = false
        fitWindow()
    }

    // MARK: Actions

    @objc private func allowAccess() {
        if CGPreflightScreenCaptureAccess() { refresh(); say("Already allowed."); return }
        _ = CGRequestScreenCaptureAccess()
        say("macOS will ask now. If nothing appears, press Open System Settings and switch Moon Cat on. Then press Restart Moon Cat.")
        refresh()
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func recheck() {
        refresh()
        say(CGPreflightScreenCaptureAccess() ? "Allowed for this copy of Moon Cat."
                                              : "Not allowed for this copy of Moon Cat. If you already switched it on, press Restart Moon Cat, or Reset permission if it still says off.")
    }

    @objc private func testCapture() {
        guard CGPreflightScreenCaptureAccess() else {
            say("Not allowed yet, so I did not try. Press Allow screen access first.")
            return
        }
        guard #available(macOS 14.0, *) else {
            say("Adaptive mode needs macOS 14 or later.")
            return
        }
        let r = (NSScreen.main ?? NSScreen.screens[0]).frame
        let rect = NSRect(x: r.midX - 60, y: r.midY - 60, width: 120, height: 120)
        say("Testing…")
        Task { @MainActor in
            do {
                _ = try await ScreenMatch.fill(for: rect)
                self.say("Test capture worked. Adaptive mode is ready.")
            } catch {
                let ns = error as NSError
                self.say("Test capture failed: \(ns.localizedDescription) [\(ns.domain) \(ns.code)]. Try Reset permission, then Allow and Restart.")
            }
        }
    }

    /// Clears Moon Cat's entry from the Screen Recording list. Fixes a permission that belongs to an older build.
    @objc private func resetPermission() {
        let id = Bundle.main.bundleIdentifier ?? "com.yash.mooncat"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", id]
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                say("Cleared Moon Cat from the Screen Recording list. Press Allow screen access, switch it on, then press Restart Moon Cat.")
            } else {
                say("macOS could not clear it (code \(p.terminationStatus)). Open System Settings, select Moon Cat in the list and press the minus button.")
            }
        } catch {
            say("Could not run the reset: \(error.localizedDescription). Open System Settings and remove Moon Cat from the list by hand.")
        }
        refresh()
    }

    @objc private func restartApp() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc private func styleChanged() {
        guard let raw = stylePopup.selectedItem?.representedObject as? String,
              let st = VeilStyle(rawValue: raw) else { return }
        if st == .blend && !CGPreflightScreenCaptureAccess() {
            say("“Adapt to app” needs screen access first. Press Allow screen access above.")
            refresh()
            return
        }
        Veil.shared.defaultStyle = st
        say("New veils will start as \(st.title).")
    }

    @objc private func liftAll() {
        Veil.shared.removeAll()
        refresh()
    }

    @objc private func startCover() {
        window.orderOut(nil)
        Veil.shared.startSelecting()
    }
}
