import AppKit
import Foundation
import UserNotifications

@MainActor
final class LocalNotificationService {
    private let center = UNUserNotificationCenter.current()
    private let delegate = NotificationCenterDelegate()

    init() {
        center.delegate = delegate
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func deliver(_ item: AttentionItem) async {
        guard item.isVerifiedDirectMention, item.isUnseen, NotificationPreferences.directMentionsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "You were mentioned"
        content.subtitle = item.repository
        content.body = item.title
        content.userInfo = ["url": item.url.absoluteString]
        content.threadIdentifier = item.repository
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        NSApplication.shared.requestUserAttention(.criticalRequest)
        try? await center.add(UNNotificationRequest(identifier: item.notificationID, content: content, trigger: nil))
    }

    func remove(id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func removeAll() {
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

}

private final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.content.sound == nil ? [.banner] : [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let value = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: value) else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }
}

enum NotificationPreferences {
    static var directMentionsEnabled: Bool {
        let key = "notification.mention.enabled"
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }
}
