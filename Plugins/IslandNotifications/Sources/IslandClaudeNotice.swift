import Foundation
import UserNotifications

/// MacTools' own notice of a finished Claude turn. Claude's notices arrive without a banner, so
/// this one is what the island shows; posting it puts the turn under MacTools' notification
/// settings, Focus and preview privacy, and in Notification Centre's history, like any app's.
enum IslandClaudeNotice {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
    }

    static func post(_ turn: IslandClaudeTurnWatcher.Turn) {
        let title = turn.chat.title
        // Banners carry at most 1,024 characters; the card shows the whole reply.
        let body = String(turn.message.prefix(1_000))
        let thread = "claude." + turn.chat.localID
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: break
            default: return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.threadIdentifier = thread
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                         content: content, trigger: nil))
        }
    }
}
