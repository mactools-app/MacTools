# Actions and Automation E2E Evidence

This opt-in local harness prepares deterministic, non-destructive examples for the Actions & Shortcuts, Automation, Run Link, and Action Grid features from issues #247, #249, #250, and #251. It uses the stable signed Debug app at `~/Applications/MacTools Dev.app` and never runs from Derived Data.

The harness is not part of the normal build, test, CI, release, or production launch flow.

## Safety model

`make e2e-prepare` first stops the stable Debug app gracefully and exports both its main preferences domain and Finder extension preferences domain into a timestamped directory under `build/E2EArtifacts/`. It then installs a temporary fixture and relaunches exactly one app instance.

The fixture preserves unrelated action shortcut assignments and creates:

- four shortcuts: Control-Command-3 for Open Settings, Control-Command-4 for Action Grid, Control-Command-5 for Dashboard, and Control-Command-6 for the safe workflow;
- seven workflows covering local success, externally safe Run Link execution, background execution, continue-on-error, stop-on-error, cancellation during delay, and a deliberately visible privacy-safe run;
- three application-activation rules that target two session-local helper apps instead of opening apps that can restore private user content;
- one Saved Script with a stable ID, local confirmation disabled, external Run Link confirmation required, portable backup enabled, captured output, and a long enough runtime to expose progress indicators;
- nine top-level Action Grid entries plus nested System, Automation, Resilience, and Utilities folders spanning host commands, plugin actions, workflows, and one deliberately unavailable action;
- two Trackpad Gestures examples that dispatch Action Grid and the safe workflow through the shared action catalog;
- English and the light appearance for deterministic starting evidence.

The background workflow reads the current system mute value and writes the same value back. Fixture workflows never contain Display Sleep, Lock Screen, Empty Trash, or another side-effecting confirmation action: workflow invocations are not external Run Links and therefore do not apply `confirmAlways`. Confirmation is tested separately at the Run Link boundary and must always be cancelled. Display brightness remains a functional action test, not screencast evidence, because screen capture and display processing can make the real brightness change invisible in the encoded video.

The harness compiles two tiny ad-hoc-signed helper apps and a private recorder inside the session directory. The helper windows contain only fixed test labels and never read files, account state, clipboard data, or another app. The backdrop helper provides a neutral surface on every connected display. The recorder resolves and allowlists the exact process ID for the stable MacTools instance and each session helper, not every process sharing their bundle identifiers. Pixels from ChatGPT, Finder, notifications, test hosts, stale helper instances, and all other applications are therefore excluded at capture time even if their windows remain open or overlap the capture rectangle.

`make e2e-restore E2E_SESSION=...` restores both preference domains exactly from the original session backup. Backups and evidence remain in the session after restoration.

## Before granting permissions

Run the permission-independent checks:

```bash
make e2e-self-test
make e2e-preflight
```

Preflight verifies the stable app path, deep signature, Apple Development authority, Team ID, installed Debug plugins, process count, recorder dependencies (including `ffmpeg` and `ffprobe`), and whether the process hosting the harness can post synthetic shortcuts. It checks for running copies in the configured build directory and the default test-host directory, because a second app with the development bundle identity can steal Run Links from the stable app. When the stable app owns the Trackpad Gestures listener lease, preflight reports permission state as `granted`: that listener starts only after the app observes both Accessibility and Input Monitoring access. Otherwise it reports `unverified`, never a guessed denial or a hard-coded pending state.

Evidence collection is bound to the exact local product assembled by the harness. Rebuild snapshots the source commit, dirty state, and deterministic tracked/untracked source-tree hash before building, verifies that source did not change during the build, then records the installed app executable and CodeDirectory hashes, the complete installed plugin-package tree hash, and the local catalog hash. Recording and collection revalidate every value. A changed checkout, rebuilt or re-signed app, replaced plugin package, edited catalog, or session that has not completed this source-bound rebuild is rejected rather than being attributed to the wrong code.

## Prepare or upgrade a session

Create a new session once:

```bash
make e2e-prepare
```

Save the absolute session directory printed on the last line:

```bash
E2E_SESSION=/absolute/path/from/prepare
make e2e-audit E2E_SESSION="$E2E_SESSION"
```

`fixture.audit.json` must report `"valid": true` before UI automation begins.

Before recording, rebuild the session so its installed app and plugin packages are bound to the current source snapshot:

```bash
./scripts/e2e/mactools-e2e.sh rebuild "$E2E_SESSION"
```

Any source edit after this command intentionally invalidates the session. Finish the change, rebuild again, and only then record or collect evidence.

If the session was prepared with an older fixture, upgrade it in place:

```bash
make e2e-upgrade E2E_SESSION="$E2E_SESSION"
```

Upgrade preserves the original preference backups and existing screenshots, installs the current fixture, clears fixture history, removes recordings from the older fixture generation, and resets every required checkpoint to `pending` so stale evidence cannot pass the current scenario manifest. Recording validation also rejects artifacts older than the session's current preparation timestamp.

Return to a prepared session without touching its backup or fixture:

```bash
make e2e-resume E2E_SESSION="$E2E_SESSION"
```

Reset only the fixture between mutation-heavy scenario packs:

```bash
make e2e-reseed E2E_SESSION="$E2E_SESSION"
```

Reseed clears fixture history and restores the deterministic fixture but does not change checkpoint results or replace the original backups.

## Scenario manifest

The machine-readable source of truth is `scripts/e2e/scenarios.json`. List all packs or inspect one pack with:

```bash
make e2e-scenarios
scripts/e2e/mactools-e2e.sh scenarios workflow-resilience
```

Every required checkpoint in the manifest must pass. The physical-trackpad pack is explicitly optional because neither Accessibility nor Computer Use can synthesize the private raw multitouch stream.

Computer Use must query fresh accessibility state after every transition. Do not retain numeric element indexes after the UI changes. Record a checkpoint immediately after its assertion succeeds:

```bash
scripts/e2e/mactools-e2e.sh checkpoint "$E2E_SESSION" marketplace-visible pass
```

## Pre-permission scenario packs

### Baseline cross-surface path

1. Open `mactools-dev://app/settings/plugins/marketplace`; assert the current local catalog contains every plugin ID declared by `Plugins/*/plugin.json` and installed local plugins are verified.
2. Open Actions & Shortcuts; assert its search field and all four fixture assignments are visible.
3. Open Automation; assert all seven workflows, their expected step counts, and all three rules are visible.
4. Run `E2E Safe Workflow`; assert its three steps and overall run succeed and the app remains responsive.
5. Run `E2E Run Link Workflow` through its Run Link; assert its idempotent System Mute step and overall run succeed with persisted source `publishedAction.runLink`, without changing the current mute state.
6. Open `mactools-dev://app/actions/action-grid/show`; assert nine accessible grid controls, then dismiss with Escape.
7. In Actions & Shortcuts, assert the Launchpad action is available. Do not open Launchpad in a recorded session because its contents reflect the user's installed applications.
8. Launch the primary session helper with `scripts/e2e/mactools-e2e.sh privacy-helper "$E2E_SESSION" primary`; assert `E2E Privacy Helper Activation` succeeds, `E2E Privacy Helper Condition Skip` records a condition skip, and fixture audit still reports `systemMuteStatePreserved: true`.
9. Close Settings, send Control-Command-3, and assert General Settings appears. Send Control-Command-4 and assert one Action Grid overlay appears.
10. Quit and relaunch the stable app; assert the four shortcuts, seven workflows, one Saved Script, three rules, nine top-level grid entries with their nested folders, two Trackpad action mappings, and recent history persist.

The shortcut driver refuses to request permission or post an event when access is absent. Its mappings can always be checked safely:

```bash
scripts/e2e/mactools-e2e.sh shortcut "$E2E_SESSION" open-settings --dry-run
scripts/e2e/mactools-e2e.sh shortcut "$E2E_SESSION" action-grid --dry-run
scripts/e2e/mactools-e2e.sh shortcut "$E2E_SESSION" dashboard --dry-run
scripts/e2e/mactools-e2e.sh shortcut "$E2E_SESSION" safe-workflow --dry-run
```

### Shortcut lifecycle

Reseed first. In Actions & Shortcuts, try assigning Control-Command-5 to Open Settings. Assert the existing Dashboard conflict is named, approve replacement, verify Dashboard becomes unassigned, clear the replacement, and verify both rows update. Assign or clear the same action from Command-K search and assert the central shortcuts page updates immediately. Reseed afterward.

### Workflow resilience

Reseed first, then run each fixture workflow separately:

- `E2E Continue After Missing Action`: assert succeeded, unavailable, succeeded step states and a failed overall result.
- `E2E Stop On Missing Action`: assert the missing step is unavailable and its following step is skipped.
- `E2E Cancellable Delay`: stop it during its ten-second delay and assert cancelled status.
While the delay workflow is running, close Settings and assert the MacTools menu-bar icon shows its running badge. Reopen Automation, assert the row still offers Stop, then inspect Recent Runs and copy its redacted diagnostics. The diagnostics may name action references and statuses but must not include action parameters.
After every run, assert the deliberately unavailable step remains editable and visible rather than being silently removed. Reseed afterward.

### Automation conditions

Reseed and verify all three enabled rules. Launch the primary privacy helper once and assert one successful run and one skipped condition result, with no duplicate success. Launch the secondary helper and assert its rule succeeds once. Audit the fixture again to prove the mute state was preserved. These helpers contain fixed test copy only; Calculator, TextEdit, Finder, and other state-restoring apps must not be used as recorded automation targets. Reseed afterward.

```bash
scripts/e2e/mactools-e2e.sh privacy-helper "$E2E_SESSION" primary
scripts/e2e/mactools-e2e.sh privacy-helper "$E2E_SESSION" secondary
```

### Privacy-safe visual automation

Reseed, select `E2E Visual Proof Workflow`, and begin recording the `visual-automation` pack. Run the workflow from Automation. Assert all of the following in one bounded clip:

1. Automation shows a running state for `Show Privacy-Safe Helper`.
2. The primary helper covers the recorded region with its fixed shield window for about three seconds.
3. MacTools returns directly to Automation without showing another user's files or app state, and the fixture waits for that navigation to settle before advancing.
4. The deterministic Action Grid appears for the second workflow step.
5. After dismissing the grid, Recent Runs reports success and includes both steps.

This is the visual proof workflow. Do not substitute display brightness: brightness can be verified through action tests and backend state, but it is not reliable visual evidence in a screencast.

### Saved Scripts cross-surface coverage

Reseed and open Saved Scripts. Assert the seeded `E2E Privacy-Safe Visual Proof` script has a stable action ID, a 15-second timeout, local confirmation disabled, Run Links enabled with mandatory external confirmation, and portable source backup enabled. Run it directly from the manager and from the menu-bar panel; assert the running indicator remains visible during its three-second delay and the captured output contains only the two deterministic status lines.

In Actions & Shortcuts, search for the script and assert it is a canonical action. In the root Action Grid editor, search for the script and assert it appears even though the fixture also assigns it inside the nested Automation folder. Run that grid entry and assert no local confirmation appears. Open its Run Link and cancel the mandatory external confirmation. Finally audit, reseed, and audit again; the action ID must remain `run.00000000-0000-4000-8000-000000000290`. Portable backup/restore coverage must preserve the same ID so scripts that call the URL do not break.

### Run Link security and lifecycle

Use `E2E Run Link Workflow` for successful direct-link and copy checks. Expand Run Link, copy both the URL and terminal command, and assert the temporary copied-state feedback appears. Then invoke the `E2E Safe Workflow` Run Link and assert the workflow records its host-only first step as unavailable, skips the remaining steps, and reports failure without navigating. This expected rejection proves that a Run Link cannot bypass an action's external-invocation policy. For the parameterized preset, read `systemMuteValue` from `fixture.audit.json`, find the System Mute catalog action that sets that same value, create and execute its preset, and assert the mute value remains unchanged. Delete the preset and verify its old link no longer runs. Never choose the opposite mute action for this test.

Search Actions & Shortcuts for Display Sleep, invoke its direct Run Link, and cancel the external confirmation. Never press the Sleep button. Exercise rejection with an unknown action and a percent-encoded path separator, for example:

```bash
open -a "$HOME/Applications/MacTools Dev.app" 'mactools-dev://app/actions/e2e-missing-provider/not-installed'
open -a "$HOME/Applications/MacTools Dev.app" 'mactools-dev://app/actions/mactools%2Fbad/app.open-settings'
```

Assert visible rejection or matching diagnostics and no side effect. Finally quit the app, submit a navigation link followed immediately by the distinct `E2E Run Link Workflow` and `E2E Background Workflow` links, and assert the cold-launch queue runs each idempotent action once and in submission order without changing the current mute state. Reseed afterward.

### Action Grid interactions

Reseed and verify the 3-by-3 nine-entry root layout. Open the System, Automation, and nested Resilience folders in the same overlay; assert the breadcrumb/back behavior and Escape return one level before dismissal. In settings, drag an entry to reorder it, add or replace an entry in place, rename a folder, clear an entry, and assert the overlay mirrors each change. Invoke the safe workflow entry and verify its history source. Invoke the unavailable entry and assert the grid stays open with an accessible error. Exercise arrow navigation, Return, numeric selection, Escape, outside-click dismissal, and rapid repeated invocation; assert focus is correct and at most one overlay exists. Reseed afterward.

### Localization and host commands

Start from the English fixture and capture the main feature pages. Switch to Simplified Chinese and assert host and plugin copy localize without truncation. Switch to Arabic and assert right-to-left layout and readable mixed identifiers; this is a layout assertion, not a translation-completeness waiver.

Use Command-K to change appearance and restore it, then hide and restore one plugin surface. Assert the settings controls and visible panels stay synchronized. Reseed to restore English/light and plugin visibility.

### Stability and migration

Open Dashboard repeatedly with Control-Command-5 while Bluetooth state refreshes; assert the UI remains responsive and exactly one stable app process exists. Repeat mixed Dashboard, Feature Panel, Settings, and Action Grid presentation enough times to expose duplicate-window or stale-state failures.

Run the isolated plugin-catalog and migration tests and only mark `plugin-migration-isolated-tests` after they pass. These prove that legacy built-in records do not hide, uninstall, or corrupt the dynamically packaged replacements.

### Trackpad automated coverage

Open Trackpad Gestures settings and assert all gesture editors, enablement state, validation, and permission guidance are accessible. Verify the fixture exposes a four-finger long touch mapped directly to Action Grid and a five-finger long touch mapped directly to the safe workflow. Run the Trackpad Gestures XCTest classes, which inject gesture events and cover recognition, persistence, assignment, migration, portable backup, validation, and shared action dispatch without physical input. Do not claim raw hardware verification from these tests.

Run all three code-verification groups immediately after prepare or upgrade, before collecting UI evidence, and record their checkpoints automatically with:

```bash
make e2e-verify-code E2E_SESSION="$E2E_SESSION"
```

The migration, action-registry, and trackpad logs are retained in the session. The registry group covers the registry/executor/Run Link core plus all 41 current native action providers, and passes `action-registry-health` only when every suite succeeds. Runtime synchronization also logs a redacted issue-category summary if a provider definition or catalog entry is rejected; it never logs action parameters. The command temporarily stops the stable app so its XCTest host cannot compete for preferences or URLs. XCTest can leave its Derived Data host running and register that bundle as a `mactools-dev://` handler, so cleanup stops and unregisters only that exact test host, force-registers the stable installed app, and reopens the stable Marketplace. A command-only preview is available with `scripts/e2e/mactools-e2e.sh verify-code "$E2E_SESSION" --dry-run`.

## Post-permission stable rebuild

After granting the requested macOS permissions to `~/Applications/MacTools Dev.app`, rebuild and replace that exact stable bundle without changing its path, bundle identifier, Team ID, or designated requirement:

```bash
make e2e-rebuild E2E_SESSION="$E2E_SESSION"
make e2e-resume E2E_SESSION="$E2E_SESSION"
```

`e2e-rebuild` builds the host and local plugins, verifies the staged identity, keeps the previous app inside the session as a recoverable backup, replaces the stable bundle, compares before/after designated requirements, and relaunches it. It does not reseed or restore preferences. It uses the same `DERIVED_DATA` setting as `make build`. Inside the checkout, use dedicated build directories free of source files. The session remembers each directory it builds in so source verification can skip generated files when you switch directories. Preview it without mutation with:

```bash
scripts/e2e/mactools-e2e.sh rebuild "$E2E_SESSION" --dry-run
```

Repeat shortcut invocation, relaunch persistence, and the relevant permission-backed behavior. Assert the permissions remain granted and no new macOS prompt appears before marking `rebuild-permission-persistence`.

## Physical trackpad check

The optional final pack follows `Plugins/TrackpadGestures/MANUAL_TESTING.md` on a physical trackpad. Capture the configured gesture firing once, an intentionally non-matching gesture doing nothing, and the permission-denied guidance if applicable. This check supplements the injected XCTest coverage; it is not required for the automated report to pass.

## Per-pack screencasts

Dry-run without requesting Screen Recording access:

```bash
scripts/e2e/mactools-e2e.sh record-pack "$E2E_SESSION" workflow-resilience 90 --dry-run
```

After Screen Recording is granted to the recorder's host process, record bounded, reviewable clips. Each pack opens its story-specific start page before capture and publishes a readiness marker, so setup time is not part of the video. Once the visible story assertion passes, stop immediately instead of padding the clip to its maximum duration:

```bash
make e2e-record-pack E2E_SESSION="$E2E_SESSION" E2E_PACK=baseline E2E_DURATION=90
make e2e-record-pack E2E_SESSION="$E2E_SESSION" E2E_PACK=workflow-resilience E2E_DURATION=90
make e2e-record-pack E2E_SESSION="$E2E_SESSION" E2E_PACK=visual-automation E2E_DURATION=45
make e2e-record-pack E2E_SESSION="$E2E_SESSION" E2E_PACK=saved-scripts E2E_DURATION=60
```

Collection accepts a recording only when both encoded files are non-empty, their SHA-256 manifest matches, and `ffprobe` finds a parseable video stream with positive dimensions and duration. Arbitrary files cannot satisfy a recording checkpoint merely by carrying matching hashes.

In a second terminal, synchronize the UI driver with the recorder and stop on the passed assertion:

```bash
scripts/e2e/mactools-e2e.sh wait-recording-ready "$E2E_SESSION" saved-scripts
scripts/e2e/mactools-e2e.sh start-recording "$E2E_SESSION" saved-scripts
# Perform and assert the visible user story here. Frames begin at its first action.
scripts/e2e/mactools-e2e.sh stop-recording "$E2E_SESSION" saved-scripts
```

The privacy-safe visual workflow is the preferred dramatic proof. Treat brightness, audio, Night Shift, and similar system-state changes as functional assertions backed by state or history, not as visual evidence: display capture and video compression can hide or alter their apparent effect. Never open Launchpad, Finder, recent documents, or another user application during a recorded pack. The session-local helpers are the only approved external-app targets for screencasts. The recorder restarts MacTools to clear transient menu-bar panels, uses a dedicated backdrop helper process, prelaunches the separate primary and secondary workflow helpers hidden and without activation, and routes MacTools to the data-free Automation page before capture so proof actions can activate either helper without reusing the process that owns privacy isolation or firing automation rules before the story begins.

Each recorded pack writes `screencast.<pack>.mov`, `screencast.<pack>.mp4`, and `screencast.<pack>.sha256`, then automatically marks `screencast-captured` as passed. A complete report additionally requires all three non-empty artifacts for the four required story packs: `baseline`, `workflow-resilience`, `visual-automation`, and `saved-scripts`; one clip can no longer satisfy the entire evidence set. Before capture, the harness removes recordings from an older fixture generation, rebuilds and starts the session-local privacy backdrop, opens the pack's `recordingStartRoute`, reactivates MacTools, and resolves the largest visible standard MacTools window. The recorder publishes readiness but discards frames until `start-recording` marks the first story action; it stops on the assertion marker or the maximum duration, whichever comes first. ScreenCaptureKit captures that fixed rectangle using only the exact MacTools and helper process layers. It includes the pointer and, on macOS 15 or later, click indicators, but no microphone or system audio. Recorded UI automation uses `pointer-click` with the current Computer Use screenshot dimensions and coordinates so the existing accessibility-authorized E2E driver emits a real cursor move/down/up sequence; an Accessibility `AXPress` does not emit the pointer event needed for ScreenCaptureKit's click ring. Use `input-select-all` and `input-text` for deterministic text entry inside a rehearsed story, then perform one final accessibility assertion after the visible sequence; this keeps automation-inspection latency out of the clip without weakening acceptance checks. The recorder fails closed when an allowed process is absent, duplicated, or replaced, the story never starts, the window cannot be resolved, or the rectangle crosses display boundaries; it never falls back to a display-wide recording. If MacTools is hidden or moved, the captured area contains the deterministic helper backdrop rather than another application. Keep the MacTools window stationary so the desired UI remains inside the crop.

Do not close unrelated apps as recording preparation: that can discard unsaved work. For visual quality, the helper temporarily hides unrelated regular apps and observes newly launched or activated apps during capture; it restores exactly those apps when the helper terminates, including after SIGINT or SIGTERM. This is reversible defense in depth, not the privacy boundary—the ScreenCaptureKit exact-process allowlist remains responsible for excluding their pixels. Still disable sensitive notification previews when practical and inspect the generated clip before sharing; this protects against future recorder regressions and against private text intentionally shown inside MacTools itself. Recorder permission is separate from MacTools permission and may be attributed to Codex or the terminal host.

## Evidence and restoration

Build the machine-readable report and diagnostic bundle:

```bash
make e2e-collect E2E_SESSION="$E2E_SESSION"
```

The bundle contains `report.json`, the scenario-manifest version and per-pack coverage, fixture state, signature and designated-requirement evidence, current-session allowlisted action-registry and trackpad logs, PID-only process evidence, checkpoint results, and hashes for every screenshot, code-verification log, and screencast. `report.json` passes only when preflight and fixture validation pass and the checkpoint set exactly matches the current required manifest with every checkpoint marked `pass`. The optional physical-trackpad checkpoint is reported separately.

Always restore the user's preferences after the run, including after a failed or interrupted test:

```bash
make e2e-restore E2E_SESSION="$E2E_SESSION"
```

The harness never deletes the session directory or its original preference backups.
