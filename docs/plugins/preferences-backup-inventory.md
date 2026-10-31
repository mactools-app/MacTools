# Preferences Backup coverage inventory

Generated from `Plugins/*/plugin.json`; do not edit this table by hand.
Run `python3 scripts/plugins/generate-preferences-backup-inventory.py` after changing a declaration.

Declarations describe supported field boundaries. Runtime availability and export/restore failures are reported separately.
See [the backup contract](preferences-backup.md) for exclusions and recovery limits.

localOnly: 2; none: 25; partial: 36; portable: 7.

| Plugin | ID | Coverage | Exclusion codes |
| --- | --- | --- | --- |
| [AI Assistant](../../Plugins/AIAssistant) | `ai-assistant` | partial | credentials, permissions, private-content |
| [AI Usage](../../Plugins/AIUsage) | `ai-usage` | partial | credentials, permissions, history |
| [Action Grid](../../Plugins/ActionGrid) | `action-grid` | portable | — |
| [Activity Stats](../../Plugins/ActivityBar) | `activity-bar` | partial | local-activation, history |
| [App Hotkeys](../../Plugins/AppHotkey) | `app-hotkey` | partial | application-paths |
| [App Volume](../../Plugins/AppVolume) | `app-volume` | partial | permissions, device-state |
| [Dark Mode](../../Plugins/Appearance) | `appearance` | none | — |
| [Apple Shortcuts](../../Plugins/AppleShortcuts) | `apple-shortcuts` | partial | private-content |
| [Auto-hide Dock](../../Plugins/AutoHideDock) | `auto-hide-dock` | none | — |
| [Auto-hide Menu Bar](../../Plugins/AutoHideMenuBar) | `auto-hide-menu-bar` | none | — |
| [Auto Input](../../Plugins/AutoInput) | `auto-input` | partial | application-paths |
| [Battery Charge Limit](../../Plugins/BatteryChargeLimit) | `battery-charge-limit` | partial | local-activation, device-state |
| [Calendar](../../Plugins/Calendar) | `calendar` | partial | permissions, private-content |
| [Clear Clipboard](../../Plugins/ClipboardClear) | `clipboard-clear` | none | — |
| [Clipboard](../../Plugins/ClipboardHistory) | `clipboard` | partial | private-content, local-activation |
| [Cloudflare R2 Upload](../../Plugins/CloudflareR2) | `cloudflare-r2` | partial | credentials, local-activation, history |
| [Apple Container Status](../../Plugins/ContainerIndicator) | `container-indicator` | none | — |
| [Device Battery](../../Plugins/DeviceBattery) | `device-battery` | partial | device-state, permissions |
| [Disk Cleanup](../../Plugins/DiskClean) | `disk-clean` | localOnly | local-policy |
| [Display Brightness](../../Plugins/DisplayBrightness) | `display-brightness` | partial | device-state |
| [Display Resolution](../../Plugins/DisplayResolution) | `display-resolution` | none | — |
| [Display Sleep](../../Plugins/DisplaySleep) | `display-sleep` | none | — |
| [True Tone](../../Plugins/DisplayTrueColor) | `display-true-color` | none | — |
| [Display Volume](../../Plugins/DisplayVolume) | `display-volume` | partial | device-state |
| [Hide Active App on Dock Click](../../Plugins/DockClickMinimize) | `dock-click-minimize` | portable | — |
| [Dock Lock](../../Plugins/DockLock) | `dock-lock` | portable | — |
| [Duo Status](../../Plugins/DuoStatus) | `duo-status` | partial | device-state |
| [Eject Disks](../../Plugins/EjectDisk) | `eject-disk` | none | — |
| [Empty Trash](../../Plugins/EmptyTrash) | `empty-trash` | none | — |
| [Fan Control](../../Plugins/FanControl) | `fan-control` | partial | device-state |
| [Fix Damaged Apps](../../Plugins/FixDamagedApp) | `fix-damaged-app` | portable | — |
| [Hide Notch](../../Plugins/HideNotch) | `hide-notch` | partial | device-state |
| [Homebrew Manager](../../Plugins/Homebrew) | `homebrew` | none | — |
| [IP Check](../../Plugins/IPOverview) | `ip-overview` | partial | history, local-policy |
| [Custom Shortcuts: Keyboard, Trackpad, Mouse](../../Plugins/InputRemapping) | `input-remapping` | partial | external-authorization |
| [Keep Awake](../../Plugins/KeepAwake) | `keep-awake` | partial | local-activation |
| [Key Stats](../../Plugins/KeyStats) | `key-stats` | localOnly | local-activation, history |
| [Launch Items](../../Plugins/LaunchControl) | `launch-control` | partial | private-content, local-activation, local-policy |
| [Launchpad](../../Plugins/Launchpad) | `launchpad` | partial | application-paths |
| [Lock Screen](../../Plugins/LockScreen) | `lock-screen` | none | — |
| [Mac Settings](../../Plugins/MacSettings) | `mac-settings` | partial | device-state |
| [Hide Menu Bar Icons](../../Plugins/MenuBarHidden) | `menu-bar-hidden` | partial | device-state |
| [Microphone Mute](../../Plugins/MicrophoneMute) | `microphone-mute` | none | — |
| [Middle Click](../../Plugins/MiddleClick) | `middle-click` | portable | — |
| [Mouse Enhancer](../../Plugins/MouseEnhancer) | `mouse-enhancer` | partial | device-state |
| [Night Shift](../../Plugins/NightShift) | `night-shift` | none | — |
| [Dynamic Island Hover Panel](../../Plugins/NotchHoverPanel) | `notch-hover-panel` | none | — |
| [Clean Mode](../../Plugins/PhysicalCleanMode) | `physical-clean-mode` | none | — |
| [Power Status](../../Plugins/PowerStatus) | `power-status` | none | — |
| [Quit Apps](../../Plugins/QuitApps) | `quit-apps` | none | — |
| [Right Click](../../Plugins/RightClick) | `right-click` | partial | application-paths, local-activation |
| [Saved Scripts](../../Plugins/SavedScripts) | `saved-scripts` | partial | private-content, external-authorization |
| [Screenshot](../../Plugins/Screenshot) | `screenshot` | partial | private-content, device-state |
| [Sidecar](../../Plugins/Sidecar) | `sidecar` | partial | device-state |
| [Siri](../../Plugins/Siri) | `siri` | none | — |
| [Stage Manager](../../Plugins/StageManager) | `stage-manager` | none | — |
| [Storage Explorer](../../Plugins/StorageExplorer) | `com.mactools.plugin.storage-explorer` | none | — |
| [System Data](../../Plugins/SystemData) | `system-data` | partial | history |
| [System Mute](../../Plugins/SystemMute) | `system-mute` | none | — |
| [Power Actions](../../Plugins/SystemPower) | `system-power` | none | — |
| [System Soft Restart](../../Plugins/SystemSoftRestart) | `system-soft-restart` | portable | — |
| [System Status](../../Plugins/SystemStatus) | `system-status` | portable | — |
| [Trackpad Gestures](../../Plugins/TrackpadGestures) | `trackpad-gestures` | partial | permissions |
| [Trackpad Scale](../../Plugins/TrackpadScale) | `trackpad-scale` | partial | device-state |
| [Translator](../../Plugins/Translator) | `translator` | partial | credentials, permissions, private-content |
| [Voice Assistant](../../Plugins/VoiceControl) | `voice-control` | partial | credentials, permissions, history, private-content |
| [Window Layouts](../../Plugins/WindowLayouts) | `window-layouts` | partial | external-authorization |
| [Window Switcher](../../Plugins/WindowSwitcher) | `window-switcher` | partial | device-state |
| [Xcode Cleanup](../../Plugins/XcodeClean) | `xcode-clean` | none | — |
| [zsh Config](../../Plugins/ZshConfig) | `zsh-config` | none | — |
