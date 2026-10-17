import AppKit
import RunningManCore
import UserNotifications

enum NotificationAuthorization: Equatable {
    /// No app bundle, demo mode or a snapshot capture: notifications are never posted.
    case unavailable
    case notDetermined, denied, authorized
}

private let runnerIDKey = "runnerID"

/// Delivers planned notifications through the user notification center.
/// UNUserNotificationCenter traps in a process without an app bundle (`swift run`, tests),
/// so an inactive notifier never touches it.
@MainActor final class Notifier: NSObject {
    /// Called with a runner ID when the user clicks one of RunningMan's notifications.
    var openRunner: ((String) -> Void)?
    private let center: UNUserNotificationCenter?

    init(isActive: Bool) {
        center = isActive && Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
        super.init()
        // Set before launch finishes so a click that launches the app is delivered here.
        center?.delegate = self
    }

    var isActive: Bool { center != nil }

    func authorization() async -> NotificationAuthorization {
        guard let center else { return .unavailable }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .authorized
        }
    }

    /// Asks macOS only while the user has not decided yet; otherwise reports the current state.
    func requestAuthorization() async -> NotificationAuthorization {
        guard let center else { return .unavailable }
        let current = await authorization()
        guard current == .notDetermined else { return current }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorization()
    }

    func post(_ notifications: [PlannedNotification]) {
        guard let center else { return }
        for planned in notifications {
            let content = UNMutableNotificationContent()
            content.title = planned.title
            content.body = planned.body
            content.threadIdentifier = planned.runnerID
            content.userInfo = [runnerIDKey: planned.runnerID]
            if planned.kind != .jobSucceeded { content.sound = .default }
            center.add(UNNotificationRequest(identifier: planned.id, content: content, trigger: nil))
        }
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Shows banners while RunningMan is frontmost too; the open window may show another section.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let runnerID = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? response.notification.request.content.userInfo[runnerIDKey] as? String : nil
        Task { @MainActor in
            if let runnerID { self.openRunner?(runnerID) }
            completionHandler()
        }
    }
}
