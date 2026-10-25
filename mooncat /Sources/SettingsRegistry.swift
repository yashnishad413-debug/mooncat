import Foundation

/// Settings that live outside Settings.swift (added by feature modules) register their
/// defaults here, and share one helper for saving a value and announcing the change.
extension Settings {
    /// Every default contributed by a feature module. Registered at launch and cleared by
    /// "Reset to defaults".
    static var moduleDefaults: [String: Any] {
        var all: [String: Any] = [:]
        for part in [pomodoroDefaults, systemDefaults, chatDefaults, cosmeticsDefaults, perchDefaults] {
            for (k, v) in part { all[k] = v }
        }
        return all
    }

    /// Save a value and post `Settings.didChange`.
    func storeExtra(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: Settings.didChange, object: self, userInfo: ["key": key])
    }
}
