import Foundation
import MacToolsPluginKit

struct PluginExtractionMigrationPolicy {
    let id: String
    let sourcePluginID: String
    let destinationPluginID: String
    let sourceRetirementVersion: String
    let minimumDestinationVersion: String
    let legacyPreferenceKey: String
    let completionKey: String

    var transactionJournalKey: String {
        "\(completionKey).in-progress"
    }

    var sourceUninstallIntentKey: String {
        "\(completionKey).source-uninstall-intent"
    }

    var sourceUninstallRemoveDataKey: String {
        "\(sourceUninstallIntentKey).remove-data"
    }

    let destinationPreferenceMigrationMarkerKey = "migration.mouse-enhancer-middle-click.v2"

    static let mouseEnhancerMiddleClick = PluginExtractionMigrationPolicy(
        id: "mouse-enhancer-middle-click.v1",
        sourcePluginID: "mouse-enhancer",
        destinationPluginID: "trackpad-gestures",
        sourceRetirementVersion: "1.0.7",
        minimumDestinationVersion: "1.0.0",
        legacyPreferenceKey: "plugin.mouse-enhancer.mouse-enhancer.middle-click.enabled",
        completionKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1"
    )
}

enum PluginPackageMutationAuthorization {
    case standard
    case featureExtractionCoordinator
}

struct PluginPackageRollbackSnapshot {
    let pluginID: String
    let packageURL: URL
}

struct PluginManagementItem: Identifiable, Equatable {
    enum State: Equatable {
        case available
        case localDevelopment
        case installed
        case updateAvailable(installedVersion: String, catalogVersion: String)
        case restartRequired
        case failed(String)
        case incompatible(String)
        case revoked(String?)
    }

    let id: String
    let title: String
    let summary: String?
    let version: String
    let state: State
    let packageURL: URL?
    let requiresRestartToFullyUnload: Bool
    let releaseNotesURL: URL?
    let category: String?
    let releaseChannel: String?
    let capabilities: PluginPackageManifest.Capabilities?
    let uninstallDataPolicy: PluginPackageManifest.UninstallDataPolicy
    let productMetadata: PluginProductMetadata?

    var productSearchKeywords: [String] {
        productMetadata?.searchKeywords ?? []
    }

    init(
        id: String,
        title: String,
        summary: String?,
        version: String,
        state: State,
        packageURL: URL?,
        requiresRestartToFullyUnload: Bool,
        releaseNotesURL: URL?,
        category: String? = nil,
        releaseChannel: String? = nil,
        capabilities: PluginPackageManifest.Capabilities? = nil,
        uninstallDataPolicy: PluginPackageManifest.UninstallDataPolicy = .preserve,
        productMetadata: PluginProductMetadata? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.version = version
        self.state = state
        self.packageURL = packageURL
        self.requiresRestartToFullyUnload = requiresRestartToFullyUnload
        self.releaseNotesURL = releaseNotesURL
        self.category = category
        self.releaseChannel = releaseChannel
        self.capabilities = capabilities
        self.uninstallDataPolicy = uninstallDataPolicy
        self.productMetadata = productMetadata
    }

    var statusText: String {
        switch state {
        case .available:
            return AppL10n.plugins("plugin.status.available", defaultValue: "可安装")
        case .localDevelopment:
            return AppL10n.plugins("plugin.status.localDevelopment", defaultValue: "本地开发")
        case .installed:
            return AppL10n.plugins("plugin.status.installed", defaultValue: "已安装")
        case .updateAvailable:
            return AppL10n.plugins("plugin.status.updateAvailable", defaultValue: "可更新")
        case .restartRequired:
            return AppL10n.plugins("plugin.status.restartRequired", defaultValue: "需重启")
        case .failed:
            return AppL10n.plugins("plugin.status.failed", defaultValue: "加载失败")
        case .incompatible:
            return AppL10n.plugins("plugin.status.incompatible", defaultValue: "不兼容")
        case .revoked:
            return AppL10n.plugins("plugin.status.revoked", defaultValue: "已撤回")
        }
    }

    var detailText: String {
        switch state {
        case .available:
            return summary ?? AppL10n.plugins("plugin.detail.available", defaultValue: "可以安装此插件。")
        case .localDevelopment:
            return summary ?? AppL10n.plugins("plugin.detail.localDevelopment", defaultValue: "来自本地开发插件列表。")
        case .installed:
            if requiresRestartToFullyUnload {
                return AppL10n.plugins("plugin.detail.restartRequiredAfterUpdate", defaultValue: "新版本将在重启后启用，旧代码将在重启后彻底释放。")
            }

            return summary ?? ""
        case let .updateAvailable(installedVersion, catalogVersion):
            return AppL10n.pluginsFormat(
                "plugin.detail.updateAvailableFormat",
                defaultValue: "已安装 %@，可更新到 %@。",
                installedVersion,
                catalogVersion
            )
        case .restartRequired:
            return AppL10n.plugins("plugin.detail.restartRequiredAfterUpdate", defaultValue: "新版本将在重启后启用，旧代码将在重启后彻底释放。")
        case let .failed(reason), let .incompatible(reason):
            return reason
        case let .revoked(reason):
            return reason ?? AppL10n.plugins("plugin.detail.revoked", defaultValue: "此版本已被撤回。")
        }
    }

    var canInstall: Bool {
        switch state {
        case .available, .localDevelopment:
            return true
        default:
            return false
        }
    }

    var canUpdate: Bool {
        if case .updateAvailable = state {
            return true
        }

        return false
    }

    var canUninstall: Bool {
        switch state {
        case .installed, .updateAvailable, .restartRequired, .failed, .incompatible, .revoked:
            return packageURL != nil
        case .available, .localDevelopment:
            return false
        }
    }
}

struct PluginPackageUpdateFailure {
    let pluginID: String
    let error: Error
}

struct InstalledPluginMetadata {
    let capabilitiesByID: [String: PluginPackageManifest.Capabilities]
    let categoriesByID: [String: String?]
    let releaseChannelsByID: [String: String?]
    let manifestsByID: [String: PluginPackageManifest]
    let installedAtByID: [String: Date]

    init(records: [PluginPackageRecord]) {
        capabilitiesByID = Dictionary(uniqueKeysWithValues: records.compactMap {
            $0.state.isLoadable ? ($0.id, $0.manifest.capabilities) : nil
        })
        categoriesByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.manifest.category) })
        releaseChannelsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.manifest.releaseChannel) })
        manifestsByID = Dictionary(records.map { ($0.id, $0.manifest) }, uniquingKeysWith: { _, latest in latest })
        installedAtByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.installedAt) })
    }
}

@MainActor
final class DynamicPluginManager: ObservableObject {
    private let packageStore: PluginPackageStore
    private let pluginLoader: any DynamicPluginLoading
    private var loadedPluginsByID: [String: [any MacToolsPlugin]] = [:]
    private var loadedPluginIDs: Set<String> = []
    private var deferredPluginIDs: Set<String> = []
    private var catalogSnapshot: PluginCatalogSnapshot?
    private var managementResults: [DynamicPluginLoadResult] = []
    private var latestLoadErrorsByID: [String: String] = [:]
    private var packageMutationGenerationsByPluginID: [String: UInt64] = [:]

    @Published private(set) var pluginManagementItems: [PluginManagementItem] = []
    var onPluginsChanged: (([any MacToolsPlugin]) -> Void)?
    /// Revoke host-owned capabilities before plugin teardown or package removal.
    var onPluginWillDeactivate: ((String, PluginDeactivationReason) -> Void)?

    var temporaryDirectory: URL {
        packageStore.temporaryDirectory
    }

    var hostVersion: String {
        packageStore.hostVersion
    }

    func requirementFailure(for requirements: PluginProductMetadata.Requirements?) -> PluginRequirementChecker.Failure? {
        packageStore.requirementChecker.failure(for: requirements)
    }

    init(
        packageStore: PluginPackageStore = PluginPackageStore(),
        pluginLoader: (any DynamicPluginLoading)? = nil
    ) {
        self.packageStore = packageStore
        self.pluginLoader = pluginLoader ?? DynamicPluginLoader(packageStore: packageStore)
    }

    func loadInstalledPlugins() -> [any MacToolsPlugin] {
        let records = packageStore.installedRecords()
        deactivateMissingPlugins(records: records)

        let extractionPolicy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        let extractionHasPersistedJournal = packageStore
            .featureExtractionMigrationHasPersistedJournal()
        let extractionHasInferredUnsafeState = !extractionHasPersistedJournal
            && packageStore.featureExtractionMigrationHasUnsafeInstalledState()
        let extractionRequiresRuntimeArbitration = extractionHasPersistedJournal
            || extractionHasInferredUnsafeState
        let legacySourceIsAlreadyLoaded = loadedPluginsByID[extractionPolicy.sourcePluginID] != nil

        let recordsToLoad = records.filter { record in
            guard case .installed = record.state else {
                return false
            }

            if extractionRequiresRuntimeArbitration,
               record.id == extractionPolicy.sourcePluginID,
               !PluginVersionComparator.isVersion(
                   record.manifest.version,
                   atLeast: extractionPolicy.sourceRetirementVersion
               ) {
                return false
            }

            if extractionRequiresRuntimeArbitration,
               legacySourceIsAlreadyLoaded,
               record.id == extractionPolicy.destinationPluginID {
                return false
            }

            return loadedPluginsByID[record.id] == nil && !deferredPluginIDs.contains(record.id)
        }
        var loadedResults = recordsToLoad.isEmpty
            ? []
            : pluginLoader.loadInstalledPlugins(from: recordsToLoad)
        if extractionRequiresRuntimeArbitration, !legacySourceIsAlreadyLoaded {
            loadedResults = resultsByFallingBackToLegacyExtractionSourceIfNeeded(
                loadedResults,
                installedRecords: records,
                policy: extractionPolicy
            )
        }
        let loadedResultsByID = Dictionary(
            uniqueKeysWithValues: loadedResults.map { ($0.record.id, $0) }
        )

        for result in loadedResults where result.errorMessage == nil && !result.plugins.isEmpty {
            loadedPluginsByID[result.record.id] = result.plugins
            loadedPluginIDs.insert(result.record.id)
        }

        let results = records.map { record in
            if let activePlugins = loadedPluginsByID[record.id] {
                return DynamicPluginLoadResult(record: record, plugins: activePlugins, errorMessage: nil)
            }

            if let loadedResult = loadedResultsByID[record.id] {
                return loadedResult
            }

            if deferredPluginIDs.contains(record.id) {
                return DynamicPluginLoadResult(
                    record: record.markingRestartRequired(),
                    plugins: [],
                    errorMessage: nil
                )
            }

            return DynamicPluginLoadResult(record: record, plugins: [], errorMessage: nil)
        }

        latestLoadErrorsByID = Dictionary(
            uniqueKeysWithValues: results.compactMap { result in
                result.errorMessage.map { (result.record.id, $0) }
            }
        )
        rebuildManagementItems(results: results, catalogSnapshot: catalogSnapshot)
        return activePlugins(from: records)
    }

    private func resultsByFallingBackToLegacyExtractionSourceIfNeeded(
        _ initialResults: [DynamicPluginLoadResult],
        installedRecords: [PluginPackageRecord],
        policy: PluginExtractionMigrationPolicy
    ) -> [DynamicPluginLoadResult] {
        if loadedPluginsByID[policy.destinationPluginID] != nil {
            return initialResults
        }

        var results = initialResults
        if let destinationIndex = results.firstIndex(where: {
            $0.record.id == policy.destinationPluginID
        }) {
            let destinationResult = results[destinationIndex]
            let destinationMeetsMinimum = PluginVersionComparator.isVersion(
                destinationResult.record.manifest.version,
                atLeast: policy.minimumDestinationVersion
            )
            if destinationMeetsMinimum,
               destinationResult.errorMessage == nil,
               !destinationResult.plugins.isEmpty {
                do {
                    try validateFeatureExtractionReadiness(
                        plugins: destinationResult.plugins,
                        pluginID: policy.destinationPluginID
                    )
                    return results
                } catch {
                    deactivatePluginInstances(destinationResult.plugins, reason: .disabled)
                    results[destinationIndex] = DynamicPluginLoadResult(
                        record: destinationResult.record,
                        plugins: [],
                        errorMessage: error.localizedDescription
                    )
                }
            } else {
                if !destinationResult.plugins.isEmpty {
                    deactivatePluginInstances(destinationResult.plugins, reason: .disabled)
                }
                results[destinationIndex] = DynamicPluginLoadResult(
                    record: destinationResult.record,
                    plugins: [],
                    errorMessage: destinationResult.errorMessage
                        ?? (destinationMeetsMinimum
                            ? AppL10n.plugins(
                                "plugin.error.dynamic.extractionDestinationNotReady",
                                defaultValue: "提取功能的目标插件尚未就绪。"
                            )
                            : AppL10n.plugins(
                                "plugin.error.dynamic.extractionDestinationBelowMinimum",
                                defaultValue: "提取功能的目标插件版本过低。"
                            ))
                )
            }
        }

        guard let sourceRecord = installedRecords.first(where: { record in
            guard record.id == policy.sourcePluginID,
                  case .installed = record.state,
                  !deferredPluginIDs.contains(record.id)
            else {
                return false
            }
            return !PluginVersionComparator.isVersion(
                record.manifest.version,
                atLeast: policy.sourceRetirementVersion
            )
        }) else {
            return results
        }

        results.append(contentsOf: pluginLoader.loadInstalledPlugins(from: [sourceRecord]))
        return results
    }

    func prepareInstalledPluginsWithoutLoading() {
        let records = packageStore.installedRecords()
        deactivateMissingPlugins(records: records)
        latestLoadErrorsByID = [:]
        let results = records.map { record in
            DynamicPluginLoadResult(
                record: deferredPluginIDs.contains(record.id) ? record.markingRestartRequired() : record,
                plugins: [],
                errorMessage: nil
            )
        }
        rebuildManagementItems(results: results, catalogSnapshot: catalogSnapshot)
    }

    func reloadInstalledPlugins() {
        let plugins = loadInstalledPlugins()
        onPluginsChanged?(plugins)
    }

    func installPluginPackage(
        from sourceURL: URL,
        catalogEntry: PluginCatalogEntry? = nil,
        reloadAfterInstall: Bool = true,
        authorization: PluginPackageMutationAuthorization = .standard
    ) throws {
        try validatePackage(sourceURL, matches: catalogEntry)
        let manifest = try PluginPackageManifestLoader.load(
            from: sourceURL,
            hostVersion: packageStore.hostVersion
        )
        try validateFeatureExtractionMutation(manifest: manifest, authorization: authorization)
        let record = try packageStore.installPackage(from: sourceURL)
        recordSuccessfulPackageMutation(pluginID: record.id)

        if loadedPluginIDs.contains(record.id) {
            deferredPluginIDs.insert(record.id)
            packageStore.markRequiresRestartToFullyUnload(pluginID: record.id)
        } else {
            deferredPluginIDs.remove(record.id)
        }

        if reloadAfterInstall {
            reloadInstalledPlugins()
        }
    }

    func updatePluginPackage(
        from sourceURL: URL,
        catalogEntry: PluginCatalogEntry? = nil,
        reloadAfterUpdate: Bool = true,
        authorization: PluginPackageMutationAuthorization = .standard
    ) throws {
        try updatePluginPackageWithoutReload(
            from: sourceURL,
            catalogEntry: catalogEntry,
            authorization: authorization
        )
        if reloadAfterUpdate {
            reloadInstalledPlugins()
        }
    }

    /// Removes a package installed as the first half of a migration when validation or the paired
    /// source update fails. Runtime preflight may map the bundle, but its instance is torn down;
    /// rollback is unavailable once the manager has admitted the package to its normal lifecycle.
    func rollbackUnloadedPluginInstallation(pluginID: String) throws {
        guard !loadedPluginIDs.contains(pluginID) else {
            throw DynamicPluginManagerOperationError.rollbackRequiresUnloadedPlugin(pluginID)
        }

        try packageStore.uninstall(pluginID: pluginID, removeData: false)
        recordSuccessfulPackageMutation(pluginID: pluginID)
        deferredPluginIDs.remove(pluginID)
        loadedPluginsByID.removeValue(forKey: pluginID)
    }

    func makeRollbackSnapshot(pluginID: String) throws -> PluginPackageRollbackSnapshot {
        guard !loadedPluginIDs.contains(pluginID) else {
            throw DynamicPluginManagerOperationError.rollbackRequiresUnloadedPlugin(pluginID)
        }
        guard let record = packageStore.installedRecords().first(where: { $0.id == pluginID }) else {
            throw DynamicPluginManagerOperationError.pluginRecordNotFound(pluginID)
        }

        let snapshotURL = temporaryDirectory
            .appendingPathComponent("\(pluginID)-rollback-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        try FileManager.default.copyItem(at: record.packageURL, to: snapshotURL)
        return PluginPackageRollbackSnapshot(pluginID: pluginID, packageURL: snapshotURL)
    }

    func restoreRollbackSnapshot(_ snapshot: PluginPackageRollbackSnapshot) throws {
        guard !loadedPluginIDs.contains(snapshot.pluginID) else {
            throw DynamicPluginManagerOperationError.rollbackRequiresUnloadedPlugin(snapshot.pluginID)
        }
        _ = try packageStore.updatePackage(from: snapshot.packageURL)
        recordSuccessfulPackageMutation(pluginID: snapshot.pluginID)
        deferredPluginIDs.remove(snapshot.pluginID)
        loadedPluginsByID.removeValue(forKey: snapshot.pluginID)
    }

    func discardRollbackSnapshot(_ snapshot: PluginPackageRollbackSnapshot) {
        try? FileManager.default.removeItem(at: snapshot.packageURL)
    }

    func snapshotPluginPreferences(pluginID: String) -> [String: Any] {
        packageStore.snapshotPluginPreferences(pluginID: pluginID)
    }

    func restorePluginPreferences(_ snapshot: [String: Any], pluginID: String) {
        packageStore.restorePluginPreferences(snapshot, pluginID: pluginID)
    }

    func featureExtractionMigrationIsInProgress() -> Bool {
        packageStore.featureExtractionMigrationIsInProgress()
    }

    func featureExtractionSourceUninstallIsPending() -> Bool {
        packageStore.featureExtractionSourceUninstallIsPending()
    }

    func removePluginPreference(pluginID: String, key: String) {
        packageStore.removePluginPreference(pluginID: pluginID, key: key)
    }

    /// Runs the same trust, bundle, provider, metadata, and activation path used by normal
    /// loading, then immediately tears the instance down. A successful return proves a newly
    /// installed extraction destination can take over before its source package is retired.
    func validatePluginInstallationBeforeMigration(pluginID: String) throws {
        if let loadedPlugins = loadedPluginsByID[pluginID] {
            try validateFeatureExtractionReadiness(
                plugins: loadedPlugins,
                pluginID: pluginID
            )
            return
        }

        guard let record = packageStore.installedRecords().first(where: { $0.id == pluginID }) else {
            throw DynamicPluginManagerOperationError.pluginRecordNotFound(pluginID)
        }

        guard let result = pluginLoader.loadInstalledPlugins(from: [record])
            .first(where: { $0.record.id == pluginID })
        else {
            throw DynamicPluginManagerOperationError.pluginRuntimeValidationFailed(
                pluginID,
                AppL10n.plugins(
                    "plugin.error.dynamic.runtimeValidationNoResult",
                    defaultValue: "插件加载器未返回验证结果。"
                )
            )
        }

        defer {
            deactivatePluginInstances(result.plugins, reason: .updating)
        }
        guard result.errorMessage == nil, !result.plugins.isEmpty else {
            throw DynamicPluginManagerOperationError.pluginRuntimeValidationFailed(
                pluginID,
                result.errorMessage ?? AppL10n.plugins(
                    "plugin.error.dynamic.runtimeValidationNoPlugin",
                    defaultValue: "插件加载器未返回可用插件。"
                )
            )
        }
        try validateFeatureExtractionReadiness(
            plugins: result.plugins,
            pluginID: pluginID
        )
    }

    private func validateFeatureExtractionReadiness(
        plugins: [any MacToolsPlugin],
        pluginID: String
    ) throws {
        guard plugins.allSatisfy({ $0 is any PluginFeatureExtractionReadinessProviding }) else {
            throw DynamicPluginManagerOperationError.pluginRuntimeValidationFailed(
                pluginID,
                AppL10n.plugins(
                    "plugin.error.dynamic.runtimeValidationReadinessUnsupported",
                    defaultValue: "插件不支持功能迁移就绪检查。"
                )
            )
        }
        for plugin in plugins {
            guard let readinessProvider = plugin as? any PluginFeatureExtractionReadinessProviding else {
                throw DynamicPluginManagerOperationError.pluginRuntimeValidationFailed(
                    pluginID,
                    AppL10n.plugins(
                        "plugin.error.dynamic.runtimeValidationReadinessUnsupported",
                        defaultValue: "插件不支持功能迁移就绪检查。"
                    )
                )
            }
            try readinessProvider.validateFeatureExtractionReadiness()
        }
    }

    /// Stops an old loaded source before a replacement is preflight-activated, preventing two
    /// raw-device owners from overlapping during an in-app extraction migration.
    func suspendLoadedPluginForMigration(pluginID: String) -> Bool {
        guard loadedPluginsByID[pluginID] != nil else {
            return false
        }
        deactivateLoadedPlugins(pluginID: pluginID, reason: .disabled)
        return true
    }

    func restoreSuspendedPluginAfterMigrationFailure(pluginID: String, wasSuspended: Bool) {
        guard wasSuspended,
              isInstalledPlugin(pluginID),
              loadedPluginsByID[pluginID] == nil,
              !deferredPluginIDs.contains(pluginID)
        else {
            return
        }
        reloadInstalledPlugins()
    }

    func updatePluginPackages(
        _ updates: [(sourceURL: URL, catalogEntry: PluginCatalogEntry)],
        reloadAfterUpdate: Bool = true,
        featureExtractionAuthorizedPluginIDs: Set<String> = [],
        onPackageProcessed: (() -> Void)? = nil
    ) async -> [PluginPackageUpdateFailure] {
        guard !updates.isEmpty else {
            return []
        }

        var failures: [PluginPackageUpdateFailure] = []
        var didUpdatePackage = false

        defer {
            if reloadAfterUpdate && didUpdatePackage {
                reloadInstalledPlugins()
            }
        }

        for update in updates {
            guard isInstalledPlugin(update.catalogEntry.id) else {
                onPackageProcessed?()
                await Task.yield()
                continue
            }

            do {
                try updatePluginPackageWithoutReload(
                    from: update.sourceURL,
                    catalogEntry: update.catalogEntry,
                    authorization: featureExtractionAuthorizedPluginIDs.contains(
                        update.catalogEntry.id
                    ) ? .featureExtractionCoordinator : .standard
                )
                didUpdatePackage = true
            } catch {
                failures.append(
                    PluginPackageUpdateFailure(
                        pluginID: update.catalogEntry.id,
                        error: error
                    )
                )
            }

            onPackageProcessed?()
            await Task.yield()
        }

        return failures
    }

    private func updatePluginPackageWithoutReload(
        from sourceURL: URL,
        catalogEntry: PluginCatalogEntry? = nil,
        authorization: PluginPackageMutationAuthorization = .standard
    ) throws {
        try validatePackage(sourceURL, matches: catalogEntry)
        let manifest = try PluginPackageManifestLoader.load(
            from: sourceURL,
            hostVersion: packageStore.hostVersion
        )
        try validateFeatureExtractionMutation(manifest: manifest, authorization: authorization)
        let wasLoaded = loadedPluginIDs.contains(manifest.id)

        _ = try packageStore.updatePackage(from: sourceURL)
        recordSuccessfulPackageMutation(pluginID: manifest.id)

        if wasLoaded {
            deactivateLoadedPlugins(pluginID: manifest.id, reason: .updating)
            deferredPluginIDs.insert(manifest.id)
            packageStore.markRequiresRestartToFullyUnload(pluginID: manifest.id)
        } else {
            deferredPluginIDs.remove(manifest.id)
        }
    }

    func isPluginLoaded(_ pluginID: String) -> Bool {
        loadedPluginIDs.contains(pluginID)
    }

    func packageMutationGeneration(for pluginID: String) -> UInt64 {
        packageMutationGenerationsByPluginID[pluginID, default: 0]
    }

    private func recordSuccessfulPackageMutation(pluginID: String) {
        packageMutationGenerationsByPluginID[pluginID, default: 0] &+= 1
    }

    private func validateFeatureExtractionMutation(
        manifest: PluginPackageManifest,
        authorization: PluginPackageMutationAuthorization
    ) throws {
        guard case .standard = authorization else { return }
        let policy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        let installedVersions = installedPackageVersionsByID()
        let retiredSourceIsInstalled = installedVersions[policy.sourcePluginID].map {
            PluginVersionComparator.isVersion(
                $0,
                atLeast: policy.sourceRetirementVersion
            )
        } == true
        let destinationMinimumMustBePreserved = retiredSourceIsInstalled
            || packageStore.featureExtractionMigrationIsComplete()

        if manifest.id == policy.destinationPluginID,
           let sourceVersion = installedVersions[policy.sourcePluginID],
           !PluginVersionComparator.isVersion(
               sourceVersion,
               atLeast: policy.sourceRetirementVersion
           ) {
            throw DynamicPluginManagerOperationError.featureExtractionCoordinatorRequired(
                manifest.id
            )
        }

        if manifest.id == policy.destinationPluginID,
           !PluginVersionComparator.isVersion(
               manifest.version,
               atLeast: policy.minimumDestinationVersion
           ),
           destinationMinimumMustBePreserved {
            throw DynamicPluginManagerOperationError.featureExtractionCoordinatorRequired(
                manifest.id
            )
        }

        if manifest.id == policy.sourcePluginID,
           !PluginVersionComparator.isVersion(
               manifest.version,
               atLeast: policy.sourceRetirementVersion
           ),
           installedVersions[policy.destinationPluginID] != nil {
            throw DynamicPluginManagerOperationError.featureExtractionCoordinatorRequired(
                manifest.id
            )
        }

        if manifest.id == policy.sourcePluginID,
           PluginVersionComparator.isVersion(
               manifest.version,
               atLeast: policy.sourceRetirementVersion
           ),
           let installedSourceVersion = installedVersions[policy.sourcePluginID],
           !PluginVersionComparator.isVersion(
               installedSourceVersion,
               atLeast: policy.sourceRetirementVersion
           ) {
            throw DynamicPluginManagerOperationError.featureExtractionCoordinatorRequired(
                manifest.id
            )
        }
    }

    func isInstalledPlugin(_ pluginID: String) -> Bool {
        packageStore.installedRecords().contains { $0.id == pluginID }
    }

    /// Reads the retired global-disabled marker before the host loads
    /// packages. The host clears it only after the layout migration persists.
    func legacyHiddenPluginIDs() -> Set<String> {
        packageStore.legacyHiddenPluginIDs()
    }

    func clearLegacyHiddenPluginIDs() {
        packageStore.clearLegacyHiddenPluginIDs()
    }

    func installedCapabilitiesByID() -> [String: PluginPackageManifest.Capabilities] {
        Dictionary(
            uniqueKeysWithValues: packageStore.installedRecords().compactMap { record in
                guard record.state.isLoadable else {
                    return nil
                }

                return (record.id, record.manifest.capabilities)
            }
        )
    }

    /// Shares one fresh scan across host metadata projections without caching filesystem state.
    func installedMetadata() -> InstalledPluginMetadata {
        InstalledPluginMetadata(records: packageStore.installedRecords())
    }

    func installedPackageVersionsByID() -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: packageStore.installedRecords().map {
                ($0.id, $0.manifest.version)
            }
        )
    }

    func installedAtByID() -> [String: Date] {
        Dictionary(
            uniqueKeysWithValues: packageStore.installedRecords().map {
                ($0.id, $0.installedAt)
            }
        )
    }

    func installedCategoriesByID() -> [String: String?] {
        Dictionary(
            uniqueKeysWithValues: packageStore.installedRecords().map {
                ($0.id, $0.manifest.category)
            }
        )
    }

    func installedReleaseChannelsByID() -> [String: String?] {
        Dictionary(
            uniqueKeysWithValues: packageStore.installedRecords().map {
                ($0.id, $0.manifest.releaseChannel)
            }
        )
    }

    func installedManifestsByID() -> [String: PluginPackageManifest] {
        Dictionary(
            packageStore.installedRecords().map { ($0.id, $0.manifest) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    func uninstallPlugin(pluginID: String, removeData: Bool = false) throws {
        let wasLoaded = loadedPluginIDs.contains(pluginID)

        deactivateLoadedPlugins(pluginID: pluginID, reason: .uninstalling)
        do {
            try packageStore.uninstall(pluginID: pluginID, removeData: removeData)
            recordSuccessfulPackageMutation(pluginID: pluginID)
        } catch {
            // Package removal failed after its side effects were stopped. Reload
            // the still-installed package so the host returns to its previous
            // functional state instead of leaving a half-uninstalled plugin.
            reloadInstalledPlugins()
            throw error
        }
        loadedPluginsByID.removeValue(forKey: pluginID)

        if wasLoaded {
            deferredPluginIDs.insert(pluginID)
        }

        reloadInstalledPlugins()
    }

    func deactivateAll(reason: PluginDeactivationReason = .hostShutdown) {
        for pluginID in Array(loadedPluginsByID.keys) {
            deactivateLoadedPlugins(pluginID: pluginID, reason: reason)
        }
    }

    @discardableResult
    func rebuildManagementItems(catalogSnapshot: PluginCatalogSnapshot?) -> InstalledPluginMetadata {
        self.catalogSnapshot = catalogSnapshot
        let records = packageStore.installedRecords()
        let results = records.map { record in
            DynamicPluginLoadResult(
                record: deferredPluginIDs.contains(record.id) ? record.markingRestartRequired() : record,
                plugins: loadedPluginsByID[record.id] ?? [],
                errorMessage: latestLoadErrorsByID[record.id]
            )
        }
        rebuildManagementItems(results: results, catalogSnapshot: catalogSnapshot)
        return InstalledPluginMetadata(records: records)
    }

    func refreshLocalization() {
        rebuildManagementItems(results: managementResults, catalogSnapshot: catalogSnapshot)
    }

    private func deactivateMissingPlugins(records: [PluginPackageRecord]) {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })

        for pluginID in Array(loadedPluginsByID.keys) {
            guard let record = recordsByID[pluginID] else {
                deactivateLoadedPlugins(pluginID: pluginID, reason: .uninstalling)
                continue
            }

            if record.state != .installed {
                deactivateLoadedPlugins(pluginID: pluginID, reason: .disabled)
            }
        }
    }

    private func activePlugins(from records: [PluginPackageRecord]) -> [any MacToolsPlugin] {
        records.flatMap { record in
            loadedPluginsByID[record.id] ?? []
        }
    }

    private func deactivateLoadedPlugins(pluginID: String, reason: PluginDeactivationReason) {
        onPluginWillDeactivate?(pluginID, reason)
        guard let plugins = loadedPluginsByID.removeValue(forKey: pluginID) else {
            return
        }

        deactivatePluginInstances(plugins, reason: reason)
    }

    private func deactivatePluginInstances(
        _ plugins: [any MacToolsPlugin],
        reason: PluginDeactivationReason
    ) {
        for plugin in plugins {
            plugin.deactivate(reason: reason)
            plugin.onStateChange = nil
            plugin.requestPermissionGuidance = nil
            plugin.shortcutBindingResolver = nil
        }
    }

    private func validatePackage(_ sourceURL: URL, matches entry: PluginCatalogEntry?) throws {
        guard let entry else {
            return
        }

        let manifest = try PluginPackageManifestLoader.load(
            from: sourceURL,
            hostVersion: packageStore.hostVersion
        )

        guard manifest.id == entry.id else {
            throw PluginPackageResolverError.manifestMismatch(field: "id")
        }

        guard manifest.version == entry.version else {
            throw PluginPackageResolverError.manifestMismatch(field: "version")
        }

        guard manifest.minHostVersion == entry.minimumHostVersion else {
            throw PluginPackageResolverError.manifestMismatch(field: "minimumHostVersion")
        }

        guard manifest.pluginKitVersion == entry.pluginKitVersion else {
            throw PluginPackageResolverError.manifestMismatch(field: "pluginKitVersion")
        }

        guard manifest.releaseChannel == entry.releaseChannel else {
            throw PluginPackageResolverError.manifestMismatch(field: "releaseChannel")
        }
    }

    private func rebuildManagementItems(
        results: [DynamicPluginLoadResult],
        catalogSnapshot: PluginCatalogSnapshot?
    ) {
        managementResults = results
        let installedItems = Dictionary(uniqueKeysWithValues: results.map { ($0.record.id, $0) })
        let catalogEntries = catalogSnapshot?.catalog.plugins ?? []
        var itemIDs = Set<String>()
        var items: [PluginManagementItem] = []

        for entry in catalogEntries.sorted(by: catalogEntrySort) {
            itemIDs.insert(entry.id)
            let revocation = catalogSnapshot?.catalog.revoked.first {
                $0.matches(pluginID: entry.id, version: entry.version)
            }

            if let result = installedItems[entry.id] {
                let compatibleCatalogEntry = PluginVersionComparator.isVersion(
                    packageStore.hostVersion,
                    atLeast: entry.minimumHostVersion
                ) && requirementFailure(for: entry.requirements) == nil ? entry : nil
                items.append(
                    managementItem(
                        for: result,
                        catalogEntry: compatibleCatalogEntry,
                        revocation: revocation
                    )
                )
            } else {
                let state: PluginManagementItem.State
                if !PluginVersionComparator.isVersion(
                    packageStore.hostVersion,
                    atLeast: entry.minimumHostVersion
                ) {
                    state = .incompatible(
                        PluginPackageManifestError.incompatibleHostVersion(
                            required: entry.minimumHostVersion,
                            current: packageStore.hostVersion
                        ).localizedDescription
                    )
                } else if let failure = requirementFailure(for: entry.requirements) {
                    state = .incompatible(failure.localizedDescription)
                } else {
                    state = catalogSnapshot?.isLocalDevelopment == true
                        ? .localDevelopment
                        : .available
                }
                items.append(
                    PluginManagementItem(
                        id: entry.id,
                        title: entry.localizedDisplayName,
                        summary: entry.localizedSummary,
                        version: entry.version,
                        state: state,
                        packageURL: nil,
                        requiresRestartToFullyUnload: false,
                        releaseNotesURL: entry.releaseNotesURL,
                        category: entry.category,
                        releaseChannel: entry.releaseChannel,
                        capabilities: entry.capabilities,
                        uninstallDataPolicy: .preserve,
                        productMetadata: PluginProductMetadata(
                            presentation: entry.presentation,
                            discovery: entry.discovery,
                            requirements: entry.requirements,
                            privacy: entry.privacy,
                            actions: entry.actions,
                            setup: entry.setup,
                            relationships: entry.relationships
                        )
                    )
                )
            }
        }

        for result in results where !itemIDs.contains(result.record.id) {
            let revocation = catalogSnapshot?.catalog.revoked.first {
                $0.matches(pluginID: result.record.id, version: result.record.manifest.version)
            }
            items.append(
                managementItem(
                    for: result,
                    catalogEntry: nil,
                    revocation: revocation
                )
            )
        }

        pluginManagementItems = items.sorted(by: managementItemSort)
    }

    private func managementItem(
        for result: DynamicPluginLoadResult,
        catalogEntry: PluginCatalogEntry?,
        revocation: PluginCatalogRevocation?
    ) -> PluginManagementItem {
        let record = result.record
        let state: PluginManagementItem.State

        if let revocation {
            state = .revoked(revocation.reason)
        } else if record.requiresRestartToFullyUnload && record.state == .installed {
            state = .restartRequired
        } else if let errorMessage = result.errorMessage {
            state = .failed(errorMessage)
        } else if let catalogEntry,
                  PluginVersionComparator.isVersion(catalogEntry.version, newerThan: record.manifest.version) {
            state = .updateAvailable(
                installedVersion: record.manifest.version,
                catalogVersion: catalogEntry.version
            )
        } else {
            switch record.state {
            case .installed:
                state = .installed
            case let .incompatible(reason):
                state = .incompatible(reason)
            case let .failed(reason):
                state = .failed(reason)
            }
        }

        return PluginManagementItem(
            id: record.id,
            title: catalogEntry?.localizedDisplayName ?? record.manifest.localizedDisplayName,
            summary: catalogEntry?.localizedSummary ?? record.manifest.localizedSummary,
            version: catalogEntry?.version ?? record.manifest.version,
            state: state,
            packageURL: record.packageURL,
            requiresRestartToFullyUnload: record.requiresRestartToFullyUnload,
            releaseNotesURL: catalogEntry?.releaseNotesURL,
            category: catalogEntry?.category ?? record.manifest.category,
            releaseChannel: catalogEntry?.releaseChannel ?? record.manifest.releaseChannel,
            capabilities: catalogEntry?.capabilities ?? record.manifest.capabilities,
            uninstallDataPolicy: record.manifest.effectiveUninstallDataPolicy,
            productMetadata: PluginProductMetadata(
                presentation: catalogEntry?.presentation ?? record.manifest.presentation,
                discovery: catalogEntry?.discovery ?? record.manifest.discovery,
                requirements: catalogEntry?.requirements ?? record.manifest.requirements,
                privacy: catalogEntry?.privacy ?? record.manifest.privacy,
                actions: catalogEntry?.actions ?? record.manifest.actions,
                setup: catalogEntry?.setup ?? record.manifest.setup,
                relationships: catalogEntry?.relationships ?? record.manifest.relationships
            )
        )
    }

    private func catalogEntrySort(_ lhs: PluginCatalogEntry, _ rhs: PluginCatalogEntry) -> Bool {
        lhs.localizedDisplayName.localizedCompare(rhs.localizedDisplayName) == .orderedAscending
    }

    private func managementItemSort(_ lhs: PluginManagementItem, _ rhs: PluginManagementItem) -> Bool {
        lhs.title.localizedCompare(rhs.title) == .orderedAscending
    }
}

private enum DynamicPluginManagerOperationError: LocalizedError {
    case rollbackRequiresUnloadedPlugin(String)
    case pluginRecordNotFound(String)
    case pluginRuntimeValidationFailed(String, String)
    case featureExtractionCoordinatorRequired(String)

    var errorDescription: String? {
        switch self {
        case let .rollbackRequiresUnloadedPlugin(pluginID):
            AppL10n.pluginsFormat(
                "plugin.error.dynamic.rollbackRequiresUnloadedFormat",
                defaultValue: "无法回滚正在使用的插件包：%@",
                pluginID
            )
        case let .pluginRecordNotFound(pluginID):
            AppL10n.pluginsFormat(
                "plugin.error.dynamic.recordNotFoundFormat",
                defaultValue: "未找到已安装的插件记录：%@",
                pluginID
            )
        case let .pluginRuntimeValidationFailed(pluginID, reason):
            AppL10n.pluginsFormat(
                "plugin.error.dynamic.runtimeValidationFailedFormat",
                defaultValue: "插件 %@ 运行验证失败：%@",
                pluginID,
                reason
            )
        case let .featureExtractionCoordinatorRequired(pluginID):
            AppL10n.pluginsFormat(
                "plugin.error.dynamic.extractionCoordinatorRequiredFormat",
                defaultValue: "插件包变更需要由功能迁移协调器完成：%@",
                pluginID
            )
        }
    }
}

private extension PluginPackageRecord.State {
    var isLoadable: Bool {
        switch self {
        case .installed:
            return true
        case .incompatible, .failed:
            return false
        }
    }
}

private extension PluginPackageRecord {
    func markingRestartRequired() -> PluginPackageRecord {
        PluginPackageRecord(
            id: id,
            manifest: manifest,
            packageURL: packageURL,
            bundleURL: bundleURL,
            installedAt: installedAt,
            state: state,
            requiresRestartToFullyUnload: true
        )
    }
}
