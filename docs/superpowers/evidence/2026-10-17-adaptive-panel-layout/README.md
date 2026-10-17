# Adaptive panel layout review captures

These are native AppKit/SwiftUI captures of the implemented host renderers on macOS 27.2, using isolated sample data. Keep Awake and System Status use their real views with mocked state or services; other rows are fixtures. IP addresses use documentation-only TEST-NET ranges. No live user settings, network addresses, or hardware actions are captured.

Open the menu-bar popup, choose Edit Layout from its overflow menu, then use the column-count control in the header to set the panel width. Item width choices are available from the item menu while editing.

- `everyday-light.png`: three columns at 940 points.
- `everyday-dark.png`: two columns at 628 points in dark appearance.
- `editing.png`: edit-only drag handles, boundaries, and column feedback.
- `drop-preview.png`: a tall Keep Awake row's proposed destination in another column.
- `custom-theme.png`: the same drop footprint using the built-in One Light theme.
- `width-picker.png`: column presets and explicit application of an exact width.
- `custom-item-width.png`: Keep Awake at 610 points, spanning two column slots.

The drop captures programmatically position the preview; they are not recordings of a live OS drag. A short interaction recording, full VoiceOver navigation, and screen-edge/display-change acceptance remain manual follow-ups. The temporary capture harness is not part of the retained test suite.
