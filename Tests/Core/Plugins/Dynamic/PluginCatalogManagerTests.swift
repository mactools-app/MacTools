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

    func testHostInstallKeepsFeedbackPerPluginAndSeparatesCompletionFromLoadFailure() async throws {
        let pluginID = "com.example.demo"
        let store = makeStore()
        let packageURL = try makePackage(id: pluginID)
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { records in
                records.map {
                    DynamicPluginLoadResult(record: $0, plugins: [], errorMessage: "Cannot load plugin")
                }
            }
        )
        let snapshot = makeCatalogSnapshot(entries: [makeCatalogEntry(id: pluginID, version: "1.0.0")])
        let resolver = SuspendedPluginPackageResolver()
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: resolver,
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL)
        )
        let host = makeFeedbackHost(dynamicManager: dynamicManager, catalogManager: manager)
        defer { host.deactivateAllPlugins() }
        await host.refreshPluginCatalog()

        let install = Task { try await host.installPluginFromCatalog(pluginID: pluginID) }
        await resolver.waitUntilRequested()
        XCTAssertEqual(host.pluginMarketplaceOperations[pluginID], .init(kind: .install, phase: .running))
        XCTAssertNil(host.pluginMarketplaceOperations["other"])
        do {
            try await host.installPluginFromCatalog(pluginID: pluginID)
            XCTFail("A second installation must not start while the first is resolving")
        } catch {
            guard case PluginMarketplaceOperationError.operationInProgress = error else {
                resolver.resume(returning: packageURL)
                _ = try? await install.value
                throw error
            }
        }
        resolver.resume(returning: packageURL)
        try await install.value

        XCTAssertTrue(dynamicManager.isInstalledPlugin(pluginID))
        XCTAssertEqual(host.pluginMarketplaceOperations[pluginID], .init(kind: .install, phase: .completed))
        let setup = try XCTUnwrap(host.marketplaceSetupPresentation(pluginID: pluginID))
        XCTAssertEqual(setup.issues.map(\.kind), [.loadFailure])
        XCTAssertEqual(setup.issues.first?.detail, "Cannot load plugin")

        do {
            try await host.installPluginFromCatalog(pluginID: "missing")
            XCTFail("An unknown plugin must fail installation")
        } catch {
            XCTAssertEqual(host.pluginMarketplaceOperations["missing"]?.phase, .failed(error.localizedDescription))
        }
        XCTAssertEqual(host.pluginMarketplaceOperations[pluginID]?.phase, .completed)
    }

    func testHostWithoutCatalogReportsFailureForInstallAndUpdate() async throws {
        let host = makeFeedbackHost()
        defer { host.deactivateAllPlugins() }

        for kind in [PluginMarketplaceOperation.Kind.install, .update] {
            do {
                switch kind {
                case .install: try await host.installPluginFromCatalog(pluginID: "example")
                case .update: try await host.updatePluginFromCatalog(pluginID: "example")
                }
                XCTFail("No catalog manager must not report success")
            } catch {
                guard case PluginMarketplaceOperationError.catalogUnavailable = error else { throw error }
                XCTAssertEqual(host.pluginMarketplaceOperations["example"],
                               .init(kind: kind, phase: .failed(error.localizedDescription)))
            }
        }
    }

    func testSuccessfulBulkUpdateClearsEarlierPerPluginFailure() async throws {
        let pluginID = "com.example.demo"
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: pluginID, version: "1.0.0"))
        let updatePackageURL = try makePackage(id: pluginID, version: "2.0.0")
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        let snapshot = makeCatalogSnapshot(entries: [makeCatalogEntry(id: pluginID, version: "2.0.0")])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: FailFirstPluginPackageResolver(packageURL: updatePackageURL),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL)
        )
        let host = makeFeedbackHost(dynamicManager: dynamicManager, catalogManager: manager)
        defer { host.deactivateAllPlugins() }
        await host.refreshPluginCatalog()

        do {
            try await host.updatePluginFromCatalog(pluginID: pluginID)
            XCTFail("The first package resolution must fail")
        } catch {
            XCTAssertEqual(host.pluginMarketplaceOperations[pluginID]?.phase, .failed(error.localizedDescription))
        }
        XCTAssertEqual(dynamicManager.installedPackageVersionsByID()[pluginID], "1.0.0")

        try await host.updateAvailablePluginsFromCatalog()

        XCTAssertEqual(dynamicManager.installedPackageVersionsByID()[pluginID], "2.0.0")
        XCTAssertNil(host.pluginMarketplaceOperations[pluginID])
    }

    func testSupersededUpdateFailureKeepsReinstallationFeedbackAndDuplicateProtection() async throws {
        try await assertReinstallationKeepsFeedbackAfterSupersededUpdate(failsResolution: true)
    }

    func testSupersededUpdateSuccessKeepsReinstallationFeedbackAndDuplicateProtection() async throws {
        try await assertReinstallationKeepsFeedbackAfterSupersededUpdate(failsResolution: false)
    }

    private func assertReinstallationKeepsFeedbackAfterSupersededUpdate(failsResolution: Bool) async throws {
        let pluginID = "com.example.demo"
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: pluginID, version: "1.0.0"))
        let packageURL = try makePackage(id: pluginID, version: "2.0.0")
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )
        let snapshot = makeCatalogSnapshot(entries: [makeCatalogEntry(id: pluginID, version: "2.0.0")])
        let resolver = SuspendedPluginPackageResolver()
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: resolver,
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL)
        )
        let host = makeFeedbackHost(dynamicManager: dynamicManager, catalogManager: manager)
        defer { host.deactivateAllPlugins() }
        await host.refreshPluginCatalog()

        let oldUpdate = Task { try await host.updatePluginFromCatalog(pluginID: pluginID) }
        await resolver.waitUntilRequested()
        XCTAssertEqual(host.pluginMarketplaceOperations[pluginID], .init(kind: .update, phase: .running))

        try host.uninstallDynamicPlugin(pluginID: pluginID)
        XCTAssertNil(host.pluginMarketplaceOperations[pluginID])
        let installation = Task { try await host.installPluginFromCatalog(pluginID: pluginID) }
        await resolver.waitUntilRequested(2)
        XCTAssertEqual(host.pluginMarketplaceOperations[pluginID], .init(kind: .install, phase: .running))

        if failsResolution {
            resolver.resume(throwing: URLError(.notConnectedToInternet))
            do {
                try await oldUpdate.value
                XCTFail("The superseded update must still report its resolution failure to its caller")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
            }
        } else {
            resolver.resume(returning: packageURL)
            try await oldUpdate.value
        }

        XCTAssertFalse(dynamicManager.isInstalledPlugin(pluginID))
        XCTAssertEqual(host.pluginMarketplaceOperations[pluginID], .init(kind: .install, phase: .running))
        guard host.pluginMarketplaceOperations[pluginID]?.isActive == true else {
            resolver.resume(returning: packageURL, requestNumber: 2)
            _ = try? await installation.value
            return
        }
        do {
            try await host.installPluginFromCatalog(pluginID: pluginID)
            XCTFail("A superseded update must not unlock a duplicate installation")
        } catch {
            guard case PluginMarketplaceOperationError.operationInProgress = error else {
                resolver.resume(returning: packageURL, requestNumber: 2)
                _ = try? await installation.value
                throw error
            }
        }

        resolver.resume(returning: packageURL, requestNumber: 2)
        try await installation.value
        XCTAssertEqual(dynamicManager.installedPackageVersionsByID()[pluginID], "2.0.0")
        XCTAssertEqual(host.pluginMarketplaceOperations[pluginID], .init(kind: .install, phase: .completed))
    }

    func testStartupPreparationRejectsRecheckUntilLatestPackageIsLoaded() async throws {
        let pluginID = "com.example.demo"
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: pluginID, version: "1.0.0"))
        let packageURL = try makePackage(id: pluginID, version: "2.0.0")
        let dynamicManager = DynamicPluginManager(packageStore: store, pluginLoader: makeSuccessfulRuntimeLoader())
        let snapshot = makeCatalogSnapshot(entries: [makeCatalogEntry(id: pluginID, version: "2.0.0")])
        let resolver = SuspendedPluginPackageResolver()
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: resolver,
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL)
        )
        let host = makeFeedbackHost(
            dynamicManager: dynamicManager, catalogManager: manager, loadDynamicPluginsOnInit: false
        )
        defer { host.deactivateAllPlugins() }

        XCTAssertTrue(host.isPreparingPlugins)
        XCTAssertTrue(try XCTUnwrap(host.marketplaceSetupPresentation(pluginID: pluginID)).issues.isEmpty)
        host.recheckPluginRequirements()
        XCTAssertFalse(dynamicManager.isPluginLoaded(pluginID))

        let preparation = Task { await host.automaticUpdateInstalledPluginsBeforeLoading() }
        await resolver.waitUntilRequested()
        XCTAssertTrue(try XCTUnwrap(host.marketplaceSetupPresentation(pluginID: pluginID)).issues.isEmpty)
        host.recheckPluginRequirements()
        XCTAssertFalse(dynamicManager.isPluginLoaded(pluginID))
        XCTAssertEqual(dynamicManager.installedPackageVersionsByID()[pluginID], "1.0.0")

        resolver.resume(returning: packageURL)
        let succeeded = await preparation.value
        XCTAssertTrue(succeeded)
        XCTAssertFalse(host.isPreparingPlugins)
        XCTAssertTrue(dynamicManager.isPluginLoaded(pluginID))
        XCTAssertEqual(dynamicManager.installedPackageVersionsByID()[pluginID], "2.0.0")
        let item = try XCTUnwrap(host.pluginManagementItems.first { $0.id == pluginID })
        XCTAssertEqual(item.state, .installed)
        XCTAssertFalse(item.requiresRestartToFullyUnload)

        let addedPluginID = "com.example.other"
        _ = try store.installPackage(from: makePackage(id: addedPluginID))
        host.recheckPluginRequirements()
        XCTAssertTrue(dynamicManager.isPluginLoaded(addedPluginID), "Recheck must remain available after preparation")
    }

    private func makeFeedbackHost(
        dynamicManager: DynamicPluginManager? = nil,
        catalogManager: PluginCatalogManager? = nil,
        loadDynamicPluginsOnInit: Bool = true
    ) -> PluginHost {
        PluginHost(
            plugins: [], dynamicPluginManager: dynamicManager, pluginCatalogManager: catalogManager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(), loadDynamicPluginsOnInit: loadDynamicPluginsOnInit
        )
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
private final class FailFirstPluginPackageResolver: PluginPackageResolving {
    private let packageURL: URL
    private var shouldFail = true

    init(packageURL: URL) {
        self.packageURL = packageURL
    }

    func resolvePackage(for entry: PluginCatalogEntry) async throws -> URL {
        if shouldFail {
            shouldFail = false
            throw URLError(.notConnectedToInternet)
        }
        return packageURL
    }
}

@MainActor
private final class SuspendedPluginPackageResolver: PluginPackageResolving {
    private var resolutionContinuations: [Int: CheckedContinuation<URL, Error>] = [:]
    private var requestContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var requestCount = 0

    func resolvePackage(for entry: PluginCatalogEntry) async throws -> URL {
        requestCount += 1
        let requestNumber = requestCount
        requestContinuations.removeValue(forKey: requestNumber)?.resume()

        return try await withCheckedThrowingContinuation { continuation in
            resolutionContinuations[requestNumber] = continuation
        }
    }

    func waitUntilRequested(_ requestNumber: Int = 1) async {
        guard requestCount < requestNumber else {
            return
        }

        await withCheckedContinuation { continuation in
            requestContinuations[requestNumber] = continuation
        }
    }

    func resume(returning url: URL, requestNumber: Int = 1) {
        resolutionContinuations.removeValue(forKey: requestNumber)?.resume(returning: url)
    }

    func resume(throwing error: Error, requestNumber: Int = 1) {
        resolutionContinuations.removeValue(forKey: requestNumber)?.resume(throwing: error)
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
