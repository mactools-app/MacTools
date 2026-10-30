import Darwin
import Foundation
import MacToolsPluginKit

struct OpenAICompatibleConfiguration: Equatable, Sendable {
    static let defaultBaseURL = "https://api.openai.com"
    static let defaultModel = "gpt-5.4-mini"
    static var defaultPromptTemplate: String {
        defaultPromptTemplate()
    }

    static func defaultPromptTemplate(
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> String {
        localization.string(
            "settings.defaultPromptTemplate",
            defaultValue: "请将下面的文本从 {{source_language}} 翻译为 {{target_language}}，只返回译文。\n\n{{text}}"
        )
    }

    var baseURL: String
    var model: String
    var promptTemplate: String

    var normalizedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(
        baseURL: String = Self.defaultBaseURL,
        model: String = Self.defaultModel,
        promptTemplate: String = Self.defaultPromptTemplate
    ) {
        self.baseURL = baseURL
        self.model = model
        self.promptTemplate = promptTemplate
    }

    @MainActor
    init(
        storage: PluginStorage,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.init(
            baseURL: storage.string(forKey: TranslatorConstants.StorageKey.openAIBaseURL) ?? Self.defaultBaseURL,
            model: storage.string(forKey: TranslatorConstants.StorageKey.openAIModel) ?? Self.defaultModel,
            promptTemplate: storage.string(forKey: TranslatorConstants.StorageKey.openAIPromptTemplate)
                ?? Self.defaultPromptTemplate(localization: localization)
        )
    }

    var validationError: OpenAICompatibleConfigurationError? {
        if normalizedBaseURL.isEmpty {
            return .blankBaseURL
        }

        guard let components = URLComponents(string: normalizedBaseURL),
              let host = components.host,
              !host.isEmpty,
              Self.isAllowedScheme(components.scheme, host: host)
        else {
            return .invalidBaseURL
        }

        if normalizedModel.isEmpty {
            return .blankModel
        }

        if !promptTemplate.contains("{{text}}") {
            return .missingTextPlaceholder
        }

        return nil
    }

    @MainActor
    func save(to storage: PluginStorage) {
        storage.set(normalizedBaseURL, forKey: TranslatorConstants.StorageKey.openAIBaseURL)
        storage.set(normalizedModel, forKey: TranslatorConstants.StorageKey.openAIModel)
        storage.set(promptTemplate, forKey: TranslatorConstants.StorageKey.openAIPromptTemplate)
    }

    func endpointURL() throws -> URL {
        if let validationError {
            throw validationError
        }

        guard var components = URLComponents(string: normalizedBaseURL),
              let host = components.host,
              !host.isEmpty,
              Self.isAllowedScheme(components.scheme, host: host)
        else {
            throw OpenAICompatibleConfigurationError.invalidBaseURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathComponents = basePath.isEmpty ? [] : basePath.split(separator: "/").map(String.init)
        let lowercasedPathComponents = pathComponents.map { $0.lowercased() }
        let completionPathComponents: [String]

        if Array(lowercasedPathComponents.suffix(2)) == ["chat", "completions"] {
            completionPathComponents = pathComponents
        } else if lowercasedPathComponents.last == "v1" {
            completionPathComponents = pathComponents + ["chat", "completions"]
        } else {
            completionPathComponents = pathComponents + ["v1", "chat", "completions"]
        }

        components.path = "/" + completionPathComponents.joined(separator: "/")

        guard let url = components.url else {
            throw OpenAICompatibleConfigurationError.invalidBaseURL
        }

        return url
    }

    private static func isAllowedScheme(_ scheme: String?, host: String) -> Bool {
        guard let scheme = scheme?.lowercased() else {
            return false
        }

        if scheme == "https" {
            return true
        }

        return scheme == "http" && isLocalHTTPHost(host)
    }

    private static func isLocalHTTPHost(_ host: String) -> Bool {
        let normalizedHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if normalizedHost == "localhost"
            || normalizedHost == "127.0.0.1"
            || normalizedHost == "::1" {
            return true
        }

        // Parse literal addresses without DNS or permissive numeric-host shorthand.
        var ipv4 = in_addr()
        if inet_pton(AF_INET, normalizedHost, &ipv4) == 1 {
            // Darwin accepts leading zeros that URL loading may interpret as octal.
            guard normalizedHost.split(separator: ".").allSatisfy({
                $0.count == 1 || !$0.hasPrefix("0")
            }) else { return false }
            let address = UInt32(bigEndian: ipv4.s_addr)
            return address & 0xff00_0000 == 0x0a00_0000       // 10.0.0.0/8
                || address & 0xfff0_0000 == 0xac10_0000      // 172.16.0.0/12
                || address & 0xffff_0000 == 0xc0a8_0000      // 192.168.0.0/16
        }

        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, normalizedHost, &ipv6) == 1 else { return false }
        // IPv6 unique local addresses (fc00::/7); mapped IPv4 and link-local addresses
        // do not inherit this exception. Keep the host's ATS ranges aligned with it.
        return withUnsafeBytes(of: ipv6) { $0[0] & 0xfe == 0xfc }
    }
}

enum OpenAICompatibleConfigurationError: Error, Equatable, Sendable {
    case missingTextPlaceholder
    case blankBaseURL
    case invalidBaseURL
    case blankModel
}

extension OpenAICompatibleConfigurationError: LocalizedError {
    var errorDescription: String? {
        errorDescription()
    }

    func errorDescription(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .missingTextPlaceholder:
            return localization.string(
                "openAIConfiguration.error.missingTextPlaceholder",
                defaultValue: "提示词必须包含 {{text}}。"
            )
        case .blankBaseURL:
            return localization.string("openAIConfiguration.error.blankBaseURL", defaultValue: "Base URL 不能为空。")
        case .invalidBaseURL:
            return localization.string("openAIConfiguration.error.invalidBaseURL", defaultValue: "Base URL 无效。")
        case .blankModel:
            return localization.string("openAIConfiguration.error.blankModel", defaultValue: "模型不能为空。")
        }
    }
}
