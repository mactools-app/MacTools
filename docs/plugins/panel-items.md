# Panel items

PluginKit 7 replaces the primary-panel and component-panel protocols with
`MacToolsPlugin.panelItems`. A plugin may contribute multiple rows and widgets,
including multiple items of the same kind. The host owns the supported renderers,
grid, scrolling, editing, and panel windows.

For shared visual, performance, and review requirements, follow the
[plugin development standards](development-guidelines.md).

## Declaring items

```swift
var panelItems: [PluginPanelItem] {
    [
        .row(
            id: "control",
            title: "Quick Control",
            initialPlacement: .featurePanel,
            descriptor: controlDescriptor,
            state: controlState,
            action: { [weak self] in self?.handleControl($0) }
        ),
        .widget(
            id: "overview",
            title: "Overview",
            initialPlacement: .dashboard,
            descriptor: overviewDescriptor,
            state: overviewState
        ) { [model] context in
            OverviewView(model: model, context: context)
        }
        .onVisibilityChange { [weak self] visible in
            self?.setOverviewPresented(visible)
        },
        .widget(
            id: "history",
            title: "History",
            descriptor: historyDescriptor,
            state: historyState
        ) { [model] context in
            HistoryView(model: model, context: context)
        }
    ]
}
```

Omitted titles, descriptions, and icons inherit plugin metadata. Give distinct
titles to multiple items so users can identify them in the library. Item IDs are
plugin-local, case-sensitive ASCII identifiers containing letters, numbers,
periods, underscores, or hyphens, with a maximum of 128 bytes. The host accepts
up to 256 definitions per plugin. Keep IDs and renderer kinds stable; do not
derive the catalog from transient records such as processes or calendar events.

`initialPlacement` is an optional, one-time suggestion. `.dashboard` and
`.featurePanel` refer to stable built-in panel identities, even after users move
or rename their tabs. Omitting it makes the item library-only. Moving or deleting
an item overrides the suggestion permanently until an explicit layout reset.
New item IDs in plugin upgrades are initialized once. Changing the default for
an existing ID does not rearrange user layouts.

The manifest declares allowed renderer kinds, not individual item IDs:

```json
"pluginKitVersion": 7,
"capabilities": {
  "panelItems": ["row", "widget"],
  "settings": "form"
}
```

Use an empty `panelItems` array for plugins without panel content. Runtime items
must use a declared kind. Invalid or duplicate IDs do not replace a valid catalog
silently. Installed packages from older PluginKit versions remain on disk and
must be updated before the host loads their code.

## Compact icon controls

For a simple primary toggle, fixed action button, or settings-page entry point, use the shared `iconWidget` factory alongside
the existing row. It produces a library-only widget with no initial placement and
centers a single-line title below the icon. Long titles truncate; the full title,
description, and error remain available on hover. Five compact controls fit across
the standard panel, while normal widgets use a four-column grid. Both densities
can share a row. Use `PluginPanelWidgetLayoutMetrics` for sizes and spacing
instead of duplicating the renderer's constants.
`PluginPanelWidgetSpan.grid` defaults to `.standard`; the shared icon factory
selects `.compact`. Use layout metrics' `itemWidth(for:)` when resolving a span
so its grid density is preserved.

The pre-release PluginKit v7 ABI baseline includes the grid field and icon factory.
Its independent client fixture under `scripts/fixtures/plugin-kit-v7/` covers both
grid densities. Rebuild packages made against earlier development snapshots;
after v7 ships, incompatible layout changes require a new PluginKit version.

```swift
.iconWidget(
    id: "quick-control",
    title: localization.string("metadata.title", defaultValue: metadata.title),
    systemImage: metadata.iconName,
    control: .toggle,
    state: state,
    menuActionBehavior: rowDescriptor.menuActionBehavior,
    action: { [weak self] in self?.handleAction($0) }
)
```

Declare both `row` and `widget` in manifest capabilities. Read the row state once
and share that snapshot between the two definitions. `.toggle` sends
`.setSwitch(!state.isOn)`; `.button` sends `.invokeAction(controlID: "execute")`.
Only toggles use the on-state highlight. The shared renderer uses circular toggle
surfaces and rounded-square button surfaces without an outer card or switch badge.
Surfaces and accent-filled active states follow the panel theme, including library
previews. Names, descriptions, and errors remain in tooltips, with duplicate lines
removed. Error badges and native
toggle/button accessibility semantics remain available. It does not optimistically change state.
Plugins continue to publish the actual outcome through `onStateChange`.

Disabled or unavailable controls and library previews cannot perform actions.
Dismiss-before-handling controls close the panel before dispatching on the next
main-actor turn. Existing permission checks, confirmations, and emergency exits
remain in the plugin's handler. A chooser or confirmation must still open through
that handler; never replace it with immediate execution. Settings entry points
should use `PluginSettingsPresenting` from their shared handler, not host-specific
row routing. Do not use this shortcut for rows with additional controls, including
details that appear only after enabling, or controls whose primary action changes
during a session. Keep Awake, IP Overview, Siri, and Screenshot remain row-only
until their additional actions or multi-state interactions have a dedicated design.

The shared renderer owns symbol size, icon frames, and spacing. Symbols remain
centered inside their icon surfaces; the icon-and-title group aligns to the top
of the full-height hit target, with unused height below it. This alignment is the
same at every panel position, in layout editing, and in library previews. Prefer
the plugin's existing SF Symbol and a localized name for tooltips and
accessibility; do not add per-plugin padding or symbol offsets.
For foreground data refresh, attach visibility callbacks to both definitions and
track the set of visible item IDs in the plugin. Start shared work when the first
item appears and stop it only when the last item disappears; widget previews must
not initiate that work.

A row detail slider may carry one trailing icon button. Set `actionIconSystemName`
on the `.slider` control, with `actionTitle` as its tooltip and accessibility label,
and handle `.invokeAction(controlID:)` for the slider's control ID. The button stays
active when the slider is disabled, so omit the icon while the action is unavailable.
Older hosts ignore the icon; raise `minHostVersion` when the action has no other
entry point.

## Panel layout and editing

Live panels follow saved item order. Equal-height widgets share a row while their
widths fit; a different height or insufficient width starts a new row. Later items
do not backfill completed rows. Standard and compact spans retain their own widths.

During editing, small widgets use one centered menu for removal, cross-panel moves,
and ordering, leaving the surrounding area draggable. Larger cards keep separate
controls with draggable gaps. Insertion indicators follow the pointed widget edge
and preview the available footprint; moving a widget does not reserve its old cell.
Changes save one ordered list, and Undo restores the previous arrangement.

## Identity and state

An item definition is identified by `(pluginID, itemID)`. Each user-added placement
has a separate UUID. Copying creates a new UUID; moving preserves it. Copies share
the plugin and its business model, while host expansion, detail anchors, and
other presentation state use placement identity. Adding a view does not activate
another plugin instance or duplicate its background services.

Definitions are lightweight snapshots. After `onStateChange`, the host reads only
the changed plugin's items. State, localized labels, and widget dimensions may
change without changing identity. Getters and view factories must read existing
snapshots, not perform synchronous scans, hardware queries, or network requests.

`state.isAvailable` describes whether the view can currently be rendered, not a
user preference. Unavailable views retain their saved placements. Expansion and
navigation selection belong to each host placement; do not publish expansion in
the row state. Every row starts collapsed, and plugins should initialize their
detail-demand flag to `false`. Expansion is not persisted across app launches.
Unavailable rows, and disabled rows without detail content, lose
their expansion and navigation state. The host sends a collapsed action when the
last expanded copy is cleared; plugins must not independently reset expansion
while reading their state. Business actions remain shared through the item's
action handler.

### Library and localization

The host localizes inherited default descriptions when the app language changes.
Plugins remain responsible for localizing explicit item descriptions, dynamic
subtitles, and errors. Library previews render the view itself without additional
title labels; item names remain available for library search, tooltips, and
accessibility. The library preserves plugin order and packs widgets before
rows, processing declaration order within each renderer. All previews share a
scale that fits two full panel widths, but each occupies only its actual bounds.
Masonry placement chooses the topmost available position, then the leftmost;
narrow previews do not reserve half-column slots. Only nearby previews mount,
and scrolling back reuses snapshots cached for the selected plugin. Adding and removing
placements belong to panel editing, not command-palette commands.

### Height and view lifetime

For content-driven height, call `context.reportContentHeight(height)` from the
widget's intrinsic-content measurement, before applying the allocated host frame.
The host rounds valid heights to its grid and coalesces layout-only updates. Each
placement keeps its own measured height; the descriptor's span remains the default
for unmeasured placements and previews. Moving retains the measurement, removing
or discarding the widget session releases it, and the library measures previews
separately without changing live placements. Do not
write a placement's measured height into shared plugin state or call
`onStateChange` just to resize a widget.

The host lazily constructs nearby widgets and caches content per placement and
plugin revision. It updates routing closures independently of cached content.
SwiftUI local state remains mount-scoped; caching an `AnyView` does not preserve
arbitrary `@State` after viewport unmounting. Keep business data in the plugin's
model and explicitly retain any necessary per-placement state.

## Visibility and details

`onVisibilityChange` is aggregated across placements in the presented panel.
The first consumer receives `true` and the last receives `false`. Switching between
panels containing the same item does not restart its work. Scrolling, lazy view
mounting, and library previews do not deliver these notifications. Handlers may
request a state update or close the panel synchronously.

Widget context provides plugin and item IDs, an optional placement ID, dismissal,
and detail presentation. A missing placement ID identifies a preview. Preview
factories must be free of side effects and must not start polling or mutate shared
settings. Provide the widget's optional `detail` factory and call
`context.presentDetail(detailID)` to open a host-owned detail surface anchored to
the requesting placement.

## Host migration

Layout version 3 stores explicit ordered placements and initialized item keys.
The host converts old assignments, copies, removals, surface orders, and visibility
together. References to unavailable plugins remain in the layout. Old shared
preferences without renderer information retain a small migration seed until
capabilities are available; they do not invent a second view for every plugin.
Backup import uses the same conversion. Unknown or corrupt layout payloads are
preserved until an explicit reset or import. Once the replacement is saved, the
host retires the unreadable legacy layout and resumes normal ordering persistence;
relaunching must not restore the retired payload.

Plugin management order is independent of panel placement. Removing a panel
preserves its placements in the first visible remaining panel, including entries
whose plugins are temporarily unavailable.
