# Canonical action provider coverage

`PluginActionProviding` is the default integration point for a reusable plugin operation. A canonical action can appear in Actions & Shortcuts, Unified Search, Trackpad Gestures, Action Grid, and Automation. It may also support Run Links when its parameters and safety model are suitable for external invocation.

Plugins that publish or consume this action surface require MacTools 1.2.0 or later because the shared action contracts are part of that host ABI. Keep `plugin.json.minHostVersion` at or above the first host version that exports every PluginKit type used by the plugin.

This inventory records the current migration boundary. It prevents a plugin from accidentally growing a second, surface-specific execution path and makes intentional exclusions visible during review.

## Migrated providers

The following plugin source directories publish canonical actions:

- Core action surfaces: `ActionGrid`, `SavedScripts`, `Siri`.
- App and input control: `AppHotkey`, `AppVolume`, `AutoInput`, `MiddleClick`, `WindowSwitcher`.
- Display and workspace control: `Appearance`, `DisplayBrightness`, `DisplayResolution`, `DisplaySleep`, `DisplayTrueColor`, `DisplayVolume`, `DockLock`, `HideNotch`, `NightShift`, `Sidecar`, `StageManager`.
- Menu bar and Dock control: `AutoHideDock`, `AutoHideMenuBar`, `MenuBarHidden`.
- System and device control: `BatteryChargeLimit`, `FanControl`, `KeepAwake`, `LockScreen`, `MicrophoneMute`, `SystemMute`, `SystemPower`, `SystemSoftRestart`.
- Productivity and maintenance: `ActivityBar`, `AIAssistant`, `AppleShortcuts`, `ClipboardClear`, `ClipboardHistory`, `CloudflareR2`, `DiskClean`, `EjectDisk`, `EmptyTrash`, `FixDamagedApp`, `Homebrew`, `IPOverview`, `LaunchControl`, `Launchpad`, `PhysicalCleanMode`, `QuitApps`, `Screenshot`, `Translator`, `WindowLayouts`, `XcodeClean`.

Parameterized actions publish concrete catalog entries rather than asking each action surface to construct parameters. For example, Sidecar publishes per-device entries, Display Resolution publishes current display modes, App Volume publishes current audio apps, Battery Charge Limit publishes useful limit presets, and Fan Control publishes saved presets. Availability is resolved again at execution time so stale hardware, processes, or configuration fail safely.

Display Brightness registers the exact built-in brightness action for Automation. The workflow picker supplies its percentage, and the action stays out of the shared catalog.

Clipboard publishes its nine parameter-free actions in the source manifest and runtime
consistency test. Product metadata describes local encrypted storage without embedding clipboard
content, and remains independent of the manifest's private-data uninstall policy.

Operations that eject storage, empty Trash, clear the clipboard, change hardware management, or enter a physical clean session preserve confirmation or foreground-only requirements. Machine-local parameters are marked local-only, and actions that require an interactive chooser or key lifecycle do not expose Run Links.

Unattended automation is also an explicit provider decision. An action must publish both `.background` and `.automatic` before an automatic rule may run it; confirmation-required actions remain interactive even if they otherwise support background execution. Providers should keep the default overlap policy unless concurrent execution is known to be safe, return an execution handle promptly from `beginAction`, and perform expensive work asynchronously behind that handle.

The maintenance providers use deliberately narrow contracts:

- Disk Clean and Xcode Clean expose only a foreground **scan and review** action. It opens the owning settings page and starts a scan; deletion still requires the plugin's existing selection, safety validation, and confirmation flow.
- Cloudflare R2 exposes only its foreground file-picker upload action. It requires saved configuration, preserves interactive file selection and cancellation, and does not allow Run Links or unattended automation.
- Homebrew exposes update, upgrade-all, doctor, and cleanup. Upgrade-all and cleanup retain confirmation, every command reports its real completion result, and none can be invoked through a Run Link.
- Launch Items exposes start, stop, and restart only for user-owned items that the user has marked as favorites. Item IDs are local-only, stop/restart require confirmation, and stale or no-longer-favorite targets become unavailable.
- IP Check exposes refreshed copy actions for local and public IPv4 addresses. Keep Awake exposes useful timed sessions, Activity Stats exposes its existing reset flow with confirmation, Display Brightness exposes guarded built-in-display disable/restore operations, and App Volume includes a 50% preset.
- Apple Shortcuts publishes every discovered shortcut. Folder membership is shown as context in MacTools, local confirmation defaults on, Run Links always confirm, and safety-policy changes rebuild the host action registry synchronously.
- Clipboard publishes only its nine payload-free history and queue-control operations as canonical actions. Private Copy, Ignore Next Copy, Plain Text Paste, and Sequential Paste remain specialized global shortcuts so focus-dependent input synthesis and one-shot privacy suppression never enter unattended or externally invoked action surfaces.

## Intentionally specialized or non-operational

These plugins should not publish a canonical action merely to appear in action pickers:

- `AIUsage` presents subscription quota snapshots. Credential authorization and refresh controls remain in its settings and Dashboard component; it does not expose account access through automation or Run Links.
- `DuoStatus` displays battery, network, and volume snapshots in one standalone or host-primary menu-bar icon. Its settings request exclusive placement through the host and otherwise expose only appearance options; it has no repeatable system mutation to publish as an action.
- `Calendar`, `DeviceBattery`, and `SystemStatus` primarily present information without a stable repeatable mutation. Calendar's selected-date context belongs in its view, while app launching is already covered by App Hotkeys.
- `MacSettings`, `MouseEnhancer`, and `ZshConfig` are configuration editors. Mac Settings consumes existing canonical providers for settings that already have one, while runnable shell tasks belong in Saved Scripts.
- `InputRemapping` is an input-lifecycle and configuration surface rather than one stable repeatable operation. If it adopts canonical MacTools actions as mapping outputs, it remains an action consumer rather than publishing a parallel provider surface.
- `DockClickMinimize` observes native Dock clicks and hides the active app only after macOS processes the click. Its enable switch and event-monitor lifecycle are configuration, not a user-invoked canonical action.
- `RightClick` extends Finder context menus rather than representing one repeatable operation.
- `StorageExplorer` is a visual disk-usage analysis workspace with interactive folder navigation and reviewed Trash confirmation. File analysis and removal are foreground-interactive and not exposed as unattended canonical actions.
- `TrackpadGestures` is an input surface that consumes canonical actions; it is not itself an action provider.

Specialized shortcuts may remain when their input lifecycle cannot be represented by one invocation. Window Switcher keeps its press, release, and repeat shortcut behavior in addition to a canonical action that opens the interactive chooser. Physical Clean Mode keeps its emergency exit binding separate from the canonical enter action.

Middle Click publishes one stateful enable/disable action. It deliberately does not publish a “click now” command or expose finger-count parameters: those are input configuration, not repeatable operations. Trackpad Gestures remains the advanced mapper. When both plugins target the same finger-tap gesture, the shared gesture-claim contract pauses Middle Click and explains the conflict rather than allowing both listeners to fire.

This inventory covers every current plugin directory. New plugins should either implement `PluginActionProviding` for stable repeatable operations or add an explicit rationale here. Prefer stable readable action IDs, concrete catalog entries, live availability checks, bounded execution, and the narrowest external invocation policy that preserves the plugin's existing safety boundary.
