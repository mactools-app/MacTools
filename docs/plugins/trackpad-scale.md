# Trackpad Scale (experimental)

Trackpad Scale is an optional plugin for estimating small object weights on a **built-in Force Touch trackpad**. It requires MacTools 2.0.2. Capability checks require the private runtime to report both built-in status and force support; model age is never used. Missing optional capability symbols fail closed. External Magic Trackpads are not supported or advertised.

## Try it

1. Run `make run` from a configured checkout to build and sync the Debug plugin catalog. In MacTools, install/enable **Trackpad Scale / 触控板称重** from the local development catalog if it is not already installed.
2. Open its settings page, or click **Open / 打开** on its panel row. Click **Start / 开始**.
3. Keep one finger lightly touching the trackpad with no object on it for about one second. The scale automatically tares once after each Start. Wait for the ready message and a numeric estimate before adding the object. For a manual reset, keep the MacTools settings window active and press **⌘T** with the object removed.
4. Gently place a small, smooth object while keeping the same finger in the same position with steady pressure. **Auto capture / 自动记录** is on by default: after a meaningful reading stays stable for about two seconds, sampling stops and **Captured / 已记录** appears. You can lift your finger and switch tasks or take a screenshot; the result stays visible until the next **Start again / 再次称重**. Turn Auto capture off for continuous measuring; the preference is remembered.
5. Expand **Calibration / 校准** to calibrate; auto capture pauses while this section is open. Its **Tare / 归零** button and **⌘T** reset the baseline with no object. Place an independently known small weight of **1–100 g**, wait for stability, enter its weight, and click **Save Calibration / 保存校准**. Calibration is empirical and does not guarantee accuracy.
6. If still measuring, click **Stop / 停止** when finished. Leaving or closing the settings page also stops live weighing. Captured results remain available in memory. Remove all fingers before trying gestures again.

If starting immediately reports an interrupted session, quit other running MacTools apps, including Nightly or another development build, then try Start again. Only one MacTools process can own the trackpad listener. An object alone does not provide the required finger contact: keep the same finger lightly touching throughout tare and measurement.

Use only small objects and gentle placement. Never use sharp or heavy items, or rely on this tool for critical measurements. A changing finger position or pressure can change the estimate substantially.

An accuracy warning stays beside the weight, including captured readings: estimates are for reference only and can be inaccurate even after calibration. Calibration uses the raw samples driving the displayed reading; coalesced pressure extrema are used only to check stability.

The contact indicator reports valid finger contact rather than the finger's physical position. Follow **Touch → Auto-tare → Weigh** before placing an object. After contact loss, remove the object and click **Restart / 重新开始** for a fresh automatic tare; **Stop / 停止** remains available to end the session.

## UI preview

The focused settings page shows the estimate, finger contact, and **Touch → Auto-tare → Weigh** steps, with calibration collapsed by default. These latest native screenshots show the persistent accuracy warning beside a real captured estimate and the gesture-pause notice below Start/Stop. The displayed ≈62 g reading demonstrates capture and retention on a built-in Force Touch trackpad; comparison against an independently known weight remains pending.

![Trackpad Scale captured estimate with the accuracy warning and Auto capture enabled](images/trackpad-scale-captured.png)

Calibration contains manual **Tare / 归零** with **⌘T** and the known-weight controls. The controls are disabled in this screenshot because the captured session has stopped.

![Trackpad Scale accuracy warning and expanded Calibration with Tare and Command-T](images/trackpad-scale-calibration.png)

## Measurement and recovery

The pressure-minus-tare baseline follows the empirical approach described by [TrackWeight's ScaleViewModel](https://github.com/KrishKrosh/TrackWeight/blob/main/TrackWeight/ScaleViewModel.swift). This plugin is independently implemented; no TrackWeight source was copied. Apple does not specify that the raw field is measured in grams or guarantee an accuracy. There is no `NSEvent.pressure` fallback and no synthetic-reading mode in the app.

The filter uses a modest time-based exponential average. Automatic tare captures the filtered baseline after about one second of valid single-finger samples, once per explicit Start. Manual tare becomes available after at least 0.45 seconds of samples. Neither requires the **Stable** badge: normal finger-pressure variation can exceed the provisional stability threshold. Hold the finger as still as possible when taring, since a changing baseline affects the estimate. Stability checks a short window of **unsmoothed** pressure so smoothing cannot conceal motion, and saving calibration still requires stability. The initial smoothing and stability thresholds are provisional until hardware comparisons establish whether they are useful. Whole-gram display is a presentation choice, not a claim of one-gram accuracy.

Auto capture requires an estimate of at least **2 g** and at least twice the pressure variation observed at tare, plus about two seconds of stable raw pressure across the entire capture interval. Initial zero and smaller changes do not trigger capture; excessive drift and coalesced pressure spikes reset the stable interval. These thresholds are provisional; disable Auto capture to inspect smaller estimates continuously. Finger-pressure changes can still resemble an object's weight. Changing the toggle, opening/closing Calibration, or taring restarts the capture interval. A completed capture releases the weighing subscription and clears the live baseline and sample window, retaining only the estimated weight and calibration status in memory. It does not save a reading or restart sampling when the finger lifts.

Tare is temporary. Finger loss, replacement, extra contacts, invalid samples, long gaps, device changes, sleep/lock, shutdown, and closing the page clear transient measurements. After the initial tare, returning contact does not trigger another automatic tare, since an object may still be on the trackpad. Remove the object and restart, or manually tare with **⌘T**. A stopped or interrupted session must be explicitly started again. Calibration factors are stored separately per stable native device ID in plugin-scoped storage; without a persistent device identity, calibration is session-only. Reset Calibration removes the current device's saved factor. Raw touch histories are neither logged nor saved; the bounded stability window exists only in memory.

The host owns one subscription-based MultitouchSupport driver and its existing process lease. Trackpad Gestures and Middle Click use this shared input. A notice beside Start/Stop explains that weighing pauses these plugins without altering saved preferences. They resume after capture, stopping, or closing the page, once all fingers lift. Activity and device interruptions also require a zero-contact boundary before a held touch can become a new gesture.

The host supplies shared input before dynamic plugin activation and migration readiness checks. Deactivated instances are excluded from host callbacks immediately, including while a batch update still holds the old plugin list.

MacTools 2.0.2 and later require Trackpad Gestures and Middle Click packages 2.0.2 or later. Older packages remain installed with their settings preserved, but cannot activate; **Plugins** shows update guidance. This also applies when Scale is not installed, preventing old native listeners from competing with shared input. Older catalog entries and manual packages cannot be installed on the new host. Display reconfiguration rebuilds the shared listener, and recovery after system sleep waits for the native driver's ten-second settling period.

This feature needs no new permission or entitlement: it reads the same private contact stream, without posting input events. Gesture plugins retain their own existing permissions. There are no signing or security-setting changes.

Interrupted Mouse Enhancer gesture migrations update Trackpad Gestures to a host-compatible package before activation. If that update is unavailable, the old source and migration state remain intact until a compatible package becomes available.

## Private API compatibility

The host dynamically loads `/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport`, preserving the existing `MTTouch` C layout and callback/unregister ownership. It copies contacts, including pressure, before the callback returns. `MTDeviceIsBuiltIn`, `MTDeviceSupportsForce`, and identity/service lookups are optional, checked symbols. Missing required listening symbols disable listening. macOS updates can change this undocumented interface or its pressure behavior.

The host invalidates callback generations on stop/restart, observes device arrival/removal with IOKit and debounce, interrupts on host activity transitions, and stops native listening after the last subscriber leaves. A stalled contact stream clears weighing rather than displaying an old weight. The existing process lease policy prevents a secondary development/test host from taking an installed app's listener.

## Verification in this checkout

| Check | Result |
| --- | --- |
| Focused XCTest: scale-model calibration, persistence, stale/coalesced frames, and locale-specific numeric input | Passed: four tests, zero failures |
| `make ci`: full XCTest, script checks, and frozen PluginKit v7 binary client | Passed: 2,727 XCTest tests passed, four skipped, zero failures; 229 script checks passed |
| `make script-tests` (includes changelog, generated plugin data, localization, and minimum-host inventory) | Passed: 229 checks |
| Frozen PluginKit v7 binary client against the built framework | Passed |
| Unsigned Debug host and plugin build using the repository Xcode wrapper | Passed |
| `make build` | Blocked by missing `LocalConfig.xcconfig`; no signing configuration was created or changed |
| Static native UI snapshots: English/Chinese, light/dark, German/Turkish narrow content, and Arabic right-to-left layout | Passed: no clipping in inspected layouts; no sensor readings supplied |
| Real sensor and accuracy validation | Untested: available Mac mini enumerated zero multitouch devices |

Focused model test command: `make test TEST_FILTER=TrackpadScaleModelTests`.

To run the broader feature tests:

```bash
make test TEST_FILTER='TrackpadScaleMeasurementTests TrackpadScaleModelTests SharedTrackpadInputServiceTests TrackpadGesturesPluginTests TrackpadGestureRecognizerTests TrackpadMiddleClickArbiterTests TrackpadMiddleClickCoordinatorTests MiddleClickPluginTests TrackpadTypingSuppressionGateTests'
```

The unsigned build used `scripts/xcodebuild-filtered.sh` with the existing Debug scheme and `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, and an empty `CODE_SIGN_IDENTITY` command-line override. No project signing or security settings were changed. No checks are marked as hardware passes from synthetic fixtures.

## Manual hardware checklist

Current hardware evidence: a read-only probe on the available Mac mini enumerated **zero multitouch devices**, so physical sensor and accuracy checks are **untested**. Static light/dark UI snapshots are checked separately; interactive desktop checks below remain untested. Automated tests use explicitly synthetic fixtures only. Record Mac model, macOS version, native device ID/capabilities, plugin version, known weights, estimates, and pass/fail observations locally; do not record raw touch histories.

| Check | Expected outcome | Status |
| --- | --- | --- |
| Capability and real sensor path | Built-in Force Touch identified; finite positive raw pressure changes with gentle force, before tuning/calibration | Untested |
| Unsupported/non-force device | Clear unsupported state; no estimate or gesture pause remains | Untested |
| Known-weight comparisons | Compare several independently measured small weights before and after calibration; repeat placements and record error/range without promising accuracy | Untested |
| Finger lift and replacement | Estimate disappears immediately; replacement requires a new tare | Untested |
| Extra contact | Multiple-contact state; no estimate; return to one finger requires tare | Untested |
| Repeated tare | Tare repeatedly with no object, then compare the same known weight | Untested |
| Close/reopen and repeated Start/Stop | Listener releases if unused; reopened page is stopped with no stale tare/weight | Untested |
| Sleep/wake, screen lock, device re-enumeration | Session interrupts, weight clears, gestures recover; weighing requires explicit restart/tare | Untested |
| Gestures enabled | Configured Trackpad Gestures actions and Middle Click pause during weighing, resume after stop/close and finger lift; saved preferences unchanged | Untested |
| Gestures disabled | Weighing still receives pressure; stopping releases the only listener | Untested |
| UI/accessibility | Check supported languages including Arabic right-to-left layout, light/dark, narrow settings window, keyboard/focus, VoiceOver, and disabled controls | Untested |

Mark a check **Passed** only after observing its expected outcome. Record **Failed** with reproduction details when it differs, and keep unavailable hardware/physical actions **Untested**.
