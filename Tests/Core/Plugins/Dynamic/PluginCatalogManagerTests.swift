import Combine
import Foundation
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginCatalogManagerTests: XCTestCase {
    private var temporaryRoot: URL!
    private var defaults: UserDefaults!
    private let suiteName = "PluginCatalogManagerTests"

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginCatalogManagerTests-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        temporaryRoot = nil
    }

    func testHostCatalogRefreshScansInstalledPackagesOnceAndPublishesMarketplaceChanges() async throws {
        let fileManager = InstalledDirectoryCountingFileManager()
        let store = PluginPackageStore(
            rootDirectory: temporaryRoot,
            fileManager: fileManager,
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "com.example.demo", version: "2.0.0"),
        ])
        let catalogManager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [:]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL)
        )
        let host = PluginHost(
            plugins: [],
            dynamicPluginManager: dynamicManager,
            pluginCatalogManager: catalogManager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            loadDynamicPluginsOnInit: false
        )
        defer { host.deactivateAllPlugins() }
        let marketplace = PluginMarketplacePresentationModel(host: host)
        let navigation = SettingsNavigationPresentationModel(host: host)
        var marketplaceUpdates = 0
        let subscription = marketplace.objectWillChange.sink { marketplaceUpdates += 1 }
        let initialScans = fileManager.scanCount

        await host.refreshPluginCatalog()

        XCTAssertEqual(fileManager.scanCount - initialScans, 1)
        XCTAssertEqual(marketplace.items, host.pluginManagementItems)
        XCTAssertEqual(navigation.marketplaceItems, host.pluginManagementItems)
        XCTAssertEqual(marketplace.items.first?.state, .available)
        XCTAssertEqual(marketplace.catalogStatus.lastUpdatedAt, snapshot.loadedAt)
        XCTAssertGreaterThan(marketplaceUpdates, 0)

        marketplaceUpdates = 0
        await host.refreshPluginCatalog()
        XCTAssertEqual(marketplaceUpdates, 0, "An unchanged refresh must not invalidate the marketplace")

        // External package changes must be picked up on the next refresh.
        _ = try store.installPackage(from: makePackage(id: "com.example.demo", version: "1.0.0"))
        let scansBeforeInstallRefresh = fileManager.scanCount
        await host.refreshPluginCatalog()
        XCTAssertEqual(fileManager.scanCount - scansBeforeInstallRefresh, 1)
        XCTAssertEqual(marketplace.items, host.pluginManagementItems)
        XCTAssertEqual(marketplace.items.first?.state, .updateAvailable(installedVersion: "1.0.0", catalogVersion: "2.0.0"))
        XCTAssertGreaterThan(marketplaceUpdates, 0)
        withExtendedLifetime(subscription) {}
    }

    func testFailedCatalogRefreshStillReturnsFreshInstalledMetadata() async throws {
        let store = makeStore()
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )
        let manager = PluginCatalogManager(
            catalogProvider: FailingPluginCatalogProvider(),
            packageResolver: StubPluginPackageResolver(packagesByID: [:]),
            dynamicPluginManager: dynamicManager,
            source: .production(URL(string: "https://example.com/catalog.json")!)
        )
        _ = try store.installPackage(from: makePackage(id: "com.example.demo"))

        let metadata = await manager.refreshCatalog()

        XCTAssertEqual(metadata?.manifestsByID["com.example.demo"]?.version, "1.0.0")
        XCTAssertEqual(dynamicManager.pluginManagementItems.map(\.id), ["com.example.demo"])
        XCTAssertEqual(manager.status.errorMessage, "catalog unavailable")
        XCTAssertFalse(manager.status.isRefreshing)
    }

    func testAutomaticUpdatePlanOnlyIncludesInstalledPluginsWithNewerCatalogVersions() async throws {
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: "com.example.installed", version: "1.0.0"))
        _ = try store.installPackage(from: makePackage(id: "com.example.current", version: "2.0.0"))
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "com.example.installed", version: "2.0.0"),
            makeCatalogEntry(id: "com.example.current", version: "2.0.0"),
            makeCatalogEntry(id: "com.example.available", version: "1.0.0"),
        ])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [:]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL)
        )

        await manager.refreshCatalog()

        XCTAssertEqual(
            manager.automaticUpdatePlanForInstalledPlugins().updateableInstalledPluginIDs,
            ["com.example.installed"]
        )
    }

    func testNewerHostEntryStaysVisibleButCannotInstallOrAutomaticallyUpdate() async throws {
        let store = PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: defaults,
            hostVersion: "2.0.0"
        )
        _ = try store.installPackage(from: makePackage(
            id: "com.example.installed",
            version: "1.0.0"
        ))
        let futurePackage = try makePackage(
            id: "com.example.future",
            version: "1.0.0"
        )
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(
                id: "com.example.installed",
                version: "2.0.0",
                minimumHostVersion: "2.0.1"
            ),
            makeCatalogEntry(
                id: "com.example.future",
                version: "1.0.0",
                minimumHostVersion: "2.0.1"
            ),
        ])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [
                "com.example.future": futurePackage,
            ]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL)
        )

        await manager.refreshCatalog()

        XCTAssertTrue(
            manager.automaticUpdatePlanForInstalledPlugins()
                .updateableInstalledPluginIDs.isEmpty
        )
        do {
            try await manager.installPlugin(id: "com.example.future")
            XCTFail("Expected the future-host package to be rejected")
        } catch let error as PluginPackageManifestError {
            XCTAssertEqual(error, .incompatibleHostVersion(
                required: "2.0.1",
                current: "2.0.0"
            ))
        }

        let installed = try XCTUnwrap(store.installedRecords().first)
        XCTAssertEqual(installed.manifest.version, "1.0.0")
        XCTAssertEqual(installed.state, .installed)
    }

    func testMissingApplicationBlocksCatalogInstallBeforeResolvingAndRecheckEnablesIt() async throws {
        var found = false
        let store = PluginPackageStore(rootDirectory: temporaryRoot, userDefaults: defaults, hostVersion: "1.0.0",
                                       requirementChecker: .init(macOSVersion: { "27.0" }, applicationInstalled: { _ in found }))
        let dynamic = DynamicPluginManager(packageStore: store, pluginLoader: StubDynamicPluginLoader { _ in [] })
        let entry = makeCatalogEntry(id: "com.example.siri", version: "1.0.0", requirements: PluginRequirementTestData.requirements())
        let snapshot = makeCatalogSnapshot(entries: [entry])
        let manager = PluginCatalogManager(catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
                                           packageResolver: StubPluginPackageResolver(packagesByID: [:]),
                                           dynamicPluginManager: dynamic, source: .production(snapshot.sourceURL))
        await manager.refreshCatalog()
        let item = try XCTUnwrap(dynamic.pluginManagementItems.first)
        XCTAssertFalse(item.canInstall)
        XCTAssertTrue(item.detailText.contains("Siri AI"))
        do {
            try await manager.installPlugin(id: entry.id)
            XCTFail("Should reject before requesting a package from the empty resolver")
        } catch { XCTAssertEqual(error as? PluginRequirementChecker.Failure, .application("Siri AI")) }
        found = true
        dynamic.reloadInstalledPlugins()
        XCTAssertEqual(dynamic.pluginManagementItems.first?.canInstall, true)
    }

    func testAutomaticUpdateBeforeLoadingInstallsLatestPackageWithoutCallingLoader() async throws {
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: "com.example.demo", version: "1.0.0"))
        let updatePackageURL = try makePackage(id: "com.example.demo", version: "2.0.0")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                return DynamicPluginLoadResult(
                    record: record,
                    plugins: [MockDynamicPlugin(id: record.id)],
                    errorMessage: nil
                )
            }
        }
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: loader
        )
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "com.example.demo", version: "2.0.0"),
        ])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [
                "com.example.demo": updatePackageURL,
            ]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL)
        )

        await manager.refreshCatalog()
        try await manager.updateInstalledPluginsToLatestBeforeLoading()

        XCTAssertEqual(store.installedRecords().first?.manifest.version, "2.0.0")
        XCTAssertTrue(loader.receivedRecordIDBatches.isEmpty)

        XCTAssertEqual(dynamicManager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])
        XCTAssertEqual(loader.receivedRecordIDBatches, [["com.example.demo"]])
    }

    func testAutomaticUpdateInstallsTrackpadGesturesBeforeRetiringLegacyMiddleClick() async throws {
        defaults.set(
            false,
            forKey: "plugin.mouse-enhancer.mouse-enhancer.middle-click.enabled"
        )
        defaults.set(
            4,
            forKey: "plugin.mouse-enhancer.mouse-enhancer.middle-click.finger-count"
        )
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: "mouse-enhancer", version: "1.0.6"))
        let mouseUpdateURL = try makePackage(id: "mouse-enhancer", version: "1.0.7")
        let trackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let loader = makeSuccessfulRuntimeLoader()
        let dynamicManager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "mouse-enhancer", version: "1.0.7"),
            makeCatalogEntry(id: "trackpad-gestures", version: "1.0.0"),
        ])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [
                "mouse-enhancer": mouseUpdateURL,
                "trackpad-gestures": trackpadURL,
            ]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL),
            extractionMigrationUserDefaults: defaults
        )

        await manager.refreshCatalog()
        let plan = manager.automaticUpdatePlanForInstalledPlugins()
        XCTAssertEqual(plan.updateableInstalledPluginIDs, ["mouse-enhancer"])
        XCTAssertEqual(plan.affectedPluginIDs, ["mouse-enhancer", "trackpad-gestures"])

        var progressUpdates: [PluginCatalogUpdateProgress] = []
        try await manager.updateInstalledPluginsToLatestBeforeLoading {
            progressUpdates.append($0)
        }

        XCTAssertEqual(
            dynamicManager.installedPackageVersionsByID(),
            [
                "mouse-enhancer": "1.0.7",
                "trackpad-gestures": "1.0.0",
            ]
        )
        XCTAssertTrue(defaults.bool(
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1"
        ))
        XCTAssertEqual(loader.receivedRecordIDBatches, [["trackpad-gestures"]])
        XCTAssertEqual(
            progressUpdates,
            [
                PluginCatalogUpdateProgress(completedCount: 0, totalCount: 2),
                PluginCatalogUpdateProgress(completedCount: 2, totalCount: 2),
            ]
        )

        try await manager.updateInstalledPluginsToLatestBeforeLoading()
        XCTAssertEqual(dynamicManager.installedPackageVersionsByID().count, 2)
        XCTAssertEqual(loader.receivedRecordIDBatches, [["trackpad-gestures"]])

        try dynamicManager.uninstallPlugin(pluginID: "trackpad-gestures")
        try await manager.updateInstalledPluginsToLatestBeforeLoading()
        XCTAssertEqual(
            dynamicManager.installedPackageVersionsByID(),
            ["mouse-enhancer": "1.0.7"]
        )
    }

    func testExtractionMigrationStopsBeforeMutationWhenJournalCannotPersist() async throws {
        defaults.set(
            true,
            forKey: "plugin.mouse-enhancer.mouse-enhancer.middle-click.enabled"
        )
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: "mouse-enhancer", version: "1.0.6"))
        let mouseUpdateURL = try makePackage(id: "mouse-enhancer", version: "1.0.7")
        let trackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: makeSuccessfulRuntimeLoader()
        )
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "mouse-enhancer", version: "1.0.7"),
            makeCatalogEntry(id: "trackpad-gestures", version: "1.0.0"),
        ])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [
                "mouse-enhancer": mouseUpdateURL,
                "trackpad-gestures": trackpadURL,
            ]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL),
            extractionMigrationUserDefaults: defaults,
            synchronizeExtractionMigrationDefaults: { _ in false }
        )

        await manager.refreshCatalog()
        do {
            try await manager.updateInstalledPluginsToLatestBeforeLoading()
            XCTFail("Expected durable journal persistence to fail")
        } catch {
            XCTAssertEqual(
                error as? PluginCatalogManagerError,
                .migrationJournalPersistenceFailed
            )
        }

        XCTAssertEqual(
            dynamicManager.installedPackageVersionsByID(),
            ["mouse-enhancer": "1.0.6"]
        )
        XCTAssertNil(defaults.object(
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1.in-progress"
        ))
        XCTAssertEqual(
            dynamicManager.loadInstalledPlugins().map(\.metadata.id),
            ["mouse-enhancer"]
        )
    }

    func testInterruptedMigrationJournalResumesForwardBeforeLoadingSource() async throws {
        defaults.set(true, forKey: "plugin.mouse-enhancer.mouse-enhancer.middle-click.enabled")
        defaults.set(
            true,
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1.in-progress"
        )
        defaults.set(
            Data([0x01]),
            forKey: "plugin.trackpad-gestures.migration.mouse-enhancer-middle-click.v2"
        )
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: "mouse-enhancer", version: "1.0.6"))
        _ = try store.installPackage(from: makePackage(id: "trackpad-gestures", version: "1.0.0"))
        let mouseUpdateURL = try makePackage(id: "mouse-enhancer", version: "1.0.7")
        var destinationMigrationMarkerWasReset = false
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                if record.id == "trackpad-gestures" {
                    destinationMigrationMarkerWasReset = self.defaults.object(
                        forKey: "plugin.trackpad-gestures.migration.mouse-enhancer-middle-click.v2"
                    ) == nil
                }
                return DynamicPluginLoadResult(
                    record: record,
                    plugins: [MockDynamicPlugin(id: record.id)],
                    errorMessage: nil
                )
            }
        }
        let dynamicManager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "mouse-enhancer", version: "1.0.7"),
            makeCatalogEntry(id: "trackpad-gestures", version: "1.0.0"),
        ])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [
                "mouse-enhancer": mouseUpdateURL,
            ]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL),
            extractionMigrationUserDefaults: defaults
        )

        await manager.refreshCatalog()
        XCTAssertTrue(manager.hasPendingExtractionMigrationResume)
        try await manager.updateInstalledPluginsToLatestBeforeLoading()

        XCTAssertTrue(destinationMigrationMarkerWasReset)
        XCTAssertEqual(dynamicManager.installedPackageVersionsByID(), [
            "mouse-enhancer": "1.0.7",
            "trackpad-gestures": "1.0.0",
        ])
        XCTAssertTrue(defaults.bool(
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1"
        ))
        XCTAssertNil(defaults.object(
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1.in-progress"
        ))
    }

    func testExtractionMigrationRollsBackReplacementWhenSourceUpdateFails() async throws {
        defaults.set(
            true,
            forKey: "plugin.mouse-enhancer.mouse-enhancer.middle-click.enabled"
        )
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: "mouse-enhancer", version: "1.0.6"))
        let mismatchedMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.8")
        let trackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: makeSuccessfulRuntimeLoader()
        )
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "mouse-enhancer", version: "1.0.7"),
            makeCatalogEntry(id: "trackpad-gestures", version: "1.0.0"),
        ])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [
                "mouse-enhancer": mismatchedMouseURL,
                "trackpad-gestures": trackpadURL,
            ]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL),
            extractionMigrationUserDefaults: defaults
        )

        await manager.refreshCatalog()
        do {
            try await manager.updateInstalledPluginsToLatestBeforeLoading()
            XCTFail("Expected the paired source update to fail")
        } catch {
            // The replacement package must be rolled back below.
        }

        XCTAssertEqual(
            dynamicManager.installedPackageVersionsByID(),
            ["mouse-enhancer": "1.0.6"]
        )
        XCTAssertNil(defaults.object(
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1"
        ))
        XCTAssertNil(defaults.object(
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1.in-progress"
        ))
    }

    func testExtractionMigrationRollsBackReplacementWhenRuntimeValidationFails() async throws {
        defaults.set(
            true,
            forKey: "plugin.mouse-enhancer.mouse-enhancer.middle-click.enabled"
        )
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: "mouse-enhancer", version: "1.0.6"))
        let mouseUpdateURL = try makePackage(id: "mouse-enhancer", version: "1.0.7")
        let trackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let sourcePlugin = MockDynamicPlugin(id: "mouse-enhancer")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                if record.id == "mouse-enhancer" {
                    sourcePlugin.simulateActivation()
                }
                return DynamicPluginLoadResult(
                    record: record,
                    plugins: record.id == "trackpad-gestures" ? [] : [sourcePlugin],
                    errorMessage: record.id == "trackpad-gestures" ? "activation failed" : nil
                )
            }
        }
        let dynamicManager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        XCTAssertEqual(
            dynamicManager.loadInstalledPlugins().map(\.metadata.id),
            ["mouse-enhancer"]
        )
        XCTAssertTrue(sourcePlugin.isExternalSessionActive)
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "mouse-enhancer", version: "1.0.7"),
            makeCatalogEntry(id: "trackpad-gestures", version: "1.0.0"),
        ])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [
                "mouse-enhancer": mouseUpdateURL,
                "trackpad-gestures": trackpadURL,
            ]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL),
            extractionMigrationUserDefaults: defaults
        )

        await manager.refreshCatalog()
        do {
            try await manager.updateInstalledPluginsToLatestBeforeLoading()
            XCTFail("Expected replacement runtime validation to fail")
        } catch {
            // The source package and completion state are asserted below.
        }

        XCTAssertEqual(
            dynamicManager.installedPackageVersionsByID(),
            ["mouse-enhancer": "1.0.6"]
        )
        XCTAssertNil(defaults.object(
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1"
        ))
        XCTAssertNil(defaults.object(
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1.in-progress"
        ))
        XCTAssertEqual(sourcePlugin.deactivationReasons, [.disabled])
        XCTAssertEqual(loader.receivedRecordIDBatches, [
            ["mouse-enhancer"],
            ["trackpad-gestures"],
            ["mouse-enhancer"],
        ])
        XCTAssertEqual(
            dynamicManager.loadInstalledPlugins().map(\.metadata.id),
            ["mouse-enhancer"]
        )
    }

    func testExtractionMigrationDefersRetiringSourceWhenReplacementIsUnavailable() async throws {
        defaults.set(
            true,
            forKey: "plugin.mouse-enhancer.mouse-enhancer.middle-click.enabled"
        )
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: "mouse-enhancer", version: "1.0.6"))
        let mouseUpdateURL = try makePackage(id: "mouse-enhancer", version: "1.0.7")
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "mouse-enhancer", version: "1.0.7"),
        ])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [
                "mouse-enhancer": mouseUpdateURL,
            ]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL),
            extractionMigrationUserDefaults: defaults
        )

        await manager.refreshCatalog()
        XCTAssertTrue(manager.automaticUpdatePlanForInstalledPlugins().isEmpty)
        try await manager.updateInstalledPluginsToLatestBeforeLoading()
        XCTAssertEqual(
            dynamicManager.installedPackageVersionsByID(),
            ["mouse-enhancer": "1.0.6"]
        )
        do {
            try await manager.updatePlugin(id: "mouse-enhancer")
            XCTFail("Expected the retiring source update to remain deferred")
        } catch {
            // The missing replacement package is the expected failure.
        }
    }

    func testInstallPluginUsesTheVerifiedCatalogEntry() async throws {
        let store = makeStore()
        let packageURL = try makePackage(id: "com.example.restore", version: "1.0.0")
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "com.example.restore", version: "1.0.0"),
        ])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [
                "com.example.restore": packageURL,
            ]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL)
        )

        await manager.refreshCatalog()
        try await manager.installPlugin(id: "com.example.restore")

        XCTAssertEqual(store.installedRecords().map(\.id), ["com.example.restore"])
    }

    func testUninstallWinsWhenUpdateResolutionFinishesLater() async throws {
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: "com.example.demo", version: "1.0.0"))
        let updatePackageURL = try makePackage(id: "com.example.demo", version: "2.0.0")
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "com.example.demo", version: "2.0.0"),
        ])
        let resolver = SuspendedPluginPackageResolver()
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: resolver,
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL)
        )

        await manager.refreshCatalog()
        let updateTask = Task {
            try await manager.updatePlugin(id: "com.example.demo")
        }
        await resolver.waitUntilRequested()

        try dynamicManager.uninstallPlugin(pluginID: "com.example.demo")
        resolver.resume(returning: updatePackageURL)
        try await updateTask.value

        XCTAssertFalse(dynamicManager.isInstalledPlugin("com.example.demo"))
        XCTAssertTrue(store.installedRecords().isEmpty)
    }

    private func makeStore() -> PluginPackageStore {
        PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
    }

    private func makeSuccessfulRuntimeLoader() -> StubDynamicPluginLoader {
        StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(
                    record: record,
                    plugins: [MockDynamicPlugin(id: record.id)],
                    errorMessage: nil
                )
            }
        }
    }

    private func makePackage(
        id: String,
        version: String = "1.0.0",
        displayName: String = "Demo",
        bundleRelativePath: String = "Demo.bundle"
    ) throws -> URL {
        let packageURL = temporaryRoot
            .appendingPathComponent("Source", isDirectory: true)
            .appendingPathComponent("\(id)-\(version)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = packageURL.appendingPathComponent(bundleRelativePath, isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = PluginPackageManifest(
            id: id,
            displayName: displayName,
            version: version,
            minHostVersion: "0.1.0",
            bundleRelativePath: bundleRelativePath
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: packageURL.appendingPathComponent("plugin.json"))

        return packageURL
    }

    private func makeCatalogEntry(
        id: String,
        version: String,
        minimumHostVersion: String = "0.1.0",
        requirements: PluginProductMetadata.Requirements? = nil
    ) -> PluginCatalogEntry {
        PluginCatalogEntry(
            id: id,
            displayName: "Demo",
            summary: "示例插件",
            version: version,
            minimumHostVersion: minimumHostVersion,
            package: PluginCatalogPackage(
                url: URL(fileURLWithPath: "/tmp/\(id).mactoolsplugin"),
                sha256: String(repeating: "a", count: 64),
                size: 42
            ), requirements: requirements
        )
    }

    private func makeCatalogSnapshot(entries: [PluginCatalogEntry]) -> PluginCatalogSnapshot {
        PluginCatalogSnapshot(
            catalog: PluginCatalog(
                catalogID: "com.example.catalog",
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
private struct StubPluginCatalogProvider: PluginCatalogProviding {
    let snapshot: PluginCatalogSnapshot

    func loadCatalog() async throws -> PluginCatalogSnapshot {
        snapshot
    }
}

private final class InstalledDirectoryCountingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var installedDirectoryScans = 0

    var scanCount: Int { lock.withLock { installedDirectoryScans } }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if url.lastPathComponent == "Installed" {
            lock.withLock { installedDirectoryScans += 1 }
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

@MainActor
private struct FailingPluginCatalogProvider: PluginCatalogProviding {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "catalog unavailable" }
    }

    func loadCatalog() async throws -> PluginCatalogSnapshot {
        throw Failure()
    }
}

@MainActor
private struct StubPluginPackageResolver: PluginPackageResolving {
    let packagesByID: [String: URL]

    func resolvePackage(for entry: PluginCatalogEntry) async throws -> URL {
        guard let url = packagesByID[entry.id] else {
            throw PluginCatalogManagerError.catalogEntryNotFound(entry.id)
        }

        return url
    }
}

@MainActor
private final class SuspendedPluginPackageResolver: PluginPackageResolving {
    private var resolutionContinuation: CheckedContinuation<URL, Error>?
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var wasRequested = false

    func resolvePackage(for entry: PluginCatalogEntry) async throws -> URL {
        wasRequested = true
        requestContinuation?.resume()
        requestContinuation = nil

        return try await withCheckedThrowingContinuation { continuation in
            resolutionContinuation = continuation
        }
    }

    func waitUntilRequested() async {
        guard !wasRequested else {
            return
        }

        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func resume(returning url: URL) {
        resolutionContinuation?.resume(returning: url)
        resolutionContinuation = nil
    }
}

@MainActor
private final class StubDynamicPluginLoader: DynamicPluginLoading {
    private let handler: ([PluginPackageRecord]) -> [DynamicPluginLoadResult]
    private(set) var receivedRecordIDBatches: [[String]] = []

    init(handler: @escaping ([PluginPackageRecord]) -> [DynamicPluginLoadResult]) {
        self.handler = handler
    }

    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult] {
        receivedRecordIDBatches.append(records.map(\.id))
        return handler(records)
    }
}

@MainActor
private final class MockDynamicPlugin: MacToolsPlugin, PluginFeatureExtractionReadinessProviding {
    let metadata: PluginMetadata
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var deactivationReasons: [PluginDeactivationReason] = []
    private(set) var isExternalSessionActive = true
    private let readinessError: Error?

    init(id: String, readinessError: Error? = nil) {
        self.readinessError = readinessError
        self.metadata = PluginMetadata(
            id: id,
            title: "Demo",
            iconName: "shippingbox",
            iconTint: .blue,
            order: 1,
            defaultDescription: "Demo"
        )
    }

    func deactivate(reason: PluginDeactivationReason) {
        deactivationReasons.append(reason)
        if reason.requiresStateCleanup {
            isExternalSessionActive = false
        }
    }

    func simulateActivation() {
        isExternalSessionActive = true
    }

    func validateFeatureExtractionReadiness() throws {
        if let readinessError {
            throw readinessError
        }
    }
}
