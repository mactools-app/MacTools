import Darwin
import Foundation
import MacToolsFileSystem
import XCTest
@testable import StorageExplorerPlugin

final class StorageExplorerProgressTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let physical = try XCTUnwrap(realpath(root.path, nil))
        root = URL(fileURLWithPath: String(cString: physical))
        free(physical)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testWorkerCountsPreserveTotalsAndHardLinksAcrossFolders() async throws {
        for directory in ["a", "b"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let file = root.appendingPathComponent("a/file")
        try Data(repeating: 3, count: 10_000).write(to: file)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("b/link"))
        let canonicalPath = root.appendingPathComponent("a/file").path
        let duplicatePath = root.appendingPathComponent("b/link").path
        for workers in [1, 4] {
            let result = try await StorageExplorerScanner(workerCount: workers).scanSnapshot(rootURL: root) { _ in }
            XCTAssertEqual(result.items[result.rootPath]?.size, 10_000)
            XCTAssertEqual(result.items[root.appendingPathComponent("a").path]?.size, 10_000)
            XCTAssertEqual(result.items[root.appendingPathComponent("b").path]?.size, 0)
            XCTAssertEqual(result.items[canonicalPath]?.size, 10_000)
            XCTAssertEqual(result.items[duplicatePath]?.size, 0)
            XCTAssertEqual(result.fileTypeTotals["—"]?.size, 10_000)
            XCTAssertEqual(result.fileTypeTotals["—"]?.count, 2)
            XCTAssertEqual(result.items.count, 5)
            XCTAssertEqual(result.progress.skippedCount, 0)
        }

        let productionResult = try await StorageExplorerScanner(
            workerCount: 4,
            publishesItems: false,
            maximumRetainedFiles: 100
        ).scanSnapshot(rootURL: root) { _ in }
        XCTAssertEqual(productionResult.items[productionResult.rootPath]?.size, 10_000)
        XCTAssertEqual(productionResult.items[canonicalPath]?.size, 10_000)
        XCTAssertNil(productionResult.items[duplicatePath])
        XCTAssertTrue(productionResult.fileTypeTotals.isEmpty)
        XCTAssertTrue(productionResult.fileTypeTotalsByDirectory.isEmpty)
    }

    func testCacheInvalidationRefreshesNestedContentAndReusesUnaffectedDirectories() async throws {
        for directory in ["a", "b"] {
            let folder = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 20).write(to: folder.appendingPathComponent("file"))
        }
        let scanner = StorageExplorerScanner()
        let first = try await scanner.scanSnapshot(rootURL: root) { _ in }
        let second = try await scanner.scanSnapshot(rootURL: root) { _ in }
        XCTAssertEqual(second.progress.cachedDirectories, 3)
        let changed = URL(fileURLWithPath: first.rootPath).appendingPathComponent("a/file")
        try Data(repeating: 1, count: 150).write(to: changed)
        scanner.invalidate(paths: [changed.path])
        let refreshed = try await scanner.scanSnapshot(rootURL: root) { _ in }
        XCTAssertEqual(refreshed.items[refreshed.rootPath]?.size, 170)
        XCTAssertEqual(refreshed.progress.cachedDirectories, 1)
        scanner.clearCache()
        let full = try await scanner.scanSnapshot(rootURL: root) { _ in }
        XCTAssertEqual(full.progress.cachedDirectories, 0)
    }

    func testPrecancelledTaskAlwaysThrows() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StorageExplorerScanner().scanSnapshot(rootURL: root) { _ in }
        }
        do { _ = try await task.value; XCTFail("A cancelled scan must not return a complete snapshot") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testStreamCanReconstructFinalIndexAndReportsIncompleteRootFirst() async throws {
        for i in 0..<2 {
            try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("file-\(i)"))
        }
        let events = EventBox()
        let result = try await StorageExplorerScanner().scanSnapshot(rootURL: root) { events.append($0) }
        let captured = events.values
        XCTAssertTrue(captured.first?.items.first?.isIncomplete == true)
        var reconstructed = StorageExplorerSnapshot(rootPath: result.rootPath)
        for event in captured { reconstructed.apply(event.items) }
        XCTAssertEqual(reconstructed.items, result.items)
        XCTAssertEqual(result.items[result.rootPath]?.size, 200)
        XCTAssertFalse(result.items[result.rootPath]?.isIncomplete ?? true)
        XCTAssertTrue(captured.contains { $0.progress.phase == .finalizing })
        XCTAssertEqual(result.progress.phase, .finalizing)
    }

    func testBulkStorageAttributesMatchFilesystemIncludingSparseFile() throws {
        let file = root.appendingPathComponent("sparse.bin")
        let fd = open(file.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(ftruncate(fd, 2_000_000), 0)
        let listing = try FileSystemDirectoryReader.read(path: root.path, cancelled: { false })
        let entry = try XCTUnwrap(listing.entries.first)
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey])
        XCTAssertEqual(entry.dataLength, Int64(try XCTUnwrap(values.fileSize)))
        XCTAssertEqual(entry.allocatedSize, Int64(try XCTUnwrap(values.totalFileAllocatedSize)))
        XCTAssertEqual(try XCTUnwrap(entry.modificationDate).timeIntervalSince1970,
                       try XCTUnwrap(values.contentModificationDate).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(entry.hasLayoutMismatch)
    }

    func testUnreadableFolderIsReportedAsIncomplete() async throws {
        let blocked = root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(blocked.path, 0), 0)
        defer { chmod(blocked.path, 0o700) }
        let result = try await StorageExplorerScanner().scanSnapshot(rootURL: root) { _ in }
        XCTAssertGreaterThan(result.progress.skippedCount, 0)
        XCTAssertTrue(result.items[result.rootPath]?.isIncomplete ?? false)
        XCTAssertTrue(result.items.values.contains { $0.name == "blocked" && $0.isAccessDenied })
    }

    func testRemovingSkippedFolderClearsAncestorWarnings() async throws {
        let device = try fixtureDevice()
        let parentPath = root.appendingPathComponent("parent").path
        let skippedPath = root.appendingPathComponent("parent/skipped").path
        for cloudOnly in [true, false] {
            let listings = [
                root.path: FileSystemDirectoryListing(entries: [fixtureEntry("parent", directory: true, device: device)]),
                parentPath: FileSystemDirectoryListing(entries: [
                    fixtureEntry("skipped", directory: true, device: cloudOnly ? device : device ^ 1,
                                 flags: cloudOnly ? UInt32(SF_DATALESS) : 0),
                    fixtureEntry("file.bin", device: device, size: 20)
                ])
            ]
            let scanner = StorageExplorerScanner(publishesItems: false, directoryReader: { path in
                guard let listing = listings[path] else { throw CocoaError(.fileNoSuchFile) }
                return listing
            })
            var snapshot = try await scanner.scanSnapshot(rootURL: root) { _ in }
            XCTAssertEqual(snapshot.progress.skippedCount, 1)
            XCTAssertEqual(snapshot.items[parentPath]?.skippedCount, 1)
            XCTAssertEqual(snapshot.items[root.path]?.skippedCount, 1)

            snapshot.removeSubtrees(at: [skippedPath])

            XCTAssertNil(snapshot.items[skippedPath])
            XCTAssertEqual(snapshot.items[parentPath]?.size, 20)
            XCTAssertEqual(snapshot.items[parentPath]?.skippedCount, 0)
            XCTAssertEqual(snapshot.items[parentPath]?.isIncomplete, false)
            XCTAssertEqual(snapshot.items[root.path]?.skippedCount, 0)
            XCTAssertEqual(snapshot.items[root.path]?.isIncomplete, false)
            XCTAssertEqual(snapshot.progress.skippedCount, 0)
        }
    }

    func testRemovingIncompleteSubtreePreservesUnrelatedSkippedItem() async throws {
        let device = try fixtureDevice()
        let deniedPath = root.appendingPathComponent("denied").path
        for name in ["selected", "Selected.app"] {
            let selectedPath = root.appendingPathComponent(name).path
            let listings = [
                root.path: FileSystemDirectoryListing(entries: [
                    fixtureEntry(name, directory: true, device: device),
                    fixtureEntry("denied", directory: true, device: device)
                ]),
                selectedPath: FileSystemDirectoryListing(entries: [
                    fixtureEntry("cloud", directory: true, device: device, flags: UInt32(SF_DATALESS))
                ])
            ]
            let scanner = StorageExplorerScanner(publishesItems: false, directoryReader: { path in
                if path == deniedPath { throw POSIXError(.EACCES) }
                guard let listing = listings[path] else { throw CocoaError(.fileNoSuchFile) }
                return listing
            })
            var snapshot = try await scanner.scanSnapshot(rootURL: root) { _ in }
            XCTAssertEqual(snapshot.items[root.path]?.skippedCount, 2)
            XCTAssertEqual(snapshot.progress.skippedCount, 2)

            snapshot.removeSubtrees(at: [selectedPath])

            XCTAssertEqual(snapshot.items[root.path]?.skippedCount, 1)
            XCTAssertEqual(snapshot.items[root.path]?.isIncomplete, true)
            XCTAssertEqual(snapshot.items[deniedPath]?.isAccessDenied, true)
            XCTAssertEqual(snapshot.progress.skippedCount, 1)
        }
    }

    private func fixtureDevice() throws -> UInt64 {
        var status = stat()
        guard lstat(root.path, &status) == 0 else { throw POSIXError(.EIO) }
        return UInt64(UInt32(bitPattern: status.st_dev))
    }

    private func fixtureEntry(_ name: String, directory: Bool = false, device: UInt64,
                              flags: UInt32 = 0, size: Int64 = 0) -> FileSystemBulkAttributeEntry {
        var entry = FileSystemBulkAttributeEntry()
        entry.nameBytes = name.utf8.map { CChar(bitPattern: $0) } + [0]
        entry.fileType = directory ? .directory : .regularFile
        entry.devid = device
        entry.fileID = 1
        entry.linkCount = 1
        entry.flags = flags
        entry.dataLength = size
        entry.allocatedSize = size
        return entry
    }

    func testProgressOnlySnapshotBoundsRetainedFilesWithoutUnusedFileTypeTotals() async throws {
        for directory in 0..<3 {
            let folder = root.appendingPathComponent("folder-\(directory)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in 0..<3 {
                try Data(repeating: 1, count: (file + 1) * 16_384)
                    .write(to: folder.appendingPathComponent("file-\(file).bin"))
            }
        }
        let snapshot = try await StorageExplorerScanner(
            workerCount: 4,
            publishesItems: false,
            maximumRetainedFiles: 2
        ).scanSnapshot(rootURL: root) { _ in }

        XCTAssertEqual(snapshot.items[snapshot.rootPath]?.size, 18 * 16_384)
        XCTAssertTrue(snapshot.fileTypeTotals.isEmpty)
        XCTAssertTrue(snapshot.fileTypeTotalsByDirectory.isEmpty)
        XCTAssertLessThanOrEqual(snapshot.items.values.filter { !$0.isDirectory }.count, 5)
        for directory in 0..<3 {
            XCTAssertNotNil(snapshot.items[root.appendingPathComponent("folder-\(directory)/file-2.bin").path])
        }
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StorageExplorerScanUpdate] = []
    var values: [StorageExplorerScanUpdate] { lock.withLock { events } }
    func append(_ event: StorageExplorerScanUpdate) { lock.withLock { events.append(event) } }
}
