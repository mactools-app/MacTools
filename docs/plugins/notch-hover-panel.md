# Dynamic Island Hover Panel

`Plugins/NotchHoverPanel/` opens the regular MacTools menu-bar panel when the pointer rests over the Dynamic Island. In **Panel style**, **Dynamic Island** expands from the notch and contracts into it when it closes. **Classic** slides the original popover below the notch. Both styles are available on Macs with a notch and use the same hover area and delays. The plugin handles hover detection, delays, and which presentation it owns. The host handles panel content, positioning, and animation.

The default trigger matches the Dynamic Island. The side-reach setting extends the trigger into the adjacent menu-bar areas. When enabled, the lower trigger extends below the island by the configured lower reach. The panel stays open while the pointer is over the island or inside the panel. It hides after the configured delay once the pointer leaves both. Mirrored secondary displays are ignored.

By default the plugin and menu-bar icon are enabled, side reach and lower reach are both `0 pt`, the lower trigger is enabled, the show delay is `0.18 s`, and the hide delay is `0.28 s`. Existing preferences are preserved on upgrade. A reset restores the defaults. Preferences are stored locally under `notch-hover.*` keys. The plugin requests no permissions and makes no network requests.

Hiding the menu-bar icon only takes effect while the plugin is enabled and a display can host the hover trigger. Disabling, isolating, or removing the plugin restores the icon, and display hot-plugging also restores it when the last Dynamic Island-capable screen disconnects. Menu-bar-anchored panels fall back to a top-right screen anchor while the icon is hidden. Users can still reach the panel and settings by hovering the Dynamic Island.

The plugin uses the host's anchored menu-bar panel presentation API, so its package requires MacTools `2.2.0` or later.

## Build and Verification

Run the targeted tests.

```sh
make test TEST_FILTER="NotchHoverPanelGeometryTests NotchHoverPanelControllerTests MenuBarPanelMenuPresenterTests"
```

On a Mac display with a Dynamic Island, hover over the notch to open the panel. Move into the panel and check that it stays open, then move away to close it. Re-enter while it is closing and check that it reopens smoothly. With the default reach, hovering beside the notch or below it should leave the panel closed. Increase side and lower reach to check both optional trigger areas, then disable the lower trigger and check that direct hover still works. Open the panel from the status item and check that leaving the notch area does not close it.
