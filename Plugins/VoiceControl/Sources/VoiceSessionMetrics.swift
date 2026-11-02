import Foundation

/// Bounded, in-memory counters only. Never retain audio, transcripts, credentials or error messages here.
struct VoiceSessionMetrics {
    struct Tokens {
        let input: Int
        let cachedInput: Int
        let cacheWriteInput: Int
        let output: Int
    }
    let id: UUID
    private(set) var voiceSeconds: Double?
    private(set) var finalized = false
    private(set) var closeReason: String?
    private(set) var responses: [String: Tokens] = [:]

    mutating func observe(_ event: [String: Any]) {
        let type = event["type"] as? String
        if type == "session.usage.updated" || type == "session.closed" {
            if let seconds = (event["usage"] as? [String: Any])?["seconds"] as? Double,
               seconds.isFinite, (0...3_600).contains(seconds) {
                voiceSeconds = max(voiceSeconds ?? 0, seconds)
                if type == "session.closed" {
                    finalized = true
                    let reason = event["reason"] as? String
                    closeReason = ["close_requested", "expired", "content", "remote_hangup", "connection_lost"].contains(reason ?? "") ? reason : nil
                }
            }
        }
        guard type == "response.event", let nested = event["event"] as? [String: Any],
              ["response.completed", "response.failed", "response.incomplete"].contains(nested["type"] as? String ?? ""),
              let response = nested["response"] as? [String: Any], let id = response["id"] as? String,
              id.utf8.count <= 256, responses.count < 128 || responses[id] != nil,
              let usage = response["usage"] as? [String: Any] else { return }
        func count(_ value: Any?) -> Int {
            guard let value = value as? Int, (0...1_000_000_000).contains(value) else { return 0 }
            return value
        }
        let details = usage["input_tokens_details"] as? [String: Any]
        let input = count(usage["input_tokens"])
        responses[id] = Tokens(input: input, cachedInput: min(input, count(details?["cached_tokens"])),
            cacheWriteInput: min(input, count(details?["cache_write_tokens"])), output: count(usage["output_tokens"]))
    }
}
