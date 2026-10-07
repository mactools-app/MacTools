import Darwin
import Foundation

// MARK: - Target kinds

/// Developer-artifact kind (design §10.1).
///
/// Each kind binds a set of **project markers**: only a same-level marker file counts as a hit.
/// That is the only false-positive defense—`~/Documents/build` may well be a photo folder, and
/// so may `~/Pictures/dist`; a wrong delete costs far more than a miss.
/// `__pycache__` is the only unconditional kind: CPython owns that name exclusively, so there is
/// no ambiguity.
enum DiskCleanPurgeKind: String, CaseIterable, Equatable, Sendable {
    case nodeModules
    case rustTarget
    case buildOutput
    case distOutput
    case pythonCache

    /// Directory name. Classification looks only at this name, not the rest of the path.
    var directoryName: String {
        switch self {
        case .nodeModules:
            return "node_modules"
        case .rustTarget:
            return "target"
        case .buildOutput:
            return "build"
        case .distOutput:
            return "dist"
        case .pythonCache:
            return "__pycache__"
        }
    }

    /// Sibling project-marker candidates: any one match is enough. Empty array means unconditional.
    var projectMarkers: [String] {
        switch self {
        case .nodeModules:
            return ["package.json"]
        case .rustTarget:
            return ["Cargo.toml"]
        case .buildOutput, .distOutput:
            return ["package.json", "setup.py", "pyproject.toml"]
        case .pythonCache:
            return []
        }
    }

    var displayName: String {
        switch self {
        case .nodeModules:
            return "Node 依赖"
        case .rustTarget:
            return "Rust 编译产物"
        case .buildOutput:
            return "构建输出"
        case .distOutput:
            return "打包输出"
        case .pythonCache:
            return "Python 字节码缓存"
        }
    }

    /// Stable synthetic target ID (`DiskCleanRuleCatalogV2` builds targets from this).
    /// Written as-is into audit logs; changing it changes historical record semantics.
    var targetID: String {
        "purge." + directoryName
    }

    /// Directory name → kind. Names are unique, so use a dictionary rather than sequential compares.
    static let byDirectoryName: [String: DiskCleanPurgeKind] = Dictionary(
        uniqueKeysWithValues: DiskCleanPurgeKind.allCases.map { ($0.directoryName, $0) }
    )
}

// MARK: - Git state

/// Git state of the repository containing the candidate (design §10.1 git warning).
///
/// **Fail-safe direction is fixed**: if inspection fails, treat as dirty. A false "dirty" only
/// skips default selection (user can still check); a false "clean" may let users unknowingly
/// delete workspace state that uncommitted build artifacts depend on.
enum DiskCleanPurgeGitState: Equatable, Sendable {
    /// No `.git` found within the root boundary. No badge; treat as a normal candidate.
    case notInRepository
    case clean(repositoryPath: String)
    case dirty(repositoryPath: String, reason: DirtyReason)

    enum DirtyReason: Equatable, Sendable {
        /// `git status --porcelain -unormal` produced output.
        case uncommittedChanges
        /// `git log --branches --not --remotes` produced output.
        case unpushedCommits
        /// git missing, timed out (2s), or non-zero exit—treat as dirty.
        case inspectionFailed(String)
    }

    var isDirty: Bool {
        if case .dirty = self { return true }
        return false
    }

    var repositoryPath: String? {
        switch self {
        case .notInRepository:
            return nil
        case let .clean(repositoryPath):
            return repositoryPath
        case let .dirty(repositoryPath, _):
            return repositoryPath
        }
    }
}

// MARK: - Discovery results

/// One hit from the traversal phase. Git check and sizing are not done yet—both are filled in later.
struct DiskCleanPurgeDiscoveredItem: Equatable, Sendable {
    /// **Physical path**: root is `realpath`-normalized and each level is opened no-follow, so the
    /// joined result has no symlink ancestors and can go straight to sizing and removal primitives
    /// (design §13-6).
    let path: String
    let kind: DiskCleanPurgeKind
    /// Project-marker filename that matched. `__pycache__` is unconditional, so nil.
    let projectMarker: String?
    /// Directory containing the marker—the project root.
    let projectPath: String
    /// Nearest `.git` ancestor (including the scan root itself; never past the root boundary).
    /// nil = not in a repository.
    let repositoryPath: String?
}

/// Traversal status of a single scan root.
enum DiskCleanPurgeRootStatus: Equatable, Sendable {
    /// Never opened—directory deleted, TCC denied, or non-local volume. UI must distinguish this
    /// from "scanned but no candidates".
    case unreadable(reason: DiskCleanScanCompleteness.PartialReason)
    /// Traversed. `completeness` records subtrees skipped along the way (permission, mount point;
    /// depth truncation is not counted).
    case traversed(completeness: DiskCleanScanCompleteness)
}

struct DiskCleanPurgeDiscoveryReport: Equatable, Sendable {
    let root: String
    let status: DiskCleanPurgeRootStatus
    let items: [DiskCleanPurgeDiscoveredItem]
}

/// Full candidate description with git state. Stage two mints a unified-pipeline `DiskCleanCandidate` from this.
struct DiskCleanPurgeCandidate: Identifiable, Equatable, Sendable {
    let item: DiskCleanPurgeDiscoveredItem
    let gitState: DiskCleanPurgeGitState

    var id: String { item.path }
    var path: String { item.path }
    var kind: DiskCleanPurgeKind { item.kind }
    var projectMarker: String? { item.projectMarker }
    var projectPath: String { item.projectPath }

    /// Default-selection policy: not selected when the repo is dirty (including inspection failure); otherwise selected.
    var isSelectedByDefault: Bool { !gitState.isDirty }
}

struct DiskCleanPurgeRootReport: Equatable, Sendable {
    let root: String
    let status: DiskCleanPurgeRootStatus
    let candidates: [DiskCleanPurgeCandidate]
}

struct DiskCleanPurgeScanResult: Equatable, Sendable {
    let reports: [DiskCleanPurgeRootReport]

    var candidates: [DiskCleanPurgeCandidate] {
        reports.flatMap(\.candidates)
    }

    /// Roots that could not be opened at all. UI uses this for "folder removed or no access" rather than an empty list.
    var unreadableRoots: [String] {
        reports.compactMap { report in
            if case .unreadable = report.status { return report.root }
            return nil
        }
    }
}

// MARK: - Traversal

/// Developer-artifact discovery walk (design §10.1). **Blocking**; called by `DiskCleanPurgeScanner`
/// on a background queue.
///
/// Uses fd-relative bulk metadata with a `readdir` fallback rather than `FileManager.enumerator`:
/// the latter has no no-follow or device constraints and will follow symlinks out of the scan root
/// and silently cross mount points. This is discovery only and deletes nothing, but produced paths
/// go straight to removal primitives, so they must be trustworthy physical paths.
///
/// Depth cap is 6 levels; prune on hit: `node_modules` contains thousands of nested `node_modules`,
/// and reporting any from the second level on is pointless—deleting the outer one already deletes them.
struct DiskCleanPurgeDiscovery: Sendable {
    static let defaultMaximumDepth = 6

    /// Maximum depth at which candidates can match (root is 0). Directories at the cap still
    /// participate in matching but are not enumerated further.
    let maximumDepth: Int
    private let opener: DiskCleanRootOpener
    private let sourceFactory: any DiskCleanDirectoryEntrySourceFactory

    init(
        maximumDepth: Int = defaultMaximumDepth,
        opener: DiskCleanRootOpener = DiskCleanRootOpener(),
        sourceFactory: any DiskCleanDirectoryEntrySourceFactory = DiskCleanDiscoveryEntrySourceFactory()
    ) {
        self.maximumDepth = max(maximumDepth, 1)
        self.opener = opener
        self.sourceFactory = sourceFactory
    }

    func discover(root: String, isCancelled: () -> Bool = { false }) -> DiskCleanPurgeDiscoveryReport {
        switch opener.open(path: root) {
        case let .failed(reason):
            return DiskCleanPurgeDiscoveryReport(root: root, status: .unreadable(reason: reason), items: [])

        case .resolved:
            // Root is not a directory (file / symlink / socket). Nothing to traverse; report unreadable honestly.
            return DiskCleanPurgeDiscoveryReport(root: root, status: .unreadable(reason: .walkError), items: [])

        case let .directory(fileDescriptor, identity):
            var state = TraversalState(rootDevice: identity.devid)
            let rootRepository = Self.containsGitEntry(directoryFileDescriptor: fileDescriptor) ? root : nil
            visit(
                fileDescriptor: fileDescriptor,
                path: root,
                depth: 0,
                repositoryPath: rootRepository,
                isCancelled: isCancelled,
                state: &state
            )
            // readdir order is filesystem-defined; sorting stabilizes both the list and tests.
            return DiskCleanPurgeDiscoveryReport(
                root: root,
                status: .traversed(completeness: state.accumulator.completeness),
                items: state.items.sorted { $0.path < $1.path }
            )
        }
    }

    // MARK: Internals

    private struct TraversalState {
        let rootDevice: UInt64
        var items: [DiskCleanPurgeDiscoveredItem] = []
        var accumulator = DiskCleanCompletenessAccumulator()
    }

    /// Recursion rather than an explicit stack: with depth cap 6, stack and fd use stay constant-
    /// scale and the readability is worth it (executor delete prewalk caps at 128 and must use an
    /// explicit stack there).
    ///
    /// Takes ownership of `fileDescriptor`.
    private func visit(
        fileDescriptor: Int32,
        path: String,
        depth: Int,
        repositoryPath: String?,
        isCancelled: () -> Bool,
        state: inout TraversalState
    ) {
        let source: any DiskCleanDirectoryEntrySource
        do {
            source = try sourceFactory.makeSource(fileDescriptor: fileDescriptor)
        } catch {
            // Protocol contract: on makeSource throw, fd ownership remains with the caller.
            close(fileDescriptor)
            state.accumulator.add(errno: (error as? DiskCleanPOSIXError)?.code ?? EIO)
            return
        }
        defer { source.close() }

        while true {
            guard !isCancelled() else {
                // Same cancel exit as sizing: mark result incomplete so the caller knows this is not "finished empty".
                state.accumulator.add(.timedOut)
                return
            }

            let batch: [DiskCleanWalkEntry]?
            do {
                batch = try source.nextBatch()
            } catch {
                state.accumulator.add(errno: (error as? DiskCleanPOSIXError)?.code ?? EIO)
                return
            }
            guard let batch else { return }

            for entry in batch {
                guard case let .resolved(resolved) = entry else {
                    state.accumulator.add(.walkError)
                    continue
                }
                // Never follow or report symlinks: following leaves the scan root; reporting would make users think the target is deleted.
                guard resolved.fileType == .directory else { continue }
                guard let name = Self.name(of: resolved) else {
                    // Filename is not valid UTF-8 and cannot safely become a candidate path. Skip one tree; fail-safe.
                    state.accumulator.add(.walkError)
                    continue
                }

                let childPath = path + "/" + name
                let childDepth = depth + 1

                if let kind = DiskCleanPurgeKind.byDirectoryName[name],
                   let match = Self.projectMarker(for: kind, directoryFileDescriptor: source.directoryFileDescriptor) {
                    state.items.append(
                        DiskCleanPurgeDiscoveredItem(
                            path: childPath,
                            kind: kind,
                            projectMarker: match.markerName,
                            projectPath: path,
                            repositoryPath: repositoryPath
                        )
                    )
                    continue  // prune on hit
                }

                guard childDepth < maximumDepth else { continue }
                guard resolved.devid == state.rootDevice else {
                    // Do not descend into mount points: another volume has its own free space and permission model; scan-root authorization does not cover it.
                    state.accumulator.add(.crossedMountPoint)
                    continue
                }

                descend(
                    name: resolved.nameBytes,
                    parentFileDescriptor: source.directoryFileDescriptor,
                    childPath: childPath,
                    depth: childDepth,
                    inheritedRepositoryPath: repositoryPath,
                    isCancelled: isCancelled,
                    state: &state
                )
            }
        }
    }

    private func descend(
        name: [CChar],
        parentFileDescriptor: Int32,
        childPath: String,
        depth: Int,
        inheritedRepositoryPath: String?,
        isCancelled: () -> Bool,
        state: inout TraversalState
    ) {
        // Single-component `openat` + `O_NOFOLLOW`: if the entry becomes a symlink between readdir and open, fail with ELOOP.
        let childDescriptor = name.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return openat(parentFileDescriptor, base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard childDescriptor >= 0 else {
            state.accumulator.add(errno: errno)
            return
        }

        // Nearest `.git` overrides the inherited value: nested repos (submodules, independent monorepo repos) use the nearest.
        let repositoryPath = Self.containsGitEntry(directoryFileDescriptor: childDescriptor)
            ? childPath
            : inheritedRepositoryPath

        visit(
            fileDescriptor: childDescriptor,
            path: childPath,
            depth: depth,
            repositoryPath: repositoryPath,
            isCancelled: isCancelled,
            state: &state
        )
    }

    /// Project-marker match result. `unconditional` must be distinct from "matched a marker":
    /// the former has no marker basis to show in the candidate description, not "marker is empty string".
    private enum MarkerMatch {
        case unconditional
        case matched(String)

        var markerName: String? {
            if case let .matched(name) = self { return name }
            return nil
        }
    }

    /// Returns nil = no match, not a candidate.
    private static func projectMarker(
        for kind: DiskCleanPurgeKind,
        directoryFileDescriptor: Int32
    ) -> MarkerMatch? {
        guard !kind.projectMarkers.isEmpty else { return .unconditional }
        for marker in kind.projectMarkers
        where existsAsFile(name: marker, directoryFileDescriptor: directoryFileDescriptor) {
            return .matched(marker)
        }
        return nil
    }

    /// Marker must be a file or symlink, not a directory: in monorepos `package.json` may be a
    /// symlink, but a **directory** named `package.json` is only a coincidence, not a project root.
    private static func existsAsFile(name: String, directoryFileDescriptor: Int32) -> Bool {
        var status = stat()
        guard fstatat(directoryFileDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return DiskCleanRootIdentity.FileType(mode: status.st_mode) != .directory
    }

    /// `.git` may be a directory (normal repo) or a file (worktree / submodule gitdir pointer); both count.
    private static func containsGitEntry(directoryFileDescriptor: Int32) -> Bool {
        var status = stat()
        return fstatat(directoryFileDescriptor, ".git", &status, AT_SYMLINK_NOFOLLOW) == 0
    }

    private static func name(of entry: DiskCleanResolvedEntry) -> String? {
        let bytes = entry.nameBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        // Prefer String(bytes:encoding:) over String(decoding:): the latter replaces invalid bytes
        // with U+FFFD, producing a path to a non-existent file that is useless to removal primitives.
        return String(bytes: bytes, encoding: .utf8)
    }
}

// MARK: - Git inspection

/// Repository dirty-state check. Both commands use the `DiskCleanSubprocessRunning` seam with a 2s timeout (design §10.1).
struct DiskCleanGitStatusInspector: Sendable {
    static let executablePath = "/usr/bin/git"
    static let timeout = Duration.seconds(2)

    private let runner: any DiskCleanSubprocessRunning

    init(runner: any DiskCleanSubprocessRunning = LocalDiskCleanSubprocessRunner()) {
        self.runner = runner
    }

    func inspect(repositoryPath: String) async -> DiskCleanPurgeGitState {
        do {
            let status = try await run(
                arguments: ["-C", repositoryPath, "status", "--porcelain", "-unormal"]
            )
            guard status.exitCode == 0 else {
                return .dirty(repositoryPath: repositoryPath, reason: .inspectionFailed("status 退出码 \(status.exitCode)"))
            }
            if !Self.isBlank(status.standardOutput) {
                return .dirty(repositoryPath: repositoryPath, reason: .uncommittedChanges)
            }

            // Unpushed commits: commits on local branches not on any remote. One is enough, hence -n 1.
            let unpushed = try await run(
                arguments: ["-C", repositoryPath, "log", "--branches", "--not", "--remotes", "-n", "1"]
            )
            guard unpushed.exitCode == 0 else {
                return .dirty(repositoryPath: repositoryPath, reason: .inspectionFailed("log 退出码 \(unpushed.exitCode)"))
            }
            if !Self.isBlank(unpushed.standardOutput) {
                return .dirty(repositoryPath: repositoryPath, reason: .unpushedCommits)
            }
            return .clean(repositoryPath: repositoryPath)
        } catch {
            return .dirty(repositoryPath: repositoryPath, reason: .inspectionFailed(Self.describe(error)))
        }
    }

    private func run(arguments: [String]) async throws -> DiskCleanSubprocessResult {
        try await runner.run(
            executablePath: Self.executablePath,
            arguments: arguments,
            timeout: Self.timeout
        )
    }

    /// Only blank output counts as clean: git emits empty string with no changes; shell-wrapped paths may add a newline.
    private static func isBlank(_ output: Data) -> Bool {
        String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DiskCleanSubprocessError.timedOut:
            return "git 检查超时"
        case DiskCleanSubprocessError.executableUnavailable:
            return "未找到 git"
        case let DiskCleanSubprocessError.launchFailed(_, message):
            return "git 启动失败：\(message)"
        default:
            return "git 检查失败"
        }
    }
}

// MARK: - Scanner

/// Developer-artifact purge scanner (design §10.1).
///
/// Orchestrates two jobs: blocking traversal on a background thread, and one git inspection per
/// repository (a single repo often has dozens of `node_modules`; spawning per item would multiply
/// the 2s timeout by dozens).
struct DiskCleanPurgeScanner: Sendable {
    private let discovery: DiskCleanPurgeDiscovery
    private let inspector: DiskCleanGitStatusInspector

    init(
        discovery: DiskCleanPurgeDiscovery = DiskCleanPurgeDiscovery(),
        inspector: DiskCleanGitStatusInspector = DiskCleanGitStatusInspector()
    ) {
        self.discovery = discovery
        self.inspector = inspector
    }

    func scan(roots: [String]) async -> DiskCleanPurgeScanResult {
        var reports: [DiskCleanPurgeRootReport] = []
        var inspectedRepositories: [String: DiskCleanPurgeGitState] = [:]

        for root in roots {
            let discovered = await discoverInBackground(root: root)
            var candidates: [DiskCleanPurgeCandidate] = []
            candidates.reserveCapacity(discovered.items.count)

            for item in discovered.items {
                guard let repository = item.repositoryPath else {
                    candidates.append(DiskCleanPurgeCandidate(item: item, gitState: .notInRepository))
                    continue
                }
                let state: DiskCleanPurgeGitState
                if let cached = inspectedRepositories[repository] {
                    state = cached
                } else {
                    state = await inspector.inspect(repositoryPath: repository)
                    inspectedRepositories[repository] = state
                }
                candidates.append(DiskCleanPurgeCandidate(item: item, gitState: state))
            }

            reports.append(
                DiskCleanPurgeRootReport(root: root, status: discovered.status, candidates: candidates)
            )
        }

        return DiskCleanPurgeScanResult(reports: reports)
    }

    /// Traversal blocks in `readdir`/`openat` and must not occupy Swift concurrency's cooperative
    /// thread pool. Depth cap 6 bounds the cost, so WorkerPool abandon budgets are unnecessary—
    /// that machinery is for sizing that can hang forever.
    ///
    /// Blocking traversal does not observe `Task.isCancelled`; cancel sets `DiskCleanCancellationFlag`
    /// (same as WorkerPool) and traversal polls it per batch.
    private func discoverInBackground(root: String) async -> DiskCleanPurgeDiscoveryReport {
        let flag = DiskCleanCancellationFlag()
        let discovery = self.discovery
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(
                        returning: discovery.discover(root: root, isCancelled: { flag.isSet })
                    )
                }
            }
        } onCancel: {
            flag.set()
        }
    }
}
