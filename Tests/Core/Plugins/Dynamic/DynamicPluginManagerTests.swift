import AppKit
import Foundation
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class DynamicPluginManagerTests: XCTestCase {
    private var temporaryRoot: URL!
    private var defaults: UserDefaults!
    private let suiteName = "DynamicPluginManagerTests"

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicPluginManagerTests-\(UUID().uuidString)", isDirectory: true)
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

    func testReloadKeepsExistingLoadedPluginInstances() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let plugin = MockDynamicPlugin(id: "com.example.demo")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])
        XCTAssertEqual(loader.receivedRecordIDBatches, [["com.example.demo"]])

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])

        XCTAssertEqual(loader.receivedRecordIDBatches, [["com.example.demo"]])
        XCTAssertTrue(plugin.deactivationReasons.isEmpty)
    }

    func testHostLanguageChangeReprojectsManagementMetadataWithoutReloadingPlugins() throws {
        let original = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(original) }
        PluginRuntimeLocalization.source.setPreference("en")
        let sourceURL = try makePackage(
            id: "com.example.localized",
            localizedMetadata: [
                "en": PluginLocalizedMetadata(displayName: "English title", summary: "English summary"),
                "ar": PluginLocalizedMetadata(displayName: "عنوان عربي", summary: "ملخص عربي"),
            ]
        )
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let plugin = MockDynamicPlugin(id: "com.example.localized")
        let loader = StubDynamicPluginLoader { records in
            records.map { DynamicPluginLoadResult(record: $0, plugins: [plugin], errorMessage: nil) }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let host = makePluginHostForTests(
            plugins: [],
            suiteName: suiteName + ".HostLocalization",
            dynamicPluginManager: manager
        )
        let originalItem = try XCTUnwrap(host.pluginManagementItems.first)
        XCTAssertEqual(originalItem.title, "English title")
        let activations = plugin.activationContexts.count
        let loadBatches = loader.receivedRecordIDBatches

        PluginRuntimeLocalization.source.setPreference("ar")
        host.refreshLocalization()
        let arabicItem = try XCTUnwrap(host.pluginManagementItems.first)
        XCTAssertEqual(arabicItem.title, "عنوان عربي")
        XCTAssertEqual(arabicItem.summary, "ملخص عربي")
        XCTAssertEqual(arabicItem.id, originalItem.id)
        XCTAssertEqual(arabicItem.state, originalItem.state)
        XCTAssertEqual(arabicItem.packageURL, originalItem.packageURL)
        XCTAssertEqual(loader.receivedRecordIDBatches, loadBatches)
        XCTAssertEqual(plugin.activationContexts.count, activations)
        XCTAssertTrue(plugin.deactivationReasons.isEmpty)

        PluginRuntimeLocalization.source.setPreference("en")
        host.refreshLocalization()
        XCTAssertEqual(host.pluginManagementItems.first?.title, "English title")
    }

    func testFutureHostCatalogEntryIsVisibleButCannotBeInstalled() throws {
        let store = makeStore()
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )
        let entry = PluginCatalogEntry(
            id: "com.example.future",
            displayName: "Future",
            summary: "Future host only",
            version: "1.0.0",
            minimumHostVersion: "2.0.0",
            package: PluginCatalogPackage(
                url: URL(fileURLWithPath: "/tmp/Future.mactoolsplugin"),
                sha256: String(repeating: "a", count: 64),
                size: 42
            )
        )
        manager.rebuildManagementItems(catalogSnapshot: PluginCatalogSnapshot(
            catalog: PluginCatalog(
                catalogID: "com.example.catalog",
                generatedAt: Date(timeIntervalSince1970: 0),
                minimumHostVersion: "1.0.0",
                plugins: [entry]
            ),
            sourceURL: URL(fileURLWithPath: "/tmp/catalog.json"),
            sourceKind: .production,
            loadedAt: Date(timeIntervalSince1970: 0)
        ))

        let item = try XCTUnwrap(manager.pluginManagementItems.first)
        XCTAssertFalse(item.canInstall)
        guard case let .incompatible(reason) = item.state else {
            return XCTFail("Expected incompatible marketplace entry")
        }
        XCTAssertTrue(reason.contains("2.0.0"))
    }

    func testUpdatingLoadedPluginInstallsFilesButDoesNotReloadNativeCodeUntilRestart() throws {
        let firstPackageURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let updatePackageURL = try makePackage(id: "com.example.demo", version: "2.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: firstPackageURL)
        let plugin = MockDynamicPlugin(id: "com.example.demo")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])

        try manager.updatePluginPackage(from: updatePackageURL)

        XCTAssertEqual(plugin.deactivationReasons, [.updating])
        XCTAssertTrue(manager.loadInstalledPlugins().isEmpty)
        XCTAssertEqual(store.installedRecords().first?.manifest.version, "2.0.0")
        XCTAssertEqual(manager.pluginManagementItems.first?.state, .restartRequired)
        XCTAssertEqual(
            manager.pluginManagementItems.first?.detailText,
            AppL10n.plugins(
                "plugin.detail.restartRequiredAfterUpdate",
                defaultValue: "新版本将在重启后启用，旧代码将在重启后彻底释放。"
            )
        )
    }

    func testUpdateThenUninstallUsesManifestOwnedPrivateDataCleanup() throws {
        var removedKeyPluginIDs: [String] = []
        let firstPackageURL = try makePackage(
            id: "com.example.private",
            version: "1.0.0",
            uninstallDataPolicy: .removePrivateData
        )
        let updatePackageURL = try makePackage(
            id: "com.example.private",
            version: "2.0.0",
            uninstallDataPolicy: .removePrivateData
        )
        let store = makeStore(privateDataKeyRemover: { removedKeyPluginIDs.append($0) })
        _ = try store.installPackage(from: firstPackageURL)
        let plugin = MockDynamicPlugin(id: "com.example.private")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        _ = manager.loadInstalledPlugins()

        try manager.updatePluginPackage(from: updatePackageURL)
        XCTAssertTrue(manager.loadInstalledPlugins().isEmpty)
        try manager.uninstallPlugin(pluginID: "com.example.private")

        XCTAssertEqual(removedKeyPluginIDs, ["com.example.private"])
        XCTAssertTrue(store.installedRecords().isEmpty)
    }

    func testDirectSourceRetirementUpdateRequiresExtractionCoordinator() throws {
        let oldMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.6")
        let retiredMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.7")
        let store = makeStore()
        _ = try store.installPackage(from: oldMouseURL)
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )

        XCTAssertThrowsError(try manager.updatePluginPackage(from: retiredMouseURL))
        XCTAssertEqual(manager.installedPackageVersionsByID(), ["mouse-enhancer": "1.0.6"])
    }

    func testDirectDestinationInstallRequiresExtractionCoordinator() throws {
        let oldMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.6")
        let trackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: oldMouseURL)
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )

        XCTAssertThrowsError(try manager.installPluginPackage(from: trackpadURL))
        XCTAssertEqual(manager.installedPackageVersionsByID(), ["mouse-enhancer": "1.0.6"])
    }

    func testSourceUninstallDoesNotDeletePackageWhenIntentCannotPersist() throws {
        let policy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        defaults.set(true, forKey: policy.transactionJournalKey)
        let sourceURL = try makePackage(id: policy.sourcePluginID, version: "1.0.6")
        let store = PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: defaults,
            synchronizeUserDefaults: { _ in false },
            hostVersion: "1.0.0"
        )
        _ = try store.installPackage(from: sourceURL)

        XCTAssertThrowsError(try store.uninstall(pluginID: policy.sourcePluginID, removeData: false)) {
            guard case PluginPackageStoreError.migrationStatePersistenceFailed = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }

        XCTAssertEqual(store.installedRecords().map(\.id), [policy.sourcePluginID])
        XCTAssertNil(defaults.object(forKey: policy.sourceUninstallIntentKey))
        XCTAssertTrue(defaults.bool(forKey: policy.transactionJournalKey))
    }

    func testLostJournalLoadsValidatedDestinationWithoutLegacySource() throws {
        let oldMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.6")
        let trackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: oldMouseURL)
        _ = try store.installPackage(from: trackpadURL)
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(
                    record: record,
                    plugins: [MockDynamicPlugin(id: record.id)],
                    errorMessage: nil
                )
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(
            manager.loadInstalledPlugins().map(\.metadata.id),
            ["trackpad-gestures"]
        )
        XCTAssertEqual(loader.receivedRecordIDBatches, [["trackpad-gestures"]])
        XCTAssertTrue(manager.featureExtractionMigrationIsInProgress())
        XCTAssertNil(defaults.object(
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1.in-progress"
        ))
    }

    func testLostJournalFallsBackToLegacySourceAfterDestinationReadinessFailure() throws {
        let oldMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.6")
        let trackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: oldMouseURL)
        _ = try store.installPackage(from: trackpadURL)
        let destinationPlugin = MockDynamicPlugin(
            id: "trackpad-gestures",
            readinessError: MockFeatureExtractionReadinessError.listenerUnavailable
        )
        let sourcePlugin = MockDynamicPlugin(id: "mouse-enhancer")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(
                    record: record,
                    plugins: [
                        record.id == "trackpad-gestures" ? destinationPlugin : sourcePlugin,
                    ],
                    errorMessage: nil
                )
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(
            manager.loadInstalledPlugins().map(\.metadata.id),
            ["mouse-enhancer"]
        )
        XCTAssertEqual(loader.receivedRecordIDBatches, [
            ["trackpad-gestures"],
            ["mouse-enhancer"],
        ])
        XCTAssertEqual(destinationPlugin.deactivationReasons, [.disabled])
    }

    func testBatchUpdatingLoadedPluginsReloadsOnlyOnce() async throws {
        let firstAlphaURL = try makePackage(id: "com.example.alpha", version: "1.0.0", displayName: "Alpha")
        let firstBetaURL = try makePackage(id: "com.example.beta", version: "1.0.0", displayName: "Beta")
        let updateAlphaURL = try makePackage(id: "com.example.alpha", version: "2.0.0", displayName: "Alpha")
        let updateBetaURL = try makePackage(id: "com.example.beta", version: "2.0.0", displayName: "Beta")
        let store = makeStore()
        _ = try store.installPackage(from: firstAlphaURL)
        _ = try store.installPackage(from: firstBetaURL)
        let alphaPlugin = MockDynamicPlugin(id: "com.example.alpha")
        let betaPlugin = MockDynamicPlugin(id: "com.example.beta")
        let pluginsByID = [
            "com.example.alpha": alphaPlugin,
            "com.example.beta": betaPlugin,
        ]
        let loader = StubDynamicPluginLoader { records in
            records.compactMap { record in
                guard let plugin = pluginsByID[record.id] else {
                    return nil
                }

                return DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        var pluginChangeBatches: [[String]] = []
        manager.onPluginsChanged = { plugins in
            pluginChangeBatches.append(plugins.map(\.metadata.id))
        }

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.alpha", "com.example.beta"])

        let failures = await manager.updatePluginPackages([
            (sourceURL: updateAlphaURL, catalogEntry: makeCatalogEntry(id: "com.example.alpha", version: "2.0.0")),
            (sourceURL: updateBetaURL, catalogEntry: makeCatalogEntry(id: "com.example.beta", version: "2.0.0")),
        ])

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(loader.receivedRecordIDBatches, [
            ["com.example.alpha", "com.example.beta"],
        ])
        XCTAssertEqual(pluginChangeBatches, [[]])
        XCTAssertEqual(alphaPlugin.deactivationReasons, [.updating])
        XCTAssertEqual(betaPlugin.deactivationReasons, [.updating])
        XCTAssertEqual(
            store.installedRecords().map { "\($0.id):\($0.manifest.version)" },
            [
                "com.example.alpha:2.0.0",
                "com.example.beta:2.0.0",
            ]
        )
        XCTAssertTrue(manager.pluginManagementItems.allSatisfy { item in
            if case .restartRequired = item.state {
                return true
            }

            return false
        })
    }

    func testUninstallingLoadedPluginDeletesPackageAndRemovesManagementItem() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let plugin = MockDynamicPlugin(id: "com.example.demo")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])

        var revokedBeforeTeardown = false
        manager.onPluginWillDeactivate = { id, reason in
            XCTAssertEqual(id, "com.example.demo")
            XCTAssertEqual(reason, .uninstalling)
            XCTAssertTrue(plugin.deactivationReasons.isEmpty)
            XCTAssertFalse(store.installedRecords().isEmpty)
            revokedBeforeTeardown = true
        }

        try manager.uninstallPlugin(pluginID: "com.example.demo")

        XCTAssertTrue(revokedBeforeTeardown)
        XCTAssertEqual(plugin.deactivationReasons, [.uninstalling])
        XCTAssertTrue(manager.loadInstalledPlugins().isEmpty)
        XCTAssertTrue(manager.pluginManagementItems.isEmpty)
        XCTAssertTrue(store.installedRecords().isEmpty)
    }

    func testFailedUninstallRestoresPrimaryIconAndSuccessfulRetryClearsSelection() throws {
        let sourceURL = try makePackage(id: "com.example.icon")
        var failsRemoval = true
        let store = PluginPackageStore(
            rootDirectory: temporaryRoot, userDefaults: defaults,
            packageFileMover: { source, destination in
                if failsRemoval, destination.lastPathComponent.hasPrefix("uninstall-") {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.moveItem(at: source, to: destination)
            },
            hostVersion: "1.0.0"
        )
        _ = try store.installPackage(from: sourceURL)
        var currentPlugin: MockDynamicIconPlugin?
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                let plugin = MockDynamicIconPlugin()
                currentPlugin = plugin
                return DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let host = PluginHost(
            plugins: [], dynamicPluginManager: manager, shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        defer { host.deactivateAllPlugins() }
        let oldContext = try XCTUnwrap(currentPlugin?.menuBarIconHostContext)
        try oldContext.requestPlacement(.primary, for: "status").get()
        let stored = defaults.data(forKey: PluginMenuBarIconCoordinator.preferenceKey)

        XCTAssertThrowsError(try host.uninstallDynamicPlugin(pluginID: "com.example.icon"))
        XCTAssertTrue(manager.isInstalledPlugin("com.example.icon"))
        XCTAssertEqual(currentPlugin?.menuBarIconHostContext?.placement(for: "status"), .primary)
        XCTAssertEqual(defaults.data(forKey: PluginMenuBarIconCoordinator.preferenceKey), stored)
        XCTAssertEqual(host.menuBarIconCoordinator.primaryIconOwner?.requiresRestart, false)
        guard case .failure(.unavailable) = oldContext.requestPlacement(.standalone, for: "status") else {
            return XCTFail("The old context must remain revoked after rollback")
        }

        failsRemoval = false
        try host.uninstallDynamicPlugin(pluginID: "com.example.icon")
        XCTAssertNil(host.menuBarIconCoordinator.primaryIconOwner)
        XCTAssertNil(defaults.data(forKey: PluginMenuBarIconCoordinator.preferenceKey))
        XCTAssertFalse(manager.isInstalledPlugin("com.example.icon"))
    }

    private func makeStore(
        privateDataKeyRemover: ((String) throws -> Void)? = nil
    ) -> PluginPackageStore {
        PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: defaults,
            privateDataKeyRemover: privateDataKeyRemover,
            hostVersion: "1.0.0"
        )
    }

    private func makePackage(
        id: String,
        version: String = "1.0.0",
        displayName: String = "Demo",
        bundleRelativePath: String = "Demo.bundle",
        pluginKitVersion: Int = PluginPackageManifestLoader.supportedPluginKitVersion,
        minHostVersion: String = "0.1.0",
        releaseChannel: String? = nil,
        uninstallDataPolicy: PluginPackageManifest.UninstallDataPolicy? = nil,
        localizedMetadata: [String: PluginLocalizedMetadata]? = nil
    ) throws -> URL {
        let packageURL = temporaryRoot
            .appendingPathComponent("Source", isDirectory: true)
            .appendingPathComponent("\(id)-\(version)", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = packageURL.appendingPathComponent(bundleRelativePath, isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = PluginPackageManifest(
            id: id,
            displayName: displayName,
            version: version,
            minHostVersion: minHostVersion,
            pluginKitVersion: pluginKitVersion,
            bundleRelativePath: bundleRelativePath,
            releaseChannel: releaseChannel,
            localizedMetadata: localizedMetadata,
            uninstallDataPolicy: uninstallDataPolicy
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: packageURL.appendingPathComponent("plugin.json"))

        return packageURL
    }

    private func makeCatalogEntry(
        id: String,
        version: String,
        releaseChannel: String? = nil
    ) -> PluginCatalogEntry {
        PluginCatalogEntry(
            id: id,
            displayName: "Demo",
            summary: "示例插件",
            version: version,
            minimumHostVersion: "0.1.0",
            package: PluginCatalogPackage(
                url: URL(fileURLWithPath: "/tmp/Demo.mactoolsplugin"),
                sha256: String(repeating: "a", count: 64),
                size: 42
            ),
            releaseChannel: releaseChannel
        )
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
    private(set) var activationContexts: [PluginRuntimeContext] = []
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

    func activate(context: PluginRuntimeContext) {
        activationContexts.append(context)
    }

    func deactivate(reason: PluginDeactivationReason) {
        deactivationReasons.append(reason)
    }

    func validateFeatureExtractionReadiness() throws {
        if let readinessError {
            throw readinessError
        }
    }
}

@MainActor
private final class MockDynamicIconPlugin: MacToolsPlugin, PluginMenuBarIconProviding, PluginMenuBarIconHostContextConsuming {
    let metadata = PluginMetadata(
        id: "com.example.icon", title: "Icon", iconName: "circle", iconTint: .blue, order: 1, defaultDescription: "Test"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var onMenuBarIconChange: ((String) -> Void)?
    var menuBarIconHostContext: PluginMenuBarIconHostContext?
    var menuBarIconDescriptors: [PluginMenuBarIconDescriptor] { [.init(id: "status", title: "Status")] }

    func menuBarIconPlacementDidChange() {}
    func menuBarIcon(for iconID: String, context: PluginMenuBarIconRenderContext) -> PluginMenuBarIconSnapshot? {
        guard let image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil) else { return nil }
        return .init(revision: 0, image: image, isTemplate: true, tooltip: "Test", accessibilityDescription: "Test")
    }
}

private enum MockFeatureExtractionReadinessError: Error {
    case listenerUnavailable
}
