import Foundation

enum PlayerState: String, Equatable, Sendable {
    case playing
    case paused
    case stopped
    case unknown

    init(appleScriptValue: String) {
        switch appleScriptValue.lowercased() {
        case "playing": self = .playing
        case "paused": self = .paused
        case "stopped": self = .stopped
        default: self = .unknown
        }
    }
}

struct TrackInfo: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let position: TimeInterval
    let state: PlayerState

    var identityKey: String {
        "\(artist.lowercased())|\(title.lowercased())|\(Int(duration.rounded()))"
    }

    var displayName: String {
        if artist.isEmpty {
            return title
        }
        return "\(title) — \(artist)"
    }
}

/// One singable unit (character for CJK, word/syllable chunk for Latin).
struct LyricWord: Equatable, Sendable {
    let text: String
    /// Absolute start time in seconds.
    let start: TimeInterval
    /// Absolute end time in seconds.
    let end: TimeInterval
}

struct LyricLine: Equatable, Sendable, Identifiable {
    let time: TimeInterval
    /// Absolute end time in seconds, when the source provides it.
    let end: TimeInterval?
    let text: String
    /// Per-unit timings for karaoke highlighting.
    let words: [LyricWord]
    /// Optional localized meaning aligned to this line.
    let translation: String?

    var id: String { "\(time)-\(text.hashValue)" }

    init(
        time: TimeInterval,
        end: TimeInterval? = nil,
        text: String,
        words: [LyricWord] = [],
        translation: String? = nil
    ) {
        self.time = time
        self.end = end
        self.text = text
        self.words = words
        self.translation = translation
    }

    var endTime: TimeInterval {
        words.last?.end ?? end ?? time
    }
}

enum WordTimingQuality: String, Equatable, Sendable {
    /// No per-word data.
    case none
    /// Exact timings from Apple Music word-timed TTML.
    case exact
}

struct LyricsDocument: Equatable, Sendable {
    let lines: [LyricLine]
    let source: String
    let isSynced: Bool
    let wordTiming: WordTimingQuality

    init(
        lines: [LyricLine],
        source: String,
        isSynced: Bool,
        wordTiming: WordTimingQuality
    ) {
        self.lines = lines
        self.source = source
        self.isSynced = isSynced
        self.wordTiming = wordTiming
    }

    static let empty = LyricsDocument(
        lines: [],
        source: "none",
        isSynced: false,
        wordTiming: .none
    )

    func lineIndex(at position: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var lo = 0
        var hi = lines.count - 1
        var answer: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position {
                answer = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return answer
    }

    func line(at position: TimeInterval) -> LyricLine? {
        guard let index = lineIndex(at: position) else { return nil }
        return lines[index]
    }
}
