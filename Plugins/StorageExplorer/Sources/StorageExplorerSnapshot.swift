import Foundation

/// Flat nodes keep navigation and updates independent of the size of descendant trees.
public struct StorageExplorerSnapshot: Sendable, Codable {
    public var progress = StorageExplorerScanProgress()
    public var rootPath: String
    public var items: [String: StorageItem] = [:]
    public var children: [String: [String]] = [:]
    public var fileTypeTotals: [String: StorageExplorerSizeTotals] = [:]
    public var fileTypeTotalsByDirectory: [String: [String: StorageExplorerSizeTotals]] = [:]

    public init(rootPath: String) { self.rootPath = rootPath }

    public mutating func apply(_ updates: [StorageItem]) {
        for item in updates {
            if items[item.path] == nil, let parent = item.parentPath {
                children[parent, default: []].append(item.path)
            }
            items[item.path] = item
        }
    }

    public func children(of path: String) -> [StorageItem] {
        (children[path] ?? []).compactMap { items[$0] }
    }

    /// Removes confirmed Trash successes using recorded totals, including files omitted from
    /// the retained tree. External changes and unretained hard links remain estimates until refresh.
    mutating func removeSubtrees(at paths: Set<String>) {
        let roots = paths.compactMap { path -> StorageItem? in
            guard path != rootPath, let item = items[path] else { return nil }
            var ancestor = item.parentPath
            while let path = ancestor {
                if paths.contains(path) { return nil }
                ancestor = items[path]?.parentPath
            }
            return item
        }
        var removedPaths: Set<String> = []
        var removedLinks: [StorageFileInode: StorageItem] = [:]
        for root in roots {
            var pending = [root.path]
            var descendantDirectories = 0
            while let path = pending.popLast(), removedPaths.insert(path).inserted {
                pending.append(contentsOf: children[path] ?? [])
                if path != root.path, items[path]?.isDirectory == true { descendantDirectories += 1 }
                if let item = items[path], item.isHardLinked, let identity = item.fileIdentity,
                   item.size > 0 || item.allocatedSize > 0 {
                    removedLinks[identity] = item
                }
            }
            let typeTotals: [String: StorageExplorerSizeTotals]
            if root.isDirectory && !root.isPackage {
                typeTotals = fileTypeTotalsByDirectory[root.path] ?? [:]
            } else {
                var totals = StorageExplorerSizeTotals()
                totals.add(root)
                typeTotals = [root.isPackage ? "package" : (root.fileExtension.isEmpty ? "—" : root.fileExtension): totals]
            }
            var ancestor = root.parentPath
            while let path = ancestor, var item = items[path] {
                item.size = max(0, item.size - root.size)
                item.allocatedSize = max(0, item.allocatedSize - root.allocatedSize)
                // Directory totals include their own node as well as the parent's direct entry.
                let removedCount = root.scannedCount + (root.isDirectory ? 1 : 0)
                item.scannedCount = max(1, item.scannedCount - removedCount)
                item.skippedCount = max(0, item.skippedCount - root.skippedCount)
                item.isIncomplete = item.isAccessDenied || item.isCloudPlaceholder || item.skippedCount > 0
                if path == root.parentPath { item.childCount = max(0, item.childCount - 1) }
                items[path] = item
                if var existing = fileTypeTotalsByDirectory[path] {
                    for (kind, removed) in typeTotals {
                        guard var total = existing[kind] else { continue }
                        total.size = max(0, total.size - removed.size)
                        total.allocatedSize = max(0, total.allocatedSize - removed.allocatedSize)
                        total.count = max(0, total.count - removed.count)
                        existing[kind] = total.count > 0 ? total : nil
                    }
                    fileTypeTotalsByDirectory[path] = existing
                }
                ancestor = item.parentPath
            }
            // Progress counts each enumerated entry once; folded directory totals also include
            // the retained directory nodes, which must not be subtracted a second time here.
            progress.filesScanned = max(0, progress.filesScanned - (root.scannedCount - descendantDirectories))
            progress.skippedCount = max(0, progress.skippedCount - root.skippedCount)
        }
        for parent in Set(roots.compactMap(\.parentPath)) {
            children[parent]?.removeAll { removedPaths.contains($0) }
        }
        for path in removedPaths {
            items.removeValue(forKey: path)
            children.removeValue(forKey: path)
            fileTypeTotalsByDirectory.removeValue(forKey: path)
        }

        // Keep shared data charged to a surviving retained link when its counted path was moved.
        var survivingLinks: [StorageFileInode: StorageItem] = [:]
        if !removedLinks.isEmpty {
            for item in items.values where item.isHardLinked {
                guard let identity = item.fileIdentity, removedLinks[identity] != nil else { continue }
                if survivingLinks[identity].map({ item.path < $0.path }) ?? true {
                    survivingLinks[identity] = item
                }
            }
        }
        for (identity, var survivor) in survivingLinks {
            guard let removed = removedLinks[identity] else { continue }
            survivor.size += removed.size
            survivor.allocatedSize += removed.allocatedSize
            items[survivor.path] = survivor
            let kind = survivor.fileExtension.isEmpty ? "—" : survivor.fileExtension
            var ancestor = survivor.parentPath
            while let path = ancestor, var item = items[path] {
                item.size += removed.size
                item.allocatedSize += removed.allocatedSize
                items[path] = item
                if fileTypeTotalsByDirectory[path]?[kind] != nil {
                    fileTypeTotalsByDirectory[path]?[kind]?.size += removed.size
                    fileTypeTotalsByDirectory[path]?[kind]?.allocatedSize += removed.allocatedSize
                }
                ancestor = item.parentPath
            }
        }
        fileTypeTotals = fileTypeTotalsByDirectory[rootPath] ?? [:]
        progress.bytesScanned = items[rootPath]?.size ?? 0
        progress.allocatedBytesScanned = items[rootPath]?.allocatedSize ?? 0
    }

    /// Compatibility representation for scanner clients that explicitly request a full tree.
    public func tree() -> StorageItem? {
        guard var root = items[rootPath] else { return nil }
        var built = items
        for item in items.values.sorted(by: { $0.path.count > $1.path.count }) {
            guard item.isDirectory && !item.isPackage else { continue }
            var copy = item
            copy.children = (children[item.path] ?? []).compactMap { built[$0] }.sorted { $0.size > $1.size }
            built[item.path] = copy
        }
        root = built[rootPath] ?? root
        return root
    }
}

public struct StorageExplorerScanUpdate: Sendable {
    public let items: [StorageItem]
    public let progress: StorageExplorerScanProgress
}

public protocol StorageExplorerScanning: Sendable {
    func scanSnapshot(rootURL: URL, update: @escaping @Sendable (StorageExplorerScanUpdate) -> Void) async throws -> StorageExplorerSnapshot
    func invalidate(paths: [String])
    func clearCache()
}
