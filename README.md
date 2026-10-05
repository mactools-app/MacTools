<div align="center">
  <img src="docs/assets/logo-mactools-rounded.png" width="88" height="88" alt="MacTools logo">
  <h1>MacTools</h1>
  <p><strong>Your Mac's everyday tools, right in the menu bar.</strong></p>
  <p>Free, open source, and native to macOS. Build your own panels, connect actions, and add the tools you need.</p>
  <p><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>
  <p>
    <a href="https://github.com/ggbond268/MacTools/releases"><img src="https://img.shields.io/github/v/release/ggbond268/MacTools?filter=v*" alt="Latest app release"></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-24292f" alt="macOS 14 or later">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="GPL-3.0-only license"></a>
  </p>
  <p><a href="https://mactools.ggbond.app">Website</a> · <a href="https://github.com/ggbond268/MacTools/releases">Download</a> · <a href="docs/README.md">Documentation</a> · <a href="https://github.com/ggbond268/MacTools/issues">Feedback</a></p>
</div>

<p align="center">
  <a href="docs/assets/screenshots/readme/dashboard-en-dark.png"><img src="docs/assets/screenshots/readme/dashboard-en-dark.png" width="32%" alt="System status panel with live metrics, processes, device batteries, and quick controls"></a>
  <a href="docs/assets/screenshots/readme/activity-en-dark.png"><img src="docs/assets/screenshots/readme/activity-en-dark.png" width="32%" alt="Activity Statistics panel with input counts, screen time, app usage, and trends"></a>
  <a href="docs/assets/screenshots/readme/controls-en-dark.png"><img src="docs/assets/screenshots/readme/controls-en-dark.png" width="32%" alt="Quick controls for displays, appearance, audio, and power"></a>
</p>

## Install

```bash
brew install --cask mactools
```

Or download the app from [GitHub Releases](https://github.com/ggbond268/MacTools/releases). Requires **macOS 14 or later**; some plugins need newer macOS versions or compatible hardware.

Open MacTools, choose plugins in **Settings → Marketplace**, then arrange your menu bar panels. Permissions are requested as needed.

Plugin shortcut settings use the same separate section headings and native cards as other settings, without empty-section gaps or redundant navigation buttons.

Custom settings workspaces use adaptive system backgrounds that coordinate with native settings cards. Search fields, inset previews, and selected controls retain distinct visual roles in light and dark appearance.

System Status settings use subtle metric row separators, aligned controls, and a two-line metric header in narrow windows to keep names and value assignments readable.

<details>
<summary>Updates and Nightly builds</summary>

MacTools checks for app updates automatically. With Homebrew:

```bash
brew update
brew upgrade --cask --greedy mactools
```

Try development features with `MacTools-Nightly.dmg` from a [`nightly-*` prerelease](https://github.com/ggbond268/MacTools/releases). Nightly has separate preferences and plugins and can coexist with the stable app. It is intended for testing; hardware controls still affect the same Mac.

</details>

## Make it yours

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>Custom panels</h3>
      <p>Mix live widgets, quick controls, and feature rows. Drag to rearrange them, move them between panels, and choose each panel's icon. More and editing menus open on the first click from a background app; detail panels stay open during internal focus changes.</p>
      <a href="docs/assets/screenshots/readme/components-en-dark.png"><img width="100%" src="docs/assets/screenshots/readme/components-en-dark.png" alt="MacTools component library with a System Status widget preview"></a>
    </td>
    <td width="50%" valign="top">
      <h3>Custom themes</h3>
      <p>Choose built-in palettes or import iTerm2 and Base16/Base24 themes. Set light and dark themes separately, choose system glass or solid floating panels, and personalize the menu bar icon with images or animations.</p>
      <a href="docs/assets/screenshots/readme/themes-en-dark.png"><img width="100%" src="docs/assets/screenshots/readme/themes-en-dark.png" alt="Dark theme gallery with System Default, One Dark, GitHub Dark, and other palettes"></a>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>Automation &amp; workflows</h3>
      <p>Chain actions with delays and failure handling. Trigger workflows by schedule, calendar events, apps, power, displays, or network changes, and review their run history.</p>
      <a href="docs/assets/screenshots/readme/automation-en-dark.png"><img width="100%" src="docs/assets/screenshots/readme/automation-en-dark.png" alt="Multi-step workflow in the MacTools automation editor"></a>
    </td>
    <td width="50%" valign="top">
      <h3>A growing plugin marketplace</h3>
      <p>Browse dozens of plugins for productivity, displays, audio, cleanup, and monitoring. Install and update the ones you need, with settings and shortcuts in one place.</p>
      <a href="docs/assets/screenshots/readme/marketplace-en-dark.png"><img width="100%" src="docs/assets/screenshots/readme/marketplace-en-dark.png" alt="MacTools plugin marketplace with category filters and installed plugins"></a>
    </td>
  </tr>
</table>

## Get to any action quickly

Search actions, settings, workflows, and plugins from the **Command Palette**. Press **⌘K** within MacTools, or assign a global shortcut to open it from anywhere. Use **Action Grid**, keyboard shortcuts, mouse mappings, or trackpad gestures for frequent actions; connect Apple Shortcuts, saved scripts, and [Run Links](docs/url-scheme.md) to your setup.

Window Switcher keeps the compact toolbar in Cycle and Direct Key modes. Search Select uses that same toolbar with its inline search field expanded and focused. Cycle switches on shortcut release until you type or press **⌘F**, which opens search and keeps the chooser visible. All Windows sits beside the display filter and expands when an app scope is available; Search, More, and the grid/list control align to the right. Click the mode indicator to cycle through Search Select, Cycle, and Direct Key; the selection is saved, and the open chooser stays available for Enter or Escape. Window-key assignments reserve **⌘F** for search. Close Search clears the query and restores the previous mode while keeping scope and display filters.

In Direct Keys mode, **Tab** selects the next window and **Shift-Tab** selects the previous one, wrapping within the current results. **Return** opens the selected window. Search editing and shortcut recording keep their own Tab behavior.

Switching between grid and list keeps the selected window and visible shortcut numbers in sync, including after scrolling or filtering. Scrollbars hide when all results fit, and the grid stays clear of overlaid navigation buttons.

The selected window stays fully visible when the chooser opens, resizes, or changes layout. Grid results scroll with a mouse or trackpad. Previews support pinch zoom in every chooser mode, including while Tab changes the selected window. Choosing a minimized window restores it before switching. Helper-rendered apps participate in recent-use ordering, while inactive titleless surfaces stay out of the chooser.

Editing a direct shortcut highlights its key and shows a concise prompt beside Direct Keys, with Cancel at the far right. Recording instructions and feedback are available in all 12 supported languages.

<p align="center"><a href="docs/assets/screenshots/readme/search-en-dark.png"><img src="docs/assets/screenshots/readme/search-en-dark.png" width="640" alt="Command Palette searching window actions, settings, and plugins in English"></a></p>

## A toolbox for everyday work

| Area | What you can do |
| --- | --- |
| Capture & clipboard | Annotate screenshots, use OCR and QR recognition, pin images, capture scrolling content, and record a region. Keep encrypted local clipboard history, snippets, and paste queues, with a default clipboard content limit of 30 MB per item. |
| Windows & workspace | Switch and arrange windows, launch apps, manage Stage Manager, and customize Finder's right-click menu. |
| Keyboard, mouse & trackpad | Remap inputs, assign gestures and app shortcuts, tune scrolling, add middle-click, and type text with Auto Input. |
| Displays & appearance | Adjust brightness and resolution, connect Sidecar, toggle True Tone and Night Shift, hide the notch, and organize menu bar icons and the Dock. |
| Audio & power | Control system, microphone, app, and display volume; keep the Mac awake; manage fans and charging limits; lock, sleep, or shut down. |
| Monitoring & calendar | Follow system performance, device batteries, activity statistics, AI usage, and network status, or combine battery, Wi-Fi, and volume into one resizable menu bar icon with the battery percentage, status colors, detailed network states, and a Bluetooth audio mark. Check your calendar and upcoming events. |
| Cleanup & maintenance | Explore disk usage visually, review large files and folders before moving them to Trash, see where storage goes across caches, developer tools, app data, and IM chat tools, clean disk and Xcode files, manage Homebrew and login items, eject disks, empty Trash, quit apps, repair quarantined apps, soft-restart macOS, and use physical Clean Mode. |
| Utilities & configuration | Translate selected text, run editable AI prompt templates on selected text, upload to Cloudflare R2, edit zsh files, open Siri, and save reusable Mac Settings profiles. |

Clipboard History moves reused items to the front when you copy or paste them from the plugin, including item shortcuts and snippets. Browsing leaves the order unchanged, and sequential paste queues keep their established order. History expires after the configured period of inactivity, measured from its latest use or capture. Count and storage limits apply separately; Saved items and snippets remain available.

Clipboard history defaults to a 512 MB content capacity, with 64 MB, 256 MB, 512 MB, 1 GB, and 5 GB options. Existing saved capacity settings are preserved.

Clipboard opens on the display under the pointer and remembers each display's window position after dragging the title bar or top handle. Automatic repositioning when displays change preserves those saved positions.

Window Switcher, Command Palette, Clipboard History, and clipboard actions share compact search headers with soft gray fields. Existing close controls use borderless icons; each panel keeps its original controls. Hover and focus feedback stay subtle; Increase Contrast restores visible boundaries.

The clipboard panel and action menu use neutral system gray selections. Native action buttons have matching heights and subtle hover feedback, with an icon-only More button. List titles use regular weight while detail headings remain emphasized.

Clipboard selection and scrolling respond immediately. Rapid navigation skips transient preview requests, and recent image and rich-text previews are reused within bounded caches. Large rich-text items use their saved text summaries for preview.

Screenshots work on macOS 14+; region recording and per-app volume require macOS 15+. Hardware controls depend on device support. See the [feature guides](docs/README.md) for details.

Screenshot selection remains available on each display after switching desktops or entering and leaving full-screen apps.

**Take your setup with you:** export and import preferences, keep local backups, or sync supported settings through a cloud or shared folder. The app supports **12 languages** and follows your system language by default.

## `mactools` in your terminal

Discover actions, check availability, and run supported actions from scripts or local AI agents, with **JSON output**, timeouts, and cancellation.

The CLI is currently an **experimental Nightly feature on Apple silicon**. Install it from **Settings → General → Command Line** in a supported Nightly build, then enable integration. The Nightly command is `mactools-nightly`; ordinary stable releases do not yet offer managed CLI installation.

```bash
mactools-nightly doctor --json
mactools-nightly actions list --json
```

Use `actions describe <id>` and `actions availability <id>` to inspect an ID returned by the list, then `actions run <id>` to execute it. Execution is limited to eligible, safe, background, automatic, portable, parameterless actions; typed parameters and saved presets are not yet supported.

[CLI installation](docs/testing/cli-nightly-distribution.md) · [AI-agent usage](docs/cli/agent-usage.md) · [URL API](docs/url-scheme.md)

## Contribute

Bug reports, translations, plugin ideas, and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) for the Swift 6 / SwiftUI / AppKit development setup, or the [plugin development guide](docs/plugins/local-native-plugins.md) to build a plugin.

<a href="https://github.com/ggbond268/MacTools/graphs/contributors"><img src="https://contrib.rocks/image?repo=ggbond268/MacTools&max=120&columns=12" width="480" alt="MacTools contributors"></a>

## Privacy & license

Local-first, with no maintainer-operated analytics or advertising. Network-dependent features and system permissions are explained in the [Privacy Policy](https://mactools.ggbond.app/privacy-policy).

[GPL-3.0-only](LICENSE). See [licensing scope](LICENSING.md) and [third-party notices](Sources/Resources/ThirdPartyNotices/README.md) for dependencies, artwork, and acknowledgments.

<a href="https://hellogithub.com/repository/ggbond268/MacTools"><img src="https://abroad.hellogithub.com/v1/widgets/recommend.svg?rid=6cddbd75f09848fb8848b58510394a5c&claim_uid=g4n28zqFcD0Vhw3&theme=small" alt="Featured on HelloGitHub"></a>
