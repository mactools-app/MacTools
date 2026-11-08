import Foundation

/// Reads the catalog responses already downloaded by Music.app. This provider
/// never uses Apple account credentials and never makes a network request.
final class AppleMusicCacheLyricsProvider: @unchecked Sendable {
    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let databaseURL: URL
    private let maximumCandidates = 160
    private let metadataMatcher = TrackMetadataMatcher()

    init(
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        let root = cacheDirectory
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/com.apple.Music", isDirectory: true)
        self.cacheDirectory = root.appendingPathComponent("fsCachedData", isDirectory: true)
        self.databaseURL = root.appendingPathComponent("Cache.db")
    }

    func lyrics(for track: TrackInfo) -> LyricsDocument {
        var best: (match: TrackMetadataMatch, song: CatalogSong)?
        var readableCandidates = 0
        var decodedResponses = 0
        var songsExamined = 0

        let candidates = candidates()
        for candidate in candidates {
            guard let data = candidate.data() else {
                continue
            }
            readableCandidates += 1
            guard let response = try? JSONDecoder().decode(CatalogResponse.self, from: data) else {
                continue
            }
            decodedResponses += 1

            for song in response.data {
                songsExamined += 1
                guard song.relationships?.syllableLyrics?.data.first?.attributes.ttmlLocalizations != nil,
                      let match = metadataMatcher.match(song.attributes, to: track) else {
                    continue
                }
                if best == nil || match.score > best!.match.score {
                    best = (match, song)
                }
            }

            // Exact metadata plus duration is definitive; candidates are newest first.
            if best?.match.score ?? 0 >= 180 { break }
        }

        guard let song = best?.song else {
            return .empty
        }
        guard let rawTTML = song.relationships?.syllableLyrics?.data.first?.attributes.ttmlLocalizations,
              let selection = localizedTTML(from: rawTTML) else {
            return .empty
        }
        let parsed: ParsedAppleTTML
        do {
            parsed = try AppleTTMLParser.parse(selection.primaryTTML)
        } catch {
            return .empty
        }
        guard !parsed.lines.isEmpty else {
            return .empty
        }
        let enrichedLines = enrich(
            parsed.lines,
            with: selection.alternatives
        )

        return LyricsDocument(
            lines: enrichedLines,
            source: "Apple Music",
            isSynced: true,
            wordTiming: parsed.wordTiming
        )
    }

    // MARK: - Cache index

    private func candidates() -> [CacheCandidate] {
        let indexed = indexedCandidates()
        var candidates = indexed
        var indexedPaths = Set(indexed.compactMap(\.fileURL))

        // The database is a private implementation detail. Always append recent
        // files as a fallback because an index can exist while containing stale
        // paths after a Music or macOS update.
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return candidates
        }

        let recentFiles = urls
            .filter { (try? $0.resourceValues(forKeys: keys).isRegularFile) == true }
            .sorted {
                let lhs = try? $0.resourceValues(forKeys: keys).contentModificationDate
                let rhs = try? $1.resourceValues(forKeys: keys).contentModificationDate
                return (lhs ?? .distantPast) > (rhs ?? .distantPast)
            }
            .prefix(maximumCandidates)
        for url in recentFiles where indexedPaths.insert(url).inserted {
            candidates.append(.file(url))
        }
        return candidates
    }

    private func indexedCandidates() -> [CacheCandidate] {
        guard fileManager.isReadableFile(atPath: databaseURL.path),
              fileManager.isExecutableFile(atPath: "/usr/bin/sqlite3") else {
            return []
        }

        let query = """
        SELECT d.isDataOnFS || char(9) || hex(d.receiver_data)
        FROM cfurl_cache_response r
        JOIN cfurl_cache_receiver_data d USING(entry_ID)
        WHERE r.request_key LIKE '%syllable-lyrics%'
        ORDER BY r.time_stamp DESC
        LIMIT \(maximumCandidates);
        """

        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", databaseURL.path, query]
        process.standardOutput = output
        process.standardError = errorOutput

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            _ = errorOutput.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return []
            }
            guard let raw = String(data: data, encoding: .utf8) else {
                return []
            }
            return raw.components(separatedBy: .newlines).compactMap { row in
                let fields = row.split(separator: "\t", maxSplits: 1).map(String.init)
                guard fields.count == 2, let payload = Data(hexEncoded: fields[1]) else {
                    return nil
                }
                if fields[0] == "1",
                   let name = String(data: payload, encoding: .utf8),
                   let url = cacheFileURL(named: name) {
                    return .file(url)
                }
                if fields[0] == "0" {
                    return .inline(payload)
                }
                return nil
            }
        } catch {
            return []
        }
    }

    private func cacheFileURL(named name: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        guard name.count == 36,
              name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        let url = cacheDirectory.appendingPathComponent(name, isDirectory: false)
        return fileManager.isReadableFile(atPath: url.path) ? url : nil
    }

    private func localizedTTML(from value: TTMLLocalizations) -> LocalizedTTMLSelection? {
        let localizations: [String: String]
        switch value {
        case .ttml(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<") {
                // The API response contains a raw TTML document rather than a
                // localized dictionary; use it directly.
                return LocalizedTTMLSelection(
                    primaryTTML: trimmed,
                    locale: TTMLLanguageDetector.language(in: trimmed),
                    alternatives: []
                )
            }
            guard let data = trimmed.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                return nil
            }
            localizations = decoded
        case .localized(let values):
            localizations = values
        }
        guard let key = localizations.keys.sorted().first,
              let primary = localizations[key] else { return nil }
        let alternatives = localizations
            .filter { $0.key != key && $0.value != primary }
            .sorted { $0.key < $1.key }
            .map { LocalizedTTMLAlternative(locale: $0.key, ttml: $0.value) }
        return LocalizedTTMLSelection(
            primaryTTML: primary,
            locale: key,
            alternatives: alternatives
        )
    }

    private func enrich(
        _ primaryLines: [LyricLine],
        with alternatives: [LocalizedTTMLAlternative]
    ) -> [LyricLine] {
        var translations: [Int: String] = [:]

        for alternative in alternatives {
            guard let parsed = try? AppleTTMLParser.parse(alternative.ttml) else { continue }

            for (alternativeIndex, alternativeLine) in parsed.lines.enumerated() {
                let index: Int?
                if alternativeIndex < primaryLines.count,
                   abs(primaryLines[alternativeIndex].time - alternativeLine.time) <= 1 {
                    index = alternativeIndex
                } else {
                    index = primaryLines.indices.min {
                        abs(primaryLines[$0].time - alternativeLine.time)
                            < abs(primaryLines[$1].time - alternativeLine.time)
                    }
                }
                guard let index,
                      abs(primaryLines[index].time - alternativeLine.time) <= 1,
                      primaryLines[index].text != alternativeLine.text else { continue }
                if translations[index] == nil {
                    translations[index] = alternativeLine.text
                }
            }
        }

        return primaryLines.enumerated().map { index, line in
            LyricLine(
                time: line.time,
                end: line.end,
                text: line.text,
                words: line.words,
                translation: translations[index]
            )
        }
    }
}

// MARK: - Metadata matching

private struct TrackMetadataMatch {
    let score: Int
    let evidence: String
}

private struct TrackMetadataMatcher {
    func match(_ song: CatalogSongAttributes, to track: TrackInfo) -> TrackMetadataMatch? {
        let wantedTitle = ComparableMetadataText(track.title)
        let candidateTitle = ComparableMetadataText(song.name)
        let titleMatch = wantedTitle.match(candidateTitle)
        guard titleMatch != .none else { return nil }

        let durationDifference: TimeInterval? = {
            guard track.duration > 0,
                  let duration = song.durationInMillis,
                  duration > 0 else { return nil }
            return abs(Double(duration) / 1000 - track.duration)
        }()
        if let durationDifference, durationDifference > 12 { return nil }

        let wantedArtist = ComparableMetadataText(track.artist)
        let candidateArtist = ComparableMetadataText(song.artistName)
        let artistMatch = wantedArtist.match(candidateArtist)
        let artistMissing = wantedArtist.isEmpty || candidateArtist.isEmpty
        let localizedArtist = wantedArtist.usesDifferentWritingSystem(from: candidateArtist)
        let artistIsTrusted = artistMatch.isStrongIdentity

        let wantedAlbum = ComparableMetadataText(track.album)
        let candidateAlbum = ComparableMetadataText(song.albumName ?? "")
        let albumMatch = wantedAlbum.match(candidateAlbum)
        let albumIsTrusted = albumMatch.isStrongIdentity

        let durationIsTight = durationDifference.map { $0 <= 2 } == true
        let durationIsNear = durationDifference.map { $0 <= 5 } == true
        let accepted: Bool
        switch titleMatch {
        case .exact, .canonical:
            accepted = artistIsTrusted
                || (durationIsTight && (localizedArtist || artistMissing || albumIsTrusted))
        case .transliterated:
            accepted = durationIsTight && (artistIsTrusted || albumIsTrusted)
        case .contained:
            accepted = durationIsNear && artistIsTrusted
        case .none:
            accepted = false
        }
        guard accepted else { return nil }

        var score = titleMatch.titleScore
        if artistIsTrusted {
            score += artistMatch.identityScore
        } else if localizedArtist {
            score += 10
        } else if !artistMissing {
            score -= 40
        }
        if albumIsTrusted {
            score += albumMatch.albumScore
        }
        if let durationDifference {
            if durationDifference <= 2 { score += 40 }
            else if durationDifference <= 5 { score += 25 }
            else { score += 5 }
        }

        let durationEvidence = durationDifference.map {
            String(format: "%.1fs", $0)
        } ?? "unavailable"
        let artistEvidence = artistIsTrusted
            ? artistMatch.label
            : (localizedArtist ? "localized-writing-system" : "missing")
        return TrackMetadataMatch(
            score: score,
            evidence: "title=\(titleMatch.label); artist=\(artistEvidence); "
                + "album=\(albumMatch.label); durationDelta=\(durationEvidence)"
        )
    }
}

private enum MetadataTextMatch: Equatable {
    case exact
    case canonical
    case transliterated
    case contained
    case none

    var label: String {
        switch self {
        case .exact: return "exact"
        case .canonical: return "cjk-canonical"
        case .transliterated: return "transliterated"
        case .contained: return "contained"
        case .none: return "none"
        }
    }

    var isStrongIdentity: Bool {
        switch self {
        case .exact, .canonical, .transliterated: return true
        case .contained, .none: return false
        }
    }

    var titleScore: Int {
        switch self {
        case .exact: return 100
        case .canonical: return 95
        case .transliterated: return 80
        case .contained: return 45
        case .none: return 0
        }
    }

    var identityScore: Int {
        switch self {
        case .exact: return 45
        case .canonical: return 42
        case .transliterated: return 35
        case .contained: return 20
        case .none: return 0
        }
    }

    var albumScore: Int {
        switch self {
        case .exact: return 20
        case .canonical: return 18
        case .transliterated: return 12
        case .contained: return 6
        case .none: return 0
        }
    }
}

private struct ComparableMetadataText {
    private static let cjkCanonicalTransform = StringTransform("Traditional-Simplified")

    let surface: String
    let cjkCanonical: String
    let transliterated: String
    let containsCJK: Bool
    let containsASCIILatin: Bool

    var isEmpty: Bool { surface.isEmpty }

    init(_ value: String) {
        surface = Self.compact(value, stripsDiacritics: true)
        let canonical = value.applyingTransform(Self.cjkCanonicalTransform, reverse: false) ?? value
        cjkCanonical = Self.compact(canonical, stripsDiacritics: true)
        let latin = canonical.applyingTransform(.toLatin, reverse: false) ?? canonical
        transliterated = Self.compact(latin, stripsDiacritics: false)
        containsCJK = value.unicodeScalars.contains { Self.isCJK($0.value) }
        containsASCIILatin = value.unicodeScalars.contains {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
    }

    func match(_ other: ComparableMetadataText) -> MetadataTextMatch {
        guard !isEmpty, !other.isEmpty else { return .none }
        if surface == other.surface { return .exact }
        if cjkCanonical == other.cjkCanonical { return .canonical }
        let bothUseCJK = containsCJK && other.containsCJK
        if !bothUseCJK,
           !transliterated.isEmpty,
           transliterated == other.transliterated {
            return .transliterated
        }
        if Self.containsEitherDirection(surface, other.surface)
            || Self.containsEitherDirection(cjkCanonical, other.cjkCanonical)
            || (!bothUseCJK
                && Self.containsEitherDirection(transliterated, other.transliterated)) {
            return .contained
        }
        return .none
    }

    func usesDifferentWritingSystem(from other: ComparableMetadataText) -> Bool {
        (containsCJK && other.containsASCIILatin)
            || (containsASCIILatin && other.containsCJK)
    }

    private static func containsEitherDirection(_ lhs: String, _ rhs: String) -> Bool {
        min(lhs.count, rhs.count) >= 3 && (lhs.contains(rhs) || rhs.contains(lhs))
    }

    private static func compact(_ value: String, stripsDiacritics: Bool) -> String {
        var options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]
        if stripsDiacritics { options.insert(.diacriticInsensitive) }
        let folded = value.folding(options: options, locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func isCJK(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x323AF).contains(value)
    }
}

private enum TTMLLanguageDetector {
    static func language(in ttml: String) -> String? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let delegate = RootElementDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return delegate.language
    }

    private final class RootElementDelegate: NSObject, XMLParserDelegate {
        var language: String?
        private var foundRoot = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard !foundRoot else { return }
            foundRoot = true
            language = attributeDict["xml:lang"] ?? attributeDict["lang"]
        }
    }
}

private struct LocalizedTTMLSelection {
    let primaryTTML: String
    let locale: String?
    let alternatives: [LocalizedTTMLAlternative]

    init(
        primaryTTML: String,
        locale: String? = nil,
        alternatives: [LocalizedTTMLAlternative]
    ) {
        self.primaryTTML = primaryTTML
        self.locale = locale
        self.alternatives = alternatives
    }
}

private struct LocalizedTTMLAlternative {
    let locale: String
    let ttml: String
}

private enum CacheCandidate {
    case file(URL)
    case inline(Data)

    var fileURL: URL? {
        guard case .file(let url) = self else { return nil }
        return url
    }

    func data() -> Data? {
        switch self {
        case .file(let url):
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        case .inline(let data):
            return data
        }
    }
}

private extension Data {
    init?(hexEncoded value: String) {
        guard value.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        self.init(bytes)
    }
}

// MARK: - Catalog response models

private struct CatalogResponse: Decodable {
    let data: [CatalogSong]
}

private struct CatalogSong: Decodable {
    let attributes: CatalogSongAttributes
    let relationships: CatalogRelationships?
}

private struct CatalogSongAttributes: Decodable {
    let name: String
    let artistName: String
    let albumName: String?
    let durationInMillis: Int?
}

private struct CatalogRelationships: Decodable {
    let syllableLyrics: CatalogRelationship?

    enum CodingKeys: String, CodingKey {
        case syllableLyrics = "syllable-lyrics"
    }
}

private struct CatalogRelationship: Decodable {
    let data: [CatalogLyric]
}

private struct CatalogLyric: Decodable {
    let attributes: CatalogLyricAttributes
}

private struct CatalogLyricAttributes: Decodable {
    let ttmlLocalizations: TTMLLocalizations?
}

private enum TTMLLocalizations: Decodable {
    case ttml(String)
    case localized([String: String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .ttml(value)
        } else {
            self = .localized(try container.decode([String: String].self))
        }
    }
}
