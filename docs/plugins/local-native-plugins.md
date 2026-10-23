# MacTools Local Native Plugins

MacTools supports trusted local native plugins through a host-owned package store and a shared `MacToolsPluginKit.framework`.

Native plugins run in-process and must be trusted. When the host has a Team ID, plugin bundles must use the same Team ID. The host validates the plugin bundle signature before loading code. Disabling or uninstalling a plugin immediately removes its contributions from the UI and deletes package files when requested, while already-loaded native code is fully released after the app restarts.

For catalog-based installation, GitHub release distribution, and Debug `file://` development catalogs, see [plugin-catalog.md](plugin-catalog.md).

For a complete workspace-plugin example with a typed catalog, verified adapters, portable preferences, profiles, and composition of canonical actions from other providers, see [Mac Settings](mac-settings.md).

For a foreground capture plugin with native editing windows, host-owned permissions and shortcuts, local recognition, and capture-session cleanup, see [Screenshot](screenshot.md).

## Package Layout

Use a directory package with the `.mactoolsplugin` extension:

```text
Example.mactoolsplugin/
  plugin.json
  LICENSE                    # Required when the package is distributed independently
  THIRD_PARTY_NOTICES.txt    # Present only when third-party notices apply
  Example.bundle/
    Contents/
      Info.plist
      MacOS/Example
      Resources/
```

`plugin.json` is read before loading executable code:

The current source uses PluginKit v7 with a minimum host version of `1.3.1`. Rebuild packages for this ABI; older packages remain discoverable for updates but cannot load into the v7 host. Released v6 hosts retain their own catalog.

```json
{
  "id": "com.example.mactools.demo",
  "displayName": "Demo",
  "summary": "示例插件",
  "localizedMetadata": {
    "zh-Hans": {
      "displayName": "示例",
      "summary": "示例插件"
    },
    "en": {
      "displayName": "Demo",
      "summary": "Demo plugin"
    }
  },
  "version": "1.0.0",
  "minHostVersion": "1.3.1",
  "pluginKitVersion": 7,
  "bundleRelativePath": "Example.bundle",
  "factoryClass": "Example.ExamplePluginFactory",
  "capabilities": {
    "panelItems": ["row"],
    "settings": "form"
  },
  "permissions": [],
  "uninstallDataPolicy": "preserve",
  "category": "productivity"
}
```

`displayName` and `summary` are fallback marketplace metadata. Add `localizedMetadata` for every user-facing marketplace language the plugin supports. The host chooses the best match from the user's language preferences before the plugin bundle is loaded, but it does not own plugin translations.

`category` is optional and is used by the marketplace and "已安装" list to group plugins. Supported values: `display`, `audio`, `system`, `storage`, `productivity`, `monitoring`. Unknown or omitted values fall back to "其他".

`uninstallDataPolicy` defaults to `preserve`. Use `removePrivateData` only when uninstall must crypto-shred sensitive plugin data. The host then always shows a destructive-data warning, removes the plugin's host-owned support/cache/temporary directories and preferences, and deletes the standardized Keychain item identified by `PluginPrivateDataKeychainIdentity`; cleanup does not depend on loading plugin executable code.

If private-data cleanup fails, its recovery intent blocks a fresh installation of the same plugin until cleanup succeeds. A completed cleanup intent that only retains obsolete package residue does not block installation. This prevents a delayed uninstall retry from deleting the replacement installation's data.

The plugin bundle must expose a factory that conforms to `MacToolsPluginBundleFactory`. The factory returns a `PluginProvider`, and the provider returns exactly one `MacToolsPlugin` instance for the package.

Source repositories can keep implementation and tests beside each plugin:

```text
Plugins/Example/
  plugin.json
  Sources/              # Plugin implementation and feature code
  Bundle/               # Thin bundle entrypoint that anchors the factory
  Tests/                # Optional XCTest files
  project.yml           # Optional build overrides for non-default plugins
  Resources/            # Optional plugin resources
```

The runtime payload contains the projected `plugin.json` and the built `.bundle`. Bundle resources must therefore be copied into the built `.bundle` by the generated Xcode target. In this repository, `Plugins/<PluginName>/Resources` is automatically added to the generated bundle target, so plugin-owned `.xcstrings`, images, JSON files, and other runtime resources should live there. Official release packaging also copies the repository `LICENSE` into every independently distributed ZIP and generates a product-specific `THIRD_PARTY_NOTICES.txt` when required. These legal files are generated from central sources and are not maintained inside each plugin source directory. `Tests/` is included only by the host unit-test target during development and is never packaged into the app or plugin distribution.

In this repository, plugin Xcode targets are generated before XcodeGen runs. The generator scans `Plugins/*/plugin.json` and applies a shared target template for `Sources/`, `Bundle/`, `Tests/`, plugin schemes, and the host test target. Most plugins do not need any root project changes. Add `Plugins/<PluginName>/project.yml` only for plugin-local build differences such as `OTHER_LDFLAGS`, `SWIFT_INCLUDE_PATHS`, extra bundle resources, helper/tool targets, or additional target dependencies. A helper/tool target can declare `bundleResourcePath` to have the generated bundle target copy its built executable into `Contents/Resources/<bundleResourcePath>/`.

The manifest ID is the stable identity of the package. It must match the runtime `PluginMetadata.id`, and a package must return exactly one plugin instance. Use lower-case, readable IDs such as `display-brightness` unless there is a strong reason to use a reverse-DNS identifier. The ID `marketplace` is reserved for the host-owned URL route and is not a valid plugin ID.

The same source manifest may add optional product metadata for pre-install discovery, requirements, privacy, actions, setup, and plugin relationships. Follow [`plugin-manifest.schema.json`](plugin-manifest.schema.json); do not create a second marketplace metadata file. Declare localized product copy under the source-only `productStrings` table. Each entry either reuses `@displayName` or `@summary`, imports an existing `Resources/Localizable.xcstrings` key with `@localizable.<key>`, uses a standard localized toggle or enabled-state label with `@standardAction.<key>`, renders declared requirements with `@standardSetup.requirements.title` or `@standardSetup.requirements.description`, or supplies all 11 supported locale values; localized product fields uniformly reference `@productStrings.<key>`. Packaging and catalog generation expand the references and remove the source table before distribution. Keep screenshots under `MarketplaceAssets/`, and describe dynamic machine-local action entries with templates instead of enumerating local values. The catalog generator validates localization, identifiers, permission and surface values, references, domains, assets, and action completeness before projection.

When a plugin uses a private Apple framework, it must load that framework dynamically at runtime and validate every required class and selector before use. Do not add a static framework link: unsupported systems must present a clear plugin error instead of crashing.

## Development Steps

To add a plugin, create `Plugins/<PluginName>/plugin.json`, `Sources/`, and `Bundle/`. Add `Tests/` for core behavior or regressions not already covered; see the [validation policy](../../CONTRIBUTING.md#validation). Most plugins can then run directly with:

```bash
make run
```

Finder Sync, Share, Quick Look, and other macOS app extensions are host-level targets. A plugin may expose settings or status for that feature, but the extension target itself must be embedded by the main app through `project.yml`; it cannot be installed into Finder by a dynamic `.mactoolsplugin` bundle at runtime.

In Debug development, `make run` builds the main `MacTools` scheme, synchronizes the freshly built plugin bundles from `build/DerivedData/Build/Products/Debug` into `build/LocalPlugins/Packages`, generates `build/LocalPlugins/catalog.dev.json`, and updates `~/Library/Application Support/MacTools Dev/Plugins/Installed`. It then stages and verifies a rollback-safe replacement of `~/Applications/MacTools Dev.app` before launching that stable path. The installer refuses a replacement whose designated code-signing requirement differs from the previously installed app, preserving macOS permission grants across rebuilds. When that stable Debug app exists, Derived Data copies do not start the exclusive trackpad listener, and the generated XCTest action explicitly disables it for the test host. This prevents an old build or a lingering hosted test app from taking gesture input after the installed app restarts.

A full Debug sync mirrors the current checkout: packages missing from its local catalog are moved from `Installed` to the sibling `Quarantined` directory so packages left by another worktree cannot appear as incompatible. A filtered sync such as `make sync-debug-plugins PLUGIN=calendar` preserves unrelated installed packages.

Debug package copies normalize `minHostVersion` to the locally built app version because the host and plugin bundles come from the same checkout. Release packages preserve each source manifest's declared minimum host version.

Fallback compiles in `build-local-plugins.sh` reuse internal compiler workspaces under `~/Library/Caches/MacTools/PluginBuilds`. The cache separates source checkout, project/scheme, Xcode/SDK, host architecture, configuration, destination, signing mode and compiler flags. A lock covers compilation and copying bundles into packages. Each run retains its log and build record under `<output-dir>/BuildReports/`; packaged bundles remain under `<output-dir>/Packages` and do not depend on the compiler cache. Set `MACTOOLS_PLUGIN_FRESH_BUILD=1` for a separate cold workspace, `MACTOOLS_PLUGIN_CACHE_VARIANT` to isolate a probe, or `MACTOOLS_PLUGIN_CACHE_ROOT` for another internal root. Existing compiler output is preserved. Prebuilt packages and `--products-dir` aggregate products keep their existing packaging path.

If the plugin needs extra frameworks, private include paths, bundle resources, helper/tool targets, or target dependencies, add only those differences in `Plugins/<PluginName>/project.yml`. If the plugin package contains an extra executable inside the bundle resources, declare it in `plugin.json.package.signPaths` so release packaging signs it before signing the bundle.

Plugin UI copy should be localized by the plugin itself. Put plugin string catalogs under `Plugins/<PluginName>/Resources`, then look them up from the plugin bundle, for example:

```swift
private enum DemoL10n {
    static let strings = PluginLocalization(bundle: Bundle(for: DemoPluginFactory.self))

    static var title: String {
        strings.string("metadata.title", defaultValue: "示例")
    }
}
```

To build and resynchronize Debug plugin bundles without launching the app:

```bash
make sync-debug-plugins
```

To test the standalone plugin package build path, build its package and Debug catalog explicitly:

```bash
make build-plugin PLUGIN=<plugin directory or id>
make run
```

To update an existing plugin, change its code/resources/tests beside the plugin and run the focused build or tests before opening a PR. Do not bump `plugin.json.version` in a normal feature PR. The standard `make release` flow detects package-relevant changes, automatically bumps affected manifests, and records those updates in the plugin release commit.

When a change touches `Sources/MacToolsPluginKit/`, it is package-relevant for every plugin. `make release` automatically selects and bumps every affected manifest so all plugin packages are rebuilt against the same PluginKit build. A manual version bump is needed only when bypassing `make release` and using the lower-level release workflow directly.

## Panel Widgets and Runtime Ownership

Users can remove every widget or add multiple copies of the same plugin. A widget is a presentation entry, not a new plugin instance: installation, activation, shortcuts, and independently enabled background services remain plugin-owned.

Declare multiple named views with `MacToolsPlugin.panelItems`; see [Panel items](panel-items.md) for IDs, renderer types, defaults, and migration. Use each item’s `onVisibilityChange` for work required by the presented panel. Copies of the same item share one visibility transition, while distinct items are separate consumers. Switching panels containing the same item does not restart its work.

Component views are mounted near the scroll viewport and can be recycled. Keep durable selection state and business tasks in a plugin-owned model; reserve view-local state for transient interaction. Do not start polling or refresh business data from each copy's `onAppear`. Library previews receive `PluginPanelWidgetContext.isPreview == true`: they must not acquire foreground consumers or change live layout measurements. That context distinguishes preview creation from live content; lifecycle callbacks are the authority for subsequent panel visibility changes.

## Settings UI

Plugin settings are hosted by MacTools. PluginKit 7 exposes one `settingsPage` entry point with two explicit layouts:

- `PluginSettingsPage.form` is the default. Describe standard controls with `PluginSettingsSection`, `PluginSettingsRow`, and `PluginSettingsControl`; the host renders the native grouped form, search entries, validation, permissions, and shortcuts.
- Reserve segmented pickers for a few short labels; use `.menu` when options are longer or localization can make the row overflow. Declarative sliders should provide `valueFormat` for a live host-rendered readout. Custom settings use `PluginSettingsSlider` to keep stepped values without drawing dense tick marks.
- A form may contain a custom section for a complex list, chart, drag and drop editor, or manager while retaining the host-owned page shell and surrounding native sections.
- `PluginSettingsPage.workspace` is reserved for a task-oriented full settings surface such as a cleanup browser or configuration editor. Declare `scrolling: .host` for a simple long page and `.selfManaged` for split views, lists, or editors. The host still owns navigation, header, permissions, shortcuts, background, and lifetime.
- Use `.onVisibilityChange` for work that belongs to the whole settings page, such as starting observation or stopping a test session. Do not attach page lifetime work to custom section `onAppear`/`onDisappear`; grouped Form sections are lazy and may be recycled while the page is still visible.
- Use `permissionRequirements` for system permission rows and `shortcutDefinitions` for shortcut rows. A form places a shortcut group with `PluginSettingsSection.shortcutGroup`; a custom section that renders a group itself declares `embeddedShortcutGroupIDs`.

The manifest must declare the matching `capabilities.settings` value: `none`, `form`, or `workspace`. The host does not read an undeclared page and rejects a runtime layout that differs from the manifest. This capability is an ABI contract, not a styling preference.

Settings changes use typed `PluginSettingsAction` values (`setBoolean`, `setSelection`, `setNumber`, `setText`, and `invoke`) instead of string-only callbacks. Text and numeric controls distinguish `.changed` from `.committed`, allowing live updates without rebuilding the entire settings hierarchy for every keystroke or slider tick.

Custom sections and workspaces provide only plugin-specific content. The settings window title, plugin icon, description, permission cards, shortcut cards, scrolling shell, and system background are derived by the host; do not repeat a page title inside custom content. Form sections must not draw their own outer card or section header: use `presentation: .standard` for normal custom content, or `.edgeToEdge` for an AppKit table or an internally padded row collection. Add/Refresh-style actions belong in `.headerAccessory`.

All custom settings views should use `MacToolsPluginKit.PluginSettingsTheme` for typography, spacing, radii, colors, and shared card backgrounds. This keeps the dependency direction clean: the host app and plugins both depend on `MacToolsPluginKit`, while plugins never depend on `Sources/App/SettingsStyle.swift`.

Use `PluginSettingsItem` (host 1.3.1+) for an icon, title, optional description, and trailing custom control. It shares the host form row layout and neutral icon styling. The containing form or custom section still owns padding and separators; use `pluginSettingsListRowPadding` for internally padded sections.

Use the shared typography, spacing, control, and container rules in [Plugin development standards](development-guidelines.md#visual-and-interaction-design). Extend `PluginSettingsTheme` when a shared token is missing instead of copying a local style enum.

### Unified Search

MacTools automatically indexes visible declarative row titles, descriptions, keywords and picker options, plus permission and shortcut rows. Current text-field and secure-field values are never indexed. Custom sections and workspaces can expose individual destinations by conforming to `PluginSettingsSearchProviding`; apply `pluginSettingsSearchAnchor(pluginID:entryID:)` to the matching control so selecting a result scrolls to, highlights, and exposes accessibility focus.

Actions are never inferred from panel buttons. `PluginCommandProviding` remains available for existing legacy commands; new executable capabilities use the canonical action API below. Actions requiring a decision must declare confirmation metadata and preserve their complete safety flow.

## Actions and shortcuts

New executable capabilities should use `PluginActionProviding` rather than adding new legacy commands or shortcut-owned callbacks. Publish stable `ActionKey` values, versioned parameter schemas, availability snapshots, risk/confirmation policy, external-invocation policy, execution capabilities, and bounded timeouts. If discovery surfaces should name system permissions before execution, also implement `PluginActionPermissionProviding` and map each action to IDs declared by `permissionRequirements`.

Host-owned system integrations may additionally consult the optional `PluginActionExposureProviding` contract. `.excluded` is a provider veto; `.automatic` delegates to the host's conservative eligibility checks and does not bypass risk, availability, permission, parameter, or foreground requirements. Unknown surfaces and provider failures must fail closed, and exposure is revalidated at execution time. Keep `externalInvocationPolicy` separate because it governs Run Links rather than general system discovery.

If an action executes mutable provider-owned content that is not represented by its `ActionDefinition` or catalog entry, also implement `PluginActionExecutionRevisionProviding`. Advance the revision after every successful persisted mutation. The host snapshots and revalidates it around confirmation so a user never approves one payload and executes another.

Treat action execution capabilities as explicit safety contracts. Add `.automatic` only when the action can run unattended without confirmation or foreground UI; `.background` alone does not permit automatic rules. Choose an `ActionConcurrencyPolicy` for overlap-sensitive actions (`.rejectWhileRunning` is the safe default, `.serialize` queues, and `.allowConcurrent` is opt-in). `beginAction` must validate and return an `ActionExecutionHandle` promptly; move substantive work into the handle operation. Every action has a host-enforced deadline, while `.cancellable` additionally authorizes the host to invoke the provider cancellation callback.

Ordinary action shortcuts are owned by the host's `ShortcutAssignmentService`. A plugin may declare or migrate a default binding, but it must not persist or register a second binding for the same action. Workflows, Run Links, and Action Grid also retain `ActionReference` values and invoke through the host executor. See [Actions, Automation, Run Links, and Action Grid](../actions-automation.md) for the ownership and verification contract.

The current migration coverage, intentional exclusions, and design-first backlog are tracked in [Canonical action provider coverage](action-provider-coverage.md). Consult that inventory before adding a new plugin-only command or shortcut so reusable operations remain available consistently across shortcuts, gestures, Action Grid, Automation, Unified Search, and eligible Run Links.

Action Grid is the reference implementation for an optional action surface. Its package can be built independently with:

```bash
make build-plugin PLUGIN=ActionGrid
```

## Install Location

Installed plugins are copied into:

```text
~/Library/Application Support/MacTools/Plugins/
  Installed/
  Staging/
  Data/
  Caches/
  Temporary/
```

Debug builds use a separate application identity and storage root:

```text
~/Library/Application Support/MacTools Dev/Plugins/
```

Install and update are staged before moving into `Installed`. Per-plugin runtime context includes scoped `UserDefaults` storage plus support, cache, temporary, and bundle resource locations.

## Security Model

- Only local package directories ending in `.mactoolsplugin` are accepted.
- The manifest ID, versions, and bundle relative path are validated before loading code.
- Host version and plugin kit version are checked before loading code.
- Installed packages built for an older PluginKit are kept on disk but marked incompatible and are never passed to the native bundle loader.
- Public value types within one PluginKit version must preserve their stored binary layout. CI compiles the independent frozen v7 client in `scripts/fixtures/plugin-kit-v7/` and links it against the current framework to catch binary incompatibility that source-only tests can miss. See [Panel items](panel-items.md#compact-icon-controls) for the pre-release baseline.
- The plugin bundle signature is validated before loading code.
- When the host has a Team ID, the plugin bundle must have the same Team ID.
- Untrusted third-party native plugins should use a future isolated process or XPC model instead of in-process bundle loading.

## Lifecycle

Plugins can implement:

```swift
func activate(context: PluginRuntimeContext)
func deactivate(reason: PluginDeactivationReason)
```

`deactivate` is called before updating, uninstalling, and host shutdown. It can also be called when the host isolates a plugin after a runtime failure or when an installed package is no longer loadable. Plugins should cancel tasks, timers, observers, event taps, windows, and other retained system resources there.

Native bundle code is treated as loaded for the lifetime of the current app process. If a loaded plugin is updated or uninstalled, its contributions are removed from MacTools immediately and `deactivate` is called, but the executable code is considered fully released only after the app restarts. Updating a loaded plugin replaces the package files on disk and activates the new code on the next launch.

## Pointer-intercepting plugins

Plugins using a `CGEvent` tap declare `accessibility` in the manifest and expose a matching `PluginPermissionRequirement`. Start only after authorization, stop and invalidate the tap during deactivation, and re-enable it after `.tapDisabledByTimeout` or `.tapDisabledByUserInput`. Keep callback work bounded; never perform I/O, scans, or blocking operations there.

## Palette text input

A provider can additionally adopt `PluginActionInputProviding` to expose one required string input through host-owned composition and optional explicit aliases. Declare an existing canonical action with a sensitive, local-only string parameter, then publish an `ActionInputDescriptor`. The host keeps these incomplete descriptors separate from executable catalog references. After preparation and validation, it assembles the complete reference and uses the normal action executor.

Preparation returns an ephemeral `ActionInputSession`; it must not send input or create a conversation. The host releases unsubmitted sessions when composition ends and transfers accepted sessions to execution completion. Other surfaces do not implicitly gain input forms or expose aliases. Use the first host version exporting these new types as the plugin's minimum host version.

Aliases must be unambiguous at a space boundary. `ask siri <message>` is the first implementation. An alias recognizes an action; it never executes merely because text was entered. Plugins do not parse the raw query themselves.
