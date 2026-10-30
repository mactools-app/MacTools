# Dynamic Island Hover Panel

`Plugins/NotchHoverPanel/` presents the regular MacTools menu-bar panel when the pointer rests in the blank menu-bar space immediately beside the Dynamic Island, or moves upward from directly below it toward the Dynamic Island. The plugin owns only hover detection, delays, and visibility ownership; the host owns panel content, sizing, positioning, and animation.

The side triggers use the screen's auxiliary top-left and top-right areas, so they remain limited to the menu-bar band and do not react to the rest of the menu bar. A third trigger spans the Dynamic Island width and extends below it by the configured vertical reach, which makes an upward approach from the content area reveal the panel. Mirrored secondary displays are ignored to avoid duplicate triggers. The panel is shown below the Dynamic Island and stays open while the pointer is inside the panel or the short corridor between the Dynamic Island and panel. It hides after the configured delay once the pointer leaves both regions.

Settings include enablement, menu-bar icon visibility, trigger width, lower trigger reach, show delay, and hide delay. Defaults are enabled, visible MacTools menu-bar icon, `52 pt` trigger width, `72 pt` lower reach, `0.18 s` show delay, and `0.28 s` hide delay. Users can hide the icon explicitly; saved visibility preferences remain unchanged on upgrade. A reset action restores those defaults. Preferences are stored locally under `notch-hover.*` keys. The plugin requests no permissions and makes no network requests.

Hiding the menu-bar icon only takes effect while the plugin is enabled and a display can host the hover trigger. Disabling, isolating, or removing the plugin restores the icon, and display hot-plugging also restores it when the last Dynamic Island-capable screen disconnects. Menu-bar-anchored panels fall back to a top-right screen anchor while the icon is hidden. Users can still reach the panel and settings by hovering the Dynamic Island.

The plugin uses the host's anchored menu-bar panel presentation API, so its package requires MacTools `2.2.0` or later.

## Build and Verification

Run `make generate`, then:

```sh
make build-plugin PLUGIN=NotchHoverPanel
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug \
  -derivedDataPath build/DerivedData test -quiet \
  -only-testing:MacToolsTests/NotchHoverPanelGeometryTests
```

Manual checks require a Mac display with a Dynamic Island: hover each side of it and confirm the panel slides out, move upward from directly below it and confirm it also appears, move into the panel and confirm it stays open, leave the panel and Dynamic Island area and confirm it hides after the delay, then adjust each slider and verify the change persists after relaunch. Also verify that opening a panel from the status item is not dismissed by the plugin.
