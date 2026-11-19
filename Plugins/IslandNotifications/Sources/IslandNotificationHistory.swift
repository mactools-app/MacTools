import AppKit
import Combine
import MacToolsPluginKit

/// One notification the island showed, as the panel's Notifications list keeps it.
struct IslandHistoryEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    /// The name the list groups and labels by.
    let appName: String
    /// The app as Notification Centre's own rows name it ("Spark Desktop, <title>, <body>").
    let centerApp: String?
    let appURL: URL?
    let bundleIdentifier: String?
    let title: String
    let body: String
    /// A Claude chat turn: its row in Notification Centre is MacTools' notice (see `claudeRequestID`).
    let claudeChat: IslandClaudeChat?
    /// Banner text lines, for finding a Messages conversation if Notification Centre no longer has it.
    let lineCount: Int
    /// MacTools saw the banner arrive; without that its Messages conversation isn't looked up.
    var arrivalConfirmed = true
    /// A Claude entry: MacTools' own notice behind it, removed when the entry is opened or cleared.
    var claudeRequestID: String?

    var groupKey: String { bundleIdentifier ?? appName }

    /// A third banner line is a subtitle (a group conversation's name), drawn in the title's weight.
    var subtitle: String? {
        guard lineCount > 2, let first = body.components(separatedBy: "\n").first, !first.isEmpty else { return nil }
        return first
    }

    var message: String {
        guard let subtitle else { return body }
        return String(body.dropFirst(subtitle.count)).trimmingCharacters(in: .newlines)
    }
}

/// The notifications the island has shown since MacTools started, newest first, as Notification
/// Centre lists them. Kept in memory only: Notification Centre stays the record, this list only
/// mirrors what passed through the island so the panel can show it.
@MainActor
final class IslandNotificationHistory: ObservableObject {
    @Published private(set) var entries: [IslandHistoryEntry] = []
    static let limit = 64

    func add(_ entry: IslandHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    func remove(_ entry: IslandHistoryEntry) { entries.removeAll { $0.id == entry.id } }
    func removeGroup(_ key: String) { entries.removeAll { $0.groupKey == key } }
    func removeAll() { entries.removeAll() }

    struct Group: Identifiable, Equatable {
        let id: String
        let entries: [IslandHistoryEntry]
        var newest: IslandHistoryEntry { entries[0] }
    }

    /// Notification Centre's automatic grouping: one stack per app, ordered by each app's newest.
    static func groups(_ entries: [IslandHistoryEntry]) -> [Group] {
        var order: [String] = []
        var byApp: [String: [IslandHistoryEntry]] = [:]
        for entry in entries {
            if byApp[entry.groupKey] == nil { order.append(entry.groupKey) }
            byApp[entry.groupKey, default: []].append(entry)
        }
        return order.map { Group(id: $0, entries: byApp[$0] ?? []) }
    }
}

/// Matches the panel's entries to Notification Centre's rows. A row reads "<App>, <title>, <body>".
enum IslandCenterMatch {
    static func normalized(_ text: String) -> String {
        text.unicodeScalars.filter { $0 != "\u{200E}" && $0 != "\u{200F}" }.map(String.init).joined()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The row is this notification: it starts with the app, then has the title and then all of its
    /// text. The marks between the parts depend on the language (", " "、" "，" "،"). Text either
    /// side shortened with "…" may stop early, but must agree for at least 12 characters.
    static func row(_ description: String, matchesApp app: String, title: String, body: String) -> Bool {
        let row = normalized(description)
        let title = normalized(title)
        // The title is the whole next part: it starts right after the app and ends at a mark.
        guard let rest = afterApp(row, app: app), rest.hasPrefix(title) else { return false }
        let afterTitle = rest.dropFirst(title.count)
        guard afterTitle.isEmpty || isMark(afterTitle) else { return false }
        let wanted = normalized(body), shown = String(afterTitle)
        let want = compact(wanted), have = compact(shown)
        if want == have { return true }
        if wanted.hasSuffix("…"), want.count >= 12, have.hasPrefix(want) { return true }
        if shown.hasSuffix("…"), have.count >= 12, want.hasPrefix(have) { return true }
        return false
    }

    /// The text alone: without spaces, line breaks, the list marks between parts (a subtitle is its
    /// own part in a row but its own line on a banner) and a closing "…".
    private static func compact(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !IslandNotification.descriptionSeparators.contains($0)
        }.map(Character.init)).trimmingCharacters(in: CharacterSet(charactersIn: "…"))
    }

    /// A collapsed stack of this app's notifications; only its newest shows in the description.
    static func stack(_ description: String, isApp app: String) -> Bool {
        afterApp(normalized(description), app: app) != nil
    }

    /// What follows the app's name and the mark after it, when the description starts with the app.
    private static func afterApp(_ row: String, app: String) -> Substring? {
        let app = normalized(app)
        guard !app.isEmpty, row.hasPrefix(app) else { return nil }
        let rest = row.dropFirst(app.count)
        guard isMark(rest) else { return nil }
        return rest.drop { $0.unicodeScalars.allSatisfy(IslandNotification.descriptionSeparators.contains) }
    }

    /// Text that starts with a list mark (", " "、" "，" "،"), not just a space inside a name.
    private static func isMark(_ text: Substring) -> Bool {
        text.trimmingPrefix(while: { $0 == " " }).first.map { ",、，،".contains($0) } ?? false
    }
}

/// How Notification Centre writes a notification's time: "now", "53m ago", "10:29 am",
/// "Yesterday, 10:04 pm", then the date.
enum IslandHistoryTime {
    static func text(for date: Date, now: Date, localization: PluginLocalization) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return localization.string("history.now", defaultValue: "现在") }
        if elapsed < 3600 {
            let minutes = Duration.seconds(Int(elapsed / 60) * 60)
                .formatted(.units(allowed: [.minutes], width: .narrow))
            return String(format: localization.string("history.ago", defaultValue: "%@前"), minutes)
        }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = PluginRuntimeLocalization.locale
        return formatter.string(from: date)
    }
}
