import Foundation
import XCTest
@testable import SystemDataPlugin

@MainActor
final class SystemDataControllerTests: XCTestCase {
    func testCompletedScanPublishesGroupsSummaryAndNotifiesHost() async throws {
        let scanner = SystemDataImmediateScanner(result: SystemDataTestFixtures.result())
        let controller = SystemDataController(
            scanner: scanner,
            definitions: SystemDataTestFixtures.definitions
        )
        var notifications = 0
        controller.onStateChange = { notifications += 1 }

        controller.scan()
        try await waitUntil { controller.state == .completed }

        XCTAssertEqual(controller.groups.map(\.id), ["group-a", "group-b"])
        XCTAssertEqual(controller.groups[0].items.first?.bytes, 1000)
        XCTAssertEqual(controller.groups[1].items.map(\.bytes), [300, 200])
        XCTAssertEqual(controller.summary?.totalBytes, 1500)
        XCTAssertEqual(controller.summary?.availableBytes, 5000)
        XCTAssertEqual(controller.summary?.capacityBytes, 100_000)
        XCTAssertEqual(controller.summary?.measuredItemCount, 3)
        XCTAssertGreaterThan(notifications, 0)
    }

    func testStaleScanProgressAndCompletionCannotReplaceNewerScan() async throws {
        let scanner = SystemDataManualScanner()
        let controller = SystemDataController(
            scanner: scanner,
            definitions: SystemDataTestFixtures.definitions
        )

        controller.scan()
        try await waitUntil { scanner.ids.count == 1 }
        let firstID = scanner.ids[0]

        // Queue first-scan progress, then start a second scan on the same
        // actor: the queued hop must lose to the new generation.
        scanner.emit(SystemDataTestFixtures.progress(completed: 7, bytes: 999), to: firstID)
        controller.scan()
        try await waitUntil { scanner.ids.count == 2 }
        let secondID = scanner.ids[1]

        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.state, .scanning(.zero))

        scanner.emit(SystemDataTestFixtures.progress(completed: 3, bytes: 120), to: secondID)
        try await waitUntil {
            controller.state == .scanning(SystemDataTestFixtures.progress(completed: 3, bytes: 120))
        }

        // A result from the dead scan arrives late and must be ignored.
        scanner.finish(id: firstID, result: SystemDataTestFixtures.result(a1Bytes: 111))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(controller.state == .completed, "stale completion must be ignored")

        scanner.finish(id: secondID, result: SystemDataTestFixtures.result(a1Bytes: 222))
        try await waitUntil { controller.state == .completed }
        XCTAssertEqual(
            controller.groups.first { $0.id == "group-a" }?.items.first?.bytes,
            222
        )

        // Progress landing after the snapshot must not regress the terminal state.
        scanner.emit(SystemDataTestFixtures.progress(completed: 10), to: secondID)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.state, .completed)
    }

    func testCancelKeepsLastSnapshotAndMarksCancelled() async throws {
        let scanner = SystemDataManualScanner()
        let controller = SystemDataController(
            scanner: scanner,
            definitions: SystemDataTestFixtures.definitions
        )

        controller.scan()
        try await waitUntil { scanner.ids.count == 1 }
        scanner.finish(id: scanner.ids[0], result: SystemDataTestFixtures.result())
        try await waitUntil { controller.state == .completed }
        let snapshot = controller.groups

        controller.scan()
        try await waitUntil { scanner.ids.count == 2 }
        controller.cancel()

        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertEqual(controller.groups, snapshot)
        XCTAssertNotNil(controller.summary)

        // The cancelled scan settles late with CancellationError; the bumped
        // generation keeps the terminal state instead of rewriting it.
        scanner.fail(id: scanner.ids[1], error: CancellationError())
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertEqual(controller.groups, snapshot)
    }

    func testScanFailurePublishesLocalizedMessage() async throws {
        let scanner = SystemDataImmediateScanner(failureMessage: "boom")
        let controller = SystemDataController(
            scanner: scanner,
            definitions: SystemDataTestFixtures.definitions
        )

        controller.scan()
        try await waitUntil { controller.state == .failed("boom") }
        XCTAssertTrue(controller.groups.isEmpty)
        XCTAssertNil(controller.summary)
    }

    func testProgressAfterCompletionIsDroppedForSameGeneration() async throws {
        let scanner = SystemDataManualScanner()
        let controller = SystemDataController(
            scanner: scanner,
            definitions: SystemDataTestFixtures.definitions
        )

        controller.scan()
        try await waitUntil { scanner.ids.count == 1 }
        let id = scanner.ids[0]
        scanner.finish(id: id, result: SystemDataTestFixtures.result())
        try await waitUntil { controller.state == .completed }

        scanner.emit(SystemDataTestFixtures.progress(completed: 4), to: id)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.state, .completed)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        if predicate() { return }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }
}
