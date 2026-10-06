import AppKit
import Darwin
import Foundation
import MacToolsFileSystem

/// Read-only measurement of the catalog. Blocking filesystem work runs on
/// bounded GCD workers outside Swift's cooperative executor.
public protocol SystemDataScanning: Sendable {
    func scan(
        progress: @escaping @Sendable (SystemDataScanProgress) -> Void
    ) async throws -> SystemDataScanResult
}

public struct SystemDataScanner: SystemDataScanning {
    public struct Configuration: Sendable {
        public let catalog: [SystemDataGroupDefinition]
        public let homeDirectory: String
        public let workerCount: Int
        public let progressInterval: TimeInterval

        public init(
            catalog: [SystemDataGroupDefinition] = SystemDataCatalog.groups,
            homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
            workerCount: Int? = nil,
            progressInterval: TimeInterval = 0.25
        ) {
            self.catalog = catalog
            self.homeDirectory = homeDirectory
            self.workerCount = workerCount
                ?? min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
            self.progressInterval = progressInterval
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func scan(
        progress: @escaping @Sendable (SystemDataScanProgress) -> Void
    ) async throws -> SystemDataScanResult {
        try Task.checkCancellation()
        let jobs = Self.makeJobs(catalog: configuration.catalog)
        guard !jobs.isEmpty else {
            return SystemDataScanResult(results: [], availableBytes: nil, capacityBytes: nil, finishedAt: Date())
        }

        let state = ScanState(
            totalItems: jobs.count,
            progressInterval: configuration.progressInterval,
            report: progress
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Self.run(jobs: jobs, configuration: self.configuration, state: state))
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    // MARK: - Jobs

    private struct ScanJob: Sendable {
        let index: Int
        let itemID: String
        let path: String
        let kind: SystemDataItemKind
        let pathResolver: SystemDataPathResolver?
    }

    private static func makeJobs(catalog: [SystemDataGroupDefinition]) -> [ScanJob] {
        var jobs: [ScanJob] = []
        for group in catalog {
            for item in group.items {
                jobs.append(
                    ScanJob(
                        index: jobs.count,
                        itemID: item.id,
                        path: item.path,
                        kind: item.kind,
                        pathResolver: item.pathResolver
                    )
                )
            }
        }
        return jobs
    }

    // MARK: - Worker pool

    private static func run(
        jobs: [ScanJob],
        configuration: Configuration,
        state: ScanState
    ) -> Result<SystemDataScanResult, Error> {
        if state.isCancelled {
            return .failure(CancellationError())
        }
        // Publish item counts immediately so the panel never shows a blind
        // "0/0" while the first directories are still being measured.
        state.report(force: true)

        let workerCount = min(configuration.workerCount, jobs.count)
        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            while !state.isCancelled, let index = state.takeNextJobIndex() {
                let job = jobs[index]
                do {
                    let result = try measure(job: job, configuration: configuration, state: state)
                    state.finish(jobIndex: index, result: result)
                } catch {
                    state.cancel()
                    return
                }
            }
        }

        if state.isCancelled {
            return .failure(CancellationError())
        }
        guard let results = state.completedResults(count: jobs.count) else {
            return .failure(CancellationError())
        }
        state.report(force: true)

        let volume = volumeInfo(home: configuration.homeDirectory)
        return .success(
            SystemDataScanResult(
                results: results,
                availableBytes: volume.available,
                capacityBytes: volume.capacity,
                finishedAt: Date()
            )
        )
    }

    private static func measure(
        job: ScanJob,
        configuration: Configuration,
        state: ScanState
    ) throws -> SystemDataJobResult {
        let template = SystemDataCatalog.expand(path: job.path, home: configuration.homeDirectory)
        let resolved = measurementPath(
            template: template,
            resolver: job.pathResolver,
            home: configuration.homeDirectory
        )
        switch job.kind {
        case let .path(excluding):
            let status = measurePath(path: resolved.path, excluding: excluding, state: state)
            return SystemDataJobResult(
                itemID: job.itemID,
                status: status,
                resolvedPath: resolved.reportedPath
            )
        case let .children(excluding):
            let measurement = try measureChildren(
                itemID: job.itemID,
                parentPath: resolved.path,
                excluding: excluding,
                state: state
            )
            return SystemDataJobResult(
                itemID: job.itemID,
                status: measurement.status,
                children: measurement.children,
                resolvedPath: resolved.reportedPath
            )
        }
    }

    // MARK: - Dynamic paths

    /// Applies declared path resolvers before measurement. Only a successful
    /// resolution changes the reported path; failures keep the static template.
    private static func measurementPath(
        template: String,
        resolver: SystemDataPathResolver?,
        home: String
    ) -> (path: String, reportedPath: String?) {
        switch resolver {
        case let .toolOutput(executable, arguments):
            guard let path = toolOutputPath(
                executable: executable,
                arguments: arguments,
                home: home
            ) else {
                return (template, nil)
            }
            return (path, path)
        case nil:
            return (template, nil)
        }
    }

    /// Runs `<executable> <arguments>` and reads the first output line, e.g.
    /// `go env GOMODCACHE` or `uv cache dir`; returns nil when the tool is
    /// missing, fails, times out, or reports something unusable so callers
    /// keep the static template.
    private static func toolOutputPath(
        executable: String,
        arguments: [String],
        home: String
    ) -> String? {
        guard let resolved = findExecutable(named: executable, home: home) else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // A wedged tool must not stall a scan worker forever.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if finished.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return validatedToolOutputPath(from: String(decoding: data, as: UTF8.self))
    }

    private static func findExecutable(named name: String, home: String) -> String? {
        var directories: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        directories.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/local/go/bin",
            "/usr/bin",
            home + "/.local/bin",
        ])
        for directory in directories where !directory.isEmpty {
            let candidate = directory + "/" + name
            if access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return nil
    }

    /// Accepts a single absolute path line; tool output is external input, so
    /// blank, relative, or junk lines keep the static fallback.
    static func validatedToolOutputPath(from output: String) -> String? {
        guard let line = output
            .split(whereSeparator: \.isNewline)
            .first
            .map({ String($0).trimmingCharacters(in: .whitespaces) })
        else { return nil }
        guard !line.isEmpty, line.hasPrefix("/"), !line.contains("\0") else {
            return nil
        }
        return line
    }

    // MARK: - Walking

    private struct WalkOutcome {
        let bytes: Int64
        let failedRoot: Bool
    }

    private static func measurePath(
        path: String,
        excluding: Set<String>,
        state: ScanState
    ) -> SystemDataItemStatus {
        let resolved: String
        switch resolvePath(path) {
        case .missing:
            return .absent
        case .inaccessible:
            // A denied ancestor leaves an existing entry: report it honestly
            // as unreadable instead of hiding it as absent.
            return .unreadable
        case let .resolved(value):
            resolved = value
        }
        do {
            let outcome = try walk(root: resolved, excluding: excluding, state: state)
            // `walk` invalidates the item only when the root itself cannot be
            // opened or every direct subdirectory is policy-blocked; see
            // `shouldReportUnreadable(policyDeniedChildren:readableChildren:)`.
            return outcome.failedRoot ? .unreadable : .measured(bytes: outcome.bytes)
        } catch {
            // Only cancellation escapes `walk`; let it abort the whole scan.
            state.cancel()
            return .unreadable
        }
    }

    /// POSIX permission denials (EPERM from TCC or similar policy) differ from
    /// ordinary EACCES/ENOENT races.
    static func isPermissionDenied(_ error: Error) -> Bool {
        if let posix = error as? POSIXError {
            return posix.code == .EPERM
        }
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain && ns.code == Int(EPERM)
    }

    /// Policy-blocked direct children (EPERM from TCC at depth 1) invalidate
    /// the whole measurement only when not a single direct subdirectory could
    /// be read: then the location's payload — an app container's `Data`, a
    /// fully TCC-protected folder — is entirely hidden, and any total would
    /// be a lie. Trees with at least one readable subdirectory keep measuring
    /// what they can open; deeper denials and ordinary EACCES/ENOENT races
    /// only skip their own subtree.
    static func shouldReportUnreadable(
        policyDeniedChildren: Int,
        readableChildren: Int
    ) -> Bool {
        policyDeniedChildren > 0 && readableChildren == 0
    }

    /// Measures one directory tree with a single allocation accounting pass.
    /// Symlinks are counted as themselves and never followed; files with a link
    /// count above one are counted once per walk.
    private static func walk(
        root: String,
        excluding: Set<String>,
        state: ScanState
    ) throws -> WalkOutcome {
        var status = stat()
        guard lstat(root, &status) == 0 else {
            return WalkOutcome(bytes: 0, failedRoot: true)
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            let bytes = max(Int64(status.st_blocks) * 512, 0)
            state.note(directories: 0, bytes: bytes)
            return WalkOutcome(bytes: bytes, failedRoot: false)
        }

        var bytes = max(Int64(status.st_blocks) * 512, 0)
        state.note(directories: 0, bytes: bytes)

        var stack: [(directory: String, depth: Int)] = [(root, 0)]
        var countedHardLinks: Set<HardLinkKey> = []
        var policyDeniedChildren = 0
        var readableChildren = 0

        while let (directory, depth) = stack.popLast() {
            if state.isCancelled { throw CancellationError() }

            let listing: FileSystemDirectoryListing
            do {
                listing = try FileSystemDirectoryReader.read(path: directory) { state.isCancelled }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if depth == 0 {
                    // The location itself cannot be opened at all.
                    return WalkOutcome(bytes: 0, failedRoot: true)
                }
                if depth == 1, isPermissionDenied(error) {
                    policyDeniedChildren += 1
                }
                // A single unreadable subdirectory makes that subtree partial,
                // never a failure of the whole item. Whether the item as a
                // whole is untrustworthy is decided after the walk from the
                // policy-denial and readable-child counts.
                state.note(directories: 0, bytes: 0, unreadableDirectories: 1)
                continue
            }
            if depth == 1 { readableChildren += 1 }
            state.note(directories: 1, bytes: 0)

            var directoryBytes: Int64 = 0
            for entry in listing.entries {
                guard let name = entry.displayName else { continue }
                if directory == root, excluding.contains(name) { continue }

                switch entry.fileType {
                case .directory:
                    directoryBytes += entry.allocatedSize ?? 0
                    stack.append((directory + "/" + name, depth + 1))
                case .regularFile:
                    if let linkCount = entry.linkCount, linkCount > 1,
                       let devid = entry.devid, let fileID = entry.fileID {
                        let key = HardLinkKey(devid: devid, fileID: fileID)
                        if !countedHardLinks.insert(key).inserted { continue }
                    }
                    directoryBytes += entry.allocatedSize ?? 0
                case .symlink, .other, nil:
                    break
                }
            }
            bytes += directoryBytes
            state.note(directories: 0, bytes: directoryBytes)
        }
        if shouldReportUnreadable(
            policyDeniedChildren: policyDeniedChildren,
            readableChildren: readableChildren
        ) {
            // Every direct subdirectory is policy-blocked: the location's
            // payload is hidden, so report the item unreadable instead of a
            // silently partial size.
            return WalkOutcome(bytes: 0, failedRoot: true)
        }
        return WalkOutcome(bytes: bytes, failedRoot: false)
    }

    private static func measureChildren(
        itemID: String,
        parentPath: String,
        excluding: Set<String>,
        state: ScanState
    ) throws -> (status: SystemDataItemStatus, children: [SystemDataChildMeasurement]) {
        let resolved: String
        switch resolvePath(parentPath) {
        case .missing:
            return (.absent, [])
        case .inaccessible:
            return (.unreadable, [])
        case let .resolved(value):
            resolved = value
        }

        var parentStatus = stat()
        guard lstat(resolved, &parentStatus) == 0 else { return (.absent, []) }
        guard (parentStatus.st_mode & S_IFMT) == S_IFDIR else {
            let outcome = try walk(root: resolved, excluding: [], state: state)
            return (outcome.failedRoot ? .unreadable : .measured(bytes: outcome.bytes), [])
        }

        let listing: FileSystemDirectoryListing
        do {
            listing = try FileSystemDirectoryReader.read(path: resolved) { state.isCancelled }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (.unreadable, [])
        }
        state.note(directories: 1, bytes: 0)

        // The parent's own allocation plus its loose files belong to the group
        // but to no child; keep them in a synthetic entry so totals add up.
        var looseBytes = max(Int64(parentStatus.st_blocks) * 512, 0)
        var countedHardLinks: Set<HardLinkKey> = []
        var children: [SystemDataChildMeasurement] = []

        for entry in listing.entries {
            if state.isCancelled {
                throw CancellationError()
            }
            guard let name = entry.displayName else { continue }
            if excluding.contains(name) { continue }

            switch entry.fileType {
            case .directory:
                let childPath = resolved + "/" + name
                let outcome = try walk(root: childPath, excluding: [], state: state)
                children.append(
                    SystemDataChildMeasurement(
                        id: itemID + ".child." + name,
                        name: name,
                        path: childPath,
                        bytes: outcome.bytes,
                        isUnreadable: outcome.failedRoot,
                        displayName: Self.resolvedAppName(forDirectoryName: name)
                    )
                )
            case .regularFile:
                if let linkCount = entry.linkCount, linkCount > 1,
                   let devid = entry.devid, let fileID = entry.fileID {
                    let key = HardLinkKey(devid: devid, fileID: fileID)
                    if !countedHardLinks.insert(key).inserted { continue }
                }
                looseBytes += entry.allocatedSize ?? 0
            case .symlink, .other, nil:
                break
            }
        }

        if looseBytes > 0 {
            children.append(
                SystemDataChildMeasurement(
                    id: itemID + ".files",
                    name: "",
                    path: resolved,
                    bytes: looseBytes,
                    isSyntheticFiles: true
                )
            )
        }
        state.note(directories: 0, bytes: 0)
        let total = children.reduce(Int64(0)) { $0 + $1.bytes }
        return (.measured(bytes: total), children)
    }

    // MARK: - App name resolution

    /// A reverse-DNS style directory name such as `com.docker.docker` usually
    /// is a bundle identifier whose owning app has a friendlier display name.
    static func isBundleIdentifierLike(_ name: String) -> Bool {
        guard name.contains("."), !name.hasPrefix("."), !name.hasSuffix(".") else { return false }
        guard !name.contains("..") else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }

    /// Installed-app display name for a bundle identifier, or nil when no app
    /// claims it so callers keep the raw directory name. Runs on scan workers:
    /// LaunchServices queries are thread-safe and fail open to nil.
    static func appDisplayName(forBundleIdentifier bundleID: String) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let bundleName = Bundle(url: appURL).flatMap { bundle -> String? in
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        }
        let candidates = [bundleName, appURL.deletingPathExtension().lastPathComponent]
        return candidates.compactMap { candidate -> String? in
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }.first
    }

    /// Display name for one measured directory: bundle-id-like names resolve
    /// to the installed app's name; anything else returns nil.
    static func resolvedAppName(forDirectoryName name: String) -> String? {
        guard isBundleIdentifierLike(name) else { return nil }
        return appDisplayName(forBundleIdentifier: name)
    }

    // MARK: - Helpers

    private struct HardLinkKey: Hashable {
        let devid: UInt64
        let fileID: UInt64
    }

    private enum PathProbe {
        case resolved(String)
        case missing
        case inaccessible
    }

    /// Resolves symlinks and physical-path aliases so the directory reader's
    /// `O_NOFOLLOW_ANY` open succeeds. A denied ancestor (EACCES/EPERM) leaves
    /// an existing entry that must report unreadable; only missing-path
    /// failures report absence.
    private static func resolvePath(_ path: String) -> PathProbe {
        var probe = stat()
        if lstat(path, &probe) != 0 {
            return errno == EACCES || errno == EPERM ? .inaccessible : .missing
        }
        guard let resolved = realpath(path, nil) else { return .resolved(path) }
        defer { free(resolved) }
        return .resolved(String(cString: resolved))
    }

    private static func volumeInfo(home: String) -> (available: Int64?, capacity: Int64?) {
        let url = URL(fileURLWithPath: home)
        if let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]) {
            let available = values.volumeAvailableCapacityForImportantUsage
                .map { Int64($0) }
            let capacity = values.volumeTotalCapacity.map { Int64($0) }
            if available != nil || capacity != nil {
                return (available, capacity)
            }
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: home) {
            let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value
            let total = (attributes[.systemSize] as? NSNumber)?.int64Value
            return (free, total)
        }
        return (nil, nil)
    }
}

// MARK: - Shared scan state

/// Lock-protected worker state. Every field is only read or written under the
/// lock; progress reports are throttled here and delivered outside the lock so
/// the consumer can never be invoked while it is held.
private final class ScanState: @unchecked Sendable {
    private let lock = NSLock()
    private let totalItems: Int
    private let progressInterval: TimeInterval
    private let report: @Sendable (SystemDataScanProgress) -> Void

    private var nextJobIndex = 0
    private var completedItems = 0
    private var directoriesRead = 0
    private var unreadableDirectories = 0
    private var bytesFound: Int64 = 0
    private var results: [SystemDataJobResult?]
    private var cancelled = false
    private var lastReport = Date()

    init(
        totalItems: Int,
        progressInterval: TimeInterval,
        report: @escaping @Sendable (SystemDataScanProgress) -> Void
    ) {
        self.totalItems = totalItems
        self.progressInterval = progressInterval
        self.report = report
        self.results = Array(repeating: nil, count: totalItems)
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func takeNextJobIndex() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard nextJobIndex < totalItems else { return nil }
        let index = nextJobIndex
        nextJobIndex += 1
        return index
    }

    func finish(jobIndex: Int, result: SystemDataJobResult) {
        lock.lock()
        results[jobIndex] = result
        completedItems += 1
        let snapshot = shouldReportLocked(force: false)
        lock.unlock()
        if snapshot.report {
            deliver(snapshot.progress)
        }
    }

    func note(directories: Int, bytes: Int64, unreadableDirectories: Int = 0) {
        guard directories != 0 || bytes != 0 || unreadableDirectories != 0 else { return }
        lock.lock()
        directoriesRead += directories
        bytesFound += bytes
        self.unreadableDirectories += unreadableDirectories
        let snapshot = shouldReportLocked(force: false)
        lock.unlock()
        if snapshot.report {
            deliver(snapshot.progress)
        }
    }

    /// Forces a final progress delivery once every job has been recorded.
    func report(force: Bool) {
        lock.lock()
        let snapshot = shouldReportLocked(force: force)
        lock.unlock()
        if snapshot.report {
            deliver(snapshot.progress)
        }
    }

    func completedResults(count: Int) -> [SystemDataJobResult]? {
        lock.lock()
        defer { lock.unlock() }
        guard results.count == count, results.allSatisfy({ $0 != nil }) else { return nil }
        return results.compactMap { $0 }
    }

    private func shouldReportLocked(force: Bool) -> (report: Bool, progress: SystemDataScanProgress) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= progressInterval else {
            return (false, progressLocked)
        }
        lastReport = now
        return (true, progressLocked)
    }

    private var progressLocked: SystemDataScanProgress {
        SystemDataScanProgress(
            completedItems: completedItems,
            totalItems: totalItems,
            directoriesRead: directoriesRead,
            bytesFound: bytesFound
        )
    }

    private func deliver(_ progress: SystemDataScanProgress) {
        report(progress)
    }
}
