import Darwin
import Foundation
import MacToolsFileSystem
import XCTest

final class FileSystemDirectoryReaderTests: XCTestCase {
    func testBatchesDeliverEachEntryOnceAndAllowCancellationBetweenReads() throws {
        var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let physical = try XCTUnwrap(realpath(root.path, nil))
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        free(physical)
        // Long names ensure this small fixture needs more than one metadata buffer.
        let names = Set((0..<400).map { "\($0)-" + String(repeating: "x", count: 180) })
        for name in names { try Data([1]).write(to: root.appendingPathComponent(name)) }

        var received: [String] = []
        var batches = 0
        try FileSystemDirectoryReader.readBatches(path: root.path, cancelled: { false }) { batch in
            batches += 1
            XCTAssertEqual(batch.skippedCount, 0)
            for entry in batch.entries {
                let bytes = try XCTUnwrap(entry.nameBytes)
                received.append(bytes.withUnsafeBytes { String(decoding: $0.dropLast(), as: UTF8.self) })
                XCTAssertEqual(entry.dataLength, 1)
            }
        }
        XCTAssertGreaterThan(batches, 1)
        XCTAssertEqual(received.count, names.count)
        XCTAssertEqual(Set(received), names)

        var cancelled = false
        var delivered = 0
        XCTAssertThrowsError(try FileSystemDirectoryReader.readBatches(path: root.path, cancelled: { cancelled }) { batch in
            delivered += batch.entries.count
            cancelled = true
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThan(delivered, 0)
        XCTAssertLessThan(delivered, names.count)
    }
}
