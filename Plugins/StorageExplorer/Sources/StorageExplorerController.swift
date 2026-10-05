import AppKit
import Foundation
import MacToolsPluginKit
import SwiftUI

@MainActor
public final class StorageExplorerScanStatus: ObservableObject {
    @Published public var progress = StorageExplorerScanProgress()
}

public enum StorageExplorerReviewAvailability: Equatable, Sendable {
    case empty
    case scanning
    case cachedPreview
    case updating
    case executing
    case ready
}

@MainActor
public final class StorageExplorerController: ObservableObject {
    @Published public private(set) var scanState: StorageExplorerScanState = .idle
    @Published public private(set) var scanRootURL: URL?
    @Published public private(set) var currentPath: String?
    @Published public private(set) var navigationStack: [StorageItem] = []
    @Published public private(set) var basket: Set<String> = []
    @Published public var searchQuery = "" { didSet { refreshPresentation() } }
    @Published public var mode: StorageExplorerMode = .folders { didSet { selectedPath = nil; refreshPresentation() } }
    @Published public var metric: StorageExplorerMetric = .allocated { didSet { refreshPresentation() } }
    @Published public var selectedPath: String?
    @Published public var isConfirmingTrash = false
    @Published public private(set) var reviewItems: [StorageItem] = []
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var lastSuccessMessage: String?
    @Published public private(set) var isExecutingTrash = false
    @Published public private(set) var rows: [StorageExplorerRow] = []
    @Published public private(set) var chartRows: [StorageExplorerRow] = []
    @Published public private(set) var matchingCount = 0
    @Published public private(set) var displayedBytes: Int64 = 0
    @Published public private(set) var mapRootItems: [StorageItem] = []
    @Published private(set) var hierarchyNodes: [StorageExplorerHierarchyNode] = []
    @Published private(set) var hierarchyRevision = 0
    @Published public private(set) var isUpdatingPresentation = false
    @Published public private(set) var scanStartedAt: Date?
    @Published public private(set) var scanCompletedAt: Date?
    @Published public private(set) var isShowingCachedPreview = false
    @Published public private(set) var cachedPreviewDate: Date?
    public let status = StorageExplorerScanStatus()
    public let scanner: any StorageExplorerScanning
    public let safetyPolicy: StorageExplorerSafetyPolicy
    public private(set) var copy: StorageExplorerControllerCopy
    private enum TrashFailure {
        case operation
        case partial(count: Int, names: [String])
    }
    private var trashFailure: TrashFailure?
    private var isShowingTrashFailure = false
    private var trashFailureMessage: String? {
        switch trashFailure {
        case .operation:
            return copy.trashOperationFailed
        case let .partial(count, names):
            let formatter = ListFormatter()
            formatter.locale = PluginRuntimeLocalization.locale
            return String(
                format: copy.trashPartialFailure, locale: PluginRuntimeLocalization.locale,
                count, formatter.string(from: names) ?? names.joined(separator: ", ")
            )
        case nil:
            return nil
        }
    }
    public let snapshotCache: (any StorageExplorerSnapshotCaching)?

    private(set) var snapshot = StorageExplorerSnapshot(rootPath: "")
    private var activeScanTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var generation = UUID()
    private var presentationRevision = 0
    private var navigationRevision = 0
    private var sort: StorageExplorerSort = .size
    private var ascending = false
    private var cacheInvalidationTask: Task<Void, Never>?
    private var cachedPreviewTask: Task<Void, Never>?
    private var cacheSaveTask: Task<Void, Never>?
    private var snapshotCacheRootPath: String?
    private var pendingPresentationReadyRevision: Int?

    public init(scanner: any StorageExplorerScanning = StorageExplorerScanner(publishesItems: false),
                safetyPolicy: StorageExplorerSafetyPolicy = StorageExplorerSafetyPolicy(),
                copy: StorageExplorerControllerCopy = .fallback,
                snapshotCache: (any StorageExplorerSnapshotCaching)? = nil) {
        self.scanner = scanner
        self.safetyPolicy = safetyPolicy
        self.copy = copy
        self.snapshotCache = snapshotCache
    }

    deinit {
        activeScanTask?.cancel()
        presentationTask?.cancel()
        cachedPreviewTask?.cancel()
        cacheSaveTask?.cancel()
    }

    public var isScanning: Bool { if case .scanning = scanState { true } else { false } }
    public var rootItem: StorageItem? { snapshot.items[snapshot.rootPath] }
    public var currentDirectory: StorageItem? { currentPath.flatMap { snapshot.items[$0] } }
    public var inspectedItem: StorageItem? {
        guard let selectedPath else { return nil }
        return snapshot.items[selectedPath] ?? rows.first { $0.id == selectedPath }?.item
    }

    public func startScan(
        at url: URL,
        restoringBasket: Set<String> = [],
        completionError: String? = nil
    ) {
        guard !isExecutingTrash else { return }
        let previousBasket = basket
        cancelScan()
        let id = UUID()
        generation = id
        cachedPreviewTask?.cancel()
        cachedPreviewTask = nil
        let previousPath = currentPath
        let previousNavigationRevision = navigationRevision
        let sameRoot = url.path == scanRootURL?.path
        scanRootURL = url
        basket = sameRoot ? restoringBasket : []
        reviewItems = []
        isConfirmingTrash = false
        lastErrorMessage = nil
        lastSuccessMessage = nil
        trashFailure = nil
        isShowingTrashFailure = false
        isUpdatingPresentation = false
        pendingPresentationReadyRevision = nil
        if !sameRoot { scanCompletedAt = nil }
        // There is no continuous file monitor, so every explicit scan starts from fresh metadata.
        scheduleCacheReset()
        if !sameRoot {
            isShowingCachedPreview = false
            cachedPreviewDate = nil
            snapshot = StorageExplorerSnapshot(rootPath: url.path)
            currentPath = nil
            selectedPath = nil
            navigationStack = []
            rows = []; chartRows = []
            mapRootItems = []
            hierarchyNodes = []
            hierarchyRevision += 1
            matchingCount = 0
            displayedBytes = 0
            searchQuery = ""
            loadCachedPreview(for: url.path, generation: id)
        }
        status.progress = StorageExplorerScanProgress(currentPath: url.path)
        scanStartedAt = Date()
        scanState = .scanning(status.progress)
        if sameRoot, basket != previousBasket {
            rebuildRetainedPresentation()
        }
        activeScanTask = Task { [weak self, scanner] in
            do {
                if let invalidation = self?.cacheInvalidationTask {
                    await invalidation.value
                }
                guard self?.generation == id, !Task.isCancelled else { return }
                let result = try await scanner.scanSnapshot(rootURL: url) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id, self.isScanning else { return }
                        self.receive(update)
                    }
                }
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.snapshot = result
                self.status.progress = result.progress
                self.scanRootURL = URL(fileURLWithPath: result.rootPath)
                let preferredPath = self.navigationRevision == previousNavigationRevision ? previousPath : self.currentPath
                self.currentPath = preferredPath.flatMap { result.items[$0] == nil ? nil : $0 } ?? result.rootPath
                self.scanState = .completed
                self.scanStartedAt = nil
                let completedAt = Date()
                self.scanCompletedAt = completedAt
                self.isShowingCachedPreview = false
                self.cachedPreviewDate = nil
                self.basket = Set(restoringBasket.filter { result.items[$0] != nil })
                self.reviewItems = self.basket.sorted().compactMap { result.items[$0] }
                self.isShowingTrashFailure = self.trashFailure != nil
                self.lastErrorMessage = self.trashFailureMessage ?? completionError
                self.rebuildNavigation()
                self.refreshPresentation()
                self.saveSnapshotToCache(result, completedAt: completedAt, rootPath: url.path)
            } catch {
                guard let self, self.generation == id else { return }
                if error is CancellationError { self.scanState = .cancelled }
                else {
                    self.scanState = .failed(error.localizedDescription)
                    self.lastErrorMessage = error.localizedDescription
                }
                self.scanStartedAt = nil
                self.rebuildRetainedPresentation()
            }
        }
    }

    private func loadCachedPreview(for rootPath: String, generation id: UUID) {
        guard let snapshotCache else { return }
        cachedPreviewTask = Task { [weak self] in
            guard let cached = await snapshotCache.load(rootPath: rootPath),
                  !Task.isCancelled,
                  let self,
                  self.generation == id,
                  self.isScanning,
                  self.snapshot.items.isEmpty
            else { return }
            self.snapshot = cached.snapshot
            self.currentPath = cached.snapshot.rootPath
            self.isShowingCachedPreview = true
            self.cachedPreviewDate = cached.completedAt
            self.selectedPath = nil
            self.rebuildNavigation()
            self.refreshPresentation()
        }
    }

    private func saveSnapshotToCache(_ snapshot: StorageExplorerSnapshot, completedAt: Date, rootPath: String) {
        guard let snapshotCache else { return }
        snapshotCacheRootPath = rootPath
        let previous = cacheSaveTask
        cacheSaveTask = Task {
            // Serialize saves so an older scan cannot overwrite a snapshot adjusted after Trash.
            if let previous { await previous.value }
            guard !Task.isCancelled else { return }
            await snapshotCache.save(snapshot: snapshot, completedAt: completedAt, rootPath: rootPath)
        }
    }

    /// Releasing a full-disk cache can be expensive. Keep it off the main actor so starting a
    /// refresh never blocks treemap hover, clicks, or drag interactions.
    private func scheduleCacheReset() {
        let previous = cacheInvalidationTask
        let scanner = scanner
        cacheInvalidationTask = Task.detached(priority: .utility) {
            if let previous { await previous.value }
            scanner.clearCache()
        }
    }

    private func receive(_ update: StorageExplorerScanUpdate) {
        // Keep the visible result snapshot atomic. Progressive item updates are useful to the
        // scanner, but applying and re-presenting them on the main actor makes the workspace
        // jump while the user is waiting. The completed scan replaces the snapshot once.
        status.progress = update.progress
    }

    public func cancelScan() {
        let wasScanning = isScanning
        generation = UUID()
        activeScanTask?.cancel()
        activeScanTask = nil
        if wasScanning { scanState = .cancelled }
        scanStartedAt = nil
        if wasScanning { rebuildRetainedPresentation() }
    }

    public func selectFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        PluginPresentationSafety.prepareForWindowOrdering()
        if panel.runModal() == .OK, let url = panel.url { startScan(at: url) }
    }

    public func scanHomeFolder() { startScan(at: FileManager.default.homeDirectoryForCurrentUser) }
    public func drillDown(to item: StorageItem) {
        guard item.isDirectory && !item.isPackage, snapshot.items[item.path] != nil else { return }
        navigationRevision += 1
        currentPath = item.path
        selectedPath = nil
        rebuildNavigation()
        clearPresentationForNavigation()
        if mode == .folders {
            refreshPresentation()
        } else {
            mode = .folders
        }
    }
    public func navigateUp() {
        guard let parent = currentDirectory?.parentPath, let item = snapshot.items[parent] else { return }
        drillDown(to: item)
    }
    public func navigateToBreadcrumb(at index: Int) {
        guard navigationStack.indices.contains(index) else { return }
        drillDown(to: navigationStack[index])
    }
    private func rebuildNavigation() {
        var stack: [StorageItem] = []
        var path = currentPath
        while let current = path, let item = snapshot.items[current] { stack.append(item); path = item.parentPath }
        navigationStack = stack.reversed()
    }

    public func setSort(_ value: StorageExplorerSort, ascending: Bool) {
        sort = value
        self.ascending = ascending
        refreshPresentation()
    }

    func refreshLocalization(copy: StorageExplorerControllerCopy) {
        self.copy = copy
        if isShowingTrashFailure { lastErrorMessage = trashFailureMessage }
        if lastSuccessMessage != nil { lastSuccessMessage = copy.movedToTrash }
        rebuildRetainedPresentation()
    }

    private func refreshPresentation() {
        presentationRevision += 1
        schedulePresentation()
    }

    private func rebuildRetainedPresentation() {
        guard rootItem != nil else { return }
        beginPresentationUpdate()
        refreshPresentation()
    }

    private func schedulePresentation() {
        guard presentationTask == nil else { return }
        presentationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled else { return }
            let revision = self.presentationRevision
            let generation = self.generation
            let snapshot = self.snapshot, directory = self.currentPath ?? snapshot.rootPath
            let mode = self.mode, metric = self.metric, query = self.searchQuery, sort = self.sort, ascending = self.ascending
            let basket = self.basket, otherName = self.copy.otherName
            let locale = PluginRuntimeLocalization.locale
            let result = await Task.detached(priority: .userInitiated) {
                StorageExplorerPresentation.make(snapshot: snapshot, directory: directory, mode: mode,
                    metric: metric, query: query, sort: sort, ascending: ascending,
                    excluding: basket, otherName: otherName, locale: locale)
            }.value
            self.presentationTask = nil
            if revision == self.presentationRevision && generation == self.generation
                && directory == self.currentPath && mode == self.mode && metric == self.metric
                && query == self.searchQuery && sort == self.sort && ascending == self.ascending
                && basket == self.basket {
                self.rows = result.rows
                self.chartRows = result.chart
                self.mapRootItems = result.mapRootItems
                self.hierarchyNodes = result.hierarchy
                self.hierarchyRevision += 1
                if self.isUpdatingPresentation {
                    self.pendingPresentationReadyRevision = self.hierarchyRevision
                }
                self.matchingCount = result.matchingCount
                self.displayedBytes = result.total
            }
            if revision != self.presentationRevision { self.schedulePresentation() }
        }
    }

    private func clearPresentationForNavigation() {
        rows = []
        chartRows = []
        mapRootItems = []
        hierarchyNodes = []
        hierarchyRevision += 1
        matchingCount = 0
        displayedBytes = 0
    }

    public func canStage(_ item: StorageItem) -> Bool {
        !isShowingCachedPreview && !isScanning && !isExecutingTrash && !item.isSymlink
            && snapshot.items[item.path] != nil
            && safetyPolicy.validatePathForRemoval(item.path, withinRoot: snapshot.rootPath).isAllowed
    }

    public func reviewEligibility(for item: StorageItem) -> StorageExplorerReviewEligibility {
        if isShowingCachedPreview { return .cachedPreview }
        if isScanning || isExecutingTrash || isUpdatingPresentation { return .busy }
        if basket.contains(item.path) { return .selected }
        if let parentPath = basket.first(where: { item.path.hasPrefix($0 + "/") }) {
            return .includedBySelectedParent(name: snapshot.items[parentPath]?.name ?? URL(fileURLWithPath: parentPath).lastPathComponent)
        }
        if item.isSymlink { return .symlink }
        guard snapshot.items[item.path] != nil else { return .unavailable }
        if item.path == snapshot.rootPath { return .scanRoot }
        guard safetyPolicy.validatePathForRemoval(item.path, withinRoot: snapshot.rootPath).isAllowed else {
            return .protectedLocation
        }
        if item.isIncomplete { return .incomplete(skippedCount: max(1, item.skippedCount)) }
        return .eligible
    }

    public var reviewAvailability: StorageExplorerReviewAvailability {
        if basket.isEmpty { return .empty }
        if isExecutingTrash { return .executing }
        if isShowingCachedPreview { return .cachedPreview }
        if isScanning { return .scanning }
        if isUpdatingPresentation { return .updating }
        return .ready
    }
    public func toggleSelection(path: String) {
        if basket.contains(path) {
            beginPresentationUpdate()
            basket.remove(path)
            refreshPresentation()
            return
        }
        guard let item = snapshot.items[path], canStage(item) else { return }
        // A selected ancestor already includes this item; selecting an ancestor replaces descendants.
        guard !basket.contains(where: { path.hasPrefix($0 + "/") }) else { return }
        beginPresentationUpdate()
        basket = basket.filter { !$0.hasPrefix(path + "/") }
        basket.insert(path)
        refreshPresentation()
    }
    public func selectAllVisible(items: [StorageItem]) { for item in items { if !basket.contains(item.path) { toggleSelection(path: item.path) } } }
    public func clearSelection() {
        guard !basket.isEmpty else { return }
        beginPresentationUpdate()
        basket.removeAll()
        refreshPresentation()
    }

    public func presentationDidRender(revision: Int) {
        guard pendingPresentationReadyRevision == revision else { return }
        pendingPresentationReadyRevision = nil
        isUpdatingPresentation = false
    }

    private func beginPresentationUpdate() {
        isUpdatingPresentation = true
        pendingPresentationReadyRevision = nil
    }
    public var selectedItemsForReview: [StorageItem] { basket.sorted().compactMap { snapshot.items[$0] } }
    public var totalSelectedBytes: Int64 { selectedItemsForReview.reduce(0) { $0 + metric.bytes($1) } }

    public func revealInFinder(path: String) {
        guard snapshot.items[path] != nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    public func confirmTrash() {
        let items = selectedItemsForReview
        guard !items.isEmpty, items.allSatisfy(canStage) else { return }
        reviewItems = items
        isConfirmingTrash = true
    }
    public func executeTrash() async {
        guard !reviewItems.isEmpty, reviewItems.allSatisfy(canStage) else { isConfirmingTrash = false; return }
        let attemptedItems = reviewItems
        let root = snapshot.rootPath
        isExecutingTrash = true
        lastErrorMessage = nil
        lastSuccessMessage = nil
        trashFailure = nil
        isShowingTrashFailure = false
        do {
            let result = try await safetyPolicy.recycleItems(
                attemptedItems,
                withinRoot: root,
                rootIdentity: rootItem?.fileIdentity
            )
            let movedPaths = Set(result.moved.keys.map { $0.standardizedFileURL.path })
            let failedItems = attemptedItems.filter { !movedPaths.contains($0.url.standardizedFileURL.path) }
            if !movedPaths.isEmpty {
                let previousSnapshot = snapshot
                let adjusted = await Task.detached(priority: .userInitiated) {
                    var snapshot = previousSnapshot
                    snapshot.removeSubtrees(at: movedPaths)
                    return snapshot
                }.value
                // Navigation can change while Trash runs. Return to the closest surviving folder.
                var path = currentPath
                while let current = path, adjusted.items[current] == nil {
                    path = previousSnapshot.items[current]?.parentPath
                }
                snapshot = adjusted
                currentPath = path ?? root
                if let selectedPath, adjusted.items[selectedPath] == nil { self.selectedPath = nil }
                status.progress = adjusted.progress
                rebuildNavigation()
                if let completedAt = scanCompletedAt, let rootPath = snapshotCacheRootPath {
                    saveSnapshotToCache(adjusted, completedAt: completedAt, rootPath: rootPath)
                }
            }
            basket = Set(failedItems.map(\.path))
            reviewItems = failedItems
            isExecutingTrash = false
            isConfirmingTrash = false
            if failedItems.isEmpty {
                lastSuccessMessage = copy.movedToTrash
            } else {
                trashFailure = .partial(count: failedItems.count, names: failedItems.prefix(3).map(\.name))
                isShowingTrashFailure = true
                lastErrorMessage = trashFailureMessage
            }
            rebuildRetainedPresentation()
        } catch {
            isExecutingTrash = false
            isConfirmingTrash = false
            basket = Set(attemptedItems.map(\.path))
            reviewItems = attemptedItems
            trashFailure = .operation
            isShowingTrashFailure = true
            lastErrorMessage = trashFailureMessage
            rebuildRetainedPresentation()
        }
    }

}

public struct StorageExplorerControllerCopy: Sendable {
    public let movedToTrash: String
    public let trashOperationFailed: String
    public let trashPartialFailure: String
    public let otherName: String

    public init(
        movedToTrash: String,
        trashOperationFailed: String,
        trashPartialFailure: String,
        otherName: String = "其他"
    ) {
        self.movedToTrash = movedToTrash
        self.trashOperationFailed = trashOperationFailed
        self.trashPartialFailure = trashPartialFailure
        self.otherName = otherName
    }

    public static let fallback = StorageExplorerControllerCopy(
        movedToTrash: "已移至废纸篓",
        trashOperationFailed: "无法将所选项目移至废纸篓。请检查所选项目后重试。",
        trashPartialFailure: "%d 个项目未能移至废纸篓：%@",
        otherName: "其他"
    )
}
