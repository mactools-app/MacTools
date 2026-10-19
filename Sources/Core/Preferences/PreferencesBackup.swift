import Foundation
import MacToolsPluginKit

enum PreferencesImportProgress: Equatable, Sendable {
    case preparing(pluginCount: Int)
    case installingPlugin(id: String, number: Int, total: Int)
    case restoringPreferences(completedPluginCount: Int, totalPluginCount: Int)

    var completedUnitCount: Int {
        switch self {
        case .preparing:
            return 0
        case let .installingPlugin(_, number, _):
            return max(0, number - 1)
        case let .restoringPreferences(completedPluginCount, _):
            return completedPluginCount
        }
    }

    var totalUnitCount: Int {
        switch self {
        case let .preparing(pluginCount):
            return pluginCount + 1
        case let .installingPlugin(_, _, total):
            return total + 1
        case let .restoringPreferences(_, totalPluginCount):
            return totalPluginCount + 1
        }
    }
}

struct PreferencesBackup: Codable, Equatable, Sendable {
    static let currentFormatVersion = 7
    static let maximumFileSize = 16 * 1024 * 1024

    struct ApplicationPreferences: Codable, Equatable, Sendable {
        let appearancePreference: String
        let floatingPanelAppearance: String?
        let languagePreference: String
        // Decode older backups only; current exports store the panel order instead.
        let menuBarClickBehavior: String?
        let settingsSidebarPluginSortMode: String?
        let settingsSidebarCustomPluginOrder: [String]?

        init(
            appearancePreference: String,
            floatingPanelAppearance: String? = nil,
            languagePreference: String,
            menuBarClickBehavior: String? = nil,
            settingsSidebarPluginSortMode: String? = nil,
            settingsSidebarCustomPluginOrder: [String]? = nil
        ) {
            self.appearancePreference = appearancePreference
            self.floatingPanelAppearance = floatingPanelAppearance
            self.languagePreference = languagePreference
            self.menuBarClickBehavior = menuBarClickBehavior
            self.settingsSidebarPluginSortMode = settingsSidebarPluginSortMode
            self.settingsSidebarCustomPluginOrder = settingsSidebarCustomPluginOrder
        }
    }

    let formatVersion: Int
    let exportedAt: Date
    let application: ApplicationPreferences
    let pluginDisplay: PluginDisplayPreferencesBackup
    let shortcutCustomizations: [String: ShortcutCustomization]
    let actionShortcutAssignments: [ActionShortcutAssignmentRecord]
    private(set) var actionShortcutAssignmentsWereEncoded = true
    let pluginPreferences: [String: Data]
    let pluginPreferenceActionReferences: [String: [ActionReference]]
    let actionInvocationPresets: [ActionInvocationPreset]?
    let workflows: [WorkflowDefinition]?
    let automationRules: [AutomationRule]?
    let selection: PreferencesBackupSelection?

    init(
        application: ApplicationPreferences,
        pluginDisplay: PluginDisplayPreferencesBackup,
        shortcutCustomizations: [String: ShortcutCustomization],
        actionShortcutAssignments: [ActionShortcutAssignmentRecord] = [],
        pluginPreferences: [String: Data] = [:],
        pluginPreferenceActionReferences: [String: [ActionReference]] = [:],
        actionInvocationPresets: [ActionInvocationPreset]? = [],
        workflows: [WorkflowDefinition]? = [],
        automationRules: [AutomationRule]? = [],
        selection: PreferencesBackupSelection? = nil,
        exportedAt: Date = .now
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.application = application
        self.pluginDisplay = pluginDisplay
        self.shortcutCustomizations = shortcutCustomizations
        self.actionShortcutAssignments = actionShortcutAssignments
        self.pluginPreferences = pluginPreferences
        self.pluginPreferenceActionReferences = pluginPreferenceActionReferences
        self.actionInvocationPresets = actionInvocationPresets
        self.workflows = workflows
        self.automationRules = automationRules
        self.selection = selection ?? .all(pluginPreferenceIDs: Set(pluginPreferences.keys))
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case exportedAt
        case application
        case pluginDisplay
        case shortcutCustomizations
        case actionShortcutAssignments
        case pluginPreferences
        case pluginPreferenceActionReferences
        case actionInvocationPresets
        case workflows
        case automationRules
        case selection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        application = try container.decode(ApplicationPreferences.self, forKey: .application)
        pluginDisplay = try container.decode(PluginDisplayPreferencesBackup.self, forKey: .pluginDisplay)
        shortcutCustomizations = try container.decode(
            [String: ShortcutCustomization].self,
            forKey: .shortcutCustomizations
        )
        actionShortcutAssignmentsWereEncoded = container.contains(.actionShortcutAssignments)
        actionShortcutAssignments = try container.decodeIfPresent(
            [ActionShortcutAssignmentRecord].self,
            forKey: .actionShortcutAssignments
        ) ?? []
        pluginPreferences = try container.decodeIfPresent(
            [String: Data].self,
            forKey: .pluginPreferences
        ) ?? [:]
        let decodedPluginPreferenceActionReferences = try container.decodeIfPresent(
            [String: [ActionReference]].self,
            forKey: .pluginPreferenceActionReferences
        )
        pluginPreferenceActionReferences = decodedPluginPreferenceActionReferences ?? [:]
        actionInvocationPresets = try container.decodeIfPresent(
            [ActionInvocationPreset].self,
            forKey: .actionInvocationPresets
        )
        workflows = try container.decodeIfPresent(
            [WorkflowDefinition].self,
            forKey: .workflows
        )
        automationRules = try container.decodeIfPresent(
            [AutomationRule].self,
            forKey: .automationRules
        )
        selection = try container.decodeIfPresent(
            PreferencesBackupSelection.self,
            forKey: .selection
        )
        if formatVersion >= 4,
           actionInvocationPresets == nil || workflows == nil || automationRules == nil {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Format 4 backups must include Run Link presets, workflows, and automation rules."
                )
            )
        }
        if formatVersion >= 5, selection == nil {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Format 5 backups must describe the selected preference categories."
                )
            )
        }
        if formatVersion >= 6, decodedPluginPreferenceActionReferences == nil {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Format 6 backups must include plugin action dependencies."
                )
            )
        }
        if formatVersion >= 6, !actionShortcutAssignmentsWereEncoded {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Format 6 backups must include action shortcut assignments."
                )
            )
        }
    }

    func validate() throws {
        guard (1 ... Self.currentFormatVersion).contains(formatVersion) else {
            throw PreferencesBackupError.unsupportedFormatVersion(formatVersion)
        }
    }

    func validateApplicationPreferences(
        using validator: (ApplicationPreferences) -> Bool
    ) throws {
        guard !effectiveSelection.includesApplicationPreferences || validator(application) else {
            throw PreferencesBackupError.invalidApplicationPreferences
        }
    }

    var effectiveSelection: PreferencesBackupSelection {
        if let selection { return selection }
        if formatVersion <= 3 {
            return PreferencesBackupSelection(
                includesApplicationPreferences: true,
                includesPluginLayout: true,
                includesShortcuts: true,
                includesAutomation: false,
                includesRunLinks: false,
                pluginPreferenceIDs: Set(pluginPreferences.keys)
            )
        }
        return .all(pluginPreferenceIDs: Set(pluginPreferences.keys))
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumFileSize else {
            throw PreferencesBackupError.fileTooLarge(maximumBytes: Self.maximumFileSize)
        }
        return data
    }

    /// Wire versions and export timestamps describe serialization, not restorable preferences.
    /// Decoding has already migrated supported formats into the same preference models.
    func hasSameMeaningfulContent(as other: PreferencesBackup) -> Bool {
        application == other.application
            && pluginDisplay == other.pluginDisplay
            && shortcutCustomizations == other.shortcutCustomizations
            && actionShortcutAssignments == other.actionShortcutAssignments
            && actionShortcutAssignmentsWereEncoded == other.actionShortcutAssignmentsWereEncoded
            && pluginPreferencesHaveSameMeaningfulContent(as: other.pluginPreferences)
            && pluginPreferenceActionReferences == other.pluginPreferenceActionReferences
            && actionInvocationPresets == other.actionInvocationPresets
            && workflows == other.workflows
            && automationRules == other.automationRules
            && selection == other.selection
    }

    private func pluginPreferencesHaveSameMeaningfulContent(
        as other: [String: Data]
    ) -> Bool {
        guard pluginPreferences.count == other.count else { return false }
        return pluginPreferences.allSatisfy { pluginID, data in
            guard let otherData = other[pluginID] else { return false }
            if data == otherData { return true }
            guard let value = try? JSONSerialization.jsonObject(with: data),
                  let otherValue = try? JSONSerialization.jsonObject(with: otherData),
                  JSONSerialization.isValidJSONObject(value),
                  JSONSerialization.isValidJSONObject(otherValue),
                  let canonicalData = try? JSONSerialization.data(
                      withJSONObject: value,
                      options: [.sortedKeys]
                  ),
                  let canonicalOtherData = try? JSONSerialization.data(
                      withJSONObject: otherValue,
                      options: [.sortedKeys]
                  )
            else {
                return false
            }
            return canonicalData == canonicalOtherData
        }
    }

    static func decodeJSON(_ data: Data) throws -> PreferencesBackup {
        do {
            return try PreferencesArchiveDocument.decodeJSON(data).backup
        } catch let validationError as PreferencesBackupError {
            throw validationError
        } catch {
            return try decodePayloadJSON(data)
        }
    }

    static func decodePayloadJSON(_ data: Data) throws -> PreferencesBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(PreferencesBackup.self, from: data)
        try backup.validate()
        return backup
    }

    static func decodeJSON(
        contentsOf url: URL,
        maximumFileSize: Int = maximumFileSize
    ) async throws -> PreferencesBackup {
        try await Task.detached(priority: .userInitiated) {
            let data = try Self.readFile(at: url, maximumSize: maximumFileSize)
            return try Self.decodeJSON(data)
        }.value
    }

    static func readFile(at url: URL, maximumSize: Int = maximumFileSize) throws -> Data {
        precondition(maximumSize > 0)

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        var data = Data()
        data.reserveCapacity(maximumSize + 1)

        while data.count <= maximumSize {
            let remainingByteCount = maximumSize + 1 - data.count
            guard let chunk = try file.read(upToCount: min(64 * 1024, remainingByteCount)),
                  !chunk.isEmpty
            else {
                break
            }

            data.append(chunk)
        }

        guard data.count <= maximumSize else {
            throw PreferencesBackupError.fileTooLarge(maximumBytes: maximumSize)
        }

        return data
    }
}

struct PreferencesBackupSelection: Codable, Equatable, Sendable {
    var includesApplicationPreferences: Bool
    var includesPluginLayout: Bool
    var includesShortcuts: Bool
    var includesAutomation: Bool
    var includesRunLinks: Bool
    var pluginPreferenceIDs: Set<String>

    static func all(pluginPreferenceIDs: Set<String>) -> Self {
        Self(
            includesApplicationPreferences: true,
            includesPluginLayout: true,
            includesShortcuts: true,
            includesAutomation: true,
            includesRunLinks: true,
            pluginPreferenceIDs: pluginPreferenceIDs
        )
    }

    var isEmpty: Bool {
        !includesApplicationPreferences
            && !includesPluginLayout
            && !includesShortcuts
            && !includesAutomation
            && !includesRunLinks
            && pluginPreferenceIDs.isEmpty
    }

    func intersecting(_ available: Self) -> Self {
        Self(
            includesApplicationPreferences: includesApplicationPreferences
                && available.includesApplicationPreferences,
            includesPluginLayout: includesPluginLayout && available.includesPluginLayout,
            includesShortcuts: includesShortcuts && available.includesShortcuts,
            includesAutomation: includesAutomation && available.includesAutomation,
            includesRunLinks: includesRunLinks && available.includesRunLinks,
            pluginPreferenceIDs: pluginPreferenceIDs.intersection(available.pluginPreferenceIDs)
        )
    }
}

struct PluginDisplayPreferencesBackup: Codable, Equatable, Sendable {
    let orderedPluginIDs: [String]
    /// Read-only compatibility fields for pre-multiview backup payloads.
    let hiddenPluginIDs: [String]
    let dashboardOrderedPluginIDs: [String]?
    let featurePanelOrderedPluginIDs: [String]?
    let dashboardHiddenPluginIDs: [String]?
    let featurePanelHiddenPluginIDs: [String]?
    let panelConfiguration: MenuBarPanelConfiguration?

    private enum CodingKeys: String, CodingKey {
        case orderedPluginIDs, hiddenPluginIDs, dashboardOrderedPluginIDs, featurePanelOrderedPluginIDs
        case dashboardHiddenPluginIDs, featurePanelHiddenPluginIDs, panelConfiguration
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        orderedPluginIDs = try values.decodeIfPresent([String].self, forKey: .orderedPluginIDs) ?? []
        hiddenPluginIDs = try values.decodeIfPresent([String].self, forKey: .hiddenPluginIDs) ?? []
        dashboardOrderedPluginIDs = try values.decodeIfPresent([String].self, forKey: .dashboardOrderedPluginIDs)
        featurePanelOrderedPluginIDs = try values.decodeIfPresent([String].self, forKey: .featurePanelOrderedPluginIDs)
        dashboardHiddenPluginIDs = try values.decodeIfPresent([String].self, forKey: .dashboardHiddenPluginIDs)
        featurePanelHiddenPluginIDs = try values.decodeIfPresent([String].self, forKey: .featurePanelHiddenPluginIDs)
        struct Version: Decodable { let version: Int }
        if let version = try values.decodeIfPresent(Version.self, forKey: .panelConfiguration), version.version < 3 {
            let legacy = try values.decode(LegacyPanelLayout.self, forKey: .panelConfiguration)
            let preferences = Self(orderedPluginIDs: orderedPluginIDs, hiddenPluginIDs: hiddenPluginIDs,
                dashboardOrderedPluginIDs: dashboardOrderedPluginIDs,
                featurePanelOrderedPluginIDs: featurePanelOrderedPluginIDs,
                dashboardHiddenPluginIDs: dashboardHiddenPluginIDs,
                featurePanelHiddenPluginIDs: featurePanelHiddenPluginIDs)
            panelConfiguration = PanelLayoutMigrator.migrate(legacy,
                preferences: LegacyPanelDisplayPreferences(backup: preferences))
        } else {
            panelConfiguration = try values.decodeIfPresent(MenuBarPanelConfiguration.self, forKey: .panelConfiguration)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(orderedPluginIDs, forKey: .orderedPluginIDs)
        try values.encodeIfPresent(panelConfiguration, forKey: .panelConfiguration)
        // Current exports always have a canonical layout. Preserve a legacy
        // envelope when re-encoding an old backup before importing it.
        if panelConfiguration == nil {
            try values.encode(hiddenPluginIDs, forKey: .hiddenPluginIDs)
            try values.encodeIfPresent(dashboardOrderedPluginIDs, forKey: .dashboardOrderedPluginIDs)
            try values.encodeIfPresent(featurePanelOrderedPluginIDs, forKey: .featurePanelOrderedPluginIDs)
            try values.encodeIfPresent(dashboardHiddenPluginIDs, forKey: .dashboardHiddenPluginIDs)
            try values.encodeIfPresent(featurePanelHiddenPluginIDs, forKey: .featurePanelHiddenPluginIDs)
        }
    }

    init(
        orderedPluginIDs: [String],
        hiddenPluginIDs: [String],
        dashboardOrderedPluginIDs: [String]? = nil,
        featurePanelOrderedPluginIDs: [String]? = nil,
        dashboardHiddenPluginIDs: [String]? = nil,
        featurePanelHiddenPluginIDs: [String]? = nil,
        panelConfiguration: MenuBarPanelConfiguration? = nil
    ) {
        self.orderedPluginIDs = orderedPluginIDs
        self.hiddenPluginIDs = hiddenPluginIDs
        self.dashboardOrderedPluginIDs = dashboardOrderedPluginIDs
        self.featurePanelOrderedPluginIDs = featurePanelOrderedPluginIDs
        self.dashboardHiddenPluginIDs = dashboardHiddenPluginIDs
        self.featurePanelHiddenPluginIDs = featurePanelHiddenPluginIDs
        self.panelConfiguration = panelConfiguration
    }
}

struct PreferencesImportPreview: Equatable {
    let pluginCount: Int
    let unavailablePluginIDs: [String]
    let shortcutCount: Int
    let unavailableShortcutIDs: [String]
    let unavailableActionReferences: [ActionReference]
    let retainedUnavailableActionReferences: [ActionReference]
    let installablePlugins: [PreferencesImportInstallablePlugin]
    let selection: PreferencesBackupSelection

    var installableMissingPluginIDs: [String] {
        installablePlugins.map(\.id)
    }

    static func make(
        backup: PreferencesBackup,
        availablePluginIDs: Set<String>,
        availableShortcutIDs: Set<String>,
        availableActionReferences: Set<ActionReference> = [],
        additionalActionReferences: [ActionReference] = [],
        actionReferenceCanResolve: ((ActionReference) -> Bool)? = nil,
        actionReferenceIsRestorable: (ActionReference) -> Bool = { _ in true },
        pluginManagementItems: [PluginManagementItem],
        selection requestedSelection: PreferencesBackupSelection? = nil,
        applicationPreferencesAreValid: (PreferencesBackup.ApplicationPreferences) -> Bool
    ) throws -> PreferencesImportPreview {
        try backup.validate()
        let availableSelection = backup.effectiveSelection
        let selection = (requestedSelection ?? availableSelection).intersecting(availableSelection)
        if selection.includesApplicationPreferences,
           !applicationPreferencesAreValid(backup.application) {
            throw PreferencesBackupError.invalidApplicationPreferences
        }

        let displayPluginIDs: Set<String> = selection.includesPluginLayout
            ? Set(backup.pluginDisplay.orderedPluginIDs)
            .union(backup.pluginDisplay.hiddenPluginIDs)
            .union(backup.pluginDisplay.dashboardOrderedPluginIDs ?? [])
            .union(backup.pluginDisplay.featurePanelOrderedPluginIDs ?? [])
            .union(backup.pluginDisplay.dashboardHiddenPluginIDs ?? [])
            .union(backup.pluginDisplay.featurePanelHiddenPluginIDs ?? [])
            .union(backup.pluginDisplay.panelConfiguration?.placementsByPanelID.values.flatMap { $0.map(\.item.pluginID) } ?? [])
            .union(backup.pluginDisplay.panelConfiguration?.legacySeed?.pluginIDs ?? [])
            : []
        let selectedActionReferences = (selection.includesShortcuts
            ? backup.actionShortcutAssignments.map(\.reference)
            : [])
            + (selection.includesRunLinks
                ? (backup.actionInvocationPresets ?? []).map(\.reference)
                : [])
            + (selection.includesAutomation
                ? (backup.workflows ?? []).flatMap { $0.steps.map(\.reference) }
                : [])
            + additionalActionReferences
        let actionPluginIDs: Set<String> = Set(selectedActionReferences.compactMap { reference -> String? in
            switch reference.key.providerID {
            case "mactools", AutomationController.providerID:
                return nil
            default:
                return reference.key.providerID
            }
        })
        let backedUpPluginIDs = displayPluginIDs
            .union(selection.pluginPreferenceIDs.intersection(backup.pluginPreferences.keys))
            .union(actionPluginIDs)
        let missingPluginIDs = backedUpPluginIDs.subtracting(availablePluginIDs)
        let managementItemsByID = Dictionary(
            pluginManagementItems.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let installablePlugins = missingPluginIDs.compactMap { pluginID -> PreferencesImportInstallablePlugin? in
            guard let item = managementItemsByID[pluginID], item.canInstall else { return nil }
            return PreferencesImportInstallablePlugin(
                id: item.id,
                title: item.title,
                summary: item.summary,
                version: item.version
            )
        }
        let installablePluginIDs = Set(installablePlugins.map(\.id))
        let compatibilityShortcutIDs: Set<String> = selection.includesShortcuts ? Set(
            backup.actionShortcutAssignments.compactMap { assignment in
                assignment.reference.key.providerID == "mactools"
                    ? assignment.reference.key.actionID
                    : nil
            }
        ) : []
        let backedUpShortcutIDs: Set<String> = (selection.includesShortcuts
            ? Set(backup.shortcutCustomizations.keys)
            : [])
            .subtracting(compatibilityShortcutIDs)
        let canResolve = actionReferenceCanResolve
            ?? { availableActionReferences.contains($0) }
        let availableActionCount = (selection.includesShortcuts ? backup.actionShortcutAssignments : []).filter {
            canResolve($0.reference)
        }.count
        let unavailableActionReferences = Array(Set(
            selectedActionReferences.filter { !actionReferenceIsRestorable($0) }
        )).sorted { lhs, rhs in
            if lhs.key.providerID != rhs.key.providerID {
                return lhs.key.providerID < rhs.key.providerID
            }
            return lhs.key.actionID < rhs.key.actionID
        }
        let retainedUnavailableActionReferences = Array(Set(
            selectedActionReferences.filter {
                actionReferenceIsRestorable($0) && !canResolve($0)
            }
        )).sorted { lhs, rhs in
            if lhs.key.providerID != rhs.key.providerID {
                return lhs.key.providerID < rhs.key.providerID
            }
            return lhs.key.actionID < rhs.key.actionID
        }
        return PreferencesImportPreview(
            pluginCount: backedUpPluginIDs.intersection(availablePluginIDs).count,
            unavailablePluginIDs: missingPluginIDs.subtracting(installablePluginIDs).sorted(),
            shortcutCount: backedUpShortcutIDs.intersection(availableShortcutIDs).count
                + availableActionCount,
            unavailableShortcutIDs: backedUpShortcutIDs.subtracting(availableShortcutIDs).sorted(),
            unavailableActionReferences: unavailableActionReferences,
            retainedUnavailableActionReferences: retainedUnavailableActionReferences,
            installablePlugins: installablePlugins.sorted { $0.title.localizedCompare($1.title) == .orderedAscending },
            selection: selection
        )
    }
}

struct PreferencesImportInstallablePlugin: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String?
    let version: String
}

struct PreferencesImportResult: Equatable {
    let installedPluginIDs: [String]
    let deferredPluginPreferenceIDs: [String]
    let pluginInstallationFailures: [String: String]
    let shortcutErrors: [String: String]

    init(
        installedPluginIDs: [String],
        deferredPluginPreferenceIDs: [String] = [],
        pluginInstallationFailures: [String: String],
        shortcutErrors: [String: String]
    ) {
        self.installedPluginIDs = installedPluginIDs
        self.deferredPluginPreferenceIDs = deferredPluginPreferenceIDs
        self.pluginInstallationFailures = pluginInstallationFailures
        self.shortcutErrors = shortcutErrors
    }
}

enum PreferencesBackupError: Error, Equatable {
    case unsupportedFormatVersion(Int)
    case invalidApplicationPreferences
    case fileTooLarge(maximumBytes: Int)
}

@MainActor
protocol PreferencesBackupApplicationStoring: AnyObject {
    var preferencesBackupChangeReporter: PreferencesBackupChangeReporter? { get set }

    func applicationPreferences() -> PreferencesBackup.ApplicationPreferences
    func validates(_ preferences: PreferencesBackup.ApplicationPreferences) -> Bool
    func apply(_ preferences: PreferencesBackup.ApplicationPreferences)
    func setAppearancePreference(rawValue: String) -> Bool
    func setFloatingPanelAppearance(rawValue: String) -> Bool
    func setLanguagePreference(rawValue: String) -> Bool
}
