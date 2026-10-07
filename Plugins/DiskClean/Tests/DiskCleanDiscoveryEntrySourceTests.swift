import Darwin
import Foundation
import XCTest
@testable import DiskCleanPlugin

final class DiskCleanDiscoveryEntrySourceTests: XCTestCase {
    func testUnsupportedBulkReadFallsBackToTheOriginalDirectory() throws {
        let directory = try DiskCleanTempDirectory(name: "DiskCleanDiscoveryEntrySourceTests")
        defer { directory.remove() }
        try directory.makeFile("Outside/foreign.dmg", bytes: 20)
        for code in [ENOTSUP, EINVAL, ENOSYS] {
            let root = "Root-\(code)"
            try directory.makeFile("\(root)/original.dmg", bytes: 10)
            try directory.makeSymlink("\(root)/alias.dmg", destination: "original.dmg")
            guard case let .directory(descriptor, _) = DiskCleanRootOpener().open(path: directory.resolve(root).path) else {
                return XCTFail("expected directory")
            }
            let source = try DiskCleanDiscoveryEntrySourceFactory(
                bulkSourceFactory: ScriptedDiscoverySourceFactory(steps: [.failure(DiskCleanPOSIXError(code: code))])
            ).makeSource(fileDescriptor: descriptor)
            defer { source.close() }
            try FileManager.default.moveItem(at: directory.resolve(root), to: directory.resolve("Moved-\(code)"))
            try directory.makeSymlink(root, destination: "Outside")

            let entries = try XCTUnwrap(source.nextBatch())

            let resolved = entries.compactMap { entry -> DiskCleanResolvedEntry? in
                guard case let .resolved(value) = entry else { return nil }
                return value
            }
            XCTAssertEqual(Set(resolved.map { String(cString: $0.nameBytes) }), ["original.dmg", "alias.dmg"])
            XCTAssertEqual(resolved.sorted { $0.nameBytes.lexicographicallyPrecedes($1.nameBytes) }.map(\.fileType), [.symlink, .regularFile])
            XCTAssertNil(try source.nextBatch())
        }
    }

    func testFailureAfterDeliveredBatchDoesNotRestartEnumeration() throws {
        let directory = try DiskCleanTempDirectory(name: "DiskCleanDiscoveryEntrySourceTests")
        defer { directory.remove() }
        let root = try directory.makeDirectory("Root")
        guard case let .directory(descriptor, _) = DiskCleanRootOpener().open(path: root.path) else {
            return XCTFail("expected directory")
        }
        let delivered: [DiskCleanWalkEntry] = [.unresolved(code: ENOENT)]
        let source = try DiskCleanDiscoveryEntrySourceFactory(
            bulkSourceFactory: ScriptedDiscoverySourceFactory(steps: [
                .success(delivered), .failure(DiskCleanPOSIXError(code: ENOTSUP))
            ])
        ).makeSource(fileDescriptor: descriptor)
        defer { source.close() }

        XCTAssertEqual(try source.nextBatch(), delivered)
        XCTAssertThrowsError(try source.nextBatch()) { error in
            XCTAssertEqual(error as? DiskCleanPOSIXError, DiskCleanPOSIXError(code: ENOTSUP))
        }
    }
}

private struct ScriptedDiscoverySourceFactory: DiskCleanDirectoryEntrySourceFactory {
    let steps: [Result<[DiskCleanWalkEntry]?, DiskCleanPOSIXError>]

    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource {
        ScriptedDiscoverySource(fileDescriptor: fileDescriptor, steps: steps)
    }
}

private final class ScriptedDiscoverySource: DiskCleanDirectoryEntrySource {
    let directoryFileDescriptor: Int32
    private var steps: [Result<[DiskCleanWalkEntry]?, DiskCleanPOSIXError>]
    private var isClosed = false

    init(fileDescriptor: Int32, steps: [Result<[DiskCleanWalkEntry]?, DiskCleanPOSIXError>]) {
        self.directoryFileDescriptor = fileDescriptor
        self.steps = steps
    }

    func nextBatch() throws -> [DiskCleanWalkEntry]? {
        guard !steps.isEmpty else { return nil }
        return try steps.removeFirst().get()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(directoryFileDescriptor)
    }
}
