import AppKit
import CoreGraphics
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardEmbeddedPreviewPresentationTests: XCTestCase {
    func testRowThumbnailsDoNotReduceDetailResolutionOrRetainSourcePayloads() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1_024, pixelsHigh: 512,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let pdf = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: pdf as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 1_024, height: 512)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        let pngRepresentation = ClipboardStoredRepresentation(
            typeIdentifier: ClipboardRepresentationType.png, data: data
        )
        let pdfRepresentation = ClipboardStoredRepresentation(
            typeIdentifier: ClipboardRepresentationType.pdf, data: pdf as Data
        )
        for representations in [[pngRepresentation], [pdfRepresentation, pngRepresentation]] {
            let payload = ClipboardHistoryPayload(pasteboardItems: [.init(representations: representations)])
            let imageItem = ClipboardHistoryItem(id: UUID(), payload: payload, capturedAt: .now,
                sourceApplication: nil, isPinned: false, lastUsedAt: nil)
            XCTAssertEqual(imageItem.kind, .image)
            imageItem.configurePayloadLoader({ payload }, discardCachedPayload: true)
            let rows = ClipboardEmbeddedPreviewCache.rowThumbnails()
            let details = ClipboardEmbeddedPreviewCache()

            let loadedRow = await rows.image(for: imageItem)
            let rowImage = try XCTUnwrap(loadedRow)
            let rowWidth = try XCTUnwrap(rowImage.representations.first?.pixelsWide)
            XCTAssertLessThanOrEqual(rowWidth, 240)
            XCTAssertNil(imageItem.payload)

            let loadedDetail = await details.image(for: imageItem)
            let detailImage = try XCTUnwrap(loadedDetail)
            XCTAssertEqual(detailImage.representations.first?.pixelsWide, 1_024)
            XCTAssertGreaterThan(detailImage.size.width, rowImage.size.width)
            XCTAssertTrue(rows.cachedImage(for: imageItem) === rowImage)
            XCTAssertNil(imageItem.payload)
        }
    }

    func testInvalidationRejectsPendingThumbnailAndReleasesCachedImages() async {
        let first = item("Cached"), second = item("Deleted while loading")
        let image = NSImage(size: NSSize(width: 120, height: 80))
        let started = expectation(description: "Thumbnail load started")
        var completion: CheckedContinuation<NSImage?, Never>?
        let cache = ClipboardEmbeddedPreviewCache { item in
            if item.id == first.id { return image }
            return await withCheckedContinuation {
                completion = $0
                started.fulfill()
            }
        }
        _ = await cache.image(for: first)
        let request = Task { await cache.image(for: second) }
        await fulfillment(of: [started], timeout: 5)

        cache.retain { _ in false }
        completion?.resume(returning: image)
        let result = await request.value
        XCTAssertNil(result)
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalCost, 0)
    }

    func testCachedSelectionReplacesPendingPreviewAndRejectsItsLateResult() async {
        let first = item("First"), second = item("Second")
        let firstImage = NSImage(size: NSSize(width: 20, height: 20))
        let secondImage = NSImage(size: NSSize(width: 30, height: 30))
        let started = expectation(description: "First preview started")
        var completion: CheckedContinuation<NSImage?, Never>?
        let cache = ClipboardEmbeddedPreviewCache { item in
            if item.id == second.id { return secondImage }
            return await withCheckedContinuation {
                completion = $0
                started.fulfill()
            }
        }
        _ = await cache.image(for: second)
        let presentation = ClipboardEmbeddedPreviewPresentation()
        let pending = Task { await presentation.load(first, cache: cache) }
        await fulfillment(of: [started], timeout: 5)

        await presentation.load(second, cache: cache)
        completion?.resume(returning: firstImage)
        await pending.value

        guard case let .ready(image) = presentation.state else {
            return XCTFail("The current cached selection must remain visible")
        }
        XCTAssertTrue(image === secondImage)
    }

    private func item(_ text: String) -> ClipboardHistoryItem {
        ClipboardHistoryItem(id: UUID(), text: text, capturedAt: .now,
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
    }
}
