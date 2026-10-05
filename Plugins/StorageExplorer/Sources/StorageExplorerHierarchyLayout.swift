import Foundation

struct StorageExplorerHierarchyNode: Identifiable, Equatable, Sendable {
    let item: StorageItem
    let bytes: Int64
    let children: [StorageExplorerHierarchyNode]
    let colorKey: String

    var id: String { item.path }
    var isAggregate: Bool { item.path.hasPrefix("group:other:") }
}

enum StorageExplorerHierarchyLayout {
    static func make(
        snapshot: StorageExplorerSnapshot,
        directory: String,
        metric: StorageExplorerMetric,
        excluding excludedPaths: Set<String>,
        otherName: String,
        maximumDepth: Int = 3
    ) -> [StorageExplorerHierarchyNode] {
        let excluded = excludedPaths
        var removedBytesByAncestor: [String: Int64] = [:]
        var adjustedBytesByPath: [String: Int64] = [:]

        func parentPath(of path: String) -> String? {
            if let parent = snapshot.items[path]?.parentPath {
                return parent
            }
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != ".", parent != path else { return nil }
            return parent
        }

        for path in excluded.sorted() {
            guard let selected = snapshot.items[path] else { continue }
            let selectedBytes = metric.bytes(selected)
            var ancestor = parentPath(of: path)
            var visited: Set<String> = []
            while let path = ancestor, visited.insert(path).inserted {
                removedBytesByAncestor[path, default: 0] += selectedBytes
                ancestor = parentPath(of: path)
            }
        }

        func isExcluded(_ path: String) -> Bool {
            var candidate: String? = path
            var visited: Set<String> = []
            while let path = candidate, visited.insert(path).inserted {
                if excluded.contains(path) { return true }
                candidate = parentPath(of: path)
            }
            return false
        }

        func adjustedBytes(_ item: StorageItem) -> Int64 {
            if let cached = adjustedBytesByPath[item.path] { return cached }
            let bytes = isExcluded(item.path)
                ? 0
                : max(0, metric.bytes(item) - removedBytesByAncestor[item.path, default: 0])
            adjustedBytesByPath[item.path] = bytes
            return bytes
        }

        func nodes(parentPath: String, depth: Int, colorKey: String?) -> [StorageExplorerHierarchyNode] {
            let parentBytes = snapshot.items[parentPath].map(adjustedBytes) ?? 0
            var children: [(item: StorageItem, bytes: Int64)] = []
            for item in snapshot.children(of: parentPath) {
                let bytes = adjustedBytes(item)
                if bytes > 0 { children.append((item, bytes)) }
            }
            children.sort {
                $0.bytes == $1.bytes ? $0.item.path < $1.item.path : $0.bytes > $1.bytes
            }
            let limit = depth == 0 ? 48 : depth == 1 ? 18 : 10
            let visible = Array(children.prefix(limit))
            var result = visible.enumerated().map { index, value -> StorageExplorerHierarchyNode in
                let item = value.item
                // The completed snapshot is sorted deterministically by size and path. Top-level
                // rank drives a warm-to-cool palette, while descendants inherit their group color.
                let key = colorKey ?? "size-rank:\(index):\(item.path)"
                let nested = depth + 1 < maximumDepth && item.isDirectory && !item.isPackage
                    ? nodes(parentPath: item.path, depth: depth + 1, colorKey: key)
                    : []
                return StorageExplorerHierarchyNode(
                    item: item,
                    bytes: value.bytes,
                    children: nested,
                    colorKey: key
                )
            }
            let represented = result.reduce(Int64(0)) { $0 + $1.bytes }
            let remainder = max(0, parentBytes - represented)
            if remainder > 0 {
                let aggregate = StorageItem(
                    name: otherName,
                    path: "group:other:" + parentPath,
                    url: URL(fileURLWithPath: parentPath),
                    isDirectory: false,
                    size: remainder,
                    allocatedSize: remainder,
                    parentPath: parentPath
                )
                result.append(StorageExplorerHierarchyNode(
                    item: aggregate,
                    bytes: remainder,
                    children: [],
                    colorKey: colorKey ?? "size-rank:7:other"
                ))
            }
            return result
        }

        return nodes(parentPath: directory, depth: 0, colorKey: nil)
    }
}

struct StorageExplorerHierarchyRect: Identifiable, Equatable {
    let node: StorageExplorerHierarchyNode
    let rect: CGRect
    let depth: Int
    let rootID: String
    let sizeLabel: String
    var id: String { node.id }
}

enum StorageExplorerHierarchyRectLayout {
    static func make(
        nodes: [StorageExplorerHierarchyNode],
        in bounds: CGRect,
        maximumRectangles: Int = 500,
        minimumChildWidth: CGFloat = 44,
        minimumChildHeight: CGFloat = 34,
        locale: Locale = .current
    ) -> [StorageExplorerHierarchyRect] {
        struct Work {
            let nodes: [StorageExplorerHierarchyNode]
            let rect: CGRect
            let depth: Int
            let rootID: String?
        }

        var result: [StorageExplorerHierarchyRect] = []
        var queue = [Work(nodes: nodes, rect: bounds, depth: 0, rootID: nil)]
        var queueIndex = 0
        let byteStyle = ByteCountFormatStyle(style: .file).locale(locale)

        while queueIndex < queue.count, result.count < maximumRectangles {
            let work = queue[queueIndex]
            queueIndex += 1
            let positive = work.nodes.filter { $0.bytes > 0 }
            guard !positive.isEmpty, work.rect.width > 2, work.rect.height > 2,
                  result.count + positive.count <= maximumRectangles else { continue }
            let weights = positive.map { Double($0.bytes) }
            let boxes = partition(weights: weights, in: work.rect)
            for (node, box) in zip(positive, boxes) {
                let rootID = work.rootID ?? node.id
                result.append(StorageExplorerHierarchyRect(
                    node: node,
                    rect: box,
                    depth: work.depth,
                    rootID: rootID,
                    sizeLabel: node.bytes.formatted(byteStyle)
                ))
                guard !node.children.isEmpty else { continue }
                let header = min(26, max(18, box.height * 0.12))
                let inset = box.insetBy(dx: 4, dy: 4)
                let childRect = CGRect(
                    x: inset.minX,
                    y: inset.minY + header,
                    width: inset.width,
                    height: max(0, inset.height - header)
                )
                guard childRect.width >= minimumChildWidth,
                      childRect.height >= minimumChildHeight else { continue }
                queue.append(Work(
                    nodes: node.children,
                    rect: childRect,
                    depth: work.depth + 1,
                    rootID: rootID
                ))
            }
        }
        return result
    }

    private static func partition(weights: [Double], in rect: CGRect) -> [CGRect] {
        guard !weights.isEmpty else { return [] }
        var result = Array(repeating: CGRect.zero, count: weights.count)

        func split(_ range: Range<Int>, _ box: CGRect) {
            if range.count == 1 {
                result[range.lowerBound] = box
                return
            }
            let total = range.reduce(0.0) { $0 + weights[$1] }
            guard total > 0 else { return }
            var subtotal = 0.0
            var pivot = range.lowerBound
            repeat {
                subtotal += weights[pivot]
                pivot += 1
            } while pivot < range.upperBound - 1 && subtotal < total / 2
            let fraction = subtotal / total
            let horizontal = box.width >= box.height
            let first = CGRect(
                x: box.minX,
                y: box.minY,
                width: horizontal ? box.width * fraction : box.width,
                height: horizontal ? box.height : box.height * fraction
            )
            let second = CGRect(
                x: horizontal ? first.maxX : box.minX,
                y: horizontal ? box.minY : first.maxY,
                width: horizontal ? box.width - first.width : box.width,
                height: horizontal ? box.height : box.height - first.height
            )
            split(range.lowerBound..<pivot, first)
            split(pivot..<range.upperBound, second)
        }

        split(weights.indices, rect)
        return result
    }
}
