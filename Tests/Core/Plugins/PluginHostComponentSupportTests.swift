import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginHostComponentSupportTests: XCTestCase {
    private let suiteName = "PluginHostComponentSupportTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDynamicPhaseShortcutDefaultCannotBypassExistingShortcutConflict() async {
        let initial = ShortcutBinding(keyCode: 48, modifiers: [.option])
        let occupied = ShortcutBinding(keyCode: 18, modifiers: [.command, .option])
        let phase = PhaseShortcutTestPlugin(binding: initial)
        let other = MockComponentPanelPlugin(id: "other", shortcutDefinitions: [
            PluginShortcutDefinition(id: "occupied", title: "Occupied", description: "", actionID: "occupied",
                                     scope: .global, defaultBinding: occupied, isRequired: false)
        ])
        let host = makeHost(plugins: [phase, other])
        XCTAssertEqual(phase.shortcutBindingResolver?("cycle"), initial)
        phase.binding = occupied
        phase.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertNil(phase.shortcutBindingResolver?("cycle"))
        XCTAssertNil(phase.latestBinding)
        XCTAssertGreaterThan(phase.notifications, 0)
        XCTAssertNotNil(host.shortcutItems.first { $0.id == "phase-test.shortcut.cycle" }?.errorMessage)
        phase.binding = initial
        phase.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(phase.latestBinding, initial)
        XCTAssertNil(host.shortcutItems.first { $0.id == "phase-test.shortcut.cycle" }?.errorMessage)
    }

    func testComponentOnlyPluginContributesSettingsPermissionsAndShortcuts() {
        let componentPanelPlugin = MockComponentPanelPlugin(
            id: "component",
            permissionRequirements: [
                PluginPermissionRequirement(
                    id: "accessibility",
                    kind: .accessibility,
                    title: "辅助功能",
                    description: "需要辅助功能权限。"
                )
            ],
            settingsPage: .form(
                description: "组件设置说明。",
                sections: [
                    PluginSettingsSection(
                        id: "settings",
                        title: "组件设置",
                        rows: [
                            PluginSettingsRow(
                                id: "settings-action",
                                title: "组件状态",
                                control: .status(
                                    text: "正常",
                                    systemImage: "checkmark",
                                    tone: .positive,
                                    actionTitle: "执行"
                                )
                            )
                        ]
                    )
                ]
            ),
            shortcutDefinitions: [
                PluginShortcutDefinition(
                    id: "shortcut",
                    title: "组件快捷键",
                    description: "触发组件动作。",
                    actionID: "shortcut-action",
                    scope: .whilePluginActive,
                    defaultBinding: nil,
                    isRequired: false
                )
            ]
        )
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertEqual(host.permissionCards.map(\.pluginID), ["component"])
        XCTAssertEqual(host.permissionCards.map(\.iconSystemImage), ["accessibility"])
        XCTAssertEqual(host.permissionCards.map(\.iconVisualScale), [1.0])
        XCTAssertEqual(host.shortcutItems.map(\.pluginID), ["component"])
        XCTAssertEqual(host.pluginSettingsItems.map(\.id), ["component"])
        XCTAssertEqual(host.pluginSettingsItems.first?.sections.map(\.id), ["settings"])
        XCTAssertEqual(host.pluginSettingsItems.first?.permissionCards.map(\.permissionID), ["accessibility"])
        XCTAssertEqual(host.pluginSettingsItems.first?.shortcutItems.map(\.pluginID), ["component"])
    }

    func testPermissionRefreshClearsSettingsGuidanceAfterGrant() throws {
        let plugin = MockComponentPanelPlugin(
            id: "component",
            permissionRequirements: [.init(
                id: "input-monitoring",
                kind: .inputMonitoring,
                title: "Input Monitoring",
                description: "Read input events."
            )],
            settingsPage: .form(description: "Component settings", sections: []),
            isPermissionGranted: false
        )
        let host = makeHost(plugins: [plugin])
        let refreshCallCount = plugin.refreshCallCount
        XCTAssertEqual(host.pluginSettingsItems.first?.missingPermissionCards.count, 1)

        plugin.isPermissionGranted = true
        host.permissionCoordinator.refresh()

        XCTAssertEqual(host.permissionCoordinator.items.first?.status, .granted)
        XCTAssertEqual(host.permissionCards.first?.statusTone, .positive)
        let settings = try XCTUnwrap(host.pluginSettingsItems.first)
        XCTAssertEqual(settings.permissionCards.first?.statusTone, .positive)
        XCTAssertTrue(settings.missingPermissionCards.isEmpty)
        XCTAssertEqual(plugin.refreshCallCount, refreshCallCount)
        XCTAssertTrue(plugin.handledPermissionIDs.isEmpty)
    }

    func testLanguageSwitchRefreshesPluginMetadataAndPreservesCustomSettingsIntroductions() throws {
        let originalPreference = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        PluginRuntimeLocalization.source.setPreference("en")

        let inherited = MockComponentPanelPlugin(
            id: "inherited",
            permissionRequirements: [.init(
                id: "accessibility",
                kind: .accessibility,
                title: "Permission",
                description: "Permission description"
            )],
            settingsPage: .form(description: "Component inherited", sections: [])
        )
        let custom = MockComponentPanelPlugin(
            id: "custom",
            settingsPage: .form(description: "Custom settings introduction", sections: [])
        )
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostSettingsLocalizationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )
        let localizedMetadata = [
            "en": PluginLocalizedMetadata(displayName: "English plugin name", summary: "English metadata introduction"),
            "ar": PluginLocalizedMetadata(displayName: "Arabic plugin name", summary: "Arabic metadata introduction")
        ]
        for plugin in [inherited, custom] {
            _ = installTestPluginPackage(
                id: plugin.metadata.id,
                bundleName: "\(plugin.metadata.id).bundle",
                capabilities: .init(panelItems: [.widget], settings: .form),
                localizedMetadata: localizedMetadata,
                store: store
            )
        }
        let pluginsByID = [inherited.metadata.id: inherited, custom.metadata.id: custom]
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { records in
                records.map { record in
                    DynamicPluginLoadResult(
                        record: record,
                        plugins: [pluginsByID[record.manifest.id]!],
                        errorMessage: nil
                    )
                }
            }
        )
        let host = makeHost(plugins: [], dynamicPluginManager: manager)

        for (language, expectedIntroduction) in [
            ("en", "English metadata introduction"),
            ("ar", "Arabic metadata introduction"),
            ("en", "English metadata introduction")
        ] {
            PluginRuntimeLocalization.source.setPreference(language)
            host.refreshLocalization()
            XCTAssertEqual(
                host.pluginSettingsItems.first { $0.pluginID == "inherited" }?.description,
                expectedIntroduction
            )
            XCTAssertEqual(
                host.pluginSettingsItems.first { $0.pluginID == "custom" }?.description,
                "Custom settings introduction"
            )
            XCTAssertEqual(
                host.permissionCoordinator.items.first?.affectedFeatures.first?.pluginTitle,
                localizedMetadata[language]?.displayName
            )
        }
    }

    func testPermissionRefreshAddsSettingsGuidanceAfterRevocation() throws {
        let plugin = MockComponentPanelPlugin(
            id: "component",
            permissionRequirements: [.init(
                id: "input-monitoring",
                kind: .inputMonitoring,
                title: "Input Monitoring",
                description: "Read input events."
            )]
        )
        let host = makeHost(plugins: [plugin])
        let refreshCallCount = plugin.refreshCallCount
        XCTAssertTrue(host.pluginSettingsItems.isEmpty)

        plugin.isPermissionGranted = false
        host.permissionCoordinator.refresh()

        XCTAssertEqual(host.permissionCoordinator.items.first?.status, .attention)
        let settings = try XCTUnwrap(host.pluginSettingsItems.first)
        XCTAssertEqual(settings.missingPermissionCards.map(\.permissionID), ["input-monitoring"])
        XCTAssertEqual(plugin.refreshCallCount, refreshCallCount)
        XCTAssertTrue(plugin.handledPermissionIDs.isEmpty)
    }

    func testShortcutsInSameSharedBindingGroupCanUseSameBinding() {
        let binding = ShortcutBinding(keyCode: 18, modifiers: [.command, .option])
        let componentPanelPlugin = MockComponentPanelPlugin(
            id: "component",
            shortcutDefinitions: [
                PluginShortcutDefinition(
                    id: "first",
                    title: "第一个",
                    description: "第一个动作。",
                    actionID: "first",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false,
                    sharedBindingGroupID: "brightness.down"
                ),
                PluginShortcutDefinition(
                    id: "second",
                    title: "第二个",
                    description: "第二个动作。",
                    actionID: "second",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false,
                    sharedBindingGroupID: "brightness.down"
                )
            ]
        )
        let host = makeHost(plugins: [componentPanelPlugin])

        host.setShortcutBinding(binding, for: "component.shortcut.first")
        host.setShortcutBinding(binding, for: "component.shortcut.second")

        XCTAssertNil(host.shortcutItems.first { $0.id == "component.shortcut.second" }?.errorMessage)
    }

    func testShortcutsInDifferentSharedBindingGroupsStillRejectDuplicateBindings() {
        let binding = ShortcutBinding(keyCode: 18, modifiers: [.command, .option])
        let componentPanelPlugin = MockComponentPanelPlugin(
            id: "component",
            shortcutDefinitions: [
                PluginShortcutDefinition(
                    id: "first",
                    title: "第一个",
                    description: "第一个动作。",
                    actionID: "first",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false,
                    sharedBindingGroupID: "brightness.down"
                ),
                PluginShortcutDefinition(
                    id: "second",
                    title: "第二个",
                    description: "第二个动作。",
                    actionID: "second",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false,
                    sharedBindingGroupID: "brightness.up"
                )
            ]
        )
        let host = makeHost(plugins: [componentPanelPlugin])

        host.setShortcutBinding(binding, for: "component.shortcut.first")
        host.setShortcutBinding(binding, for: "component.shortcut.second")

        XCTAssertNotNil(host.shortcutItems.first { $0.id == "component.shortcut.second" }?.errorMessage)
    }

    func testPluginStateChangesOnlyReadDirtyPanelState() async throws {
        let changingPlugin = CountingPrimaryPanelPlugin(id: "changing", order: 1)
        let stablePlugin = CountingPrimaryPanelPlugin(id: "stable", order: 2)
        let host = makeHost(
            plugins: [changingPlugin, stablePlugin],
            pluginStateChangeRebuildDelay: .milliseconds(20)
        )
        changingPlugin.panelStateReadCount = 0
        stablePlugin.panelStateReadCount = 0

        changingPlugin.primarySubtitle = "changed"
        changingPlugin.onStateChange?()
        changingPlugin.primarySubtitle = "changed again"
        changingPlugin.onStateChange?()
        changingPlugin.onStateChange?()

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(changingPlugin.panelStateReadCount, 1)
        XCTAssertEqual(stablePlugin.panelStateReadCount, 0)
        XCTAssertEqual(host.panelItems.map(\.description), ["changed again", "Feature stable"])
    }

    func testComponentSurfaceLifecycleEventsAreSentWhenPanelVisibilityChanges() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        host.setVisibleMenuBarPanel("components")
        host.setVisibleMenuBarPanel("components")
        host.setVisibleMenuBarPanel(nil)
        host.setVisibleMenuBarPanel(nil)

        XCTAssertEqual(componentPanelPlugin.surfaceEvents, [
            .visible("widget"),
            .hidden("widget")
        ])
    }

    func testUninstallingDynamicPluginRemovesLayoutAndShortcutReferences() throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let packageStore = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "dynamic",
            bundleName: "Dynamic.bundle",
            capabilities: .init(panelItems: [.row]),
            store: packageStore
        )
        let shortcutDefinition = PluginShortcutDefinition(
            id: "open",
            title: "Open",
            description: "Open the dynamic plugin.",
            actionID: "open",
            scope: .global,
            defaultBinding: nil,
            isRequired: false
        )
        let plugin = MockPrimaryPanelPlugin(
            id: "dynamic",
            shortcutDefinitions: [shortcutDefinition]
        )
        let manager = DynamicPluginManager(
            packageStore: packageStore,
            pluginLoader: StubDynamicPluginLoader { records in
                records.map { record in
                    DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
                }
            }
        )
        let shortcutStore = ShortcutStore(userDefaults: defaults)
        let host = PluginHost(
            plugins: [],
            dynamicPluginManager: manager,
            shortcutStore: shortcutStore,
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        let shortcutID = "dynamic.shortcut.open"
        host.setShortcutBinding(
            ShortcutBinding(keyCode: 12, modifiers: [.command]),
            for: shortcutID
        )

        XCTAssertEqual(host.panelEntries(in: "features").map(\.pluginID), ["dynamic"])
        XCTAssertNotNil(shortcutStore.customizations(for: [shortcutID])[shortcutID])

        try host.uninstallDynamicPlugin(pluginID: "dynamic")

        XCTAssertTrue(host.panelEntries(in: "features").isEmpty)
        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertTrue(host.shortcutItems.isEmpty)
        XCTAssertTrue(shortcutStore.customizations(for: [shortcutID]).isEmpty)
        XCTAssertTrue(packageStore.installedRecords().isEmpty)
    }

    func testDynamicPanelCapabilityMismatchRejectsTheInvalidCatalog() {
        let plugin = MockCombinedPlugin(id: "dynamic")
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "dynamic",
            bundleName: "Dynamic.bundle",
            capabilities: .init(panelItems: [.widget]),
            store: store
        )
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let host = makeHost(plugins: [], dynamicPluginManager: manager)

        XCTAssertTrue(host.panelEntries(in: "components").isEmpty)
        XCTAssertTrue(host.panelEntries(in: "features").isEmpty)
        XCTAssertTrue(host.availablePanelItems.isEmpty)
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    private func shortcutDefinition(id: String, groupID: String?) -> PluginShortcutDefinition {
        PluginShortcutDefinition(
            id: id,
            title: id,
            description: id,
            actionID: id,
            scope: .global,
            defaultBinding: nil,
            isRequired: false,
            settingsGroupID: groupID
        )
    }

    func testCopiesShareLifecycleAndRemovingLastCopyDoesNotDeactivatePlugin() throws {
        let plugin = MockCombinedPlugin(id: "dual")
        let host = makeHost(plugins: [plugin])
        let other = try XCTUnwrap(host.addMenuBarPanel())
        let entry = host.testEntry(pluginID: "dual", kind: .widget)
        let activations = plugin.activateCallCount
        let deactivations = plugin.deactivateCallCount
        host.setVisibleMenuBarPanel("components")
        XCTAssertTrue(host.addPanelItem(entry.key, to: "components"))
        XCTAssertTrue(host.addPanelItem(entry.key, to: other))
        host.setVisibleMenuBarPanel(other)
        host.setVisibleMenuBarPanel("components")
        XCTAssertEqual(plugin.surfaceEvents, [.visible("widget")])
        for copy in host.panelEntries(in: "components") {
            XCTAssertTrue(host.removePanelEntry(copy, from: "components"))
        }
        XCTAssertEqual(plugin.surfaceEvents, [.visible("widget"), .hidden("widget")])
        XCTAssertTrue(host.componentItems(in: "components").isEmpty)
        // A hidden copy must not keep foreground work alive, but remains available.
        host.setVisibleMenuBarPanel(other)
        XCTAssertEqual(plugin.surfaceEvents.last, .visible("widget"))
        XCTAssertTrue(host.removePanelEntry(try XCTUnwrap(host.panelEntries(in: other).first), from: other))
        XCTAssertEqual(plugin.surfaceEvents.last, .hidden("widget"))
        XCTAssertTrue(host.availablePanelItems.contains { $0.key == .init(pluginID: "dual", itemID: "widget") })
        XCTAssertEqual(plugin.activateCallCount, activations)
        XCTAssertEqual(plugin.deactivateCallCount, deactivations)
        XCTAssertEqual(host.panelItems(in: "features").map(\.pluginID), ["dual"])
    }

    func testRestoreDefaultPanelsResetsLayoutAndRemovesOnlyCustomPanelShortcuts() throws {
        let dual = MockCombinedPlugin(id: "dual")
        let host = makeHost(plugins: [dual])
        let custom = try XCTUnwrap(host.addMenuBarPanel())
        host.moveTestItem(pluginID: "dual", kind: .widget, to: custom)
        host.moveTestItem(pluginID: "dual", kind: .row, to: custom)
        host.removeTestItem(pluginID: "dual", kind: .widget)
        var original = host.menuBarPanels[0]
        original.name = "Renamed"
        original.systemImage = "heart"
        original.isHidden = true
        host.updateMenuBarPanel(original)
        host.moveMenuBarPanel(id: custom, toOffset: 0)
        let customReference = host.panelActionReference(id: custom)
        let defaultReference = host.panelActionReference(id: "features")
        let customBinding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option])
        let defaultBinding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_J), modifiers: [.control, .option])
        XCTAssertNil(host.setActionShortcutBindingAndReturnError(customBinding, for: customReference))
        XCTAssertNil(host.setActionShortcutBindingAndReturnError(defaultBinding, for: defaultReference))
        let activationCount = dual.activateCallCount
        let deactivationCount = dual.deactivateCallCount

        XCTAssertNil(host.restoreDefaultMenuBarPanelLayout())
        XCTAssertEqual(host.menuBarPanels, MenuBarPanelConfiguration().displayPanels)
        XCTAssertEqual(host.menuBarPanelStore.configuration.panels, MenuBarPanelDefinition.defaults)
        XCTAssertNil(host.actionShortcutSettingsItem(for: customReference))
        XCTAssertEqual(host.actionShortcutSettingsItem(for: defaultReference)?.assignment.binding, defaultBinding)
        XCTAssertEqual(host.componentItems.map(\.pluginID), ["dual"])
        XCTAssertEqual(host.panelItems(in: "features").map(\.pluginID), ["dual"])
        XCTAssertEqual(dual.activateCallCount, activationCount)
        XCTAssertEqual(dual.deactivateCallCount, deactivationCount)
        XCTAssertEqual(MenuBarPanelStore(userDefaults: UserDefaults(suiteName: suiteName)!).configuration, host.menuBarPanelStore.configuration)
    }

    func testCustomPanelShortcutsUseRegistryAndRejectConflicts() throws {
        let host = makeHost()
        let first = try XCTUnwrap(host.addMenuBarPanel())
        let second = try XCTUnwrap(host.addMenuBarPanel())
        let binding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option])
        XCTAssertNil(host.setActionShortcutBindingAndReturnError(binding, for: host.panelActionReference(id: first)))
        XCTAssertNotNil(host.setActionShortcutBindingAndReturnError(binding, for: host.panelActionReference(id: second)))
        host.deleteMenuBarPanel(id: first)
        XCTAssertNil(host.actionShortcutSettingsItem(for: host.panelActionReference(id: first)))
        XCTAssertNil(host.setActionShortcutBindingAndReturnError(binding, for: host.panelActionReference(id: second)))
    }

    func testPanelBackupRestoresLayoutAndCustomShortcutTogether() throws {
        let host = makeHost(plugins: [MockCombinedPlugin(id: "dual")])
        let panelID = try XCTUnwrap(host.addMenuBarPanel())
        host.moveTestItem(pluginID: "dual", kind: .widget, to: panelID)
        let binding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_J), modifiers: [.control, .option])
        XCTAssertNil(host.setActionShortcutBindingAndReturnError(binding, for: host.panelActionReference(id: panelID)))
        let backup = host.makePreferencesBackup()
        host.deleteMenuBarPanel(id: panelID)
        let result = try host.importPreferences(backup)
        XCTAssertTrue(result.shortcutErrors.isEmpty)
        XCTAssertEqual(host.componentItems(in: panelID).map(\.pluginID), ["dual"])
        XCTAssertEqual(host.actionShortcutSettingsItem(for: host.panelActionReference(id: panelID))?.assignment.binding, binding)
    }

    private func makeHost(
        plugins: [any MacToolsPlugin] = [],
        dynamicPluginManager: DynamicPluginManager? = nil,
        displayConfigurationObserver: (any DisplayConfigurationObserving)? = nil,
        displayTopologyRefreshDelay: Duration = .milliseconds(180),
        pluginStateChangeRebuildDelay: Duration = .milliseconds(80),
        openPermissionSettings: @escaping (URL) -> Void = { _ in },
        permissionGuidanceHandler: @escaping PermissionCoordinator.GuidanceHandler = { _, _ in }
    ) -> PluginHost {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        return PluginHost(
            plugins: plugins,
            dynamicPluginManager: dynamicPluginManager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            displayConfigurationObserver: displayConfigurationObserver,
            displayTopologyRefreshDelay: displayTopologyRefreshDelay,
            pluginStateChangeRebuildDelay: pluginStateChangeRebuildDelay,
            openPermissionSettings: openPermissionSettings,
            permissionGuidanceHandler: permissionGuidanceHandler
        )
    }

    private func installTestPluginPackage(
        id: String,
        bundleName: String,
        capabilities: PluginPackageManifest.Capabilities = .init(),
        localizedMetadata: [String: PluginLocalizedMetadata]? = nil,
        store: PluginPackageStore
    ) -> PluginPackageRecord {
        let sourceURL = store.rootDirectory
            .appendingPathComponent("Source", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = sourceURL.appendingPathComponent(bundleName, isDirectory: true)
        try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = PluginPackageManifest(
            id: id,
            displayName: id,
            version: "1.0.0",
            minHostVersion: "0.1.0",
            bundleRelativePath: bundleName,
            capabilities: capabilities,
            localizedMetadata: localizedMetadata
        )
        let data = try? JSONEncoder().encode(manifest)
        try? data?.write(to: sourceURL.appendingPathComponent("plugin.json"))

        return try! store.installPackage(from: sourceURL)
    }
}

@MainActor
private final class StubDynamicPluginLoader: DynamicPluginLoading {
    private let handler: ([PluginPackageRecord]) -> [DynamicPluginLoadResult]
    private(set) var receivedRecordIDs: [String] = []

    init(handler: @escaping ([PluginPackageRecord]) -> [DynamicPluginLoadResult]) {
        self.handler = handler
    }

    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult] {
        receivedRecordIDs = records.map(\.id)
        return handler(records)
    }
}

@MainActor
private final class MockComponentPanelPlugin: MacToolsPlugin, PluginRuntimeLocalizationRefreshing, PluginShortcutBindingChangeHandling, PluginGroupedShortcutSettingsProviding, PluginDashboardPresenting {
    var panelItems: [PluginPanelItem] {
        return [
            .widget(id: "widget", initialPlacement: .dashboard,
                    descriptor: descriptor, state: widgetState,
                    detail: { [weak self] in self?.makePanelDetailContent(detailID: $0, dismiss: $1) },
                    content: { [weak self] context in
                        self?.makeView(context: context) ?? AnyView(EmptyView())
                    })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("widget") }
                    else { self?.panelItemDidBecomeHidden("widget") }
                },
        ]
    }

    struct ShortcutBindingChange: Equatable {
        let id: String
        let binding: ShortcutBinding?
    }
    enum SurfaceEvent: Equatable {
        case visible(String)
        case hidden(String)
    }

    let metadata: PluginMetadata
    let descriptor: PluginPanelWidgetDescriptor
    let permissionRequirements: [PluginPermissionRequirement]
    let shortcutDefinitions: [PluginShortcutDefinition]
    let settingsPage: PluginSettingsPage?
    let shortcutSettingsGroups: [PluginShortcutSettingsGroupConfiguration]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestDashboardPresentation: (() -> Void)?
    var receivedContexts: [PluginPanelWidgetContext] = []
    var isActive: Bool
    private(set) var makeViewCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var localizationRefreshCount = 0
    private(set) var receivedPanelVisibilityValues: [Bool] = []
    private(set) var surfaceEvents: [SurfaceEvent] = []
    private(set) var shortcutBindingChanges: [ShortcutBindingChange] = []
    var isPermissionGranted: Bool
    var onRefresh: (() -> Void)?
    private(set) var handledPermissionIDs: [String] = []

    var onSurfaceVisible: (() -> Void)?

    init(
        id: String,
        order: Int = 1,
        span: PluginPanelWidgetSpan = .oneByOne,
        isActive: Bool = false,
        permissionRequirements: [PluginPermissionRequirement] = [],
        settingsPage: PluginSettingsPage? = nil,
        shortcutDefinitions: [PluginShortcutDefinition] = [],
        shortcutSettingsGroups: [PluginShortcutSettingsGroupConfiguration] = [],
        isPermissionGranted: Bool = true
    ) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemPurple),
            order: order,
            defaultDescription: "Component \(id)"
        )
        self.descriptor = PluginPanelWidgetDescriptor(span: span)
        self.isActive = isActive
        self.permissionRequirements = permissionRequirements
        self.shortcutDefinitions = shortcutDefinitions
        self.settingsPage = settingsPage
        self.shortcutSettingsGroups = shortcutSettingsGroups
        self.isPermissionGranted = isPermissionGranted
    }

    var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(
            subtitle: "Component subtitle",
            isActive: isActive,
            isEnabled: true,
            isAvailable: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
        makeViewCallCount += 1
        receivedContexts.append(context)
        receivedPanelVisibilityValues.append(!context.isPreview)
        return AnyView(Text(context.pluginID))
    }

    func makePanelDetailContent(
        detailID: String,
        dismiss: @escaping () -> Void
    ) -> PluginPanelDetailContent? {
        guard detailID == "cpu" else {
            return nil
        }
        return PluginPanelDetailContent(
            id: detailID,
            title: "CPU",
            content: AnyView(Text("CPU detail"))
        )
    }

    func panelItemDidBecomeVisible(_ surface: String) {
        surfaceEvents.append(.visible(surface))
        onSurfaceVisible?()
    }

    func panelItemDidBecomeHidden(_ surface: String) {
        surfaceEvents.append(.hidden(surface))
    }

    func refresh() {
        refreshCallCount += 1
        onRefresh?()
    }

    func refreshLocalization() {
        localizationRefreshCount += 1
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: isPermissionGranted, footnote: nil)
    }

    func handlePermissionAction(id: String) { handledPermissionIDs.append(id) }
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}
    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?) {
        shortcutBindingChanges.append(.init(id: id, binding: binding))
    }
}

@MainActor
private final class MutableComponentPanelPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .widget(id: "widget", initialPlacement: .dashboard,
                    descriptor: descriptor, state: widgetState,
                    content: { [weak self] context in
                        self?.makeView(context: context) ?? AnyView(EmptyView())
                    }),
        ]
    }

    let metadata: PluginMetadata
    let descriptor = PluginPanelWidgetDescriptor(span: .oneByOne)
    var settingsPage: PluginSettingsPage?
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var isActive = false
    var onComponentStateRead: (() -> Void)?
    private(set) var componentStateReadCount = 0

    init(id: String, settingsPage: PluginSettingsPage? = nil) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemPurple),
            order: 1,
            defaultDescription: "Component \(id)"
        )
        self.settingsPage = settingsPage
    }

    var widgetState: PluginPanelWidgetState {
        componentStateReadCount += 1
        onComponentStateRead?()
        return PluginPanelWidgetState(
            subtitle: "Component subtitle",
            isActive: isActive,
            isEnabled: true,
            isAvailable: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
        AnyView(Text(context.pluginID))
    }

    func triggerStateChange() {
        onStateChange?()
    }
}

@MainActor
private final class MockPrimaryPanelPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    let metadata: PluginMetadata
    let rowDescriptor: PluginPanelRowDescriptor
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var refreshCallCount = 0
    private let definedShortcuts: [PluginShortcutDefinition]

    init(
        id: String,
        order: Int = 1,
        shortcutDefinitions: [PluginShortcutDefinition] = []
    ) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemBlue),
            order: order,
            defaultDescription: "Feature \(id)"
        )
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .switch,
            menuActionBehavior: .keepPresented
        )
        self.definedShortcuts = shortcutDefinitions
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: "Feature subtitle",
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { definedShortcuts }

    func refresh() {
        refreshCallCount += 1
    }
    func handleAction(_ action: PluginPanelAction) {}

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}
}

@MainActor
private final class CountingPrimaryPanelPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    let metadata: PluginMetadata
    let rowDescriptor: PluginPanelRowDescriptor
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var primarySubtitle: String
    var panelStateReadCount = 0

    init(id: String, order: Int) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemBlue),
            order: order,
            defaultDescription: "Feature \(id)"
        )
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .switch,
            menuActionBehavior: .keepPresented
        )
        self.primarySubtitle = ""
    }

    var rowState: PluginPanelRowState {
        panelStateReadCount += 1
        return PluginPanelRowState(
            subtitle: primarySubtitle,
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {}
    func handleAction(_ action: PluginPanelAction) {}

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}
}

@MainActor
private final class MockCombinedPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("control") }
                    else { self?.panelItemDidBecomeHidden("control") }
                },
            .widget(id: "widget", initialPlacement: .dashboard,
                    descriptor: descriptor, state: widgetState,
                    content: { [weak self] context in
                        self?.makeView(context: context) ?? AnyView(EmptyView())
                    })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("widget") }
                    else { self?.panelItemDidBecomeHidden("widget") }
                },
        ]
    }

    enum SurfaceEvent: Equatable {
        case visible(String)
        case hidden(String)
    }

    let metadata: PluginMetadata
    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )
    let descriptor: PluginPanelWidgetDescriptor
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var surfaceEvents: [SurfaceEvent] = []
    private(set) var activateCallCount = 0
    private(set) var deactivateCallCount = 0

    init(id: String, order: Int = 1, span: PluginPanelWidgetSpan = .oneByOne) {
        descriptor = PluginPanelWidgetDescriptor(span: span)
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemPurple),
            order: order,
            defaultDescription: "Combined \(id)"
        )
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: "Combined subtitle",
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(
            subtitle: "Combined component subtitle",
            isActive: false,
            isEnabled: true,
            isAvailable: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
        AnyView(
            VStack(spacing: 8) {
                Image(systemName: metadata.iconName).font(.title2)
                Text(context.pluginID).font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(metadata.iconTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        )
    }

    func handleAction(_ action: PluginPanelAction) {}

    func activate(context: PluginRuntimeContext) {
        activateCallCount += 1
    }

    func deactivate(reason: PluginDeactivationReason) {
        deactivateCallCount += 1
    }

    func panelItemDidBecomeVisible(_ surface: String) {
        surfaceEvents.append(.visible(surface))
    }

    func panelItemDidBecomeHidden(_ surface: String) {
        surfaceEvents.append(.hidden(surface))
    }
}

@MainActor
private final class PhaseShortcutTestPlugin: MacToolsPlugin, PluginShortcutEventHandling, PluginShortcutBindingChangeHandling {
    let metadata: PluginMetadata
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var binding: ShortcutBinding
    var latestBinding: ShortcutBinding?
    var notifications = 0
    init(binding: ShortcutBinding, id: String = "phase-test") {
        self.binding = binding
        metadata = PluginMetadata(id: id, title: "Phase Test", iconName: "keyboard", iconTint: .blue,
                                  order: 0, defaultDescription: "")
    }
    var shortcutDefinitions: [PluginShortcutDefinition] {
        [PluginShortcutDefinition(id: "cycle", title: "Cycle", description: "", actionID: "cycle",
                                  scope: .whilePluginActive, defaultBinding: binding, isRequired: false)]
    }
    func handleShortcutEvent(id: String, phase: PluginShortcutEventPhase) {}
    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?) {
        latestBinding = binding; notifications += 1
    }
}
