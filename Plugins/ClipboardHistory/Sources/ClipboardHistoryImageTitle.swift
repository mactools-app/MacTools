import Foundation

/// Resolves display text from stored metadata without reading the image payload.
enum ClipboardHistoryImageTitle {
    private static let maximumExcerptCharacterCount = 120
    private static let precedingContextCharacterCount = 24

    static func title(for item: ClipboardHistoryItem, query: String, fallback: String) -> String {
        let savedTitle = normalizedWhitespace(item.savedMetadata?.title ?? "")
        if !savedTitle.isEmpty { return savedTitle }

        let capturedText = normalizedWhitespace(item.text)
        if !capturedText.isEmpty { return excerpt(capturedText) }

        let recognizedText = normalizedWhitespace(item.imageSearchText ?? "")
        guard !recognizedText.isEmpty else { return fallback }
        return excerpt(recognizedText, query: ClipboardHistorySearch.PreparedQuery(query))
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func excerpt(
        _ text: String,
        query: ClipboardHistorySearch.PreparedQuery? = nil
    ) -> String {
        guard text.count > maximumExcerptCharacterCount else { return text }
        var start = text.startIndex
        if let query, !query.isEmpty, let match = matchingRange(in: text, query: query) {
            start = text.index(
                match.lowerBound, offsetBy: -precedingContextCharacterCount,
                limitedBy: text.startIndex
            ) ?? text.startIndex
        }
        let end = text.index(start, offsetBy: maximumExcerptCharacterCount, limitedBy: text.endIndex)
            ?? text.endIndex
        let content = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > text.startIndex ? "…" : "") + content + (end < text.endIndex ? "…" : "")
    }

    private static func matchingRange(
        in text: String,
        query: ClipboardHistorySearch.PreparedQuery
    ) -> Range<String.Index>? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        if let range = text.range(of: query.normalizedText, options: options, locale: .current) {
            return range
        }
        // Search can match separate terms without an exact phrase. Keep the earliest
        // matching term visible while leaving the search engine's ordering untouched.
        return query.tokens.compactMap {
            text.range(of: $0, options: options, locale: .current)
        }.min { $0.lowerBound < $1.lowerBound }
    }
}
