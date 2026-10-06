import Darwin
import Foundation
import XCTest
@testable import SystemDataPlugin

final class SystemDataScannerTests: XCTestCase {
    private var homeDirectory: URL!
    private var cachesRoot: URL!
    private var parentRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-data-" + UUID().uuidString, isDirectory: true)
        cachesRoot = homeDirectory.appendingPathComponent("caches", isDirectory: true)
        parentRoot = homeDirectory.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        // Restore restricted fixtures before removal so cleanup can descend.
        _ = chmod(homeDirectory.appendingPathComponent("unreadable").path, 0o755)
        _ = chmod(homeDirectory.appendingPathComponent("blocked").path, 0o755)
        try? FileManager.default.removeItem(at: homeDirectory)
        try super.tearDownWithError()
    }

    // MARK: - Path probe

    func testPathProbeMeasuresAllocationAndHonorsExclusions() async throws {
        // Included content: a flat file, a nested file, and a hard-linked file.
        let bigFile = cachesRoot.appendingPathComponent("big.bin")
        try write(Data(repeating: 0x41, count: 64 * 1024), to: bigFile)

        let nested = cachesRoot.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write(Data(repeating: 0x42, count: 32 * 1024), to: nested.appendingPathComponent("deep.bin"))

        let hardSource = cachesRoot.appendingPathComponent("hard.bin")
        try write(Data(repeating: 0x43, count: 8 * 1024), to: hardSource)
        let hardAlias = cachesRoot.appendingPathComponent("hard-alias.bin")
        XCTAssertEqual(link(hardSource.path, hardAlias.path), 0, "hard link setup failed")

        // A symlink to a large file must never be followed.
        let outside = homeDirectory.appendingPathComponent("outside.bin")
        try write(Data(repeating: 0x44, count: 1024 * 1024), to: outside)
        try FileManager.default.createSymbolicLink(
            at: cachesRoot.appendingPathComponent("link.bin"),
            withDestinationURL: outside
        )

        // Excluded root child: a 1 MB file that must not be counted at all.
        let excluded = cachesRoot.appendingPathComponent("Excluded")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try write(Data(repeating: 0x45, count: 1024 * 1024), to: excluded.appendingPathComponent("huge.bin"))

        let catalog = [
            SystemDataGroupDefinition(
                id: "g",
                label: .literal("G"),
                systemImage: "folder",
                items: [
                    SystemDataItemDefinition(
                        id: "caches",
                        label: .literal("Caches"),
                        path: cachesRoot.path,
                        badge: .safe,
                        kind: .path(excluding: ["Excluded"])
                    ),
                ]
            ),
        ]

        let scanner = makeScanner(catalog: catalog)
        let result = try await scanner.scan { _ in }

        let job = try XCTUnwrap(result.results.first { $0.itemID == "caches" })
        XCTAssertEqual(job.status, .measured(bytes: Self.expectedAllocation(at: cachesRoot, excluding: ["Excluded"])))
        XCTAssertGreaterThan(job.status.bytes, 0)
        // The excluded file alone is 1 MB; if it leaked in, the total would exceed it.
        XCTAssertLessThan(job.status.bytes, 1024 * 1024)
    }

    func testMissingPathIsAbsentAndUnreadableRootIsUnreadable() async throws {
        let unreadable = homeDirectory.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try write(Data(repeating: 0x41, count: 4096), to: unreadable.appendingPathComponent("secret.bin"))
        XCTAssertEqual(chmod(unreadable.path, 0o000), 0)

        let catalog = [
            SystemDataGroupDefinition(
                id: "g",
                label: .literal("G"),
                systemImage: "folder",
                items: [
                    SystemDataItemDefinition(
                        id: "missing",
                        label: .literal("Missing"),
                        path: homeDirectory.appendingPathComponent("does-not-exist").path,
                        badge: .safe,
                        kind: .path()
                    ),
                    SystemDataItemDefinition(
                        id: "unreadable",
                        label: .literal("Unreadable"),
                        path: unreadable.path,
                        badge: .review,
                        kind: .path()
                    ),
                ]
            ),
        ]

        let scanner = makeScanner(catalog: catalog)
        let result = try await scanner.scan { _ in }

        XCTAssertEqual(result.results.first { $0.itemID == "missing" }?.status, .absent)
        XCTAssertEqual(result.results.first { $0.itemID == "unreadable" }?.status, .unreadable)
    }

    func testBlockedAncestorReportsUnreadableNotAbsent() async throws {
        // The child exists, but a denied ancestor makes it unreachable: that
        // must read as unreadable rather than silently disappearing as absent.
        let blocked = homeDirectory.appendingPathComponent("blocked")
        let child = blocked.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try write(Data(repeating: 0x41, count: 4096), to: child.appendingPathComponent("secret.bin"))
        XCTAssertEqual(chmod(blocked.path, 0o000), 0)

        let catalog = [
            SystemDataGroupDefinition(
                id: "g",
                label: .literal("G"),
                systemImage: "folder",
                items: [
                    SystemDataItemDefinition(
                        id: "under-blocked-ancestor",
                        label: .literal("Child"),
                        path: child.path,
                        badge: .review,
                        kind: .path()
                    ),
                ]
            ),
        ]

        let scanner = makeScanner(catalog: catalog)
        let result = try await scanner.scan { _ in }

        XCTAssertEqual(
            result.results.first { $0.itemID == "under-blocked-ancestor" }?.status,
            .unreadable
        )
    }

    // MARK: - Children probe

    func testChildrenProbeSplitsChildrenAndCountsLooseFiles() async throws {
        let alpha = parentRoot.appendingPathComponent("alpha")
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try write(Data(repeating: 0x41, count: 16 * 1024), to: alpha.appendingPathComponent("a.bin"))

        let beta = parentRoot.appendingPathComponent("beta")
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        try write(Data(repeating: 0x42, count: 8 * 1024), to: beta.appendingPathComponent("b.bin"))

        try write(Data(repeating: 0x43, count: 4 * 1024), to: parentRoot.appendingPathComponent("loose.bin"))

        let catalog = [
            SystemDataGroupDefinition(
                id: "g",
                label: .literal("G"),
                systemImage: "folder",
                items: [
                    SystemDataItemDefinition(
                        id: "parent",
                        label: .literal("Parent"),
                        path: parentRoot.path,
                        badge: .review,
                        kind: .children()
                    ),
                ]
            ),
        ]

        let scanner = makeScanner(catalog: catalog)
        let result = try await scanner.scan { _ in }

        let job = try XCTUnwrap(result.results.first { $0.itemID == "parent" })
        let alphaChild = try XCTUnwrap(job.children.first { $0.name == "alpha" })
        let betaChild = try XCTUnwrap(job.children.first { $0.name == "beta" })
        let looseChild = try XCTUnwrap(job.children.first { $0.isSyntheticFiles })

        XCTAssertEqual(alphaChild.bytes, Self.expectedAllocation(at: alpha))
        XCTAssertEqual(betaChild.bytes, Self.expectedAllocation(at: beta))
        XCTAssertGreaterThan(looseChild.bytes, 0)
        let childrenTotal = job.children.reduce(Int64(0)) { $0 + $1.bytes }
        XCTAssertEqual(job.status, .measured(bytes: childrenTotal))
    }

    // MARK: - App name resolution

    func testBundleIdentifierLikeDetection() {
        XCTAssertTrue(SystemDataScanner.isBundleIdentifierLike("com.docker.docker"))
        XCTAssertTrue(SystemDataScanner.isBundleIdentifierLike("dev.warp.Warp-Stable"))
        XCTAssertTrue(SystemDataScanner.isBundleIdentifierLike("com.example.deeply.nested_1"))
        XCTAssertFalse(SystemDataScanner.isBundleIdentifierLike("Google"))
        XCTAssertFalse(SystemDataScanner.isBundleIdentifierLike(".hidden"))
        XCTAssertFalse(SystemDataScanner.isBundleIdentifierLike("trailing."))
        XCTAssertFalse(SystemDataScanner.isBundleIdentifierLike("com..bad"))
        XCTAssertFalse(SystemDataScanner.isBundleIdentifierLike("has space.app"))
    }

    func testAppDisplayNameResolvesInstalledAppsAndFallsBackToNil() {
        // Finder ships with macOS, so LaunchServices always knows the identifier.
        let finderName = SystemDataScanner.appDisplayName(forBundleIdentifier: "com.apple.finder")
        XCTAssertNotNil(finderName)
        XCTAssertFalse(finderName?.isEmpty ?? true)

        XCTAssertNil(
            SystemDataScanner.appDisplayName(
                forBundleIdentifier: "com.example.not-installed"
            )
        )
        // Plain folder names never reach the LaunchServices query.
        XCTAssertNil(SystemDataScanner.resolvedAppName(forDirectoryName: "Google"))
        XCTAssertNil(SystemDataScanner.resolvedAppName(forDirectoryName: "com.example.not-installed"))
    }

    func testChildrenMeasurementCarriesResolvedAppName() async throws {
        let appDir = parentRoot.appendingPathComponent("com.apple.finder")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try write(Data(repeating: 0x41, count: 4 * 1024), to: appDir.appendingPathComponent("d.bin"))

        let catalog = [
            SystemDataGroupDefinition(
                id: "g",
                label: .literal("G"),
                systemImage: "folder",
                items: [
                    SystemDataItemDefinition(
                        id: "parent",
                        label: .literal("Parent"),
                        path: parentRoot.path,
                        badge: .review,
                        kind: .children()
                    ),
                ]
            ),
        ]

        let result = try await makeScanner(catalog: catalog).scan { _ in }
        let job = try XCTUnwrap(result.results.first { $0.itemID == "parent" })
        let child = try XCTUnwrap(job.children.first { $0.name == "com.apple.finder" })

        // The raw directory name keeps identity; the display name replaces the label.
        let resolved = SystemDataScanner.appDisplayName(forBundleIdentifier: "com.apple.finder")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(child.displayName, resolved)
    }

    // MARK: - Whole scan

    func testScanReturnsEveryJobAndDeliversProgress() async throws {
        try FileManager.default.createDirectory(at: cachesRoot, withIntermediateDirectories: true)
        try write(Data(repeating: 0x42, count: 8192), to: cachesRoot.appendingPathComponent("a.bin"))
        try FileManager.default.createDirectory(at: parentRoot, withIntermediateDirectories: true)
        try write(Data(repeating: 0x43, count: 8192), to: parentRoot.appendingPathComponent("b.bin"))

        let catalog = [
            SystemDataGroupDefinition(
                id: "g",
                label: .literal("G"),
                systemImage: "folder",
                items: [
                    SystemDataItemDefinition(
                        id: "caches",
                        label: .literal("Caches"),
                        path: cachesRoot.path,
                        badge: .safe,
                        kind: .path()
                    ),
                    SystemDataItemDefinition(
                        id: "parent",
                        label: .literal("Parent"),
                        path: parentRoot.path,
                        badge: .review,
                        kind: .children()
                    ),
                ]
            ),
        ]

        let scanner = makeScanner(catalog: catalog)
        final class ProgressBox: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() {
                lock.withLock { count += 1 }
            }
            var value: Int {
                lock.withLock { count }
            }
        }
        let progressBox = ProgressBox()

        let result = try await scanner.scan { _ in progressBox.increment() }

        XCTAssertEqual(result.results.count, 2)
        XCTAssertTrue(result.results.allSatisfy { $0.status.isMeasured })
        XCTAssertGreaterThan(progressBox.value, 0)
        XCTAssertNotNil(result.finishedAt)
    }

    // MARK: - Helpers

    private func makeScanner(
        catalog: [SystemDataGroupDefinition]
    ) -> SystemDataScanner {
        SystemDataScanner(
            configuration: .init(
                catalog: catalog,
                homeDirectory: homeDirectory.path,
                workerCount: 2,
                progressInterval: 0
            )
        )
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    /// Independent reference implementation of the allocation contract: sum of
    /// `st_blocks * 512` for directories and regular files, hard-linked files
    /// counted once, symlinks never followed, root-level names excluded.
    private static func expectedAllocation(
        at url: URL,
        excluding: Set<String> = []
    ) -> Int64 {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return 0 }
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            return Int64(status.st_blocks) * 512
        }

        var total = Int64(status.st_blocks) * 512
        var counted: Set<UInt64> = []
        var stack = [url.path]
        var isRoot = true

        while let directory = stack.popLast() {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in contents.sorted() {
                if isRoot, excluding.contains(name) { continue }
                let path = directory + "/" + name
                var entry = stat()
                guard lstat(path, &entry) == 0 else { continue }
                switch entry.st_mode & S_IFMT {
                case S_IFDIR:
                    total += Int64(entry.st_blocks) * 512
                    stack.append(path)
                case S_IFREG:
                    if entry.st_nlink > 1 {
                        if !counted.insert(entry.st_ino).inserted { continue }
                    }
                    total += Int64(entry.st_blocks) * 512
                default:
                    continue
                }
            }
            isRoot = false
        }
        return total
    }

    // MARK: - Tool output resolution

    func testToolOutputPathValidation() {
        XCTAssertEqual(
            SystemDataScanner.validatedToolOutputPath(from: "/Users/me/dev/gomod\n"),
            "/Users/me/dev/gomod"
        )
        XCTAssertEqual(
            SystemDataScanner.validatedToolOutputPath(from: "  /var/cache/go/mod  \r\n"),
            "/var/cache/go/mod"
        )
        // Blank, relative, unexpanded-home, or binary-junk output keeps the
        // static fallback instead of feeding garbage to the walker.
        XCTAssertNil(SystemDataScanner.validatedToolOutputPath(from: ""))
        XCTAssertNil(SystemDataScanner.validatedToolOutputPath(from: "\n"))
        XCTAssertNil(SystemDataScanner.validatedToolOutputPath(from: "relative/path\n"))
        XCTAssertNil(SystemDataScanner.validatedToolOutputPath(from: "~/go/pkg/mod"))
        XCTAssertNil(SystemDataScanner.validatedToolOutputPath(from: "/tmp/go\u{0}mod"))
    }
}
