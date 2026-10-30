import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools
@testable import ActionGridPlugin

@MainActor
final class StarterPackControllerTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let name = "StarterPackTests-\(UUID())"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    func testOnboardingIsOptionalAndDoesNotReappearForExistingSetups() {
        let store = defaults()
        let fixture = Fixture()
        let first = StarterPackController(defaults: store, hasExistingSetup: false, services: fixture.services)
        XCTAssertTrue(first.needsOnboarding)
        first.finishOnboarding()
        XCTAssertFalse(StarterPackController(defaults: store, hasExistingSetup: false, services: fixture.services).needsOnboarding)
        XCTAssertTrue(fixture.installs.isEmpty)
        let existingStore = defaults()
        existingStore.set(Data(), forKey: MenuBarPanelStore.storageKey)
        XCTAssertTrue(StarterPackController.hasExistingPreferences(in: existingStore))
        let existing = StarterPackController(defaults: existingStore, hasExistingSetup: true, services: fixture.services)
        XCTAssertFalse(existing.needsOnboarding)
        XCTAssertTrue(existing.selectedPacks.isEmpty)
        XCTAssertEqual(first.selectedPacks, [.everyday])
    }

    func testUnfinishedOnboardingSurvivesPersistedDefaultsAndCanBeDeferredAndResumed() {
        let store = defaults()
        let fixture = Fixture()
        let first = StarterPackController(defaults: store, hasExistingSetup: false, services: fixture.services)
        first.selectPack(.windows, isSelected: true)
        first.updateDraft {
            $0.selectedPluginIDs.remove("keep-awake")
            $0.seedGrid = true
            $0.addToPanel = false
            $0.panelID = MenuBarPanelDefinition.featuresID
        }
        store.set(Data(), forKey: MenuBarPanelStore.storageKey)

        let reopened = StarterPackController(defaults: store, hasExistingSetup: true, services: fixture.services)
        XCTAssertTrue(reopened.needsOnboarding)
        XCTAssertEqual(reopened.selectedPacks, [.everyday, .windows])
        XCTAssertFalse(reopened.selectedIDs.contains("keep-awake"))
        XCTAssertTrue(reopened.draft.seedGrid)
        XCTAssertTrue(reopened.draft.addToPanel)
        XCTAssertNil(reopened.draft.panelID)
        reopened.deferOnboarding()

        let deferred = StarterPackController(defaults: store, hasExistingSetup: true, services: fixture.services)
        XCTAssertFalse(deferred.needsOnboarding)
        XCTAssertTrue(deferred.canResumeOnboarding)
        deferred.resumeOnboarding()
        XCTAssertTrue(deferred.needsOnboarding)
        deferred.selectPack(.meetings, isSelected: true)
        XCTAssertFalse(deferred.selectedIDs.contains("keep-awake"))
        deferred.finishOnboarding()
        let completed = StarterPackController(defaults: store, hasExistingSetup: true, services: fixture.services)
        XCTAssertFalse(completed.canResumeOnboarding)
        XCTAssertTrue(completed.selectedPacks.isEmpty)
        XCTAssertTrue(fixture.installs.isEmpty)
    }

    func testFailedOnboardingPreservesNewerDraftThroughResumeAndRestart() async {
        let store = defaults()
        let fixture = Fixture()
        fixture.unusable = ["keep-awake"]
        let first = StarterPackController(defaults: store, hasExistingSetup: false, services: fixture.services)
        first.updateDraft { $0.addToPanel = false }
        first.apply()
        await first.waitForInstallation()
        XCTAssertTrue(first.needsOnboarding)
        first.selectPack(.writing, isSelected: true)
        first.updateDraft { $0.selectedPluginIDs.remove("display-brightness") }
        let editedIDs = first.selectedIDs
        first.deferOnboarding()
        first.resumeOnboarding()
        XCTAssertEqual(first.selectedIDs, editedIDs)
        XCTAssertEqual(first.appliedPacks, [.everyday])

        let reopened = StarterPackController(defaults: store, hasExistingSetup: true, services: fixture.services)
        XCTAssertTrue(reopened.needsOnboarding)
        XCTAssertEqual(reopened.selectedPacks, [.everyday, .writing])
        XCTAssertEqual(reopened.selectedIDs, editedIDs)
        XCTAssertTrue(reopened.hasChanges)
        fixture.unusable = []
        XCTAssertTrue(reopened.canApply)
        reopened.apply()
        await reopened.waitForInstallation()
        XCTAssertFalse(reopened.canResumeOnboarding)
        XCTAssertEqual(fixture.installs.filter { $0 == "system-status" }.count, 1)
    }

    func testOnlyMissingPluginsInstallAndExistingPlacementsKeepTheirIdentity() async {
        let fixture = Fixture()
        fixture.installed = ["system-status", "keep-awake"]
        let customPanel = MenuBarPanelDefinition(id: "work", name: "Work", systemImage: "briefcase")
        fixture.layout.panels.append(customPanel)
        let existing = MenuBarPanelPlacement(item: .init(pluginID: "keep-awake", itemID: "control"))
        let copy = MenuBarPanelPlacement(item: existing.item)
        fixture.layout.placementsByPanelID[customPanel.id] = [existing, copy]
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: true, services: fixture.services)
        controller.selectPack(.everyday, isSelected: true)
        controller.updateDraft { $0.panelID = MenuBarPanelDefinition.featuresID; $0.addToPanel = true }
        let preview = controller.panelItemsByPanelID()
        XCTAssertEqual(preview[customPanel.id], [existing.item, copy.item])
        XCTAssertEqual(preview[MenuBarPanelDefinition.featuresID]?.count, 5)
        controller.apply()
        await controller.waitForInstallation()
        XCTAssertEqual(fixture.installs, ["microphone-mute", "system-mute", "lock-screen", "display-brightness"])
        XCTAssertEqual(fixture.layout.placementsByPanelID[customPanel.id], [existing, copy])
        XCTAssertEqual(fixture.layout.placementsByPanelID[MenuBarPanelDefinition.featuresID]?.count, 5)
        XCTAssertNil(fixture.layout.placementsByPanelID[MenuBarPanelDefinition.componentsID])
        XCTAssertEqual(controller.panelItemsByPanelID(showsAppliedSelection: true), preview)
        XCTAssertEqual(controller.resultPanelID, MenuBarPanelDefinition.featuresID)
        XCTAssertFalse(controller.hasChanges)
        controller.apply()
        await controller.waitForInstallation()
        XCTAssertEqual(fixture.installs.count, 4)
    }

    func testCatalogMustLoadBeforeDownloadsStartAndOnboardingCompletes() async {
        let fixture = Fixture()
        fixture.catalogReady = false
        let store = defaults()
        let controller = StarterPackController(defaults: store, hasExistingSetup: false, services: fixture.services)
        XCTAssertFalse(controller.apply())
        await controller.waitForInstallation()
        XCTAssertTrue(fixture.installs.isEmpty)
        XCTAssertTrue(controller.needsOnboarding)
        XCTAssertFalse(store.bool(forKey: StarterPackController.onboardingKey))

        fixture.catalogReady = true
        XCTAssertNil(controller.draft.panelID)
        let preview = controller.panelItemsByPanelID()
        XCTAssertEqual(preview[MenuBarPanelDefinition.componentsID], [.init(pluginID: "system-status", itemID: "widget")])
        XCTAssertEqual(preview[MenuBarPanelDefinition.featuresID]?.count, 5)
        XCTAssertTrue(controller.apply())
        await controller.waitForInstallation()
        XCTAssertEqual(fixture.installed, Set(StarterPack.everyday.pluginIDs))
        XCTAssertEqual(controller.panelItemsByPanelID(showsAppliedSelection: true), preview)
        XCTAssertEqual(controller.resultPanelID, MenuBarPanelDefinition.componentsID)
        XCTAssertFalse(controller.needsOnboarding)
    }

    func testHiddenDefaultPanelFallsBackToFirstVisiblePanel() async {
        let fixture = Fixture()
        fixture.layout.panels[0].isHidden = true
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: false, services: fixture.services)
        let preview = controller.panelItemsByPanelID()
        XCTAssertEqual(Set(preview.keys), [MenuBarPanelDefinition.featuresID])
        XCTAssertEqual(preview[MenuBarPanelDefinition.featuresID]?.count, 6)
        XCTAssertTrue(controller.apply())
        await controller.waitForInstallation()
        XCTAssertEqual(controller.panelItemsByPanelID(showsAppliedSelection: true), preview)
        XCTAssertEqual(controller.resultPanelID, MenuBarPanelDefinition.featuresID)
    }

    func testSavedDraftPreservesExplicitTargetAndSupportsDefaultRouting() throws {
        let previous = Data(#"{"selectedPluginIDs":["keep-awake"],"addToPanel":true,"panelID":"features","seedGrid":false,"assignShortcut":false}"#.utf8)
        let restored = try JSONDecoder().decode(StarterPackDraft.self, from: previous)
        XCTAssertEqual(restored.panelID, MenuBarPanelDefinition.featuresID)
        let fresh = StarterPackDraft(selectedPluginIDs: ["keep-awake"])
        let encoded = try JSONEncoder().encode(fresh)
        XCTAssertNil(try JSONDecoder().decode(StarterPackDraft.self, from: encoded).panelID)
    }

    func testAppliedPreviewExcludesFailedPlacementsAndUnusablePlugins() async {
        let fixture = Fixture()
        fixture.unusable = ["microphone-mute"]
        var services = fixture.services
        let addPlacement = services.addPlacement
        services.addPlacement = { item, panel in
            item.pluginID != "system-status" && addPlacement(item, panel)
        }
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: false, services: services)
        XCTAssertTrue(controller.apply())
        await controller.waitForInstallation()
        let preview = controller.panelItemsByPanelID(showsAppliedSelection: true)
        XCTAssertNil(preview[MenuBarPanelDefinition.componentsID])
        XCTAssertEqual(Set(preview[MenuBarPanelDefinition.featuresID, default: []].map(\.pluginID)),
                       ["keep-awake", "system-mute", "lock-screen", "display-brightness"])
        XCTAssertEqual(controller.resultPanelID, MenuBarPanelDefinition.featuresID)
        XCTAssertEqual(controller.setupMessages.count, 1)
    }

    func testInstalledToolsCanBeAddedToPanelsWithoutACatalog() async {
        let fixture = Fixture()
        fixture.installed = Set(StarterPack.everyday.pluginIDs)
        fixture.catalogReady = false
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: true, services: fixture.services)
        controller.selectPack(.everyday, isSelected: true)
        controller.updateDraft { $0.addToPanel = true }
        XCTAssertTrue(controller.apply())
        await controller.waitForInstallation()
        XCTAssertTrue(fixture.installs.isEmpty)
        XCTAssertEqual(fixture.layout.placementsByPanelID.values.flatMap { $0 }.count, 6)
    }

    func testOptingOutOfPanelLayoutDoesNotAddPlacements() async {
        let fixture = Fixture()
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: false, services: fixture.services)
        controller.updateDraft { $0.addToPanel = false }
        controller.apply()
        await controller.waitForInstallation()
        XCTAssertEqual(fixture.installs.count, 6)
        XCTAssertTrue(fixture.layout.placementsByPanelID.isEmpty)
        XCTAssertTrue(controller.panelItemsByPanelID(showsAppliedSelection: true).isEmpty)
    }

    func testInstalledPackageThatCannotLoadReportsItsErrorWithoutAddingControls() async {
        let fixture = Fixture()
        var services = fixture.services
        services.isUsable = { _ in false }
        let loadFailure = "Rejected test bundle"
        services.readinessMessage = { _ in loadFailure }
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: false, services: services)
        controller.apply()
        await controller.waitForInstallation()
        XCTAssertEqual(fixture.installed.count, 6)
        XCTAssertTrue(controller.results.allSatisfy { $0.outcome == .failed(loadFailure) })
        XCTAssertTrue(fixture.layout.placementsByPanelID.isEmpty)
    }

    func testPartialFailureKeepsSuccessesAndRetryInstallsOnlyTheMissingPlugin() async {
        let fixture = Fixture()
        fixture.failures = ["microphone-mute"]
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: false, services: fixture.services)
        controller.apply()
        await controller.waitForInstallation()
        XCTAssertEqual(controller.results.filter { if case .failed = $0.outcome { true } else { false } }.count, 1)
        XCTAssertEqual(fixture.layout.placementsByPanelID.values.flatMap { $0 }.count, 5)
        let preserved = fixture.layout.placementsByPanelID
        fixture.failures = []
        controller.apply()
        await controller.waitForInstallation()
        XCTAssertEqual(fixture.installs.suffix(1), ["microphone-mute"])
        XCTAssertEqual(fixture.installs.count, 7)
        XCTAssertEqual(fixture.layout.placementsByPanelID[MenuBarPanelDefinition.componentsID]?.prefix(3), preserved[MenuBarPanelDefinition.componentsID]?.prefix(3))
    }

    func testStopKeepsTheCurrentInstallAndSkipsTheRemainingPlugins() async {
        let fixture = Fixture()
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: false, services: fixture.services)
        fixture.didInstall = { controller.stopAfterCurrentPlugin() }
        controller.apply()
        await controller.waitForInstallation()
        XCTAssertEqual(fixture.installs, ["system-status"])
        XCTAssertEqual(controller.results.filter { $0.outcome == .skipped }.count, 5)
        XCTAssertEqual(fixture.layout.placementsByPanelID.values.flatMap { $0 }.count, 1)
    }

    func testStartEmptyDuringInstallationPreservesChoicesForRetryAfterRestart() async {
        let store = defaults()
        let fixture = Fixture()
        let controller = StarterPackController(defaults: store, hasExistingSetup: false, services: fixture.services)
        controller.selectPack(.windows, isSelected: true)
        controller.updateDraft { $0.selectedPluginIDs.remove("keep-awake"); $0.addToPanel = false }
        let selectedIDs = controller.selectedIDs
        fixture.didInstall = { controller.stopAfterCurrentPlugin() }

        XCTAssertTrue(controller.apply())
        XCTAssertFalse(controller.startEmpty())
        XCTAssertTrue(controller.canResumeOnboarding)
        XCTAssertEqual(controller.selectedIDs, selectedIDs)
        await controller.waitForInstallation()
        XCTAssertTrue(controller.wasStopped)

        let reopened = StarterPackController(defaults: store, hasExistingSetup: true, services: fixture.services)
        XCTAssertTrue(reopened.needsOnboarding)
        XCTAssertEqual(reopened.selectedPacks, [.everyday, .windows])
        XCTAssertEqual(reopened.selectedIDs, selectedIDs)
        XCTAssertTrue(reopened.draft.addToPanel)
        XCTAssertTrue(reopened.canApply)

        XCTAssertTrue(reopened.startEmpty())
        XCTAssertTrue(reopened.selectedPacks.isEmpty)
        XCTAssertTrue(reopened.selectedIDs.isEmpty)
        XCTAssertFalse(reopened.canResumeOnboarding)
        XCTAssertFalse(StarterPackController(defaults: store, hasExistingSetup: true, services: fixture.services).canResumeOnboarding)
        XCTAssertEqual(fixture.installs, ["system-status"])
    }

    func testHostRejectsPackageMutationsAndBackupRestoreWhilePackInstallationIsRunning() async {
        let fixture = Fixture()
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: false, services: fixture.services)
        let suite = "StarterPackTests-\(UUID())"
        suites.append(suite)
        let host = makePluginHostForTests(plugins: [], suiteName: suite)
        host.starterPacks = controller
        let backup = host.makePreferencesBackup()
        let originalLayout = host.menuBarPanelStore.configuration
        controller.apply()
        XCTAssertThrowsError(try host.installPluginPackage(from: URL(fileURLWithPath: "/unused-test-package")))
        XCTAssertThrowsError(try host.uninstallDynamicPlugin(pluginID: "keep-awake"))
        XCTAssertThrowsError(try host.importPreferences(backup))
        do {
            _ = try await host.importPreferences(backup, installingMissingPluginIDs: [])
            XCTFail("Backup restoration must wait until pack setup finishes")
        } catch {
            XCTAssertEqual(host.menuBarPanelStore.configuration, originalLayout)
            XCTAssertFalse(host.isImportingPreferences)
        }
        controller.stopAfterCurrentPlugin()
        await controller.waitForInstallation()
    }

    func testWindowPackPreservesGridAndShortcutAndRechecksChangesDuringInstall() async {
        let fixture = Fixture()
        fixture.grid = .occupied
        fixture.shortcut = true
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: true, services: fixture.services)
        controller.clearSelection()
        controller.selectPack(.windows, isSelected: true)
        controller.updateDraft { $0.assignShortcut = true; $0.seedGrid = true }
        controller.apply()
        await controller.waitForInstallation()
        XCTAssertTrue(fixture.seeded.isEmpty)
        XCTAssertEqual(fixture.shortcutWrites, 0)
        fixture.installed = []
        fixture.grid = .empty
        fixture.didInstall = { fixture.grid = .occupied }
        controller.apply()
        await controller.waitForInstallation()
        XCTAssertTrue(fixture.seeded.isEmpty)
    }

    func testNewWindowGridRestoresThroughTheRealPluginFormatAndReportsShortcutConflict() async throws {
        let fixture = Fixture()
        fixture.shortcutError = "Shortcut is already assigned"
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: false, services: fixture.services)
        controller.clearSelection()
        controller.selectPack(.windows, isSelected: true)
        controller.updateDraft { $0.assignShortcut = true; $0.seedGrid = true }
        controller.apply()
        await controller.waitForInstallation()
        let grid = ActionGridStore(storage: UserDefaultsPluginStorage(pluginID: "action-grid", userDefaults: defaults()))
        let payload = try JSONEncoder().encode(StarterPackGridPreferences(references: fixture.seeded))
        XCTAssertTrue(grid.restorePortableBackup(payload))
        XCTAssertEqual(grid.entries.map(\.reference.key.actionID), ["left-half", "right-half", "maximize"])
        XCTAssertEqual(controller.setupMessages, ["Shortcut is already assigned"])
        XCTAssertFalse(fixture.shortcut)
    }

    func testCombinedPacksInstallSharedPluginsOnceAndUseDefaultLocations() async {
        let fixture = Fixture()
        fixture.installed = ["keep-awake"]
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: true, services: fixture.services)
        controller.selectPack(.everyday, isSelected: true)
        controller.selectPack(.windows, isSelected: true)
        XCTAssertEqual(controller.selectedIDs.count, 12)
        XCTAssertTrue(controller.draft.addToPanel)
        controller.updateDraft { $0.selectedPluginIDs.remove("system-mute") }
        controller.selectPack(.meetings, isSelected: true)
        XCTAssertFalse(controller.selectedIDs.contains("system-mute"))
        controller.selectPack(.meetings, isSelected: false)
        controller.selectPack(.everyday, isSelected: false)
        XCTAssertTrue(controller.selectedIDs.contains("keep-awake"))
        XCTAssertFalse(controller.selectedIDs.contains("microphone-mute"))
        controller.apply()
        await controller.waitForInstallation()
        XCTAssertEqual(Set(fixture.installs), Set(StarterPack.windows.pluginIDs).subtracting(["keep-awake"]))
        XCTAssertEqual(fixture.installs.count, Set(fixture.installs).count)
        XCTAssertEqual(controller.panelItemsByPanelID(showsAppliedSelection: true),
                       [MenuBarPanelDefinition.featuresID: StarterPack.windows.panelItems])
        XCTAssertTrue(fixture.seeded.isEmpty)
    }

    func testLinksAreAdditiveAndRunningBatchKeepsItsReviewedSelection() async {
        let fixture = Fixture()
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: false, services: fixture.services)
        controller.includePackFromLink(.windows)
        XCTAssertEqual(controller.selectedPacks, [.windows])
        controller.includePackFromLink(.meetings)
        let reviewed = controller.selectedIDs
        XCTAssertEqual(controller.selectedPacks, [.windows, .meetings])
        fixture.didInstall = { controller.includePackFromLink(.maintenance); controller.clearSelection() }
        controller.apply()
        await controller.waitForInstallation()
        XCTAssertEqual(fixture.installs, reviewed)
        XCTAssertEqual(controller.appliedPacks, [.windows, .meetings])
        let appliedPanelItems = controller.appliedPanelItems
        controller.clearSelection()
        controller.selectPack(.writing, isSelected: true)
        XCTAssertEqual(controller.selectedPacks, [.writing])
        XCTAssertEqual(controller.appliedPacks, [.windows, .meetings])
        XCTAssertEqual(controller.appliedDraft?.selectedPluginIDs, Set(reviewed))
        XCTAssertEqual(controller.appliedPanelItems, appliedPanelItems)
    }

    func testAllPacksHaveOneReversiblePluginSelectionAndDeduplicatedPlacements() async {
        let fixture = Fixture()
        let controller = StarterPackController(defaults: defaults(), hasExistingSetup: false, services: fixture.services)
        controller.selectAllPacks()
        let union = Set(StarterPack.allCases.flatMap(\.pluginIDs))
        XCTAssertEqual(Set(controller.selectedIDs), union)
        XCTAssertEqual(controller.candidateIDs.count, union.count)
        controller.updateDraft { $0.selectedPluginIDs.remove("keep-awake") }
        XCTAssertTrue(controller.candidateIDs.contains("keep-awake"))
        controller.updateDraft { $0.selectedPluginIDs.insert("keep-awake") }
        controller.apply()
        await controller.waitForInstallation()
        XCTAssertEqual(Set(fixture.installs), union)
        XCTAssertEqual(fixture.installs.count, union.count)
        let items = fixture.layout.placementsByPanelID.values.flatMap { $0 }.map(\.item)
        XCTAssertEqual(items.count, Set(items).count)
        controller.clearSelection()
        XCTAssertTrue(controller.selectedIDs.isEmpty)
        XCTAssertEqual(fixture.installed, union)
    }
}

@MainActor
private final class Fixture {
    var installed: Set<String> = []
    var installs: [String] = []
    var failures: Set<String> = []
    var unusable: Set<String> = []
    var catalogReady = true
    var layout = MenuBarPanelConfiguration()
    var grid: StarterPackGridState = .empty
    var seeded: [ActionReference] = []
    var shortcut = false
    var shortcutWrites = 0
    var shortcutError: String?
    var didInstall: (() -> Void)?

    var services: StarterPackServices {
        StarterPackServices(
            installedIDs: { self.installed },
            isUsable: { self.installed.contains($0) && !self.unusable.contains($0) },
            isCatalogReady: { self.catalogReady },
            install: { id in
                self.installs.append(id)
                if self.failures.contains(id) { throw StarterPackError.notReady }
                self.installed.insert(id)
                self.didInstall?()
            },
            layout: { self.layout },
            addPlacement: { item, panel in
                guard self.layout.panels.contains(where: { $0.id == panel && !$0.isHidden }) else { return false }
                self.layout.placementsByPanelID[panel, default: []].append(.init(item: item))
                return true
            },
            gridState: { self.grid },
            seedGrid: { self.seeded = $0; self.grid = .occupied; return true },
            hasGridShortcut: { self.shortcut },
            assignGridShortcut: {
                self.shortcutWrites += 1
                if self.shortcutError == nil { self.shortcut = true }
                return self.shortcutError
            }
        )
    }
}
