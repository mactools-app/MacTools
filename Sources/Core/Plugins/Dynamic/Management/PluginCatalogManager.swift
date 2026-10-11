import Foundation

struct PluginCatalogStatus: Equatable {
    enum Source: Equatable {
        case production(URL)
        case localDevelopment(URL)
        case unavailable
    }

    var source: Source
    var lastUpdatedAt: Date?
    var errorMessage: String?
    var isRefreshing: Bool

    static let unavailable = PluginCatalogStatus(
        source: .unavailable,
        lastUpdatedAt: nil,
        errorMessage: nil,
        isRefreshing: false
    )

    var title: String {
        switch source {
        case .production:
            return AppL10n.plugins("plugin.catalog.title.production", defaultValue: "插件列表")
        case .localDevelopment:
            return AppL10n.plugins("plugin.catalog.title.localDevelopment", defaultValue: "本地开发列表")
        case .unavailable:
            return AppL10n.plugins("plugin.catalog.title.unavailable", defaultValue: "插件列表未配置")
        }
    }

    var detailText: String {
        if let errorMessage {
            return errorMessage
        }

        if isRefreshing {
            return AppL10n.plugins("plugin.catalog.detail.refreshing", defaultValue: "正在刷新插件列表...")
        }

        switch source {
        case let .production(url), let .localDevelopment(url):
            return url.absoluteString
        case .unavailable:
            return AppL10n.plugins("plugin.catalog.detail.unavailable", defaultValue: "已安装插件仍可继续管理。")
        }
    }
}

struct PluginCatalogBulkUpdateError: LocalizedError {
    let failures: [PluginPackageUpdateFailure]

    var errorDescription: String? {
        let ids = failures.map(\.pluginID).joined(separator: "、")
        return AppL10n.pluginsFormat("plugin.error.catalog.bulkUpdateFailedFormat", defaultValue: "部分插件更新失败：%@", ids)
    }
}

struct PluginCatalogUpdatePlan: Equatable {
    let updateableInstalledPluginIDs: [String]
    let migrationAffectedPluginIDs: [String]

    init(
        updateableInstalledPluginIDs: [String],
        migrationAffectedPluginIDs: [String] = []
    ) {
        self.updateableInstalledPluginIDs = updateableInstalledPluginIDs
        self.migrationAffectedPluginIDs = migrationAffectedPluginIDs
    }

    var affectedPluginIDs: [String] {
        Array(Set(updateableInstalledPluginIDs + migrationAffectedPluginIDs)).sorted()
    }

    var isEmpty: Bool {
        affectedPluginIDs.isEmpty
    }
}

struct PluginCatalogUpdateProgress: Equatable {
    let completedCount: Int
    let totalCount: Int

    init(completedCount: Int, totalCount: Int) {
        self.totalCount = max(0, totalCount)
        self.completedCount = min(max(0, completedCount), self.totalCount)
    }
}

private struct PendingPluginExtractionMigration {
    let rule: PluginExtractionMigrationPolicy
    let destinationEntry: PluginCatalogEntry?
    let sourceUpdateEntry: PluginCatalogEntry?
    let destinationNeedsInstall: Bool
    let destinationNeedsUpdate: Bool
    let sourceNeedsInstall: Bool

    var affectedPluginIDs: [String] {
        var ids: [String] = []
        if destinationNeedsInstall || destinationNeedsUpdate {
            ids.append(rule.destinationPluginID)
        }
        if sourceUpdateEntry != nil {
            ids.append(rule.sourcePluginID)
        }
        if ids.isEmpty {
            // A fully updated pair still requires journaled readiness validation and durable
            // completion. Represent that logical reconciliation as real migration work.
            ids = [rule.sourcePluginID, rule.destinationPluginID]
        }
        return ids
    }
}

@MainActor
final class PluginCatalogManager {
    private let catalogProvider: (any PluginCatalogProviding)?
    private let packageResolver: any PluginPackageResolving
    private let dynamicPluginManager: DynamicPluginManager
    private let source: PluginCatalogSource?
    private let extractionMigrationUserDefaults: UserDefaults?
    private let synchronizeExtractionMigrationDefaults: (UserDefaults) -> Bool

    private var snapshot: PluginCatalogSnapshot?
    private(set) var status: PluginCatalogStatus

    init(
        catalogProvider: (any PluginCatalogProviding)?,
        packageResolver: any PluginPackageResolving,
        dynamicPluginManager: DynamicPluginManager,
        source: PluginCatalogSource?,
        extractionMigrationUserDefaults: UserDefaults? = nil,
        synchronizeExtractionMigrationDefaults: @escaping (UserDefaults) -> Bool = {
            $0.synchronize()
        }
    ) {
        self.catalogProvider = catalogProvider
        self.packageResolver = packageResolver
        self.dynamicPluginManager = dynamicPluginManager
        self.source = source
        self.extractionMigrationUserDefaults = extractionMigrationUserDefaults
        self.synchronizeExtractionMigrationDefaults = synchronizeExtractionMigrationDefaults

        if let source {
            switch source {
            case let .production(url):
                self.status = PluginCatalogStatus(
                    source: .production(url),
                    lastUpdatedAt: nil,
                    errorMessage: nil,
                    isRefreshing: false
                )
            case let .localDevelopment(url):
                self.status = PluginCatalogStatus(
                    source: .localDevelopment(url),
                    lastUpdatedAt: nil,
                    errorMessage: nil,
                    isRefreshing: false
                )
            }
        } else {
            self.status = .unavailable
        }
    }

    static func live(dynamicPluginManager: DynamicPluginManager) -> PluginCatalogManager {
        let source = PluginCatalogProviderConfiguration.defaultSource()
        let provider = PluginCatalogProviderFactory.makeProvider(source: source)
        let resolver = PluginPackageResolver(
            temporaryDirectory: dynamicPluginManager.temporaryDirectory
        )

        return PluginCatalogManager(
            catalogProvider: provider,
            packageResolver: resolver,
            dynamicPluginManager: dynamicPluginManager,
            source: source,
            extractionMigrationUserDefaults: .standard
        )
    }

    @discardableResult
    func refreshCatalog() async -> InstalledPluginMetadata? {
        guard let catalogProvider else {
            status = .unavailable
            return nil
        }

        status.isRefreshing = true
        status.errorMessage = nil

        do {
            let snapshot = try await catalogProvider.loadCatalog()
            self.snapshot = snapshot
            status = PluginCatalogStatus(
                source: statusSource(for: snapshot),
                lastUpdatedAt: snapshot.loadedAt,
                errorMessage: nil,
                isRefreshing: false
            )
        } catch {
            status.isRefreshing = false
            status.errorMessage = error.localizedDescription
        }

        return dynamicPluginManager.rebuildManagementItems(catalogSnapshot: snapshot)
    }

    func installPlugin(id: String) async throws {
        let extractionRule = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        if id == extractionRule.destinationPluginID,
           extractionMigrationRequiresCoordinatedTransition() {
            guard pendingExtractionMigration(requiresLegacyPreference: false) != nil else {
                throw PluginCatalogManagerError.catalogEntryNotFound(extractionRule.sourcePluginID)
            }
            _ = try await performPendingExtractionMigration(
                reloadAfterMigration: true,
                requiresLegacyPreference: false
            )
            return
        }

        let entry = try compatibleCatalogEntry(id: id)
        let packageURL = try await packageResolver.resolvePackage(for: entry)
        try dynamicPluginManager.installPluginPackage(
            from: packageURL,
            catalogEntry: entry
        )
        if id == extractionRule.sourcePluginID || id == extractionRule.destinationPluginID {
            _ = try await performPendingExtractionMigration(
                reloadAfterMigration: true,
                requiresLegacyPreference: false
            )
        }
    }

    func updatePlugin(id: String) async throws {
        let extractionRule = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        if id == extractionRule.sourcePluginID {
            if pendingExtractionMigration() != nil {
                let migratedSourceIDs = try await performPendingExtractionMigration(
                    reloadAfterMigration: true
                )
                if migratedSourceIDs.contains(id) {
                    return
                }
            } else if let entry = usableCatalogEntry(id: id),
                      shouldDeferSourceUpdateForExtraction(
                          entry,
                          installedVersions: dynamicPluginManager.installedPackageVersionsByID()
                      ) {
                throw PluginCatalogManagerError.catalogEntryNotFound(
                    extractionRule.destinationPluginID
                )
            }
        }

        let entry = try compatibleCatalogEntry(id: id)
        let packageURL = try await packageResolver.resolvePackage(for: entry)
        guard dynamicPluginManager.isInstalledPlugin(id) else {
            return
        }

        try dynamicPluginManager.updatePluginPackage(
            from: packageURL,
            catalogEntry: entry,
            authorization: id == extractionRule.sourcePluginID
                ? .featureExtractionCoordinator
                : .standard
        )
    }

    func updateAvailablePlugins(
        progress: ((PluginCatalogUpdateProgress) -> Void)? = nil
    ) async throws {
        let migratedSourceIDs = try await performPendingExtractionMigration(
            reloadAfterMigration: true
        )
        let entries = try availableUpdateEntries().filter {
            !migratedSourceIDs.contains($0.id)
        }
        guard !entries.isEmpty else {
            return
        }

        try await updatePlugins(entries: entries, reloadAfterUpdate: true, progress: progress)
    }

    func automaticUpdatePlanForInstalledPlugins() -> PluginCatalogUpdatePlan {
        let entries = updateEntriesForInstalledPlugins()
        let migration = pendingExtractionMigration()
        return PluginCatalogUpdatePlan(
            updateableInstalledPluginIDs: entries.map(\.id),
            migrationAffectedPluginIDs: migration?.affectedPluginIDs ?? []
        )
    }

    var hasPendingExtractionMigrationResume: Bool {
        dynamicPluginManager.featureExtractionMigrationIsInProgress()
            || pendingExtractionMigration() != nil
    }

    func updateInstalledPluginsToLatestBeforeLoading(
        progress: ((PluginCatalogUpdateProgress) -> Void)? = nil
    ) async throws {
        let pendingMigration = pendingExtractionMigration()
        let migrationAffectedCount = pendingMigration?.affectedPluginIDs.count ?? 0
        let initialUpdateEntries = updateEntriesForInstalledPlugins()
        let plannedMigrationSourceID = pendingMigration?.sourceUpdateEntry?.id
        let remainingUpdateCount = initialUpdateEntries.filter {
            $0.id != plannedMigrationSourceID
        }.count
        let totalCount = migrationAffectedCount + remainingUpdateCount

        if migrationAffectedCount > 0 {
            progress?(PluginCatalogUpdateProgress(completedCount: 0, totalCount: totalCount))
            await Task.yield()
        }

        let migrationUpdatedPluginIDs = try await performPendingExtractionMigration()
        let entries = updateEntriesForInstalledPlugins().filter {
            !migrationUpdatedPluginIDs.contains($0.id)
        }
        guard !entries.isEmpty else {
            if migrationAffectedCount > 0 {
                progress?(
                    PluginCatalogUpdateProgress(
                        completedCount: migrationAffectedCount,
                        totalCount: totalCount
                    )
                )
            }
            return
        }

        try await updatePlugins(
            entries: entries,
            reloadAfterUpdate: false,
            progress: { updateProgress in
                progress?(
                    PluginCatalogUpdateProgress(
                        completedCount: migrationAffectedCount + updateProgress.completedCount,
                        totalCount: totalCount
                    )
                )
            }
        )
    }

    private func performPendingExtractionMigration(
        reloadAfterMigration: Bool = false,
        requiresLegacyPreference: Bool = true
    ) async throws -> Set<String> {
        guard let pending = pendingExtractionMigration(
            requiresLegacyPreference: requiresLegacyPreference
        ),
              let defaults = extractionMigrationUserDefaults
        else {
            return []
        }

        let participantVersionsBeforeResolution = dynamicPluginManager
            .installedPackageVersionsByID()
        let sourceMutationGenerationBeforeResolution = dynamicPluginManager
            .packageMutationGeneration(for: pending.rule.sourcePluginID)
        let destinationMutationGenerationBeforeResolution = dynamicPluginManager
            .packageMutationGeneration(for: pending.rule.destinationPluginID)
        let migrationWasAlreadyInProgress = dynamicPluginManager
            .featureExtractionMigrationIsInProgress()

        let destinationPackageURL: URL?
        if pending.destinationNeedsInstall || pending.destinationNeedsUpdate {
            guard let destinationEntry = pending.destinationEntry else {
                throw PluginCatalogManagerError.catalogEntryNotFound(pending.rule.destinationPluginID)
            }
            destinationPackageURL = try await packageResolver.resolvePackage(for: destinationEntry)
        } else {
            destinationPackageURL = nil
        }

        let sourceUpdatePackageURL: URL?
        if let sourceUpdateEntry = pending.sourceUpdateEntry {
            sourceUpdatePackageURL = try await packageResolver.resolvePackage(for: sourceUpdateEntry)
        } else {
            sourceUpdatePackageURL = nil
        }

        let participantVersionsAfterResolution = dynamicPluginManager
            .installedPackageVersionsByID()
        guard defaults.object(forKey: pending.rule.completionKey) == nil,
              participantVersionsAfterResolution[pending.rule.sourcePluginID]
                == participantVersionsBeforeResolution[pending.rule.sourcePluginID],
              participantVersionsAfterResolution[pending.rule.destinationPluginID]
                == participantVersionsBeforeResolution[pending.rule.destinationPluginID],
              dynamicPluginManager.packageMutationGeneration(
                  for: pending.rule.sourcePluginID
              ) == sourceMutationGenerationBeforeResolution,
              dynamicPluginManager.packageMutationGeneration(
                  for: pending.rule.destinationPluginID
              ) == destinationMutationGenerationBeforeResolution
        else {
            // Package resolution is an actor-reentrant suspension point. A user uninstall or
            // replacement of either participant during that interval wins over this stale plan.
            // Report cancellation instead of claiming those participants migrated successfully.
            throw PluginCatalogManagerError.migrationPlanInvalidated
        }

        let transactionJournalWasAlreadyPresent = defaults.bool(
            forKey: pending.rule.transactionJournalKey
        )
        defaults.set(true, forKey: pending.rule.transactionJournalKey)
        guard synchronizeExtractionMigrationDefaults(defaults) else {
            if !transactionJournalWasAlreadyPresent {
                defaults.removeObject(forKey: pending.rule.transactionJournalKey)
                _ = synchronizeExtractionMigrationDefaults(defaults)
            }
            throw PluginCatalogManagerError.migrationJournalPersistenceFailed
        }
        if migrationWasAlreadyInProgress {
            // Recovery always commits forward. Re-run the destination's idempotent preference
            // migration in case the previous process stopped during preflight or rollback.
            dynamicPluginManager.removePluginPreference(
                pluginID: pending.rule.destinationPluginID,
                key: pending.rule.destinationPreferenceMigrationMarkerKey
            )
        }

        let destinationPreferenceSnapshot = dynamicPluginManager.snapshotPluginPreferences(
            pluginID: pending.rule.destinationPluginID
        )
        let destinationWasLoaded = pending.destinationNeedsUpdate
            && dynamicPluginManager.isPluginLoaded(pending.rule.destinationPluginID)
        let suspendedSource = pending.sourceUpdateEntry.map {
            dynamicPluginManager.suspendLoadedPluginForMigration(pluginID: $0.id)
        } ?? false
        var installedDestination = false
        var destinationRollbackSnapshot: PluginPackageRollbackSnapshot?
        do {
            if let destinationPackageURL, let destinationEntry = pending.destinationEntry {
                if pending.destinationNeedsInstall {
                    try dynamicPluginManager.installPluginPackage(
                        from: destinationPackageURL,
                        catalogEntry: destinationEntry,
                        reloadAfterInstall: false,
                        authorization: .featureExtractionCoordinator
                    )
                    installedDestination = true
                } else {
                    if !destinationWasLoaded {
                        destinationRollbackSnapshot = try dynamicPluginManager.makeRollbackSnapshot(
                            pluginID: pending.rule.destinationPluginID
                        )
                    }
                    try dynamicPluginManager.updatePluginPackage(
                        from: destinationPackageURL,
                        catalogEntry: destinationEntry,
                        reloadAfterUpdate: false,
                        authorization: .featureExtractionCoordinator
                    )
                }
            }

            if destinationWasLoaded {
                // Native bundles already admitted to the process cannot prove the replacement
                // binary is active. Stage the compatible package and finish after restart.
                dynamicPluginManager.restoreSuspendedPluginAfterMigrationFailure(
                    pluginID: pending.rule.sourcePluginID,
                    wasSuspended: suspendedSource
                )
                return pending.sourceUpdateEntry.map { [$0.id] } ?? []
            }

            try dynamicPluginManager.validatePluginInstallationBeforeMigration(
                pluginID: pending.rule.destinationPluginID
            )

            if let sourceUpdatePackageURL, let sourceUpdateEntry = pending.sourceUpdateEntry {
                if pending.sourceNeedsInstall {
                    try dynamicPluginManager.installPluginPackage(
                        from: sourceUpdatePackageURL,
                        catalogEntry: sourceUpdateEntry,
                        reloadAfterInstall: false,
                        authorization: .featureExtractionCoordinator
                    )
                } else {
                    try dynamicPluginManager.updatePluginPackage(
                        from: sourceUpdatePackageURL,
                        catalogEntry: sourceUpdateEntry,
                        reloadAfterUpdate: false,
                        authorization: .featureExtractionCoordinator
                    )
                }
            }
        } catch {
            var migrationError = error
            var canRestoreSuspendedSource = true
            dynamicPluginManager.restorePluginPreferences(
                destinationPreferenceSnapshot,
                pluginID: pending.rule.destinationPluginID
            )
            if let destinationRollbackSnapshot {
                do {
                    try dynamicPluginManager.restoreRollbackSnapshot(destinationRollbackSnapshot)
                    dynamicPluginManager.discardRollbackSnapshot(destinationRollbackSnapshot)
                } catch let rollbackError {
                    canRestoreSuspendedSource = false
                    migrationError = PluginExtractionMigrationError(
                        migrationID: pending.rule.id,
                        primaryError: error,
                        rollbackError: rollbackError
                    )
                }
            } else if installedDestination {
                do {
                    try dynamicPluginManager.rollbackUnloadedPluginInstallation(
                        pluginID: pending.rule.destinationPluginID
                    )
                } catch let rollbackError {
                    canRestoreSuspendedSource = false
                    migrationError = PluginExtractionMigrationError(
                        migrationID: pending.rule.id,
                        primaryError: error,
                        rollbackError: rollbackError
                    )
                }
            }
            let rolledBackVersions = dynamicPluginManager.installedPackageVersionsByID()
            let completedRollbackToSourceOnly = canRestoreSuspendedSource
                && rolledBackVersions[pending.rule.destinationPluginID] == nil
                && rolledBackVersions[pending.rule.sourcePluginID].map {
                    !PluginVersionComparator.isVersion(
                        $0,
                        atLeast: pending.rule.sourceRetirementVersion
                    )
                } == true
            if completedRollbackToSourceOnly {
                defaults.removeObject(forKey: pending.rule.transactionJournalKey)
                _ = synchronizeExtractionMigrationDefaults(defaults)
            }
            if canRestoreSuspendedSource {
                dynamicPluginManager.restoreSuspendedPluginAfterMigrationFailure(
                    pluginID: pending.rule.sourcePluginID,
                    wasSuspended: suspendedSource
                )
            }
            throw migrationError
        }

        if let destinationRollbackSnapshot {
            dynamicPluginManager.discardRollbackSnapshot(destinationRollbackSnapshot)
        }

        guard persistExtractionMigrationCompletion(pending.rule, defaults: defaults) else {
            throw PluginCatalogManagerError.migrationCompletionPersistenceFailed
        }
        if reloadAfterMigration {
            dynamicPluginManager.reloadInstalledPlugins()
        }
        if let sourceUpdateEntry = pending.sourceUpdateEntry {
            return [sourceUpdateEntry.id]
        }
        return []
    }

    private func updatePlugins(
        entries: [PluginCatalogEntry],
        reloadAfterUpdate: Bool,
        progress: ((PluginCatalogUpdateProgress) -> Void)? = nil
    ) async throws {
        var resolvedUpdates: [(sourceURL: URL, catalogEntry: PluginCatalogEntry)] = []
        var failures: [PluginPackageUpdateFailure] = []
        let totalCount = entries.count
        var completedCount = 0

        func reportProgress() {
            progress?(
                PluginCatalogUpdateProgress(
                    completedCount: completedCount,
                    totalCount: totalCount
                )
            )
        }

        reportProgress()
        await Task.yield()

        for entry in entries {
            do {
                let packageURL = try await packageResolver.resolvePackage(for: entry)
                resolvedUpdates.append((sourceURL: packageURL, catalogEntry: entry))
            } catch {
                failures.append(PluginPackageUpdateFailure(pluginID: entry.id, error: error))
                completedCount += 1
                reportProgress()
                await Task.yield()
            }
        }

        failures.append(
            contentsOf: await dynamicPluginManager.updatePluginPackages(
                resolvedUpdates,
                reloadAfterUpdate: reloadAfterUpdate,
                featureExtractionAuthorizedPluginIDs: [
                    PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick.sourcePluginID,
                ],
                onPackageProcessed: {
                    completedCount += 1
                    reportProgress()
                }
            )
        )

        guard failures.isEmpty else {
            throw PluginCatalogBulkUpdateError(failures: failures)
        }
    }

    func rebuildManagementItems() {
        dynamicPluginManager.rebuildManagementItems(catalogSnapshot: snapshot)
    }

    private func pendingExtractionMigration(
        requiresLegacyPreference: Bool = true
    ) -> PendingPluginExtractionMigration? {
        let rule = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        guard let defaults = extractionMigrationUserDefaults,
              defaults.object(forKey: rule.completionKey) == nil,
              !dynamicPluginManager.featureExtractionSourceUninstallIsPending()
        else {
            return nil
        }
        let transactionIsInProgress = dynamicPluginManager
            .featureExtractionMigrationIsInProgress()
        if requiresLegacyPreference,
           !transactionIsInProgress,
           defaults.object(forKey: rule.legacyPreferenceKey) == nil {
            return nil
        }

        let installedVersions = dynamicPluginManager.installedPackageVersionsByID()
        let sourceVersion = installedVersions[rule.sourcePluginID]
        let sourceNeedsInstall = sourceVersion == nil
        guard !sourceNeedsInstall || transactionIsInProgress else {
            return nil
        }

        let installedDestinationVersion = installedVersions[rule.destinationPluginID]
        let destinationNeedsInstall = installedDestinationVersion == nil
        let destinationNeedsUpdate = installedDestinationVersion.map {
            !extractionDestinationVersionIsCompatible($0)
        } ?? false
        let destinationEntry: PluginCatalogEntry?
        if destinationNeedsInstall || destinationNeedsUpdate {
            guard let availableDestination = usableCatalogEntry(id: rule.destinationPluginID),
                  PluginVersionComparator.isVersion(
                      availableDestination.version,
                      atLeast: rule.minimumDestinationVersion
                  ),
                  installedDestinationVersion.map({
                      PluginVersionComparator.isVersion(
                          availableDestination.version,
                          newerThan: $0
                      )
                  }) ?? true
            else {
                return nil
            }
            destinationEntry = availableDestination
        } else {
            destinationEntry = nil
        }

        let sourceUpdateEntry: PluginCatalogEntry?
        if let sourceVersion,
           PluginVersionComparator.isVersion(sourceVersion, atLeast: rule.sourceRetirementVersion) {
            sourceUpdateEntry = nil
        } else {
            guard let availableSourceUpdate = usableCatalogEntry(id: rule.sourcePluginID),
                  PluginVersionComparator.isVersion(
                      availableSourceUpdate.version,
                      atLeast: rule.sourceRetirementVersion
                  ),
                  sourceVersion.map({
                      PluginVersionComparator.isVersion(
                          availableSourceUpdate.version,
                          newerThan: $0
                      )
                  }) ?? true
            else {
                // Keep the old source package intact until its replacement package and the
                // source version that retires the behavior can be migrated as one operation.
                return nil
            }
            sourceUpdateEntry = availableSourceUpdate
        }

        return PendingPluginExtractionMigration(
            rule: rule,
            destinationEntry: destinationEntry,
            sourceUpdateEntry: sourceUpdateEntry,
            destinationNeedsInstall: destinationNeedsInstall,
            destinationNeedsUpdate: destinationNeedsUpdate,
            sourceNeedsInstall: sourceNeedsInstall
        )
    }

    private func extractionMigrationRequiresCoordinatedTransition() -> Bool {
        let rule = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        guard let defaults = extractionMigrationUserDefaults,
              defaults.object(forKey: rule.completionKey) == nil
        else {
            return false
        }

        let installedVersions = dynamicPluginManager.installedPackageVersionsByID()
        guard let sourceVersion = installedVersions[rule.sourcePluginID]
        else {
            return false
        }
        let destinationIsCompatible = installedVersions[rule.destinationPluginID].map {
            extractionDestinationVersionIsCompatible($0)
        } ?? false
        return !destinationIsCompatible && !PluginVersionComparator.isVersion(
            sourceVersion,
            atLeast: rule.sourceRetirementVersion
        )
    }

    private func extractionDestinationVersionIsCompatible(_ version: String) -> Bool {
        let rule = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        return PluginVersionComparator.isVersion(version, atLeast: rule.minimumDestinationVersion)
            && PluginPackageManifestLoader.pluginVersionFailure(
                id: rule.destinationPluginID, version: version, hostVersion: dynamicPluginManager.hostVersion
            ) == nil
    }

    private func persistExtractionMigrationCompletion(
        _ rule: PluginExtractionMigrationPolicy,
        defaults: UserDefaults
    ) -> Bool {
        let completionWasAlreadyPresent = defaults.bool(forKey: rule.completionKey)
        defaults.set(true, forKey: rule.completionKey)

        // Keep the write-ahead journal until completion itself is durable. If this write fails,
        // restore an uncommitted in-memory view so recovery remains eligible in this process.
        guard synchronizeExtractionMigrationDefaults(defaults) else {
            if !completionWasAlreadyPresent {
                defaults.removeObject(forKey: rule.completionKey)
                _ = synchronizeExtractionMigrationDefaults(defaults)
            }
            return false
        }

        // A failure here can leave completion + journal on disk. PluginPackageStore reconciles
        // that explicitly safe crash state during initialization and before journal checks.
        defaults.removeObject(forKey: rule.transactionJournalKey)
        _ = synchronizeExtractionMigrationDefaults(defaults)
        return true
    }

    private func usableCatalogEntry(id: String) -> PluginCatalogEntry? {
        guard let entry = snapshot?.catalog.plugins.first(where: { $0.id == id }),
              isCompatibleWithCurrentHost(entry),
              snapshot?.catalog.revoked.contains(where: {
                  $0.matches(pluginID: entry.id, version: entry.version)
              }) != true
        else {
            return nil
        }
        return entry
    }

    private func catalogEntry(id: String) throws -> PluginCatalogEntry {
        guard let entry = snapshot?.catalog.plugins.first(where: { $0.id == id }) else {
            throw PluginCatalogManagerError.catalogEntryNotFound(id)
        }

        return entry
    }

    private func availableUpdateEntries() throws -> [PluginCatalogEntry] {
        let ids = dynamicPluginManager.pluginManagementItems
            .filter(\.canUpdate)
            .map(\.id)
        guard !ids.isEmpty else {
            return []
        }

        let entriesByID = Dictionary(
            uniqueKeysWithValues: (snapshot?.catalog.plugins ?? []).map { ($0.id, $0) }
        )

        let installedVersions = dynamicPluginManager.installedPackageVersionsByID()
        return try ids.compactMap { id in
            guard let entry = entriesByID[id] else {
                throw PluginCatalogManagerError.catalogEntryNotFound(id)
            }

            guard isCompatibleWithCurrentHost(entry) else { return nil }
            return shouldDeferSourceUpdateForExtraction(
                entry,
                installedVersions: installedVersions
            ) ? nil : entry
        }
    }

    private func updateEntriesForInstalledPlugins() -> [PluginCatalogEntry] {
        let installedVersionsByID = dynamicPluginManager.installedPackageVersionsByID()

        return (snapshot?.catalog.plugins ?? []).filter { entry in
            guard isCompatibleWithCurrentHost(entry) else { return false }
            guard let installedVersion = installedVersionsByID[entry.id] else {
                return false
            }

            if snapshot?.catalog.revoked.contains(where: {
                $0.matches(pluginID: entry.id, version: entry.version)
            }) == true {
                return false
            }

            if shouldDeferSourceUpdateForExtraction(entry, installedVersions: installedVersionsByID) {
                return false
            }

            return PluginVersionComparator.isVersion(entry.version, newerThan: installedVersion)
        }
    }

    private func compatibleCatalogEntry(id: String) throws -> PluginCatalogEntry {
        let entry = try catalogEntry(id: id)
        guard PluginVersionComparator.isVersion(dynamicPluginManager.hostVersion, atLeast: entry.minimumHostVersion) else {
            throw PluginPackageManifestError.incompatibleHostVersion(
                required: entry.minimumHostVersion,
                current: dynamicPluginManager.hostVersion
            )
        }
        if let failure = PluginPackageManifestLoader.pluginVersionFailure(
            id: entry.id, version: entry.version, hostVersion: dynamicPluginManager.hostVersion
        ) { throw failure }
        if let failure = dynamicPluginManager.requirementFailure(for: entry.requirements) { throw failure }
        return entry
    }

    private func isCompatibleWithCurrentHost(_ entry: PluginCatalogEntry) -> Bool {
        PluginVersionComparator.isVersion(
            dynamicPluginManager.hostVersion,
            atLeast: entry.minimumHostVersion
        ) && PluginPackageManifestLoader.pluginVersionFailure(
            id: entry.id, version: entry.version, hostVersion: dynamicPluginManager.hostVersion
        ) == nil && dynamicPluginManager.requirementFailure(for: entry.requirements) == nil
    }

    private func shouldDeferSourceUpdateForExtraction(
        _ entry: PluginCatalogEntry,
        installedVersions: [String: String]
    ) -> Bool {
        let rule = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        guard entry.id == rule.sourcePluginID,
              PluginVersionComparator.isVersion(entry.version, atLeast: rule.sourceRetirementVersion),
              let defaults = extractionMigrationUserDefaults,
              defaults.object(forKey: rule.completionKey) == nil,
              defaults.object(forKey: rule.legacyPreferenceKey) != nil
        else {
            return false
        }

        let destinationIsCompatible = installedVersions[rule.destinationPluginID].map {
            extractionDestinationVersionIsCompatible($0)
        } ?? false
        guard !destinationIsCompatible else { return false }
        guard let destinationEntry = usableCatalogEntry(id: rule.destinationPluginID) else {
            return true
        }
        return !PluginVersionComparator.isVersion(
            destinationEntry.version,
            atLeast: rule.minimumDestinationVersion
        )
    }

    private func statusSource(for snapshot: PluginCatalogSnapshot) -> PluginCatalogStatus.Source {
        switch snapshot.sourceKind {
        case .production:
            return .production(snapshot.sourceURL)
        case .localDevelopment:
            return .localDevelopment(snapshot.sourceURL)
        }
    }
}

enum PluginCatalogManagerError: LocalizedError, Equatable {
    case catalogEntryNotFound(String)
    case migrationPlanInvalidated
    case migrationJournalPersistenceFailed
    case migrationCompletionPersistenceFailed

    var errorDescription: String? {
        switch self {
        case let .catalogEntryNotFound(id):
            return AppL10n.pluginsFormat("plugin.error.catalog.entryNotFoundFormat", defaultValue: "插件列表中未找到插件：%@", id)
        case .migrationPlanInvalidated:
            return AppL10n.plugins(
                "plugin.error.catalog.migrationPlanInvalidated",
                defaultValue: "插件状态已更改，请重试更新。"
            )
        case .migrationJournalPersistenceFailed:
            return AppL10n.plugins(
                "plugin.error.catalog.migrationJournalPersistenceFailed",
                defaultValue: "无法保存插件迁移状态，未执行更新。"
            )
        case .migrationCompletionPersistenceFailed:
            return AppL10n.plugins(
                "plugin.error.catalog.migrationCompletionPersistenceFailed",
                defaultValue: "插件已更新，但无法保存迁移完成状态；下次启动时将继续恢复。"
            )
        }
    }
}

private struct PluginExtractionMigrationError: LocalizedError {
    let migrationID: String
    let primaryError: Error
    let rollbackError: Error

    var errorDescription: String? {
        AppL10n.pluginsFormat(
            "plugin.error.catalog.extractionRollbackFailedFormat",
            defaultValue: "插件功能迁移 %@ 失败：%@；回滚也失败：%@",
            migrationID,
            primaryError.localizedDescription,
            rollbackError.localizedDescription
        )
    }
}
