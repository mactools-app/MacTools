# Mouse Enhancer Smooth Scrolling Engine

Date: 2026-09-09

## Summary

Mouse Enhancer can already invert scroll direction (#400) and tune scroll step and speed (#406), but the wheel still moves content in discrete native jumps. This spec adds an opt-in smooth scrolling engine for mouse-classified scroll events: wheel ticks are intercepted, accumulated, and re-emitted as a continuous, interpolated pixel stream paced by the display refresh rate, modeled on Mos. Trackpad input is never re-emitted.

## Background

Issue [#400](https://github.com/ggbond268/MacTools/issues/400) asked for scroll feel tuning. PR [#406](https://github.com/ggbond268/MacTools/pull/406) added in-place step/gain adjustment, which fixes "too fast / too slow" but cannot fix jumpiness: a lifted 40 px step still lands as one discrete jump. The remaining feel gap versus Mos is the interpolation engine. Mos itself ties step and speed into its smoothing pipeline; without re-emission, amplified steps feel stepper, not smoother.

## Reference Research

[Mos](https://github.com/Caldis/Mos) (GPLv3, same license as MacTools) is the reference implementation. Its engine:

- Intercepts mouse wheel events in a CGEventTap and swallows them.
- Accumulates `step × speed` into a per-axis target buffer; same-direction ticks accumulate, an opposite tick resets the buffer.
- On a CVDisplayLink frame loop, emits `(target − current) × durationFraction` as `isContinuous` pixel deltas on a mutated clone of the original event.
- Posts with `CGEventPostToPid` to the event's original target process (Mos PR #523): avoids re-entry into the tap chain, keeps momentum from following the cursor, and avoids proxy crashes.
- Marks synthetic events via `eventSourceUserData` so its own tap ignores them.
- Guards stale frames with a generation counter and a 5 s TTL on the posting snapshot.
- Detects zombie CVDisplayLinks (5 s health check, >2 s silence → recreate, with cooldown) and self-corrects a link bound to a lower refresh-rate display (verify at 2/4/8 s, recreate when nominal < 70% of the max active display rate; issue #958).
- Sends a zero-delta terminal event to Chromium targets on stop so browser scroll does not stick.
- Bypasses smoothing for already-smoothed remote-control events and (pre-macOS 26) while Launchpad is active.

What we skip for MVP: per-application overrides, dash/toggle/block hotkeys, and trackpad phase simulation (`scrollPhase`/`momentumPhase` emulation). Phase simulation changes how browsers rubber-band and is the highest-risk compatibility surface; it can be a follow-up behind its own toggle.

## Product Model

New Mouse Enhancer settings (mouse section only; trackpads are natively smooth):

- **Smooth scrolling** toggle, default off. When on, mouse wheel scrolling animates instead of jumping.
- **Scroll duration** slider (fast–slow), controlling how long one tick's motion takes to finish. Reuses the existing step and gain values: each tick adds `step-adjusted, gain-applied` distance to the animation target.

Direction reversal and the remote-control bypass from #406 keep working: reversal is applied when the target is computed, and remote-smoothed events never enter the engine.

## Architecture

New `MouseScrollSmoother` inside the MouseEnhancer plugin, driven by the existing tap session:

1. **Capture** — the scroll tap runs at the annotated-session stage, where application routing information is available. Mouse-classified wheel events are swallowed (return `nil`) only after the engine copies the event, validates `eventTargetUnixProcessID`, and successfully starts its frame driver. Failure preserves the ordinary reversal/step/gain path.
2. **Accumulate** — apply reverse/step/gain to the tick, then add to the per-axis buffer; direction reversal resets the opposite axis and restarts the animation. Trackpad-classified, remote-smoothed, and synthetic (self-posted) events pass through untouched.
3. **Emit** — a CVDisplayLink frame loop uses elapsed-time exponential decay per axis. Rounded cumulative positions preserve fractional movement across frames; zero-motion frames are skipped. Pixel, line, and fixed-point fields follow native pixel-event conversion. A serial `userInteractive` queue posts via `CGEventPostToPid`, preserving queued movement through natural completion before a zero-delta terminal event.
4. **Recover** — the session's existing wake/secure-input recovery tears the engine down with the taps; the buffer resets so wake never resumes a stale glide. A watchdog also invalidates a driver silent for more than 0.5 seconds. Wheel events pass through during a 0.5-second retry interval; the next eligible tick recreates the driver. Frame processing and driver lifecycle changes share a serial queue, while the display callback only enqueues work there.

The accumulator, decay math, and buffer/reset semantics are pure value types, unit-testable without a display link. The display-link poster is a thin shell around them.

## Risks and Mitigations

- **Continuous-event compatibility** — some apps (games, CAD, remote clients) mishandle synthetic continuous events. The feature defaults off, applies only to mouse wheel events, and the remote-control bypass keeps remote sessions native. A per-app bypass list can follow if reports arrive.
- **Feedback loops** — self-posted events carry an `eventSourceUserData` marker and are ignored by the tap; posting goes directly to the target PID instead of the tap chain.
- **Stale queued frames** — generation invalidation cancels frames on reset, disable, driver failure, or an in-flight target transition, and templates expire after five seconds. A target transition starts a new accumulator so pending motion cannot transfer to another application.
- **Zombie/mis-locked display links** — a monotonic-clock watchdog restores ordinary scrolling and recreates stalled links. Refresh-rate rebinding remains deferred; elapsed-time decay accounts for different frame rates.
- **Latency perception** — frames emit once accumulated movement rounds to a whole pixel; fractional movement is retained for subsequent frames.

## Testing

- Unit tests: accumulator semantics (same-direction accumulation, reversal reset, drain), decay math bounds, template generation/TTL, bypass conditions.
- Session tests: engine starts/stops with configuration changes, resets on wake recovery, survives config updates mid-glide.
- Manual matrix: Chrome/Safari/Firefox terminal behavior, Xcode, Figma, terminals, games, mixed-Hz multi-display, sleep/wake, mid-glide direction reversal, remote-control sessions.

## Rollout

Single plugin release fragment (`release: plugin`, `type: added`), README and plugin docs update. Off by default; no migration. Upstream issue filed for design feedback before the implementation PR.
