# Shared typography

MacTools uses native macOS information roles across settings, menu panels, widgets, and utility windows. Keep fonts in PluginKit and let reusable renderers own repeated layout. The public `PluginTypography` and `PluginMetricValue` APIs require **host 2.0.1**. Their consumers must declare a compatible `minHostVersion`; older settings accessors remain available.

## Roles

Use `PluginTypography.<role>.font` in SwiftUI and `.nsFont` in AppKit. Use the same AppKit font for drawing and measurement. The implementation resolves system text styles without observers, timers, per-view theme objects, or an application font cache.

| Role | System style | Use |
| --- | --- | --- |
| `pageTitle` | Title 2, semibold | Host page headers and standalone window titles |
| `sectionTitle` | Body, semibold | Sections, cards, and emphasized item titles |
| `body` | Body | Ordinary text and item names; medium weight may emphasize an interactive item |
| `detail` | Subheadline | Descriptions, help, and subtitles |
| `caption` | Caption | Compact metadata, chart labels, badges, and units |
| `control` | Callout | Custom control labels; native controls normally manage their own font |
| `value` | Callout, monospaced digits | Inline percentages, temperatures, and counts |
| `metric` | Title 2, semibold, monospaced digits | Standalone numeric readings |
| `prominentMetric` | Large title, semibold, monospaced digits | A card's principal reading |
| `code` | Callout, monospaced | Technical text and aligned code |

`PluginSettingsTheme.Typography` remains the settings facade, backed by these roles. Do not rename existing settings accessors or add a second page title inside custom settings content. Standard SwiftUI semantic styles remain appropriate when they already express the same role; do not rewrite them just to change spelling.

Use `PluginMetricValue(value, unit: unit)` for a standalone value and subordinate unit. Set `isProminent` for the principal reading, inherit the value's foreground from the caller, and pass `unitColor: theme.text.secondary` in themed widgets. Keep domain thresholds, formatting, and accessibility descriptions with the owning feature.

## Density and color

Use ordinary and compact layouts. Compact presentation primarily adjusts spacing, grouping, visible detail, and metric prominence. Prefer 11–13pt for sustained reading and keep ordinary text at least 10pt. Inspect `minimumScaleFactor` as well as the nominal font. SF Symbols are geometry, not ordinary text, and may require smaller sizes.

Reduce redundant labels or chart ticks before shrinking text. Wrap descriptions, truncate secondary metadata with access to the full value, and reserve enough height for the selected font. Avoid per-render text measurement in SwiftUI; let native layout handle intrinsic sizes. Recalculate fixed AppKit frames when adopting a different role.

In fixed, tightly constrained content, use 7pt for a single-character status mark inside a small badge and 9pt for a short auxiliary label under an icon when the usual caption does not fit. These sizes are not tied to a particular plugin. Keep the complete meaning available through accessibility and, for truncated labels, help text. Ordinary names, descriptions, controls, and metrics continue to use the regular roles and remain at least 10pt. Keep these compact sizes local to the renderer rather than adding a general-purpose tiny-text role.

Native settings use system foregrounds. Custom panel and widget content uses `pluginComponentTheme`: primary for necessary information, secondary for supporting text, tertiary only for optional context, and disabled for unavailable controls. Accent identifies interaction. Status colors identify actual success, warning, failure, or information and need accompanying text or symbols. Preserve category colors, provider artwork, and domain thresholds. Shared meanings do not require identical RGB values across surfaces.

## Content exceptions

Preserve screenshot annotations, captured pixels, editor content and syntax, rich text, user-selected Launchpad label styles, transient safety instructions, and menu-bar indicator geometry. Charts, calendars, and treemaps retain domain layouts and meaningful data colors. Their necessary labels still need readable defaults and accessible values. A content exception is not a reason to give surrounding buttons, descriptions, or status text an unrelated style.

## Verification

Review affected layouts in light and dark appearance, a representative custom panel theme, long Chinese and English text, common display scaling, and the supported window sizes. Check focus, disabled controls, empty/error states, and Increase Contrast where relevant. Semantic fonts alone do not provide a macOS-wide Dynamic Type feature.

Appearance changes do not need tests asserting fixed font sizes, colors, or spacing. Public API additions still need minimum-host inventory checks and frozen-client compatibility validation. See [development guidelines](development-guidelines.md#visual-and-interaction-design) and [contributing](../../CONTRIBUTING.md#validation).

Platform references: [Apple typography](https://developer.apple.com/design/human-interface-guidelines/typography) and [semantic color](https://developer.apple.com/design/human-interface-guidelines/color).
