import AppKit
import Foundation
import MacToolsPluginKit

/// Snapshot of the plugin's current state for panel and settings display.
struct AppleMusicLyricsSnapshot: Equatable, Sendable {
    let isEnabled: Bool
    let isMusicRunning: Bool
    let isTrackPlaying: Bool
    let hasLyrics: Bool
    let currentTrackTitle: String
    let currentTrackArtist: String
    let currentLine: String
    let errorMessage: String?
}

/// Protocol for the controller so tests can substitute fakes.
@MainActor
protocol AppleMusicLyricsControlling: AnyObject {
    var onStateChange: (() -> Void)? { get set }
    var onPersistentPreferencesChange: (() -> Void)? { get set }
    var snapshot: AppleMusicLyricsSnapshot { get }

    var fontSize: Double { get }
    var backgroundOpacity: Double { get }
    var textOpacity: Double { get }
    var cornerRadius: Double { get }
    var showsNextLine: Bool { get }
    var textColor: LyricsTextColorOption { get }
    var allowsDragging: Bool { get }
    var karaokeEnabled: Bool { get }

    func activate()
    func deactivate()
    func refresh()
    func setEnabled(_ isEnabled: Bool)
    func setFontSize(_ size: Double)
    func setBackgroundOpacity(_ opacity: Double)
    func setTextOpacity(_ opacity: Double)
    func setCornerRadius(_ radius: Double)
    func setShowsNextLine(_ showsNextLine: Bool)
    func setTextColor(_ option: LyricsTextColorOption)
    func setAllowsDragging(_ allows: Bool)
    func setKaraokeEnabled(_ enabled: Bool)
    func resetToDefaults()
    func reloadPortablePreferences()
}

@MainActor
final class AppleMusicLyricsController: AppleMusicLyricsControlling {
    enum StorageKey {
        static let enabled = "apple-music-lyrics.enabled"
        static let fontSize = "apple-music-lyrics.font-size"
        static let backgroundOpacity = "apple-music-lyrics.background-opacity"
        static let textOpacity = "apple-music-lyrics.text-opacity"
        static let cornerRadius = "apple-music-lyrics.corner-radius"
        static let showsNextLine = "apple-music-lyrics.shows-next-line"
        static let textColor = "apple-music-lyrics.text-color"
        static let allowsDragging = "apple-music-lyrics.allows-dragging"
        static let karaokeEnabled = "apple-music-lyrics.karaoke-enabled"
        static let windowPosition = "apple-music-lyrics.window-position"
    }

    enum Defaults {
        static let isEnabled = false
        static let fontSize = 24.0
        static let backgroundOpacity = 0.65
        static let textOpacity = 1.0
        static let cornerRadius = 16.0
        static let showsNextLine = true
        static let textColor = LyricsTextColorOption.system
        static let allowsDragging = false
        static let karaokeEnabled = true
    }

    private static let allowedFontSizeRange: ClosedRange<Double> = 14...48
    private static let allowedOpacityRange: ClosedRange<Double> = 0.1...1.0
    private static let allowedTextOpacityRange: ClosedRange<Double> = 0.1...1.0
    private static let allowedCornerRadiusRange: ClosedRange<Double> = 0...28
    private static let pollInterval: TimeInterval = 0.5
    /// Maximum time to wait for a single Music.app AppleScript round trip.
    private static let fetchTimeout: TimeInterval = 1.5
    /// Spaced retries after a lookup finds no lyrics yet; Music may still be
    /// writing the catalog response to disk for a freshly started track.
    private static let lyricsRetryDelays: [TimeInterval] = [2, 4, 8]

    var onStateChange: (() -> Void)?
    var onPersistentPreferencesChange: (() -> Void)?

    private let storage: any PluginStorage
    private let nowPlayingService: any AppleMusicNowPlayingServicing
    private let lyricsProvider: AppleMusicCacheLyricsProvider

    private var isEnabled: Bool
    private var storedFontSize: Double
    private var storedBackgroundOpacity: Double
    private var storedTextOpacity: Double
    private var storedCornerRadius: Double
    private var storedShowsNextLine: Bool
    private var storedTextColor: LyricsTextColorOption
    private var storedAllowsDragging: Bool
    private var storedKaraokeEnabled: Bool

    private var pollTimer: Timer?
    private var currentTrack: TrackInfo?
    private var currentLyrics: LyricsDocument = .empty
    private var currentLine: String = ""
    private var lyricsFetchTask: Task<Void, Never>?
    private var lyricsRetryTask: Task<Void, Never>?
    private var lyricsRetryCount = 0
    private var isFetchInFlight = false
    private var isAutomationDenied = false
    private var lastReportedSnapshot: AppleMusicLyricsSnapshot?
    private var errorMessage: String?
    private var isActive = false

    /// Serial queue for the blocking AppleScript round trip. Using a dedicated
    /// queue (rather than the Swift cooperative pool) keeps a slow Music reply
    /// from starving other async work.
    private let fetchQueue = DispatchQueue(label: "apple-music-lyrics.fetch")
    /// Identity of the request currently executing on `fetchQueue`, used to
    /// discard results that arrive after a timeout or after disabling.
    private var activeFetchRequestID: UUID?
    private var pendingTimeoutTask: Task<Void, Never>?
    private var fetchTimedOut = false

    private let floatingWindow: LyricsFloatingWindow

    init(
        storage: any PluginStorage,
        localization: PluginLocalization,
        nowPlayingService: any AppleMusicNowPlayingServicing = AppleMusicNowPlayingService(),
        lyricsProvider: AppleMusicCacheLyricsProvider = AppleMusicCacheLyricsProvider()
    ) {
        self.storage = storage
        self.nowPlayingService = nowPlayingService
        self.lyricsProvider = lyricsProvider

        if storage.object(forKey: StorageKey.enabled) == nil {
            isEnabled = Defaults.isEnabled
        } else {
            isEnabled = storage.bool(forKey: StorageKey.enabled)
        }

        storedFontSize = Self.clampedFontSize(
            storage.object(forKey: StorageKey.fontSize) as? Double ?? Defaults.fontSize
        )
        storedBackgroundOpacity = Self.clampedOpacity(
            storage.object(forKey: StorageKey.backgroundOpacity) as? Double ?? Defaults.backgroundOpacity
        )
        storedTextOpacity = Self.clampedTextOpacity(
            storage.object(forKey: StorageKey.textOpacity) as? Double ?? Defaults.textOpacity
        )
        storedCornerRadius = Self.clampedCornerRadius(
            storage.object(forKey: StorageKey.cornerRadius) as? Double ?? Defaults.cornerRadius
        )
        if storage.object(forKey: StorageKey.showsNextLine) == nil {
            storedShowsNextLine = Defaults.showsNextLine
        } else {
            storedShowsNextLine = storage.bool(forKey: StorageKey.showsNextLine)
        }
        if storage.object(forKey: StorageKey.textColor) == nil {
            storedTextColor = Defaults.textColor
        } else {
            storedTextColor = LyricsTextColorOption(
                rawValue: storage.string(forKey: StorageKey.textColor) ?? ""
            ) ?? Defaults.textColor
        }
        if storage.object(forKey: StorageKey.allowsDragging) == nil {
            storedAllowsDragging = Defaults.allowsDragging
        } else {
            storedAllowsDragging = storage.bool(forKey: StorageKey.allowsDragging)
        }
        if storage.object(forKey: StorageKey.karaokeEnabled) == nil {
            storedKaraokeEnabled = Defaults.karaokeEnabled
        } else {
            storedKaraokeEnabled = storage.bool(forKey: StorageKey.karaokeEnabled)
        }

        let appearance = LyricsAppearance(
            fontSize: storedFontSize,
            backgroundOpacity: storedBackgroundOpacity,
            textOpacity: storedTextOpacity,
            cornerRadius: storedCornerRadius,
            showsNextLine: storedShowsNextLine,
            textColor: storedTextColor,
            allowsDragging: storedAllowsDragging,
            karaokeEnabled: storedKaraokeEnabled
        )
        floatingWindow = LyricsFloatingWindow(appearance: appearance)
        floatingWindow.restorePosition(Self.windowPosition(from: storage))
        floatingWindow.onPositionChange = { [weak self] point in
            self?.saveWindowPosition(point)
        }
    }

    isolated deinit {
        pollTimer?.invalidate()
        lyricsFetchTask?.cancel()
        lyricsRetryTask?.cancel()
    }

    var currentAppearance: LyricsAppearance {
        LyricsAppearance(
            fontSize: storedFontSize,
            backgroundOpacity: storedBackgroundOpacity,
            textOpacity: storedTextOpacity,
            cornerRadius: storedCornerRadius,
            showsNextLine: storedShowsNextLine,
            textColor: storedTextColor,
            allowsDragging: storedAllowsDragging,
            karaokeEnabled: storedKaraokeEnabled
        )
    }

    var snapshot: AppleMusicLyricsSnapshot {
        let isMusicRunning = nowPlayingService.isMusicRunning
        let isTrackPlaying = currentTrack?.state == .playing
        let hasLyrics = !currentLyrics.lines.isEmpty

        return AppleMusicLyricsSnapshot(
            isEnabled: isEnabled,
            isMusicRunning: isMusicRunning,
            isTrackPlaying: isTrackPlaying,
            hasLyrics: hasLyrics,
            currentTrackTitle: currentTrack?.title ?? "",
            currentTrackArtist: currentTrack?.artist ?? "",
            currentLine: currentLine,
            errorMessage: errorMessage
        )
    }

    var fontSize: Double { storedFontSize }
    var backgroundOpacity: Double { storedBackgroundOpacity }
    var textOpacity: Double { storedTextOpacity }
    var cornerRadius: Double { storedCornerRadius }
    var showsNextLine: Bool { storedShowsNextLine }
    var textColor: LyricsTextColorOption { storedTextColor }
    var allowsDragging: Bool { storedAllowsDragging }
    var karaokeEnabled: Bool { storedKaraokeEnabled }

    // MARK: - Lifecycle

    func activate() {
        isActive = true
        if isEnabled {
            startPolling()
            applyWindowVisibility()
        }
    }

    func deactivate() {
        isActive = false
        stopPolling()
        cancelLyricsWork()
        invalidateFetchRequest()
        floatingWindow.hideLyrics()
    }

    func refresh() {
        pollNow()
    }

    // MARK: - Settings

    func setEnabled(_ isEnabled: Bool) {
        guard self.isEnabled != isEnabled else { return }
        self.isEnabled = isEnabled
        storage.set(isEnabled, forKey: StorageKey.enabled)

        if isEnabled {
            // Re-enabling after an Automation denial retries the Apple Events.
            isAutomationDenied = false
            startPolling()
            pollNow()
        } else {
            stopPolling()
            cancelLyricsWork()
            invalidateFetchRequest()
            floatingWindow.hideLyrics()
            currentTrack = nil
            currentLyrics = .empty
            currentLine = ""
            errorMessage = nil
        }
        onStateChange?()
    }

    /// Re-reads the portable appearance preferences from storage after a
    /// restore. `enabled` and the window position are deliberately not touched
    /// because they are local to each Mac.
    func reloadPortablePreferences() {
        storedFontSize = Self.clampedFontSize(
            storage.object(forKey: StorageKey.fontSize) as? Double ?? Defaults.fontSize
        )
        storedBackgroundOpacity = Self.clampedOpacity(
            storage.object(forKey: StorageKey.backgroundOpacity) as? Double ?? Defaults.backgroundOpacity
        )
        storedTextOpacity = Self.clampedTextOpacity(
            storage.object(forKey: StorageKey.textOpacity) as? Double ?? Defaults.textOpacity
        )
        storedCornerRadius = Self.clampedCornerRadius(
            storage.object(forKey: StorageKey.cornerRadius) as? Double ?? Defaults.cornerRadius
        )
        if storage.object(forKey: StorageKey.showsNextLine) == nil {
            storedShowsNextLine = Defaults.showsNextLine
        } else {
            storedShowsNextLine = storage.bool(forKey: StorageKey.showsNextLine)
        }
        if storage.object(forKey: StorageKey.textColor) == nil {
            storedTextColor = Defaults.textColor
        } else {
            storedTextColor = LyricsTextColorOption(
                rawValue: storage.string(forKey: StorageKey.textColor) ?? ""
            ) ?? Defaults.textColor
        }
        if storage.object(forKey: StorageKey.allowsDragging) == nil {
            storedAllowsDragging = Defaults.allowsDragging
        } else {
            storedAllowsDragging = storage.bool(forKey: StorageKey.allowsDragging)
        }
        if storage.object(forKey: StorageKey.karaokeEnabled) == nil {
            storedKaraokeEnabled = Defaults.karaokeEnabled
        } else {
            storedKaraokeEnabled = storage.bool(forKey: StorageKey.karaokeEnabled)
        }
        applyAppearance()
        onStateChange?()
    }

    func setFontSize(_ size: Double) {
        let clamped = Self.clampedFontSize(size)
        guard storedFontSize != clamped else { return }
        storedFontSize = clamped
        storage.set(clamped, forKey: StorageKey.fontSize)
        applyAppearance()
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    func setBackgroundOpacity(_ opacity: Double) {
        let clamped = Self.clampedOpacity(opacity)
        guard storedBackgroundOpacity != clamped else { return }
        storedBackgroundOpacity = clamped
        storage.set(clamped, forKey: StorageKey.backgroundOpacity)
        applyAppearance()
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    func setTextOpacity(_ opacity: Double) {
        let clamped = Self.clampedTextOpacity(opacity)
        guard storedTextOpacity != clamped else { return }
        storedTextOpacity = clamped
        storage.set(clamped, forKey: StorageKey.textOpacity)
        applyAppearance()
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    func setCornerRadius(_ radius: Double) {
        let clamped = Self.clampedCornerRadius(radius)
        guard storedCornerRadius != clamped else { return }
        storedCornerRadius = clamped
        storage.set(clamped, forKey: StorageKey.cornerRadius)
        applyAppearance()
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    func setShowsNextLine(_ showsNextLine: Bool) {
        guard storedShowsNextLine != showsNextLine else { return }
        storedShowsNextLine = showsNextLine
        storage.set(showsNextLine, forKey: StorageKey.showsNextLine)
        applyAppearance()
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    func setTextColor(_ option: LyricsTextColorOption) {
        guard storedTextColor != option else { return }
        storedTextColor = option
        storage.set(option.rawValue, forKey: StorageKey.textColor)
        applyAppearance()
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    func setAllowsDragging(_ allows: Bool) {
        guard storedAllowsDragging != allows else { return }
        storedAllowsDragging = allows
        storage.set(allows, forKey: StorageKey.allowsDragging)
        applyAppearance()
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    func setKaraokeEnabled(_ enabled: Bool) {
        guard storedKaraokeEnabled != enabled else { return }
        storedKaraokeEnabled = enabled
        storage.set(enabled, forKey: StorageKey.karaokeEnabled)
        applyAppearance()
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    func resetToDefaults() {
        isEnabled = Defaults.isEnabled
        storedFontSize = Defaults.fontSize
        storedBackgroundOpacity = Defaults.backgroundOpacity
        storedTextOpacity = Defaults.textOpacity
        storedCornerRadius = Defaults.cornerRadius
        storedShowsNextLine = Defaults.showsNextLine
        storedTextColor = Defaults.textColor
        storedAllowsDragging = Defaults.allowsDragging
        storedKaraokeEnabled = Defaults.karaokeEnabled

        storage.set(isEnabled, forKey: StorageKey.enabled)
        storage.set(storedFontSize, forKey: StorageKey.fontSize)
        storage.set(storedBackgroundOpacity, forKey: StorageKey.backgroundOpacity)
        storage.set(storedTextOpacity, forKey: StorageKey.textOpacity)
        storage.set(storedCornerRadius, forKey: StorageKey.cornerRadius)
        storage.set(storedShowsNextLine, forKey: StorageKey.showsNextLine)
        storage.set(storedTextColor.rawValue, forKey: StorageKey.textColor)
        storage.set(storedAllowsDragging, forKey: StorageKey.allowsDragging)
        storage.set(storedKaraokeEnabled, forKey: StorageKey.karaokeEnabled)

        if isEnabled {
            startPolling()
            pollNow()
        } else {
            stopPolling()
            cancelLyricsWork()
            invalidateFetchRequest()
            floatingWindow.hideLyrics()
            currentTrack = nil
            currentLyrics = .empty
            currentLine = ""
            errorMessage = nil
        }
        applyAppearance()
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollNow()
            }
        }
        timer.tolerance = 0.1
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Queries Music.app without blocking the main thread. The AppleScript round
    /// trip runs on a dedicated serial queue; a watchdog reports a timeout at
    /// `fetchTimeout` even though the synchronous AppleScript cannot be stopped
    /// mid-flight. The request slot stays occupied until the call actually
    /// finishes, so at most one request is in flight at a time.
    private func pollNow() {
        guard isActive, isEnabled, !isFetchInFlight, !isAutomationDenied else { return }
        isFetchInFlight = true
        fetchTimedOut = false
        let requestID = UUID()
        activeFetchRequestID = requestID
        let service = nowPlayingService

        // Watchdog: reports a timeout at the deadline without freeing the slot.
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.fetchTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.activeFetchRequestID == requestID else { return }
            self.fetchTimedOut = true
            self.handleFetchError(.timedOut)
        }
        pendingTimeoutTask = timeoutTask

        fetchQueue.async { [weak self] in
            let outcome = service.fetch().mapError(Self.mapPollingError)
            DispatchQueue.main.async {
                guard let self, self.activeFetchRequestID == requestID else { return }
                self.activeFetchRequestID = nil
                self.pendingTimeoutTask?.cancel()
                self.pendingTimeoutTask = nil
                self.isFetchInFlight = false
                guard self.isActive, self.isEnabled else { return }
                if self.fetchTimedOut {
                    self.fetchTimedOut = false
                    // A late reply still matters when it is an Automation denial;
                    // otherwise the result is stale and the next poll refreshes.
                    if case .failure(let error) = outcome, error == .automationDenied {
                        self.handleFetchError(error)
                    }
                    return
                }
                switch outcome {
                case .success(let track):
                    self.handleTrack(track)
                case .failure(let error):
                    self.handleFetchError(error)
                }
            }
        }
    }

    private nonisolated static func mapPollingError(_ error: Error) -> AppleMusicPollingError {
        if case AppleMusicScriptError.automationDenied = error {
            return .automationDenied
        }
        if case AppleMusicScriptError.timedOut = error {
            return .timedOut
        }
        return .failed(error.localizedDescription)
    }

    private func handleFetchError(_ error: AppleMusicPollingError) {
        errorMessage = error.localizedDescription
        if error == .automationDenied {
            // The user denied Automation access. Stop polling, drop the stale
            // track, and hide the window so the previous lyric does not linger;
            // the error message points at the Automation pane.
            isAutomationDenied = true
            stopPolling()
            cancelLyricsWork()
            currentTrack = nil
            currentLyrics = .empty
            currentLine = ""
            floatingWindow.hideLyrics()
            isFetchInFlight = false
        }
        notifyIfChanged()
    }

    private func handleTrack(_ track: TrackInfo?) {
        guard let track else {
            // Music stopped or not playing.
            if currentTrack != nil || !currentLyrics.lines.isEmpty || errorMessage != nil {
                currentTrack = nil
                currentLyrics = .empty
                currentLine = ""
                errorMessage = nil
                floatingWindow.hideLyrics()
                notifyIfChanged()
            }
            return
        }

        let identityChanged = currentTrack?.identityKey != track.identityKey
        let positionChanged = abs((currentTrack?.position ?? 0) - track.position) > 0.3
            || currentTrack?.state != track.state

        currentTrack = track
        errorMessage = nil

        if identityChanged {
            // Track changed: fetch new lyrics.
            currentLine = ""
            currentLyrics = .empty
            fetchLyrics(for: track)
        } else if positionChanged {
            // Same track: update the displayed line.
            updateDisplayedLine(position: track.position)
        }

        applyWindowVisibility()
        notifyIfChanged()
    }

    private func fetchLyrics(for track: TrackInfo) {
        lyricsFetchTask?.cancel()
        lyricsRetryTask?.cancel()
        lyricsRetryCount = 0
        let provider = lyricsProvider
        lyricsFetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let lyrics = await Task.detached(priority: .userInitiated) {
                provider.lyrics(for: track)
            }.value

            guard !Task.isCancelled else { return }
            guard self.isActive, self.isEnabled else { return }
            guard self.currentTrack?.identityKey == track.identityKey else { return }

            self.applyFetchedLyrics(lyrics, for: track)
            if lyrics.lines.isEmpty {
                self.scheduleLyricsRetry(for: track)
            }
        }
    }

    /// Re-applies a freshly loaded lyric document and notifies only when the
    /// displayed state actually changed, so repeated polls do not churn the host.
    private func applyFetchedLyrics(_ lyrics: LyricsDocument, for track: TrackInfo) {
        currentLyrics = lyrics
        currentLine = ""
        if let line = lyrics.line(at: track.position) {
            currentLine = line.text
            if let translation = line.translation, !translation.isEmpty {
                currentLine = "\(line.text)\n\(translation)"
            }
        }
        applyWindowVisibility()
        updateDisplayedLine(position: track.position)
        notifyIfChanged()
    }

    /// Lyrics may appear in Music's cache a moment after a track starts. A few
    /// spaced retries catch the late write without restarting the track, as long
    /// as the same track is still playing and lyrics are still missing.
    private func scheduleLyricsRetry(for track: TrackInfo) {
        guard lyricsRetryCount < Self.lyricsRetryDelays.count else { return }
        let delay = Self.lyricsRetryDelays[lyricsRetryCount]
        lyricsRetryCount += 1
        let provider = lyricsProvider
        lyricsRetryTask?.cancel()
        lyricsRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.isActive, self.isEnabled else { return }
            guard self.currentTrack?.identityKey == track.identityKey else { return }
            guard self.currentLyrics.lines.isEmpty else { return }

            let lyrics = await Task.detached(priority: .userInitiated) {
                provider.lyrics(for: track)
            }.value
            guard !Task.isCancelled else { return }
            guard self.isActive, self.isEnabled else { return }
            guard self.currentTrack?.identityKey == track.identityKey else { return }
            guard self.currentLyrics.lines.isEmpty else { return }

            self.applyFetchedLyrics(lyrics, for: track)
            if lyrics.lines.isEmpty {
                self.scheduleLyricsRetry(for: track)
            }
        }
    }

    private func cancelLyricsWork() {
        lyricsFetchTask?.cancel()
        lyricsFetchTask = nil
        lyricsRetryTask?.cancel()
        lyricsRetryTask = nil
        lyricsRetryCount = 0
    }

    /// Invalidates the in-flight Music request so a late reply is discarded
    /// instead of reopening the window or applying stale state.
    private func invalidateFetchRequest() {
        activeFetchRequestID = nil
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil
        isFetchInFlight = false
        fetchTimedOut = false
    }

    private func notifyIfChanged() {
        let current = snapshot
        guard current != lastReportedSnapshot else { return }
        lastReportedSnapshot = current
        onStateChange?()
    }

    private func updateDisplayedLine(position: TimeInterval) {
        guard let track = currentTrack else { return }
        guard !currentLyrics.lines.isEmpty else {
            currentLine = ""
            floatingWindow.hideLyrics()
            return
        }
        if let line = currentLyrics.line(at: position) {
            currentLine = line.text
            if let translation = line.translation, !translation.isEmpty {
                currentLine = "\(line.text)\n\(translation)"
            }
        }
        if track.state == .playing {
            floatingWindow.update(
                track: track,
                lyrics: currentLyrics,
                position: position
            )
        }
    }

    private func applyWindowVisibility() {
        guard let track = currentTrack else {
            floatingWindow.hideLyrics()
            return
        }
        guard track.state == .playing, !currentLyrics.lines.isEmpty else {
            floatingWindow.hideLyrics()
            return
        }
        floatingWindow.update(
            track: track,
            lyrics: currentLyrics,
            position: track.position
        )
        floatingWindow.showLyrics()
    }

    private func applyAppearance() {
        floatingWindow.setAppearance(currentAppearance)
    }

    // MARK: - Clamping

    private static func clampedFontSize(_ value: Double) -> Double {
        min(max(value, allowedFontSizeRange.lowerBound), allowedFontSizeRange.upperBound)
    }

    private static func clampedOpacity(_ value: Double) -> Double {
        min(max(value, allowedOpacityRange.lowerBound), allowedOpacityRange.upperBound)
    }

    private static func clampedTextOpacity(_ value: Double) -> Double {
        min(max(value, allowedTextOpacityRange.lowerBound), allowedTextOpacityRange.upperBound)
    }

    // MARK: - Window position persistence

    private static func windowPosition(from storage: any PluginStorage) -> NSPoint? {
        guard let raw = storage.string(forKey: StorageKey.windowPosition) else { return nil }
        let parts = raw.split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else { return nil }
        return NSPoint(x: x, y: y)
    }

    private func saveWindowPosition(_ point: NSPoint) {
        storage.set("\(point.x),\(point.y)", forKey: StorageKey.windowPosition)
    }

    private static func clampedCornerRadius(_ value: Double) -> Double {
        min(max(value, allowedCornerRadiusRange.lowerBound), allowedCornerRadiusRange.upperBound)
    }
}

/// A Sendable, displayable failure from a Music.app poll. Keeping this concrete
/// (rather than `Error`) lets the asynchronous poll run inside `withTaskGroup`.
enum AppleMusicPollingError: Error, Sendable, Equatable, LocalizedError {
    case automationDenied
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .automationDenied:
            return "Automation access to Music was denied. Open System Settings → Privacy & Security → Automation and allow MacTools to control Music."
        case .timedOut:
            return "Music did not respond in time"
        case .failed(let message):
            return message
        }
    }
}
