# Voice Assistant capability coverage

Voice Assistant discovers commands from enabled plugins at runtime. Existing complete catalog references are available automatically unless a provider excludes voice exposure; the counts below describe source declarations, not a promise that a device currently supports every action. Saved commands depend on the user's configured catalog. Required parameters need a provider adapter.

The main Voice Assistant settings page includes **Automatically allow newly installed plugins**, on by default. Its changes are saved immediately for future conversations. Turning it off keeps current selections and requires manual approval for later providers; existing explicit exclusions remain blocked when it is on. Manage Features retains searchable selections and batch edits with Cancel/Done. Allow All and Allow None change the listed providers without changing the automatic policy.

The Voice Assistant entry exposes two fixed voice commands for this setting. Disabling automatic access applies directly; enabling requires confirmation in the app. Changes never expand an already active conversation's grant. The host's Applications entry can also be allowed or excluded independently of other plugins.

This version adds fresh state queries for display brightness, system metrics, power, appearance, Keep Awake, Night Shift, and system mute. Brightness uses the same canonical controller write as native controls and validates the display generation before dispatch. Readback distinguishes Apple-native/DDC measurements from software dimming, missing observations, and pending writes. Voice excludes cursor-scoped increment shortcuts and uses the discovered display with an absolute percentage.

Every enabled feature also has a setup/review entry through the host. Opening that entry does not complete its operation; plugins without a dedicated settings page may open Marketplace. Features requiring pickers, editors, or native approvals keep those flows. Clipboard history, calendar contents, file contents, credentials, process names, and network addresses are not included in the new device-state queries. Adding private-content queries requires provider declarations and native approval.

| Plugin | Static commands | Saved/dynamic commands | Fresh voice state |
| --- | ---: | --- | --- |
| AI Assistant | 3 | — | — |
| AI Usage | — | — | — |
| Action Grid | 1 | — | — |
| Activity Stats | 2 | — | — |
| App Hotkeys | — | Yes | — |
| App Volume | — | Yes | — |
| Dark Mode | 3 | — | Appearance policy and current theme |
| Apple Shortcuts | — | Yes | — |
| Auto-hide Dock | 2 | — | — |
| Auto-hide Menu Bar | 3 | — | — |
| Auto Input | 2 | Yes | — |
| Battery Charge Limit | 4 | Yes | — |
| Calendar | — | — | — |
| Clear Clipboard | 1 | — | — |
| Clipboard | 9 | — | — |
| Cloudflare R2 Upload | 1 | — | — |
| Apple Container Status | — | — | — |
| Device Battery | — | — | — |
| Disk Cleanup | 1 | — | — |
| Display Brightness | 5 | — | Display list and fresh brightness readback |
| Display Resolution | — | Yes | — |
| Display Sleep | 1 | — | — |
| True Tone | 2 | — | — |
| Display Volume | 2 | — | — |
| Hide Active App on Dock Click | — | — | — |
| Dock Lock | 2 | — | — |
| Duo Status | — | — | — |
| Eject Disks | 1 | — | — |
| Empty Trash | 1 | — | — |
| Fan Control | — | Yes | — |
| Fix Damaged Apps | 1 | — | — |
| Hide Notch | 2 | — | — |
| Homebrew Manager | 4 | — | — |
| IP Check | 2 | — | — |
| Custom Shortcuts: Keyboard, Trackpad, Mouse | — | — | — |
| Keep Awake | 3 | — | Enabled, scheduled end, remaining time, display sleep prevention |
| Key Stats | — | — | — |
| Launch Items | — | Yes | — |
| Launchpad | 1 | — | — |
| Lock Screen | 1 | — | — |
| Mac Settings | 8 | — | — |
| Hide Menu Bar Icons | 1 | — | — |
| Microphone Mute | 2 | — | — |
| Middle Click | 1 | — | — |
| Mouse Enhancer | — | — | — |
| Night Shift | 2 | — | Fresh enabled state, with unavailable readback distinguished |
| Dynamic Island Hover Panel | — | — | — |
| Clean Mode | 1 | — | — |
| Power Status | — | — | Battery, charging, AC and measured power |
| Quit Apps | 1 | — | — |
| Right Click | — | — | — |
| Saved Scripts | — | Yes | — |
| Screenshot | 2 | — | — |
| Sidecar | 2 | Yes | — |
| Siri | 1 | — | — |
| Stage Manager | 2 | — | — |
| Storage Explorer | — | — | — |
| System Data | — | — | — |
| System Mute | 2 | — | Default output mute, with unavailable readback distinguished |
| Power Actions | 4 | — | — |
| System Soft Restart | 1 | — | — |
| System Status | 1 | — | CPU, memory, disk space, battery |
| Trackpad Gestures | — | — | — |
| Trackpad Scale | — | — | — |
| Translator | 2 | — | — |
| Window Layouts | 40 | Yes | — |
| Window Switcher | 2 | — | — |
| Xcode Cleanup | 1 | — | — |
| zsh Config | — | — | — |

Source inventory: 69 plugins and 136 static command declarations. Actual host availability and exposure policy remain authoritative.

## Acceptance priorities

Direct commands remain available for Window Layouts, appearance, Keep Awake presets, Night Shift, system mute, and named Apple Shortcuts. Read-only voice questions now cover seven providers. App Volume supports its discovered fixed volume presets for running apps; arbitrary volume percentages, generic window geometry, and unsupported parameter combinations require a dedicated adapter rather than invented arguments.

The host's Applications entry opens or activates matching apps from standard application folders and running apps elsewhere. Say “Open Google Chrome,” “Switch to Safari,” or “Open TextEdit”; no hotkey assignment, App Hotkeys entry, or Launchpad installation is required. The host revalidates the selected bundle before opening and uses native activation rather than App Hotkeys' visibility toggle. Multiple matches require clarification. App-specific operations such as creating a browser tab remain separate capabilities.

Native interfaces remain necessary for screenshot selection, file pickers, editors, and configuration-only plugins. Opening those interfaces is a successful navigation step, not a completed screenshot, cleanup, upload, or edit. Private clipboard/calendar/file/process queries remain excluded unless a provider declares a query with native approval.

For each beta smoke test, record the spoken request, enabled/allowed providers, discovered capability, host result, actual visible outcome, and any native prompt. Check a multi-plugin request, an ambiguous target, a disabled provider, cancellation before confirmation, and Stop during pending work. Device-specific behavior and confirmation remain part of acceptance even when discovery succeeds.
