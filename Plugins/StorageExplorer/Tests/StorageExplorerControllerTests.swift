import Darwin
import Foundation
import MacToolsPluginKit
import XCTest
@testable import StorageExplorerPlugin

@MainActor
final class StorageExplorerControllerTests: XCTestCase {
    func testLanguageChangeRebuildsRetainedPresentationWithoutScanningOrChangingSelection() async throws {
        let originalPreference = UserDefaults.standard.string(forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey)
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        PluginRuntimeLocalization.source.setPreference("en")
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let root = "/tmp/storage-localization"
        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        scanner.finish(path: root, snapshot: Self.fixture(root: root))
        try await waitUntil { !controller.rows.isEmpty }
        controller.toggleSelection(path: root + "/a")
        try await waitUntil { controller.hierarchyNodes.map(\.id) == [root + "/b"] }
        let rows = controller.rows
        let selection = controller.basket
        let revision = controller.hierarchyRevision

        PluginRuntimeLocalization.source.setPreference("fr")
        controller.refreshLocalization(copy: controller.copy)
        try await waitUntil { controller.hierarchyRevision > revision }

        XCTAssertEqual(scanner.scanCount, 1)
        XCTAssertEqual(controller.scanRootURL?.path, root)
        XCTAssertEqual(controller.basket, selection)
        XCTAssertEqual(controller.rows.map(\.bytes), rows.map(\.bytes))
        XCTAssertNotEqual(controller.rows.map(\.sizeLabel), rows.map(\.sizeLabel))
    }

    func testObsoleteProgressAndFailureCannotReplaceNewScan() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let first = URL(fileURLWithPath: "/tmp/storage-first")
        let second = URL(fileURLWithPath: "/tmp/storage-second")
        controller.startScan(at: first)
        try await waitUntil { scanner.hasRequest(first.path) }
        controller.startScan(at: second)
        try await waitUntil { scanner.hasRequest(second.path) }
        scanner.emit(path: first.path, size: 900)
        scanner.finish(path: first.path, error: CancellationError())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(controller.isScanning)
        XCTAssertEqual(controller.scanRootURL, second)
        XCTAssertEqual(controller.status.progress.bytesScanned, 0)
        scanner.finish(path: second.path)
        try await waitUntil { !controller.isScanning }
        XCTAssertEqual(controller.rootItem?.path, second.path)
        XCTAssertEqual(controller.scanState, .completed)
    }

    func testSelectionTotalsSpanFoldersAndNormalizeAncestorOverlap() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let root = URL(fileURLWithPath: "/tmp/storage-selection")
        controller.startScan(at: root)
        try await waitUntil { scanner.hasRequest(root.path) }
        let snapshot = Self.fixture(root: root.path)
        scanner.finish(path: root.path, snapshot: snapshot)
        try await waitUntil { !controller.isScanning }
        controller.toggleSelection(path: root.path + "/a/one")
        controller.drillDown(to: try XCTUnwrap(snapshot.items[root.path + "/b"]))
        controller.toggleSelection(path: root.path + "/b/two")
        XCTAssertEqual(controller.totalSelectedBytes, 600)
        XCTAssertEqual(controller.selectedItemsForReview.count, 2)
        controller.toggleSelection(path: root.path + "/a")
        XCTAssertFalse(controller.basket.contains(root.path + "/a/one"))
        XCTAssertEqual(controller.totalSelectedBytes, 600)
        controller.toggleSelection(path: root.path + "/a/one")
        XCTAssertEqual(controller.basket.count, 2)
    }

    func testBackgroundHierarchyTracksLatestSelectionAndNavigation() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let root = "/tmp/storage-hierarchy"
        let snapshot = Self.fixture(root: root)
        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        scanner.finish(path: root, snapshot: snapshot)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.hierarchyNodes.map(\.id) == [root + "/b", root + "/a"] }

        controller.toggleSelection(path: root + "/b")
        XCTAssertTrue(controller.isUpdatingPresentation)
        try await waitUntil { controller.hierarchyNodes.map(\.id) == [root + "/a"] }
        XCTAssertTrue(controller.isUpdatingPresentation)
        controller.presentationDidRender(revision: controller.hierarchyRevision)
        XCTAssertFalse(controller.isUpdatingPresentation)

        controller.drillDown(to: try XCTUnwrap(snapshot.items[root + "/a"]))
        XCTAssertTrue(controller.hierarchyNodes.isEmpty)
        try await waitUntil { controller.hierarchyNodes.map(\.id) == [root + "/a/one"] }
        XCTAssertEqual(controller.currentPath, root + "/a")
    }

    func testRapidRepeatedStagingPublishesOnlyLatestHierarchy() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let root = "/tmp/storage-repeated-staging"
        let snapshot = Self.fixture(root: root)
        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        scanner.finish(path: root, snapshot: snapshot)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.hierarchyNodes.count == 2 }

        controller.toggleSelection(path: root + "/b")
        controller.toggleSelection(path: root + "/a")

        try await waitUntil { controller.hierarchyNodes.isEmpty }
        XCTAssertEqual(controller.basket, [root + "/a", root + "/b"])
    }

    func testSameDirectoryRefreshKeepsPreviousHierarchyUntilReplacementPublishes() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let root = "/tmp/storage-hierarchy-refresh"
        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        scanner.finish(path: root, snapshot: Self.fixture(root: root))
        try await waitUntil { !controller.isScanning }
        try await waitUntil { !controller.hierarchyNodes.isEmpty }
        let previousHierarchy = controller.hierarchyNodes

        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        XCTAssertEqual(controller.hierarchyNodes, previousHierarchy)

        var replacement = StorageExplorerSnapshot(rootPath: root)
        replacement.apply([
            StorageItem(
                name: "storage-hierarchy-refresh",
                path: root,
                url: URL(fileURLWithPath: root),
                isDirectory: true,
                size: 400,
                allocatedSize: 400
            ),
            StorageItem(
                name: "replacement",
                path: root + "/replacement",
                url: URL(fileURLWithPath: root + "/replacement"),
                isDirectory: false,
                size: 400,
                allocatedSize: 400,
                parentPath: root
            )
        ])
        scanner.finish(path: root, snapshot: replacement)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.hierarchyNodes.map(\.id) == [root + "/replacement"] }
    }

    func testCancelledRescanRebuildsRetainedHierarchyAfterClearingBasket() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let root = "/tmp/storage-cancelled-refresh"
        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        scanner.finish(path: root, snapshot: Self.fixture(root: root))
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.hierarchyNodes.map(\.id) == [root + "/b", root + "/a"] }

        controller.toggleSelection(path: root + "/b")
        try await waitUntil { controller.hierarchyNodes.map(\.id) == [root + "/a"] }

        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        XCTAssertTrue(controller.basket.isEmpty)
        controller.cancelScan()
        scanner.finish(path: root, error: CancellationError())

        try await waitUntil { controller.hierarchyNodes.map(\.id) == [root + "/b", root + "/a"] }
        XCTAssertEqual(controller.scanState, .cancelled)
    }

    func testFailedRescanRebuildsRetainedHierarchyAfterClearingBasket() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let root = "/tmp/storage-failed-refresh"
        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        scanner.finish(path: root, snapshot: Self.fixture(root: root))
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.hierarchyNodes.map(\.id) == [root + "/b", root + "/a"] }

        controller.toggleSelection(path: root + "/b")
        try await waitUntil { controller.hierarchyNodes.map(\.id) == [root + "/a"] }

        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        XCTAssertTrue(controller.basket.isEmpty)
        scanner.finish(
            path: root,
            error: NSError(domain: "StorageExplorerControllerTests", code: 1)
        )

        try await waitUntil { controller.hierarchyNodes.map(\.id) == [root + "/b", root + "/a"] }
        XCTAssertFalse(controller.isScanning)
        if case .failed = controller.scanState {} else {
            XCTFail("Expected failed scan state")
        }
    }

    func testPartialResultsUpdateProgressWithoutReplacingVisibleSnapshot() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let path = "/tmp/storage-partial"
        controller.startScan(at: URL(fileURLWithPath: path))
        try await waitUntil { scanner.hasRequest(path) }
        scanner.emit(path: path, size: 100)
        try await waitUntil { controller.status.progress.bytesScanned == 100 }
        XCTAssertTrue(controller.isScanning)
        XCTAssertNil(controller.rootItem)
        controller.toggleSelection(path: path)
        XCTAssertTrue(controller.basket.isEmpty)
        controller.cancelScan()
        scanner.finish(path: path)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.scanState, .cancelled)
    }

    func testSwitchingRootsClearsOldResultsAndSelectionImmediately() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let first = "/tmp/storage-old", second = "/tmp/storage-new"
        controller.startScan(at: URL(fileURLWithPath: first))
        try await waitUntil { scanner.hasRequest(first) }
        scanner.finish(path: first, snapshot: Self.fixture(root: first))
        try await waitUntil { !controller.isScanning }
        controller.toggleSelection(path: first + "/a")
        controller.startScan(at: URL(fileURLWithPath: second))
        XCTAssertNil(controller.currentDirectory)
        XCTAssertTrue(controller.basket.isEmpty)
        try await waitUntil { scanner.hasRequest(second) }
        scanner.finish(path: second)
        try await waitUntil { !controller.isScanning }
    }

    func testExistingNavigationSurvivesAtomicRefreshCompletion() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let path = "/tmp/storage-navigation"
        let snapshot = Self.fixture(root: path)
        controller.startScan(at: URL(fileURLWithPath: path))
        try await waitUntil { scanner.hasRequest(path) }
        scanner.finish(path: path, snapshot: snapshot)
        try await waitUntil { !controller.isScanning }
        controller.drillDown(to: try XCTUnwrap(snapshot.items[path + "/b"]))

        controller.startScan(at: URL(fileURLWithPath: path))
        try await waitUntil { scanner.hasRequest(path) }
        scanner.emitSnapshot(path: path, snapshot: snapshot)
        XCTAssertEqual(controller.currentPath, path + "/b")
        scanner.finish(path: path, snapshot: snapshot)
        try await waitUntil { !controller.isScanning }
        XCTAssertEqual(controller.currentPath, path + "/b")
    }

    func testExplicitRefreshAlwaysReadsFreshMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.bin")
        try Data(repeating: 1, count: 10).write(to: file)
        let controller = StorageExplorerController()
        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        XCTAssertEqual(controller.rootItem?.size, 10)
        try Data(repeating: 2, count: 400).write(to: file)
        controller.startScan(at: try XCTUnwrap(controller.scanRootURL))
        try await waitUntil { !controller.isScanning }
        XCTAssertEqual(controller.rootItem?.size, 400)
    }

    func testCachedPreviewAppearsUntilFreshScanCompletesAndCannotBeReviewed() async throws {
        let scanner = ControlledStorageScanner()
        let root = "/tmp/storage-cached-preview"
        let cached = Self.fixture(root: root)
        let cache = ControlledStorageSnapshotCache(
            cached: StorageExplorerCachedSnapshot(
                snapshot: cached,
                completedAt: Date(timeIntervalSinceNow: -120)
            )
        )
        let controller = StorageExplorerController(scanner: scanner, snapshotCache: cache)

        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        try await waitUntil { controller.isShowingCachedPreview }

        XCTAssertTrue(controller.isScanning)
        XCTAssertEqual(controller.rootItem?.path, root)
        XCTAssertNotNil(controller.cachedPreviewDate)
        let item = try XCTUnwrap(cached.items[root + "/a"])
        XCTAssertEqual(controller.reviewEligibility(for: item), .cachedPreview)
        controller.toggleSelection(path: item.path)
        XCTAssertTrue(controller.basket.isEmpty)

        var fresh = cached
        fresh.items[root]?.allocatedSize = 999
        scanner.finish(path: root, snapshot: fresh)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { cache.savedSnapshot != nil }

        XCTAssertFalse(controller.isShowingCachedPreview)
        XCTAssertNil(controller.cachedPreviewDate)
        XCTAssertEqual(controller.rootItem?.allocatedSize, 999)
        XCTAssertEqual(cache.savedRootPath, root)
    }

    func testCachedPreviewForDifferentRootCannotReplaceActiveScan() async throws {
        let scanner = ControlledStorageScanner()
        let first = "/tmp/storage-cache-first"
        let second = "/tmp/storage-cache-second"
        let cache = ControlledStorageSnapshotCache(
            cachedByRoot: [first: StorageExplorerCachedSnapshot(
                snapshot: Self.fixture(root: first),
                completedAt: Date()
            )],
            loadDelay: .milliseconds(80)
        )
        let controller = StorageExplorerController(scanner: scanner, snapshotCache: cache)

        controller.startScan(at: URL(fileURLWithPath: first))
        controller.startScan(at: URL(fileURLWithPath: second))
        try await waitUntil { scanner.hasRequest(second) }
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertFalse(controller.isShowingCachedPreview)
        XCTAssertNil(controller.rootItem)
        XCTAssertEqual(controller.scanRootURL?.path, second)
        scanner.finish(path: second)
        try await waitUntil { !controller.isScanning }
    }

    func testSnapshotCacheRoundTripsCompleteSnapshotAndRejectsExpiredPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = "/tmp/storage-cache-round-trip"
        let snapshot = Self.fixture(root: root)
        let cache = StorageExplorerSnapshotCache(
            directoryURL: directory,
            maximumAge: 60
        )

        let completedAt = Date(timeIntervalSinceNow: -10)
        await cache.save(snapshot: snapshot, completedAt: completedAt, rootPath: root)
        let cached = await cache.load(rootPath: root)
        let loaded = try XCTUnwrap(cached)
        XCTAssertEqual(loaded.snapshot.items, snapshot.items)
        XCTAssertEqual(loaded.completedAt.timeIntervalSince1970, completedAt.timeIntervalSince1970, accuracy: 0.001)

        await cache.save(
            snapshot: snapshot,
            completedAt: Date(timeIntervalSinceNow: -120),
            rootPath: root
        )
        let expired = await cache.load(rootPath: root)
        XCTAssertNil(expired)
    }

    func testUnrelatedFilesystemChangeDoesNotBlockReviewOfUnchangedSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected.bin")
        let unrelated = root.appendingPathComponent("unrelated.bin")
        try Data(repeating: 1, count: 10).write(to: selected)
        try Data(repeating: 2, count: 10).write(to: unrelated)
        let controller = StorageExplorerController()
        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.contains(where: { $0.name == selected.lastPathComponent }) }
        let selectedPath = try XCTUnwrap(controller.rows.first(where: { $0.name == selected.lastPathComponent })?.item.path)
        controller.toggleSelection(path: selectedPath)

        try Data(repeating: 3, count: 20).write(to: unrelated)
        controller.confirmTrash()

        XCTAssertTrue(controller.isConfirmingTrash)
        XCTAssertEqual(controller.reviewItems.map(\.path), [selectedPath])
    }

    func testChangedSelectedFolderCanBeReviewedWithoutRefreshing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("existing.bin"))
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = StorageExplorerController()

        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.contains(where: { $0.name == "selected" }) }
        let selected = try XCTUnwrap(controller.rows.first(where: { $0.name == "selected" })?.item)
        controller.toggleSelection(path: selected.path)
        try Data([2]).write(to: folder.appendingPathComponent("new.bin"))
        controller.confirmTrash()

        XCTAssertTrue(controller.isConfirmingTrash)
        XCTAssertEqual(controller.reviewItems.map(\.path), [selected.path])
        XCTAssertNil(controller.lastErrorMessage)
    }

    func testChangedSelectedFileCanMoveToTrashWithoutRefreshingWhenIdentityIsUnchanged() async throws {
        var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let physical = realpath(root.path, nil) {
            root = URL(fileURLWithPath: String(cString: physical))
            free(physical)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected.bin")
        try Data(repeating: 1, count: 10).write(to: selected)
        let recycler = PartialTrashRecycler(successfulPath: selected.path)
        let controller = StorageExplorerController(
            safetyPolicy: StorageExplorerSafetyPolicy(trashRecycler: recycler)
        )
        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.contains(where: { $0.name == selected.lastPathComponent }) }
        let item = try XCTUnwrap(controller.rows.first(where: { $0.name == selected.lastPathComponent })?.item)
        controller.toggleSelection(path: item.path)

        try Data(repeating: 2, count: 100).write(to: selected)
        controller.confirmTrash()
        XCTAssertTrue(controller.isConfirmingTrash)
        XCTAssertEqual(controller.reviewItems.map(\.path), [item.path])
        XCTAssertNil(controller.lastErrorMessage)

        await controller.executeTrash()
        try await waitUntil { !controller.isScanning }

        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertNil(controller.lastErrorMessage)
    }

    func testReviewAvailabilityExplainsOnlyActualActionStates() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let root = "/tmp/storage-review-availability"
        XCTAssertEqual(controller.reviewAvailability, .empty)
        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        XCTAssertEqual(controller.reviewAvailability, .empty)
        let snapshot = Self.fixture(root: root)
        scanner.finish(path: root, snapshot: snapshot)
        try await waitUntil { !controller.isScanning }
        controller.toggleSelection(path: root + "/a")
        XCTAssertEqual(controller.reviewAvailability, .updating)
        try await waitUntil { controller.hierarchyNodes.map(\.id) == [root + "/b"] }
        controller.presentationDidRender(revision: controller.hierarchyRevision)
        XCTAssertEqual(controller.reviewAvailability, .ready)
        controller.clearSelection()
        XCTAssertEqual(controller.reviewAvailability, .empty)
    }

    func testReviewEligibilityExplainsStableRestrictionReasons() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let root = "/tmp/storage-review-eligibility"
        var snapshot = Self.fixture(root: root)
        snapshot.items[root + "/a"]?.isIncomplete = true
        snapshot.items[root + "/a"]?.skippedCount = 3

        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        scanner.finish(path: root, snapshot: snapshot)
        try await waitUntil { !controller.isScanning }

        XCTAssertEqual(controller.reviewEligibility(for: try XCTUnwrap(snapshot.items[root])), .scanRoot)
        XCTAssertEqual(
            controller.reviewEligibility(for: try XCTUnwrap(snapshot.items[root + "/a"])),
            .incomplete(skippedCount: 3)
        )
        let incompleteItem = try XCTUnwrap(snapshot.items[root + "/a"])
        XCTAssertTrue(controller.canStage(incompleteItem))
        XCTAssertTrue(controller.reviewEligibility(for: incompleteItem).canAdd)
        XCTAssertTrue(controller.reviewEligibility(for: incompleteItem).canToggle)
        XCTAssertEqual(controller.reviewEligibility(for: try XCTUnwrap(snapshot.items[root + "/b"])), .eligible)

        controller.toggleSelection(path: root + "/b")
        try await waitUntil { controller.hierarchyNodes.map(\.id) == [root + "/a"] }
        controller.presentationDidRender(revision: controller.hierarchyRevision)
        XCTAssertEqual(controller.reviewEligibility(for: try XCTUnwrap(snapshot.items[root + "/b"])), .selected)
        XCTAssertEqual(
            controller.reviewEligibility(for: try XCTUnwrap(snapshot.items[root + "/b/two"])),
            .includedBySelectedParent(name: "b")
        )
    }

    func testIncompleteFolderCanBeSelectedAndConfirmedForTrash() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        let root = "/tmp/storage-incomplete-review"
        var snapshot = Self.fixture(root: root)
        snapshot.items[root + "/a"]?.isIncomplete = true
        snapshot.items[root + "/a"]?.skippedCount = 2

        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        scanner.finish(path: root, snapshot: snapshot)
        try await waitUntil { !controller.isScanning }

        controller.toggleSelection(path: root + "/a")
        try await waitUntil { controller.basket.contains(root + "/a") }
        controller.confirmTrash()

        XCTAssertTrue(controller.isConfirmingTrash)
        XCTAssertEqual(controller.reviewItems.map(\.path), [root + "/a"])
    }

    func testSymlinkIsVisibleButCannotBeStaged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination.bin")
        let symbolicLink = root.appendingPathComponent("link.bin")
        try Data([1]).write(to: destination)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: destination)
        let controller = StorageExplorerController(
            scanner: StorageExplorerScanner(publishesItems: true)
        )

        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.contains(where: { $0.name == "link.bin" }) }
        let item = try XCTUnwrap(controller.rows.first(where: { $0.name == "link.bin" })?.item)

        XCTAssertTrue(item.isSymlink)
        XCTAssertFalse(controller.canStage(item))
        XCTAssertEqual(controller.reviewEligibility(for: item), .symlink)
        controller.toggleSelection(path: item.path)
        XCTAssertTrue(controller.basket.isEmpty)
    }

    func testDeduplicatedHardLinkKeepsObservedSizeForReviewValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.bin")
        let duplicate = root.appendingPathComponent("duplicate.bin")
        try Data(repeating: 1, count: 64).write(to: original)
        XCTAssertEqual(link(original.path, duplicate.path), 0)
        let controller = StorageExplorerController(
            scanner: StorageExplorerScanner(publishesItems: true)
        )

        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.count == 2 }
        let hardLinks = controller.rows.map(\.item).filter(\.isHardLinked)
        XCTAssertEqual(hardLinks.count, 2)
        let deduplicated = try XCTUnwrap(hardLinks.first(where: { $0.size == 0 }))
        XCTAssertEqual(deduplicated.observedFileSize, 64)
        controller.toggleSelection(path: deduplicated.path)
        controller.confirmTrash()

        XCTAssertTrue(controller.isConfirmingTrash)
        XCTAssertEqual(controller.reviewItems.map(\.path), [deduplicated.path])
    }

    func testTrashingCountedHardLinkPreservesSurvivingLinkAccountingWithoutRescanning() async throws {
        var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let physical = realpath(root.path, nil) {
            root = URL(fileURLWithPath: String(cString: physical))
            free(physical)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("a.bin")
        let duplicate = root.appendingPathComponent("b.txt")
        try Data(repeating: 1, count: 64).write(to: original)
        XCTAssertEqual(link(original.path, duplicate.path), 0)
        let scanner = CountingStorageScanner()
        let controller = StorageExplorerController(
            scanner: scanner,
            safetyPolicy: StorageExplorerSafetyPolicy(trashRecycler: PartialTrashRecycler(successfulPath: original.path))
        )
        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        let allocated = try XCTUnwrap(controller.rootItem?.allocatedSize)
        XCTAssertEqual(controller.snapshot.items[original.path]?.size, 64)
        XCTAssertEqual(controller.snapshot.items[duplicate.path]?.size, 0)
        controller.toggleSelection(path: original.path)
        controller.confirmTrash()

        await controller.executeTrash()

        XCTAssertFalse(controller.isScanning)
        XCTAssertNil(controller.snapshot.items[original.path])
        XCTAssertEqual(controller.snapshot.items[duplicate.path]?.size, 64)
        XCTAssertEqual(controller.snapshot.items[duplicate.path]?.allocatedSize, allocated)
        XCTAssertEqual(controller.rootItem?.size, 64)
        XCTAssertEqual(controller.rootItem?.allocatedSize, allocated)
        XCTAssertNil(controller.snapshot.fileTypeTotals["bin"])
        XCTAssertEqual(controller.snapshot.fileTypeTotals["txt"]?.size, 64)
        XCTAssertEqual(controller.snapshot.fileTypeTotals["txt"]?.count, 1)
        try await waitUntil { controller.rows.map(\.id) == [duplicate.path] }
        XCTAssertEqual(scanner.scanCount, 1)

        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        XCTAssertEqual(scanner.scanCount, 2)
        XCTAssertEqual(controller.rootItem?.size, 64)
    }

    func testSuccessfulFolderTrashUpdatesSnapshotAndNavigationWithoutRescanning() async throws {
        var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let requestedRoot = root
        if let physical = realpath(root.path, nil) {
            root = URL(fileURLWithPath: String(cString: physical))
            free(physical)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("selected")
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: folder.appendingPathComponent("small.bin"))
        try Data(repeating: 1, count: 8_192).write(to: folder.appendingPathComponent("larger.bin"))
        try Data(repeating: 2, count: 20).write(to: nested.appendingPathComponent("small.bin"))
        try Data(repeating: 3, count: 30).write(to: nested.appendingPathComponent("large.bin"))
        let remaining = root.appendingPathComponent("selected-other.bin")
        try Data(repeating: 4, count: 40).write(to: remaining)
        let scanner = CountingStorageScanner(scanner: StorageExplorerScanner(
            publishesItems: false,
            collectsFileTypeTotals: true,
            maximumRetainedFiles: 1
        ))
        let cache = ControlledStorageSnapshotCache()
        let controller = StorageExplorerController(
            scanner: scanner,
            safetyPolicy: StorageExplorerSafetyPolicy(trashRecycler: PartialTrashRecycler(successfulPath: folder.path)),
            snapshotCache: cache
        )
        controller.startScan(at: requestedRoot)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { cache.savedSnapshot != nil }
        let completedAt = controller.scanCompletedAt
        XCTAssertNil(controller.snapshot.items[folder.appendingPathComponent("small.bin").path])
        let remainingItem = try XCTUnwrap(controller.snapshot.items[remaining.path])
        controller.drillDown(to: try XCTUnwrap(controller.snapshot.items[nested.path]))
        controller.selectedPath = nested.appendingPathComponent("large.bin").path
        controller.toggleSelection(path: folder.path)
        controller.confirmTrash()

        await controller.executeTrash()

        XCTAssertFalse(controller.isScanning)
        XCTAssertEqual(controller.scanState, .completed)
        XCTAssertEqual(controller.currentPath, root.path)
        XCTAssertNil(controller.selectedPath)
        XCTAssertEqual(controller.navigationStack.map(\.path), [root.path])
        XCTAssertEqual(controller.rootItem?.size, 40)
        XCTAssertEqual(controller.rootItem?.allocatedSize, remainingItem.allocatedSize)
        XCTAssertEqual(controller.rootItem?.childCount, 1)
        XCTAssertEqual(controller.rootItem?.scannedCount, 2)
        XCTAssertEqual(controller.status.progress.filesScanned, 1)
        XCTAssertEqual(controller.snapshot.fileTypeTotals["bin"]?.count, 1)
        XCTAssertEqual(controller.snapshot.fileTypeTotals["bin"]?.size, 40)
        XCTAssertFalse(controller.snapshot.items.keys.contains { $0 == folder.path || $0.hasPrefix(folder.path + "/") })
        XCTAssertNil(controller.snapshot.children[folder.path])
        XCTAssertNil(controller.snapshot.fileTypeTotalsByDirectory[nested.path])
        XCTAssertTrue(controller.basket.isEmpty)
        XCTAssertTrue(controller.reviewItems.isEmpty)
        XCTAssertNil(controller.lastErrorMessage)
        XCTAssertNotNil(controller.lastSuccessMessage)
        XCTAssertEqual(controller.scanCompletedAt, completedAt)
        try await waitUntil { controller.rows.map(\.id) == [remaining.path] }
        try await waitUntil { cache.savedSnapshot?.items[folder.path] == nil }
        XCTAssertEqual(cache.savedRootPath, requestedRoot.path)
        XCTAssertEqual(controller.hierarchyNodes.map(\.id), [remaining.path])
        controller.mode = .largestFiles
        try await waitUntil { controller.rows.map(\.id) == [remaining.path] }
        controller.mode = .fileTypes
        try await waitUntil { controller.rows.map(\.id) == ["type:bin"] }
        XCTAssertEqual(controller.rows.first?.item.childCount, 1)
        XCTAssertEqual(scanner.scanCount, 1)
    }

    func testFailedTrashRetainsSnapshotAndSelectionWithoutRescanning() async throws {
        var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let physical = realpath(root.path, nil) {
            root = URL(fileURLWithPath: String(cString: physical))
            free(physical)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.bin")
        try Data([1, 2, 3]).write(to: file)
        let scanner = CountingStorageScanner()
        let controller = StorageExplorerController(
            scanner: scanner,
            safetyPolicy: StorageExplorerSafetyPolicy(trashRecycler: FailingTrashRecycler())
        )
        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        let previousItems = controller.snapshot.items
        controller.toggleSelection(path: file.path)
        controller.confirmTrash()

        await controller.executeTrash()

        XCTAssertFalse(controller.isScanning)
        XCTAssertEqual(controller.scanState, .completed)
        XCTAssertEqual(controller.snapshot.items, previousItems)
        XCTAssertEqual(controller.basket, [file.path])
        XCTAssertEqual(controller.reviewItems.map(\.path), [file.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNotNil(controller.lastErrorMessage)
        XCTAssertNil(controller.lastSuccessMessage)
        try await waitUntil { controller.rows.map(\.id) == [file.path] }
        let previousMessage = try XCTUnwrap(controller.lastErrorMessage)
        let revision = controller.hierarchyRevision
        controller.refreshLocalization(copy: Self.updatedCopy(controller.copy))
        try await waitUntil { controller.hierarchyRevision > revision }
        XCTAssertNotEqual(controller.lastErrorMessage, previousMessage)
        XCTAssertEqual(controller.reviewItems.map(\.path), [file.path])
        XCTAssertEqual(scanner.scanCount, 1)
    }

    func testPartialTrashResultUpdatesSnapshotAndKeepsOnlyFailedItemWithoutRescanning() async throws {
        var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let physical = realpath(root.path, nil) {
            root = URL(fileURLWithPath: String(cString: physical))
            free(physical)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.bin")
        let second = root.appendingPathComponent("second.bin")
        try Data(repeating: 1, count: 10).write(to: first)
        try Data(repeating: 2, count: 20).write(to: second)
        let recycler = PartialTrashRecycler(successfulPath: first.path)
        let scanner = CountingStorageScanner()
        let controller = StorageExplorerController(
            scanner: scanner,
            safetyPolicy: StorageExplorerSafetyPolicy(trashRecycler: recycler)
        )
        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.count == 2 }
        controller.toggleSelection(path: first.path)
        controller.toggleSelection(path: second.path)
        controller.confirmTrash()
        await controller.executeTrash()

        XCTAssertFalse(controller.isScanning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertNil(controller.snapshot.items[first.path])
        XCTAssertEqual(controller.rootItem?.size, 20)
        XCTAssertEqual(controller.basket, [second.path])
        XCTAssertEqual(controller.reviewItems.map(\.path), [second.path])
        XCTAssertNotNil(controller.lastErrorMessage)
        try await waitUntil { controller.rows.map(\.id) == [second.path] }
        let previousMessage = try XCTUnwrap(controller.lastErrorMessage)
        let revision = controller.hierarchyRevision
        controller.refreshLocalization(copy: Self.updatedCopy(controller.copy))
        try await waitUntil { controller.hierarchyRevision > revision }
        XCTAssertNotEqual(controller.lastErrorMessage, previousMessage)
        XCTAssertEqual(controller.reviewItems.map(\.path), [second.path])
        XCTAssertEqual(scanner.scanCount, 1)
    }

    private static func updatedCopy(_ copy: StorageExplorerControllerCopy) -> StorageExplorerControllerCopy {
        StorageExplorerControllerCopy(
            movedToTrash: "updated-" + copy.movedToTrash,
            trashOperationFailed: "updated-" + copy.trashOperationFailed,
            trashPartialFailure: "updated-" + copy.trashPartialFailure,
            otherName: copy.otherName
        )
    }

    static func fixture(root: String) -> StorageExplorerSnapshot {
        func item(_ suffix: String, _ parent: String?, _ size: Int64, _ directory: Bool) -> StorageItem {
            let path = root + suffix
            return StorageItem(name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                url: URL(fileURLWithPath: path), isDirectory: directory, size: size,
                allocatedSize: size * 2, parentPath: parent.map { root + $0 })
        }
        var snapshot = StorageExplorerSnapshot(rootPath: root)
        snapshot.apply([item("", nil, 300, true), item("/a", "", 100, true), item("/b", "", 200, true),
                        item("/a/one", "/a", 100, false), item("/b/two", "/b", 200, false)])
        return snapshot
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for controlled scan")
    }
}

private struct FailingTrashRecycler: StorageExplorerTrashRecycling {
    func recycle(urls: [URL]) async throws -> StorageExplorerRecycleResult {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class CountingStorageScanner: StorageExplorerScanning, @unchecked Sendable {
    private let scanner: StorageExplorerScanner
    private let lock = NSLock()
    private var count = 0

    init(scanner: StorageExplorerScanner = StorageExplorerScanner(publishesItems: true)) {
        self.scanner = scanner
    }

    var scanCount: Int { lock.withLock { count } }

    func scanSnapshot(rootURL: URL, update: @escaping @Sendable (StorageExplorerScanUpdate) -> Void) async throws -> StorageExplorerSnapshot {
        lock.withLock { count += 1 }
        return try await scanner.scanSnapshot(rootURL: rootURL, update: update)
    }

    func invalidate(paths: [String]) { scanner.invalidate(paths: paths) }
    func clearCache() { scanner.clearCache() }
}

private final class PartialTrashRecycler: StorageExplorerTrashRecycling, @unchecked Sendable {
    let successfulPath: String
    init(successfulPath: String) { self.successfulPath = successfulPath }

    func recycle(urls: [URL]) async throws -> StorageExplorerRecycleResult {
        let successfulName = URL(fileURLWithPath: successfulPath).lastPathComponent
        guard let successful = urls.first(where: { $0.lastPathComponent == successfulName }) else {
            return StorageExplorerRecycleResult(moved: [:], errorDescription: "No matching item")
        }
        try FileManager.default.removeItem(at: successful)
        return StorageExplorerRecycleResult(
            moved: [successful: URL(fileURLWithPath: "/Users/dummy/.Trash/" + successful.lastPathComponent)],
            errorDescription: "One item failed"
        )
    }
}

private final class ControlledStorageScanner: StorageExplorerScanning, @unchecked Sendable {
    private struct Request {
        let update: @Sendable (StorageExplorerScanUpdate) -> Void
        let continuation: CheckedContinuation<StorageExplorerSnapshot, Error>
    }
    private let lock = NSLock()
    private var requests: [String: Request] = [:]
    private var requestCount = 0
    var scanCount: Int { lock.withLock { requestCount } }
    func invalidate(paths: [String]) {}
    func clearCache() {}
    func hasRequest(_ path: String) -> Bool { lock.withLock { requests[path] != nil } }
    func scanSnapshot(rootURL: URL, update: @escaping @Sendable (StorageExplorerScanUpdate) -> Void) async throws -> StorageExplorerSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                requestCount += 1
                requests[rootURL.path] = Request(update: update, continuation: continuation)
            }
        }
    }
    func emitSnapshot(path: String, snapshot: StorageExplorerSnapshot) {
        let request = lock.withLock { requests[path] }
        request?.update(StorageExplorerScanUpdate(items: Array(snapshot.items.values), progress: snapshot.progress))
    }
    func emit(path: String, size: Int64) {
        let request = lock.withLock { requests[path] }
        var item = StorageItem(name: "root", path: path, url: URL(fileURLWithPath: path), isDirectory: true, size: size)
        item.isIncomplete = true
        request?.update(StorageExplorerScanUpdate(items: [item], progress: StorageExplorerScanProgress(bytesScanned: size, currentPath: path)))
    }
    func finish(path: String, snapshot: StorageExplorerSnapshot? = nil, error: Error? = nil) {
        let request = lock.withLock { requests.removeValue(forKey: path) }
        if let error { request?.continuation.resume(throwing: error); return }
        var result = snapshot ?? StorageExplorerSnapshot(rootPath: path)
        if result.items.isEmpty {
            result.apply([StorageItem(name: "root", path: path, url: URL(fileURLWithPath: path), isDirectory: true)])
        }
        request?.continuation.resume(returning: result)
    }
}

private final class ControlledStorageSnapshotCache: StorageExplorerSnapshotCaching, @unchecked Sendable {
    private let lock = NSLock()
    private let cachedByRoot: [String: StorageExplorerCachedSnapshot]
    private let loadDelay: Duration?
    private var storedSnapshot: StorageExplorerSnapshot?
    private var storedRootPath: String?

    init(
        cached: StorageExplorerCachedSnapshot? = nil,
        cachedByRoot: [String: StorageExplorerCachedSnapshot] = [:],
        loadDelay: Duration? = nil
    ) {
        if let cached {
            self.cachedByRoot = [cached.snapshot.rootPath: cached]
        } else {
            self.cachedByRoot = cachedByRoot
        }
        self.loadDelay = loadDelay
    }

    var savedSnapshot: StorageExplorerSnapshot? { lock.withLock { storedSnapshot } }
    var savedRootPath: String? { lock.withLock { storedRootPath } }

    func load(rootPath: String) async -> StorageExplorerCachedSnapshot? {
        if let loadDelay { try? await Task.sleep(for: loadDelay) }
        return cachedByRoot[rootPath]
    }

    func save(snapshot: StorageExplorerSnapshot, completedAt: Date, rootPath: String) async {
        lock.withLock {
            storedSnapshot = snapshot
            storedRootPath = rootPath
        }
    }
}
