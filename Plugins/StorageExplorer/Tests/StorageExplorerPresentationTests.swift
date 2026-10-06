import XCTest
@testable import StorageExplorerPlugin

final class StorageExplorerPresentationTests: XCTestCase {
    func testHierarchyRectangleLayoutKeepsTileBudgetAndEveryRoot() {
        func leaf(_ path: String, bytes: Int64) -> StorageExplorerHierarchyNode {
            let item = StorageItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                url: URL(fileURLWithPath: path),
                isDirectory: false,
                size: bytes,
                allocatedSize: bytes
            )
            return StorageExplorerHierarchyNode(item: item, bytes: bytes, children: [], colorKey: "size-rank:0")
        }
        let roots = (0..<2).map { rootIndex -> StorageExplorerHierarchyNode in
            let rootPath = "/root-\(rootIndex)"
            let children = (0..<2).map { childIndex -> StorageExplorerHierarchyNode in
                let childPath = rootPath + "/child-\(childIndex)"
                let grandchildren = (0..<2).map {
                    leaf(childPath + "/leaf-\($0)", bytes: 1)
                }
                let item = StorageItem(
                    name: "child-\(childIndex)", path: childPath,
                    url: URL(fileURLWithPath: childPath), isDirectory: true,
                    size: 2, allocatedSize: 2, parentPath: rootPath
                )
                return StorageExplorerHierarchyNode(
                    item: item, bytes: 2, children: grandchildren, colorKey: "size-rank:\(rootIndex)"
                )
            }
            let item = StorageItem(
                name: "root-\(rootIndex)", path: rootPath,
                url: URL(fileURLWithPath: rootPath), isDirectory: true,
                size: 4, allocatedSize: 4, parentPath: "/"
            )
            return StorageExplorerHierarchyNode(
                item: item, bytes: 4, children: children, colorKey: "size-rank:\(rootIndex)"
            )
        }

        let rectangles = StorageExplorerHierarchyRectLayout.make(
            nodes: roots,
            in: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            maximumRectangles: 6
        )

        XCTAssertLessThanOrEqual(rectangles.count, 6)
        XCTAssertTrue(rectangles.contains { $0.depth > 0 })
        XCTAssertEqual(rectangles.filter { $0.depth == 0 }.count, roots.count)
        XCTAssertEqual(Set(rectangles.filter { $0.depth == 0 }.map(\.rootID)), Set(roots.map(\.id)))
    }

    func testTreemapPartitionsWithoutOverlapAndPreservesArea() {
        let rows = (1...4).map { number -> StorageExplorerRow in
            let item = StorageItem(name: "\(number)", path: "/\(number)", url: URL(fileURLWithPath: "/\(number)"), isDirectory: false, size: Int64(number))
            return StorageExplorerRow(item: item, name: item.name, bytes: item.size, sizeLabel: "", percentage: "", kind: "", modified: .distantPast, dateLabel: "")
        }
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 300)
        let tiles = StorageExplorerTreemapLayout.tiles(rows: rows, in: bounds)
        XCTAssertEqual(tiles.count, rows.count)
        for (i, tile) in tiles.enumerated() {
            XCTAssertEqual(tile.rect.width * tile.rect.height / (bounds.width * bounds.height), Double(tile.row.bytes) / 10, accuracy: 0.000001)
            for other in tiles.dropFirst(i + 1) {
                let intersection = tile.rect.intersection(other.rect)
                XCTAssertTrue(intersection.isNull || intersection.width * intersection.height < 0.00001)
            }
        }
        XCTAssertTrue(StorageExplorerTreemapLayout.tiles(rows: rows, in: .zero).isEmpty)
    }

    func testLargestFilesSearchesAllDescendantsAndUsesAllocatedMetric() {
        let root = "/fixture"
        var snapshot = StorageExplorerSnapshot(rootPath: root)
        for i in 0..<3 {
            let path = root + "/nested/file-\(i).bin"
            snapshot.apply([StorageItem(name: "file-\(i).bin", path: path, url: URL(fileURLWithPath: path), isDirectory: false,
                                       size: Int64(i + 1), allocatedSize: Int64(100 - i), parentPath: root + "/nested")])
        }
        let result = StorageExplorerPresentation.make(snapshot: snapshot, directory: root, mode: .largestFiles,
            metric: .allocated, query: "nested", sort: .size, ascending: false)
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.rows.first?.bytes, 100)
        XCTAssertEqual(result.total, 297)
        let types = StorageExplorerPresentation.make(snapshot: snapshot, directory: root, mode: .fileTypes,
            metric: .logical, query: "", sort: .size, ascending: false)
        XCTAssertEqual(types.rows.count, 1)
        XCTAssertEqual(types.rows.first?.bytes, 6)
        XCTAssertEqual(types.rows.first?.item.childCount, 3)
    }

    func testChartGroupsOverflowWithoutLosingBytes() {
        var snapshot = StorageExplorerSnapshot(rootPath: "/fixture")
        for i in 0..<162 {
            let path = "/fixture/\(i)"
            snapshot.apply([StorageItem(name: "\(i)", path: path, url: URL(fileURLWithPath: path),
                isDirectory: false, size: 10, parentPath: "/fixture")])
        }
        let groupName = UUID().uuidString
        let result = StorageExplorerPresentation.make(snapshot: snapshot, directory: "/fixture", mode: .folders,
            metric: .logical, query: "", sort: .size, ascending: false, otherName: groupName)
        XCTAssertEqual(result.chart.last?.name, groupName)
        XCTAssertEqual(result.chart.count, 161)
        XCTAssertEqual(result.chart.reduce(0) { $0 + $1.bytes }, 1_620)
        XCTAssertEqual(result.chart.last?.id, "group:other")
        XCTAssertEqual(result.chart.last?.bytes, 20)
        XCTAssertEqual(result.rows.count, 162)
    }

    func testHierarchyExcludesSelectedFoldersAndPrecomputesNestedDeductions() throws {
        let root = "/fixture"
        func item(_ suffix: String, parent: String?, bytes: Int64, directory: Bool) -> StorageItem {
            let path = root + suffix
            return StorageItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                url: URL(fileURLWithPath: path),
                isDirectory: directory,
                size: bytes,
                allocatedSize: bytes * 2,
                parentPath: parent.map { root + $0 }
            )
        }
        var snapshot = StorageExplorerSnapshot(rootPath: root)
        snapshot.apply([
            item("", parent: nil, bytes: 320, directory: true),
            item("/a", parent: "", bytes: 180, directory: true),
            item("/a/large", parent: "/a", bytes: 100, directory: false),
            item("/a/small", parent: "/a", bytes: 30, directory: false),
            item("/a/tiny", parent: "/a", bytes: 10, directory: false),
            item("/b", parent: "", bytes: 90, directory: true),
            item("/b/selected", parent: "/b", bytes: 40, directory: false),
            item("/loose", parent: "", bytes: 30, directory: false)
        ])

        let nodes = StorageExplorerHierarchyLayout.make(
            snapshot: snapshot,
            directory: root,
            metric: .logical,
            excluding: [root + "/a/small", root + "/b"],
            otherName: "Other"
        )

        XCTAssertEqual(nodes.map(\.id), [root + "/a", root + "/loose", "group:other:" + root])
        let folder = try XCTUnwrap(nodes.first)
        XCTAssertEqual(folder.bytes, 150)
        XCTAssertEqual(folder.children.map(\.id), [root + "/a/large", root + "/a/tiny", "group:other:" + root + "/a"])
        XCTAssertEqual(folder.children.map(\.bytes), [100, 10, 40])
        XCTAssertEqual(nodes.last?.bytes, 20)
        XCTAssertEqual(nodes.reduce(0) { $0 + $1.bytes }, 200)
    }
}
