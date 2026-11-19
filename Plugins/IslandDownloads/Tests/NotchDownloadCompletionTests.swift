import Foundation
import XCTest
@testable import IslandDownloadsPlugin

/// A download whose size its publisher never knew (Firefox reports a total of 0) still gets its
/// completion when it stops being published, but only with the file's own evidence.
final class NotchDownloadCompletionTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folder = folder.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func unknownSize(at url: URL) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = url
        return progress
    }

    func testUnknownSizeDownloadCompletesWhenUnpublishedWithANewFile() throws {
        let url = folder.appendingPathComponent("archive.zip")
        let progress = unknownSize(at: url)
        var publication = try XCTUnwrap(NotchDownloadPublication(NotchDownloadProgressSnapshot(progress), folder: folder))
        // While it runs, a zero total never counts as finished.
        try Data("partial".utf8).write(to: url)
        XCTAssertEqual(publication.item(NotchDownloadProgressSnapshot(progress), folder: folder)?.completed, false)
        try Data("the whole file".utf8).write(to: url)
        let ended = NotchDownloadProgressSnapshot(progress).endedByUnpublishing()
        XCTAssertEqual(publication.item(ended, folder: folder)?.completed, true)
    }

    func testUnpublishingNeverCompletesAnUnchangedExistingFile() throws {
        let url = folder.appendingPathComponent("report.pdf")
        try Data("already here".utf8).write(to: url)
        let progress = unknownSize(at: url)
        var publication = try XCTUnwrap(NotchDownloadPublication(NotchDownloadProgressSnapshot(progress), folder: folder))
        let ended = NotchDownloadProgressSnapshot(progress).endedByUnpublishing()
        XCTAssertNotEqual(publication.item(ended, folder: folder)?.completed, true)
    }

    func testCancelledOrKnownSizeDownloadsAreLeftAsTheyWere() {
        let url = folder.appendingPathComponent("movie.mp4")
        let cancelled = unknownSize(at: url)
        cancelled.cancel()
        XCTAssertFalse(NotchDownloadProgressSnapshot(cancelled).endedByUnpublishing().isFinished)
        let known = Progress(totalUnitCount: 100)
        known.completedUnitCount = 40
        XCTAssertFalse(NotchDownloadProgressSnapshot(known).endedByUnpublishing().isFinished)
    }
}
