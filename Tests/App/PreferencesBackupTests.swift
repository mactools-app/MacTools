import Carbon.HIToolbox
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import SystemStatusPlugin

@MainActor
final class PreferencesBackupTests: XCTestCase {
    private let suiteName = "PreferencesBackupTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testExportContainsOnlyPortableHostAndKnownPluginPreferences() throws {
        let defaults = makeDefaults()
        defaults.set(AppAppearancePreference.dark.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
        defaults.set(
            PluginFloatingPanelAppearance.solid.rawValue,
            forKey: PluginFloatingPanelAppearance.userDefaultsKey
        )
        defaults.set(AppLanguagePreference.en.rawValue, forKey: AppLanguagePreference.userDefaultsKey)
        defaults.set("swapped", forKey: MenuBarPanelStore.legacyClickBehaviorStorageKey)
        SettingsSidebarPreferencesStore.applyImportedPreferences(
            sortMode: .custom,
            customOrderedPluginIDs: ["second", "first"],
            to: defaults
        )
        defaults.set("api-key-value", forKey: "translator.apiKey")

        let firstPlugin = BackupTestPlugin(id: "first", order: 1, shortcutID: "toggle")
        let secondPlugin = BackupTestPlugin(id: "second", order: 2, shortcutID: "open")
        PluginOrderingStore(userDefaults: defaults).setOrderedPluginIDs(
            [secondPlugin.metadata.id, firstPlugin.metadata.id], defaultPluginIDs: ["first", "second"])
        let host = makeHost(plugins: [firstPlugin, secondPlugin], defaults: defaults)
        host.setShortcutBinding(
            ShortcutBinding(keyCode: 12, modifiers: [.command, .shift]),
            for: "first.shortcut.toggle"
        )
        let openSettingsBinding = ShortcutBinding(keyCode: 13, modifiers: [.command, .option])
        XCTAssertNil(host.setAppShortcutBindingAndReturnError(openSettingsBinding, for: .openSettings))

        let backup = host.makePreferencesBackup()
        let decodedBackup = try PreferencesBackup.decodeJSON(backup.encodedJSON())

        XCTAssertEqual(decodedBackup.formatVersion, PreferencesBackup.currentFormatVersion)
        XCTAssertEqual(decodedBackup.application, backup.application)
        XCTAssertEqual(decodedBackup.pluginDisplay, backup.pluginDisplay)
        XCTAssertEqual(decodedBackup.shortcutCustomizations, backup.shortcutCustomizations)
        XCTAssertEqual(backup.application.appearancePreference, AppAppearancePreference.dark.rawValue)
        XCTAssertEqual(
            backup.application.floatingPanelAppearance,
            PluginFloatingPanelAppearance.solid.rawValue
        )
        XCTAssertEqual(backup.application.languagePreference, AppLanguagePreference.en.rawValue)
        XCTAssertNil(backup.application.menuBarClickBehavior)
        XCTAssertEqual(backup.pluginDisplay.panelConfiguration?.panels.map(\.id), ["features", "components"])
        XCTAssertNil(defaults.object(forKey: MenuBarPanelStore.legacyClickBehaviorStorageKey))
        XCTAssertEqual(
            backup.application.settingsSidebarPluginSortMode,
            SettingsSidebarPluginSortMode.custom.rawValue
        )
        XCTAssertEqual(
            backup.application.settingsSidebarCustomPluginOrder,
            ["second", "first"]
        )
        XCTAssertEqual(backup.pluginDisplay.orderedPluginIDs, ["second", "first"])
        XCTAssertTrue(backup.pluginDisplay.hiddenPluginIDs.isEmpty)
        XCTAssertNil(backup.pluginDisplay.dashboardOrderedPluginIDs)
        XCTAssertNil(backup.pluginDisplay.featurePanelOrderedPluginIDs)
        XCTAssertEqual(backup.pluginDisplay.panelConfiguration, host.menuBarPanelStore.configuration)
        XCTAssertEqual(
            backup.shortcutCustomizations["first.shortcut.toggle"],
            .custom(ShortcutBinding(keyCode: 12, modifiers: [.command, .shift]))
        )
        XCTAssertEqual(backup.shortcutCustomizations["app.open-settings"], .custom(openSettingsBinding))
        XCTAssertNil(backup.shortcutCustomizations["second.shortcut.open"])
        XCTAssertFalse(try XCTUnwrap(String(data: backup.encodedJSON(), encoding: .utf8)).contains("api-key-value"))
    }

    func testPortablePluginPreferencesRoundTripThroughBackup() throws {
        let portableData = Data("sidecar-portable-settings".utf8)
        let sourcePlugin = BackupTestPlugin(
            id: "sidecar",
            order: 1,
            shortcutID: "toggle",
            portablePreferences: portableData
        )
        let sourceHost = makeHost(plugins: [sourcePlugin], defaults: makeDefaults())

        let backup = sourceHost.makePreferencesBackup()
        XCTAssertEqual(backup.pluginPreferences["sidecar"], portableData)

        let restoredPlugin = BackupTestPlugin(id: "sidecar", order: 1, shortcutID: "toggle")
        let restoredHost = makeHost(plugins: [restoredPlugin], defaults: makeDefaults())
        _ = try restoredHost.importPreferences(backup)

        XCTAssertEqual(restoredPlugin.restoredPortablePreferences, portableData)
    }

    func testSelectiveExportContainsOnlyChosenCategoriesAndPluginSettings() throws {
        let defaults = makeDefaults()
        let first = BackupTestPlugin(
            id: "first",
            order: 1,
            shortcutID: "toggle",
            portablePreferences: Data("first".utf8)
        )
        let second = BackupTestPlugin(
            id: "second",
            order: 2,
            shortcutID: "open",
            portablePreferences: Data("second".utf8)
        )
        let host = makeHost(plugins: [first, second], defaults: defaults)
        let selection = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: false,
            includesAutomation: false,
            includesRunLinks: false,
            pluginPreferenceIDs: ["first"]
        )

        let backup = host.makePreferencesBackup(selection: selection)
        let decoded = try PreferencesBackup.decodeJSON(backup.encodedJSON())

        XCTAssertEqual(decoded.effectiveSelection, selection)
        XCTAssertEqual(decoded.pluginPreferences, ["first": Data("first".utf8)])
        XCTAssertTrue(decoded.shortcutCustomizations.isEmpty)
        XCTAssertTrue(decoded.actionShortcutAssignments.isEmpty)
        XCTAssertEqual(decoded.actionInvocationPresets, [])
        XCTAssertEqual(decoded.workflows, [])
        XCTAssertEqual(decoded.automationRules, [])
    }

    func testSelectiveImportRestoresOnlyChosenPluginSettings() throws {
        let first = BackupTestPlugin(id: "first", order: 1, shortcutID: "toggle")
        let second = BackupTestPlugin(id: "second", order: 2, shortcutID: "open")
        let host = makeHost(plugins: [first, second], defaults: makeDefaults())
        let entry = try XCTUnwrap(host.panelEntries(in: "features").first)
        _ = host.setPanelItemWidth(.custom(720), entry: entry)
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["second", "first"],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:],
            pluginPreferences: [
                "first": Data("restore-first".utf8),
                "second": Data("restore-second".utf8),
            ]
        )
        let selection = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: false,
            includesAutomation: false,
            includesRunLinks: false,
            pluginPreferenceIDs: ["first"]
        )

        _ = try host.importPreferences(backup, selection: selection)

        XCTAssertEqual(first.restoredPortablePreferences, Data("restore-first".utf8))
        XCTAssertNil(second.restoredPortablePreferences)
        XCTAssertEqual(host.pluginSettingsItems.map(\.pluginID), ["first", "second"])
        XCTAssertEqual(host.panelItems(in: "features").first?.width, .custom(720))
    }

    func testRunLinkPresetsWorkflowsAndRulesRoundTripThroughBackup() throws {
        let plugin = BackupActionProviderPlugin()
        let portableReference = try XCTUnwrap(plugin.references().first)
        let workflow = WorkflowDefinition(
            id: UUID(),
            name: "Morning Setup",
            systemImage: "sunrise",
            isEnabled: true,
            steps: []
        )
        let rule = AutomationRule(
            id: UUID(),
            name: "Weekday Morning",
            workflowID: workflow.id,
            isEnabled: true,
            trigger: .schedule(.init(hour: 9, minute: 0, weekdays: [2, 3, 4, 5, 6])),
            conditions: []
        )
        let preset = ActionInvocationPreset(
            id: UUID(),
            reference: portableReference,
            createdAt: Date(timeIntervalSince1970: 123)
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:],
            pluginPreferences: [plugin.metadata.id: Data("provider-settings".utf8)],
            actionInvocationPresets: [preset],
            workflows: [workflow],
            automationRules: [rule]
        )

        let host = makeHost(plugins: [plugin], defaults: makeDefaults())
        let result = try host.importPreferences(backup)
        XCTAssertTrue(result.shortcutErrors.isEmpty)

        let restored = host.makePreferencesBackup()
        XCTAssertEqual(restored.actionInvocationPresets, [preset])
        XCTAssertEqual(restored.workflows, [workflow])
        XCTAssertEqual(restored.automationRules, [rule])
    }

    func testExportExcludesKnownLocalAndSensitiveActionReferencesAcrossFeatures() throws {
        let plugin = BackupActionProviderPlugin()
        let host = makeHost(plugins: [plugin], defaults: makeDefaults())
        let references = try plugin.references()

        for (offset, reference) in references.enumerated() {
            let result = host.setActionShortcutBinding(
                ShortcutBinding(keyCode: UInt16(30 + offset), modifiers: [.command, .control]),
                to: reference
            )
            guard case .success = result else {
                return XCTFail("Expected action shortcut assignment for \(reference.key.actionID)")
            }
        }

        guard case .success = host.createActionRunLink(for: references[0]),
              case .success = host.createActionRunLink(for: references[1]) else {
            return XCTFail("Expected portable and local Run Link presets to be created")
        }
        guard case .failure(.sensitiveParametersUnsupported) = host.createActionRunLink(
            for: references[2]
        ) else {
            return XCTFail("Sensitive Run Link presets must be rejected at creation time")
        }

        var workflowIDs: [UUID] = []
        var ruleIDs: [UUID] = []
        for reference in references {
            let workflow = try XCTUnwrap(host.automationController.createWorkflow())
            host.automationController.addStep(workflowID: workflow.id, reference: reference)
            let rule = try XCTUnwrap(
                host.automationController.createRule(workflowID: workflow.id)
            )
            workflowIDs.append(workflow.id)
            ruleIDs.append(rule.id)
        }
        let localChild = try XCTUnwrap(
            host.automationController.workflows.first { $0.id == workflowIDs[1] }
        )
        let nestedParent = try XCTUnwrap(host.automationController.createWorkflow())
        host.automationController.addStep(
            workflowID: nestedParent.id,
            reference: localChild.actionReference
        )
        let nestedRule = try XCTUnwrap(
            host.automationController.createRule(workflowID: nestedParent.id)
        )
        workflowIDs.append(nestedParent.id)
        ruleIDs.append(nestedRule.id)
        let nestedShortcutResult = host.setActionShortcutBinding(
            ShortcutBinding(keyCode: 40, modifiers: [.command, .control]),
            to: nestedParent.actionReference
        )
        guard case .success = nestedShortcutResult else {
            return XCTFail("Expected nested workflow shortcut, got \(nestedShortcutResult)")
        }

        let backup = host.makePreferencesBackup()

        XCTAssertEqual(backup.actionShortcutAssignments.map(\.reference), [references[0]])
        XCTAssertEqual(backup.actionInvocationPresets?.map(\.reference), [references[0]])
        XCTAssertEqual(backup.workflows?.map(\.id), [workflowIDs[0]])
        XCTAssertEqual(backup.automationRules?.map(\.id), [ruleIDs[0]])
    }

    func testImportDropsDeviceLocalDisplayAndCalendarRulesFromEditedBackup() throws {
        let provider = BackupActionProviderPlugin()
        let host = makeHost(plugins: [provider], defaults: makeDefaults())
        let workflow = WorkflowDefinition(
            name: "Imported",
            steps: [WorkflowStep(reference: try provider.references()[0])]
        )
        let portableRule = AutomationRule(
            name: "Portable",
            workflowID: workflow.id,
            trigger: .display(DisplayAutomationTrigger(
                event: .connected,
                displayNameContains: "Studio"
            ))
        )
        let localRule = AutomationRule(
            name: "Local",
            workflowID: workflow.id,
            trigger: .display(DisplayAutomationTrigger(
                event: .connected,
                displayIdentifier: "742311"
            ))
        )
        let localCalendarRule = AutomationRule(
            name: "Local Calendar",
            workflowID: workflow.id,
            trigger: .calendar(CalendarAutomationTrigger(
                phase: .starts,
                calendarIdentifier: "eventkit-calendar-id"
            ))
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:],
            pluginPreferences: [provider.metadata.id: Data("provider-settings".utf8)],
            workflows: [workflow],
            automationRules: [portableRule, localRule, localCalendarRule]
        )

        _ = try host.importPreferences(backup)

        XCTAssertEqual(host.automationController.rules.map(\.id), [portableRule.id])
    }

    func testCurrentImportRejectsNewShortcutConflictWithoutPartiallyApplyingState() throws {
        let ordinary = BackupTestPlugin(id: "ordinary", order: 1, shortcutID: "toggle")
        let actionProvider = BackupActionProviderPlugin()
        let host = makeHost(plugins: [ordinary, actionProvider], defaults: makeDefaults())
        let binding = ShortcutBinding(keyCode: 19, modifiers: [.command, .option])
        let reference = try actionProvider.references()[0]
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: ["ordinary.shortcut.toggle": .custom(binding)],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: reference,
                binding: binding
            )],
            pluginPreferences: [
                actionProvider.metadata.id: Data("provider-settings".utf8),
            ]
        )

        let result = try host.importPreferences(backup)

        XCTAssertNotNil(result.shortcutErrors["action-shortcuts"])
        XCTAssertNil(host.shortcutAssignmentService.assignment(for: reference))
        XCTAssertFalse(
            host.shortcutItems.first { $0.id == "ordinary.shortcut.toggle" }?.canClear ?? true
        )
    }

    func testFailedProviderRestoreDropsAllDependentImportedReferences() throws {
        let provider = BackupPreferenceDefinedActionPlugin()
        provider.shouldFailRestore = true
        let surface = BackupActionSurfacePlugin()
        let host = makeHost(plugins: [provider, surface], defaults: makeDefaults())
        let workflow = WorkflowDefinition(
            name: "Provider Dependent",
            steps: [WorkflowStep(reference: provider.reference)]
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: provider.reference,
                binding: ShortcutBinding(keyCode: 45, modifiers: [.command, .control])
            )],
            pluginPreferences: [
                provider.metadata.id: Data("enabled".utf8),
                surface.metadata.id: try JSONEncoder().encode([
                    provider.reference,
                    workflow.actionReference,
                ]),
            ],
            actionInvocationPresets: [
                ActionInvocationPreset(reference: provider.reference),
                ActionInvocationPreset(reference: workflow.actionReference),
            ],
            workflows: [workflow]
        )

        let result = try host.importPreferences(backup)

        XCTAssertEqual(
            Set(result.shortcutErrors.keys),
            [
                "plugin-preferences.\(provider.metadata.id)",
                "plugin-preferences.\(surface.metadata.id)",
            ]
        )
        XCTAssertTrue(host.shortcutAssignmentService.assignments.isEmpty)
        XCTAssertTrue(host.automationController.workflows.isEmpty)
        XCTAssertTrue(surface.references.isEmpty)
        XCTAssertTrue(host.makePreferencesBackup().actionInvocationPresets?.isEmpty ?? true)
    }

    func testExportMigratesOlderRunLinkSchemaBeforePortabilityFiltering() throws {
        let plugin = BackupMigratingActionPlugin()
        let legacyReference = try plugin.legacyReference()
        let currentReference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let legacyPreset = ActionInvocationPreset(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000471")!,
            reference: legacyReference,
            createdAt: Date(timeIntervalSince1970: 471)
        )
        let currentPreset = ActionInvocationPreset(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000472")!,
            reference: currentReference,
            createdAt: Date(timeIntervalSince1970: 472)
        )
        let sourceDefaults = makeDefaults()
        sourceDefaults.set(
            try JSONEncoder().encode(
                BackupActionPresetEnvelope(
                    formatVersion: ActionInvocationPreset.currentFormatVersion,
                    presets: [legacyPreset, currentPreset]
                )
            ),
            forKey: "actions.run-link-presets.v1"
        )
        let sourceHost = makeHost(plugins: [plugin], defaults: sourceDefaults)

        let encodedBackup = try sourceHost.makePreferencesBackup().encodedJSON()
        let decodedBackup = try PreferencesBackup.decodeJSON(encodedBackup)
        let exportedPresets = try XCTUnwrap(decodedBackup.actionInvocationPresets)
        XCTAssertEqual(exportedPresets.map(\.id), [legacyPreset.id, currentPreset.id])
        XCTAssertEqual(exportedPresets.map(\.createdAt), [legacyPreset.createdAt, currentPreset.createdAt])
        XCTAssertEqual(Set(exportedPresets.map(\.reference)), [currentReference])
        XCTAssertTrue(exportedPresets.allSatisfy { $0.reference.schemaVersion == 2 })
        XCTAssertTrue(exportedPresets.allSatisfy {
            $0.reference.parameters["value"] == .string("legacy")
        })

        let restoredHost = makeHost(
            plugins: [BackupMigratingActionPlugin()],
            defaults: makeDefaults()
        )
        _ = try restoredHost.importPreferences(decodedBackup)

        XCTAssertEqual(
            restoredHost.makePreferencesBackup().actionInvocationPresets,
            exportedPresets
        )
    }

    func testPreviewAndInstallIncludeRunLinkAndWorkflowOnlyPluginDependencies() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreferencesBackupActionDependencyTests-\(UUID().uuidString)", isDirectory: true)
        let defaultsName = "PreferencesBackupActionDependencyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let pluginIDs = ["run-link-only", "surface-only", "workflow-only"]
        var packagesByID: [String: URL] = [:]
        for pluginID in pluginIDs {
            packagesByID[pluginID] = try makeDynamicPluginPackage(
                at: temporaryRoot,
                id: pluginID,
                version: "1.0.0"
            )
        }
        let packageStore = PluginPackageStore(
            rootDirectory: temporaryRoot.appending(path: "Installed", directoryHint: .isDirectory),
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        let dynamicManager = DynamicPluginManager(
            packageStore: packageStore,
            pluginLoader: BackupDynamicPluginLoader()
        )
        let catalogManager = PluginCatalogManager(
            catalogProvider: BackupCatalogProvider(
                entries: pluginIDs.map { makeCatalogEntry(id: $0, version: "1.0.0") }
            ),
            packageResolver: BackupPackageResolver(packagesByID: packagesByID),
            dynamicPluginManager: dynamicManager,
            source: .production(URL(string: "https://example.com/catalog.json")!)
        )
        let surface = BackupActionSurfacePlugin()
        let host = PluginHost(
            plugins: [surface],
            dynamicPluginManager: dynamicManager,
            pluginCatalogManager: catalogManager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            loadDynamicPluginsOnInit: false
        )
        let runLinkReference = ActionReference(
            key: ActionKey(providerID: "run-link-only", actionID: "run")
        )
        let workflowReference = ActionReference(
            key: ActionKey(providerID: "workflow-only", actionID: "run")
        )
        let surfaceReference = ActionReference(
            key: ActionKey(providerID: "surface-only", actionID: "run")
        )
        let surfacePayload = try JSONEncoder().encode([surfaceReference])
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            pluginPreferences: [surface.metadata.id: surfacePayload],
            pluginPreferenceActionReferences: [surface.metadata.id: [surfaceReference]],
            actionInvocationPresets: [
                ActionInvocationPreset(id: UUID(), reference: runLinkReference, createdAt: .now),
            ],
            workflows: [
                WorkflowDefinition(
                    name: "Plugin Workflow",
                    steps: [WorkflowStep(reference: workflowReference)]
                ),
            ]
        )

        await host.refreshPluginCatalog()
        let preview = try host.preferencesImportPreview(for: backup)

        XCTAssertEqual(preview.installablePlugins.map(\.id).sorted(), pluginIDs)
        XCTAssertTrue(preview.unavailablePluginIDs.isEmpty)

        let withoutSurface = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: false,
            includesAutomation: true,
            includesRunLinks: true,
            pluginPreferenceIDs: []
        )
        let selectivePreview = try host.preferencesImportPreview(
            for: backup,
            selection: withoutSurface
        )
        XCTAssertEqual(
            selectivePreview.installablePlugins.map(\.id).sorted(),
            ["run-link-only", "workflow-only"]
        )

        let result = try await host.importPreferences(
            backup,
            installingMissingPluginIDs: Set(pluginIDs)
        )
        XCTAssertEqual(result.installedPluginIDs, pluginIDs)
        XCTAssertTrue(result.pluginInstallationFailures.isEmpty)
    }

    func testExportAndImportPreserveSurfaceDisplayOrders() throws {
        let sourceDefaults = makeDefaults()
        let sourceHost = makeHost(
            plugins: [
                BackupCombinedPlugin(id: "first", order: 1, shortcutID: "toggle"),
                BackupCombinedPlugin(id: "second", order: 2, shortcutID: "open"),
                BackupCombinedPlugin(id: "third", order: 3, shortcutID: "show")
            ],
            defaults: sourceDefaults
        )
        sourceHost.reorderTestItem(pluginID: "third", kind: .widget, toOffset: 0)
        sourceHost.reorderTestItem(pluginID: "second", kind: .row, toOffset: 0)
        sourceHost.removeTestItem(pluginID: "first", kind: .widget)
        sourceHost.removeTestItem(pluginID: "third", kind: .row)

        _ = sourceHost.setMenuBarPanelWidth(1200)
        var layout = sourceHost.menuBarPanelStore.configuration
        layout.placementsByPanelID["features"]?[0].presentation = "compact-switch"
        layout.placementsByPanelID["features"]?[0].width = .custom(720)
        layout.placementsByPanelID["features"]?[1].width = .fill
        layout.placementsByPanelID["features", default: []].append(.init(
            item: .init(pluginID: "missing", itemID: "control"), presentation: "future-presentation",
            width: .init(mode: "future-width", points: 840)))
        layout = layout.normalized()
        XCTAssertTrue(sourceHost.menuBarPanelStore.replace(layout))
        let backup = try PreferencesBackup.decodeJSON(sourceHost.makePreferencesBackup().encodedJSON())
        let cloud = CloudPreferencesSnapshot(generation: 1, deviceID: "source", deviceName: "Source", backup: backup)
        XCTAssertEqual(try CloudPreferencesSnapshot.decodeJSON(cloud.encodedJSON()).backup.pluginDisplay.panelConfiguration, layout)


        XCTAssertEqual(backup.pluginDisplay.panelConfiguration, sourceHost.menuBarPanelStore.configuration)
        XCTAssertNil(backup.pluginDisplay.dashboardOrderedPluginIDs)
        XCTAssertNil(backup.pluginDisplay.featurePanelOrderedPluginIDs)

        let targetDefaults = makeDefaults()
        let targetHost = makeHost(
            plugins: [
                BackupCombinedPlugin(id: "first", order: 1, shortcutID: "toggle"),
                BackupCombinedPlugin(id: "second", order: 2, shortcutID: "open"),
                BackupCombinedPlugin(id: "third", order: 3, shortcutID: "show")
            ],
            defaults: targetDefaults
        )

        _ = try targetHost.importPreferences(backup)
        XCTAssertEqual(targetHost.preferredMenuBarPanelWidth, 1200)
        XCTAssertEqual(targetHost.menuBarPanelStore.configuration, layout)
        XCTAssertEqual(targetHost.panelItems(in: "features").map(\.width), [.custom(720), .fill])


        XCTAssertEqual(targetHost.panelEntries(in: "components").map(\.pluginID), ["third", "second"])
        XCTAssertTrue(targetHost.menuBarPanelStore.configuration.initializedItems.contains(.init(pluginID: "first", itemID: "widget")))
        XCTAssertEqual(targetHost.componentItems.map(\.pluginID), ["third", "second"])
        XCTAssertEqual(targetHost.panelEntries(in: "features").map(\.pluginID), ["second", "first"])
        XCTAssertTrue(targetHost.menuBarPanelStore.configuration.initializedItems.contains(.init(pluginID: "third", itemID: "control")))
        XCTAssertEqual(targetHost.panelItems.map(\.pluginID), ["second", "first"])
    }

    func testInvalidShortcutImportLeavesAllShortcutCustomizationsUntouched() throws {
        let defaults = makeDefaults()
        let host = makeHost(
            plugins: [
                BackupTestPlugin(id: "first", order: 1, shortcutID: "toggle"),
                BackupTestPlugin(id: "second", order: 2, shortcutID: "open")
            ],
            defaults: defaults
        )
        let firstBinding = ShortcutBinding(keyCode: 12, modifiers: [.command])
        let secondBinding = ShortcutBinding(keyCode: 13, modifiers: [.command])
        host.setShortcutBinding(firstBinding, for: "first.shortcut.toggle")
        host.setShortcutBinding(secondBinding, for: "second.shortcut.open")
        let existingCustomizations = host.makePreferencesBackup().shortcutCustomizations
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: ["first", "second"], hiddenPluginIDs: []),
            shortcutCustomizations: [
                "first.shortcut.toggle": .custom(firstBinding),
                "second.shortcut.open": .custom(firstBinding)
            ]
        )

        let result = try host.importPreferences(backup)

        XCTAssertEqual(
            Set(result.shortcutErrors.keys),
            Set(["first.shortcut.toggle", "second.shortcut.open"])
        )
        XCTAssertEqual(host.makePreferencesBackup().shortcutCustomizations, existingCustomizations)
    }

    func testDecodeRejectsUnsupportedFormatVersion() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any])
        let unsupportedVersion = PreferencesBackup.currentFormatVersion + 1
        json["formatVersion"] = unsupportedVersion

        XCTAssertThrowsError(try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))) { error in
            guard case PreferencesBackupError.unsupportedFormatVersion(unsupportedVersion) = error else {
                return XCTFail("Expected unsupported format version error, got \(error)")
            }
        }
    }

    func testDecodeRejectsInvalidApplicationPreferences() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any])
        var application = try XCTUnwrap(json["application"] as? [String: Any])
        application["languagePreference"] = "unsupported-language"
        json["application"] = application

        let decodedBackup = try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))
        let store = PreferencesBackupStore(userDefaults: makeDefaults())

        XCTAssertThrowsError(try decodedBackup.validateApplicationPreferences(using: store.validates)) { error in
            guard case PreferencesBackupError.invalidApplicationPreferences = error else {
                return XCTFail("Expected invalid application preferences error, got \(error)")
            }
        }
    }

    func testOlderBackupWithoutFloatingPanelAppearanceUsesSystemDefault() throws {
        let backup = PreferencesBackup(
            application: PreferencesBackup.ApplicationPreferences(
                appearancePreference: AppAppearancePreference.system.rawValue,
                floatingPanelAppearance: PluginFloatingPanelAppearance.solid.rawValue,
                languagePreference: AppLanguagePreference.system.rawValue
            ),
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any])
        var application = try XCTUnwrap(json["application"] as? [String: Any])
        application.removeValue(forKey: "floatingPanelAppearance")
        json["application"] = application

        let decoded = try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))
        let defaults = makeDefaults()
        PluginFloatingPanelAppearance.solid.store(in: defaults)
        let store = PreferencesBackupStore(userDefaults: defaults)

        XCTAssertNil(decoded.application.floatingPanelAppearance)
        XCTAssertTrue(store.validates(decoded.application))
        store.apply(decoded.application)
        XCTAssertEqual(PluginFloatingPanelAppearance.stored(in: defaults), .system)
    }

    func testDecodeRejectsInvalidFloatingPanelAppearance() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any])
        var application = try XCTUnwrap(json["application"] as? [String: Any])
        application["floatingPanelAppearance"] = "unsupported-surface"
        json["application"] = application

        let decoded = try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))
        let store = PreferencesBackupStore(userDefaults: makeDefaults())

        XCTAssertThrowsError(try decoded.validateApplicationPreferences(using: store.validates)) { error in
            XCTAssertEqual(error as? PreferencesBackupError, .invalidApplicationPreferences)
        }
    }

    func testDecodeFileRejectsContentAboveSizeLimit() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x20, count: PreferencesBackup.maximumFileSize + 1).write(to: url)

        do {
            _ = try await PreferencesBackup.decodeJSON(contentsOf: url)
            XCTFail("Expected oversized backup to be rejected")
        } catch {
            XCTAssertEqual(
                error as? PreferencesBackupError,
                .fileTooLarge(maximumBytes: PreferencesBackup.maximumFileSize)
            )
        }
    }

    private var validApplicationPreferences: PreferencesBackup.ApplicationPreferences {
        PreferencesBackup.ApplicationPreferences(
            appearancePreference: AppAppearancePreference.system.rawValue,
            floatingPanelAppearance: PluginFloatingPanelAppearance.system.rawValue,
            languagePreference: AppLanguagePreference.system.rawValue,
            menuBarClickBehavior: "standard"
        )
    }

    private func makeDefaults(suiteName customSuiteName: String? = nil) -> UserDefaults {
        let resolvedSuiteName = customSuiteName ?? suiteName
        let defaults = UserDefaults(suiteName: resolvedSuiteName)!
        defaults.removePersistentDomain(forName: resolvedSuiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: resolvedSuiteName)
        }
        return defaults
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PreferencesBackupTests-\(UUID().uuidString).json")
    }

    func testCloudImportPreservesLocalRulesNestedDependenciesShortcutsAndRunLinks() throws {
        let defaults = makeDefaults()
        let provider = BackupActionProviderPlugin()
        let coordinator = CloudPreferencesSyncCoordinator(userDefaults: defaults)
        let host = PluginHost(
            plugins: [provider], shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            cloudPreferencesSyncCoordinator: coordinator, globalShortcutManager: GlobalShortcutManager()
        )
        let references = try provider.references()
        let child = WorkflowDefinition(name: "Local dependency", steps: [WorkflowStep(reference: references[0])])
        let parent = WorkflowDefinition(name: "Local parent", steps: [WorkflowStep(reference: child.actionReference)])
        let localWorkflow = WorkflowDefinition(name: "Hardware workflow", steps: [WorkflowStep(reference: references[1])])
        let oldPortable = WorkflowDefinition(name: "Deleted on other Mac")
        let displayRule = AutomationRule(name: "Local display", workflowID: parent.id, trigger: .display(DisplayAutomationTrigger(event: .connected, displayIdentifier: "local-display")))
        let calendarRule = AutomationRule(name: "Local calendar", workflowID: parent.id, trigger: .calendar(CalendarAutomationTrigger(phase: .starts, calendarIdentifier: "local-calendar")))
        XCTAssertTrue(host.automationController.restorePreferences(workflows: [child, parent, localWorkflow, oldPortable], rules: [displayRule, calendarRule]))
        guard case .success = host.setActionShortcutBinding(ShortcutBinding(keyCode: 31, modifiers: [.command, .control]), to: references[1]),
              case .success = host.createActionRunLink(for: references[1]) else {
            return XCTFail("Expected local shortcut and Run Link")
        }
        let localShortcuts = host.shortcutAssignmentService.assignments
        let presetStore = ActionInvocationPresetStore(userDefaults: defaults)
        let localPresets = presetStore.presets()
        let remoteWorkflow = WorkflowDefinition(name: "New portable workflow")
        let remoteRule = AutomationRule(name: "Portable rule", workflowID: remoteWorkflow.id, trigger: .display(DisplayAutomationTrigger(event: .connected)))
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            // Replacing this provider would destroy a preset used by the local child.
            pluginPreferences: [provider.metadata.id: Data("replacement-without-local-preset".utf8)],
            workflows: [remoteWorkflow], automationRules: [remoteRule]
        )
        try withExtendedLifetime(host) { try coordinator.importHandler?(backup) }
        XCTAssertEqual(Set(host.automationController.workflows.map(\.id)), [child.id, parent.id, localWorkflow.id, remoteWorkflow.id])
        XCTAssertEqual(host.automationController.workflows.first { $0.id == child.id }, child)
        XCTAssertEqual(host.automationController.workflows.first { $0.id == parent.id }, parent)
        XCTAssertEqual(Set(host.automationController.rules.map(\.id)), [displayRule.id, calendarRule.id, remoteRule.id])
        XCTAssertEqual(host.automationController.rules.first { $0.id == displayRule.id }, displayRule)
        XCTAssertEqual(host.automationController.rules.first { $0.id == calendarRule.id }, calendarRule)
        XCTAssertEqual(host.shortcutAssignmentService.assignments, localShortcuts)
        XCTAssertEqual(presetStore.presets(), localPresets)
    }

    func testCloudSyncReportsPluginPreferenceRestoreFailures() throws {
        let defaults = makeDefaults()
        let coordinator = CloudPreferencesSyncCoordinator(userDefaults: defaults)
        let host = PluginHost(
            plugins: [BackupActionProviderPlugin()],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            cloudPreferencesSyncCoordinator: coordinator,
            globalShortcutManager: GlobalShortcutManager()
        )
        try withExtendedLifetime(host) {
            XCTAssertThrowsError(try coordinator.importHandler?(
                makePluginImportBackup(payload: Data("invalid-settings".utf8))
            ))
        }
    }

    private func makeHost(
        plugins: [any MacToolsPlugin],
        defaults: UserDefaults
    ) -> PluginHost {
        PluginHost(
            plugins: plugins,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
    }

    private func makePluginImportBackup(payload: Data) -> PreferencesBackup {
        PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["backup-actions", "built-in"],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:],
            pluginPreferences: ["backup-actions": payload]
        )
    }

    private func makeDynamicPluginPackage(at root: URL, id: String, version: String) throws -> URL {
        let packageURL = root
            .appending(path: "Source/\(id)-\(UUID().uuidString).mactoolsplugin", directoryHint: .isDirectory)
        let bundleRelativePath = "Demo.bundle"
        try FileManager.default.createDirectory(
            at: packageURL.appending(path: bundleRelativePath, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let manifest = PluginPackageManifest(
            id: id,
            displayName: "Installable",
            version: version,
            minHostVersion: "0.1.0",
            bundleRelativePath: bundleRelativePath,
            capabilities: .init(panelItems: [.row])
        )
        try JSONEncoder().encode(manifest).write(to: packageURL.appending(path: "plugin.json"))
        return packageURL
    }

    private func makeCatalogEntry(id: String, version: String) -> PluginCatalogEntry {
        PluginCatalogEntry(
            id: id,
            displayName: "Installable",
            summary: "Available from the verified catalog.",
            version: version,
            minimumHostVersion: "0.1.0",
            package: PluginCatalogPackage(
                url: URL(fileURLWithPath: "/tmp/\(id).mactoolsplugin"),
                sha256: String(repeating: "a", count: 64),
                size: 42
            )
        )
    }

}

@MainActor
private struct BackupCatalogProvider: PluginCatalogProviding {
    let entries: [PluginCatalogEntry]

    func loadCatalog() async throws -> PluginCatalogSnapshot {
        PluginCatalogSnapshot(
            catalog: PluginCatalog(
                catalogID: "com.example.backup-tests",
                generatedAt: Date(timeIntervalSince1970: 0),
                minimumHostVersion: "0.1.0",
                plugins: entries
            ),
            sourceURL: URL(string: "https://example.com/catalog.json")!,
            sourceKind: .production,
            loadedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

@MainActor
private struct BackupPackageResolver: PluginPackageResolving {
    let packagesByID: [String: URL]

    func resolvePackage(for entry: PluginCatalogEntry) async throws -> URL {
        guard let packageURL = packagesByID[entry.id] else {
            throw PluginCatalogManagerError.catalogEntryNotFound(entry.id)
        }

        return packageURL
    }
}

@MainActor
private final class BackupDynamicPluginLoader: DynamicPluginLoading {
    var preparePluginForActivation: ((any MacToolsPlugin) -> Void)?
    private(set) var receivedRecordIDBatches: [[String]] = []

    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult] {
        receivedRecordIDBatches.append(records.map(\.id))
        return records.map { record in
            DynamicPluginLoadResult(
                record: record,
                plugins: [BackupTestPlugin(id: record.id, order: 10, shortcutID: "toggle")],
                errorMessage: nil
            )
        }
    }
}

@MainActor
private final class BackupTestPlugin: MacToolsPlugin, PluginPortablePreferencesProviding {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    let metadata: PluginMetadata
    let rowDescriptor: PluginPanelRowDescriptor
    let shortcutDefinitions: [PluginShortcutDefinition]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private let portablePreferences: Data?
    private(set) var restoredPortablePreferences: Data?

    init(id: String, order: Int, shortcutID: String, portablePreferences: Data? = nil) {
        metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "gearshape",
            iconTint: .blue,
            order: order,
            defaultDescription: id
        )
        rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .switch,
            menuActionBehavior: .keepPresented
        )
        shortcutDefinitions = [
            PluginShortcutDefinition(
                id: shortcutID,
                title: shortcutID,
                description: shortcutID,
                actionID: shortcutID,
                scope: .global,
                defaultBinding: nil,
                isRequired: false
            )
        ]
        self.portablePreferences = portablePreferences
    }

    func makePortablePreferencesBackup() -> Data? {
        portablePreferences
    }

    func restorePortablePreferences(from data: Data) {
        restoredPortablePreferences = data
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    func handleAction(_ action: PluginPanelAction) {}
}

@MainActor
private final class BackupActionProviderPlugin: MacToolsPlugin, PluginActionProviding,
    PluginPortablePreferencesProviding, PluginPortablePreferencesRestorationReporting,
    PluginPortablePreferencesActionReferencesProviding,
    PluginActionReferenceBackupProviding
{
    let metadata = PluginMetadata(
        id: "backup-actions",
        title: "Backup Actions",
        iconName: "shippingbox",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Backup action portability tests"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var actionDefinitions: [ActionDefinition] {
        [
            definition(actionID: "portable"),
            definition(actionID: "local", portability: .localOnly),
            definition(actionID: "sensitive", privacy: .sensitive),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        (try? references())?.map {
            ActionCatalogEntry(reference: $0, title: $0.key.actionID)
        } ?? []
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }

    func makePortablePreferencesBackup() -> Data? { Data("provider-settings".utf8) }
    func restorePortablePreferences(from data: Data) {}
    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        data == Data("provider-settings".utf8)
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        guard data == Data("provider-settings".utf8) else { return nil }
        return try? [references()[0]]
    }

    func backupDisposition(
        for reference: ActionReference
    ) -> PluginActionReferenceBackupDisposition {
        reference.key.actionID == "portable" ? .requiresPluginPreferences : .selfContained
    }

    func references() throws -> [ActionReference] {
        try ["portable", "local", "sensitive"].map { actionID in
            ActionReference(
                key: ActionKey(providerID: metadata.id, actionID: actionID),
                parameters: try ActionParameterSet(["value": .string(actionID)])
            )
        }
    }

    private func definition(
        actionID: String,
        privacy: ActionParameterPrivacy = .publicValue,
        portability: ActionParameterPortability = .portable
    ) -> ActionDefinition {
        ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: actionID),
            title: actionID,
            description: actionID,
            systemImage: "shippingbox",
            parameters: [
                ActionParameterDefinition(
                    id: "value",
                    title: "Value",
                    kind: .string,
                    privacy: privacy,
                    portability: portability
                ),
            ],
            externalInvocationPolicy: .allowed,
            capabilities: [.background, .foregroundInteractive]
        )
    }
}

private struct BackupActionPresetEnvelope: Encodable {
    let formatVersion: Int
    let presets: [ActionInvocationPreset]
}

@MainActor
private final class BackupMigratingActionPlugin: MacToolsPlugin, PluginActionProviding {
    let metadata = PluginMetadata(
        id: "migrating-actions",
        title: "Migrating Actions",
        iconName: "arrow.triangle.2.circlepath",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Migration tests"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var actionDefinitions: [ActionDefinition] {
        [ActionDefinition(
            key: actionKey,
            parameterSchemaVersion: 2,
            title: "Migrated",
            description: "Migrated",
            systemImage: "arrow.triangle.2.circlepath",
            parameters: [ActionParameterDefinition(id: "value", title: "Value", kind: .string)],
            capabilities: [.background, .foregroundInteractive]
        )]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        guard let reference = try? currentReference() else { return [] }
        return [ActionCatalogEntry(reference: reference, title: "Migrated")]
    }

    func legacyReference() throws -> ActionReference {
        ActionReference(
            key: actionKey,
            schemaVersion: 1,
            parameters: try ActionParameterSet(["legacyValue": .string("legacy")])
        )
    }

    func unpublishedReference() throws -> ActionReference {
        ActionReference(
            key: actionKey,
            schemaVersion: 2,
            parameters: try ActionParameterSet(["value": .string("unpublished")])
        )
    }

    func migrateActionReference(
        _ reference: ActionReference,
        toSchemaVersion schemaVersion: Int
    ) -> ActionReference? {
        guard reference.key == actionKey,
              reference.schemaVersion == 1,
              schemaVersion == 2,
              case let .string(value)? = reference.parameters["legacyValue"] else {
            return nil
        }
        return try? ActionReference(
            key: actionKey,
            schemaVersion: 2,
            parameters: ActionParameterSet(["value": .string(value)])
        )
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }

    private var actionKey: ActionKey {
        ActionKey(providerID: metadata.id, actionID: "migrated")
    }

    private func currentReference() throws -> ActionReference {
        ActionReference(
            key: actionKey,
            schemaVersion: 2,
            parameters: try ActionParameterSet(["value": .string("legacy")])
        )
    }
}

@MainActor
private final class BackupPreferenceDefinedActionPlugin: MacToolsPlugin, PluginActionProviding,
    PluginPortablePreferencesProviding, PluginPortablePreferencesRestorationReporting,
    PluginPortablePreferencesActionReferencesProviding,
    PluginActionReferenceBackupProviding
{
    let metadata = PluginMetadata(
        id: "preference-defined-actions",
        title: "Preference Defined Actions",
        iconName: "gear",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Preference dependency tests"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var shouldFailRestore = false
    private var preferencesRestored = false

    var reference: ActionReference {
        ActionReference(key: ActionKey(providerID: metadata.id, actionID: storedActionID))
    }

    var actionDefinitions: [ActionDefinition] {
        guard preferencesRestored else { return [] }
        return [ActionDefinition(
            key: reference.key,
            title: "Restored Item",
            description: "Restored Item",
            systemImage: "gear",
            capabilities: [.background, .foregroundInteractive]
        )]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        preferencesRestored ? [ActionCatalogEntry(reference: reference, title: "Restored Item")] : []
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }

    func makePortablePreferencesBackup() -> Data? {
        preferencesRestored ? Data(storedActionID.utf8) : nil
    }

    func restorePortablePreferences(from data: Data) {
        restoredActionID = decodedActionID(from: data)
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard !shouldFailRestore, let actionID = decodedActionID(from: data) else {
            return false
        }
        restoredActionID = actionID
        return true
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        guard let actionID = decodedActionID(from: data) else { return nil }
        return [ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: actionID)
        )]
    }

    func backupDisposition(
        for reference: ActionReference
    ) -> PluginActionReferenceBackupDisposition {
        restoredActionID == reference.key.actionID
            ? .requiresPluginPreferences
            : .excluded
    }

    private var restoredActionID: String? {
        get { preferencesRestored ? storedActionID : nil }
        set {
            storedActionID = newValue ?? "restored-item"
            preferencesRestored = newValue != nil
        }
    }

    private var storedActionID = "restored-item"

    private func decodedActionID(from data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        return value == "enabled" ? "restored-item" : value
    }
}

@MainActor
private final class BackupActionSurfacePlugin: MacToolsPlugin, PluginPortablePreferencesProviding,
    PluginPortablePreferencesRestorationReporting,
    PluginPortablePreferencesActionReferencesProviding, ActionGridHostContextConsuming
{
    let metadata = PluginMetadata(
        id: "backup-action-surface",
        title: "Backup Action Surface",
        iconName: "square.grid.3x3",
        iconTint: .blue,
        order: 2,
        defaultDescription: "Action-surface backup tests"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var actionGridHostContext: ActionGridHostContext?
    var references: [ActionReference] = []

    func makePortablePreferencesBackup() -> Data? {
        try? JSONEncoder().encode(references.filter {
            actionGridHostContext?.canExport($0) ?? false
        })
    }

    func restorePortablePreferences(from data: Data) {
        references = ((try? JSONDecoder().decode([ActionReference].self, from: data)) ?? []).filter {
            actionGridHostContext?.canRestore($0) ?? false
        }
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode([ActionReference].self, from: data),
              decoded.allSatisfy({ actionGridHostContext?.canRestore($0) ?? false }) else {
            return false
        }
        references = decoded
        return true
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        try? JSONDecoder().decode([ActionReference].self, from: data)
    }
    func handleAction(_ action: PluginPanelAction) {}
}

private final class BackupCombinedPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
            .widget(id: "widget", initialPlacement: .dashboard,
                    descriptor: descriptor, state: widgetState,
                    content: { [weak self] context in
                        self?.makeView(context: context) ?? AnyView(EmptyView())
                    }),
        ]
    }

    let metadata: PluginMetadata
    let rowDescriptor: PluginPanelRowDescriptor
    let descriptor = PluginPanelWidgetDescriptor(span: .oneByOne)
    let shortcutDefinitions: [PluginShortcutDefinition]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(id: String, order: Int, shortcutID: String) {
        metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "gearshape",
            iconTint: .blue,
            order: order,
            defaultDescription: id
        )
        rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .switch,
            menuActionBehavior: .keepPresented
        )
        shortcutDefinitions = [
            PluginShortcutDefinition(
                id: shortcutID,
                title: shortcutID,
                description: shortcutID,
                actionID: shortcutID,
                scope: .global,
                defaultBinding: nil,
                isRequired: false
            )
        ]
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(
            subtitle: metadata.defaultDescription,
            isActive: false,
            isEnabled: true,
            isAvailable: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
        AnyView(Text(context.pluginID))
    }

    func handleAction(_ action: PluginPanelAction) {}
}
