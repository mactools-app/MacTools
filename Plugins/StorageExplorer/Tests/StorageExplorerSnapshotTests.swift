import Foundation
import XCTest
@testable import StorageExplorerPlugin

final class StorageExplorerSnapshotTests: XCTestCase {
    func testSiblingBatchRemovalPreservesChildrenAndTotalsAcrossParents() throws {
        func item(_ path: String, parent: String?, size: Int64,
                  directory: Bool = false, childCount: Int = 0, scannedCount: Int = 1) -> StorageItem {
            var item = StorageItem(name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                                   url: URL(fileURLWithPath: path), isDirectory: directory,
                                   size: size, allocatedSize: size * 2, childCount: childCount, parentPath: parent)
            item.scannedCount = scannedCount
            return item
        }
        var snapshot = StorageExplorerSnapshot(rootPath: "/scan")
        snapshot.apply([
            item("/scan", parent: nil, size: 450, directory: true, childCount: 3, scannedCount: 10),
            item("/scan/a", parent: "/scan", size: 300, directory: true, childCount: 2, scannedCount: 3),
            item("/scan/b", parent: "/scan", size: 125, directory: true, childCount: 2, scannedCount: 3),
            item("/scan/file", parent: "/scan", size: 25),
            item("/scan/a/one", parent: "/scan/a", size: 100),
            item("/scan/a/two", parent: "/scan/a", size: 200),
            item("/scan/b/one", parent: "/scan/b", size: 50),
            item("/scan/b/two", parent: "/scan/b", size: 75)
        ])
        snapshot.progress.filesScanned = 7
        snapshot.progress.bytesScanned = 450
        snapshot.progress.allocatedBytesScanned = 900

        snapshot.removeSubtrees(at: ["/scan/a/one", "/scan/a/two", "/scan/b/one", "/scan/file"])

        XCTAssertEqual(Set(snapshot.items.keys), ["/scan", "/scan/a", "/scan/b", "/scan/b/two"])
        XCTAssertEqual(snapshot.children["/scan"], ["/scan/a", "/scan/b"])
        XCTAssertEqual(snapshot.children["/scan/a"], [])
        XCTAssertEqual(snapshot.children["/scan/b"], ["/scan/b/two"])
        XCTAssertEqual(snapshot.items["/scan"]?.size, 75)
        XCTAssertEqual(snapshot.items["/scan"]?.allocatedSize, 150)
        XCTAssertEqual(snapshot.items["/scan"]?.scannedCount, 6)
        XCTAssertEqual(snapshot.items["/scan"]?.childCount, 2)
        XCTAssertEqual(snapshot.items["/scan/a"]?.size, 0)
        XCTAssertEqual(snapshot.items["/scan/a"]?.childCount, 0)
        XCTAssertEqual(snapshot.items["/scan/b"]?.size, 75)
        XCTAssertEqual(snapshot.items["/scan/b"]?.childCount, 1)
        XCTAssertEqual(snapshot.progress.filesScanned, 3)
        XCTAssertEqual(snapshot.progress.bytesScanned, 75)
        XCTAssertEqual(snapshot.progress.allocatedBytesScanned, 150)
    }
}
