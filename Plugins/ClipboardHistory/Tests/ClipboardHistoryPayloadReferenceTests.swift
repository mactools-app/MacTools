import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardHistoryPayloadReferenceTests: XCTestCase {
    func testConcurrentReadersReceivePayloadWhenCachePublicationIsInvalidated() async throws {
        let payload = ClipboardHistoryPayload.plainText("Shared saved content")
        let started = expectation(description: "Payload read started")
        let release = DispatchSemaphore(value: 0)
        let reference = ClipboardHistoryPayloadReference(loader: {
            started.fulfill()
            release.wait()
            return payload
        })
        defer { release.signal() }
        let owner = Task.detached {
            defer { reference.discardCachedPayloadIfReloadable() }
            return try reference.load()
        }
        await fulfillment(of: [started], timeout: 5)
        let synchronousReader = Task.detached {
            defer { reference.discardCachedPayloadIfReloadable() }
            return try reference.load()
        }
        let joined = await waitForReaders(1, reference: reference)
        XCTAssertTrue(joined)
        // Rebind persistence while both readers share the original read. Its result
        // cannot enter the cache, regardless of which reader resumes first.
        reference.configureLoader({ payload }, discardCachedPayload: true)
        release.signal()

        let original = try await owner.value
        let synchronous = try await synchronousReader.value
        XCTAssertEqual(original, payload)
        XCTAssertEqual(synchronous, payload)
        XCTAssertNil(reference.cached)
    }

    func testFailedReadReportsItsErrorAndAllowsRetry() async throws {
        let payload = ClipboardHistoryPayload.plainText("Readable on retry")
        let loader = RetryPayloadLoader(payload: payload)
        let reference = ClipboardHistoryPayloadReference(loader: { try loader.load() })
        do {
            _ = try await reference.loadAsync()
            XCTFail("An unavailable payload must still report a real read failure")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoSuchFile)
        }
        XCTAssertNil(reference.cached)

        XCTAssertEqual(try reference.load(), payload)
        reference.discardCachedPayloadIfReloadable()
        XCTAssertNil(reference.cached)
    }

    func testCancellingAsyncReaderPreservesTheResultForAWaitingSyncReader() async throws {
        let payload = ClipboardHistoryPayload.plainText("Still selected")
        let started = expectation(description: "Payload read started")
        let release = DispatchSemaphore(value: 0)
        let reference = ClipboardHistoryPayloadReference(loader: {
            started.fulfill()
            release.wait()
            return payload
        })
        defer { release.signal() }
        let cancelledReader = Task { try await reference.loadAsync() }
        await fulfillment(of: [started], timeout: 5)
        let survivingReader = Task.detached {
            defer { reference.discardCachedPayloadIfReloadable() }
            return try reference.load()
        }
        let joined = await waitForReaders(2, reference: reference)
        XCTAssertTrue(joined)
        cancelledReader.cancel()
        do {
            _ = try await cancelledReader.value
            XCTFail("The cancelled reader must not receive the payload")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(reference.cached)
        release.signal()

        let recovered = try await survivingReader.value
        XCTAssertEqual(recovered, payload)
        XCTAssertNil(reference.cached)
    }

    private func waitForReaders(_ count: Int, reference: ClipboardHistoryPayloadReference) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if reference.waitingLoaderCountForTesting == count { return true }
            await Task.yield()
        }
        return false
    }
}

private final class RetryPayloadLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFailed = false
    private let payload: ClipboardHistoryPayload

    init(payload: ClipboardHistoryPayload) { self.payload = payload }

    func load() throws -> ClipboardHistoryPayload {
        try lock.withLock {
            if !hasFailed {
                hasFailed = true
                throw CocoaError(.fileReadNoSuchFile)
            }
            return payload
        }
    }
}
