import Darwin

/// Bulk discovery with a streaming fallback before the first batch is delivered.
struct DiskCleanDiscoveryEntrySourceFactory: DiskCleanDirectoryEntrySourceFactory {
    private let bulkSourceFactory: any DiskCleanDirectoryEntrySourceFactory
    private let streamSourceFactory: any DiskCleanDirectoryEntrySourceFactory

    init(
        bulkSourceFactory: any DiskCleanDirectoryEntrySourceFactory = DiskCleanBulkEntrySourceFactory(),
        streamSourceFactory: any DiskCleanDirectoryEntrySourceFactory = DiskCleanDirectoryStreamEntrySourceFactory()
    ) {
        self.bulkSourceFactory = bulkSourceFactory
        self.streamSourceFactory = streamSourceFactory
    }

    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource {
        DiskCleanDiscoveryEntrySource(
            source: try bulkSourceFactory.makeSource(fileDescriptor: fileDescriptor),
            streamSourceFactory: streamSourceFactory
        )
    }
}

private final class DiskCleanDiscoveryEntrySource: DiskCleanDirectoryEntrySource {
    private var source: any DiskCleanDirectoryEntrySource
    private let streamSourceFactory: any DiskCleanDirectoryEntrySourceFactory
    private var canFallBack = true
    private var isClosed = false

    var directoryFileDescriptor: Int32 { source.directoryFileDescriptor }

    init(
        source: any DiskCleanDirectoryEntrySource,
        streamSourceFactory: any DiskCleanDirectoryEntrySourceFactory
    ) {
        self.source = source
        self.streamSourceFactory = streamSourceFactory
    }

    deinit { close() }

    func nextBatch() throws -> [DiskCleanWalkEntry]? {
        guard !isClosed else { return nil }
        do {
            let batch = try source.nextBatch()
            canFallBack = false
            return batch
        } catch let error as DiskCleanPOSIXError
            where canFallBack && (error.code == ENOTSUP || error.code == EINVAL || error.code == ENOSYS) {
            canFallBack = false
            // Open a new description at offset zero, anchored to the original directory.
            // Reopening its path could follow a replacement directory or symbolic link.
            let descriptor = openat(
                source.directoryFileDescriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK
            )
            guard descriptor >= 0 else { throw DiskCleanPOSIXError(code: errno) }
            let fallback: any DiskCleanDirectoryEntrySource
            do {
                fallback = try streamSourceFactory.makeSource(fileDescriptor: descriptor)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            source.close()
            source = fallback
            return try source.nextBatch()
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        source.close()
    }
}
