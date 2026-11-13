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

Kept the host responsive by polling Music off the main thread with a timeout and a single in-flight request, and by notifying the host only when the displayed state changes.

Enforced the polling timeout at the deadline even when a slow Music reply cannot be interrupted, keeping one request in flight at a time.

Declared Automation access; denial pauses polling, clears the current lyric, hides the window, and guides users to System Settings. The error clears when the feature is off or playback resumes.

Retried missing lyrics a few times while the same track is playing so lyrics appear as soon as Music caches them.

Kept the lyrics window closed after a reset by cancelling in-flight lookups and checking the plugin is still active before showing a result.

Kept background and text opacity independent by rendering the glass and the labels as siblings.

Included appearance preferences in Preferences Backup while keeping activation, window position, and permissions local to each Mac.
