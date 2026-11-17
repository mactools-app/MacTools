import Foundation
import MacToolsPluginKit

/// The page's choices travel with MacTools' preferences backup. The usage
/// read from the agents' logs is history and stays on this Mac.
struct AIUsagePreferencesBackup: Codable, Equatable {
    static let version = 1

    var version = Self.version
    var period: String
    var limitDisplay: String
    var cardOrder: [String]
    var hiddenCards: [String]
    var providers: [String: Bool]
    var priceUpdates: Bool

    static func current(in defaults: UserDefaults = .standard) -> Self {
        Self(period: NotchAgentSupport.period(in: defaults).rawValue,
             limitDisplay: NotchAgentSupport.limitDisplay(in: defaults).rawValue,
             cardOrder: NotchAgentSupport.orderedCards(in: defaults).map(\.rawValue),
             hiddenCards: NotchAgentSupport.hiddenCards(in: defaults).map(\.rawValue).sorted(),
             providers: Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map {
                 ($0.rawValue, defaults.object(forKey: NotchAgentSupport.key(for: $0)) as? Bool ?? true)
             }),
             priceUpdates: NotchAgentSupport.updatesPrices(in: defaults))
    }

    /// Every field is checked before anything is written; an unknown value
    /// rejects the whole payload.
    static func decodeValidated(_ data: Data) -> Self? {
        guard data.count <= 16_384, let backup = try? JSONDecoder().decode(Self.self, from: data),
              backup.version == version,
              AgentPeriod(rawValue: backup.period) != nil,
              NotchAgentLimitDisplay(rawValue: backup.limitDisplay) != nil,
              backup.cardOrder.count <= NotchAgentCard.allCases.count,
              backup.hiddenCards.count <= NotchAgentCard.allCases.count,
              (backup.cardOrder + backup.hiddenCards).allSatisfy({ NotchAgentCard(rawValue: $0) != nil }),
              Set(backup.providers.keys).isSubset(of: Set(AgentProvider.allCases.map(\.rawValue))),
              backup.providers.values.contains(true) else { return nil }
        return backup
    }

    func apply(to defaults: UserDefaults = .standard) {
        defaults.set(period, forKey: DefaultsKey.notchAgentsPeriod)
        defaults.set(limitDisplay, forKey: DefaultsKey.notchAgentsLimitDisplay)
        defaults.set(cardOrder.joined(separator: ","), forKey: DefaultsKey.notchAgentsCardOrder)
        defaults.set(hiddenCards.joined(separator: ","), forKey: DefaultsKey.notchAgentsHiddenCards)
        for provider in AgentProvider.allCases {
            defaults.set(providers[provider.rawValue] ?? true, forKey: NotchAgentSupport.key(for: provider))
        }
        defaults.set(priceUpdates, forKey: DefaultsKey.notchAgentsPriceUpdates)
    }
}

extension AIUsagePlugin: PluginPortablePreferencesProviding, PluginPortablePreferencesRestorationReporting {
    func makePortablePreferencesBackup() -> Data? {
        try? JSONEncoder().encode(AIUsagePreferencesBackup.current())
    }

    func restorePortablePreferences(from data: Data) {
        _ = restorePortablePreferencesReportingResult(from: data)
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard let backup = AIUsagePreferencesBackup.decodeValidated(data) else { return false }
        let previous = AIUsagePreferencesBackup.current()
        backup.apply()
        // Written values are read back; a store that kept something else
        // gets the previous choices again.
        guard AIUsagePreferencesBackup.current() == normalized(backup) else {
            previous.apply()
            return false
        }
        preferencesChanged()
        onStateChange?()
        return true
    }

    /// What reading the stored values back gives for a backup: the order
    /// lists every card, the hidden set is sorted.
    private func normalized(_ backup: AIUsagePreferencesBackup) -> AIUsagePreferencesBackup {
        var seen = Set<String>()
        var copy = backup
        copy.cardOrder = (backup.cardOrder + NotchAgentCard.allCases.map(\.rawValue)).filter { seen.insert($0).inserted }
        copy.hiddenCards = Array(Set(backup.hiddenCards)).sorted()
        copy.providers = Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map {
            ($0.rawValue, backup.providers[$0.rawValue] ?? true)
        })
        return copy
    }
}
