import Darwin
import Foundation

public struct FileSystemDirectoryListing: Sendable {
    public var entries: [FileSystemBulkAttributeEntry]
    public var skippedCount: Int
    public init(entries: [FileSystemBulkAttributeEntry] = [], skippedCount: Int = 0) {
        self.entries = entries
        self.skippedCount = skippedCount
    }
}

/// Pass a physical path (resolve /tmp and /var aliases before calling).
/// Metadata-only directory reads. No file payload is opened, and symbolic links are never followed.
public enum FileSystemDirectoryReader {
    public static func read(path: String, cancelled: () -> Bool) throws -> FileSystemDirectoryListing {
        var result = FileSystemDirectoryListing()
        do {
            try readBatches(path: path, cancelled: cancelled) { batch in
                result.entries.append(contentsOf: batch.entries)
                result.skippedCount += batch.skippedCount
            }
        } catch let error as POSIXError where supportsFallback(error.code.rawValue) {
            // This collecting API can discard an earlier partial bulk read before restarting.
            result = FileSystemDirectoryListing()
            try fallback(path: path, cancelled: cancelled) { batch in
                result.entries.append(contentsOf: batch.entries)
                result.skippedCount += batch.skippedCount
            }
        }
        return result
    }

    /// Delivers bounded metadata batches without retaining a whole directory. Previously
    /// delivered batches remain valid if a later read fails; callers must mark the scan incomplete.
    public static func readBatches(
        path: String,
        cancelled: () -> Bool,
        consume: (FileSystemDirectoryListing) throws -> Void
    ) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var attributes = FileSystemBulkAttributeParser.makeAttributeList(includeStorageDetails: true)
        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        var deliveredBatch = false
        while true {
            if cancelled() { throw CancellationError() }
            let count = getattrlistbulk(fd, &attributes, buffer, capacity, 0)
            if count < 0 {
                // Restart only before delivery: a streamed consumer cannot roll back prior batches.
                if !deliveredBatch, supportsFallback(errno) {
                    return try fallback(path: path, cancelled: cancelled, consume: consume)
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { return }
            let parsed = FileSystemBulkAttributeParser.parse(
                buffer: UnsafeRawBufferPointer(start: buffer, count: capacity), entryCount: Int(count)
            )
            var result = FileSystemDirectoryListing()
            result.entries.reserveCapacity(parsed.entries.count)
            if parsed.isTruncated { result.skippedCount += 1 }
            for var entry in parsed.entries {
                guard let name = entry.nameBytes else { result.skippedCount += 1; continue }
                if !entry.isFullyResolved || entry.flags == nil || entry.modificationDate == nil
                    || (entry.fileType != .directory && entry.allocatedSize == nil) {
                    guard let resolved = statEntry(name: name, fd: fd) else {
                        result.skippedCount += 1
                        continue
                    }
                    entry = resolved
                }
                result.entries.append(entry)
            }
            deliveredBatch = true
            try consume(result)
        }
    }

    private static func supportsFallback(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EINVAL || code == ENOSYS
    }

    private static func fallback(
        path: String,
        cancelled: () -> Bool,
        consume: (FileSystemDirectoryListing) throws -> Void
    ) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let directory = fdopendir(fd) else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { closedir(directory) }
        var result = FileSystemDirectoryListing()
        while true {
            if cancelled() { throw CancellationError() }
            errno = 0
            guard let pointer = readdir(directory) else {
                if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if !result.entries.isEmpty || result.skippedCount > 0 { try consume(result) }
                return
            }
            let name: [CChar] = withUnsafeBytes(of: pointer.pointee.d_name) { bytes in
                Array(bytes.prefix { $0 != 0 }.map { CChar(bitPattern: $0) }) + [0]
            }
            if name == [46, 0] || name == [46, 46, 0] { continue }
            if let entry = statEntry(name: name, fd: fd) { result.entries.append(entry) }
            else { result.skippedCount += 1 }
            if result.entries.count + result.skippedCount >= 256 {
                try consume(result)
                result = FileSystemDirectoryListing()
            }
        }
    }

    private static func statEntry(name: [CChar], fd: Int32) -> FileSystemBulkAttributeEntry? {
        var status = stat()
        guard name.withUnsafeBufferPointer({ fstatat(fd, $0.baseAddress!, &status, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            return nil
        }
        var entry = FileSystemBulkAttributeEntry()
        entry.nameBytes = name
        switch status.st_mode & S_IFMT {
        case S_IFDIR: entry.fileType = .directory
        case S_IFREG: entry.fileType = .regularFile
        case S_IFLNK: entry.fileType = .symlink
        default: entry.fileType = .other
        }
        entry.devid = UInt64(UInt32(bitPattern: status.st_dev))
        entry.fileID = status.st_ino
        entry.linkCount = UInt32(status.st_nlink)
        entry.dataLength = max(status.st_size, 0)
        entry.allocatedSize = max(Int64(status.st_blocks) * 512, 0)
        entry.flags = status.st_flags
        entry.modificationDate = Date(timeIntervalSince1970: Double(status.st_mtimespec.tv_sec)
            + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000)
        return entry
    }
}
