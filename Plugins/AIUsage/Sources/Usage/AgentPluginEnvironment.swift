// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Vorssaint (github.com/vorssaint/vorssaint-utils), GPL-3.0-or-later.
// Copyright (C) 2026 Vorssaint; MacTools adaptation (C) 2026 MacTools contributors.

import Foundation
import MacToolsPluginKit

/// Preference keys for the ported AI page. They live under the plugin's own
/// storage namespace (`plugin.ai-usage.`), so `@AppStorage` and
/// `PluginStorage` read the same values.
enum DefaultsKey {
    private static let prefix = "plugin.ai-usage.agents."
    static let notchAgentsPeriod = prefix + "period"
    static let notchAgentsLimitDisplay = prefix + "limitDisplay"
    static let notchAgentsCardOrder = prefix + "cardOrder"
    static let notchAgentsHiddenCards = prefix + "hiddenCards"
    static let notchAgentsClaude = prefix + "claude"
    static let notchAgentsCodex = prefix + "codex"
    static let notchAgentsOpenCode = prefix + "opencode"
    static let notchAgentsCopilot = prefix + "copilot"
    static let notchAgentsPriceUpdates = prefix + "priceUpdates"
    static let notchAgentsClaudeProfile = prefix + "claudeProfile"

    static let all = [notchAgentsPeriod, notchAgentsLimitDisplay, notchAgentsCardOrder, notchAgentsHiddenCards,
                      notchAgentsClaude, notchAgentsCodex, notchAgentsOpenCode, notchAgentsCopilot,
                      notchAgentsPriceUpdates]
}

/// Where the plugin keeps its files, set by the host at activation. The
/// usage archive is a cache the logs can rebuild; the downloaded price list
/// is support data.
enum AgentPluginEnvironment {
    nonisolated(unsafe) static var cacheDirectory: URL?
    nonisolated(unsafe) static var supportDirectory: URL?
    nonisolated(unsafe) static var resourceBundle: Bundle = .main
    /// Whether the plugin is active. The service reads nothing while it is not.
    nonisolated(unsafe) static var active = false

    /// The parser changes with the plugin, not the host, so the archive is
    /// stamped with the plugin bundle's version.
    static var buildInfo: [String: Any]? { resourceBundle.infoDictionary }
}

/// Owner-only files in the plugin's support folder.
enum PrivateFileStore {
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600

    static var containerURL: URL? { AgentPluginEnvironment.supportDirectory }

    @discardableResult
    static func createDirectory(at url: URL, container: URL? = containerURL) -> Bool {
        let manager = FileManager.default
        guard (try? manager.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: directoryPermissions])) != nil
        else { return false }
        try? manager.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: url.path)
        return true
    }

    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: url.path)
        return true
    }
}

extension NotchAgentStrings {
    /// Vorssaint's translations, picked by the language MacTools runs in.
    static var current: NotchAgentStrings {
        for language in PluginRuntimeLocalization.preferredLanguages {
            let code = language.lowercased()
            if code.hasPrefix("zh-hant-hk") || code.hasPrefix("zh-hk") { return .zhHK }
            if code.hasPrefix("zh-hant") || code.hasPrefix("zh-tw") { return .zhTW }
            if code.hasPrefix("zh") { return .zhHans }
            switch code.prefix(2) {
            case "en": return .enUS
            case "pt": return .ptBR
            case "es": return .es
            case "sk": return .sk
            case "de": return .de
            case "fr": return .fr
            case "it": return .it
            case "ru": return .ru
            case "tr": return .tr
            case "ja": return .ja
            case "ko": return .ko
            case "uk": return .uk
            default: continue
            }
        }
        return .enUS
    }
}
