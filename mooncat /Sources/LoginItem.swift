import Foundation
import ServiceManagement

/// Launch-at-login, via SMAppService (macOS 13+).
enum LoginItem {
    static let didChange = Notification.Name("MoonCatLoginItemDidChange")

    static var status: SMAppService.Status {
        return SMAppService.mainApp.status
    }

    /// True when the system will actually launch her at login.
    static var isEnabled: Bool {
        return status == .enabled
    }

    /// True when the user toggled it on but still has to approve it in System Settings.
    static var needsApproval: Bool {
        return status == .requiresApproval
    }

    /// Short human-readable status for the Preferences window.
    static var statusText: String {
        switch status {
        case .enabled: return "She will start when you log in."
        case .requiresApproval: return "Approve MoonCat in System Settings → General → Login Items."
        case .notRegistered: return "She will not start automatically."
        case .notFound: return "macOS could not find the app. Move MoonCat.app to /Applications and try again."
        @unknown default: return "Unknown status."
        }
    }

    @discardableResult
    static func set(_ on: Bool) -> Result<Void, Error> {
        let service = SMAppService.mainApp
        do {
            if on {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status != .notRegistered { try service.unregister() }
            }
            NotificationCenter.default.post(name: didChange, object: nil)
            return .success(())
        } catch {
            NotificationCenter.default.post(name: didChange, object: nil)
            return .failure(error)
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
