import Foundation

/// Live fragments have timestamps, but no turn IDs or completed-turn event.
/// Keep each speaker independent so an acknowledgment cannot split ongoing input.
struct VoiceTranscript {
    enum Speaker: String, Sendable { case user, assistant }
    struct Fragment {
        let id: UUID
        let speaker: Speaker
        var text: String
        let start: Int?
        let end: Int?
    }
    struct Turn: Identifiable, Equatable {
        let id: UUID
        let speaker: Speaker
        var text: String
        var start: Int?
        var end: Int?
    }

    private(set) var fragments: [Fragment] = []
    private(set) var turns: [Turn] = []

    mutating func append(_ text: String, speaker: Speaker, start: Int?, end: Int?) {
        guard !text.isEmpty else { return }
        let validTiming = start != nil && end != nil && start! >= 0 && end! >= start!
        fragments.append(.init(id: UUID(), speaker: speaker, text: String(text.suffix(12_000)),
                               start: validTiming ? start : nil, end: validTiming ? end : nil))
        var count = fragments.reduce(0) { $0 + $1.text.count }
        while fragments.count > 256 || (count > 12_000 && fragments.count > 1) {
            count -= fragments.removeFirst().text.count
        }
        rebuildTurns()
    }

    private mutating func rebuildTurns() {
        turns = []
        for fragment in fragments {
            let existing = turns.lastIndex { turn in
                guard turn.speaker == fragment.speaker else { return false }
                if let start = fragment.start, let end = fragment.end,
                   let turnStart = turn.start, let turnEnd = turn.end {
                    // Use the session timeline, not arrival gaps, including late fragments.
                    return start <= turnEnd + 1_200 && end >= turnStart - 1_200
                }
                return turns.last?.id == turn.id
            }
            if let existing {
                turns[existing].text += fragment.text
                if let start = fragment.start { turns[existing].start = min(turns[existing].start ?? start, start) }
                if let end = fragment.end { turns[existing].end = max(turns[existing].end ?? end, end) }
            } else {
                turns.append(.init(id: fragment.id, speaker: fragment.speaker, text: fragment.text,
                                   start: fragment.start, end: fragment.end))
            }
        }
        // Stable for equal or unavailable timestamps; never reorder a speaker's text.
        turns = turns.enumerated().sorted {
            let left = $0.element.start ?? Int.max, right = $1.element.start ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
}

/// Local-only preconnection audio. Never truncate an utterance silently.
struct VoicePendingInput {
    private(set) var chunks: [Data] = []
    private var bytes = 0
    mutating func append(_ data: Data) throws {
        guard bytes + data.count <= 24_000 * 2 * 15 else { throw VoiceFailure.connection }
        chunks.append(data); bytes += data.count
    }
    mutating func take() -> [Data] {
        defer { chunks = []; bytes = 0 }
        return chunks
    }
}
