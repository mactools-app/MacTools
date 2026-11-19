import AppKit
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

    /// What the notification carries: banners hold at most 1,024 characters; the card shows the whole reply.
    static func postedText(_ turn: IslandClaudeTurnWatcher.Turn) -> String {
        String(turn.message.prefix(1_000))
    }

    /// Posts the notice; true once macOS accepted the request. Without permission nothing is posted.
    static func post(_ turn: IslandClaudeTurnWatcher.Turn, requestID: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return false
        }
        let content = UNMutableNotificationContent()
        content.title = turn.chat.title
        content.body = postedText(turn)
        content.threadIdentifier = "claude." + turn.chat.localID
        do {
            try await center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    /// True while Notification Centre holds this request: macOS delivered it.
    static func isDelivered(_ requestID: String) async -> Bool {
        await UNUserNotificationCenter.current().deliveredNotifications().contains { $0.request.identifier == requestID }
    }

    /// MacTools' names as a banner shows them: the bundle's display name, falling back to its name.
    static var ownNames: Set<String> {
        let info = Bundle.main.localizedInfoDictionary ?? [:]
        let plain = Bundle.main.infoDictionary ?? [:]
        let names = ["CFBundleDisplayName", "CFBundleName"].flatMap { [info[$0], plain[$0]] }.compactMap { $0 as? String }
        return Set((names + [NSRunningApplication.current.localizedName].compactMap { $0 }).filter { !$0.isEmpty })
    }
}
