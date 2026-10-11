# Floating palette appearance

Command Palette and Clipboard History use `PluginPaletteSurface` from PluginKit. Clipboard History's action and queue companion palettes use the same surface. Window Layouts feedback, Auto Input's input-source HUD, the modifier-drag HUD, and Clipboard privacy feedback use the underlying `PluginFloatingPanelSurface`. The menu-bar panel uses its own component theme.

## Ownership and rendering

- `PluginFloatingPanelSurface` owns the shared floating-panel background and supports rounded rectangles and capsules. The API requires host 2.0.1. `PluginPaletteSurface` retains its existing public interface as the palette-specific wrapper. `PluginPaletteColors.selectedText` requires host 1.3.1.
- On macOS 26 and later, the background bridges AppKit's `NSGlassEffectView` into SwiftUI with regular style. Hosted content remains outside the background so drag handles, native input, and view identity are preserved.
- The host exposes Follow macOS and Solid appearances. Follow macOS leaves the native Liquid Glass appearance to AppKit; Solid uses the semantic window background. The menu-bar color-theme system remains separate.
- Reduce Transparency always selects the opaque semantic background, regardless of the app preference. Older supported macOS versions use native material for Follow macOS. Increase Contrast strengthens palette, selected-row, control, and image-preview boundaries. Selection text preserves the system's preferred foreground when it meets 4.5:1 contrast against the opaque selection background; otherwise it uses black or white. This also protects yellow accents, selected subtitles, and shortcut labels. Colors resolve again for the current appearance.
- Command Palette clips its backdrop to the visible rounded silhouette and applies one shared content shadow in both Settings and standalone presentations. The standalone panel uses a plain AppKit hosting container, disables automatic SwiftUI safe-area/sizing behavior, and has no second window shadow around its transparent padding. Clipboard keeps its existing hosting and native shadow.
- The host retains Command Palette routing, focus restoration, drag/snap coordination, and placement. Clipboard History retains its panel lifetime, explicit drag handle, native resizing, per-display placement, search model, previews, and action routing. Glass never tints captured previews or changes clipboard payloads.

Apple references: [custom SwiftUI glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), [macOS 27 AppKit design updates](https://developer.apple.com/videos/play/wwdc2026/289/).

## Search headers and icon controls

- Command Palette, Clipboard History, clipboard actions, and Window Switcher share a 36-point search header. Window Switcher's expandable inline field retains its compact 32-point layout.
- `PluginPaletteSearchChrome` applies search spacing, a neutral semantic fill, and a subtle focus-fill change without replacing the native text field or its input-method handling. Pass the field's accessibility identifier and current Increase Contrast state. Custom AppKit headers use `PluginPaletteChrome` colors and the same metrics. Both APIs require host 1.3.1.
- Search text uses the regular system font. Keep the magnifying glass, placeholder, clear action, and insertion caret recognizable. Clear buttons retain a 24-point hit target. Preserve each panel's original controls: style existing close buttons consistently, but do not add one solely to match another panel's layout.
- `PluginPaletteToolbarControlStyle` has no permanent border or fill in the standard appearance. Hover and press use neutral fills; disabled controls do not react. Native AppKit icon controls use inline bezels with mouse-over borders. Increase Contrast restores search and SwiftUI control outlines, while native controls follow the system accessibility appearance.
- Preserve existing search commands, IME composition, focus restoration, and the distinction between clearing a query, collapsing inline search, and dismissing a panel.

## Validation

Palette appearance and native interaction are checked manually. Automated screenshot capture, native pointer injection, and UI XCTest fixtures have been removed from the routine suite. Keep logic coverage in the command/search models, action executor, and clipboard controllers; see the [core test scope](../testing/core-tests.md).

For changes to this surface, exercise only the affected paths:

- Open the palette, type a query with ordinary text and IME composition, execute or cancel, and reopen.
- Check focus, dragging, resizing, and display placement when those behaviors change.
- Review Follow macOS and Solid in light/dark appearance, Reduce Transparency, and Increase Contrast when changing material or colors. Use representative backgrounds and content rather than a screenshot matrix.
- For performance work, compare the same workload on equivalent builds and record the OS, settings, and observations. Avoid fixed wall-clock thresholds in XCTest.

Attach a representative screenshot or short recording to the review. Use `make ci` before pushing shared PluginKit changes; compile-time compatibility does not replace native acceptance on affected macOS versions.
