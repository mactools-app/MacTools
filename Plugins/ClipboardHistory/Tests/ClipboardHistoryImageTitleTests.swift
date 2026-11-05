import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardHistoryImageTitleTests: XCTestCase {
    func testSavedNameAndCapturedTextTakePriorityOverRecognizedTextAndSearch() {
        var image = item(capturedText: "\n Captured\tcaption ", recognizedText: "Recognized content")
        XCTAssertEqual(title(image, query: "content"), "Captured caption")

        image.setSavedMetadata(.init(title: "  My\n screenshot  "))
        for query in ["", "content", "caption"] {
            XCTAssertEqual(title(image, query: query), "My screenshot")
        }
    }

    func testSearchExcerptIncludesLateMatchingPhraseOrSeparateTerms() {
        let recognized = String(repeating: "Navigation item\n", count: 12)
            + "Voice Control settings\nEnable selected features."
            + String(repeating: " Additional details.", count: 8)
        let image = item(recognizedText: recognized)
        XCTAssertFalse(title(image).contains("Voice Control"))
        for query in ["control settings", "settings voice"] {
            let result = title(image, query: query)
            XCTAssertTrue(result.contains("Voice Control settings"))
            XCTAssertFalse(result.contains("\n"))
        }
    }

    func testSearchExcerptMatchesCaseDiacriticsAndCharacterWidth() {
        let image = item(recognizedText: String(repeating: "Menu item ", count: 20)
            + "ＣＡＦÉ settings and preferences")
        XCTAssertTrue(title(image, query: "cafe").contains("ＣＡＦÉ settings"))
    }

    func testFallbackAndCompletedRecognitionUseMetadataWithoutLoadingPayloads() {
        var image = item(recognizedText: " \n\t ")
        image.configurePayloadLoader({
            XCTFail("List titles must never load image payloads")
            throw CocoaError(.fileReadNoSuchFile)
        }, discardCachedPayload: true)
        XCTAssertEqual(title(image), "图片")
        image.setImageSearchText("\n Voice\tControl\n settings  ")
        XCTAssertEqual(title(image), "Voice Control settings")
        XCTAssertEqual(title(image, query: "unrelated source name"), "Voice Control settings")
        XCTAssertNil(image.payload)
    }

    private func title(_ item: ClipboardHistoryItem, query: String = "") -> String {
        ClipboardHistoryImageTitle.title(for: item, query: query, fallback: "图片")
    }

    private func item(capturedText: String? = nil, recognizedText: String? = nil) -> ClipboardHistoryItem {
        var representations = [ClipboardStoredRepresentation(
            typeIdentifier: ClipboardRepresentationType.png, data: Data([0x01])
        )]
        if let capturedText {
            representations.append(.init(typeIdentifier: ClipboardRepresentationType.plainText,
                data: Data(capturedText.utf8)))
        }
        return ClipboardHistoryItem(id: UUID(),
            payload: .init(pasteboardItems: [.init(representations: representations)]),
            capturedAt: .now, sourceApplication: nil, isPinned: false, lastUsedAt: nil,
            imageSearchText: recognizedText)
    }
}
