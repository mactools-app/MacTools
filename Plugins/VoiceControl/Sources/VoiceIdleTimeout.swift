enum VoiceIdleTimeout: Int, CaseIterable, Sendable {
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300

    static let defaultValue = Self.oneMinute
    var duration: Duration { .seconds(rawValue) }
}
