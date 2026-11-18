import Foundation
import OSLog
import SQLite3

// These decisions stay independent of AX and AppKit so failure boundaries can be tested.
enum IslandNotificationStyle: Equatable {
    case temporary, persistent

    init?(subrole: String) {
        switch subrole {
        case "AXNotificationCenterBanner": self = .temporary
        case "AXNotificationCenterAlert": self = .persistent
        default: return nil
        }
    }

    /// A grouped stack of banners or alerts (macOS 27 NotificationCenter has both subroles).
    init?(stackSubrole subrole: String) {
        switch subrole {
        case "AXNotificationCenterBannerStack": self = .temporary
        case "AXNotificationCenterAlertStack": self = .persistent
        default: return nil
        }
    }
}

enum IslandMovePolicy {
    static func originalPosition(position: CGPoint, prior: CGPoint?, desktopMinX: CGFloat,
                                 normalPosition: CGPoint) -> CGPoint {
        prior ?? (position.x < desktopMinX - 5000 ? normalPosition : position)
    }

    static func allowsRecovery(position: CGPoint?, desktopMinX: CGFloat,
                               notificationCount: Int, hasUnexpectedContent: Bool, complete: Bool) -> Bool {
        guard let position, position.x.isFinite, position.y.isFinite else { return false }
        return position.x < desktopMinX - 5000 && notificationCount > 0 && !hasUnexpectedContent && complete
    }

    static func allowsMove(enabled: Bool, trusted: Bool, hasNotch: Bool,
                           notificationCount: Int, hasUnexpectedContent: Bool, complete: Bool) -> Bool {
        enabled && trusted && hasNotch && notificationCount > 0 && !hasUnexpectedContent && complete
    }
}

struct IslandNotificationQueue<Item> {
    private(set) var current: Item?
    private(set) var waiting: [Item] = []

    mutating func append(_ item: Item) { waiting.append(item) }

    @discardableResult
    mutating func presentNext(blocked: Bool) -> Item? {
        guard !blocked, current == nil, !waiting.isEmpty else { return nil }
        let item = waiting.removeFirst()
        current = item
        return item
    }

    mutating func finish() { current = nil }

    /// Removes waiting items that match, returning them.
    @discardableResult
    mutating func removeWaiting(where shouldRemove: (Item) -> Bool) -> [Item] {
        let removed = waiting.filter(shouldRemove)
        waiting.removeAll(where: shouldRemove)
        return removed
    }
    mutating func removeAll() { current = nil; waiting.removeAll() }
}

struct IslandNotificationLifetime {
    private(set) var remaining: TimeInterval?
    private var paused = false
    private var lastUpdate: TimeInterval

    init(style: IslandNotificationStyle, now: TimeInterval) {
        remaining = style == .temporary ? 5 : nil
        lastUpdate = now
    }

    mutating func advance(to now: TimeInterval, paused: Bool) -> Bool {
        let elapsed = max(0, now - lastUpdate)
        lastUpdate = now
        let wasPaused = self.paused
        self.paused = paused
        guard let remaining else { return false }
        self.remaining = max(0, remaining - (wasPaused ? 0 : elapsed))
        return self.remaining == 0
    }
}


/// How an inline reply ended (Messages or Claude).
enum IslandReplyOutcome: Equatable, Sendable {
    case sent
    /// Messages: no conversation, or more than one, matches the banner title.
    case noConversation
    /// MacTools is not allowed to control Messages (Privacy & Security > Automation).
    case notAuthorized
    /// Claude: that chat already has unsent text in its message box.
    case claudeDraft
    /// Claude: more than one open chat has this title.
    case ambiguousChat
    case failed
}

/// Sends an inline reply through Messages' scripting interface, to the exact conversation found
/// in Messages' history (`IslandMessagesChat`). Nothing is ever matched by name.
enum IslandMessagesReply {
    /// The reply and the conversation travel as script arguments, never as script source.
    /// Every service's copy of one conversation (iMessage, SMS, RCS, any) has an id ending with the
    /// same identifier, and the ";+;" / ";-;" marker says group or one-to-one.
    private static let script = """
    on run argv
        set theText to item 1 of argv
        set theSuffix to ";" & (item 2 of argv)
        set theMarker to ";" & (item 3 of argv) & ";"
        tell application "Messages"
            -- Send to the chat itself (not "chat id ..."), preferring iMessage, then any, RCS, SMS.
            set chosenChat to missing value
            set chosenRank to 99
            repeat with c in (every chat)
                set chatID to (id of c) as text
                if chatID ends with theSuffix and chatID contains theMarker then
                    set rank to 5
                    if chatID starts with "iMessage;" then set rank to 1
                    if chatID starts with "any;" then set rank to 2
                    if chatID starts with "RCS;" then set rank to 3
                    if chatID starts with "SMS;" then set rank to 4
                    if rank < chosenRank then
                        set chosenRank to rank
                        set chosenChat to contents of c
                    end if
                end if
            end repeat
            if chosenChat is missing value then return "none"
            send theText to chosenChat
            return "sent"
        end tell
    end run
    """

    static func send(_ text: String, toChat chat: IslandMessagesChat.Conversation) async -> IslandReplyOutcome {
        let (status, output, errors) = await run([text, chat.identifier, chat.isGroup ? "+" : "-"])
        if status == 0 { return output == "sent" ? .sent : .noConversation }
        // The AppleScript error number only, never the reply text.
        let code = errors.range(of: #"\(-?\d+\)"#, options: .regularExpression).map { String(errors[$0]) } ?? "none"
        logger.notice("send failed status=\(status, privacy: .public) error=\(code, privacy: .public)")
        return errors.contains("-1743") ? .notAuthorized : .failed
    }

    private static let logger = Logger(subsystem: "MacTools.IslandNotifications", category: "messages")

    private static func run(_ arguments: [String]) async -> (Int32, String, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // "--" ends osascript's options, so a reply starting with "-" stays an argument.
            process.arguments = ["-e", script, "--"] + arguments
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.terminationHandler = { process in
                let out = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let err = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, out, err))
            }
            do { try process.run() } catch { continuation.resume(returning: (-1, "", "")); return }
            // Messages (or its first-use permission prompt) must not leave the card sending forever.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

/// Finds the exact Messages conversation a banner belongs to, from Messages' own history
/// (`~/Library/Messages/chat.db`, read-only; needs Full Disk Access for MacTools). The banner's
/// message text is matched against messages received in the last few minutes, and only a single
/// matching conversation counts. Nothing is stored and nothing but the conversation id leaves here.
enum IslandMessagesChat {
    struct Conversation: Equatable, Sendable {
        /// The part after the service: the person's number or address, or "chat123456789" for a group.
        let identifier: String
        let isGroup: Bool
        /// A group's id for Messages' open link.
        var groupID: String?

        /// Opens this conversation in Messages.
        var openURL: URL? {
            var components = URLComponents()
            if isGroup {
                guard let groupID else { return nil }
                components.scheme = "sms"
                components.host = "open"
                components.queryItems = [URLQueryItem(name: "groupid", value: groupID)]
            } else {
                components.scheme = identifier.contains("@") ? "imessage" : "sms"
                components.path = identifier
            }
            return components.url
        }
    }

    enum Lookup: Equatable, Sendable {
        case found(Conversation)
        /// No conversation, or more than one, matches.
        case notFound
        /// Messages' history can't be read (no Full Disk Access).
        case unavailable
    }

    private static let logger = Logger(subsystem: "MacTools.IslandNotifications", category: "messages")

    private static var databasePath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
    }

    /// True when Messages' history can be read (Full Disk Access granted).
    static var isAvailable: Bool {
        guard let db = open() else { return false }
        sqlite3_close(db)
        return true
    }

    private static func open() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 500)
        // Opening succeeds lazily; a query proves access.
        guard sqlite3_exec(db, "SELECT 1 FROM chat LIMIT 1", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    /// `bannerLines`: the banner's text lines after its title. A group banner (three lines) must lead
    /// to a group conversation and a one-to-one banner to a one-to-one conversation.
    static func resolve(bannerLines: [String], isGroupBanner: Bool) -> Lookup {
        guard let db = open() else { return .unavailable }
        defer { sqlite3_close(db) }
        let candidates = Set(bannerLines.map(normalized).filter { !$0.isEmpty })
        guard !candidates.isEmpty else { return .notFound }
        // Message dates are nanoseconds since 2001; look back five minutes.
        let since = Int64((Date().timeIntervalSinceReferenceDate - 300) * 1_000_000_000)
        let sql = """
        SELECT c.guid, m.text, m.attributedBody, c.group_id, m.message_summary_info FROM message m
        JOIN chat_message_join j ON j.message_id = m.ROWID
        JOIN chat c ON c.ROWID = j.chat_id
        WHERE m.is_from_me = 0 AND m.date > ?1
        ORDER BY m.date DESC LIMIT 200
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return .notFound }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, since)
        var rows = 0
        var chats = Set<String>()
        var groupIDs: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            rows += 1
            guard let guid = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
            var text = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            if text == nil, let blob = sqlite3_column_blob(statement, 2) {
                text = attributedBodyText(Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 2))))
            }
            // An edited message keeps its earlier versions; the banner shows the one that arrived.
            var versions = text.map { [$0] } ?? []
            if let blob = sqlite3_column_blob(statement, 4) {
                versions += editedVersions(Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 4))))
            }
            guard versions.contains(where: { matches(normalized($0), candidates) }) else { continue }
            chats.insert(guid)
            if let groupID = sqlite3_column_text(statement, 3).map({ String(cString: $0) }), !groupID.isEmpty {
                groupIDs[guid] = groupID
            }
        }
        // Copies of one conversation on different services share the identifier after the service.
        let conversations = Set(chats.compactMap(conversation(fromGUID:)).map { "\($0.isGroup ? "+" : "-");\($0.identifier)" })
        logger.notice("lookup rows=\(rows, privacy: .public) matchingChats=\(chats.count, privacy: .public) conversations=\(conversations.count, privacy: .public) groupBanner=\(isGroupBanner, privacy: .public)")
        guard conversations.count == 1, let guid = chats.first, var found = conversation(fromGUID: guid) else { return .notFound }
        found.groupID = chats.lazy.compactMap { groupIDs[$0] }.first
        guard found.isGroup == isGroupBanner else {
            logger.notice("lookup refused: banner and conversation kinds differ")
            return .notFound
        }
        return .found(found)
    }

    /// "iMessage;+;chat123" → group "chat123"; "any;-;+61400000000" → one-to-one "+61400000000".
    static func conversation(fromGUID guid: String) -> Conversation? {
        let parts = guid.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "+" || parts[1] == "-", !parts[2].isEmpty else { return nil }
        return Conversation(identifier: String(parts[2]), isGroup: parts[1] == "+")
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Banners can shorten long messages, so a long enough banner line may be a prefix.
    private static func matches(_ text: String, _ candidates: Set<String>) -> Bool {
        candidates.contains { $0 == text || ($0.count >= 12 && text.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "…")))) }
    }

    /// `message_summary_info` holds each version of an edited message under "ec": the message's
    /// part number, then a list of versions, each with its text archived like `attributedBody` ("t").
    static func editedVersions(_ data: Data) -> [String] {
        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let parts = info["ec"] as? [String: Any] else { return [] }
        return parts.values.flatMap { part -> [String] in
            ((part as? [[String: Any]]) ?? []).compactMap { ($0["t"] as? Data).flatMap(attributedBodyText) }
        }
    }

    /// Newer macOS stores some message text only in `attributedBody` (an archived NSAttributedString):
    /// the string follows the "NSString" class marker as a length-prefixed UTF-8 run.
    static func attributedBodyText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let marker = bytes.firstRange(of: Array("NSString".utf8)) else { return nil }
        var index = marker.upperBound
        while index < bytes.count, bytes[index] != 0x2B { index += 1 }   // "+" precedes the length
        index += 1
        guard index < bytes.count else { return nil }
        var length = Int(bytes[index]); index += 1
        if length == 0x81, index + 1 < bytes.count {
            length = Int(bytes[index]) | Int(bytes[index + 1]) << 8; index += 2
        } else if length == 0x82, index + 3 < bytes.count {
            length = Int(bytes[index]) | Int(bytes[index + 1]) << 8 | Int(bytes[index + 2]) << 16 | Int(bytes[index + 3]) << 24
            index += 4
        }
        guard length > 0, index + length <= bytes.count else { return nil }
        return String(bytes: bytes[index..<(index + length)], encoding: .utf8)
    }
}
