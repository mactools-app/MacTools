import AppKit
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardPasteboardReaderProcessTests: XCTestCase {

    @MainActor
    func testHelperReadsMultipleClipboardRevisionsWithoutRelaunching() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            requestTimeout: .seconds(2)
        )
        defer { Task { await reader.stop() } }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("first", forType: .string))
        let firstRequest = request(for: pasteboard)
        let first = try await readPublishedRevision(firstRequest, from: pasteboard, using: reader)
        XCTAssertEqual(plainText(in: first), "first")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("second", forType: .string))
        let secondRequest = request(for: pasteboard)
        XCTAssertGreaterThan(secondRequest.expectedChangeCount, firstRequest.expectedChangeCount)
        let second = try await readPublishedRevision(secondRequest, from: pasteboard, using: reader)
        XCTAssertEqual(plainText(in: second), "second")
        let stale = try await reader.read(firstRequest)
        XCTAssertEqual(stale.status, .changed, "A published newer revision must reject the stale request")
        let launchCount = await reader.launchCountForTesting
        XCTAssertEqual(launchCount, 1)
    }

    @MainActor
    func testPlainTextRequestRejectsSensitiveProducerTypesAndRecovers() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let sensitiveItem = NSPasteboardItem()
        XCTAssertTrue(sensitiveItem.setString("secret", forType: .string))
        XCTAssertTrue(sensitiveItem.setData(Data(), forType: .init("org.nspasteboard.ConcealedType")))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([sensitiveItem]))
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            requestTimeout: .seconds(2)
        )
        defer { Task { await reader.stop() } }

        let sensitiveResponse = try await readPublishedRevision(
            request(for: pasteboard, kind: .plainText),
            from: pasteboard, using: reader, expectedStatus: .unsafe
        )
        XCTAssertEqual(sensitiveResponse.status, .unsafe)
        XCTAssertNil(plainText(in: sensitiveResponse))

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("public", forType: .string))
        let recovered = try await readPublishedRevision(
            request(for: pasteboard, kind: .plainText), from: pasteboard, using: reader
        )
        XCTAssertEqual(plainText(in: recovered), "public")
    }

    @MainActor
    func testPlainTextRequestEnforcesByteLimitAndReaderRecovers() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            requestTimeout: .seconds(2)
        )
        defer { Task { await reader.stop() } }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("too long", forType: .string))
        let oversized = try await readPublishedRevision(
            request(for: pasteboard, kind: .plainText, maximumByteCount: 3),
            from: pasteboard, using: reader, expectedStatus: .oversized
        )
        XCTAssertEqual(oversized.status, .oversized)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("ok", forType: .string))
        let recovered = try await readPublishedRevision(
            request(for: pasteboard, kind: .plainText), from: pasteboard, using: reader
        )
        XCTAssertEqual(plainText(in: recovered), "ok")
    }

    func testNeverRespondingHelperIsKilledWithinDeadline() async throws {
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { URL(fileURLWithPath: "/bin/sleep") },
            helperArguments: ["60"],
            requestTimeout: .milliseconds(50)
        )
        let request = ClipboardPasteboardReaderRequest(
            pasteboardName: NSPasteboard.Name.general.rawValue,
            maximumByteCount: 1_024,
            expectedChangeCount: NSPasteboard.general.changeCount
        )

        do {
            _ = try await reader.read(request)
            XCTFail("A helper that never responds must time out")
        } catch {
            XCTAssertTrue(error is ClipboardPasteboardReaderProcess.TimeoutError
                || error is ClipboardPasteboardReaderWireError)
        }
        let hasLiveSession = await reader.hasLiveSessionForTesting
        let launchCount = await reader.launchCountForTesting
        XCTAssertFalse(hasLiveSession)
        XCTAssertEqual(launchCount, 1)
    }

    func testExitedHelperIsRelaunchedForTheNextClipboardRevision() async throws {
        let helperURL = try XCTUnwrap(Self.helperURL)
        let pasteboard = NSPasteboard.withUniqueName()
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { helperURL },
            helperArguments: [
                "--maximum-requests", "1",
                "--linger-after-maximum-requests-milliseconds", "250",
            ],
            requestTimeout: .seconds(2)
        )
        defer { Task { await reader.stop() } }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("first", forType: .string))
        let first = try await reader.read(request(for: pasteboard))
        XCTAssertEqual(plainText(in: first), "first")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("second", forType: .string))
        let second = try await reader.read(request(for: pasteboard))
        XCTAssertEqual(plainText(in: second), "second")
        let launchCount = await reader.launchCountForTesting
        XCTAssertEqual(launchCount, 2)
    }

    @MainActor
    private func readPublishedRevision(
        _ request: ClipboardPasteboardReaderRequest,
        from pasteboard: NSPasteboard,
        using reader: ClipboardPasteboardReaderProcess,
        expectedStatus: ClipboardPasteboardReaderResponse.Status = .payload
    ) async throws -> ClipboardPasteboardReaderResponse {
        // A named pasteboard crosses processes. Wait only for publication of this
        // exact revision; never replace the request with a newer change count.
        let deadline = ContinuousClock.now + .seconds(2)
        var response = try await reader.read(request)
        while (response.status == .changed || response.status == .empty), ContinuousClock.now < deadline {
            guard pasteboard.changeCount == request.expectedChangeCount else {
                XCTFail("The test pasteboard changed while waiting for its published revision")
                return response
            }
            try await Task.sleep(for: .milliseconds(10))
            response = try await reader.read(request)
        }
        XCTAssertEqual(response.status, expectedStatus,
                       "Expected the published revision, received \(response.status)")
        return response
    }

    private func request(
        for pasteboard: NSPasteboard,
        kind: ClipboardPasteboardReaderRequest.Kind = .payload,
        maximumByteCount: Int = 1_024 * 1_024
    ) -> ClipboardPasteboardReaderRequest {
        ClipboardPasteboardReaderRequest(
            kind: kind,
            pasteboardName: pasteboard.name.rawValue,
            maximumByteCount: maximumByteCount,
            expectedChangeCount: pasteboard.changeCount
        )
    }

    private func plainText(in response: ClipboardPasteboardReaderResponse) -> String? {
        response.items.lazy
            .flatMap(\.representations)
            .first { $0.typeIdentifier == ClipboardRepresentationType.plainText }
            .flatMap { String(data: $0.data, encoding: .utf8) }
    }

    private static var helperURL: URL? {
        var directory = Bundle(for: Self.self).bundleURL
        while directory.path != "/" {
            let candidate = directory
                .appendingPathComponent("ClipboardHistory.bundle", isDirectory: true)
                .appendingPathComponent("Contents/Resources/PasteboardReaderHelper", isDirectory: true)
                .appendingPathComponent("mactools-clipboard-pasteboard-reader-helper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
