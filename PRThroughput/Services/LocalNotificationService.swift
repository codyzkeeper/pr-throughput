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

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert])
    }

    func authorizationStatusDescription() async -> String {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: "Not requested"
        case .denied: "Denied — feed and menu-bar dot remain active"
        case .authorized: "Allowed"
        case .provisional: "Provisionally allowed"
        case .ephemeral: "Allowed for this session"
        @unknown default: "Unknown"
        }
    }

    @discardableResult
    func deliver(_ item: AttentionItem, accountID: String) async -> Bool {
        guard item.kind == .actionLabels, item.isUnseen,
              let application = item.highestPriorityUndeliveredApplication,
              let pullRequestID = item.pullRequestID else { return false }
        let content = UNMutableNotificationContent()
        content.title = application.labelName
        content.subtitle = item.repository
        content.body = item.title
        content.userInfo = ["url": item.url.absoluteString]
        content.threadIdentifier = item.repository
        content.sound = nil
        content.interruptionLevel = .passive
        do {
            try await center.add(UNNotificationRequest(
                identifier: ActionNotificationIdentifier.value(accountID: accountID, pullRequestID: pullRequestID),
                content: content,
                trigger: nil
            ))
            return true
        } catch {
            return false
        }
    }

    // Retained, but intentionally unused. Loud mention behavior requires a future
    // product decision and the GitHub notifications OAuth scope before reactivation.
    func deliverLegacyLoudMention(_ item: AttentionItem) async {
        guard item.isVerifiedDirectMention, item.isUnseen else { return }
        let content = UNMutableNotificationContent()
        content.title = "You were mentioned"
        content.subtitle = item.repository
        content.body = item.title
        content.userInfo = ["url": item.url.absoluteString]
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
