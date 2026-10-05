import Foundation
import MacToolsPluginKit

public enum StorageExplorerMode: String, CaseIterable, Sendable { case folders, largestFiles, fileTypes }
public enum StorageExplorerMetric: String, CaseIterable, Sendable {
    case logical, allocated
    public func bytes(_ item: StorageItem) -> Int64 { self == .logical ? item.size : item.allocatedSize }
}
public enum StorageExplorerSort: String, Sendable { case name, size, kind, modified }

public struct StorageExplorerRow: Identifiable, Sendable, Equatable {
    public var id: String { item.path }
    public let item: StorageItem
    public let name: String
    public let bytes: Int64
    public let sizeLabel: String
    public let percentage: String
    public let kind: String
    public let modified: Date
    public let dateLabel: String
}

struct StorageExplorerPresentation: Sendable {
    var rows: [StorageExplorerRow] = []
    var chart: [StorageExplorerRow] = []
    var mapRootItems: [StorageItem] = []
    var hierarchy: [StorageExplorerHierarchyNode] = []
    var matchingCount = 0
    var total: Int64 = 0

    static func make(snapshot: StorageExplorerSnapshot, directory: String, mode: StorageExplorerMode,
                     metric: StorageExplorerMetric, query: String, sort: StorageExplorerSort,
                     ascending: Bool, excluding excludedPaths: Set<String> = [],
                     otherName: String = "Other", locale: Locale = .current) -> Self {
        var candidates: [StorageItem]
        switch mode {
        case .folders: candidates = snapshot.children(of: directory)
        case .largestFiles: candidates = snapshot.items.values.filter { !$0.isDirectory || $0.isPackage }
        case .fileTypes:
            var exact = snapshot.fileTypeTotalsByDirectory[directory] ?? snapshot.fileTypeTotals
            if exact.isEmpty {
                for item in snapshot.items.values where !item.isDirectory || item.isPackage {
                    let kind = item.isPackage ? "package" : (item.fileExtension.isEmpty ? "—" : item.fileExtension)
                    exact[kind, default: StorageExplorerSizeTotals()].add(item)
                }
            }
            candidates = exact.map { kind, totals in
                StorageItem(
                    name: kind,
                    path: "type:" + kind,
                    url: URL(fileURLWithPath: "/"),
                    isDirectory: false,
                    size: totals.size,
                    allocatedSize: totals.allocatedSize,
                    childCount: totals.count,
                    isAccessDenied: false
                )
            }
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            candidates = candidates.filter { $0.name.localizedStandardContains(query)
                || (mode == .largestFiles && $0.path.localizedStandardContains(query)) }
        }
        let total = candidates.reduce(Int64(0)) { $0 + metric.bytes($1) }
        let byteStyle = ByteCountFormatStyle(style: .file).locale(locale)
        let dates = DateFormatter()
        dates.locale = locale
        dates.dateStyle = .short
        dates.timeStyle = .none
        func row(_ item: StorageItem) -> StorageExplorerRow {
            let bytes = metric.bytes(item)
            return StorageExplorerRow(item: item, name: item.name, bytes: bytes,
                sizeLabel: bytes.formatted(byteStyle),
                percentage: total > 0 ? (Double(bytes) / Double(total)).formatted(.percent.precision(.fractionLength(1)).locale(locale)) : "—",
                kind: item.isPackage ? "package" : item.isDirectory ? "folder" : item.fileExtension,
                modified: item.modificationDate ?? .distantPast,
                dateLabel: item.modificationDate.map { dates.string(from: $0) } ?? "—")
        }
        let bySize = candidates.sorted {
            metric.bytes($0) == metric.bytes($1) ? $0.path < $1.path : metric.bytes($0) > metric.bytes($1)
        }
        let visibleChart = bySize.prefix(160).filter { metric.bytes($0) > 0 }
        var chart = visibleChart.map(row)
        let remaining = total - visibleChart.reduce(Int64(0)) { $0 + metric.bytes($1) }
        if remaining > 0 {
            let other = StorageItem(name: otherName, path: "group:other", url: URL(fileURLWithPath: "/"),
                isDirectory: false, size: remaining, allocatedSize: remaining)
            chart.append(row(other))
        }
        candidates.sort { lhs, rhs in
            let comparison: ComparisonResult
            switch sort {
            case .name: comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .kind: comparison = lhs.fileExtension.localizedStandardCompare(rhs.fileExtension)
            case .modified:
                let a = lhs.modificationDate ?? .distantPast, b = rhs.modificationDate ?? .distantPast
                comparison = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
            case .size:
                let a = metric.bytes(lhs), b = metric.bytes(rhs)
                comparison = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
            }
            if comparison == .orderedSame { return lhs.path < rhs.path }
            return comparison == (ascending ? .orderedAscending : .orderedDescending)
        }
        let hierarchy = StorageExplorerHierarchyLayout.make(
            snapshot: snapshot,
            directory: directory,
            metric: metric,
            excluding: excludedPaths,
            otherName: otherName
        )
        return Self(
            rows: candidates.prefix(5_000).map(row),
            chart: chart,
            mapRootItems: bySize,
            hierarchy: hierarchy,
            matchingCount: candidates.count,
            total: total
        )
    }
}

/// A balanced area partition bounds layout work and preserves exact proportions without tiny view trees.
struct StorageExplorerTreemapLayout {
    struct Tile: Identifiable, Equatable {
        let row: StorageExplorerRow
        let rect: CGRect
        var id: String { row.id }
    }

    static func tiles(rows: [StorageExplorerRow], in rect: CGRect) -> [Tile] {
        let rows = rows.filter { $0.bytes > 0 }
        guard !rows.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        var result: [Tile] = []
        func split(_ range: Range<Int>, _ box: CGRect) {
            if range.count == 1 { result.append(Tile(row: rows[range.lowerBound], rect: box)); return }
            let total = range.reduce(0.0) { $0 + Double(rows[$1].bytes) }
            var accumulated = 0.0
            var pivot = range.lowerBound
            repeat {
                accumulated += Double(rows[pivot].bytes)
                pivot += 1
            } while pivot < range.upperBound - 1 && accumulated < total / 2
            let fraction = accumulated / total
            let horizontal = box.width >= box.height
            let first = CGRect(x: box.minX, y: box.minY,
                width: horizontal ? box.width * fraction : box.width,
                height: horizontal ? box.height : box.height * fraction)
            let second = CGRect(x: horizontal ? first.maxX : box.minX,
                y: horizontal ? box.minY : first.maxY,
                width: horizontal ? box.width - first.width : box.width,
                height: horizontal ? box.height : box.height - first.height)
            split(range.lowerBound..<pivot, first)
            split(pivot..<range.upperBound, second)
        }
        split(rows.indices, rect)
        return result
    }
}

enum StorageExplorerFormatting {
    static func bytes(_ value: Int64, locale: Locale = PluginRuntimeLocalization.locale) -> String {
        value.formatted(.byteCount(style: .file).locale(locale))
    }
}
