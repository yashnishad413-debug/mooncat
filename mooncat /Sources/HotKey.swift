import AppKit
import Carbon.HIToolbox

/// One global keyboard shortcut, registered with Carbon's RegisterEventHotKey.
/// This needs no Accessibility permission and no event tap. The binding (key code and
/// Carbon modifier mask) lives in `Settings`; the shortcut is re-registered whenever it changes.
final class HotKey {
    static let shared = HotKey()
    /// Posted whenever `status` changes, so Preferences can show the current state.
    static let statusDidChange = Notification.Name("MoonCatHotKeyStatusDidChange")

    enum Status: Equatable {
        case unregistered
        case registered
        case taken                 // another app or macOS already owns this combination
        case failed(OSStatus)
    }

    enum Outcome {
        case ok
        case taken
        case failed(OSStatus)
    }

    private(set) var status: Status = .unregistered
    var isRegistered: Bool { return status == .registered }

    /// Called on the main thread when the shortcut is pressed.
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    // The last binding we tried to register (successfully or not), so unrelated
    // Settings changes do not trigger a pointless re-registration.
    private var attemptedCode = -1
    private var attemptedMods = -1

    private static let signature: OSType = 0x4D434154      // "MCAT"
    private static let hotKeyIDValue: UInt32 = 1
    private static let okStatus: OSStatus = 0
    private static let notHandledStatus: OSStatus = -9874  // eventNotHandledErr
    private static let existsStatus: OSStatus = -9878      // eventHotKeyExistsErr

    private init() {
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let s = Settings.shared
            if s.hotKeyCode != self.attemptedCode || s.hotKeyModifiers != self.attemptedMods {
                self.register()
            }
        }
    }

    // MARK: Register / unregister

    /// (Re)registers the binding stored in Settings. Safe to call repeatedly.
    @discardableResult
    func register() -> Bool {
        releaseKey()
        let s = Settings.shared
        let code = s.hotKeyCode
        let mods = s.hotKeyModifiers
        attemptedCode = code
        attemptedMods = mods
        let st = attempt(code: code, mods: mods)
        setStatus(HotKey.statusFor(st))
        return st == HotKey.okStatus
    }

    func unregister() {
        releaseKey()
        setStatus(.unregistered)
    }

    /// Tries a new binding. On success it is saved to Settings. On failure the previous
    /// binding is put back, so a refused combination never leaves the user with no shortcut.
    func rebind(keyCode: Int, modifiers: Int) -> Outcome {
        let s = Settings.shared
        let oldCode = s.hotKeyCode
        let oldMods = s.hotKeyModifiers
        releaseKey()

        let st = attempt(code: keyCode, mods: modifiers)
        if st == HotKey.okStatus {
            attemptedCode = keyCode
            attemptedMods = modifiers
            s.setHotKey(code: keyCode, modifiers: modifiers)
            setStatus(.registered)
            return .ok
        }

        attemptedCode = oldCode
        attemptedMods = oldMods
        let back = attempt(code: oldCode, mods: oldMods)
        setStatus(HotKey.statusFor(back))
        return st == HotKey.existsStatus ? .taken : .failed(st)
    }

    private func releaseKey() {
        if let ref = hotKeyRef {
            _ = UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func attempt(code: Int, mods: Int) -> OSStatus {
        guard code >= 0, mods >= 0 else { return -9879 }     // eventHotKeyInvalidErr
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: HotKey.signature, id: HotKey.hotKeyIDValue)
        let st = RegisterEventHotKey(UInt32(code), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref)
        if st == HotKey.okStatus { hotKeyRef = ref }
        return st
    }

    private static func statusFor(_ st: OSStatus) -> Status {
        if st == okStatus { return .registered }
        if st == existsStatus { return .taken }
        return .failed(st)
    }

    private func setStatus(_ new: Status) {
        status = new
        NotificationCenter.default.post(name: HotKey.statusDidChange, object: self)
    }

    private func installHandlerIfNeeded() {
        if handlerRef != nil { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let st = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event = event, let userData = userData else { return HotKey.notHandledStatus }
            var id = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &id)
            if err == HotKey.okStatus && id.signature == HotKey.signature && id.id == HotKey.hotKeyIDValue {
                let owner = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { owner.onTrigger?() }
                return HotKey.okStatus
            }
            return HotKey.notHandledStatus
        }, 1, &spec, me, &handlerRef)
        if st != HotKey.okStatus { handlerRef = nil }
    }

    // MARK: Text for the UI

    /// e.g. "⌥⌘Space" for the binding currently stored in Settings.
    var displayString: String {
        let s = Settings.shared
        return HotKey.displayString(keyCode: s.hotKeyCode, modifiers: s.hotKeyModifiers)
    }

    static func displayString(keyCode: Int, modifiers: Int) -> String {
        var out = ""
        if modifiers & controlKey != 0 { out += "⌃" }
        if modifiers & optionKey != 0 { out += "⌥" }
        if modifiers & shiftKey != 0 { out += "⇧" }
        if modifiers & cmdKey != 0 { out += "⌘" }
        return out + keyName(keyCode)
    }

    /// Converts AppKit modifier flags to the Carbon mask RegisterEventHotKey wants.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return m
    }

    // Names for a US keyboard layout. Unknown codes fall back to "Key N".
    private static let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`",
        51: "Delete", 53: "Esc",
        64: "F17", 65: "Num .", 67: "Num *", 69: "Num +", 71: "Num Clear", 75: "Num /",
        76: "Enter", 78: "Num -", 79: "F18", 80: "F19", 81: "Num =",
        82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4", 87: "Num 5",
        88: "Num 6", 89: "Num 7", 90: "F20", 91: "Num 8", 92: "Num 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4",
        119: "End", 120: "F2", 121: "Page Down", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    static func keyName(_ code: Int) -> String {
        return keyNames[code] ?? "Key \(code)"
    }
}
