import Foundation
import MacToolsPluginKit

enum VoiceFailure: Error {
    case credentials, microphone, audio, connection, overloaded, protocolError
}

enum VoiceCredentials {
    /// Read only when a conversation starts; persist the selected path, never the secret.
    static func load(path: String?, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if let key = environment["OPENAI_API_KEY"], valid(key) { return key }
        guard let path = path ?? environment["MACTOOLS_VOICE_ENV_FILE"], path.hasPrefix("/"),
              let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { throw VoiceFailure.credentials }
        defer { try? file.close() }
        // Bound the actual read instead of querying unrelated extended attributes.
        // Protected locations can block filesystem calls pending system approval.
        var data = Data()
        do {
            while data.count <= 65_536 {
                guard let chunk = try file.read(upToCount: 65_537 - data.count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch { throw VoiceFailure.credentials }
        guard data.count <= 65_536, let source = String(data: data, encoding: .utf8) else { throw VoiceFailure.credentials }
        let candidates = source.components(separatedBy: .newlines).compactMap { line -> String? in
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == "OPENAI_API_KEY" else { return nil }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, (first == "\"" || first == "'"), value.last == first {
                value.removeFirst(); value.removeLast()
            }
            return value
        }
        guard candidates.count == 1, let key = candidates.first, valid(key) else { throw VoiceFailure.credentials }
        return key
    }

    static func valid(_ key: String) -> Bool {
        key.hasPrefix("sk-") && key.count > 20 && key.count < 1024 && !key.contains(where: { $0.isWhitespace })
    }
}

/// A user's explicit choice always wins over development environment variables.
@MainActor
final class VoiceCredentialConfiguration {
    enum Source: String { case none, keychain, file, environment }
    private let storage: any PluginStorage
    private let secrets: any VoiceSecretStoring
    private let environment: [String: String]
    private(set) var source: Source
    private(set) var path: String?

    init(storage: any PluginStorage, secrets: any VoiceSecretStoring = VoiceSecretStore(),
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.storage = storage; self.secrets = secrets; self.environment = environment
        #if DEBUG
        path = storage.string(forKey: "credentialFile")
        if let saved = storage.string(forKey: "credentialSource") {
            source = Source(rawValue: saved) ?? .none
        } else { source = path == nil ? .environment : .file }
        #else
        path = nil
        source = storage.string(forKey: "credentialSource") == "keychain" ? .keychain : .none
        #endif
    }

    var isConfigured: Bool {
        switch source {
        case .none: return false
        case .keychain: return true
        case .file, .environment:
            #if DEBUG
            return source == .file ? path != nil : environment["OPENAI_API_KEY"] != nil || environment["MACTOOLS_VOICE_ENV_FILE"] != nil
            #else
            return false
            #endif
        }
    }

    func loadForConversation() async throws -> String {
        switch source {
        case .file, .environment:
            #if DEBUG
            let path = source == .file ? path : nil
            let environment = source == .file ? [:] : environment
            return try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try VoiceCredentials.load(path: path, environment: environment)
            }.value
            #else
            throw VoiceFailure.credentials
            #endif
        case .none: throw VoiceFailure.credentials
        case .keychain:
            let secrets = self.secrets
            let key = try await Task.detached(priority: .userInitiated) { try secrets.load() }.value
            guard let key, VoiceCredentials.valid(key) else { throw VoiceFailure.credentials }
            return key
        }
    }

    func save(_ input: String) async throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoiceCredentials.valid(key) else { throw VoiceFailure.credentials }
        let secrets = self.secrets
        try await Task.detached(priority: .userInitiated) { try secrets.save(key) }.value
        source = .keychain; path = nil
        storage.removeObject(forKey: "credentialFile")
        storage.set(source.rawValue, forKey: "credentialSource")
    }

    #if DEBUG
    func selectFile(_ path: String) {
        self.path = path; source = .file
        storage.set(path, forKey: "credentialFile")
        storage.set(source.rawValue, forKey: "credentialSource")
    }

    #endif

    func forget() async throws {
        let secrets = self.secrets
        try await Task.detached(priority: .userInitiated) { try secrets.remove() }.value
        source = .none; path = nil
        storage.removeObject(forKey: "credentialFile")
        storage.set(source.rawValue, forKey: "credentialSource")
    }
}
