# Dynamic Island Notifications

Shows macOS notifications as cards that grow out of the camera island on the MacBook Pro introduced with macOS 27, the way iPhone shows them from the Dynamic Island. The plugin is off by default and stays local to this Mac.

## Requirements

- A MacBook Pro with the camera island and macOS 27 or later, with the built-in display active. On every other Mac, including notched ones, the plugin reports that it is unavailable and does nothing.
- Accessibility, granted through the plugin's permission card. The plugin uses it to read banners and keep their window out of sight.
- Full Disk Access is optional. It is used only to read Messages' own history, so that a reply goes to the exact conversation.

## How it works

The plugin watches Notification Centre's banner windows through Accessibility. When a banner appears, its window is moved off screen before it draws, and the plugin shows its own non-activating card in its place.

Notification Centre stays the record. Every notification still goes into its history, and Focus, notification styles and preview privacy apply before a banner exists. The plugin never changes notification settings and never reads Notification Centre's database.

Cards:

- **Lifetime:** a temporary card stays for five seconds, paused while it is hovered, held open, being replied to, or under the MacTools hover panel. A persistent alert waits until it is dismissed.
- **Several notifications:** one card shows at a time. A newer temporary notification replaces an idle card after one second; a held or busy card is never interrupted.
- **Gestures:** swipe up to dismiss. Pull down to open the full message, or to hold a card that has nothing more to show. A click opens the exact item through the banner's own action, and Esc closes the card.
- **Replies:** Messages cards reply to the conversation found in Messages' history, never to one matched by name. Claude cards follow Claude Code's session logs and type the reply into that chat, without bringing Claude forward.
- **Live Activities:** with a compact system Live Activity showing, the card splits below it. With an expanded or unreadable activity, banners stay native.

Notification text never leaves the Mac and is never written to disk. The logs record steps only.

## Notifications list

The list in the panel shows the notifications the island has shown since MacTools started, stacked by app. It lives in memory and is cleared when MacTools quits.

Opening or clearing an entry acts on its row in Notification Centre, so the app opens the exact item. Notification Centre is opened through its own accessibility action on a short-lived background thread, its window is moved off screen as it appears, and the row is pressed. Notification Centre applies that move only after drawing its first frame, so on rare occasions a sliver of it shows at the screen edge for a few tens of milliseconds.

If the row is gone, because the app withdrew it or it was cleared, Messages and Claude entries open their conversation or chat directly. Every other entry opens its app.

## Recovery

Turning the plugin off, unloading it and quitting normally put every hidden window back. A window left off screen by a forced quit is recovered the next time the plugin starts. Unknown windows, and windows that cannot be read completely, are left untouched.

## Manual acceptance

Automated tests cover the queue, safety decisions, list grouping and description matching. The checks below need the hardware.

- With the switch off or Accessibility denied, confirm banners stay native and no card appears. Repeat with only an external display active.
- Send temporary banners, banners with private previews, and banners under Focus. Check that nothing flashes or ghosts, and that Notification Centre history is complete.
- While typing in another app, hover a card and close it, and confirm keyboard focus stays in that app.
- Test the gestures. Click a fresh card and confirm the exact item opens.
- Reply to a Messages card and a Claude card, and confirm the reply reaches the right conversation.
- Send several notifications in a row, and send one while the hover panel is open.
- Open and clear entries in the Notifications list, including one inside a stack.
- Test a persistent alert, a Notification Centre restart, sleep and wake, display changes, and opening Notification Centre while a card is showing.
- Check Reduce Motion, VoiceOver announcements and actions, long text, and another system language.
