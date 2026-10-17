import Foundation
import MacToolsPluginKit

struct MenuBarPanelDefinition: Codable, Equatable, Identifiable, Sendable {
    static let componentsID = "components"
    static let featuresID = "features"
    static let maximumCount = 5
    static let maximumNameLength = 24

    let id: String
    var name: String
    var systemImage: String
    var isHidden = false

    var isDefault: Bool { id == Self.componentsID || id == Self.featuresID }

    var title: String {
        if !name.isEmpty { return name }
        return switch id {
        case Self.componentsID:
            AppL10n.plugins("plugin.panel.components", defaultValue: "组件面板")
        case Self.featuresID:
            AppL10n.plugins("plugin.panel.features", defaultValue: "功能面板")
        default:
            FeatureL10n.string("新面板")
        }
    }

    static func nextName(avoiding names: Set<String>) -> String {
        var number = 1
        while names.contains(FeatureL10n.format("面板 %lld", number)) { number += 1 }
        return FeatureL10n.format("面板 %lld", number)
    }

    static var defaults: [Self] {
        [
            Self(id: componentsID, name: "", systemImage: "square.grid.2x2"),
            Self(id: featuresID, name: "", systemImage: "switch.2"),
        ]
    }
}

@MainActor
final class MenuBarPanelStore {
    static let storageKey = "menuBar.panelConfiguration"
    static let selectionStorageKey = "menuBar.lastSelectedPanelID"
    static let legacyClickBehaviorStorageKey = "menuBar.clickBehaviorPreference"
    static let legacyDisplayStorageKey = "plugin.display.preferences"
    private let userDefaults: UserDefaults
    private let reporter: PreferencesBackupChangeReporter?
    private(set) var configuration: MenuBarPanelConfiguration
    private(set) var loadError: String?

    init(userDefaults: UserDefaults, reporter: PreferencesBackupChangeReporter? = nil) {
        self.userDefaults = userDefaults
        self.reporter = reporter
        configuration = MenuBarPanelConfiguration()
        do {
            let data = userDefaults.data(forKey: Self.storageKey)
            let legacyDisplay = userDefaults.data(forKey: Self.legacyDisplayStorageKey)
            let version = try data.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["version"] as? Int
            if let data, (version == MenuBarPanelConfiguration.currentVersion || version == 3) {
                configuration = try JSONDecoder().decode(MenuBarPanelConfiguration.self, from: data).normalized()
            } else if data == nil || version == 1 || version == 2 {
                let legacy = try data.map { try JSONDecoder().decode(LegacyPanelLayout.self, from: $0) }
                    ?? LegacyPanelLayout()
                configuration = PanelLayoutMigrator.migrate(legacy,
                    preferences: try LegacyPanelDisplayPreferences(data: legacyDisplay))
                configuration = configuration.applyingLegacyClickBehavior(
                    userDefaults.string(forKey: Self.legacyClickBehaviorStorageKey))
                if data != nil || legacyDisplay != nil ||
                    userDefaults.object(forKey: Self.legacyClickBehaviorStorageKey) != nil {
                    // Write the complete replacement before retiring any source fields.
                    let encoded = try JSONEncoder().encode(configuration)
                    userDefaults.set(encoded, forKey: Self.storageKey)
                    userDefaults.removeObject(forKey: Self.legacyClickBehaviorStorageKey)
                }
            } else {
                throw CocoaError(.coderReadCorrupt)
            }
            if userDefaults.data(forKey: Self.storageKey) != nil, let legacyDisplay {
                let legacy = try LegacyPanelDisplayPreferences(data: legacyDisplay)
                // Both replacement stores must be durable before retiring the shared source.
                if userDefaults.object(forKey: PluginOrderingStore.storageKey) == nil {
                    userDefaults.set(legacy.generalOrder, forKey: PluginOrderingStore.storageKey)
                }
                if userDefaults.array(forKey: PluginOrderingStore.storageKey) is [String] {
                    userDefaults.removeObject(forKey: Self.legacyDisplayStorageKey)
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    var lastSelectedPanelID: String {
        let panels = configuration.panels.filter { !$0.isHidden }
        let saved = userDefaults.string(forKey: Self.selectionStorageKey)
        return panels.first { $0.id == saved }?.id ?? panels.first?.id ?? MenuBarPanelDefinition.componentsID
    }

    func rememberSelection(id: String) {
        guard configuration.panels.contains(where: { $0.id == id && !$0.isHidden }),
              userDefaults.string(forKey: Self.selectionStorageKey) != id else { return }
        userDefaults.set(id, forKey: Self.selectionStorageKey)
    }

    @discardableResult
    func replace(_ configuration: MenuBarPanelConfiguration, replacingUnreadable: Bool = false) -> Bool {
        guard configuration.version == MenuBarPanelConfiguration.currentVersion,
              loadError == nil || replacingUnreadable else { return false }
        let next = configuration.normalized()
        guard next != self.configuration || replacingUnreadable,
              let data = try? JSONEncoder().encode(next) else { return false }
        userDefaults.set(data, forKey: Self.storageKey)
        if replacingUnreadable {
            // An explicit reset/import supersedes the legacy layout, including
            // unreadable data. Preserve its management order before retiring it.
            if userDefaults.object(forKey: PluginOrderingStore.storageKey) == nil {
                let legacy = userDefaults.data(forKey: Self.legacyDisplayStorageKey).flatMap {
                    try? LegacyPanelDisplayPreferences(data: $0)
                }
                userDefaults.set(legacy?.generalOrder ?? [], forKey: PluginOrderingStore.storageKey)
            }
            userDefaults.removeObject(forKey: Self.legacyDisplayStorageKey)
            userDefaults.removeObject(forKey: Self.legacyClickBehaviorStorageKey)
        }
        self.configuration = next
        loadError = nil
        if let selected = userDefaults.string(forKey: Self.selectionStorageKey),
           !next.panels.contains(where: { $0.id == selected && !$0.isHidden }) {
            userDefaults.removeObject(forKey: Self.selectionStorageKey)
        }
        reporter?.didPersist(.pluginDisplay)
        return true
    }

    /// Seeding and the acknowledgement are one write, including library-only items.
    @discardableResult
    func reconcile(_ items: [(key: PluginPanelItemKey, initialPlacement: PluginPanelInitialPlacement?)],
                   discoveredPluginIDs: Set<String> = []) -> Bool {
        var next = configuration
        for item in items where next.initializedItems.insert(item.key).inserted {
            if let seed = next.legacySeed, seed.pluginIDs.contains(item.key.pluginID),
               !seed.resolvedPluginIDs.contains(item.key.pluginID),
               item.key.itemID == "control" || item.key.itemID == "widget" {
                let hidden = item.key.itemID == "widget" ? seed.dashboardHidden : seed.featureHidden
                guard !hidden.contains(item.key.pluginID) else { continue }
                let panelID = item.key.itemID == "widget" ? MenuBarPanelDefinition.componentsID : MenuBarPanelDefinition.featuresID
                let placement = MenuBarPanelPlacement(item: item.key)
                let order = seed.generalOrder
                let successors = order.firstIndex(of: item.key.pluginID).map { Set(order.dropFirst($0 + 1)) } ?? []
                var existing = next.placementsByPanelID[panelID, default: []]
                let index = existing.firstIndex { $0.item.itemID == item.key.itemID && successors.contains($0.item.pluginID) }
                existing.insert(placement, at: index ?? existing.count)
                next.placementsByPanelID[panelID] = existing
                continue
            }
            guard let initial = item.initialPlacement else { continue }
            next.placementsByPanelID[initial.panelID, default: []].append(MenuBarPanelPlacement(item: item.key))
        }
        next.legacySeed?.resolvedPluginIDs.formUnion(discoveredPluginIDs.union(items.map(\.key.pluginID)))
        if let seed = next.legacySeed, seed.pluginIDs.isSubset(of: seed.resolvedPluginIDs) { next.legacySeed = nil }
        return replace(next)
    }

    func migrateLegacyHiddenPlugins(_ ids: Set<String>) -> Bool {
        guard loadError == nil else { return false }
        var next = configuration
        let previous = next.legacySeed
        next.legacySeed = LegacyPanelSeed(generalOrder: previous?.generalOrder ?? [],
            dashboardHidden: (previous?.dashboardHidden ?? []).union(ids),
            featureHidden: (previous?.featureHidden ?? []).union(ids),
            resolvedPluginIDs: (previous?.resolvedPluginIDs ?? []).subtracting(ids))
        for panelID in next.placementsByPanelID.keys {
            next.placementsByPanelID[panelID]?.removeAll { ids.contains($0.item.pluginID) }
        }
        return next == configuration || replace(next)
    }

    @discardableResult
    func addPanel() -> String? {
        guard configuration.panels.count < MenuBarPanelDefinition.maximumCount else { return nil }
        var next = configuration
        let id = UUID().uuidString.lowercased()
        next.panels.append(MenuBarPanelDefinition(id: id,
            name: MenuBarPanelDefinition.nextName(avoiding: Set(next.panels.map(\.title))), systemImage: "star"))
        return replace(next) ? id : nil
    }

    func updatePanel(_ panel: MenuBarPanelDefinition) {
        guard let index = configuration.panels.firstIndex(where: { $0.id == panel.id }) else { return }
        var next = configuration
        next.panels[index] = panel
        replace(next)
    }

    func deletePanel(id: String) {
        guard configuration.panels.contains(where: { $0.id == id && !$0.isDefault }) else { return }
        var next = configuration
        next.panels.removeAll { $0.id == id }
        let displaced = next.placementsByPanelID.removeValue(forKey: id) ?? []
        // Preserve every instance, including unavailable plugins, in the first visible panel.
        let destination = next.panels.first { !$0.isHidden }?.id ?? MenuBarPanelDefinition.componentsID
        next.placementsByPanelID[destination, default: []].append(contentsOf: displaced)
        replace(next)
    }

    func movePanel(id: String, toOffset: Int) {
        var next = configuration
        guard let index = next.panels.firstIndex(where: { $0.id == id }) else { return }
        let panel = next.panels.remove(at: index)
        next.panels.insert(panel, at: min(max(toOffset - (toOffset > index ? 1 : 0), 0), next.panels.count))
        replace(next)
    }

    @discardableResult
    func addItem(_ key: PluginPanelItemKey, to panelID: String) -> MenuBarPanelPlacement? {
        guard configuration.panels.contains(where: { $0.id == panelID }) else { return nil }
        var next = configuration
        let placement = MenuBarPanelPlacement(item: key)
        next.initializedItems.insert(key)
        next.placementsByPanelID[panelID, default: []].append(placement)
        return replace(next) ? placement : nil
    }

    func removePlacement(id: UUID) {
        var next = configuration
        for panelID in next.placementsByPanelID.keys {
            next.placementsByPanelID[panelID]?.removeAll { $0.id == id }
        }
        replace(next)
    }

    func removePlugin(id: String) {
        var next = configuration
        for panelID in next.placementsByPanelID.keys {
            next.placementsByPanelID[panelID]?.removeAll { $0.item.pluginID == id }
        }
        next.initializedItems = next.initializedItems.filter { $0.pluginID != id }
        replace(next)
    }

    func movePlacement(id: UUID, to panelID: String, visibleOrder: [UUID]) {
        guard configuration.panels.contains(where: { $0.id == panelID }),
              let source = configuration.panelID(for: id),
              let placement = configuration.placementsByPanelID[source]?.first(where: { $0.id == id }) else { return }
        var next = configuration
        next.placementsByPanelID[source]?.removeAll { $0.id == id }
        next.placementsByPanelID[panelID, default: []].append(placement)
        next.placementsByPanelID[panelID] = Self.reordered(next.placementsByPanelID[panelID, default: []],
                                                        requested: visibleOrder)
        replace(next)
    }

    func setOrder(_ ids: [UUID], panelID: String) {
        var next = configuration
        next.placementsByPanelID[panelID] = Self.reordered(next.placementsByPanelID[panelID, default: []], requested: ids)
        replace(next)
    }

    private static func reordered(_ placements: [MenuBarPanelPlacement], requested: [UUID]) -> [MenuBarPanelPlacement] {
        let lookup = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })
        var seen: Set<UUID> = []
        let requested = requested.filter { lookup[$0] != nil && seen.insert($0).inserted }
        let moving = Set(requested)
        var iterator = requested.makeIterator()
        // Unavailable entries retain their slots while the visible projection moves.
        return placements.map { moving.contains($0.id) ? lookup[iterator.next()!]! : $0 }
    }
}
