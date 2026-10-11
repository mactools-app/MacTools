import Foundation
import SwiftUI

// MARK: - Inode Identity for Hard Link Deduplication

public struct StorageFileInode: Hashable, Sendable, Codable {
    public let device: dev_t
    public let inode: ino_t

    public init(device: dev_t, inode: ino_t) {
        self.device = device
        self.inode = inode
    }
}

// MARK: - Storage Item

public struct StorageItem: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let path: String
    public let url: URL
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymlink: Bool
    public var size: Int64
    public var allocatedSize: Int64
    public let modificationDate: Date?
    public var childCount: Int
    public var children: [StorageItem]
    public var isAccessDenied: Bool
    public var parentPath: String?
    public var isIncomplete: Bool = false
    public var isCloudPlaceholder: Bool = false
    public var scannedCount: Int = 1
    public var skippedCount: Int = 0
    public let fileIdentity: StorageFileInode?
    /// The file length observed on disk before hard-link accounting is deduplicated.
    public let observedFileSize: Int64
    public let hardLinkCount: UInt32

    public init(
        id: String? = nil,
        name: String,
        path: String,
        url: URL,
        isDirectory: Bool,
        isPackage: Bool = false,
        isSymlink: Bool = false,
        size: Int64 = 0,
        allocatedSize: Int64 = 0,
        modificationDate: Date? = nil,
        childCount: Int = 0,
        children: [StorageItem] = [],
        isAccessDenied: Bool = false,
        parentPath: String? = nil,
        fileIdentity: StorageFileInode? = nil,
        observedFileSize: Int64? = nil,
        hardLinkCount: UInt32 = 1
    ) {
        self.id = id ?? path
        self.name = name
        self.path = path
        self.url = url
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.size = size
        self.allocatedSize = allocatedSize
        self.modificationDate = modificationDate
        self.childCount = childCount
        self.children = children
        self.parentPath = parentPath
        self.isAccessDenied = isAccessDenied
        self.fileIdentity = fileIdentity
        self.observedFileSize = observedFileSize ?? size
        self.hardLinkCount = hardLinkCount
    }

    public var fileExtension: String {
        url.pathExtension.lowercased()
    }

    public var iconSystemName: String {
        if isDirectory {
            if isPackage {
                return "shippingbox.fill"
            }
            return "folder.fill"
        }

        switch fileExtension {
        case "dmg", "iso", "pkg":
            return "opticaldisc"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar":
            return "archivebox.fill"
        case "mov", "mp4", "mkv", "avi", "webm":
            return "film.fill"
        case "mp3", "m4a", "flac", "wav", "aac":
            return "music.note"
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "raw":
            return "photo.fill"
        case "swift", "py", "js", "ts", "rs", "c", "cpp", "h", "java", "go", "rb", "sh", "json", "yml", "yaml", "toml":
            return "curlybraces"
        case "pdf":
            return "doc.richtext.fill"
        case "app":
            return "app.dashed"
        default:
            return "doc.fill"
        }
    }

    public var formattedSize: String {
        StorageExplorerFormatting.bytes(size)
    }

    public var isHardLinked: Bool { hardLinkCount > 1 }

    public static func == (lhs: StorageItem, rhs: StorageItem) -> Bool {
        lhs.path == rhs.path && lhs.size == rhs.size && lhs.allocatedSize == rhs.allocatedSize
            && lhs.childCount == rhs.childCount && lhs.isIncomplete == rhs.isIncomplete
            && lhs.isAccessDenied == rhs.isAccessDenied && lhs.modificationDate == rhs.modificationDate
            && lhs.skippedCount == rhs.skippedCount && lhs.scannedCount == rhs.scannedCount
            && lhs.isCloudPlaceholder == rhs.isCloudPlaceholder
            && lhs.fileIdentity == rhs.fileIdentity
            && lhs.observedFileSize == rhs.observedFileSize
            && lhs.hardLinkCount == rhs.hardLinkCount
    }
}

public struct StorageExplorerSizeTotals: Sendable, Equatable, Codable {
    public var size: Int64 = 0
    public var allocatedSize: Int64 = 0
    public var count: Int = 0
    public var isIncomplete = false

    public mutating func add(_ item: StorageItem) {
        size += item.size
        allocatedSize += item.allocatedSize
        count += 1
        isIncomplete = isIncomplete || item.isIncomplete
    }

    public mutating func add(_ other: Self) {
        size += other.size
        allocatedSize += other.allocatedSize
        count += other.count
        isIncomplete = isIncomplete || other.isIncomplete
    }
}

public enum StorageExplorerReviewEligibility: Equatable, Sendable {
    case eligible
    case selected
    case includedBySelectedParent(name: String)
    case busy
    case incomplete(skippedCount: Int)
    case symlink
    case aggregate
    case cachedPreview
    case scanRoot
    case protectedLocation
    case unavailable

    public var canAdd: Bool {
        switch self {
        case .eligible, .incomplete:
            true
        default:
            false
        }
    }

    public var canToggle: Bool {
        switch self {
        case .eligible, .incomplete, .selected:
            true
        default:
            false
        }
    }
}

// MARK: - Scan Progress and State

public enum StorageExplorerScanPhase: String, Sendable, Equatable, Codable {
    case enumerating
    case finalizing
}

public struct StorageExplorerScanProgress: Sendable, Equatable, Codable {
    public var filesScanned: Int
    public var bytesScanned: Int64
    public var allocatedBytesScanned: Int64
    public var currentPath: String
    public var elapsed: TimeInterval = 0
    public var skippedCount: Int = 0
    public var cachedDirectories: Int = 0
    public var phase: StorageExplorerScanPhase = .enumerating

    public init(
        filesScanned: Int = 0,
        bytesScanned: Int64 = 0,
        allocatedBytesScanned: Int64 = 0,
        currentPath: String = ""
    ) {
        self.filesScanned = filesScanned
        self.bytesScanned = bytesScanned
        self.allocatedBytesScanned = allocatedBytesScanned
        self.currentPath = currentPath
    }
}

public enum StorageExplorerScanState: Sendable, Equatable {
    case idle
    case scanning(StorageExplorerScanProgress)
    case completed
    case failed(String)
    case cancelled
}
