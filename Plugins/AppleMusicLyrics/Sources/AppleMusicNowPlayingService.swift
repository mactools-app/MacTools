import AppKit
import Foundation

/// Abstraction over Music.app playback state so the controller can be tested
/// with a synchronous fake. Implementations must be safe to call from a
/// background cooperative worker.
protocol AppleMusicNowPlayingServicing: Sendable {
    var isMusicRunning: Bool { get }
    func fetch() -> Result<TrackInfo?, Error>
}

/// Polls Music.app for the currently playing track via AppleScript.
final class AppleMusicNowPlayingService: AppleMusicNowPlayingServicing, @unchecked Sendable {
    private let delimiter = "\u{1F}"
    private let musicBundleIdentifier = "com.apple.Music"
    /// `errAEEventNotPermitted`: the user denied the Automation prompt for
    /// Apple Events to Music.
    private static let automationDeniedErrorNumber = -1743

    private lazy var playerStateScript: NSAppleScript? = NSAppleScript(source: """
        tell application "Music"
            if player state is stopped then
                return "STOPPED"
            end if
            set t to current track
            set delim to "\(delimiter)"
            return (name of t) & delim & (artist of t) & delim & (album of t) & delim & (player state as text) & delim & (player position as text) & delim & (duration of t as text)
        end tell
        """)

    var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: musicBundleIdentifier
        ).isEmpty
    }

    func fetch() -> Result<TrackInfo?, Error> {
        // Avoid launching Music if it isn't already running.
        guard isMusicRunning else { return .success(nil) }

        guard let playerStateScript else {
            return .failure(AppleMusicScriptError.failedToCreate)
        }

        var errorInfo: NSDictionary?
        let result = playerStateScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let errorNumber = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            if errorNumber == Self.automationDeniedErrorNumber {
                return .failure(AppleMusicScriptError.automationDenied)
            }
            return .failure(
                AppleMusicScriptError.executionFailed(errorInfo.description)
            )
        }

        let value = (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "STOPPED" {
            return .success(nil)
        }

        let parts = value.components(separatedBy: delimiter)
        guard parts.count >= 6 else {
            return .failure(AppleMusicNowPlayingError.unexpectedFormat(value))
        }

        let title = parts[0]
        let artist = parts[1]
        let album = parts[2]
        let state = PlayerState(appleScriptValue: parts[3])
        let position = TimeInterval(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        let duration = TimeInterval(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        return .success(
            TrackInfo(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                position: position,
                state: state
            )
        )
    }
}

enum AppleMusicScriptError: LocalizedError {
    case failedToCreate
    case executionFailed(String)
    case automationDenied
    case timedOut
    case unknown

    var errorDescription: String? {
        switch self {
        case .failedToCreate:
            return "Unable to create AppleScript"
        case .executionFailed(let message):
            return "AppleScript execution failed: \(message)"
        case .automationDenied:
            return "Automation access to Music was denied. Open System Settings → Privacy & Security → Automation and allow MacTools to control Music."
        case .timedOut:
            return "Music did not respond in time"
        case .unknown:
            return "Unknown AppleScript error"
        }
    }
}

enum AppleMusicNowPlayingError: LocalizedError {
    case unexpectedFormat(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedFormat(let value):
            return "Unexpected Music response: \(value)"
        }
    }
}
