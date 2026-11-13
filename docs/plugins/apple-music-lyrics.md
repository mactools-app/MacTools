# Apple Music Lyrics Plugin

`Plugins/AppleMusicLyrics/` shows a frosted-glass desktop lyrics window in the top-right corner while Apple Music plays a song that has lyrics. The plugin reads the lyric documents already cached by Apple Music on the local machine and never needs an Apple account or a network request.

The floating window is a borderless `NSPanel` with an `NSVisualEffectView` using the `.hudWindow` material, so it blends with the desktop and stays on top of other windows while remaining non-activating. It shows the current track and artist, the current lyric line, and optionally the next line. Track and playback position are polled from Music.app every `0.5 s`; lyrics are matched by title, artist, album, and duration against the cached catalog responses.

Reading playback state sends Apple Events to Music, so the plugin needs **Automation** access. The first poll triggers the macOS prompt; if it is denied, the plugin pauses polling, clears the current lyric, hides the window, and the panel shows guidance to open **System Settings → Privacy & Security → Automation** and allow MacTools to control Music. Re-enabling the plugin retries after the grant. The AppleScript round trip runs on a dedicated queue off the main thread with a `1.5 s` watchdog that reports a timeout at the deadline, keeping a single request in flight so a slow or unresponsive Music process never freezes the MacTools UI. The host is notified only when the displayed state actually changes, not on every poll.

## Settings

- **启用桌面歌词 / Enable desktop lyrics** turns the plugin on and off.
- **歌词字号 / Font size** adjusts the current line's font size from `14 pt` to `48 pt`.
- **背景透明度 / Background opacity** controls the frosted-glass material opacity from `0.1` to `1.0`; lower values are more transparent.
- **字体透明度 / Text opacity** controls the text opacity independently from `0.1` to `1.0`, so lyrics stay readable on a very transparent background.
- **圆角半径 / Corner radius** sets the window's corner radius from `0 pt` to `28 pt`.
- **显示下一句歌词 / Show next line** shows the upcoming lyric line under the current one.
- **文字颜色 / Text color** chooses white, black, or system (white on the dark HUD material).
- **允许拖动位置 / Allow dragging** lets the user drag the window freely and remembers the position across launches.
- **逐字渲染 / Karaoke rendering** highlights sung and upcoming words progressively. Apple Music's lyric timing is approximate, so the per-word effect may drift from the actual singing.

Preferences are stored locally under `apple-music-lyrics.*` keys. The appearance preferences (font, opacity, color, next-line, dragging, and karaoke) transfer through Preferences Backup; activation, the saved window position, and the Automation permission stay local to each Mac. The plugin makes no network requests.

## Karaoke Rendering

When per-word timing is available, `KaraokeRenderer` paints already-sung grapheme clusters with the full text color and upcoming clusters with a strongly dimmed variant (`18 %` alpha), transitioning cluster by cluster as playback advances. When a line has no per-word `<span>` timings but does carry a `<p end>` time, the renderer falls back to a left-to-right gradient across the whole line based on playback progress. When karaoke rendering is disabled, the whole line uses the sung color and no sung/upcoming distinction is painted.

## Development Validation

Generate the plugin targets and run the focused tests with:

```bash
make generate
xcodebuild \
  -project MacTools.xcodeproj \
  -scheme MacTools \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  test -quiet \
  -only-testing:MacToolsTests/AppleMusicLyricsControllerTests \
  -only-testing:MacToolsTests/KaraokeRendererTests \
  -only-testing:MacToolsTests/LyricsTextColorOptionTests \
  -only-testing:MacToolsTests/AppleTTMLParserTests \
  -only-testing:MacToolsTests/AppleMusicCacheLyricsProviderTests \
  -only-testing:MacToolsTests/LyricsDocumentTests \
  -only-testing:MacToolsTests/AppleMusicLyricsPollingTests
```

Manual verification needs Apple Music playing a song with synced lyrics. Confirm the window appears in the top-right corner, the current line advances with playback, and upcoming text is visibly dimmer when karaoke rendering is enabled. Turn on **允许拖动位置 / Allow dragging**, drag the window, relaunch MacTools, and confirm the position is restored. Toggle **逐字渲染 / Karaoke rendering** and confirm the sung/upcoming contrast appears and disappears. With the background at `10 %` and text at `100 %`, the text must stay fully opaque while the glass dims. If no Automation prompt appears, open **System Settings → Privacy & Security → Automation** and confirm MacTools is allowed to control Music.
