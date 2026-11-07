# Quit Protection

Design draft, 2026-11-07. [MacTools issue #527](https://github.com/mactools-app/MacTools/issues/527)

Quit Protection is a separately installable, opt-in plugin for preventing accidental quits with ⌘Q. It supports two confirmation modes and three app scopes.

## Settings and quick pause

Use the same protection switch in the panel and settings. Group the confirmation mode, its timing control, and the feedback toggle under **Quit App (⌘Q)**. Show the app list beside the scope when the scope uses one. [Plugin design guidelines](../../plugins/development-guidelines.md#visual-and-interaction-design)

| App scope | Effect on this shortcut |
| --- | --- |
| All Apps | Protect every app where the shortcut and confirmation mode can be handled safely. |
| Selected Apps | Protect the apps in this rule's list. An empty list protects nothing. |
| All Apps Except | Protect eligible apps outside this rule's exclusion list. An empty list is equivalent to All Apps. |

Use an app picker for both lists. Keep the selected and excluded lists separate so switching scopes preserves each list's meaning. Show the effect of an empty list next to the picker. App scopes apply only to eligible local input. Selecting an app explicitly does not override compatibility checks.

Defaults are protection off, Selected Apps with empty lists, and Hold to Confirm. **Show Confirmation Feedback** defaults to on. A compact indicator shows the target app icon and the next action on the app's display. For Hold, the progress bar fills and the instruction changes to **Release Q to quit** in the same panel. Double Press shows the next shortcut until its confirmation window expires.

The panel and settings distinguish paused, enabled, and unavailable protection. The rule shows when it has no selected apps. When an enabled rule can protect apps and needs permission, name each verified permission, explain that it is used to intercept and deliver the shortcut, and show where to grant it.

## Confirmation modes

| Mode | Gesture and result |
| --- | --- |
| Hold to Confirm | Hold the base shortcut for 0.8 seconds by default, adjustable from 0.5 to 2 seconds. Release the letter key while still holding Command to confirm after the threshold. An early release cancels. The release must still be routed to the original app. |
| Double Press | Press the base shortcut, release the letter key, and press it again within 0.6 seconds of the first release by default. The interval is adjustable. Command may stay held between presses. Auto-repeat does not count. After expiry, the next press starts a new attempt. |

Extra Modifier remains in the prototype while shortcut conflicts are investigated. For example, ⇧⌘Q logs out and ⌃⌘Q locks the screen. [Apple keyboard shortcuts](https://support.apple.com/en-us/102650)

Escape, target changes, pausing, and edits to the active rule cancel a pending confirmation. In Double Press, an intervening unrelated keystroke or pointer press also cancels the attempt and continues to its normal handler.

## Preserve the native destination

- **⌘Q** confirms against the same running app instance. A confirmed quit lets the app present its usual save prompt or decline to quit.
- With Chrome's standard Quit shortcut available, invoke its Quit menu action after MacTools confirms. Chrome's own warning applies to keyboard quits, so replaying the shortcut could start another confirmation. Reassigned shortcuts fall back to normal keyboard delivery.
- Menu actions, shortcuts outside the rule's scope, and unrelated modified chords keep their normal behavior. Preserve ⌘Tab Q on the highlighted app. In custom switchers, remote desktops, and virtual machines, leave input to its normal handler when it may be directed elsewhere. Settings should explain that these shortcuts may take effect immediately. [Vorssaint switcher report](https://github.com/vorssaint/vorssaint-utils/issues/3349)

## Prototype and release gates

1. **Establish routing before interception.** Compare public session and annotated-session event taps for identifying the effective input destination. Verify that ordinary local app input can be distinguished from switcher or forwarded input before claiming a gesture. [Input Remapping event tap](../../../Plugins/InputRemapping/Sources/InputRemappingEventTap.swift), [Mouse Enhancer event targeting](../../../Plugins/MouseEnhancer/Sources/MouseScrollSmoother.swift)
2. **Verify the action and target at confirmation.** Store app lists by bundle identifier. Bind each gesture to a running process instance and an activation generation. Recheck routing, target identity, policy, and tap availability before delivery. For a hold, also verify that the required keys are still down. Probe delivery of one marked base-shortcut key pair to the original process. Preserve normal save prompts and check for recursion or interactions with Input Remapping. [Core Graphics process-targeted events](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)), [MacTools keyboard event helpers](../../../Sources/MacToolsPluginKit/KeyboardKeyTap.swift)
3. **Consume only the claimed gesture.** Track the first press, any pending confirmation, and the releases the tap still owns. Use monotonic deadlines independent of key repeat. Consume Escape and its paired release only when it cancels a pending gesture. A stale deadline or late second press cannot complete the previous gesture. Cancel on app exit, permission loss, tap interruption, secure input, session lock, and sleep. On recovery, require a fresh non-repeat press. Verify the minimum permissions on supported macOS versions.

Start with a disposable test app and the ⌘Q hold path to verify routing and delivery. Exercise Double Press and the app scopes on the same path. Where a context is ambiguous at the first press, pass it through. Where certainty is lost after interception, cancel and discard the pending action.

### Local prototype

- Run the app scope and confirmation gesture checks with `bash scripts/testing/quit-protection/run.sh test`.
- Run the fixture's AppKit Quit menu check with `bash scripts/testing/quit-protection/run.sh native-menu` in a desktop session. The fixture cancels its own termination in the app delegate.
- Build the interactive fixture with `bash scripts/testing/quit-protection/run.sh build` and run the printed executable. It uses Hold by default and accepts `--double-press` or `--extra-modifier`. The extra modifier is Option for this fixture. A confirmed gesture invokes the fixture's own Quit menu item. Close the fixture window to exit.
- Build two separately named disposable apps with `bash scripts/testing/quit-protection/run.sh build-routing-pair`. Run each bundle's `Contents/MacOS/QuitProtectionFixture` executable directly with `--observe-routing`, starting B before A. The fixture reports destination PIDs for fresh ⌘Q events while it is frontmost on a U.S. keyboard layout. Tap ordinary ⌘Q in A, then hold Command and use Tab to highlight B before tapping Q. Both apps cancel their own termination and log which one received Quit. Check event access with `bash scripts/testing/quit-protection/run.sh preflight`.

### Routing evidence on macOS 27.3

The user confirmed the disposable ⌘Q keyboard check manually.

Both listen-only taps started when the fixture executable ran directly from the desktop test session. The LaunchServices launch of the same fixture reported that listen access was unavailable. A desktop-automation ⌘Q sent to A appeared at the annotated-session tap with A's PID and reached A's native Quit action. The session tap did not log that synthetic press. This establishes the app-targeted baseline for that input path. Physical input and switcher routing need their own comparison before the plugin can claim a global shortcut.

## Acceptance scenarios

| Scenario | Expected result |
| --- | --- |
| Install, change scope, edit lists, and pause or resume | Install leaves ⌘Q native until enabled. All Apps, Selected Apps, and All Apps Except control which apps are protected. Scope changes preserve both lists. The panel switch pauses protection. |
| Early release, completed hold, slow or fast double press, and auto-repeat | One native action occurs only for a valid hold or two distinct presses within the interval. A stale timer or repeat cannot trigger another action. |
| Switch apps during a pending confirmation, including away and back | The pending quit is cancelled. |
| Quit an app with unsaved test documents | The native prompt appears. Cancelling the prompt keeps the app open. |
| Use native ⌘Tab Q, MacTools Window Switcher, a third-party switcher, and a remote desktop or VM | Behavior matches the paused baseline, including when protection starts while a switcher is already active. |
| Revoke permission, interrupt the tap, enter secure input, lock, or sleep during a gesture | No deferred action is sent. Recovery requires a fresh press. |

Use a controllable clock for gesture and cancellation tests. Use disposable apps and documents for routing, save prompts, and focus races. Test non-US keyboard layouts, shortcut conflicts, feedback accessibility, and coexistence with Input Remapping on macOS 14 and a current supported macOS version.
