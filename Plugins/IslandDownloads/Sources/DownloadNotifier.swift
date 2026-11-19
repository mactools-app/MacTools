import Foundation
import UserNotifications

/// Vorssaint's "Download complete" notice, posted as a real notification: the island shows it as
/// a card, and it stays in Notification Center's history like any other.
enum DownloadNotifier {
    /// The host reveals this file in Finder when the notification is clicked.
    static let revealFileKey = "MacTools.revealFileURL"

    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func post(_ item: NotchDownloadItem) {
        let text = NotchDownloadStrings.current
        let title = text.completed
        let body = item.name
        let path = item.url.path
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: break
            default: return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = "island-downloads"
            content.userInfo = [revealFileKey: path]
            let request = UNNotificationRequest(identifier: "island-downloads-\(path)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
