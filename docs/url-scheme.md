# URL scheme and Run Links

MacTools exposes a guarded URL API for navigation and explicitly eligible Run Links used by shortcuts, launchers, scripts, and links from other apps.

- Release app: `mactools://`
- Debug app: `mactools-dev://`
- Nightly app: `mactools-nightly://`

The three schemes route to the matching installation. Stable, development, and Nightly builds can coexist without one build intercepting another build's links.

## Navigation routes

| Destination | Release URL |
| --- | --- |
| Settings | `mactools://app/settings` |
| General settings | `mactools://app/settings/general` |
| Permissions | `mactools://app/settings/permissions` |
| About | `mactools://app/settings/about` |
| Actions & Shortcuts | `mactools://app/settings/features/actions-and-shortcuts` |
| Automation | `mactools://app/settings/features/automation` |
| Plugin Marketplace | `mactools://app/settings/plugins/marketplace` |
| Starter pack chooser | `mactools://app/settings/starter-packs` |
| Everyday Essentials review | `mactools://app/settings/starter-packs/everyday` |
| Windows & Workspace review | `mactools://app/settings/starter-packs/windows` |
| Writing & Clipboard review | `mactools://app/settings/starter-packs/writing` |
| Meetings & Presentations review | `mactools://app/settings/starter-packs/meetings` |
| Displays & Desk review | `mactools://app/settings/starter-packs/displays` |
| Developer Tools review | `mactools://app/settings/starter-packs/developer` |
| Storage & Maintenance review | `mactools://app/settings/starter-packs/maintenance` |
| Marketplace plugin details | `mactools://app/settings/plugins/marketplace/<plugin-id>` |
| Marketplace static-action details | `mactools://app/settings/plugins/marketplace/<plugin-id>?provider=<provider-id>&action=<action-id>` |
| Installed plugin settings | `mactools://app/settings/plugins/<plugin-id>` |
| Dashboard | `mactools://app/panels/dashboard` |
| Feature Panel | `mactools://app/panels/feature` |
| Unified search | `mactools://app/search` |

Starter pack links open the chooser or the specified pack's review without installing plugins, changing a layout, assigning shortcuts, or granting permissions. Users confirm the setup in MacTools. Known pack IDs are `everyday`, `windows`, `writing`, `meetings`, `displays`, `developer`, and `maintenance`; unknown IDs and all query parameters are rejected. A first link replaces the untouched first-run suggestion; later links add to the current selection without clearing individual exclusions. If a pack is currently installing, another pack link shows its existing progress instead of replacing the active setup.

For example:

```bash
open 'mactools://app/settings/plugins/fan-control'
open 'mactools://app/settings/plugins/marketplace/fan-control?provider=fan-control&action=set-speed'
open 'mactools://app/panels/dashboard'
open 'mactools://app/search'
open 'mactools://app/settings/starter-packs/windows'
```

Use the stable ID from the plugin's `plugin.json` for `<plugin-id>`. The ID `marketplace` is reserved for the host-owned Marketplace route and cannot be used by a plugin. A plugin settings link is accepted only when that plugin is installed, loaded, and provides settings. Dashboard and Feature Panel links always use show/focus behavior, so opening the same link again does not toggle the panel closed.

Marketplace detail links are navigation-only. They can refer to an available or installed catalog entry, but never install a package or execute an action. Cold-launch links load the catalog before deciding availability, with Retry after a loading failure. Installed details remain usable offline. `provider` and `action` are accepted only as a pair and must identify a catalog-published static action for that plugin. Duplicate, partial, or malformed values are rejected; unresolved plugin or action targets show an unavailable page after catalog resolution.

## Run Links

| Reference | Release URL |
| --- | --- |
| Eligible parameterless action | `mactools://app/actions/<provider-id>/<action-id>` |
| Saved parameter preset | `mactools://app/presets/<preset-uuid>` |

Only actions explicitly published to the shared action catalog and permitted by their provider receive Run Links. Direct action routes are parameterless and use stable, non-localized provider and action IDs. They never accept query parameters or infer actions from UI controls, shortcut IDs, or legacy commands.

Parameterized actions use a host-owned, versioned preset. The public URL contains only an opaque UUID; parameters, paths, device identifiers, selected content, and secrets are never placed in the link. Presets containing sensitive parameters are rejected. Presets remain local unless the Saved Run Links category is selected for a preferences backup and every referenced action is portable; eligible presets then retain their identifiers across restore. Presets become invalid after explicit deletion and remain stored when a provider is temporarily missing so they can recover after reinstall or re-enable.

Every accepted Run Link resolves an `ActionReference` and runs through the same `ActionExecutor` as Unified Search, global shortcuts, workflows, and Action Grid. Availability, schema migration, parameter validation, permissions, confirmation, execution mode, cancellation, timeout, provider-generation revalidation, and recursion checks are applied at execution time. Results appear in a non-activating MacTools HUD without requiring notification permission.

Mixed navigation and action links share one ordered cold-launch queue. The queue is bounded, action delivery is serialized, and a recursively delivered identical action request is rejected.

## Compatibility

Published routes are a backward-compatible product interface and are independent of the MacTools app version. New routes and optional navigation parameters may be added, but an existing route will keep its meaning. Unique unknown navigation query parameters are ignored except for Marketplace-detail links, which accept only paired `provider` and `action` highlight parameters, and starter-pack links, which accept no query parameters. Duplicate parameter names and all action-route query parameters are rejected, as are malformed or unavailable destinations.

The URL namespace has no global version. If a future feature needs an incompatible structured payload, that feature will use a dedicated `formatVersion` or `protocolVersion` parameter.

## Security

Any local process or website can invoke a custom URL scheme, so every URL is treated as untrusted input. The API does not expose plugin controls, settings action IDs, shortcut IDs, raw panel actions, shell text, arbitrary app paths, or unrestricted parameters. Command-shaped paths such as `/app/plugins/<plugin-id>/commands/<command-id>` are not supported.

The parser enforces the exact scheme and `app` authority, a 4 KiB limit, strict path-component decoding, and rejection of traversal, encoded separators, control characters, fragments, user info, ports, malformed queries, and duplicate parameters. The router records only bounded diagnostic codes and route shapes; it never logs the complete URL or query values.

Do not put secrets in URL parameters.

## Finder Sync compatibility

The existing `mactools://right-click/...` namespace is reserved for the bundled Finder Sync extension and remains backward-compatible. It is separate from the public `app` namespace; individual plugins must not register their own URL schemes.
