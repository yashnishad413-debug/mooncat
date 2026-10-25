import Foundation
import UserNotifications

/// One place for notification permission and banners (used by reminders and the focus timer).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// True once we know the user has switched notifications off for MoonCat.
    private(set) var denied = false

    private var center: UNUserNotificationCenter { return UNUserNotificationCenter.current() }

    /// Call once at launch. Lets banners show even while MoonCat is the frontmost app.
    static func install() {
        shared.center.delegate = shared
        shared.refreshStatus()
    }

    func refreshStatus() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.denied = (settings.authorizationStatus == .denied)
            }
        }
    }

    /// Asks for permission the first time it is needed.
    func ensureAuthorized(_ done: ((Bool) -> Void)? = nil) {
        center.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            switch settings.authorizationStatus {
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    DispatchQueue.main.async {
                        self.denied = !granted
                        done?(granted)
                    }
                }
            case .denied:
                DispatchQueue.main.async {
                    self.denied = true
                    done?(false)
                }
            default:
                DispatchQueue.main.async {
                    self.denied = false
                    done?(true)
                }
            }
        }
    }

    /// Schedules (or replaces, if `id` already exists) a banner for `date`.
    func schedule(id: String, title: String, body: String, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request) { error in
            if let error = error { NSLog("MoonCat: could not schedule notification: \(error)") }
        }
    }

    /// Shows a banner about a second from now.
    func post(title: String, body: String) {
        schedule(id: "mooncat-" + UUID().uuidString, title: title, body: body, at: Date())
    }

    func cancel(id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
