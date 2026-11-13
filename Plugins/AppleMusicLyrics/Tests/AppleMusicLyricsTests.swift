import XCTest
import MacToolsPluginKit
@testable import AppleMusicLyricsPlugin

final class AppleTTMLParserTests: XCTestCase {

    func testParseSimpleTTML() throws {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body>
            <div>
              <p begin="0s" end="3s">First line</p>
              <p begin="3s" end="6s">Second line</p>
              <p begin="6s" end="9s">Third line</p>
            </div>
          </body>
        </tt>
        """

        let parsed = try AppleTTMLParser.parse(ttml)
        XCTAssertEqual(parsed.lines.count, 3)
        XCTAssertEqual(parsed.lines[0].text, "First line")
        XCTAssertEqual(parsed.lines[0].time, 0, accuracy: 0.01)
        XCTAssertEqual(parsed.lines[1].text, "Second line")
        XCTAssertEqual(parsed.lines[1].time, 3, accuracy: 0.01)
        XCTAssertEqual(parsed.lines[2].text, "Third line")
        XCTAssertEqual(parsed.lines[2].time, 6, accuracy: 0.01)
    }

    func testParseTimedSpansProducesWords() throws {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body>
            <div>
              <p begin="0s" end="2s"><span begin="0s" end="0.7s">Hello </span><span begin="0.7s" end="1.4s">world </span><span begin="1.4s" end="2s">!</span></p>
            </div>
          </body>
        </tt>
        """

        let parsed = try AppleTTMLParser.parse(ttml)
        XCTAssertEqual(parsed.lines.count, 1)
        let line = try XCTUnwrap(parsed.lines.first)
        XCTAssertEqual(line.text, "Hello world !")
        XCTAssertEqual(line.words.count, 3)
        XCTAssertEqual(line.words[0].text, "Hello ")
        XCTAssertEqual(line.words[0].start, 0, accuracy: 0.01)
        XCTAssertEqual(line.words[0].end, 0.7, accuracy: 0.01)
        XCTAssertEqual(line.words[1].text, "world ")
        XCTAssertEqual(line.words[1].start, 0.7, accuracy: 0.01)
        XCTAssertEqual(parsed.wordTiming, .exact)
    }

    func testParseMillisecondTimestamps() throws {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body>
            <div>
              <p begin="1500ms" end="3000ms">Line</p>
            </div>
          </body>
        </tt>
        """

        let parsed = try AppleTTMLParser.parse(ttml)
        XCTAssertEqual(parsed.lines.count, 1)
        XCTAssertEqual(parsed.lines[0].time, 1.5, accuracy: 0.01)
    }

    func testParseClockTimestamps() throws {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body>
            <div>
              <p begin="00:01:30.000" end="00:01:35.000">Line</p>
            </div>
          </body>
        </tt>
        """

        let parsed = try AppleTTMLParser.parse(ttml)
        XCTAssertEqual(parsed.lines.count, 1)
        XCTAssertEqual(parsed.lines[0].time, 90, accuracy: 0.01)
    }

    func testParseEmptyTTML() throws {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body>
            <div></div>
          </body>
        </tt>
        """

        let parsed = try AppleTTMLParser.parse(ttml)
        XCTAssertTrue(parsed.lines.isEmpty)
    }
}

final class LyricsDocumentTests: XCTestCase {

    func testLineIndexAtPosition() {
        let document = LyricsDocument(
            lines: [
                LyricLine(time: 0, text: "Line 1"),
                LyricLine(time: 5, text: "Line 2"),
                LyricLine(time: 10, text: "Line 3"),
            ],
            source: "test",
            isSynced: true,
            wordTiming: .none
        )

        XCTAssertEqual(document.lineIndex(at: -1), nil)
        XCTAssertEqual(document.lineIndex(at: 0), 0)
        XCTAssertEqual(document.lineIndex(at: 2.5), 0)
        XCTAssertEqual(document.lineIndex(at: 5), 1)
        XCTAssertEqual(document.lineIndex(at: 7.9), 1)
        XCTAssertEqual(document.lineIndex(at: 10), 2)
        XCTAssertEqual(document.lineIndex(at: 100), 2)
    }

    func testLineAtPosition() {
        let document = LyricsDocument(
            lines: [
                LyricLine(time: 0, text: "Line 1"),
                LyricLine(time: 5, text: "Line 2"),
            ],
            source: "test",
            isSynced: true,
            wordTiming: .none
        )

        XCTAssertEqual(document.line(at: 0)?.text, "Line 1")
        XCTAssertEqual(document.line(at: 6)?.text, "Line 2")
        XCTAssertNil(document.line(at: -1))
    }
}

@MainActor
final class AppleMusicLyricsControllerTests: XCTestCase {

    private func makeStorage() -> PluginStorage {
        UserDefaultsPluginStorage(pluginID: "apple-music-lyrics-test")
    }

    func testSettingsPersistence() {
        let storage = makeStorage()
        let controller = AppleMusicLyricsController(
            storage: storage,
            localization: PluginLocalization(bundle: .main)
        )

        controller.setFontSize(32)
        XCTAssertEqual(controller.fontSize, 32)

        controller.setBackgroundOpacity(0.3)
        XCTAssertEqual(controller.backgroundOpacity, 0.3, accuracy: 0.001)

        controller.setTextOpacity(0.6)
        XCTAssertEqual(controller.textOpacity, 0.6, accuracy: 0.001)

        controller.setCornerRadius(8)
        XCTAssertEqual(controller.cornerRadius, 8)

        controller.setShowsNextLine(false)
        XCTAssertFalse(controller.showsNextLine)

        controller.setTextColor(.white)
        XCTAssertEqual(controller.textColor, .white)

        controller.setAllowsDragging(true)
        XCTAssertTrue(controller.allowsDragging)

        controller.setKaraokeEnabled(false)
        XCTAssertFalse(controller.karaokeEnabled)
    }

    func testSettingsClamping() {
        let storage = makeStorage()
        let controller = AppleMusicLyricsController(
            storage: storage,
            localization: PluginLocalization(bundle: .main)
        )

        controller.setFontSize(100)
        XCTAssertEqual(controller.fontSize, 48)

        controller.setFontSize(5)
        XCTAssertEqual(controller.fontSize, 14)

        controller.setBackgroundOpacity(2.0)
        XCTAssertEqual(controller.backgroundOpacity, 1.0, accuracy: 0.001)

        controller.setTextOpacity(2.0)
        XCTAssertEqual(controller.textOpacity, 1.0, accuracy: 0.001)

        controller.setTextOpacity(0.0)
        XCTAssertEqual(controller.textOpacity, 0.1, accuracy: 0.001)

        controller.setCornerRadius(100)
        XCTAssertEqual(controller.cornerRadius, 28)
    }

    func testResetToDefaults() {
        let storage = makeStorage()
        let controller = AppleMusicLyricsController(
            storage: storage,
            localization: PluginLocalization(bundle: .main)
        )

        controller.setFontSize(36)
        controller.setBackgroundOpacity(0.2)
        controller.setTextOpacity(0.3)
        controller.setShowsNextLine(false)
        controller.setTextColor(.black)
        controller.setAllowsDragging(true)
        controller.setKaraokeEnabled(false)

        controller.resetToDefaults()

        XCTAssertEqual(controller.fontSize, 24)
        XCTAssertEqual(controller.backgroundOpacity, 0.65, accuracy: 0.001)
        XCTAssertEqual(controller.textOpacity, 1.0, accuracy: 0.001)
        XCTAssertEqual(controller.cornerRadius, 16)
        XCTAssertTrue(controller.showsNextLine)
        XCTAssertEqual(controller.textColor, .system)
        XCTAssertFalse(controller.allowsDragging)
        XCTAssertTrue(controller.karaokeEnabled)
        XCTAssertFalse(controller.snapshot.isEnabled)
    }
}

final class AppleMusicCacheLyricsProviderTests: XCTestCase {
    func testReadsRawTTMLString() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataDirectory = root.appendingPathComponent("fsCachedData", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="zh-Hans"><body><div>
          <p begin="1.0" end="2.0"><span begin="1.0" end="2.0">万家同檐下共享</span></p>
          <p begin="2.0" end="3.0"><span begin="2.0" end="3.0">亚太繁盛四季</span></p>
        </div></body></tt>
        """
        let response: [String: Any] = [
            "data": [[
                "attributes": [
                    "name": "Test Song",
                    "artistName": "Test Artist",
                    "albumName": "Test Album",
                    "durationInMillis": 180_000
                ],
                "relationships": [
                    "syllable-lyrics": [
                        "data": [[
                            "attributes": ["ttmlLocalizations": ttml]
                        ]]
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        try data.write(to: dataDirectory.appendingPathComponent(UUID().uuidString))

        let provider = AppleMusicCacheLyricsProvider(cacheDirectory: root)
        let track = TrackInfo(
            title: "Test Song",
            artist: "Test Artist",
            album: "Test Album",
            duration: 180,
            position: 1.5,
            state: .playing
        )
        let document = provider.lyrics(for: track)

        XCTAssertEqual(document.source, "Apple Music")
        XCTAssertEqual(document.lines.count, 2)
        XCTAssertEqual(document.lines.first?.text, "万家同檐下共享")
        XCTAssertEqual(document.lines.last?.text, "亚太繁盛四季")
        XCTAssertEqual(document.lines.first?.time ?? 0, 1.0, accuracy: 0.01)
    }
}

final class KaraokeRendererTests: XCTestCase {
    private let sungColor = NSColor.white
    private let upcomingColor = NSColor.gray

    private func makeLine(words: [LyricWord], time: TimeInterval = 0) -> LyricLine {
        LyricLine(time: time, text: words.map(\.text).joined(), words: words)
    }

    func testAllWordsSung() {
        let line = makeLine(words: [
            LyricWord(text: "你", start: 0, end: 1),
            LyricWord(text: "好", start: 1, end: 2)
        ])
        let result = KaraokeRenderer.attributed(
            line: line,
            position: 2.5,
            font: .systemFont(ofSize: 24),
            sungColor: sungColor,
            upcomingColor: upcomingColor
        )
        let full = result.string
        XCTAssertEqual(full, "你好")
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: full.count)) { value, range, _ in
            let color = value as? NSColor
            XCTAssertEqual(color, sungColor)
        }
    }

    func testAllWordsUpcoming() {
        let line = makeLine(words: [
            LyricWord(text: "你", start: 0, end: 1),
            LyricWord(text: "好", start: 1, end: 2)
        ])
        let result = KaraokeRenderer.attributed(
            line: line,
            position: -1,
            font: .systemFont(ofSize: 24),
            sungColor: sungColor,
            upcomingColor: upcomingColor
        )
        let full = result.string
        XCTAssertEqual(full, "你好")
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: full.count)) { value, range, _ in
            let color = value as? NSColor
            XCTAssertEqual(color, upcomingColor)
        }
    }

    func testMidWordTransition() {
        let line = makeLine(words: [
            LyricWord(text: "你好", start: 0, end: 2)
        ])
        // At position 1.0, exactly halfway through "你好"
        let result = KaraokeRenderer.attributed(
            line: line,
            position: 1.0,
            font: .systemFont(ofSize: 24),
            sungColor: sungColor,
            upcomingColor: upcomingColor
        )
        let full = result.string
        XCTAssertEqual(full, "你好")
        // First character should be sung, second upcoming
        let firstRange = NSRange(location: 0, length: 1)
        let secondRange = NSRange(location: 1, length: 1)
        var firstColor: NSColor?
        var secondColor: NSColor?
        result.enumerateAttribute(.foregroundColor, in: firstRange) { value, _, _ in
            firstColor = value as? NSColor
        }
        result.enumerateAttribute(.foregroundColor, in: secondRange) { value, _, _ in
            secondColor = value as? NSColor
        }
        XCTAssertEqual(firstColor, sungColor)
        XCTAssertEqual(secondColor, upcomingColor)
    }

    func testNoWordsFallsBackToLineColor() {
        let line = LyricLine(time: 0, text: "Hello")
        // Before line time: upcoming
        let before = KaraokeRenderer.attributed(
            line: line,
            position: -1,
            font: .systemFont(ofSize: 24),
            sungColor: sungColor,
            upcomingColor: upcomingColor
        )
        XCTAssertEqual(before.string, "Hello")
        var color: NSColor?
        before.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: 5)) { value, _, _ in
            color = value as? NSColor
        }
        XCTAssertEqual(color, upcomingColor)

        // After line time: sung
        let after = KaraokeRenderer.attributed(
            line: line,
            position: 1,
            font: .systemFont(ofSize: 24),
            sungColor: sungColor,
            upcomingColor: upcomingColor
        )
        after.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: 5)) { value, _, _ in
            color = value as? NSColor
        }
        XCTAssertEqual(color, sungColor)
    }

    func testKaraokeDisabledUsesSungColorForWholeLine() {
        // Even mid-word, disabling karaoke must paint the entire line with the
        // sung color and never expose the upcoming/dimmed variant.
        let line = makeLine(words: [
            LyricWord(text: "你好世界", start: 0, end: 4)
        ])
        let result = KaraokeRenderer.attributed(
            line: line,
            position: 2,
            font: .systemFont(ofSize: 24),
            sungColor: sungColor,
            upcomingColor: upcomingColor,
            karaokeEnabled: false
        )
        XCTAssertEqual(result.string, "你好世界")
        var allSung = true
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: 4)) { value, _, _ in
            if let color = value as? NSColor, color != sungColor {
                allSung = false
            }
        }
        XCTAssertTrue(allSung, "every character must use the sung color when karaoke is disabled")
    }

    func testKaraokeDisabledUsesSungColorForUntimedLine() {
        // A line with no word timings must also render entirely in sung color
        // when karaoke is disabled.
        let line = LyricLine(time: 0, end: 4, text: "Hello")
        let result = KaraokeRenderer.attributed(
            line: line,
            position: 2,
            font: .systemFont(ofSize: 24),
            sungColor: sungColor,
            upcomingColor: upcomingColor,
            karaokeEnabled: false
        )
        XCTAssertEqual(result.string, "Hello")
        var color: NSColor?
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: 5)) { value, _, _ in
            color = value as? NSColor
        }
        XCTAssertEqual(color, sungColor)
    }
}

final class LyricsTextColorOptionTests: XCTestCase {
    func testSungColorKeepsFullOpacity() {
        let color = LyricsTextColorOption.white.sungColor(opacity: 1.0)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testSungColorScalesWithOpacity() {
        let color = LyricsTextColorOption.white.sungColor(opacity: 0.5)
        XCTAssertEqual(color.alphaComponent, 0.5, accuracy: 0.001)
    }

    func testUpcomingColorKeepsBaseDimWhenOpacityIsFull() {
        // At full opacity, upcoming text must stay visibly dimmer than sung text.
        let color = LyricsTextColorOption.white.upcomingColor(opacity: 1.0)
        XCTAssertEqual(color.alphaComponent, 0.18, accuracy: 0.001)
    }

    func testUpcomingColorScalesWithOpacity() {
        let color = LyricsTextColorOption.white.upcomingColor(opacity: 0.5)
        XCTAssertEqual(color.alphaComponent, 0.09, accuracy: 0.001)
    }

    func testUpcomingStaysDimmerThanSung() {
        for opacity in [0.2, 0.5, 0.8, 1.0] {
            let sung = LyricsTextColorOption.white.sungColor(opacity: opacity)
            let upcoming = LyricsTextColorOption.white.upcomingColor(opacity: opacity)
            XCTAssertGreaterThan(sung.alphaComponent, upcoming.alphaComponent,
                                 "sung must stay brighter than upcoming at opacity \(opacity)")
        }
    }

    func testBlackVariantSameDim() {
        let color = LyricsTextColorOption.black.upcomingColor(opacity: 0.6)
        XCTAssertEqual(color.alphaComponent, 0.18 * 0.6, accuracy: 0.001)
    }
}

// MARK: - Polling / automation / backup

private final class MockNowPlayingService: AppleMusicNowPlayingServicing, @unchecked Sendable {
    var isMusicRunning = true
    var result: Result<TrackInfo?, Error> = .success(nil)
    /// Simulated AppleScript latency; the mock sleeps on the fetch queue.
    var delay: TimeInterval = 0
    private(set) var fetchCount = 0

    func fetch() -> Result<TrackInfo?, Error> {
        fetchCount += 1
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        return result
    }
}

@MainActor
final class AppleMusicLyricsPollingTests: XCTestCase {

    private func makeStorage() -> PluginStorage {
        UserDefaultsPluginStorage(pluginID: "apple-music-lyrics-test-\(UUID().uuidString)")
    }

    private func playingTrack() -> TrackInfo {
        TrackInfo(
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            position: 10,
            state: .playing
        )
    }

    func testAutomationDeniedStopsPollingAndReportsError() async {
        let storage = makeStorage()
        let service = MockNowPlayingService()
        service.result = .failure(AppleMusicScriptError.automationDenied)
        let controller = AppleMusicLyricsController(
            storage: storage,
            localization: PluginLocalization(bundle: .main),
            nowPlayingService: service
        )
        controller.activate()
        controller.setEnabled(true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotNil(controller.snapshot.errorMessage)
        XCTAssertTrue(controller.snapshot.errorMessage?.contains("Automation") == true)

        // Polling must pause after the denial: a manual refresh must not issue
        // another Apple Event.
        let fetchCountAfterDenial = service.fetchCount
        controller.refresh()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(service.fetchCount, fetchCountAfterDenial)

        // Re-enabling clears the denial so the user can retry after granting
        // access in System Settings.
        controller.setEnabled(false)
        controller.setEnabled(true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(service.fetchCount, fetchCountAfterDenial)
    }

    func testAutomationDeniedClearsShownTrackAndHidesLyrics() async {
        let storage = makeStorage()
        let service = MockNowPlayingService()
        service.result = .success(playingTrack())
        let controller = AppleMusicLyricsController(
            storage: storage,
            localization: PluginLocalization(bundle: .main),
            nowPlayingService: service
        )
        controller.activate()
        controller.setEnabled(true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(controller.snapshot.isTrackPlaying)
        XCTAssertEqual(controller.snapshot.currentTrackTitle, "Song")

        // Deny access on the next poll: the stale track and its lyrics must be
        // dropped so the previous lyric does not linger on screen.
        service.result = .failure(AppleMusicScriptError.automationDenied)
        controller.refresh()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(controller.snapshot.isTrackPlaying)
        XCTAssertEqual(controller.snapshot.currentTrackTitle, "")
        XCTAssertTrue(controller.snapshot.errorMessage?.contains("Automation") == true)
    }

    func testErrorClearedWhenFeatureTurnedOff() async {
        let storage = makeStorage()
        let service = MockNowPlayingService()
        service.result = .failure(AppleMusicScriptError.automationDenied)
        let controller = AppleMusicLyricsController(
            storage: storage,
            localization: PluginLocalization(bundle: .main),
            nowPlayingService: service
        )
        controller.activate()
        controller.setEnabled(true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(controller.snapshot.errorMessage)

        controller.setEnabled(false)
        XCTAssertNil(controller.snapshot.errorMessage)
    }

    func testSlowRequestTimesOutAndKeepsOneRequestInFlight() async {
        let storage = makeStorage()
        let service = MockNowPlayingService()
        // Simulated Music reply is slower than the 1.5 s watchdog.
        service.delay = 3.0
        service.result = .success(playingTrack())
        let controller = AppleMusicLyricsController(
            storage: storage,
            localization: PluginLocalization(bundle: .main),
            nowPlayingService: service
        )
        controller.activate()
        controller.setEnabled(true)

        // Past the deadline the timeout must be reported even though the
        // synchronous AppleScript is still running.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(service.fetchCount, 1)
        XCTAssertTrue(
            controller.snapshot.errorMessage?.contains("did not respond") == true,
            "the timeout must be reported at the deadline, not after the slow reply"
        )

        // The slot stays occupied until the slow call finishes, so a manual
        // refresh must not start a second request.
        controller.refresh()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(service.fetchCount, 1, "one request must stay in flight")

        // After the slow call completes the slot frees and polling resumes.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        controller.refresh()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(service.fetchCount, 1, "polling must resume after the slot frees")
    }

    func testPollNotifiesOnlyWhenDisplayedStateChanges() async {
        let storage = makeStorage()
        let service = MockNowPlayingService()
        service.result = .success(playingTrack())
        let controller = AppleMusicLyricsController(
            storage: storage,
            localization: PluginLocalization(bundle: .main),
            nowPlayingService: service
        )
        var notifications = 0
        controller.onStateChange = { notifications += 1 }
        controller.activate()
        controller.setEnabled(true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The initial poll published the track. A second poll with identical
        // state must not re-notify the host.
        let countAfterFirstPoll = notifications
        controller.refresh()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(notifications, countAfterFirstPoll,
                       "a poll with unchanged displayed state must not notify the host")
    }

    func testPersistentChangeSignaledOnPortableSetter() {
        let storage = makeStorage()
        let controller = AppleMusicLyricsController(
            storage: storage,
            localization: PluginLocalization(bundle: .main)
        )
        var signaled = 0
        controller.onPersistentPreferencesChange = { signaled += 1 }

        controller.setFontSize(30)
        XCTAssertEqual(signaled, 1)

        controller.setTextColor(.white)
        XCTAssertEqual(signaled, 2)

        // Activation is not a portable appearance preference.
        controller.setEnabled(true)
        XCTAssertEqual(signaled, 2)
    }

    func testPortablePreferencesRoundTrip() throws {
        let sourceStorage = makeStorage()
        sourceStorage.set(32.0, forKey: AppleMusicLyricsController.StorageKey.fontSize)
        sourceStorage.set("white", forKey: AppleMusicLyricsController.StorageKey.textColor)
        sourceStorage.set(false, forKey: AppleMusicLyricsController.StorageKey.karaokeEnabled)
        sourceStorage.set("123,456", forKey: AppleMusicLyricsController.StorageKey.windowPosition)
        let source = AppleMusicLyricsPlugin(
            storage: sourceStorage,
            localization: PluginLocalization(bundle: .main)
        )
        let data = try XCTUnwrap(source.makePortablePreferencesBackup())

        let destStorage = makeStorage()
        var restoreNotified = false
        let dest = AppleMusicLyricsPlugin(
            storage: destStorage,
            localization: PluginLocalization(bundle: .main)
        )
        dest.onStateChange = { restoreNotified = true }
        XCTAssertTrue(dest.restorePortablePreferencesReportingResult(from: data))
        XCTAssertTrue(restoreNotified, "restore must reload the controller")

        XCTAssertEqual(destStorage.object(forKey: AppleMusicLyricsController.StorageKey.fontSize) as? Double, 32.0)
        XCTAssertEqual(destStorage.string(forKey: AppleMusicLyricsController.StorageKey.textColor), "white")
        XCTAssertEqual(destStorage.object(forKey: AppleMusicLyricsController.StorageKey.karaokeEnabled) as? Bool, false)
        // Screen coordinates are local to each Mac and must not transfer.
        XCTAssertNil(destStorage.object(forKey: AppleMusicLyricsController.StorageKey.windowPosition))
    }

    func testPortablePreferencesRejectsInvalidPayload() {
        let storage = makeStorage()
        let plugin = AppleMusicLyricsPlugin(
            storage: storage,
            localization: PluginLocalization(bundle: .main)
        )
        // Invalid data (out-of-range font size) must be rejected atomically.
        let invalid = """
        {"formatVersion":1,"values":{"apple-music-lyrics.font-size":{"number":999}}}
        """.data(using: .utf8)!
        XCTAssertFalse(plugin.restorePortablePreferencesReportingResult(from: invalid))
    }
}
