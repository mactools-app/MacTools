---
release: plugin
type: added
area: Apple Music Lyrics
---

New Apple Music desktop lyrics plugin: shows frosted-glass lyrics in the top-right corner with configurable font, opacity, and display options.

Added separate text opacity control so lyrics stay visible when the background is highly transparent.

Added karaoke-style word highlighting: sung words appear bright while upcoming words stay dimmed, matching Apple Music's lyric progress.

Added a drag toggle so you can reposition the lyrics window freely; the position is remembered across launches.

Added a karaoke rendering toggle to control per-word highlighting; the description notes that lyric timing is approximate and may drift from the actual singing.

Fixed lyric matching for catalog responses that return a raw TTML document instead of a localized dictionary.
