import Foundation
import MacToolsPluginKit

struct PluginPanelItemKey: Codable, Hashable, Sendable {
    let pluginID: String
    let itemID: String

    var id: String { "\(pluginID):\(itemID)" }
}

enum MenuBarPanelItemPresentation {
    static let compactSwitch = "compact-switch"
}

/// Host-owned sizing; unknown modes survive backups and temporarily missing plugins.
struct MenuBarPanelItemWidth: Codable, Hashable, Sendable {
    static let minimumPoints: Double = 304
    static let fill = Self(mode: "fill", points: nil)
    static func custom(_ points: Double) -> Self { Self(mode: "custom", points: points) }

    let mode: String
    let points: Double?

    var normalized: Self? {
        if mode == "fill" { return .fill }
        if mode == "custom" {
            guard let points, points.isFinite else { return nil }
            return .custom(max(Self.minimumPoints, points.rounded()))
        }
        return Self(mode: mode, points: points?.isFinite == true ? points : nil)
    }
}

struct MenuBarPanelPlacement: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let item: PluginPanelItemKey
    // Keep unknown preferences intact when a plugin is unavailable or downgraded.
    var presentation: String?
    var width: MenuBarPanelItemWidth?

    init(id: UUID = UUID(), item: PluginPanelItemKey, presentation: String? = nil,
         width: MenuBarPanelItemWidth? = nil) {
        self.id = id
        self.item = item
        self.presentation = presentation
        self.width = width
    }
}

/// Renderer information is resolved from the current catalog, not persisted.
struct MenuBarPanelEntry: Hashable, Identifiable, Sendable {
    let placement: MenuBarPanelPlacement
    let kind: PluginPanelItemKind

    var id: String { placement.id.uuidString.lowercased() }
    var pluginID: String { placement.item.pluginID }
    var itemID: String { placement.item.itemID }
    var key: PluginPanelItemKey { placement.item }
}

struct MenuBarPanelLayoutChange {
    let before: MenuBarPanelConfiguration
    let after: MenuBarPanelConfiguration
}

struct MenuBarPanelConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 4
    static let defaultWidth: Double = 316
    var version = currentVersion
    var panels = MenuBarPanelDefinition.defaults
    var placementsByPanelID: [String: [MenuBarPanelPlacement]] = [:]
    var initializedItems: Set<PluginPanelItemKey> = []
    var legacySeed: LegacyPanelSeed?
    var preferredWidth = defaultWidth

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, panels, placementsByPanelID, initializedItems, legacySeed, preferredWidth
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion || version == 3 else {
            guard (1...2).contains(version) else {
                throw DecodingError.dataCorruptedError(forKey: .version, in: values,
                    debugDescription: "Unsupported panel layout version")
            }
            self = try PanelLayoutMigrator.migrate(LegacyPanelLayout(from: decoder))
            return
        }
        self.version = Self.currentVersion
        panels = try values.decode([MenuBarPanelDefinition].self, forKey: .panels)
        placementsByPanelID = try values.decode([String: [MenuBarPanelPlacement]].self, forKey: .placementsByPanelID)
        initializedItems = try values.decode(Set<PluginPanelItemKey>.self, forKey: .initializedItems)
        legacySeed = try values.decodeIfPresent(LegacyPanelSeed.self, forKey: .legacySeed)
        preferredWidth = try values.decodeIfPresent(Double.self, forKey: .preferredWidth) ?? Self.defaultWidth
    }

    var displayPanels: [MenuBarPanelDefinition] {
        panels.enumerated().map { index, panel in
            var panel = panel
            panel.name = FeatureL10n.format("面板 %lld", index + 1)
            return panel
        }
    }

    func applyingLegacyClickBehavior(_ behavior: String?) -> Self {
        guard behavior == "swapped" else { return self }
        var result = self
        result.panels.reverse()
        return result
    }

    func panelID(for placementID: UUID) -> String? {
        panels.first { panel in
            placementsByPanelID[panel.id, default: []].contains { $0.id == placementID }
        }?.id
    }

    func normalized() -> Self {
        var result = self
        result.preferredWidth = preferredWidth.isFinite ? max(Self.defaultWidth, preferredWidth) : Self.defaultWidth
        var panelIDs: Set<String> = []
        var customCount = 0
        result.panels = panels.compactMap { original in
            guard !original.id.isEmpty, panelIDs.insert(original.id).inserted else { return nil }
            if !original.isDefault {
                guard customCount < MenuBarPanelDefinition.maximumCount - 2 else { return nil }
                customCount += 1
            }
            var panel = original
            panel.name = String(panel.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(MenuBarPanelDefinition.maximumNameLength))
            if panel.systemImage.isEmpty { panel.systemImage = "square.grid.2x2" }
            return panel
        }
        for panel in MenuBarPanelDefinition.defaults where !result.panels.contains(where: { $0.id == panel.id }) {
            result.panels.append(panel)
        }
        if result.panels.allSatisfy(\.isHidden) { result.panels[0].isHidden = false }
        var placementIDs: Set<UUID> = []
        result.placementsByPanelID = [:]
        // Deterministic traversal also repairs accidentally duplicated placement IDs.
        for panel in result.panels {
            let placements = placementsByPanelID[panel.id, default: []].filter {
                !$0.item.pluginID.isEmpty && !$0.item.itemID.isEmpty && placementIDs.insert($0.id).inserted
            }
            if !placements.isEmpty { result.placementsByPanelID[panel.id] = placements }
        }
        // Preserve entries whose container is missing, including imported layouts.
        let validPanels = Set(result.panels.map(\.id))
        for panelID in placementsByPanelID.keys.sorted() where !validPanels.contains(panelID) {
            for placement in placementsByPanelID[panelID, default: []]
                where !placement.item.pluginID.isEmpty && !placement.item.itemID.isEmpty
                    && placementIDs.insert(placement.id).inserted {
                result.placementsByPanelID[MenuBarPanelDefinition.componentsID, default: []].append(placement)
            }
        }
        result.initializedItems.formUnion(result.placementsByPanelID.values.flatMap { $0 }.map(\.item))
        for panelID in result.placementsByPanelID.keys {
            result.placementsByPanelID[panelID] = result.placementsByPanelID[panelID]?.map { placement in
                var placement = placement
                placement.width = placement.width?.normalized
                return placement
            }
        }
        return result
    }
}

extension PluginPanelInitialPlacement {
    var panelID: String {
        switch self {
        case .dashboard: MenuBarPanelDefinition.componentsID
        case .featurePanel: MenuBarPanelDefinition.featuresID
        }
    }
}
