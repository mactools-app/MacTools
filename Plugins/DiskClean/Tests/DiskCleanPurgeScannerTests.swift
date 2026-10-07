import Darwin
import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanPurgeScannerTests: XCTestCase {
    private var temporaryDirectory: DiskCleanTempDirectory!
    private var discovery: DiskCleanPurgeDiscovery!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = try DiskCleanTempDirectory(name: "DiskCleanPurgeScannerTests")
        discovery = DiskCleanPurgeDiscovery()
    }

    override func tearDownWithError() throws {
        temporaryDirectory?.remove()
        temporaryDirectory = nil
        discovery = nil
        try super.tearDownWithError()
    }

    // MARK: - Project-marker decision matrix

    func testFindsNodeModulesWithSiblingPackageManifest() throws {
        try temporaryDirectory.makeFile("root/app/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/app/node_modules")

        let items = try discoverItems()

        XCTAssertEqual(items.map(\.path), [path("root/app/node_modules")])
        XCTAssertEqual(items[0].kind, .nodeModules)
        XCTAssertEqual(items[0].projectMarker, "package.json")
        XCTAssertEqual(items[0].projectPath, path("root/app"))
    }

    /// Without a project marker it is not a build artifact: photo folders like `~/Documents/build` must yield zero hits.
    func testIgnoresBuildDirectoryWithoutProjectMarker() throws {
        try temporaryDirectory.makeFile("root/Documents/build/photo.jpg", bytes: 8)
        try temporaryDirectory.makeFile("root/Documents/dist/poster.png", bytes: 8)
        try temporaryDirectory.makeDirectory("root/Documents/node_modules")
        try temporaryDirectory.makeDirectory("root/Documents/target")

        let items = try discoverItems()

        XCTAssertTrue(items.isEmpty, "unmarked directories must not match, got \(items.map(\.path))")
    }

    func testMatchesEachKindWithItsMarker() throws {
        try temporaryDirectory.makeFile("root/rust/Cargo.toml", bytes: 10)
        try temporaryDirectory.makeDirectory("root/rust/target")
        try temporaryDirectory.makeFile("root/web/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/web/build")
        try temporaryDirectory.makeFile("root/py/setup.py", bytes: 10)
        try temporaryDirectory.makeDirectory("root/py/dist")
        try temporaryDirectory.makeFile("root/modern/pyproject.toml", bytes: 10)
        try temporaryDirectory.makeDirectory("root/modern/build")

        let items = try discoverItems()

        XCTAssertEqual(
            items.map { [$0.path, $0.kind.rawValue, $0.projectMarker ?? "-"] },
            [
                [path("root/modern/build"), "buildOutput", "pyproject.toml"],
                [path("root/py/dist"), "distOutput", "setup.py"],
                [path("root/rust/target"), "rustTarget", "Cargo.toml"],
                [path("root/web/build"), "buildOutput", "package.json"]
            ]
        )
    }

    /// `target` only counts with `Cargo.toml`: an Xcode `target` directory must not look like a Rust artifact.

    func testPrunesNestedCandidatesInsideAHit() throws {
        try temporaryDirectory.makeFile("root/app/package.json", bytes: 10)
        try temporaryDirectory.makeFile("root/app/node_modules/lib/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/app/node_modules/lib/node_modules")
        try temporaryDirectory.makeDirectory("root/app/node_modules/lib/__pycache__")

        let items = try discoverItems()

        XCTAssertEqual(items.map(\.path), [path("root/app/node_modules")])
    }

    /// Depth cap 6: root is 0, depth 6 still participates, depth 7 is not enumerated.
    func testHonorsDepthLimit() throws {
        try temporaryDirectory.makeFile("root/a/b/c/d/e/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/a/b/c/d/e/node_modules")
        try temporaryDirectory.makeFile("root/a/b/c/d/e/f/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/a/b/c/d/e/f/node_modules")

        let items = try discoverItems()

        XCTAssertEqual(items.map(\.path), [path("root/a/b/c/d/e/node_modules")])
    }

    func testDoesNotFollowDirectorySymlink() throws {
        try temporaryDirectory.makeFile("outside/app/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("outside/app/node_modules")
        try temporaryDirectory.makeDirectory("root")
        try temporaryDirectory.makeSymlink("root/link", destination: "../outside")

        let items = try discoverItems()

        XCTAssertTrue(items.isEmpty)
    }

    /// A symlink named `node_modules` is not a candidate: deleting it removes the link, not the dependency tree.

    // MARK: - Root status

    func testReportsPermissionDeniedRoot() throws {
        try temporaryDirectory.makeDirectory("root")
        try temporaryDirectory.denyAccess(to: "root")

        let report = discovery.discover(root: path("root"))

        XCTAssertEqual(report.status, .unreadable(reason: .permissionDenied))
    }

    /// Cancellation must not masquerade as a finished scan: the result must carry timedOut.
    func testCancellationMarksResultIncomplete() throws {
        try temporaryDirectory.makeDirectory("root/a")

        let report = discovery.discover(root: path("root"), isCancelled: { true })

        XCTAssertEqual(report.status, .traversed(completeness: .partial(reasons: [.timedOut])))
        XCTAssertTrue(report.items.isEmpty)
    }

    func testMetadataFailureKeepsDiscoveredItemsButMarksScanIncomplete() throws {
        let root = try temporaryDirectory.makeDirectory("root")
        try temporaryDirectory.makeFile("root/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/node_modules")
        let factory = ScriptedPurgeSourceFactory(scripts: [[[
            .resolved(entry(name: "node_modules", type: .directory, devid: try deviceID(of: root.path), fileID: 77)),
            .unresolved(code: EIO)
        ]]])

        let report = DiskCleanPurgeDiscovery(sourceFactory: factory).discover(root: root.path)

        XCTAssertEqual(report.items.map(\.path), [path("root/node_modules")])
        XCTAssertEqual(report.status, .traversed(completeness: .partial(reasons: [.walkError])))
    }

    // MARK: - Repository attribution

    /// Worktree/submodule `.git` is a file, not a directory, and still counts as a repository.

    // MARK: - Git three-state

    func testMarksRepositoryCleanWhenBothChecksAreEmpty() async throws {
        try makeSingleRepositoryLayout()
        let runner = ScriptedDiskCleanSubprocessRunner()

        let candidate = try await scanSingleCandidate(runner: runner)

        XCTAssertEqual(candidate.gitState, .clean(repositoryPath: path("root/repo")))
        XCTAssertTrue(candidate.isSelectedByDefault)
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(
            runner.invocations[0],
            ["-C", path("root/repo"), "status", "--porcelain", "-unormal"]
        )
        XCTAssertEqual(
            runner.invocations[1],
            ["-C", path("root/repo"), "log", "--branches", "--not", "--remotes", "-n", "1"]
        )
    }

    func testMarksRepositoryDirtyOnUncommittedChanges() async throws {
        try makeSingleRepositoryLayout()
        let runner = ScriptedDiskCleanSubprocessRunner(statusOutput: " M src/main.rs\n")

        let candidate = try await scanSingleCandidate(runner: runner)

        XCTAssertEqual(
            candidate.gitState,
            .dirty(repositoryPath: path("root/repo"), reason: .uncommittedChanges)
        )
        XCTAssertFalse(candidate.isSelectedByDefault)
        XCTAssertEqual(runner.invocations.count, 1, "status already dirty; skip unpushed-commit check")
    }

    func testMarksRepositoryDirtyOnUnpushedCommits() async throws {
        try makeSingleRepositoryLayout()
        let runner = ScriptedDiskCleanSubprocessRunner(logOutput: "9f1c2ab\n")

        let candidate = try await scanSingleCandidate(runner: runner)

        XCTAssertEqual(
            candidate.gitState,
            .dirty(repositoryPath: path("root/repo"), reason: .unpushedCommits)
        )
        XCTAssertFalse(candidate.isSelectedByDefault)
    }

    /// Timeouts are treated as dirty (fail-safe): mistaking unknown state for "clean" risks deleting needed files.
    func testTimeoutIsTreatedAsDirty() async throws {
        try makeSingleRepositoryLayout()
        let runner = ScriptedDiskCleanSubprocessRunner(
            error: DiskCleanSubprocessError.timedOut(path: DiskCleanGitStatusInspector.executablePath)
        )

        let candidate = try await scanSingleCandidate(runner: runner)

        XCTAssertEqual(
            candidate.gitState,
            .dirty(repositoryPath: path("root/repo"), reason: .inspectionFailed("git 检查超时"))
        )
        XCTAssertFalse(candidate.isSelectedByDefault)
    }

    /// A repo often has dozens of `node_modules`; inspecting each multiplies the 2s timeout.

    // MARK: - Scanner aggregation

    // MARK: - Mount protection

    /// Child devid differs from the root (another volume is mounted there) → no descent, no hits, completeness records crossedMountPoint.
    /// Real FS mounts are not available in tests, so inject a scripted entry source (same pattern as DirectoryTreeWalker).
    ///
    /// On the real FS under `Mounted/` we deliberately place a matchable `node_modules`: the scripted source will not see it,
    /// so assertions rely on `createdSourceCount` — a bad descent creates an extra `makeSource`.
    func testDoesNotDescendIntoDirectoryOnAnotherDevice() throws {
        // Real directories must exist: the scripted source only controls what is seen; descent still uses real openat.
        // Under `Mounted` we place a matchable node_modules — a bad descent would discover it on the real FS.
        let root = try temporaryDirectory.makeDirectory("root")
        try temporaryDirectory.makeFile("root/Mounted/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/Mounted/node_modules")
        try temporaryDirectory.makeDirectory("root/local")
        let rootDevice = try deviceID(of: root.path)

        let factory = ScriptedPurgeSourceFactory(scripts: [
            [[
                .resolved(entry(
                    name: "Mounted",
                    type: .directory,
                    devid: rootDevice &+ 1,
                    fileID: 77
                )),
                .resolved(entry(
                    name: "local",
                    type: .directory,
                    devid: rootDevice,
                    fileID: 78
                )),
            ]],
            // The second source is created only if same-device `local` is descended into.
            [[
                .resolved(entry(
                    name: "__pycache__",
                    type: .directory,
                    devid: rootDevice,
                    fileID: 79
                )),
            ]],
        ])
        discovery = DiskCleanPurgeDiscovery(sourceFactory: factory)

        let report = discovery.discover(root: root.path)

        guard case let .traversed(completeness) = report.status else {
            return XCTFail("expected traversed, got \(report.status)")
        }
        XCTAssertEqual(completeness, .partial(reasons: [.crossedMountPoint]))
        XCTAssertEqual(report.items.map(\.path), [root.path + "/local/__pycache__"])
        XCTAssertFalse(
            report.items.contains { $0.path.contains("/Mounted/") },
            "candidates inside a cross-device subtree must not be discovered"
        )
        XCTAssertEqual(factory.createdSourceCount, 2, "cross-device directories must not be openat-descended")
    }

    // MARK: - Fixtures

    private func path(_ relativePath: String) -> String {
        temporaryDirectory.resolve(relativePath).path
    }

    private func discoverItems() throws -> [DiskCleanPurgeDiscoveredItem] {
        discovery.discover(root: path("root")).items
    }

    private func makeSingleRepositoryLayout() throws {
        try temporaryDirectory.makeDirectory("root/repo/.git")
        try temporaryDirectory.makeFile("root/repo/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/repo/node_modules")
    }

    private func makeScanner(runner: ScriptedDiskCleanSubprocessRunner) -> DiskCleanPurgeScanner {
        DiskCleanPurgeScanner(
            discovery: discovery,
            inspector: DiskCleanGitStatusInspector(runner: runner)
        )
    }

    private func scanSingleCandidate(
        runner: ScriptedDiskCleanSubprocessRunner
    ) async throws -> DiskCleanPurgeCandidate {
        let result = await makeScanner(runner: runner).scan(roots: [path("root")])
        return try XCTUnwrap(result.candidates.first)
    }

    private func deviceID(of path: String) throws -> UInt64 {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        return UInt64(UInt32(bitPattern: status.st_dev))
    }

    private func entry(
        name: String,
        type: DiskCleanRootIdentity.FileType,
        devid: UInt64,
        fileID: UInt64,
        linkCount: UInt32 = 1,
        dataLength: Int64 = 0
    ) -> DiskCleanResolvedEntry {
        DiskCleanResolvedEntry(
            nameBytes: Array(name.utf8).map { CChar(bitPattern: $0) } + [0],
            fileType: type,
            devid: devid,
            fileID: fileID,
            linkCount: linkCount,
            dataLength: dataLength
        )
    }
}

/// Fake source factory that replays scripted entry batches. The n-th created source uses scripts[n].
/// Same pattern as `DiskCleanDirectoryTreeWalkerTests`, intentionally not shared — each suite owns its constraints.
private final class ScriptedPurgeSourceFactory: DiskCleanDirectoryEntrySourceFactory, @unchecked Sendable {
    private let scripts: [[[DiskCleanWalkEntry]]]
    private let lock = NSLock()
    private var sources: [ScriptedPurgeSource] = []

    init(scripts: [[[DiskCleanWalkEntry]]]) {
        self.scripts = scripts
    }

    var createdSourceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sources.count
    }

    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource {
        lock.lock()
        let index = sources.count
        lock.unlock()

        let source = ScriptedPurgeSource(
            fileDescriptor: fileDescriptor,
            batches: index < scripts.count ? scripts[index] : []
        )
        lock.lock()
        sources.append(source)
        lock.unlock()
        return source
    }
}

private final class ScriptedPurgeSource: DiskCleanDirectoryEntrySource {
    let directoryFileDescriptor: Int32
    private var batches: [[DiskCleanWalkEntry]]
    private(set) var isClosed = false

    init(fileDescriptor: Int32, batches: [[DiskCleanWalkEntry]]) {
        self.directoryFileDescriptor = fileDescriptor
        self.batches = batches
    }

    func nextBatch() throws -> [DiskCleanWalkEntry]? {
        guard !batches.isEmpty else { return nil }
        return batches.removeFirst()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(directoryFileDescriptor)
    }
}

/// Subprocess fake programmable per command. Existing `FakeDiskCleanSubprocessRunner` returns one result for all
/// calls and cannot cover "status clean but log has output".
final class ScriptedDiskCleanSubprocessRunner: DiskCleanSubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let statusResult: Result<DiskCleanSubprocessResult, Error>
    private let logResult: Result<DiskCleanSubprocessResult, Error>

    init(
        statusOutput: String = "",
        statusExitCode: Int32 = 0,
        logOutput: String = "",
        logExitCode: Int32 = 0
    ) {
        self.statusResult = .success(
            DiskCleanSubprocessResult(exitCode: statusExitCode, standardOutput: Data(statusOutput.utf8))
        )
        self.logResult = .success(
            DiskCleanSubprocessResult(exitCode: logExitCode, standardOutput: Data(logOutput.utf8))
        )
    }

    init(error: Error) {
        self.statusResult = .failure(error)
        self.logResult = .failure(error)
    }

    var invocations: [[String]] { lock.withLock { recorded } }

    func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration
    ) async throws -> DiskCleanSubprocessResult {
        lock.withLock { recorded.append(arguments) }
        XCTAssertEqual(executablePath, DiskCleanGitStatusInspector.executablePath)
        XCTAssertEqual(timeout, .seconds(2))
        return try (arguments.contains("status") ? statusResult : logResult).get()
    }
}
