import Foundation
import MacToolsPluginKit
import Security

protocol VoiceSecretStoring {
    func load() throws -> String?
    func save(_ key: String) throws
    func remove() throws
}

/// Each host owns a separate, device-only Keychain entry. Preferences never contain the key.
struct VoiceSecretStore: VoiceSecretStoring {
    private let service: String
    private let account = "openai.api-key.v1"

    init(hostBundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        service = PluginPrivateDataKeychainIdentity.service(pluginID: "voice-control", hostBundleIdentifier: hostBundleIdentifier)
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    func load() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VoiceSecretStoreError.security(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw VoiceFailure.credentials }
        return key
    }

    func save(_ key: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw VoiceSecretStoreError.security(status) }
        let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw VoiceSecretStoreError.security(added) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VoiceSecretStoreError.security(status) }
    }
}

enum VoiceSecretStoreError: Error { case security(OSStatus) }
