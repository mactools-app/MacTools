# Plugin development standards

These requirements apply to plugins maintained in this repository and contributions to the shared plugin API. Start with [Contributing](../../CONTRIBUTING.md) for setup and review, [local development](local-native-plugins.md) for packaging, and [panel items](panel-items.md) for the complete widget API.

## Protocols and ownership

The current API is **PluginKit 7**, with a minimum host of **MacTools 1.3.1** for that compatibility line. Declare the first compatible host for every API you consume; an unchanged older protocol does not make a new symbol available to an older app.

| Concern | Contract |
| --- | --- |
| Plugin identity | One plugin instance per package; `plugin.json.id` equals `PluginMetadata.id`. Keep plugin, item, action, permission, and shortcut IDs stable. |
| Panel content | Implement `MacToolsPlugin.panelItems` with declared `row`/`widget` renderers. `initialPlacement` is a one-time suggestion, not permission to rearrange user layouts. |
| Settings | Use `nil` for no settings, otherwise return one `PluginSettingsPage`. Match manifest `capabilities.settings`: `none`, `form`, or `workspace`. |
| Commands | Publish canonical `PluginActionProviding` actions. Workflows, Run Links, Action Grid, and composed providers use the host registry/executor; preserve availability, permission, confirmation, and exposure policies. |
| Shortcuts and permissions | Declare `shortcutDefinitions` and `permissionRequirements`; let the host own registration and guidance. |
| Lifecycle | Acquire plugin-owned services in `activate(context:)`; release them in `deactivate(reason:)`. UI mounting is not activation. |
| Metadata | Keep capabilities, requirements, privacy/setup guidance, localized product copy, and action descriptors consistent with runtime behavior. Follow the [manifest schema](plugin-manifest.schema.json). |

Record newly introduced public APIs and their first compatible host in `scripts/tests/test_plugin_minimum_host_compatibility.py`, including optional protocols. When consuming an already listed API, align `plugin.json.minHostVersion`; no duplicate inventory entry is needed. Run `make ci` for shared API/ABI changes; it includes script tests and the frozen v7 binary-client checks. A plugin newly consuming a public API runs `make script-tests`. Preserve historical signed catalogs. Release tooling owns ordinary package-version bumps.

Localize panel, settings, permission, error, and metadata text. Plugin string catalogs belong in `Plugins/<PluginName>/Resources`; use the plugin resource bundle. Source manifests declare localized product fields through `productStrings` references and place screenshots in `MarketplaceAssets/`. See [product metadata](plugin-catalog.md#product-and-capability-metadata); do not hand-edit generated package manifests or add a parallel marketplace manifest.

Every lookup needs an English resource so the shared fallback never exposes Chinese defaults or key identifiers in other languages. Keep every catalog key translated in all 11 supported languages. Run `make validate-localization` after changing copy or catalogs; `make script-tests` includes it. The check validates recognized source lookups, Marketplace enum labels, translation state, supported-language completeness, and printf argument types. A missing translation fails validation; `python3 scripts/audit-localization.py --require-complete --json` lists every finding. Computed keys and new wrapper methods still need review.

Use `PluginRuntimeLocalization.locale` for user-facing numbers, percentages, byte counts, dates, durations, and lists. Keep protocol timestamps, exported filenames, identifiers, paths, vendor field names, and user-authored content stable. Retained presentation must respond to language changes through `PluginRuntimeLocalizationRefreshing` without restarting collectors or rescanning data. Preserve the underlying values and selection. Review long translations, Arabic directionality, accessibility text, and native dialogs on the affected surfaces.

Custom SwiftUI sheets must explicitly forward their presenter's `locale` and `layoutDirection` environments to the sheet content. On macOS, automatic sheet inheritance can leave Arabic content laid out left to right. Use semantic forward/backward symbols for UI navigation while preserving physical left/right directions in input bindings. Keep manifest action symbols aligned with their runtime definitions and regenerate website data after changes.

Independent AppKit hosting views and controllers must observe the runtime locale and forward both environments to their SwiftUI roots. Refresh localized native window labels and cached previews without recreating editing or selection state. Keep physical grids, pointer coordinates, and menu-bar item ordering stable; apply the language direction to their semantic text and controls.

## Widgets

A widget is a reusable presentation of plugin data. It can have no placements, one placement, or multiple independent copies.

| Area | Requirement |
| --- | --- |
| Identity | A definition uses `(pluginID, itemID)`; each placement has its own UUID. Keep transient process/event/device records inside the model, not in item IDs. |
| State | Keep business data, collectors, and durable tasks in the plugin model. Use placement identity for independent presentation state; view-local `@State` may disappear after viewport recycling. |
| Factories | `panelItems`, descriptors, and view factories read cached snapshots. They must not synchronously scan files, query hardware, or fetch network data. |
| Sizing | Use `PluginPanelWidgetSpan` and `PluginPanelWidgetLayoutMetrics`. Resolve widths with `itemWidth(for:)` so standard and compact grids remain correct. Avoid copied cell sizes and per-plugin offsets. |
| Dynamic height | Measure intrinsic content before applying the host frame, then call `context.reportContentHeight`. Height belongs to the placement; do not write it into shared state or call `onStateChange` only to resize. |
| Preview | `context.isPreview` identifies a library preview. Render cached or deterministic preview data; do not execute actions, mutate settings, or acquire polling/foreground consumers. |
| Foreground demand | Use the item's `onVisibilityChange`. The host aggregates copies of the same item; plugins aggregate distinct item IDs sharing one collector. Start on the first consumer and stop on the last. |
| Details | Use `context.presentDetail` and the widget's detail factory. The host owns anchoring, dismissal, panel scrolling, and editing. |

Do not tie business work to each view's `onAppear` or `onDisappear`: scrolling and library previews mount views without changing the plugin's active consumers. Hiding one copy must not stop another visible copy.

For a single toggle, fixed action, or settings entry, prefer `PluginPanelItem.iconWidget`. Share one snapshot and handler with the row, distinguish `.toggle` from `.button`, and preserve permission checks and dismissal behavior. The factory supplies geometry, theme treatment, accessibility, and tooltips. Rows with secondary controls, conditional details, or multi-step sessions need a dedicated widget design; see [compact icon controls](panel-items.md#compact-icon-controls).

Choose widget checks according to the changed behavior. For state or lifecycle changes, focus on shared collection across copies, preview isolation, current values after reopening, and ignoring late callbacks after deactivation. For layout changes, visually check affected spans, scrolling, and adaptive height with representative content. Reuse host tests for unchanged placement/move mechanics; do not recreate the host test matrix in every plugin or add automated assertions for exact spacing and colors.

Keep adjacent plugin tests limited to the main action, durable state, and consequential permission or failure handling. Do not retain a separate test for every historical timing combination or presentation detail. Run `make test TEST_FILTER=<TestClassName>`; use manual checks for windows, native input, screenshots, and timing measurements. The generated test target includes plugin tests automatically and has no standalone process-probe dependencies. See the [core test scope](../testing/core-tests.md).

## Visual and interaction design

These rules apply to host and plugin UI across settings, menu-bar panels, widgets, and floating windows. Prefer native macOS appearance and behavior, using standard SwiftUI/AppKit controls and semantic system styling. Use Apple's [macOS Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) as the platform reference, applying the guidance to the app's menu-bar utility context and supported macOS versions.

Keep equivalent controls consistent in typography, SF Symbol usage, spacing roles, color meaning, and interaction feedback. Settings forms, compact menu-bar panels, and task-oriented windows may use different density and grouping while retaining the same visual language. Preserve native menu presentation where a surface uses a system menu.

Follow the [shared typography contract](typography.md) for text roles, native AppKit metrics, compact layouts, color semantics, and content-specific exceptions. `PluginSettingsTheme.Typography` delegates to the shared roles; preserve those existing settings accessors when extending other surfaces.

Before implementing a UI change, identify the surface below and inspect a comparable existing implementation. Reuse its host renderer, component, and semantic tokens. When a reusable control or style is missing, extend the appropriate shared layer and use it in the affected UI; avoid per-plugin copies of fonts, colors, spacing, or control styles. Keep unrelated UI migrations out of the change.

| Surface | Use |
| --- | --- |
| Menu-bar panels | Host panel renderers and `MenuBarPanelThemeStyle`; plugin content uses the declarative panel API and public PluginKit themes. |
| Widget cards and charts | `@Environment(\.pluginComponentTheme)` for surfaces, text, status, and categorical data colors. Keep meaningful brand colors and feature thresholds distinct from neutral theme styling. |
| Settings | `PluginSettingsPage.form` with declarative rows by default; a custom section for a complex region, or `.workspace` for a full manager/editor. |
| Custom settings content | `PluginSettingsTheme.Typography` and `.Spacing`, `PluginSettingsItem`, and `.pluginSettingsCardBackground(.standard/.recessed)`. |
| Floating palettes | `PluginPaletteSurface`, the [shared palette appearance](palette-appearance.md), and the [global presentation contract](global-panel-presentation.md). Keep app activation separate from keyboard focus. |

The host owns page titles, descriptions, permission cards, shortcuts, search, validation, and the surrounding background. Do not duplicate page chrome or draw another outer card inside a grouped Form. Plugins must not depend on `Sources/App/SettingsStyle.swift` or copy private host styles.

Keep native forms and custom workspaces as separate containers with shared surface roles:

- Native grouped Form draws its section cards. Custom section content and empty states inherit that surface without adding a standard card; nested previews and editors may use an inset surface when they need their own boundary.
- Standalone workspace cards use `pluginSettingsCardBackground(.standard)`, backed by the system's secondary background style. Do not approximate a native card with a translucent material, sampled RGB values, or a foreground color with arbitrary opacity.
- Inset previews, logs, and control groups use `.recessed` or `Palette.recessedControlBackground`; these use a neutral system background rather than an inactive selection color. Editable text uses `Palette.fieldBackground`; raised controls use `Surface.raisedControl` or the appropriate native control background.
- Preserve selected, hovered, recording, warning, and error states. Theme convergence should not remove interaction feedback or flatten all surfaces to one color.

Compare native and custom surfaces in light and dark appearance, including increased contrast and reduced transparency where available. Verify readability and clear surface boundaries; exact pixel matching across OS versions is not a requirement.

Use semantic fonts, SF Symbols, native bordered buttons, small control sizes, and switch-style toggles where appropriate. Give controls predictable widths and numeric readouts stable alignment. Long localized titles and paths must not displace controls or cause clipping. Custom settings should follow `FanControlPresetManagerView` for typography and grouping.

Preserve native keyboard navigation, focus indication, text selection and editing, input-method composition, and disabled-control behavior. Custom controls must retain the relevant accessibility labels, values, and actions. Let system controls and materials adapt to the current OS and user preferences; gate newer visual APIs with availability checks and maintain native fallbacks for the supported macOS versions. Custom themes should retain readable text and recognizable control states.

Respect the user's layout, appearance, accessibility, and system preferences. Compare changed controls with equivalent controls on existing settings and panel surfaces to catch unintended differences. Check the themes, keyboard/focus behavior, labels, and loading/error/empty states affected by the change. Visual-only changes normally use screenshots and manual verification; state transitions and actions need focused behavior coverage only where existing tests leave a gap. Keep copy brief and user-facing.

## Performance and energy

Separate **collection**, **presentation**, and **host metadata updates**. Low energy use must not silently reduce the accuracy of an enabled monitor.

- Prefer system notifications and shared observers over repeated polling. When polling is necessary, use the slowest interval that meets the feature's freshness needs, allow timer tolerance where appropriate, and avoid separate timers for each widget copy.
- Keep UI and state publication on the main actor; move expensive I/O, scans, subprocess work, and system queries to appropriate queues or actors while respecting each API's threading requirements. Declaring a method `async` alone does not move it off the main actor. Return bounded snapshots; coalesce requests, prevent overlapping refreshes, and bound caches, histories, queues, retries, and subprocess lifetimes.
- For filesystem scans, use the shared `MacToolsFileSystem` metadata reader and consume `readBatches` without retaining every entry in a wide folder. Preserve cancellation and package, symlink, and cleanup-policy boundaries. Previously delivered batches remain partial if a later read fails; never report them as a complete scan.
- Use `onStateChange?()` for state the host must rebuild. High-frequency events update their business snapshot and publish throttled presentation changes; configuration, permissions, availability, and errors still need timely host updates.
- Use `PluginObservedContent` for frequently changing `ObservableObject` presentation. Do not add another `@ObservedObject` subscription to the same model underneath it. Hidden presentation can disconnect while collectors and independent menu-bar/settings consumers continue. Reopening must immediately read current data.
- Pause presentation-only refreshes and animations when hidden. Retain explicitly enabled background tracking and its persistence guarantees. Do not make a panel opening or `refreshAll()` the only way to notice external state changes.
- On deactivation, cancel tasks, invalidate timers, remove observers, stop event taps, and release resources owned by the plugin. Reject callbacks from a stopped session; handle subscription failures, service restarts, sleep/wake, and reconnects without busy retry loops.

Measure when a change materially affects background workload, sampling frequency, large-data rendering, or claims a performance improvement. A short, reproducible before/after observation is enough; a new benchmark suite is not required. Record the environment, workload, duration, and relevant refresh settings. Start with Activity Monitor; use Instruments when there is evidence of wakeups, allocations, or main-thread stalls needing investigation. Compare the same build configuration; Debug and Release measurements are not interchangeable.

For background-work changes, start with idle (panel closed) and active use. Add multiple copies, preview, deactivation, or sleep/wake checks only when those paths are affected. Verify the core guarantees: no duplicate collectors, bounded retained memory, and correct intentional monitoring while hidden. Report the relevant observations; there is no universal CPU/energy threshold or requirement to exercise every state for a small change.

See [presentation subscriptions](presentation-performance.md) for implementation details.

## Safety and data

- Validate external inputs and recheck live targets before a system write. Preserve cleanup allowlists, permission guidance, confirmations, cancellation, and recovery. Power/session-ending actions use native foreground confirmation flows.
- Keep credentials and sensitive payloads out of logs, screenshots, and fixtures. Use synthetic data and fake services in tests; never query real accounts to verify a parser or lifecycle.
- Uninstall preserves plugin data by default. Sensitive-data removal uses `uninstallDataPolicy: removePrivateData`, `PluginPrivateDataKeychainIdentity`, and host-owned cleanup/recovery. Never remove user-exported files as part of private-data cleanup.
- Prefer public Apple APIs. Any necessary private framework must be dynamically loaded, availability-checked, and fail safely. Ordinary window movement/resizing uses public Accessibility APIs and current display geometry.
- Event taps must declare the required permission, keep callbacks bounded, stop on deactivation, and recover when macOS disables the tap. Shared external events belong in Core abstractions when multiple plugins need them.

Follow [LICENSING.md](../../LICENSING.md), retain third-party notices, and declare required system access accurately before installation.

## Review references

Use these implementations to understand the contract, adapting only the parts your plugin needs:

| Concern | Reference |
| --- | --- |
| Protocol and lifecycle | [PluginInterfaces.swift](../../Sources/MacToolsPluginKit/PluginInterfaces.swift) |
| Items, sizing, and context | [PluginPanelItems.swift](../../Sources/MacToolsPluginKit/PluginPanelItems.swift) · [PluginModels.swift](../../Sources/MacToolsPluginKit/PluginModels.swift) |
| Compact controls | [PluginPanelIconWidget.swift](../../Sources/MacToolsPluginKit/PluginPanelIconWidget.swift) |
| Themes and presentation observation | [PluginComponentTheme.swift](../../Sources/MacToolsPluginKit/PluginComponentTheme.swift) · [PluginSettingsTheme.swift](../../Sources/MacToolsPluginKit/PluginSettingsTheme.swift) · [PluginObservedContent.swift](../../Sources/MacToolsPluginKit/PluginObservedContent.swift) |
| Multiple consumers and adaptive height | [ActivityBarPlugin.swift](../../Plugins/ActivityBar/Sources/ActivityBarPlugin.swift) |
| Visibility-aware device monitoring | [DeviceBatteryPlugin.swift](../../Plugins/DeviceBattery/Sources/DeviceBatteryPlugin.swift) |

Feature-specific requirements remain in their guides: [actions and automation](../actions-automation.md), [Mac Settings](mac-settings.md), [screenshots/recording](screenshot.md), [clipboard backup](clipboard-backup.md), [App Volume](app-volume.md), [Display Volume](display-volume.md), [AI Usage](ai-usage.md), [window layouts](window-layouts.md), [window switching](window-switcher.md), [menu-bar icons](menu-bar-icons.md), [Duo Status](duo-status.md), [palette appearance](palette-appearance.md), and [Siri/input actions](siri.md). Release contributors should also read [managed CLI distribution](managed-cli-distribution.md) and [stable CLI acceptance](cli-release.md).
