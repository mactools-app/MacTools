import Foundation
import MacToolsPluginKit

enum VoiceFailure: Error {
    case credentials, microphone, audio, connection, overloaded, protocolError
}

enum VoiceCredentials {
    static func valid(_ key: String) -> Bool {
        key.hasPrefix("sk-") && key.count > 20 && key.count < 1024 && !key.contains(where: { $0.isWhitespace })
    }
}

/// Development and production both use the user's explicit login-Keychain credential.
@MainActor
final class VoiceCredentialConfiguration {
    enum Source: String { case none, keychain }
    private let storage: any PluginStorage
    private let secrets: any VoiceSecretStoring
    private(set) var source: Source

    init(storage: any PluginStorage, secrets: any VoiceSecretStoring = VoiceSecretStore()) {
        self.storage = storage; self.secrets = secrets
        source = storage.string(forKey: "credentialSource") == "keychain" ? .keychain : .none
        // Remove prototype file references without reading or importing their contents.
        storage.removeObject(forKey: "credentialFile")
        if source == .none { storage.set(source.rawValue, forKey: "credentialSource") }
    }

    var isConfigured: Bool { source == .keychain }

    func loadForConversation() async throws -> String {
        switch source {
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
        source = .keychain
        storage.removeObject(forKey: "credentialFile")
        storage.set(source.rawValue, forKey: "credentialSource")
    }

    func forget() async throws {
        let secrets = self.secrets
        try await Task.detached(priority: .userInitiated) { try secrets.remove() }.value
        source = .none
        storage.removeObject(forKey: "credentialFile")
        storage.set(source.rawValue, forKey: "credentialSource")
    }
}
