import AppKit
import Foundation
import SwiftUI

enum BitwardenItemKind: Int, CaseIterable, Identifiable {
    case login = 1, note, card, identity, sshKey

    var id: Int { rawValue }
    var key: String { ["login", "secureNote", "card", "identity", "sshKey"][rawValue - 1] }
    var titleKey: String { "kind.\(key)" }
    var icon: String { ["key", "note.text", "creditcard", "person.text.rectangle", "terminal"][rawValue - 1] }

    var fields: [String] {
        switch self {
        case .login: ["username", "password", "totp"]
        case .note: []
        case .card: ["cardholderName", "brand", "number", "expMonth", "expYear", "code"]
        case .identity: ["title", "firstName", "middleName", "lastName", "username", "company", "ssn", "passportNumber", "licenseNumber", "email", "phone", "address1", "address2", "address3", "city", "state", "postalCode", "country"]
        case .sshKey: ["publicKey", "privateKey", "keyFingerprint"]
        }
    }

    static let secretFields: Set<String> = ["password", "totp", "number", "code", "ssn", "passportNumber", "licenseNumber", "privateKey"]
}

struct BitwardenItem: Identifiable, Decodable {
    struct LoginSummary: Decodable {
        struct Website: Decodable { let uri: String? }
        let username: String?
        let uris: [Website]?
    }

    let id: String
    let name: String
    let type: Int
    let folderId: String?
    let organizationId: String?
    let collectionIds: [String]?
    let favorite: Bool?
    let reprompt: Int?
    let login: LoginSummary?
    var kind: BitwardenItemKind? { BitwardenItemKind(rawValue: type) }

    func matches(_ query: String) -> Bool {
        if query.isEmpty || name.localizedStandardContains(query) { return true }
        guard (reprompt ?? 0) == 0 else { return false }
        return login?.username?.localizedStandardContains(query) == true
            || login?.uris?.contains { $0.uri?.localizedStandardContains(query) == true } == true
    }
}

struct BitwardenGroup: Identifiable, Decodable {
    let id: String
    let name: String
}

struct BitwardenDraft: Identifiable {
    struct CustomField: Identifiable {
        enum Kind: Int, CaseIterable { case text, hidden, boolean, linked }

        let id = UUID()
        var name: String
        var value: String
        var kind: Kind
        private let original: [String: Any]

        init(record: [String: Any] = [:]) {
            original = record
            name = record["name"] as? String ?? ""
            value = record["value"] as? String ?? ""
            kind = (record["type"] as? Int).flatMap(Kind.init(rawValue:)) ?? .text
        }

        var isEditable: Bool {
            if original.isEmpty { return true }
            guard let type = original["type"] as? Int, let kind = Kind(rawValue: type) else { return false }
            return kind != .linked
        }

        var record: [String: Any] {
            guard isEditable else { return original }
            var record = original
            record["name"] = name
            record["value"] = kind == .boolean ? (value == "true" ? "true" : "false") : value
            record["type"] = kind.rawValue
            return record
        }
    }

    let id = UUID()
    let itemID: String?
    var original: [String: Any] = [:]
    var kind: BitwardenItemKind = .login
    var name = ""
    var notes = ""
    var folder = ""
    var favorite = false
    var fields: [String: String] = [:]
    var urls = ""
    var customFields: [CustomField] = []

    init() { itemID = nil }

    init(itemID: String, data: Data) throws {
        guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = record["type"] as? Int, let kind = BitwardenItemKind(rawValue: type),
              record["id"] as? String == itemID, record["reprompt"] as? Int == 0 || record["reprompt"] == nil
        else { throw BitwardenCLI.Failure.invalidResponse }
        self.itemID = itemID
        self.original = record
        self.kind = kind
        name = record["name"] as? String ?? ""
        notes = record["notes"] as? String ?? ""
        folder = record["folderId"] as? String ?? ""
        favorite = record["favorite"] as? Bool ?? false
        customFields = (record["fields"] as? [[String: Any]] ?? []).map(CustomField.init(record:))
        let details = record[kind.key] as? [String: Any] ?? [:]
        fields = details.compactMapValues { $0 as? String }
        urls = (details["uris"] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String }.joined(separator: "\n")
    }

    func encoded() throws -> Data {
        var record = original
        record["type"] = kind.rawValue
        record["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        record["notes"] = notes
        record["folderId"] = folder.isEmpty ? NSNull() : folder as Any
        record["favorite"] = favorite
        if original["fields"] is [[String: Any]] || !customFields.isEmpty {
            record["fields"] = customFields.map(\.record)
        }
        var details = record[kind.key] as? [String: Any] ?? [:]
        for field in kind.fields {
            if let value = fields[field] { details[field] = value }
        }
        if kind == .login {
            var existing = details["uris"] as? [[String: Any]] ?? []
            let values = urls.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            details["uris"] = values.map { value -> [String: Any] in
                guard let index = existing.firstIndex(where: { $0["uri"] as? String == value }) else {
                    return ["uri": value, "match": NSNull()]
                }
                return existing.remove(at: index)
            }
        }
        if kind == .note { details["type"] = 0 }
        record[kind.key] = details
        return try JSONSerialization.data(withJSONObject: record).base64EncodedData()
    }
}

@MainActor
final class BitwardenVault: ObservableObject {
    enum Status: String { case checking, unavailable, unauthenticated, locked, unlocked, failed }
    enum TrashAction { case move, restore, deletePermanently }
    struct Account: Decodable { let status: String; let serverUrl: String?; let userEmail: String? }

    @Published private(set) var status: Status = .checking {
        didSet { if oldValue != status { onStatusChange?() } }
    }
    @Published private(set) var account: Account?
    @Published private(set) var items: [BitwardenItem] = []
    @Published private(set) var trash: [BitwardenItem] = []
    @Published private(set) var folders: [BitwardenGroup] = []
    @Published private(set) var collections: [BitwardenGroup] = []
    @Published private(set) var busy = false
    @Published private(set) var error: LocalizedStringKey?
    @Published var detail: BitwardenDraft?
    @Published var generatedPassword = ""
    var onStatusChange: (() -> Void)?

    private let cli: BitwardenCLI
    private var session: String?
    private var revision = 0
    private var clipboardChangeCount: Int?
    private var clipboardTask: Task<Void, Never>?
    private var lockTask: Task<Void, Never>?

    init(cli: BitwardenCLI) { self.cli = cli }

    func refreshStatus() async {
        guard !busy else { return }
        guard cli.executable != nil else {
            lock()
            status = .unavailable
            return
        }
        await perform("error.status", resetsIdleTimer: false) { revision in
            let data = try await self.cli.run(["status"], session: self.session)
            guard revision == self.revision else { return }
            let account = try JSONDecoder().decode(Account.self, from: data)
            self.account = account
            if self.session != nil, account.status == "unlocked" {
                self.status = .unlocked
            } else {
                if self.session != nil { self.lock() }
                self.status = account.status == "unauthenticated" ? .unauthenticated : .locked
            }
        }
        if status == .checking, error != nil { status = .failed }
    }

    func authenticate(email: String, password: String, server: String, method: String, code: String) async {
        guard !busy, status == .locked || status == .unauthenticated else { return }
        let login = status == .unauthenticated
        await perform("error.authenticate") { revision in
            if login {
                var arguments = ["config", "server"]
                if !server.isEmpty {
                    guard let url = URLComponents(string: server), url.scheme?.lowercased() == "https",
                          url.host != nil, url.user == nil, url.password == nil,
                          url.query == nil, url.fragment == nil else {
                        self.error = "error.server"
                        return
                    }
                    arguments.append(server)
                } else {
                    arguments.append("https://vault.bitwarden.com")
                }
                if self.account?.serverUrl?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    != arguments.last?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                    _ = try await self.cli.run(arguments)
                    guard self.revision == revision else { return }
                    self.account = Account(status: "unauthenticated", serverUrl: arguments.last, userEmail: nil)
                }
            }
            guard self.revision == revision else { return }
            var arguments = [login ? "login" : "unlock"]
            arguments += ["--raw", "--passwordenv", "MACTOOLS_BW_PASSWORD"]
            if login {
                arguments += ["--method", method]
                if !code.isEmpty { arguments += ["--code", code] }
            }
            if login { arguments += ["--", email] }
            let data = try await self.cli.run(arguments, password: password)
            guard self.revision == revision else { return }
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = Data(base64Encoded: token), key.count == 32 || key.count == 64 else {
                throw BitwardenCLI.Failure.invalidResponse
            }
            self.session = token
            self.status = .unlocked
            self.touch()
            do { try await self.load(revision: revision) }
            catch { if self.revision == revision { self.error = "error.refresh" } }
        }
        if login && status == .unauthenticated && error != nil {
            // Some authentication failures leave the CLI signed in but locked.
            let failure = error
            await refreshStatus()
            error = failure
        }
    }

    func lock() {
        revision += 1
        session = nil
        lockTask?.cancel()
        lockTask = nil
        items = []
        trash = []
        folders = []
        collections = []
        detail = nil
        generatedPassword = ""
        error = nil
        clearClipboard()
        if status == .unlocked { status = .locked }
    }

    func touch() {
        guard session != nil else { return }
        lockTask?.cancel()
        lockTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            self?.lock()
        }
    }

    func signOut() async {
        guard !busy else { return }
        lock()
        await perform("error.signOut") { revision in
            _ = try await self.cli.run(["logout"])
            guard revision == self.revision else { return }
            self.account = nil
            self.status = .unauthenticated
        }
    }

    func refresh(sync: Bool) async {
        guard session != nil else { return }
        await perform("error.refresh") { revision in
            if sync { _ = try await self.command(["sync"]) }
            guard revision == self.revision else { return }
            try await self.load(revision: revision)
        }
    }

    func read(_ item: BitwardenItem) async {
        guard !busy, !Task.isCancelled else { return }
        detail = nil
        guard item.kind != nil, (item.reprompt ?? 0) == 0 else { return }
        await perform("error.read") { revision in
            let data = try await self.command(["get", "item", item.id])
            guard revision == self.revision, !Task.isCancelled else { return }
            self.detail = try BitwardenDraft(itemID: item.id, data: data)
        }
    }

    func save(_ draft: BitwardenDraft) async -> Bool {
        var saved = false
        await perform("error.save") { revision in
            let arguments = draft.itemID.map { ["edit", "item", $0] } ?? ["create", "item"]
            let response = try await self.command(arguments, input: try draft.encoded())
            guard revision == self.revision else { return }
            saved = true
            if let id = draft.itemID, self.detail?.itemID == id {
                self.detail = try? BitwardenDraft(itemID: id, data: response)
            }
            try await self.load(revision: revision)
        }
        return saved
    }

    func changeTrash(_ item: BitwardenItem, action: TrashAction) async {
        guard item.organizationId == nil else { return }
        switch action {
        case .move: guard items.contains(where: { $0.id == item.id }) else { return }
        case .restore, .deletePermanently: guard trash.contains(where: { $0.id == item.id }) else { return }
        }
        await perform("error.trash") { revision in
            let arguments = switch action {
            case .move: ["delete", "item", item.id]
            case .restore: ["restore", "item", item.id]
            case .deletePermanently: ["delete", "item", item.id, "--permanent"]
            }
            _ = try await self.command(arguments)
            guard revision == self.revision else { return }
            self.detail = nil
            try await self.load(revision: revision)
        }
    }

    func saveFolder(_ name: String, group: BitwardenGroup?) async {
        await perform("error.folder") { revision in
            let data = try JSONSerialization.data(withJSONObject: ["name": name])
            let arguments = group.map { ["edit", "folder", $0.id] } ?? ["create", "folder"]
            _ = try await self.command(arguments, input: data.base64EncodedData())
            guard revision == self.revision else { return }
            try await self.load(revision: revision)
        }
    }

    func generate(length: Int, digits: Bool, symbols: Bool) async {
        generatedPassword = ""
        await perform("error.generate") { revision in
            var arguments = ["generate", "--length", String(length), "--uppercase", "--lowercase"]
            if digits { arguments.append("--number") }
            if symbols { arguments.append("--special") }
            let data = try await self.cli.run(arguments)
            guard revision == self.revision else { return }
            self.generatedPassword = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
    }

    func copyVerificationCode(for item: BitwardenItem) async {
        guard item.kind == .login, (item.reprompt ?? 0) == 0 else { return }
        await perform("error.totp") { revision in
            let data = try await self.command(["get", "totp", item.id])
            guard revision == self.revision else { return }
            let code = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { throw BitwardenCLI.Failure.invalidResponse }
            self.copy(code)
        }
    }

    func copy(_ text: String) {
        guard session != nil, !text.isEmpty else { return }
        touch()
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"] {
            item.setData(Data(), forType: .init(marker))
        }
        board.writeObjects([item])
        clipboardChangeCount = board.changeCount
        clipboardTask?.cancel()
        clipboardTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.clearClipboard()
        }
    }

    private func clearClipboard() {
        let board = NSPasteboard.general
        if clipboardChangeCount == board.changeCount { board.clearContents() }
        clipboardChangeCount = nil
    }

    private func command(_ arguments: [String], input: Data? = nil) async throws -> Data {
        guard let session else { throw CancellationError() }
        return try await cli.run(arguments, session: session, input: input)
    }

    private func load(revision: Int) async throws {
        let decoder = JSONDecoder()
        let loadedItems = try await command(["list", "items"])
        let loadedTrash = try await command(["list", "items", "--trash"])
        let loadedFolders = try await command(["list", "folders"])
        let loadedCollections = try await command(["list", "collections"])
        guard revision == self.revision else { return }
        let itemList = try decoder.decode([BitwardenItem].self, from: loadedItems)
        let trashList = try decoder.decode([BitwardenItem].self, from: loadedTrash)
        let folderList = try decoder.decode([BitwardenGroup].self, from: loadedFolders)
        let collectionList = try decoder.decode([BitwardenGroup].self, from: loadedCollections)
        items = itemList
        trash = trashList
        folders = folderList
        collections = collectionList
    }

    private func perform(
        _ failure: LocalizedStringKey, resetsIdleTimer: Bool = true, operation: (Int) async throws -> Void
    ) async {
        guard !busy else { return }
        busy = true
        error = nil
        if resetsIdleTimer { touch() }
        let stamp = revision
        defer { busy = false }
        do { try await operation(stamp) }
        catch { if stamp == revision { self.error = failure } }
    }
}
