import Foundation
import MacToolsPluginKit

/// How safe it would be to remove a location, using the familiar
/// regenerable / review / reference-only vocabulary. This plugin only measures
/// and reveals; the badge tells users what a cleanup tool may do with the
/// location later.
public enum SystemDataBadge: String, Sendable, Equatable, Comparable {
    case safe
    case review
    case manual

    private var severity: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .manual: 2
        }
    }

    public static func < (lhs: SystemDataBadge, rhs: SystemDataBadge) -> Bool {
        lhs.severity < rhs.severity
    }

    /// The strongest badge wins: a group with any review-worthy item is review-worthy.
    public func merged(with other: SystemDataBadge) -> SystemDataBadge {
        max(self, other)
    }
}

/// A label that is either resolved through the plugin string catalog at render
/// time or used verbatim (dynamic directory names from a scan).
public enum SystemDataLabel: Equatable, Sendable {
    case localized(key: String, fallback: String)
    case literal(String)

    public func resolve(_ localization: PluginLocalization) -> String {
        switch self {
        case let .localized(key, fallback):
            localization.string(key, defaultValue: fallback)
        case let .literal(name):
            name
        }
    }
}

public enum SystemDataItemStatus: Equatable, Sendable {
    case measured(bytes: Int64)
    case absent
    case unreadable

    public var bytes: Int64 {
        switch self {
        case let .measured(bytes): bytes
        case .absent, .unreadable: 0
        }
    }

    public var isMeasured: Bool {
        if case .measured = self { return true }
        return false
    }
}

public struct SystemDataItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: SystemDataLabel
    public let path: String
    public let badge: SystemDataBadge
    public let status: SystemDataItemStatus

    public init(
        id: String,
        label: SystemDataLabel,
        path: String,
        badge: SystemDataBadge,
        status: SystemDataItemStatus
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.badge = badge
        self.status = status
    }

    public var bytes: Int64 { status.bytes }
}

public struct SystemDataGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: SystemDataLabel
    public let systemImage: String
    public let items: [SystemDataItem]

    public init(
        id: String,
        label: SystemDataLabel,
        systemImage: String,
        items: [SystemDataItem]
    ) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.items = items
    }

    public var bytes: Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    /// Strongest badge among measured items; reference-only when nothing measured.
    public var badge: SystemDataBadge {
        items.filter { $0.status.isMeasured }.map(\.badge).max() ?? .manual
    }

    public var measuredItemCount: Int {
        items.filter { $0.status.isMeasured }.count
    }

    public var unavailableItemCount: Int {
        items.count - measuredItemCount
    }
}

public struct SystemDataScanProgress: Equatable, Sendable {
    public let completedItems: Int
    public let totalItems: Int
    public let directoriesRead: Int
    public let bytesFound: Int64

    public init(
        completedItems: Int,
        totalItems: Int,
        directoriesRead: Int,
        bytesFound: Int64
    ) {
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.directoriesRead = directoriesRead
        self.bytesFound = bytesFound
    }

    public static let zero = SystemDataScanProgress(
        completedItems: 0,
        totalItems: 0,
        directoriesRead: 0,
        bytesFound: 0
    )
}

public enum SystemDataScanState: Equatable, Sendable {
    case idle
    case scanning(SystemDataScanProgress)
    case completed
    case cancelled
    case failed(String)

    public var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }

    public var failureMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

public struct SystemDataScanSummary: Equatable, Sendable {
    public let totalBytes: Int64
    public let availableBytes: Int64?
    public let capacityBytes: Int64?
    public let itemCount: Int
    public let measuredItemCount: Int
    public let scannedAt: Date

    public init(
        totalBytes: Int64,
        availableBytes: Int64?,
        capacityBytes: Int64?,
        itemCount: Int,
        measuredItemCount: Int,
        scannedAt: Date
    ) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.capacityBytes = capacityBytes
        self.itemCount = itemCount
        self.measuredItemCount = measuredItemCount
        self.scannedAt = scannedAt
    }
}

// MARK: - Scanner output

/// One measured entry of a "children" probe: a direct subdirectory of the
/// probe parent, or the synthetic bucket for the parent's own files.
public struct SystemDataChildMeasurement: Equatable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let bytes: Int64
    public let isSyntheticFiles: Bool
    public let isUnreadable: Bool
    /// Installed-app display name for a bundle-id-like directory (for example
    /// `com.docker.docker` → "Docker"); nil keeps the raw directory name.
    public let displayName: String?

    public init(
        id: String,
        name: String,
        path: String,
        bytes: Int64,
        isSyntheticFiles: Bool = false,
        isUnreadable: Bool = false,
        displayName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.bytes = bytes
        self.isSyntheticFiles = isSyntheticFiles
        self.isUnreadable = isUnreadable
        self.displayName = displayName
    }
}

public struct SystemDataJobResult: Equatable, Sendable {
    public let itemID: String
    public let status: SystemDataItemStatus
    public let children: [SystemDataChildMeasurement]
    /// The dynamic location actually measured, when the definition declares a
    /// path resolver; nil keeps the static template for display and reveal.
    public let resolvedPath: String?

    public init(
        itemID: String,
        status: SystemDataItemStatus,
        children: [SystemDataChildMeasurement] = [],
        resolvedPath: String? = nil
    ) {
        self.itemID = itemID
        self.status = status
        self.children = children
        self.resolvedPath = resolvedPath
    }
}

public struct SystemDataScanResult: Equatable, Sendable {
    public let results: [SystemDataJobResult]
    public let availableBytes: Int64?
    public let capacityBytes: Int64?
    public let finishedAt: Date

    public init(
        results: [SystemDataJobResult],
        availableBytes: Int64?,
        capacityBytes: Int64?,
        finishedAt: Date
    ) {
        self.results = results
        self.availableBytes = availableBytes
        self.capacityBytes = capacityBytes
        self.finishedAt = finishedAt
    }
}

// MARK: - Formatting

/// Byte text shared by the panel and the workspace. Sizes are allocated blocks
/// on disk, so they match what Finder reports for the same folders.
public enum SystemDataFormatting {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    public static func bytes(_ value: Int64) -> String {
        let metric = metric(value)
        return metric.value + " " + metric.unit
    }

    /// Splits a size into value and unit for `PluginMetricValue`.
    public static func metric(_ value: Int64) -> (value: String, unit: String) {
        guard value > 0 else { return ("0", "B") }
        var size = Double(value)
        var unitIndex = 0
        while size >= 1024, unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return ("\(Int(size))", units[unitIndex])
        }
        let number = size < 10
            ? String(format: "%.1f", size)
            : String(format: "%.0f", size)
        return (number, units[unitIndex])
    }
}
