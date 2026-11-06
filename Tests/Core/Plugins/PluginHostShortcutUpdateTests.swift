import Combine
import MacToolsPluginKit
import XCTest
@testable import AIAssistantPlugin
@testable import MacTools

@MainActor
final class PluginHostShortcutUpdateTests: XCTestCase {
    func testNewClipboardFilterDefaultYieldsToEventHandledOwner() async throws {
        let owner = ShortcutPlugin(scope: .whilePluginActive)
        let clipboard = ClipboardFilterShortcutPlugin(ownerScope: .whilePluginActive)
        let host = makePluginHostForTests(plugins: [owner, clipboard],
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))
        let binding = ShortcutBinding(keyCode: 19, modifiers: [.option, .command])
        XCTAssertNil(host.setShortcutBindingAndReturnError(binding, for: "batch.shortcut.0"))
        clipboard.includesFilter = true
        clipboard.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(owner.shortcutBindingResolver?("0"), binding)
        XCTAssertEqual(owner.deliveries.last { $0.id == "0" }?.binding, binding)
        XCTAssertNil(clipboard.shortcutBindingResolver?("panel-filter-image"))
        XCTAssertTrue(clipboard.deliveries.contains { $0.id == "panel-filter-image" && $0.binding == nil })
        clipboard.deliveries.removeAll()
        host.clearShortcut(for: "batch.shortcut.0")
        XCTAssertEqual(clipboard.shortcutBindingResolver?("panel-filter-image"), binding)
        XCTAssertEqual(clipboard.deliveries.last { $0.id == "panel-filter-image" }?.binding, binding)
    }

    func testClipboardFilterResetYieldsToExistingOwnerAndRestoresWhenAvailable() {
        let suite = "ClipboardFilterResetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(userDefaults: defaults)
        let inherited = ShortcutBinding(keyCode: 20, modifiers: [.option, .command])
        let custom = ShortcutBinding(keyCode: 3, modifiers: [.control, .option, .command])
        let ownerID = "clipboard.shortcut.existing-paste"
        let filterID = "clipboard.shortcut.panel-filter-image"
        store.setCustomization(.custom(inherited), for: ownerID)
        let plugin = ClipboardFilterShortcutPlugin(ownerScope: .whilePluginActive)
        plugin.includesFilter = true
        plugin.filterBinding = inherited
        let host = PluginHost(plugins: [plugin], shortcutStore: store,
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()),
            loadDynamicPluginsOnInit: false)
        XCTAssertNil(plugin.shortcutBindingResolver?("panel-filter-image"))
        XCTAssertNil(host.setShortcutBindingAndReturnError(custom, for: filterID))
        XCTAssertEqual(plugin.shortcutBindingResolver?("panel-filter-image"), custom)

        host.resetShortcut(for: filterID)

        XCTAssertEqual(store.customization(for: filterID), .inheritDefault)
        XCTAssertEqual(plugin.shortcutBindingResolver?("existing-paste"), inherited)
        XCTAssertNil(plugin.shortcutBindingResolver?("panel-filter-image"))
        XCTAssertNil(plugin.deliveries.last { $0.id == "panel-filter-image" }?.binding)
        XCTAssertNotNil(host.setShortcutBindingAndReturnError(inherited, for: filterID))
        XCTAssertEqual(store.customization(for: filterID), .inheritDefault)
        host.clearShortcut(for: ownerID)
        XCTAssertEqual(plugin.shortcutBindingResolver?("panel-filter-image"), inherited)
        XCTAssertEqual(plugin.deliveries.last { $0.id == "panel-filter-image" }?.binding, inherited)
    }

    func testActiveOnlyConsumerReceivesInitialAndChangedBindingsWithoutEventHandling() async {
        let plugin = ClipboardFilterShortcutPlugin(ownerScope: .whilePluginActive)
        plugin.includesFilter = true
        let host = makePluginHostForTests(plugins: [plugin],
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))
        XCTAssertEqual(plugin.deliveries.count, 2)
        XCTAssertTrue(plugin.deliveries.contains { $0.id == "existing-paste" && $0.binding == nil })
        XCTAssertNotNil(plugin.deliveries.first { $0.id == "panel-filter-image" }?.binding)
        plugin.deliveries.removeAll()
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertTrue(plugin.deliveries.isEmpty)
        let custom = ShortcutBinding(keyCode: 3, modifiers: [.command, .option, .control])
        let id = "clipboard.shortcut.panel-filter-image"
        XCTAssertNil(host.setShortcutBindingAndReturnError(custom, for: id))
        XCTAssertEqual(plugin.deliveries.last?.binding, custom)
        host.clearShortcut(for: id)
        XCTAssertEqual(plugin.deliveries.last?.id, "panel-filter-image")
        XCTAssertNil(plugin.deliveries.last?.binding)
    }

    func testClipboardFilterDefaultYieldsWhenRestoringExistingCustomization() async throws {
        let source = ClipboardFilterShortcutPlugin(ownerScope: .whilePluginActive)
        let host = makePluginHostForTests(plugins: [source],
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))
        let binding = ShortcutBinding(keyCode: 19, modifiers: [.option, .command])
        XCTAssertNil(host.setShortcutBindingAndReturnError(binding, for: "clipboard.shortcut.existing-paste"))
        let oldBackup = host.makePreferencesBackup()
        source.includesFilter = true
        source.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        for backup in [oldBackup, host.makePreferencesBackup()] {
            let destination = ClipboardFilterShortcutPlugin(ownerScope: .whilePluginActive)
            destination.includesFilter = true
            let restored = makePluginHostForTests(plugins: [destination],
                globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))
            let result = try restored.importPreferences(backup)
            XCTAssertTrue(result.shortcutErrors.isEmpty, "\(result.shortcutErrors)")
            XCTAssertEqual(destination.shortcutBindingResolver?("existing-paste"), binding)
            XCTAssertNil(destination.shortcutBindingResolver?("panel-filter-image"))
            restored.clearShortcut(for: "clipboard.shortcut.existing-paste")
            XCTAssertEqual(destination.shortcutBindingResolver?("panel-filter-image"), binding)
        }
    }

    func testNewClipboardFilterDefaultYieldsToExistingPanelAndGlobalCustomizations() async throws {
        for scope in [ShortcutScope.whilePluginActive, .global] {
            let plugin = ClipboardFilterShortcutPlugin(ownerScope: scope)
            let host = makePluginHostForTests(plugins: [plugin],
                globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))
            let ownerID = "clipboard.shortcut.existing-paste"
            let filterID = "clipboard.shortcut.panel-filter-image"
            let binding = ShortcutBinding(keyCode: 19, modifiers: [.option, .command])
            XCTAssertNil(host.setShortcutBindingAndReturnError(binding, for: ownerID))
            plugin.includesFilter = true
            plugin.onStateChange?()
            await host.waitForScheduledPluginStateRebuildForTests()
            XCTAssertEqual(plugin.shortcutBindingResolver?("existing-paste"), binding)
            XCTAssertNil(plugin.shortcutBindingResolver?("panel-filter-image"))
            let row = try XCTUnwrap(host.shortcutItems.first { $0.id == filterID })
            XCTAssertFalse(row.canClear)
            XCTAssertNotNil(row.errorMessage)
            host.clearShortcut(for: ownerID)
            XCTAssertEqual(plugin.shortcutBindingResolver?("panel-filter-image"), binding)
        }
    }

    func testClipboardFilterDefaultPreservesReverseScopeShortcutAcrossUpgradeAndRestore() async throws {
        let forward = ShortcutBinding(keyCode: 18, modifiers: [.option, .command])
        let reverse = ShortcutBinding(keyCode: 18, modifiers: [.option, .shift, .command])
        func plugin() -> ClipboardFilterShortcutPlugin {
            let result = ClipboardFilterShortcutPlugin(ownerScope: .whilePluginActive)
            result.ownerDefinitionID = "panel-cycle-scope"
            result.filterDefinitionID = "panel-filter-any-content"
            result.filterBinding = reverse
            return result
        }
        let source = plugin()
        let host = makePluginHostForTests(plugins: [source],
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))
        let ownerID = "clipboard.shortcut.panel-cycle-scope"
        XCTAssertNil(host.setShortcutBindingAndReturnError(forward, for: ownerID))
        let oldBackup = host.makePreferencesBackup()
        source.includesFilter = true
        source.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(source.shortcutBindingResolver?("panel-cycle-scope"), forward)
        XCTAssertNil(source.shortcutBindingResolver?("panel-filter-any-content"))
        XCTAssertTrue(source.deliveries.contains { $0.id == "panel-filter-any-content" && $0.binding == nil })

        for backup in [oldBackup, host.makePreferencesBackup()] {
            let destination = plugin()
            destination.includesFilter = true
            let restored = makePluginHostForTests(plugins: [destination],
                globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))
            let result = try restored.importPreferences(backup)
            XCTAssertTrue(result.shortcutErrors.isEmpty, "\(result.shortcutErrors)")
            XCTAssertEqual(destination.shortcutBindingResolver?("panel-cycle-scope"), forward)
            XCTAssertNil(destination.shortcutBindingResolver?("panel-filter-any-content"))
            restored.clearShortcut(for: ownerID)
            XCTAssertEqual(destination.shortcutBindingResolver?("panel-filter-any-content"), reverse)
        }
    }

    func testClipboardReverseScopeChordPreservesOtherPluginsExistingBindings() {
        let suite = "ClipboardReverseScopeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(userDefaults: defaults)
        let forward = ShortcutBinding(keyCode: 15, modifiers: [.option, .command])
        let reverse = ShortcutBinding(keyCode: 15, modifiers: [.option, .shift, .command])
        store.setCustomization(.custom(forward), for: "clipboard.shortcut.panel-cycle-scope")
        store.setCustomization(.custom(reverse), for: "batch.shortcut.0")
        let clipboard = ClipboardFilterShortcutPlugin(ownerScope: .whilePluginActive)
        clipboard.ownerDefinitionID = "panel-cycle-scope"
        let other = ShortcutPlugin(scope: .whilePluginActive)
        let host = PluginHost(plugins: [clipboard, other], shortcutStore: store,
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()),
            loadDynamicPluginsOnInit: false)
        XCTAssertEqual(clipboard.shortcutBindingResolver?("panel-cycle-scope"), forward)
        XCTAssertEqual(other.shortcutBindingResolver?("0"), reverse)
        XCTAssertEqual(other.deliveries.last { $0.id == "0" }?.binding, reverse)
        withExtendedLifetime(host) {}
    }

    func testShortcutRestorePreservesClipboardGlobalOwnerAndUnrelatedAssignments() throws {
        let suite = "ClipboardGlobalRestoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(userDefaults: defaults)
        let forward = ShortcutBinding(keyCode: 15, modifiers: [.option, .command])
        let reverse = ShortcutBinding(keyCode: 15, modifiers: [.option, .shift, .command])
        let unrelated = ShortcutBinding(keyCode: 35, modifiers: [.control, .command])
        store.setCustomization(.custom(reverse), for: "clipboard.shortcut.private-copy")
        store.setCustomization(.custom(forward), for: "clipboard.shortcut.panel-cycle-scope")
        store.setCustomization(.custom(unrelated), for: "batch.shortcut.0")
        func clipboard() -> ClipboardFilterShortcutPlugin {
            let plugin = ClipboardFilterShortcutPlugin(ownerScope: .global)
            plugin.ownerDefinitionID = "private-copy"
            plugin.includesFilter = true
            plugin.filterDefinitionID = "panel-cycle-scope"
            plugin.filterBinding = .init(keyCode: 48, modifiers: .control)
            return plugin
        }
        let source = PluginHost(plugins: [clipboard(), ShortcutPlugin(scope: .whilePluginActive)],
            shortcutStore: store, pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()),
            loadDynamicPluginsOnInit: false)
        let backup = source.makePreferencesBackup()
        let restoredClipboard = clipboard()
        let restoredOther = ShortcutPlugin(scope: .whilePluginActive)
        let restored = makePluginHostForTests(plugins: [restoredClipboard, restoredOther],
            loadDynamicPluginsOnInit: false,
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))
        let selection = PreferencesBackupSelection(includesApplicationPreferences: false,
            includesPluginLayout: false, includesShortcuts: true, includesAutomation: false,
            includesRunLinks: false, pluginPreferenceIDs: [])
        let result = try restored.importPreferences(backup, selection: selection)

        XCTAssertTrue(result.shortcutErrors.isEmpty, "\(result.shortcutErrors)")
        XCTAssertEqual(restoredClipboard.shortcutBindingResolver?("private-copy"), reverse)
        XCTAssertEqual(restoredClipboard.shortcutBindingResolver?("panel-cycle-scope"), forward)
        XCTAssertEqual(restoredOther.shortcutBindingResolver?("0"), unrelated)
    }

    func testAIAssistantSwitchesReleaseAndRestoreGlobalRegistrations() async {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = AIAssistantPlugin(context: PluginRuntimeContext(
            pluginID: "ai-assistant", storage: storage
        ))
        let registrar = FakeCarbonHotKeyRegistrar()
        let manager = GlobalShortcutManager(registrar: registrar)
        let host = makePluginHostForTests(plugins: [plugin], globalShortcutManager: manager)
        let shortcutIDs = Set(plugin.shortcutDefinitions.map { "ai-assistant.shortcut.\($0.id)" })
        func registeredIDs() -> Set<String> {
            Set(manager.registrationStatuses.keys).intersection(shortcutIDs)
        }
        XCTAssertEqual(registeredIDs(), shortcutIDs)

        var prompts = AIAssistantPromptStore(storage: storage).loadPrompts()
        prompts[1].isEnabled = false
        XCTAssertNil(plugin.savePromptsConfiguration(prompts))
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(registeredIDs().count, 2)
        XCTAssertFalse(registeredIDs().contains("ai-assistant.shortcut.ai-assistant.prompt.summarize"))

        plugin.handleAction(.setSwitch(false))
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertTrue(registeredIDs().isEmpty)
        XCTAssertEqual(plugin.shortcutDefinitions.count, 3)
        let custom = ShortcutBinding(keyCode: 18, modifiers: [.control, .option, .command])
        let summaryID = "ai-assistant.shortcut.ai-assistant.prompt.summarize"
        XCTAssertNil(host.setShortcutBindingAndReturnError(custom, for: summaryID))
        XCTAssertEqual(plugin.shortcutBindingResolver?("ai-assistant.prompt.summarize"), custom)
        XCTAssertFalse(registrar.registeredBindings.contains(custom))

        plugin.handleAction(.setSwitch(true))
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(registeredIDs().count, 2)
        XCTAssertFalse(registrar.registeredBindings.contains(custom))
        host.clearShortcut(for: summaryID)
        XCTAssertNil(plugin.shortcutBindingResolver?("ai-assistant.prompt.summarize"))
        XCTAssertNil(host.setShortcutBindingAndReturnError(custom, for: summaryID))

        prompts[1].isEnabled = true
        XCTAssertNil(plugin.savePromptsConfiguration(prompts))
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(registeredIDs(), shortcutIDs)
        XCTAssertTrue(registrar.registeredBindings.contains(custom))
    }

    func testCombinedUpdateProjectsAvailabilityOnceAndReusesShortcutDefinitions() async {
        let plugin = AvailabilityShortcutPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.availabilityReads = 0
        plugin.definitionReads = 0
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()

        XCTAssertEqual(plugin.availabilityReads, 1)
        XCTAssertEqual(plugin.definitionReads, 2)
        XCTAssertEqual(host.actionShortcutCatalogItems.first { $0.reference == plugin.reference }?.status, .unassigned)
    }

    func testShortcutResolverReadsLiveDefinitionsOutsidePresentation() {
        let plugin = AvailabilityShortcutPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.defaultBinding = nil
        XCTAssertNil(plugin.shortcutBindingResolver?("exit"))
        XCTAssertEqual(host.actionAvailability(for: plugin.reference), .unavailable("Exit shortcut required"))
    }

    func testReentrantStateChangeInvalidatesPresentationShortcutSnapshot() async {
        let plugin = AvailabilityShortcutPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.beforeAvailability = { [weak plugin] in
            plugin?.beforeAvailability = nil
            plugin?.defaultBinding = nil
            plugin?.onStateChange?()
        }
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()

        XCTAssertEqual(host.actionShortcutCatalogItems.first { $0.reference == plugin.reference }?.status,
                       .unavailable("Exit shortcut required"))
        await host.waitForScheduledPluginStateRebuildForTests()
    }

    func testCatalogConsumerSeesFreshRegistryAndItsShortcutChangesReachPresentation() async {
        let plugin = AvailabilityShortcutPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.actionTitle = "Updated action"
        plugin.onCatalogChange = { [weak plugin] in
            guard let plugin else { return }
            XCTAssertEqual(plugin.actionExecutionHostContext?.item(for: plugin.reference)?.title, "Updated action")
            plugin.defaultBinding = nil
        }
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()

        XCTAssertEqual(host.actionShortcutCatalogItems.first { $0.reference == plugin.reference }?.status,
                       .unavailable("Exit shortcut required"))
        XCTAssertNil(plugin.shortcutBindingResolver?("exit"))
    }

    func testPhaseShortcutsReadDefinitionsOncePerHostPhase() async {
        let plugin = ShortcutPlugin(scope: .whilePluginActive)
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.definitionReads = 0
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(plugin.definitionReads, 2, "Rebuild and registration each read one fresh snapshot")
        XCTAssertEqual(host.shortcutItems.filter { $0.pluginID == plugin.metadata.id }.count, 16)
    }

    func testUnchangedStateDoesNotRedeliverPhaseBindings() async {
        let plugin = ShortcutPlugin(scope: .whilePluginActive)
        let host = makePluginHostForTests(plugins: [plugin])
        XCTAssertEqual(plugin.deliveries.count, 16, "Each initial nil must be delivered")
        plugin.deliveries.removeAll()
        var catalogPublications = 0
        let observation = host.$actionShortcutCatalogItems.dropFirst().sink { _ in catalogPublications += 1 }
        for _ in 0..<20 { plugin.onStateChange?() }
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertTrue(plugin.deliveries.isEmpty)
        XCTAssertEqual(catalogPublications, 0)
        withExtendedLifetime(observation) {}
    }

    func testDynamicDefaultChangeAndClearStillNotifyListener() async {
        let plugin = ShortcutPlugin(scope: .whilePluginActive)
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.deliveries.removeAll()
        let binding = ShortcutBinding(keyCode: 3, modifiers: [.command, .option, .control])
        plugin.defaultBinding = binding
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(plugin.deliveries.map(\.id), ["0"])
        XCTAssertEqual(plugin.deliveries.first?.binding, binding)
        plugin.deliveries.removeAll()
        plugin.defaultBinding = nil
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(plugin.deliveries.map(\.id), ["0"])
        XCTAssertNil(plugin.deliveries.first?.binding)
    }

    func testReappearingShortcutReceivesInitialNilAgain() async {
        let plugin = ShortcutPlugin(scope: .whilePluginActive)
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.deliveries.removeAll()
        plugin.includesFirstShortcut = false
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        plugin.includesFirstShortcut = true
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(plugin.deliveries.map(\.id), ["0"])
        XCTAssertNil(plugin.deliveries.first?.binding)
    }

    func testCompletedMigrationDoesNotReadLegacyPayloadOnStateUpdates() async {
        let plugin = ShortcutPlugin(scope: .whilePluginActive)
        let host = makePluginHostForTests(plugins: [plugin])
        XCTAssertEqual(plugin.migrationReads, 1)
        XCTAssertEqual(plugin.migrationCompletions, 1)
        for _ in 0..<3 {
            plugin.onStateChange?()
            await host.waitForScheduledPluginStateRebuildForTests()
        }
        XCTAssertEqual(plugin.migrationReads, 1)
        XCTAssertEqual(plugin.migrationCompletions, 1)
    }

    func testFailedLegacyPayloadReadDoesNotMarkMigrationComplete() {
        let suite = "PluginHostShortcutUpdateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let plugin = ShortcutPlugin(scope: .whilePluginActive)
        plugin.failsMigrationRead = true
        let host = makePluginHostForTests(plugins: [plugin], suiteName: suite)
        XCTAssertFalse(ActionShortcutAssignmentStore(userDefaults: defaults)
            .hasMigratedLegacyPluginAssignments(pluginID: plugin.metadata.id))
        XCTAssertEqual(plugin.migrationCompletions, 0)
        XCTAssertNil(plugin.onStateChange, "A failed getter must still isolate the plugin")
        withExtendedLifetime(host) {}
    }

    func testBatchResetUnregistersEveryBindingBeforeReturningAndPublishesOnce() {
        let plugin = ShortcutPlugin(scope: .global)
        let suite = "PluginHostShortcutUpdateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(userDefaults: defaults)
        let bindings = (0..<16).map { ShortcutBinding(keyCode: UInt16($0), modifiers: [.command, .option, .control]) }
        for (index, binding) in bindings.enumerated() {
            store.setCustomization(.custom(binding), for: "batch.shortcut.\(index)")
        }
        let registrar = FakeCarbonHotKeyRegistrar()
        let manager = GlobalShortcutManager(registrar: registrar)
        let host = PluginHost(plugins: [plugin], shortcutStore: store,
                              pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
                              preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
                              globalShortcutManager: manager)
        XCTAssertTrue(Set(bindings).isSubset(of: Set(registrar.registeredBindings)))
        var publications = 0
        let unregisteredBeforeReset = registrar.unregisteredCount
        let subscription = host.menuBarPanelContentDidChange.sink { publications += 1 }
        plugin.resetShortcutCustomizations?((0..<16).map(String.init) + ["unknown", "0"])
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(registrar.unregisteredCount - unregisteredBeforeReset, 16)
        XCTAssertFalse(manager.registrationStatuses.keys.contains { $0.hasPrefix("batch.shortcut.") })
        for index in 0..<16 {
            XCTAssertEqual(store.customization(for: "batch.shortcut.\(index)"), .inheritDefault)
        }
        withExtendedLifetime(subscription) {}
    }
}

@MainActor
private final class ClipboardFilterShortcutPlugin: MacToolsPlugin, PluginShortcutBindingChangeHandling {
    let metadata = PluginMetadata(id: "clipboard", title: "Clipboard", iconName: "clipboard",
                                  iconTint: .blue, order: 0, defaultDescription: "")
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var includesFilter = false
    var deliveries: [(id: String, binding: ShortcutBinding?)] = []
    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?) {
        deliveries.append((id, binding))
    }
    let ownerScope: ShortcutScope
    var ownerDefinitionID = "existing-paste"
    var filterDefinitionID = "panel-filter-image"
    var filterBinding = ShortcutBinding(keyCode: 19, modifiers: [.option, .command])

    init(ownerScope: ShortcutScope) { self.ownerScope = ownerScope }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        var definitions = [PluginShortcutDefinition(id: ownerDefinitionID, title: "Existing shortcut", description: "",
            actionID: ownerDefinitionID, scope: ownerScope, defaultBinding: nil, isRequired: false)]
        if includesFilter {
            definitions.append(PluginShortcutDefinition(id: filterDefinitionID, title: "Filter", description: "",
                actionID: filterDefinitionID, scope: .whilePluginActive,
                defaultBinding: filterBinding, isRequired: false))
        }
        return definitions
    }
}

@MainActor
private final class AvailabilityShortcutPlugin: MacToolsPlugin, PluginActionProviding,
    PluginActionExecutionHostContextConsuming {
    let metadata = PluginMetadata(id: "availability-shortcut", title: "Availability", iconName: "keyboard",
                                  iconTint: .blue, order: 0, defaultDescription: "")
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var actionExecutionHostContext: PluginActionExecutionHostContext?
    var defaultBinding: ShortcutBinding? = ShortcutBinding(keyCode: 3, modifiers: [.command, .option, .control])
    var actionTitle = "Action"
    var definitionReads = 0
    var availabilityReads = 0
    var beforeAvailability: (() -> Void)?
    var onCatalogChange: (() -> Void)?
    var reference: ActionReference { ActionReference(key: ActionKey(providerID: metadata.id, actionID: "enter")) }
    var shortcutDefinitions: [PluginShortcutDefinition] {
        definitionReads += 1
        return [PluginShortcutDefinition(id: "exit", title: "Exit", description: "", actionID: "exit",
                                         scope: .whilePluginActive, defaultBinding: defaultBinding, isRequired: true)]
    }
    var actionDefinitions: [ActionDefinition] {
        [ActionDefinition(key: reference.key, title: actionTitle, description: "", systemImage: "keyboard",
                          externalInvocationPolicy: .allowed, capabilities: [.background])]
    }
    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        availabilityReads += 1
        beforeAvailability?()
        return shortcutBindingResolver?("exit") == nil ? .unavailable("Exit shortcut required") : .available
    }
    func actionExecutionCatalogDidChange() { onCatalogChange?() }
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }
}

@MainActor
private final class ShortcutPlugin: MacToolsPlugin, PluginShortcutEventHandling, PluginShortcutResetRequesting,
    PluginShortcutBindingChangeHandling, PluginLegacyActionShortcutProviding {
    struct Delivery {
        let id: String
        let binding: ShortcutBinding?
    }
    let metadata = PluginMetadata(id: "batch", title: "Batch", iconName: "keyboard", iconTint: .blue,
                                  order: 0, defaultDescription: "")
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var resetShortcutCustomizations: (([String]) -> Void)?
    var definitionReads = 0
    var defaultBinding: ShortcutBinding?
    var includesFirstShortcut = true
    var deliveries: [Delivery] = []
    var migrationReads = 0
    var migrationCompletions = 0
    var failsMigrationRead = false
    let scope: ShortcutScope
    init(scope: ShortcutScope) { self.scope = scope }
    var shortcutDefinitions: [PluginShortcutDefinition] {
        definitionReads += 1
        return (includesFirstShortcut ? 0..<16 : 1..<16).map {
            PluginShortcutDefinition(id: String($0), title: "Shortcut \($0)", description: "", actionID: String($0),
                                     scope: scope, defaultBinding: $0 == 0 ? defaultBinding : nil, isRequired: false)
        }
    }
    var legacyActionShortcutAssignments: [LegacyActionShortcutAssignment] {
        migrationReads += 1
        if failsMigrationRead { raiseTestPluginException(reason: "Legacy payload unavailable") }
        return []
    }
    func legacyActionShortcutsDidMigrate() { migrationCompletions += 1 }
    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?) {
        deliveries.append(Delivery(id: id, binding: binding))
    }
    func handleShortcutEvent(id: String, phase: PluginShortcutEventPhase) {}
}
