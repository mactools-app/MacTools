import Darwin
import Foundation
import MacToolsFileSystem

public final class StorageExplorerScanner: StorageExplorerScanning, @unchecked Sendable {
    public let workerCount: Int
    public let publishesItems: Bool
    public let collectsFileTypeTotals: Bool
    public let maximumRetainedFiles: Int
    private let cache = StorageExplorerDirectoryCache()
    private let directoryReader: (@Sendable (String) throws -> FileSystemDirectoryListing)?

    public convenience init(
        workerCount: Int? = nil,
        publishesItems: Bool = true,
        collectsFileTypeTotals: Bool? = nil,
        maximumRetainedFiles: Int = 10_000
    ) {
        self.init(workerCount: workerCount, publishesItems: publishesItems,
                  collectsFileTypeTotals: collectsFileTypeTotals,
                  maximumRetainedFiles: maximumRetainedFiles, directoryReader: nil)
    }

    init(
        workerCount: Int? = nil,
        publishesItems: Bool = true,
        collectsFileTypeTotals: Bool? = nil,
        maximumRetainedFiles: Int = 10_000,
        directoryReader: (@Sendable (String) throws -> FileSystemDirectoryListing)?
    ) {
        let adaptiveWorkerCount = max(4, ProcessInfo.processInfo.activeProcessorCount / 2)
        self.workerCount = min(max(workerCount ?? adaptiveWorkerCount, 1), 6)
        self.publishesItems = publishesItems
        self.collectsFileTypeTotals = collectsFileTypeTotals ?? publishesItems
        self.maximumRetainedFiles = max(1, maximumRetainedFiles)
        self.directoryReader = directoryReader
    }

    public func invalidate(paths: [String]) { cache.invalidate(paths: paths) }
    public func clearCache() { cache.invalidate(paths: nil) }

    public func scan(
        rootURL: URL,
        progressHandler: (@Sendable (StorageExplorerScanProgress) -> Void)? = nil
    ) async throws -> StorageItem {
        let snapshot = try await scanSnapshot(rootURL: rootURL) { progressHandler?($0.progress) }
        guard let root = snapshot.tree() else { throw CocoaError(.fileNoSuchFile) }
        return root
    }

    public func scanSnapshot(
        rootURL: URL,
        update: @escaping @Sendable (StorageExplorerScanUpdate) -> Void
    ) async throws -> StorageExplorerSnapshot {
        let cancellation = StorageExplorerCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // Blocking filesystem calls run on bounded GCD workers, outside the cooperative executor.
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        let state = try ScanWork(
                            rootURL: rootURL,
                            cancellation: cancellation,
                            update: update,
                            publishesItems: publishesItems,
                            collectsFileTypeTotals: collectsFileTypeTotals,
                            maximumRetainedFiles: maximumRetainedFiles
                        )
                        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
                            while let job = state.next() {
                                do {
                                    let consume: (FileSystemDirectoryListing) -> Void = { listing in
                                        let entries = listing.entries.compactMap {
                                            StorageExplorerScannedEntry(metadata: $0, parentPath: job.path)
                                        }
                                        state.consume(job: job, listing: listing, entries: entries)
                                    }
                                    let cached: Bool
                                    if let directoryReader {
                                        consume(try directoryReader(job.path))
                                        cached = false
                                    } else {
                                        cached = try cache.readBatches(
                                            path: job.path, cancelled: { cancellation.isCancelled }, consume: consume
                                        )
                                    }
                                    state.finish(cached: cached)
                                } catch is CancellationError {
                                    state.finishCancelled()
                                } catch {
                                    state.finishFailed(job: job, error: error)
                                }
                            }
                        }
                        if cancellation.isCancelled { throw CancellationError() }
                        continuation.resume(returning: try state.result())
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// Package classification must stay on the enumeration hot path without issuing a second
    /// filesystem metadata request for every directory. Missing an unusual package extension is
    /// safe: it only exposes more hierarchy instead of hiding ordinary folders from the scan.
    fileprivate static func isPackageDirectory(name: String) -> Bool {
        let pathExtension = (name as NSString).pathExtension.lowercased()
        return packageDirectoryExtensions.contains(pathExtension)
    }

    private static let packageDirectoryExtensions: Set<String> = [
        "action", "app", "appex", "band", "bundle", "framework", "garageband",
        "imovielibrary", "keynote", "kext", "logicx", "mdimporter", "musiclibrary",
        "numbers", "pages", "photolibrary", "photoslibrary", "pkg", "playground",
        "playgroundbook", "plugin", "prefpane", "qlgenerator", "rtfd", "saver",
        "service", "systemextension", "workflow", "xcworkspace", "xcodeproj", "xpc",
    ]
}

private struct StorageExplorerScannedEntry {
    let metadata: FileSystemBulkAttributeEntry
    let name: String
    let path: String
    let parentPath: String
    let isDirectory: Bool
    let isCloudPlaceholder: Bool
    let isPackage: Bool
    var size: Int64
    var allocatedSize: Int64
    var skippedCount = 0

    init?(metadata: FileSystemBulkAttributeEntry, parentPath: String) {
        guard let bytes = metadata.nameBytes,
              let name = bytes.withUnsafeBytes({ String(bytes: $0.dropLast(), encoding: .utf8) }),
              name != ".", name != "..", !name.contains("/") else { return nil }
        self.metadata = metadata
        self.name = name
        self.parentPath = parentPath
        self.path = parentPath == "/" ? "/" + name : parentPath + "/" + name
        self.isDirectory = metadata.fileType == .directory
        self.isCloudPlaceholder = (metadata.flags ?? 0) & UInt32(SF_DATALESS) != 0
        self.isPackage = isDirectory && !isCloudPlaceholder && StorageExplorerScanner.isPackageDirectory(name: name)
        self.size = isDirectory ? 0 : max(metadata.dataLength ?? 0, 0)
        self.allocatedSize = isDirectory ? 0 : max(metadata.allocatedSize ?? 0, 0)
    }

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    /// Foundation URLs are needed only for published or retained rows, not every scanned file.
    func makeItem() -> StorageItem {
        var item = StorageItem(
            name: name, path: path, url: URL(fileURLWithPath: path, isDirectory: isDirectory), isDirectory: isDirectory,
            isPackage: isPackage, isSymlink: metadata.fileType == .symlink,
            size: size, allocatedSize: allocatedSize, modificationDate: metadata.modificationDate,
            parentPath: parentPath, fileIdentity: ScanWork.identity(for: metadata),
            observedFileSize: isDirectory ? 0 : max(metadata.dataLength ?? 0, 0),
            hardLinkCount: isDirectory ? 1 : (metadata.linkCount ?? 1)
        )
        item.isCloudPlaceholder = isCloudPlaceholder
        item.isIncomplete = isDirectory
        item.skippedCount = skippedCount
        return item
    }
}

private final class StorageExplorerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Cached enumeration is only reused for a short window and invalidated by file events.
/// Every scan still visits directory jobs and recomputes global hard-link accounting.
private final class StorageExplorerDirectoryCache: @unchecked Sendable {
    private struct Entry { let listing: FileSystemDirectoryListing; let date: Date }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var epoch = 0
    private var count = 0

    func invalidate(paths: [String]?) {
        lock.withLock {
            epoch += 1
            guard let paths else { entries.removeAll(); count = 0; return }
            let changedPaths = Set(paths)
            // Large FSEvent batches are cheaper and safer to handle as a full cache reset.
            // This bounds synchronous prefix matching when builds or archive extraction touch
            // thousands of files at once.
            guard changedPaths.count <= 32 else { entries.removeAll(); count = 0; return }
            let stale = entries.keys.filter { directory in
                changedPaths.contains { path in
                    path == directory || path.hasPrefix(directory + "/") || directory.hasPrefix(path + "/")
                }
            }
            for path in stale { count -= entries.removeValue(forKey: path)?.listing.entries.count ?? 0 }
        }
    }

    func readBatches(
        path: String,
        cancelled: () -> Bool,
        consume: (FileSystemDirectoryListing) -> Void
    ) throws -> Bool {
        let (hit, version): (FileSystemDirectoryListing?, Int) = lock.withLock {
            let entry = entries[path]
            return (entry.flatMap { Date().timeIntervalSince($0.date) < 30 ? $0.listing : nil }, epoch)
        }
        if cancelled() { throw CancellationError() }
        if let hit { consume(hit); return true }
        var retained: FileSystemDirectoryListing? = FileSystemDirectoryListing()
        try FileSystemDirectoryReader.readBatches(path: path, cancelled: cancelled) { batch in
            if let count = retained?.entries.count {
                if count + batch.entries.count <= 10_000 {
                    retained?.entries.append(contentsOf: batch.entries)
                    retained?.skippedCount += batch.skippedCount
                } else {
                    retained = nil
                }
            }
            consume(batch)
        }
        lock.withLock {
            guard epoch == version else { return }
            count -= entries.removeValue(forKey: path)?.listing.entries.count ?? 0
            if let listing = retained {
                if count + listing.entries.count > 10_000 { entries.removeAll(); count = 0 }
                entries[path] = Entry(listing: listing, date: Date())
                count += listing.entries.count
            }
        }
        return false
    }
}

private final class ScanWork: @unchecked Sendable {
    struct Job { let path: String; let packageOwner: String? }
    struct HardLinkCandidate {
        let entry: StorageExplorerScannedEntry
        let accountingOwner: String
        let fileTypeParent: String?
    }
    private let workCondition = NSCondition()
    private let stateLock = NSLock()
    private let cancellation: StorageExplorerCancellation
    private let update: @Sendable (StorageExplorerScanUpdate) -> Void
    private var jobs: [Job] = []
    private var active = 0
    private var snapshot: StorageExplorerSnapshot
    private var changed: Set<String> = []
    private var hardLinkCandidates: [StorageFileInode: HardLinkCandidate] = [:]
    private var progress = StorageExplorerScanProgress()
    private let started = Date()
    private var lastReport = Date.distantPast
    private let device: UInt64
    private let publishesItems: Bool
    private let collectsFileTypeTotals: Bool
    private let retainedFiles: StorageExplorerLargestFileHeap
    private var largestFileByDirectory: [String: StorageExplorerScannedEntry] = [:]
    private var directFileTypeTotals: [String: [String: StorageExplorerSizeTotals]] = [:]

    init(rootURL: URL, cancellation: StorageExplorerCancellation,
         update: @escaping @Sendable (StorageExplorerScanUpdate) -> Void,
         publishesItems: Bool,
         collectsFileTypeTotals: Bool,
         maximumRetainedFiles: Int) throws {
        // Expand /tmp and /var once, then require physical paths for every directory open.
        guard let resolved = realpath(rootURL.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        let path = String(cString: resolved)
        free(resolved)
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadUnsupportedScheme) }
        self.cancellation = cancellation
        self.update = update
        self.publishesItems = publishesItems
        self.collectsFileTypeTotals = collectsFileTypeTotals
        self.retainedFiles = StorageExplorerLargestFileHeap(limit: maximumRetainedFiles)
        self.device = UInt64(UInt32(bitPattern: status.st_dev))
        self.snapshot = StorageExplorerSnapshot(rootPath: path)
        let url = URL(fileURLWithPath: path)
        let dataless = status.st_flags & UInt32(SF_DATALESS) != 0
        let package = !dataless && StorageExplorerScanner.isPackageDirectory(name: url.lastPathComponent)
        var root = StorageItem(
            name: url.lastPathComponent,
            path: path,
            url: url,
            isDirectory: true,
            isPackage: package,
            fileIdentity: StorageFileInode(device: status.st_dev, inode: status.st_ino)
        )
        root.isIncomplete = true
        root.isCloudPlaceholder = dataless
        root.skippedCount = dataless ? 1 : 0
        snapshot.apply([root])
        changed.insert(path)
        progress.skippedCount = dataless ? 1 : 0
        if !dataless { jobs = [Job(path: path, packageOwner: package ? path : nil)] }
        publish(force: true)
    }

    func next() -> Job? {
        workCondition.lock()
        defer { workCondition.unlock() }
        while jobs.isEmpty && active > 0 && !cancellation.isCancelled {
            _ = workCondition.wait(until: Date().addingTimeInterval(0.1))
        }
        guard !cancellation.isCancelled, let job = jobs.popLast() else { return nil }
        active += 1
        return job
    }

    func finishCancelled() {
        workCondition.lock(); defer { workCondition.unlock() }
        active -= 1
        workCondition.broadcast()
    }

    func finishFailed(job: Job, error: Error) {
        stateLock.lock()
        let path = job.packageOwner ?? job.path
        if let code = (error as? POSIXError)?.code, code == .EACCES || code == .EPERM {
            snapshot.items[path]?.isAccessDenied = true
        }
        addDirectTotals(to: path, bytes: 0, allocated: 0, count: 0, skipped: 1)
        progress.skippedCount += 1
        publish()
        stateLock.unlock()

        workCondition.lock()
        active -= 1
        workCondition.broadcast()
        workCondition.unlock()
    }

    func consume(
        job: Job,
        listing: FileSystemDirectoryListing,
        entries: [StorageExplorerScannedEntry]
    ) {
        let discoveredJobs = entries.compactMap { entry -> Job? in
            guard entry.isDirectory, !entry.isCloudPlaceholder, entry.metadata.devid == device else { return nil }
            return Job(path: entry.path, packageOwner: job.packageOwner ?? (entry.isPackage ? entry.path : nil))
        }

        stateLock.lock()
        let owner = job.packageOwner ?? job.path
        var bytes: Int64 = 0
        var allocated: Int64 = 0
        var skipped = listing.skippedCount + listing.entries.count - entries.count
        var retainedDirectorySkips = 0
        for var scannedEntry in entries {
            let entry = scannedEntry.metadata
            var defersHardLinkAccounting = false
            if !scannedEntry.isDirectory, (entry.linkCount ?? 1) > 1,
               let device = entry.devid, let inode = entry.fileID {
                let key = StorageFileInode(device: dev_t(truncatingIfNeeded: device), inode: ino_t(inode))
                // Directory workers finish in nondeterministic order. Defer the one charged
                // hard-link path until all candidates are known, then choose it by path.
                let candidate = HardLinkCandidate(
                    entry: scannedEntry,
                    accountingOwner: owner,
                    fileTypeParent: job.packageOwner == nil ? job.path : nil
                )
                if hardLinkCandidates[key].map({ candidate.entry.path < $0.entry.path }) ?? true {
                    hardLinkCandidates[key] = candidate
                }
                scannedEntry.size = 0
                scannedEntry.allocatedSize = 0
                defersHardLinkAccounting = true
            }
            if scannedEntry.isDirectory {
                if scannedEntry.isCloudPlaceholder || entry.devid != device {
                    scannedEntry.skippedCount = 1
                    skipped += 1
                    if job.packageOwner == nil { retainedDirectorySkips += 1 }
                }
            }
            bytes += scannedEntry.size
            allocated += scannedEntry.allocatedSize
            if job.packageOwner == nil, scannedEntry.isDirectory {
                snapshot.apply([scannedEntry.makeItem()])
                changed.insert(scannedEntry.path)
            } else if job.packageOwner == nil {
                recordFile(scannedEntry, parentPath: job.path, retain: !defersHardLinkAccounting)
            }
        }
        snapshot.items[owner]?.childCount += entries.count
        // Retained directories contribute their skips when folded into ancestors at completion.
        // Package contents have no retained nodes, so their skips belong directly to the owner.
        addDirectTotals(to: owner, bytes: bytes, allocated: allocated, count: entries.count,
                        skipped: skipped - retainedDirectorySkips)
        progress.filesScanned += entries.count
        progress.bytesScanned += bytes
        progress.allocatedBytesScanned += allocated
        progress.skippedCount += skipped
        progress.currentPath = job.path
        publish()
        stateLock.unlock()

        workCondition.lock()
        jobs.append(contentsOf: discoveredJobs)
        workCondition.broadcast()
        workCondition.unlock()
    }

    func finish(cached: Bool) {
        stateLock.lock()
        progress.cachedDirectories += cached ? 1 : 0
        publish()
        stateLock.unlock()
        workCondition.lock()
        active -= 1
        workCondition.broadcast()
        workCondition.unlock()
    }

    private func addDirectTotals(to path: String, bytes: Int64, allocated: Int64, count: Int, skipped: Int) {
        guard var item = snapshot.items[path] else { return }
        item.size += bytes
        item.allocatedSize += allocated
        item.scannedCount += count
        item.skippedCount += skipped
        snapshot.items[path] = item
        changed.insert(path)
    }

    private func publish(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.15 else { return }
        lastReport = now
        progress.elapsed = now.timeIntervalSince(started)
        update(StorageExplorerScanUpdate(items: changed.compactMap { snapshot.items[$0] }, progress: progress))
        changed.removeAll(keepingCapacity: true)
    }

    func result() throws -> StorageExplorerSnapshot {
        progress.phase = .finalizing
        publish(force: true)
        try checkCancellation()
        try applyDeterministicHardLinkAccounting()
        if !publishesItems {
            let retained = retainedFiles.items + Array(largestFileByDirectory.values)
            let unique = Dictionary(grouping: retained, by: \StorageExplorerScannedEntry.path).compactMap(\.value.first)
            snapshot.apply(unique.map { $0.makeItem() })
        }
        // Each directory records only the entries read directly from it while scanning. Folding
        // completed directories into their parents once avoids walking every ancestor while the
        // filesystem workers are contending for the shared scan-state lock.
        let directoryItems = snapshot.items.values.filter {
            $0.isDirectory && $0.path != snapshot.rootPath
        }
        var completedDirectories: [(item: StorageItem, depth: Int)] = directoryItems.map { item in
            let depth = item.path.split(separator: "/", omittingEmptySubsequences: true).count
            return (item: item, depth: depth)
        }
        completedDirectories.sort { lhs, rhs in
            if lhs.depth == rhs.depth {
                return lhs.item.path < rhs.item.path
            }
            return lhs.depth > rhs.depth
        }
        for (index, value) in completedDirectories.enumerated() {
            if index.isMultiple(of: 512) {
                try checkCancellation()
                publish()
            }
            let directory = snapshot.items[value.item.path] ?? value.item
            guard let parentPath = directory.parentPath,
                  var parent = snapshot.items[parentPath]
            else { continue }
            parent.size += directory.size
            parent.allocatedSize += directory.allocatedSize
            parent.scannedCount += directory.scannedCount
            parent.skippedCount += directory.skippedCount
            snapshot.items[parentPath] = parent
        }
        for (index, path) in snapshot.items.keys.enumerated() {
            if index.isMultiple(of: 512) {
                try checkCancellation()
                publish()
            }
            let incomplete = (snapshot.items[path]?.skippedCount ?? 0) > 0
            snapshot.items[path]?.isIncomplete = incomplete
            changed.insert(path)
        }
        try foldFileTypeTotals(directories: completedDirectories.map { $0.item })
        publish(force: true)
        snapshot.progress = progress
        return snapshot
    }

    private func applyDeterministicHardLinkAccounting() throws {
        for (index, canonical) in hardLinkCandidates.values.enumerated() {
            if index.isMultiple(of: 512) {
                try checkCancellation()
                publish()
            }
            let logical = canonical.entry.size
            let allocated = canonical.entry.allocatedSize
            addDirectTotals(
                to: canonical.accountingOwner,
                bytes: logical,
                allocated: allocated,
                count: 0,
                skipped: 0
            )
            progress.bytesScanned += logical
            progress.allocatedBytesScanned += allocated

            if let parentPath = canonical.fileTypeParent {
                if collectsFileTypeTotals {
                    let kind = canonical.entry.fileExtension.isEmpty ? "—" : canonical.entry.fileExtension
                    var totals = directFileTypeTotals[parentPath, default: [:]][kind, default: StorageExplorerSizeTotals()]
                    totals.size += logical
                    totals.allocatedSize += allocated
                    directFileTypeTotals[parentPath, default: [:]][kind] = totals
                }
                if publishesItems {
                    snapshot.items[canonical.entry.path] = canonical.entry.makeItem()
                    changed.insert(canonical.entry.path)
                } else {
                    retainedFiles.insert(canonical.entry)
                    if let existing = largestFileByDirectory[parentPath] {
                        if retainedFiles.value(of: canonical.entry) > retainedFiles.value(of: existing) {
                            largestFileByDirectory[parentPath] = canonical.entry
                        }
                    } else {
                        largestFileByDirectory[parentPath] = canonical.entry
                    }
                }
            }
        }
    }

    private func recordFile(_ item: StorageExplorerScannedEntry, parentPath: String, retain: Bool = true) {
        if collectsFileTypeTotals {
            let kind = item.isPackage ? "package" : (item.fileExtension.isEmpty ? "—" : item.fileExtension)
            var totals = directFileTypeTotals[parentPath, default: [:]][kind, default: StorageExplorerSizeTotals()]
            totals.size += item.size
            totals.allocatedSize += item.allocatedSize
            totals.count += 1
            directFileTypeTotals[parentPath, default: [:]][kind] = totals
        }
        if publishesItems {
            snapshot.apply([item.makeItem()])
            changed.insert(item.path)
        } else if retain {
            retainedFiles.insert(item)
            if let existing = largestFileByDirectory[parentPath] {
                if retainedFiles.value(of: item) > retainedFiles.value(of: existing) {
                    largestFileByDirectory[parentPath] = item
                }
            } else {
                largestFileByDirectory[parentPath] = item
            }
        }
    }

    private func foldFileTypeTotals(directories: [StorageItem]) throws {
        guard collectsFileTypeTotals else { return }
        var totals = directFileTypeTotals
        for (index, directory) in directories.enumerated() {
            if index.isMultiple(of: 512) {
                try checkCancellation()
                publish()
            }
            guard let parentPath = directory.parentPath else { continue }
            for (kind, value) in totals[directory.path] ?? [:] {
                totals[parentPath, default: [:]][kind, default: StorageExplorerSizeTotals()].add(value)
            }
            if directory.isPackage {
                totals[parentPath, default: [:]]["package", default: StorageExplorerSizeTotals()].add(directory)
            }
        }
        snapshot.fileTypeTotalsByDirectory = totals
        snapshot.fileTypeTotals = totals[snapshot.rootPath] ?? [:]
    }

    private func checkCancellation() throws {
        if cancellation.isCancelled { throw CancellationError() }
    }

    static func identity(for entry: FileSystemBulkAttributeEntry) -> StorageFileInode? {
        guard let device = entry.devid, let inode = entry.fileID else { return nil }
        return StorageFileInode(device: dev_t(truncatingIfNeeded: device), inode: ino_t(inode))
    }
}

private final class StorageExplorerLargestFileHeap {
    private let limit: Int
    private var heap: [StorageExplorerScannedEntry] = []

    init(limit: Int) { self.limit = limit }
    var items: [StorageExplorerScannedEntry] { heap }
    func value(of item: StorageExplorerScannedEntry) -> Int64 { max(item.size, item.allocatedSize) }

    func insert(_ item: StorageExplorerScannedEntry) {
        if heap.count < limit {
            heap.append(item)
            siftUp(from: heap.count - 1)
        } else if let first = heap.first, value(of: item) > value(of: first) {
            heap[0] = item
            siftDown(from: 0)
        }
    }

    private func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard value(of: heap[child]) < value(of: heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { return }
            let right = left + 1
            let child = right < heap.count && value(of: heap[right]) < value(of: heap[left]) ? right : left
            guard value(of: heap[child]) < value(of: heap[parent]) else { return }
            heap.swapAt(parent, child)
            parent = child
        }
    }
}
