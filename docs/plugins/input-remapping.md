# Input Remapping Plugin

## Purpose

- User-facing name: Custom Shortcuts.
- Inputs: keyboard, mouse, scroll, precise Trackpad Gestures catalog.
- Outputs: shortcuts, side-aware single-key taps, mouse navigation, common macOS actions.

Single-key taps are atomic press/release pairs. Left and right Command, Shift,
Option, and Control remain distinct through their physical virtual key codes.
Generated events carry the shared MacTools synthetic-input marker so another
input plugin cannot remap them again, including when compatible plugin versions
are updated independently. Caps Lock is excluded because it requires persistent
toggle semantics rather than a momentary press/release pair. Media keys remain
separate system actions because macOS delivers them as system-defined events.

## Manifest

- ID: `input-remapping`.
- Settings layout: `workspace`.
- Permissions: Accessibility, Input Monitoring.
- `pluginKitVersion`: `7`.
- Minimum host: MacTools `2.2.5`.

## Shared trackpad gestures

- Trackpad Gestures owns the private multitouch listener.
- Input Remapping consumes the shared `TrackpadGestureEventConsuming` bridge.
- The last enabled mapping owns a gesture at runtime; conflicting mappings remain saved, inactive, and marked as already used by another plugin.
- External TipTap claims resolve their native click as consumed before dispatching the shortcut action.

## Validation

- `make build-plugin PLUGIN=input-remapping`
- `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -only-testing:MacToolsTests/InputRemappingModelsTests -quiet`
