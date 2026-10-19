# Adaptive menu-bar panels

## User flow

Width controls appear only while editing the layout. The popup width menu offers
one-click column presets and a column stepper, without a fixed column cap. Two
standard columns need 628 points including panel padding. An exact numeric width
requires Apply or Return and is clamped to the display; dismissing unfinished input
does not resize the panel. Slider previews are not used. Finishing editing closes
the width menu and removes the resize control from the everyday header.

Original rows, including conditional-detail rows such as Keep Awake, now share
columns when their resolved widths fit. Automatic uses a flexible column based on
the existing 304-point preset; Fill Panel owns a full layout band; Custom keeps an exact width,
clamped to available space without discarding its saved preference. Row heights
and insertion targets use those same frames. Dragging beside an item places it in
the adjacent slot when it fits. Items are placed in saved order into the lowest available column space, so shorter
controls can stack beside expanded details.
Legacy widgets retain declared dimensions and can share columns in wide panels.
The original narrow widget grid retains its row behavior. Existing detail controls
and segmented-control list fallbacks are preserved.

Appearance, Night Shift, Microphone Mute, and Auto Hide Dock opt in to an additional
Compact Switch presentation. In editing, each item's ordering menu offers Full
Controls or Compact Switch. Labels retain the shared typography. Native switches sit
beside their label when space permits, or directly below at narrow widths, without
extra vertical spacers. Existing icon widgets remain separate library choices.
Keep Awake and other complex rows retain all existing detail controls.

Editing previews do not execute actions. Reordering, drag targets, scrolling, and
rendering use the same width-aware geometry. Undo covers committed width and
presentation changes and cannot overwrite a newer layout change. Moves preserve
placement identity, presentation, and width; newly added copies start in their original
presentation and share the plugin's business state and action handler.

Host controls have 16-point gutters with subtle native separators in everyday use and
stronger dashed guides during editing. Flexible row widths absorb the extra gutter
space so saved widths retain their column counts. Fixed-size widgets retain the
original slot width and minimum spacing. Guides stop around custom-width
items and plugin widgets. Editing adds item outlines and visible drag grips without
changing widget dimensions. The drop footprint is calculated from the proposed saved
order; committed items stay still until release. Normal controls start at column
boundaries even when compact switches are separated in the saved order. Prepared
landing positions prioritize the pointed column and use modest hysteresis to avoid
flicker near boundaries. One prefix packing pass prepares column targets after text
measurement; pointer updates do not repack or remeasure the panel. Hover scanning is
suppressed during dragging, and native drag-grip images are cached. It works across panels and in
right-to-left layouts without executing plugin content. The width button reports
the visible column count, and the width picker marks the selected count.

## Persistence and compatibility

Layout schema 4 and backup format 7 include preferred popup width, per-placement
content width, and presentation in the existing layout category. Previous layouts and backups migrate
with a width of 316 points and original presentations. Selective imports, automatic
backup snapshots, and cloud documents retain their existing selection and recovery
rules. Unknown presentation names, width modes, and unavailable plugin references remain saved.

PluginKit 7 keeps its original ABI. The new optional compact-switch protocol
requires host 2.0.3; older binary packages continue using original renderers.
Missing capability, disabled controls, errors, details, or indicators fall back to
the full row without discarding the preferred compact presentation. All computers
sharing new backup documents need an updated host; older hosts reject this format.

## Verification

Use focused geometry, coordinator, editor, store, and backup tests first, then
`make ci`, including the frozen PluginKit 7 binary client. Native visual review
covers 316-point and wider layouts, more than two columns, long English names,
editing, dark appearance, and right-to-left layout using isolated fixture data.
Final desktop acceptance should also exercise the actual menu-bar anchor at both
screen edges, choosing columns through the editing width popover, keyboard/VoiceOver use, changing
displays, permission failures, and importing an exported file on a smaller display.

Edge dragging, arbitrary resizing of plugin widget content, independent column
regions, and automatic width expansion are outside this change.
