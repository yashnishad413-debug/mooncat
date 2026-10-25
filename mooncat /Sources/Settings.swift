import AppKit

/// Every tunable number in MoonCat lives here, backed by UserDefaults.
/// Changing any value posts `Settings.didChange` so the cat and the
/// Preferences window can update live.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("MoonCatSettingsDidChange")

    private let d = UserDefaults.standard

    // MARK: Defaults (single source of truth for "Reset to defaults")

    /// Global shortcut default: Option+Command+Space (Carbon key code 49, optionKey 2048 + cmdKey 256).
    static let defaultHotKeyCode = 49
    static let defaultHotKeyModifiers = 2304

    private static let defaultValues: [String: Any] = [
        "scale": 1.0,
        "follow": true,
        "followDistance": 260.0,        // idle -> start walking when cursor is farther than this (x size)
        "followDistanceDrag": 200.0,    // same, while you are dragging files
        "stopDistance": 150.0,          // stop walking when this close (x size)
        "stopDistanceDrag": 90.0,
        "sleepDelay": 75.0,             // seconds without cursor movement before she naps
        "playFrequency": 1.0,           // 0 = never pounce, 1 = normal, 2 = twice as often
        "playIntervalMin": 14.0,        // seconds between pounces at frequency 1
        "playIntervalMax": 30.0,
        "firstPlayDelay": 15.0,
        "playAfterWalkDelay": 8.0,
        "playAfterDragDelay": 10.0,
        "pounceRangeX": 240.0,
        "pounceRangeY": 60.0,
        "pounceMinDistance": 80.0,
        "pounceDuration": 0.8,
        "pounceHeight": 60.0,
        "walkSpeedMin": 150.0,
        "walkSpeedMax": 700.0,
        "walkSpeedFactor": 1.1,
        "wakeDistance": 220.0,          // cursor this close (and moving) wakes her
        "wakeActiveTime": 6.0,          // seconds of cursor activity that wake her
        "curiousHoverDelay": 0.9,       // hover this long over her -> curious
        "happyDuration": 1.5,
        "heartInterval": 0.3,
        "tickInterval": 1.0 / 60.0,
        "screenID": 0,                  // 0 = automatic (any screen)
        "soundsEnabled": true,
        "soundVolume": 0.7,
        "hotKeyCode": Settings.defaultHotKeyCode,
        "hotKeyModifiers": Settings.defaultHotKeyModifiers,
        "autoForgetEnabled": false,
        "autoForgetDays": 90
    ]

    init() {
        d.register(defaults: Settings.defaultValues)
        d.register(defaults: Settings.moduleDefaults)
    }

    // MARK: Helpers

    private func double(_ k: String) -> Double { return d.double(forKey: k) }

    private func setValue(_ v: Any, _ k: String) {
        d.set(v, forKey: k)
        NotificationCenter.default.post(name: Settings.didChange, object: self, userInfo: ["key": k])
    }

    func resetToDefaults() {
        for k in Settings.defaultValues.keys { d.removeObject(forKey: k) }
        for k in Settings.moduleDefaults.keys { d.removeObject(forKey: k) }
        NotificationCenter.default.post(name: Settings.didChange, object: self, userInfo: ["key": "*"])
    }

    // MARK: Size and following

    var scale: Double {
        get { return min(max(double("scale"), 0.4), 2.5) }
        set { setValue(newValue, "scale") }
    }
    var follow: Bool {
        get { return d.bool(forKey: "follow") }
        set { setValue(newValue, "follow") }
    }
    var followDistance: Double {
        get { return double("followDistance") }
        set { setValue(newValue, "followDistance") }
    }
    var followDistanceDrag: Double {
        get { return double("followDistanceDrag") }
        set { setValue(newValue, "followDistanceDrag") }
    }
    var stopDistance: Double {
        get { return double("stopDistance") }
        set { setValue(newValue, "stopDistance") }
    }
    var stopDistanceDrag: Double {
        get { return double("stopDistanceDrag") }
        set { setValue(newValue, "stopDistanceDrag") }
    }

    // MARK: Sleep and play

    var sleepDelay: Double {
        get { return max(double("sleepDelay"), 5) }
        set { setValue(newValue, "sleepDelay") }
    }
    var playFrequency: Double {
        get { return max(double("playFrequency"), 0) }
        set { setValue(newValue, "playFrequency") }
    }
    var playIntervalMin: Double { return double("playIntervalMin") }
    var playIntervalMax: Double { return double("playIntervalMax") }
    var firstPlayDelay: Double { return double("firstPlayDelay") }
    var playAfterWalkDelay: Double { return double("playAfterWalkDelay") }
    var playAfterDragDelay: Double { return double("playAfterDragDelay") }
    var pounceRangeX: Double { return double("pounceRangeX") }
    var pounceRangeY: Double { return double("pounceRangeY") }
    var pounceMinDistance: Double { return double("pounceMinDistance") }
    var pounceDuration: Double { return double("pounceDuration") }
    var pounceHeight: Double { return double("pounceHeight") }

    /// Seconds until the next pounce, scaled by the play-frequency setting.
    /// Returns a huge value when play is switched off.
    func randomPlayInterval() -> Double {
        let f = playFrequency
        if f <= 0.001 { return 1_000_000 }
        let lo = min(playIntervalMin, playIntervalMax)
        let hi = max(playIntervalMin, playIntervalMax)
        return Double.random(in: lo...hi) / (f * MoodCenter.shared.playFrequencyMultiplier)
    }

    // MARK: Walking, waking, reacting

    var walkSpeedMin: Double { return double("walkSpeedMin") }
    var walkSpeedMax: Double { return double("walkSpeedMax") }
    var walkSpeedFactor: Double { return double("walkSpeedFactor") }
    var wakeDistance: Double { return double("wakeDistance") }
    var wakeActiveTime: Double { return double("wakeActiveTime") }
    var curiousHoverDelay: Double { return double("curiousHoverDelay") }
    var happyDuration: Double { return double("happyDuration") }
    var heartInterval: Double { return double("heartInterval") }
    var tickInterval: Double { return max(double("tickInterval"), 1.0 / 120.0) }

    // MARK: Screen

    /// CGDirectDisplayID of the screen she lives on, or 0 for "any screen".
    var screenID: Int {
        get { return d.integer(forKey: "screenID") }
        set { setValue(newValue, "screenID") }
    }

    /// The preferred NSScreen, or nil when set to automatic or the display is gone.
    func preferredScreen() -> NSScreen? {
        let id = screenID
        if id == 0 { return nil }
        return NSScreen.screens.first { Settings.displayID(of: $0) == id }
    }

    static func displayID(of screen: NSScreen) -> Int {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.intValue ?? 0
    }

    // MARK: Sounds (used from the Sounds step onward)

    var soundsEnabled: Bool {
        get { return d.bool(forKey: "soundsEnabled") }
        set { setValue(newValue, "soundsEnabled") }
    }
    var soundVolume: Double {
        get { return min(max(double("soundVolume"), 0), 1) }
        set { setValue(newValue, "soundVolume") }
    }

    // MARK: Global shortcut (Quick Search)

    /// Carbon virtual key code of the global shortcut.
    var hotKeyCode: Int { return d.integer(forKey: "hotKeyCode") }

    /// Carbon modifier mask (cmdKey, shiftKey, optionKey, controlKey) of the global shortcut.
    var hotKeyModifiers: Int { return d.integer(forKey: "hotKeyModifiers") }

    /// Both halves are written together so observers never see a half-changed shortcut.
    func setHotKey(code: Int, modifiers: Int) {
        d.set(code, forKey: "hotKeyCode")
        d.set(modifiers, forKey: "hotKeyModifiers")
        NotificationCenter.default.post(name: Settings.didChange, object: self, userInfo: ["key": "hotKey"])
    }

    // MARK: Auto-forget (Treasure Box)

    var autoForgetEnabled: Bool {
        get { return d.bool(forKey: "autoForgetEnabled") }
        set { setValue(newValue, "autoForgetEnabled") }
    }
    var autoForgetDays: Int {
        get { return min(max(d.integer(forKey: "autoForgetDays"), 1), 3650) }
        set { setValue(newValue, "autoForgetDays") }
    }
    /// When the daily auto-forget check last ran (seconds since 1970). Bookkeeping only, so it
    /// is written without posting `didChange` and is not touched by "Reset to defaults".
    var autoForgetLastCheck: Double {
        get { return d.double(forKey: "autoForgetLastCheck") }
        set { d.set(newValue, forKey: "autoForgetLastCheck") }
    }
}
