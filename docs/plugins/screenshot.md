# Screenshot

Screenshot brings the local Snap capture and editing implementation into one native MacTools plugin. Install the package through the plugin flow, then open **Screenshot** from its feature panel, unified search, or an optional shortcut. It has no separate menu-bar app, background capture service, or third-party runtime dependency.

Adapted from the [Snap screenshot implementation](https://github.com/idev19/Snap) and integrated with MacToolsPluginKit.

## Capture and edit

- **Capture Screenshot** opens a visible selection interface across connected displays. Only the display under the pointer previews a target window and shows the mode bar, including when moving between displays; stale hover highlights are cleared immediately. Other displays remain evenly dimmed unless they contain a selection; moving the pointer does not discard that selection. Window targeting includes visible menu bar popovers, menus, floating panels, and standard app windows while excluding system overlays; translucent menu materials keep their captured appearance in preview and export. Drag to select a region or click a highlighted target. Add rectangles, ellipses, lines, arrows, freehand marks, text, numbered tags, mosaic, or spotlight regions before copying, saving, or pinning the image.
- **Spotlight** in the screenshot annotation toolbar keeps a dragged rounded rectangle clear and dims the surrounding selection. Choose the tool again to highlight another detail; overlapping regions stay clear without darkening the background again. Copy, save, and pin include the same effect, and QR masks remain opaque.
- **Edit annotations** without a separate selection tool. Rectangles, ellipses, and spotlight regions are selected after drawing: drag inside to move, drag an edge or corner handle to resize, or use arrow keys to nudge. Click an existing shape to select it again; overlapping shapes select the topmost one. Choose a drawing tool to add another shape, or choose the active tool again to return to editing. Command-Z undoes each completed edit or annotation, and selection handles are excluded from exports.
- **Fill** appears in the style row for rectangles and ellipses. Turn it on before drawing, or select an existing shape to fill it, change its color, or return it to an outline; the change can be undone. Fills are always opaque and draw above mosaic and spotlight effects.
- **Mosaic and fill redaction** expand their edges to whole device pixels so no partially blended source pixels remain at a fractional boundary. Mosaic uses coarse 14-point blocks, area-averaged, quantized, and offset by per-capture random jitter, and is always opaque. This resists matching pixelated text against rendered candidates, but an opaque fill remains the safer choice for passwords and identifiers. The earlier blur tool has been removed.
- **Capture visibility** uses a clear dimmed backdrop, the system accent color for window and selection outlines, and balanced hover spacing. Start-confirmation bars and active scrolling/recording controls share the same glass capsule, regular-size native buttons, and padding.
- **Mode bar** uses slightly larger controls, sits 4 points below the screen's top edge, and moves horizontally using its left-hand grip. Movement stays within screen edges and avoids the camera housing; each display retains its dragged position during the current capture.
- **Magnifier** shows the pointer coordinates and current RGB or HEX color in separate left-aligned rows. Press Tab to switch formats; Command-C copies the displayed value and closes capture.
- **Quick Capture** uses the same selection interface and immediately copies the selected image after selection.
- **Text and QR recognition** processes the frozen selection locally. Recognized content can be edited and copied. Closing the panel, changing the selection or mode, or ending capture prevents an earlier recognition request from publishing its result. When text recognition is chosen from the mode bar, closing its panel ends the capture; recognition started from the screenshot toolbar returns to annotation. Annotation tools stay hidden in text-recognition mode. Recognized text keeps its layout: indentation, table columns, and paragraph gaps are rebuilt from fragment geometry, and side-by-side panels with misaligned rows are read one column at a time. The QR **Mask** action uses an opaque black fill in preview and export.
- **Recognition actions** use the same native capsule button style and sizing as scrolling and recording confirmation actions. The footer can show Close, Mask, Open Link, and Done according to the recognized content.
- **Pinned images** stay in a movable window for reference. Hovering shows Copy, Save As, and Close controls; small images show them beside the image without enlarging it. Use Command-C to copy, Command-S to save, and Escape or a double-click to close. A pinned scrolling screenshot closes after it is copied or saved; a deliberately pinned image stays open.
- **Scrolling screenshots** continuously capture the selected region while you scroll it downward yourself. Select the scrolling content rather than fixed headers or footers. Finish to copy and pin the assembled image, or cancel to discard it. Ambiguous or unmatched content is not appended; the controls explain how to recover. Besides a strict absolute match, a frame also matches when its best offset is clearly better than a typical unrelated alignment, so normal capture noise does not stall stitching; the stationary-footer check scales with that matched noise level. Matching and composition run on a serial background worker, with only the newest pending frame retained. Output is limited to 128 MiB of RGBA pixels and 32,768 rows, with an additional working-pixel budget that can lower this limit for large viewports. Reaching a limit stops capture with guidance to use smaller sections.
- **Region recording** is available on macOS 15 or later. Choose the recording mode and a region, then start and stop using the visible controls. It saves a MOV file without microphone or system audio, checking hardware codec support before starting the native recording output. A click-through accent-colored outline marks the selected region while capture is active and is excluded from the video. It stays within the target display at screen edges and hides when native capture stops, even while the file is still finalizing. The timer starts when recording actually starts. Completion requires both native capture termination and recording-file finalization; slow finalization keeps showing progress instead of reporting a false failure. Unsupported hardware encoding dimensions produce guidance to select a smaller region.
- **Recording auto zoom** is on by default and controlled by the record bar's **Auto Zoom** checkbox or the plugin's Recording settings; both share one preference. Recording still captures the original region. While capture runs, AppKit mouse monitors record pointer position, clicks, and scrolling inside the region; keyboard input is never observed, and no Accessibility permission is requested. After capture stops, the plugin renders a second movie at 60 fps that zooms to 1.6× around clicks and scrolling, follows the cursor with a dead zone, and returns to the full view after two seconds of inactivity or when the active window or app changes. Output dimensions and aspect ratio are unchanged.
- **Auto-zoom processing** shows progress in the recording panel. **Keep Original** cancels processing; cancellation or a failure keeps the original movie, named with an Original suffix, and reports its name. A clip without a click or scroll moves the original into place without re-encoding. The finished movie is published before the original is removed. Screenshots, recognition, and scrolling capture remain available while a movie renders; a new recording waits until processing ends.

Escape closes the active selection interface. Screenshot and Quick Capture global shortcuts are unassigned by default and are configured above the output section in the plugin's settings. While scrolling capture or recording is active, the capture action finishes that session instead of opening another selection interface.

## Permissions and compatibility

The plugin supports macOS 14 or later on Apple silicon and Intel. Region recording additionally requires macOS 15 or later; screenshot editing, recognition, pinning, and scrolling capture remain available on macOS 14.

MacTools owns the Screen Recording permission card (`screen-recording`, kind `screenRecording`). Grant permission from that card when you choose to capture, and follow any macOS instruction to relaunch MacTools. The plugin does not request Accessibility, microphone, or system-audio recording access. Permission denial or revocation must leave a clear recovery path in the host.

## Privacy and retention

Screen images, visible window geometry, recognized text, and codes may contain sensitive information. With recording auto zoom on, pointer positions, clicks, and scrolling inside the recorded region are kept in memory only for the current recording and discarded after its movie is rendered. Capture starts only through an explicit foreground action with a visible selection interface. The two canonical actions do not support external Run Links, automatic rules, or App Intents. The plugin does not capture on startup or run unattended screenshot jobs.

Capture, recognition, editing, and image assembly use Apple frameworks locally. The plugin has no upload, network service, or telemetry. Choosing to open a recognized link explicitly hands that URL to the user's browser; screenshots and recognized text are not sent to a service by the plugin.

Screenshots are copied to the system clipboard unless you choose a save operation. Saving to the folder never replaces an existing file; a numbered name is used instead. Cancelling Save As, or a failed write, returns to the same selection and annotations; a pinned scrolling screenshot stays open until its file is written. Saved images use PNG; recordings use MOV. The default destination is `~/Desktop/screenshot`; the folder is created on the first save, and the plugin's settings can select another folder. The selected folder is stored in plugin-scoped preferences. Exported files remain until you manage or delete them yourself; clipboard content remains subject to macOS and other clipboard applications.

Ending a selection hides its reusable capture surfaces, clears image references and annotation contents, and prevents pending work from publishing stale results. Idle surfaces do not acquire or retain desktop snapshots. Disabling the plugin destroys these surfaces and closes pinned images and auxiliary windows. Unsaved edits are discarded. If recording has already created a file, interruption or an error can leave an incomplete MOV file in the selected output folder; inspect or remove it yourself.

The package declares `uninstallDataPolicy: removePrivateData`. The host removes the plugin's private preferences, support, cache, and temporary data on uninstall. Cleanup does not delete screenshots or recordings exported to a user-selected folder, and it does not clear the system clipboard or revoke MacTools' shared Screen Recording permission.

## Plugin contract

| Field | Value |
| --- | --- |
| Package / provider ID | `screenshot` |
| Factory | `ScreenshotPlugin.ScreenshotPluginFactory` |
| Bundle / scheme | `Screenshot.bundle` / `ScreenshotPlugin` |
| Initial package version | `1.0.0` |
| Compatibility | PluginKit 7, MacTools 1.3.1 or later |
| Host surfaces | Primary panel and settings form; no component panel |
| Permission | `screen-recording` |
| Canonical actions and shortcut IDs | `capture`, `quick-capture` |
| Action parameters | None |
| Action policy | Safe, foreground interactive, external invocation unavailable, automatic execution ineligible |

The source manifest contains all 11 marketplace metadata locales. The plugin string catalog provides Simplified Chinese and English UI copy, with complete translations for the metadata and action descriptions referenced by the manifest. The host continues to own permission guidance, shortcut assignment, action discovery, and plugin lifecycle.

## Development and validation

### Capture presentation architecture

The plugin prepares one hidden nonactivating `NSPanel` per display when activated. This prepares native controls, not a screenshot or recording stream. Each explicit invocation acquires fresh opaque display images before ordering any panel. macOS 26 uses the public rectangle-based `SCScreenshotManager` API without shareable-content discovery; earlier systems use display filters. Requests run with at most three concurrent display jobs per session. Failures propagate to the user; acquisition does not fall back to obsolete CoreGraphics capture APIs. Cancellation rejects late results; it does not claim to cancel a committed operating-system screenshot request. Frame callbacks have a two-second failure deadline, not an artificial presentation delay.

Before each presentation, the pool checks each cached panel's public `isOnActiveSpace` property, including hidden panels. If AppKit reports an inactive Space, only that display's panel is closed and recreated; unaffected panels retain their controls. Panels also use `canJoinAllApplications` to join other apps' full-screen Spaces without participating in Stage Manager's window layout. Both APIs are available throughout the macOS 14+ support range. This check runs after image acquisition and adds no idle polling or Space-change observers.

On macOS 26 and later, screenshot configuration explicitly sets `ignoreShadows = false` to preserve system-drawn window framing, including glass edge highlights and shadows within the captured region. Relying on the default can remove these effects from the source image before either preview or export. Earlier systems use stream configurations, which set `ignoreShadowsSingleWindow = false` for the same reason: its default also strips menu and popover shadows from display captures, including scrolling capture and recording. This is separate from optional annotation shadows and does not reconstruct window decorations.

The original `CGImage` is assigned directly to a dedicated `CALayer`, with the source color space assigned to its window. Separate shape layers draw dimming and selection outlines, and an explicit shadow path keeps shadow composition independent of annotation drawing. The size badge and magnifier use small retained AppKit views; the magnifier reuses its source image, localized hints, and a one-pixel sRGB sampling context. The annotation view remains hidden during initial selection and is invalidated explicitly when marks or editing handles change. AppKit coalesces redraws; mouse release always commits the final position. Pointer movement does not redraw the full frozen image or create a full-screen bitmap sampler. The preview, recognition input, and PNG export all use the same frozen source. There is no live-window replacement, popover reconstruction, alpha workaround, startup capture, or continuous idle stream. Display-topology changes cancel selection and rebuild the pool through the host's `DisplayTopologyRefreshing` hook.

Pointer ownership and window targeting use AppKit mouse-rectangle semantics, including the top edge and excluding the bottom edge in unflipped coordinates. This gives vertically adjacent displays one owner at their shared edge without coordinate offsets. Capture panels and their content views disable native window movement; the mode-bar grip still moves only its own view horizontally. Mouse gestures use native AppKit dispatch. No global input hook, polling timer, or forced synchronous display is added to the drag path. Synthetic AppKit input tests verify selection geometry, not physical input delivery at the display edge.

The native window has an opaque background as well as `isOpaque = true`. An opaque frozen-image layer alone is insufficient: on the affected multi-display system, a clear native background routed exact-top-edge presses to the menu bar instead of the capture panel. A reversible comparison in the actual host reproduced failure with a clear background, success with an opaque background, failure after restoring clear, and success after restoring opaque, without changing application activation or window geometry. The background is behind the unchanged frozen image and does not alter export pixels or dimming. Regression coverage checks that this backing remains opaque across ordinary and quick capture reuse; WindowServer delivery still requires an integration check on the target system.

Layout and drawing are prepared while hidden, implicit layer actions and window ordering animations are disabled, and all panels are submitted in one main-actor turn. A Core Animation transaction does not guarantee synchronized physical scanout on separate displays. Use Instruments or a high-frame-rate recording to validate real shortcut-to-visible latency, cold and warm invocation, mixed refresh rates, Space changes, and menu-bar material fidelity before making latency guarantees.

Selection panels set their final `.screenSaver` level after configuring panel flags: setting `isFloatingPanel` resets the level to `.floating`. This keeps the capture surface above ordinary menus and popovers for native mouse delivery without activating the underlying application. Use the public level constant, not its numeric value or repeated ordering calls.

Reviewed references (architectural comparison, not copied implementations):

- [Apple rectangle screenshot API](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/capturescreenshot(rect:configuration:completionhandler:)), [`CALayer.contents`](https://developer.apple.com/documentation/quartzcore/calayer/contents), and [`CATransaction`](https://developer.apple.com/documentation/quartzcore/catransaction).
- [Apple view drawing optimization](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CocoaViewsGuide/Optimizing/Optimizing.html) and [`CALayer.shadowPath`](https://developer.apple.com/documentation/quartzcore/calayer/shadowpath): deferred dirty-region drawing and explicit shadow geometry.
- [QuickRecorder display selection](https://github.com/lihaoyun6/QuickRecorder/blob/main/QuickRecorder/SCContext.swift) uses `NSMouseInRect`; [Flameshot magnifier](https://github.com/flameshot-org/flameshot/blob/master/src/widgets/capture/magnifierwidget.cpp) retains the screenshot and paints its local source region.
- [Snapzy area selection](https://github.com/duongductrong/Snapzy/blob/abe920fb37169a29511bd01d2c8fa37ab3912632/Snapzy/Services/Capture/AreaSelectionWindow.swift): pooled nonactivating panels and separate snapshot/selection layers. Its live-passthrough and retained-popover recovery paths are not required for this frozen-preview design.
- [Mio capture pipeline](https://github.com/iSoldLeo/Mio/blob/248703192e1decc716f43b365edc0a93edc74755/Mio/Capture/CapturePipeline.swift): bounded acquisition concurrency and cancellation-aware delivery. Its startup pixel capture is not adopted.
- [Lenscap selection overlay](https://github.com/rutmehta/Lenscap/blob/b4782cdb849b5f6af076521a896da4786321319a/Sources/Lenscap/Capture/SelectionOverlay.swift): a contrasting live overlay followed by magnifier acquisition, unsuitable here because activating or recapturing can change transient menu materials.

The supplied local Feishu analysis provides supporting evidence of separate acquisition and native presentation stages. Binary names and strings alone do not establish which implementation branch runs or guarantee its performance.

### Continuous capture architecture

Recording and scrolling share geometry, control preparation, native stream ownership, and control presentation, but keep their domain state separate:

| Responsibility | Owner |
| --- | --- |
| Pixel-aligned selection and target-display validation | `CaptureRegion` |
| Hidden control realization, full content discovery, exact window exclusion | `CaptureSessionPreparation` and `CaptureControls` |
| Serialized native start/stop and acknowledged termination | `CaptureStreamSession` |
| Recording output, elapsed time, file/capture completion coordination | `Recorder` and `RecordingLifecycle` |
| Complete-frame delivery, bounded processing, stitching | `ScrollSession`, `ScrollFrameSource`, `ScrollCapture`, and `ScrollStitchingWorker` |
| Shared confirmation/status appearance and screen-clamped placement | `CaptureActionBar` and `CaptureStatusPanel` |
| Serialized background PNG/TIFF encoding and background file writes | `ScreenshotImageEncoder` |

Control windows are materialized while hidden, then resolved through `SCShareableContent` with `onScreenWindowsOnly: false`. A just-created window can exist without appearing in an on-screen-only snapshot. Exclusion uses only this session's exact window IDs, not every window owned by MacTools. Controls are ordered only after constructing the filter and configuring the output; their positions stay inside the selected display even for full-screen selections. Missing control IDs fail closed, with ID/count-only diagnostics. There is no visibility retry loop, off-screen staging window, delayed show, or window-sharing workaround.

The coordinator owns a session before asynchronous preparation starts. Cancellation during startup prevents later UI presentation; cancellation after native start requests a real stop and keeps ownership until the system acknowledges termination. A ten-second native-operation warning does not claim that capture stopped. A returned stop error permits an explicit retry; a still-pending native call is not overlapped by another stop. Recording additionally waits for the output delegate's final callback, including cancellation, and never publishes a file merely because `stopCapture` returned. Display changes stop continuous capture and prevent changed-geometry frames from entering the stitcher.

Scrolling uses a 10 fps ScreenCaptureKit stream with queue depth three, accepts only complete frames, materializes independent pixels, and feeds an `AsyncStream` with one newest-frame slot. Matching uses bounded row samples followed by full-resolution verification and ambiguity rejection; rejected frames do not replace the last accepted reference. New strips own only their copied pixels. Before allocating, the stitcher reserves six viewport buffers and three output-sized buffers within a 384 MiB working-pixel budget, in addition to the output limits. This is an allocation estimate, not a bound on framework allocations or total process RSS. PNG/TIFF encoding is serialized off the main actor; clipboard conversion cannot overwrite a newer clipboard revision.

Additional references:

- [Apple ScreenCaptureKit content discovery and filtering](https://developer.apple.com/videos/play/wwdc2022/10155/).
- [Apple straight-to-file recording and delegate completion](https://developer.apple.com/videos/play/wwdc2024/10088/).
- [QuickRecorder encoding capability checks](https://github.com/lihaoyun6/QuickRecorder/blob/main/QuickRecorder/RecordEngine.swift).
- [Snapzy scrolling frame source](https://github.com/duongductrong/Snapzy/blob/abe920fb37169a29511bd01d2c8fa37ab3912632/Snapzy/Services/Capture/ScrollingCapture/ScrollingCaptureFrameSource.swift) and [stitcher](https://github.com/duongductrong/Snapzy/blob/abe920fb37169a29511bd01d2c8fa37ab3912632/Snapzy/Services/Capture/ScrollingCapture/ScrollingCaptureStitcher.swift): continuous frame delivery and conservative matching rather than repeated one-shot capture.

A September 16, 2026 native smoke probe on the local Apple silicon system resolved both hidden control windows, captured only a synthetic opaque window, produced and decoded a 512 × 384 silent MOV, delivered complete scrolling frames, and acknowledged both stream stop and file completion when cancelled immediately after starting. No desktop content was captured or saved by that probe. The 87 focused Screenshot tests and 16 minimum-host checks passed; all 268 repository script checks passed after explicitly matching `SDKROOT` to the selected Xcode toolchain, without changing global configuration. These checks do not replace manual verification on macOS 14/15, Intel, or mixed-scale display arrangements.

### Validation commands

Plugin targets are discovered from `Plugins/Screenshot/plugin.json`. The plugin's `project.yml` only adds ScreenCaptureKit, Vision, CoreImage, UniformTypeIdentifiers, QuartzCore, and VideoToolbox linker flags. Do not modify root project targets or generated plugin configuration to register it.

After preparing local signing settings, generate the project and build the plugin:

```sh
make generate
make build-plugin PLUGIN=Screenshot
```

Run script checks for source-manifest projection, generated project configuration, and PluginKit minimum-host compatibility:

```sh
make script-tests
```

Run the adjacent Screenshot test classes and `PluginRuntimeActionSnapshotTests` through the generated host test target, limiting execution with `-only-testing:MacToolsTests/<TestClassName>`. Use injected images, permission checks, and asynchronous capture/recognition closures in tests; tests must not capture the real desktop or delete user files.

Before release, check region and window selection on a single display and mixed-scale multiple displays; annotations and PNG output; OCR and QR success, failure, and cancellation; pin closure; repeated scrolling start/finish/cancel; Screen Recording denial and revocation; plugin deactivation during pending work; and successful and failed recording finalization on macOS 15 or later. Confirm macOS 14 hides or explains the unavailable recording mode, optional shortcuts remain unassigned, and uninstall preserves exported files. Verify translated labels and errors in English and Simplified Chinese.
