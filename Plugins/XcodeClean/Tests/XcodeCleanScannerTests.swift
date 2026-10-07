import XCTest
@testable import MacTools
@testable import XcodeCleanPlugin

final class XcodeCleanScannerTests: XCTestCase {
    func testScansAllowedCategoryAndComputesSize() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let derivedRoot = temp.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: derivedRoot, withIntermediateDirectories: true)
        let projectDir = derivedRoot.appendingPathComponent("MyProject-abc")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let largeFile = projectDir.appendingPathComponent("build.o")
        try Data(repeating: 0x41, count: 1024).write(to: largeFile)

        let catalog = XcodeCleanRuleCatalog(rules: [
            XcodeCleanRule(
                id: "test.derived",
                category: .derivedData,
                pathPatterns: [derivedRoot.path + "/*"]
            )
        ])
        let scanner = XcodeCleanScanner(
            ruleCatalog: catalog,
            fileSystem: LocalXcodeCleanFileSystem(),
            allowedRoots: [derivedRoot.path],
            now: { Date(timeIntervalSince1970: 0) }
        )

        let result = try await scanner.scan(categories: [.derivedData])

        XCTAssertEqual(result.candidates.count, 1)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.category, .derivedData)
        XCTAssertEqual(candidate.safety, .allowed)
        XCTAssertEqual(candidate.sizeBytes, 1024)
    }

    func testRejectsPathsOutsideAllowedRoots() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let outsideDir = temp.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: outsideDir.appendingPathComponent("blob"))

        let catalog = XcodeCleanRuleCatalog(rules: [
            XcodeCleanRule(
                id: "test.outside",
                category: .derivedData,
                pathPatterns: [outsideDir.path + "/*"]
            )
        ])
        let scanner = XcodeCleanScanner(
            ruleCatalog: catalog,
            fileSystem: LocalXcodeCleanFileSystem(),
            allowedRoots: [temp.appendingPathComponent("Allowed").path],
            now: { Date(timeIntervalSince1970: 0) }
        )

        let result = try await scanner.scan(categories: [.derivedData])

        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.safety, .outsideAllowedRoot)
        XCTAssertEqual(result.cleanableCandidates.count, 0)
    }

    func testSizingPreservesPackageBoundariesAndDoesNotFollowSymlinks() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("Build")
        let package = root.appendingPathComponent("Sample.app")
        let nested = root.appendingPathComponent("Objects/café %")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("object.o")
        try Data(repeating: 1, count: 17).write(to: file)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("alias.o"))
        try Data(repeating: 1, count: 101).write(to: package.appendingPathComponent("payload"))
        let outside = temp.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 997).write(to: outside.appendingPathComponent("payload"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file-link"), withDestinationURL: file)

        let fileSystem = LocalXcodeCleanFileSystem()
        // Foundation counts each hard-link path, skips child packages, and visits a package root.
        XCTAssertEqual(try fileSystem.sizeOfItem(at: root.path), 34)
        XCTAssertEqual(try fileSystem.sizeOfItem(at: package.path), 101)
        XCTAssertEqual(try fileSystem.sizeOfItem(at: file.path), 17)
        let rootLink = temp.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)
        XCTAssertEqual(try fileSystem.sizeOfItem(at: rootLink.path), 0)
        XCTAssertEqual(try fileSystem.sizeOfItem(at: rootLink.path + "/"), 0)
    }

    func testCancelledSizingThrows() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LocalXcodeCleanFileSystem().sizeOfItem(at: temp.path)
        }
        do { _ = try await task.value; XCTFail("Cancelled directory sizing must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSkipsCategoriesNotInRequest() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let derivedRoot = temp.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: derivedRoot, withIntermediateDirectories: true)
        try Data([0]).write(to: derivedRoot.appendingPathComponent("blob"))

        let archivesRoot = temp.appendingPathComponent("Archives")
        try FileManager.default.createDirectory(at: archivesRoot, withIntermediateDirectories: true)
        try Data([0]).write(to: archivesRoot.appendingPathComponent("archive"))

        let catalog = XcodeCleanRuleCatalog(rules: [
            XcodeCleanRule(id: "test.derived", category: .derivedData, pathPatterns: [derivedRoot.path + "/*"]),
            XcodeCleanRule(id: "test.archives", category: .archives, pathPatterns: [archivesRoot.path + "/*"])
        ])
        let scanner = XcodeCleanScanner(
            ruleCatalog: catalog,
            allowedRoots: [derivedRoot.path, archivesRoot.path]
        )

        let result = try await scanner.scan(categories: [.derivedData])

        XCTAssertEqual(result.candidates.map(\.category), [.derivedData])
    }

    func testEmitsProgressLog() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let derivedRoot = temp.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: derivedRoot, withIntermediateDirectories: true)
        try Data([0]).write(to: derivedRoot.appendingPathComponent("blob"))

        let catalog = XcodeCleanRuleCatalog(rules: [
            XcodeCleanRule(id: "test.derived", category: .derivedData, pathPatterns: [derivedRoot.path + "/*"])
        ])
        let scanner = XcodeCleanScanner(
            ruleCatalog: catalog,
            allowedRoots: [derivedRoot.path]
        )

        let recorder = LogRecorder()
        _ = try await scanner.scan(categories: [.derivedData]) { message in
            await recorder.append(message)
        }

        let messages = await recorder.snapshot()
        XCTAssertTrue(messages.contains { $0.text.contains("扫描分类") })
        XCTAssertTrue(messages.contains { $0.text.contains("可清理") })
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "xcode-clean-scanner-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor LogRecorder {
    private var messages: [XcodeCleanScanLogMessage] = []
    func append(_ message: XcodeCleanScanLogMessage) {
        messages.append(message)
    }
    func snapshot() -> [XcodeCleanScanLogMessage] { messages }
}
