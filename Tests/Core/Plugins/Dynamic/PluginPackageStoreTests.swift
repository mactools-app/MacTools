import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class PluginPackageStoreTests: XCTestCase {
    private var temporaryRoot: URL!
    private var defaults: UserDefaults!
    private let suiteName = "PluginPackageStoreTests"

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginPackageStoreTests-\(UUID().uuidString)", isDirectory: true)
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

    func testInstallCopiesPackageIntoInstalledDirectory() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()

        let record = try store.installPackage(from: sourceURL)

        XCTAssertEqual(record.id, "com.example.demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.packageURL.path))
        XCTAssertEqual(store.installedRecords().map(\.id), ["com.example.demo"])
        XCTAssertEqual(store.installedRecords().first?.state, .installed)
    }

    func testHostUpgradeRetainsOldTrackpadPackageWithoutLoadingIt() throws {
        let oldStore = makeStore(hostVersion: "2.0.1")
        let oldPackage = try oldStore.installPackage(from: makePackage(id: "trackpad-gestures", version: "2.0.1"))
        let store = makeStore(hostVersion: "2.0.2")
        _ = try store.installPackage(from: makePackage(id: "middle-click", version: "2.0.2"))
        let loader = RequirementRecordingLoader()
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        _ = manager.loadInstalledPlugins()

        XCTAssertEqual(loader.requestedIDs, ["middle-click"])
        let retained = try XCTUnwrap(store.installedRecords().first { $0.id == "trackpad-gestures" })
        guard case .incompatible = retained.state else { return XCTFail("Old input code must not activate") }
        XCTAssertEqual(retained.manifest.version, "2.0.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPackage.packageURL.path))
        XCTAssertThrowsError(try store.installPackage(from: makePackage(id: "trackpad-gestures", version: "2.0.0"))) {
            XCTAssertEqual($0 as? PluginPackageManifestError,
                           .incompatiblePluginVersion(required: "2.0.2", current: "2.0.0"))
        }
    }

    func testMissingRequirementPreventsInstallationAndDisablesExistingPackage() throws {
        var found = false
        let checker = PluginRequirementChecker(macOSVersion: { "27.0" }, applicationInstalled: { _ in found })
        let store = makeStore(requirementChecker: checker)
        let source = try makePackage(id: "com.example.siri", requirements: PluginRequirementTestData.requirements())
        XCTAssertThrowsError(try store.installPackage(from: source)) {
            XCTAssertEqual($0 as? PluginRequirementChecker.Failure, .application("Siri AI"))
        }
        XCTAssertTrue(store.installedRecords().isEmpty)
        found = true
        XCTAssertEqual(try store.installPackage(from: source).state, .installed)
        found = false
        guard case .incompatible = try XCTUnwrap(store.installedRecords().first).state else {
            return XCTFail("The installed plugin must not be eligible for loading")
        }
        let loader = RequirementRecordingLoader()
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        XCTAssertTrue(manager.loadInstalledPlugins().isEmpty)
        XCTAssertTrue(loader.requestedIDs.isEmpty)
        found = true
        _ = manager.loadInstalledPlugins()
        XCTAssertEqual(loader.requestedIDs, ["com.example.siri"])
    }

    func testUnsupportedOSRejectsManualPackageInstallation() throws {
        let store = makeStore(requirementChecker: .init(macOSVersion: { "26.6" }, applicationInstalled: { _ in true }))
        let source = try makePackage(id: "com.example.siri", requirements: PluginRequirementTestData.requirements())
        XCTAssertThrowsError(try store.installPackage(from: source)) {
            XCTAssertEqual($0 as? PluginRequirementChecker.Failure, .macOS("27.0"))
        }
        XCTAssertTrue(store.installedRecords().isEmpty)
    }

    func testInstallRejectsPreviousPluginKitPackage() throws {
        let sourceURL = try makePackage(
            id: "com.example.demo",
            pluginKitVersion: 1
        )
        let store = makeStore()

        XCTAssertThrowsError(try store.installPackage(from: sourceURL)) { error in
            XCTAssertEqual(error as? PluginPackageManifestError, .unsupportedPluginKitVersion(1))
        }
    }

    func testUninstallDeletesPackageAndCanRemoveStorage() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let storage = UserDefaultsPluginStorage(pluginID: "com.example.demo", userDefaults: defaults)
        storage.set("value", forKey: "setting")

        try store.uninstall(pluginID: "com.example.demo", removeData: true)

        XCTAssertTrue(store.installedRecords().isEmpty)
        XCTAssertNil(defaults.object(forKey: "plugin.com.example.demo.setting"))
    }

    func testManifestPolicyRemovesPrivateDataAndKeyWithoutLoadedPlugin() throws {
        var removedKeyPluginIDs: [String] = []
        let sourceURL = try makePackage(
            id: "com.example.private",
            uninstallDataPolicy: .removePrivateData
        )
        let store = makeStore(privateDataKeyRemover: { removedKeyPluginIDs.append($0) })
        _ = try store.installPackage(from: sourceURL)
        let supportDirectory = store.dataDirectory.appendingPathComponent(
            "com.example.private",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: supportDirectory.appendingPathComponent("history.mth"))
        UserDefaultsPluginStorage(pluginID: "com.example.private", userDefaults: defaults)
            .set(true, forKey: "enabled")

        try store.uninstall(pluginID: "com.example.private", removeData: false)

        XCTAssertEqual(removedKeyPluginIDs, ["com.example.private"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportDirectory.path))
        XCTAssertNil(defaults.object(forKey: "plugin.com.example.private.enabled"))
        XCTAssertTrue(store.installedRecords().isEmpty)
    }

    func testPackageStagingFailureLeavesPrivateDataAndKeyUntouched() throws {
        var removedKeyPluginIDs: [String] = []
        let sourceURL = try makePackage(
            id: "com.example.private",
            uninstallDataPolicy: .removePrivateData
        )
        let store = makeStore(
            packageFileMover: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            privateDataKeyRemover: { removedKeyPluginIDs.append($0) }
        )
        _ = try store.installPackage(from: sourceURL)
        let supportDirectory = store.dataDirectory.appendingPathComponent(
            "com.example.private",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let historyURL = supportDirectory.appendingPathComponent("history.sqlite3")
        try Data("private".utf8).write(to: historyURL)

        XCTAssertThrowsError(try store.uninstall(pluginID: "com.example.private", removeData: false)) {
            guard case .removeFailed = $0 as? PluginPackageStoreError else {
                return XCTFail("Expected removeFailed, got \($0)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))
        XCTAssertTrue(removedKeyPluginIDs.isEmpty)
        XCTAssertEqual(store.installedRecords().map(\.id), ["com.example.private"])
    }

    func testPrivateUninstallJournalRecoversCrashBoundariesIdempotently() throws {
        let pluginIDs = [
            "com.example.private-before-stage",
            "com.example.private-after-stage",
            "com.example.private-after-directories",
        ]
        let store = makeStore(privateDataKeyRemover: { _ in })
        for pluginID in pluginIDs {
            let sourceURL = try makePackage(
                id: pluginID,
                uninstallDataPolicy: .removePrivateData
            )
            _ = try store.installPackage(from: sourceURL)
            let supportDirectory = store.dataDirectory.appendingPathComponent(
                pluginID,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
            try Data("private".utf8).write(
                to: supportDirectory.appendingPathComponent("history.sqlite3")
            )
        }

        var intents: [String: String] = [:]
        for pluginID in pluginIDs {
            let stagedName = "uninstall-\(pluginID)-crash.mactoolsplugin"
            intents[pluginID] = stagedName
            guard pluginID != pluginIDs[0] else { continue }
            let installedURL = store.installedDirectory
                .appendingPathComponent(pluginID, isDirectory: true)
                .appendingPathExtension("mactoolsplugin")
            try FileManager.default.moveItem(
                at: installedURL,
                to: store.stagingDirectory.appendingPathComponent(stagedName)
            )
        }
        try FileManager.default.removeItem(
            at: store.dataDirectory.appendingPathComponent(pluginIDs[2], isDirectory: true)
        )
        defaults.set(intents, forKey: "plugins.dynamic.privateUninstallIntents")
        XCTAssertTrue(defaults.synchronize())

        var removedKeyPluginIDs: [String] = []
        let recoveredStore = makeStore(
            privateDataKeyRemover: { removedKeyPluginIDs.append($0) }
        )

        XCTAssertTrue(recoveredStore.installedRecords().isEmpty)
        XCTAssertEqual(Set(removedKeyPluginIDs), Set(pluginIDs))
        for pluginID in pluginIDs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: recoveredStore.dataDirectory
                .appendingPathComponent(pluginID, isDirectory: true).path))
        }
        let stagedResidue = try FileManager.default.contentsOfDirectory(
            at: recoveredStore.stagingDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("com.example.private-") }
        XCTAssertTrue(stagedResidue.isEmpty)
        XCTAssertEqual(
            defaults.dictionary(forKey: "plugins.dynamic.privateUninstallIntents")?.count,
            0
        )

        let secondRecovery = makeStore(
            privateDataKeyRemover: { removedKeyPluginIDs.append($0) }
        )
        XCTAssertTrue(secondRecovery.installedRecords().isEmpty)
        XCTAssertEqual(removedKeyPluginIDs.count, pluginIDs.count)
    }

    func testPrivateUninstallJournalRejectsUnsafePathsWithoutDeletingThem() throws {
        let protectedURL = temporaryRoot.appendingPathComponent("protected.mactoolsplugin")
        try FileManager.default.createDirectory(
            at: protectedURL,
            withIntermediateDirectories: true
        )
        defaults.set(
            ["../protected": "../protected.mactoolsplugin"],
            forKey: "plugins.dynamic.privateUninstallIntents"
        )
        XCTAssertTrue(defaults.synchronize())

        _ = makeStore(privateDataKeyRemover: { _ in
            XCTFail("Invalid journal must not remove a private key")
        })

        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedURL.path))
        XCTAssertEqual(
            defaults.dictionary(forKey: "plugins.dynamic.privateUninstallIntents")?.count,
            0
        )
    }

    func testFailedUpdateRestoresExistingPackage() throws {
        let sourceURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let invalidUpdateURL = try makePackage(id: "com.example.demo", version: "2.0.0", bundleRelativePath: "Missing.bundle")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)

        do {
            _ = try store.updatePackage(from: invalidUpdateURL)
            XCTFail("Expected update failure")
        } catch {
            // Expected path.
        }

        let record = try XCTUnwrap(store.installedRecords().first)
        XCTAssertEqual(record.manifest.version, "1.0.0")
        XCTAssertEqual(record.state, .installed)
    }

    func testUpdateDoesNotInstallPackageThatIsNoLongerInstalled() throws {
        let updateURL = try makePackage(id: "com.example.demo", version: "2.0.0")
        let store = makeStore()

        XCTAssertThrowsError(try store.updatePackage(from: updateURL)) { error in
            guard let storeError = error as? PluginPackageStoreError,
                  case let .packageNotFound(pluginID) = storeError else {
                return XCTFail("Expected packageNotFound, got \(error)")
            }

            XCTAssertEqual(pluginID, "com.example.demo")
        }
        XCTAssertTrue(store.installedRecords().isEmpty)
    }

    private func makeStore(
        synchronizeUserDefaults: @escaping (UserDefaults) -> Bool = { $0.synchronize() },
        packageFileMover: ((URL, URL) throws -> Void)? = nil,
        packageFileRemover: ((URL) throws -> Void)? = nil,
        privateDataDirectoryRemover: ((URL) throws -> Void)? = nil,
        privateDataKeyRemover: ((String) throws -> Void)? = nil,
        now: @escaping () -> Date = { Date() },
        requirementChecker: PluginRequirementChecker? = nil,
        hostVersion: String = "1.0.0"
    ) -> PluginPackageStore {
        PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: defaults,
            synchronizeUserDefaults: synchronizeUserDefaults,
            packageFileMover: packageFileMover,
            packageFileRemover: packageFileRemover,
            privateDataDirectoryRemover: privateDataDirectoryRemover,
            privateDataKeyRemover: privateDataKeyRemover,
            now: now,
            hostVersion: hostVersion, requirementChecker: requirementChecker ?? PluginRequirementChecker()
        )
    }

    private func makePackage(
        id: String,
        version: String = "1.0.0",
        bundleRelativePath: String = "Demo.bundle",
        pluginKitVersion: Int = PluginPackageManifestLoader.supportedPluginKitVersion,
        uninstallDataPolicy: PluginPackageManifest.UninstallDataPolicy? = nil,
        requirements: PluginProductMetadata.Requirements? = nil
    ) throws -> URL {
        let packageURL = temporaryRoot
            .appendingPathComponent("Source", isDirectory: true)
            .appendingPathComponent("\(id)-\(version)", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = packageURL.appendingPathComponent(bundleRelativePath, isDirectory: true)

        if bundleRelativePath == "Demo.bundle" {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        }

        let manifest = PluginPackageManifest(
            id: id,
            displayName: "Demo",
            version: version,
            minHostVersion: "0.1.0",
            pluginKitVersion: pluginKitVersion,
            bundleRelativePath: bundleRelativePath,
            uninstallDataPolicy: uninstallDataPolicy, requirements: requirements
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: packageURL.appendingPathComponent("plugin.json"))

        return packageURL
    }
}

@MainActor
private final class RequirementRecordingLoader: DynamicPluginLoading {
    var preparePluginForActivation: ((any MacToolsPlugin) -> Void)?
    var requestedIDs: [String] = []
    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult] {
        requestedIDs = records.map(\.id)
        return records.map { .init(record: $0, plugins: [], errorMessage: nil) }
    }
}
