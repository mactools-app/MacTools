# MacTools Plugin Catalog

MacTools dynamic plugins use one catalog-driven flow for both production distribution and local development.

- PluginKit 2 production builds read the legacy `catalog.json` URL. PluginKit 3 and later builds read versioned URLs. MacTools through 1.1.6 remains on the immutable PluginKit v4 catalog at `v4/catalog.json`; MacTools 1.2.0 remains on the PluginKit v5/schema-2 catalog at `v5/catalog.json`; Released PluginKit v6 builds retain `v6/catalog.json`; the current source uses PluginKit v7/schema 3 at `v7/catalog.json`.
- Each catalog contains packages for one PluginKit ABI line. The legacy v2 catalog is kept unchanged when a new ABI is released, so older app builds continue to work.
- `minimumHostVersion` at the catalog root is the oldest host that can parse that catalog schema. Each entry declares its own install requirement; older hosts keep the catalog available and show newer entries as incompatible instead of rejecting the whole marketplace.
- Local development reads a Debug-only `file://` catalog, usually configured with `MACTOOLS_PLUGIN_CATALOG_URL`.
- Both flows resolve catalog entries into local staged packages, verify checksum and manifest compatibility, then install through the same package store. The marketplace can update one plugin at a time or run a batch update for every currently updateable plugin.

## Catalog format

```json
{
  "schemaVersion": 3,
  "catalogID": "com.ggbond.mactools.plugins",
  "generatedAt": "2026-05-16T12:00:00Z",
  "minimumHostVersion": "1.2.1",
  "pluginKitVersion": 7,
  "plugins": [
    {
      "id": "com.ggbond.mactools.demo",
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
      "minimumHostVersion": "1.3.1",
      "pluginKitVersion": 7,
      "capabilities": {
        "panelItems": ["row"],
        "settings": "form"
      },
      "permissions": [],
      "package": {
        "url": "https://github.com/ggbond268/MacTools/releases/download/plugins-1.0.1/Demo.mactoolsplugin.zip",
        "sha256": "...",
        "size": 1234567
      },
      "releaseNotesURL": "https://github.com/ggbond268/MacTools/releases/tag/plugins-1.0.1",
      "category": "productivity",
      "releaseChannel": "beta"
    }
  ],
  "revoked": [],
  "signature": {
    "algorithm": "ed25519",
    "value": "..."
  }
}
```

`localizedMetadata` is copied from each plugin manifest and is used by the marketplace before the plugin bundle is loaded. `displayName` and `summary` remain required fallbacks for older hosts and incomplete translations.

Catalog schema 2 follows PluginKit 4 and later manifests: `capabilities.settings` is `none`, `form`, or `workspace`. Schema 1 and its boolean `configuration` capability remain in older ABI catalogs and are not rewritten. A newer host may decode an installed package from an older ABI only far enough to identify and update it; it never loads or renders an incompatible settings API.

Catalog schema 3 is additive. It preserves every schema-2 package field and may also project `presentation`, `discovery`, `requirements`, `privacy`, `actions`, `setup`, and `relationships` from the checked-in source manifest. Schema-3 hosts accept both schema 2 and schema 3, so existing sparse catalogs and caches continue to work. The schema-3 catalog keeps its schema parsing floor of 1.2.1. PluginKit v7 entries require MacTools 1.3.1 or later and use a separate v7 endpoint. Released v4, v5, and v6 endpoints remain unchanged. The catalog signature covers every enriched field.

## Product and Capability Metadata

`Plugins/<PluginName>/plugin.json` is the only checked-in metadata source. Do not add a parallel marketplace manifest. The optional product sections are ignored safely by package loaders that only need the runtime envelope and are validated by the catalog generator:

- `presentation`: localized long description and examples, screenshot references, documentation and support URLs, publisher, and license.
- `discovery`: keywords, localized synonyms, use cases, goal categories, related plugins, and genuine alternatives.
- `requirements`: macOS, architecture, hardware, application, executable, permission, setup-complexity, and relaunch requirements.
- `privacy`: observed and persisted data, retention, network use and domains, telemetry, sensitive-content processing, and diagnostic-export disclosure.
- `actions`: static descriptors, dynamic templates, parameters, permissions, risk, supported surfaces, automatic eligibility, and external-invocation policy.
- `setup`: localized first-use steps, a suggested static test action, optional next surfaces, and missing-dependency help.
- `relationships`: related plugins, packs, recipes, and superseded plugin IDs.

### Localization

Localized product copy is declared once in the source-only `productStrings` table. Each entry either contains `ar`, `de`, `en`, `es`, `fr`, `ja`, `ko`, `pt`, `ru`, `tr`, `zh-Hans`, and `zh-Hant`, reuses the plugin's complete localized metadata with `@displayName` or `@summary`, imports an existing `Resources/Localizable.xcstrings` entry with `@localizable.<key>`, uses a standard `@standardAction.toggle.*` or `@standardAction.set-enabled.*` label, or renders declared permission, hardware, application, and executable requirements with `@standardSetup.requirements.*`. Every localized field in `presentation`, `discovery`, `privacy`, `actions`, and `setup` references `@productStrings.<key>`; inline locale objects and direct base references are rejected. Validation expands these references before package and catalog projection, rejects missing and unused entries, and removes `productStrings` from generated artifacts. Every repository plugin follows this source shape, while `Appearance`, `AppVolume`, `IPOverview`, and `WindowSwitcher` remain useful examples of fully hand-authored entries rather than inherited baseline copy.

```json
{
  "productStrings": {
    "display-name": "@displayName",
    "summary": "@summary",
    "long-description": {
      "ar": "…",
      "de": "…",
      "en": "Detailed product copy",
      "es": "…",
      "fr": "…",
      "ja": "…",
      "ko": "…",
      "pt": "…",
      "ru": "…",
      "zh-Hans": "…",
      "zh-Hant": "…"
    }
  },
  "presentation": {
    "longDescription": "@productStrings.long-description"
  }
}
```

### Action metadata

Static action entries describe fixed runtime `ActionDefinition` identities. Dynamic templates describe machine-local entries without putting local application IDs, devices, paths, or other discovered values in the signed catalog. A provider declares `static`, `dynamic`, or `mixed` and must populate the matching collections. `automatic-rule` is valid only for safe automatic actions, while `app-intent` additionally requires portable identity and parameters. External invocation is `unavailable`, `allowed`, `confirmAlways`, or `configurable` when each generated action owns the setting. A dynamic template whose generated entries can differ in risk or automatic eligibility declares `riskVariesByEntry` or `automaticEligibilityVariesByEntry`; its surfaces are the complete set that any generated entry may support, while fixed fields remain exact. Repository-wide XCTest coverage compares static identities and dynamic families, fixed and variable safety policy, external policy, supported surfaces, permissions, system images, and parameter policy against runtime definitions and focused dynamic-provider fixtures.

### Screenshots

Screenshot sources live under `Plugins/<PluginName>/MarketplaceAssets/`. The generator rejects traversal, missing or unsupported files, files over 10 MiB, and images over 7680 pixels per dimension. It adds media type, size, dimensions where available, and SHA-256 to the signed projection. Asset bytes are never embedded in `plugin.json`.

## Website projection

The public Astro site is generated from the same validated `Plugins/*/plugin.json` source manifests and their repository-local `Resources/Localizable.xcstrings` references; it does not fetch a production catalog while building. Run `cd site && npm run generate:plugins` after changing a manifest, referenced localization string, or Marketplace asset; commit `site/src/generated/*.json` and any checksum-named files under `site/public/generated/plugin-assets/`. `npm run check:generated-plugins` fails when JSON or expected assets are stale, missing, or orphaned. Plugin pages use `mactools://app/settings/plugins/marketplace/<plugin-id>` links, and static-action pages add a paired `provider` and `action` highlight; neither link installs or executes an action.

## Verification and release order

Release catalogs must include an Ed25519 signature. Debug local catalogs may omit `signature`, but they still go through package checksum, manifest, staging, and same-team code signature validation. Catalog verification validates every entry's identity and PluginKit ABI without requiring every package to support the current host. Package installation and loading continue to enforce the entry's `minimumHostVersion` strictly.

For an app version that switches to a new production catalog URL, release order is enforced: publish the compatible plugin batch first, wait for Pages to deploy the committed signed catalog, then prepare and publish the app. `scripts/plugins/preflight-app-plugin-catalog.swift` checks that the production URL returns the same nonempty, signed PluginKit catalog committed in the release ref. It also prevents this schema-3 source from being released with the already-shipped 1.2.0 version number. Both `scripts/release.py --type app` and the final app release workflow run this preflight, so the app cannot be published while its catalog is missing, stale, unsigned, or invalid.

## Versioned Catalog URLs

The catalog URL is selected by the host's supported PluginKit and catalog-schema version. In particular, MacTools 1.2.0 remains on the v5/schema-2 endpoint, while MacTools 1.3.0 uses PluginKit v6/schema 3:

```text
PluginKit 2 -> https://mactools.ggbond.app/plugins/catalog.json
PluginKit 3 -> https://mactools.ggbond.app/plugins/v3/catalog.json
PluginKit 4 -> https://mactools.ggbond.app/plugins/v4/catalog.json
PluginKit 5 / schema 2 -> https://mactools.ggbond.app/plugins/v5/catalog.json
PluginKit 6 / schema 3 -> https://mactools.ggbond.app/plugins/v6/catalog.json
PluginKit 7 / schema 3 -> https://mactools.ggbond.app/plugins/v7/catalog.json
PluginKit N -> https://mactools.ggbond.app/plugins/vN/catalog.json
```

The first release for a new PluginKit or catalog-schema compatibility line uses the previous catalog only as a comparison baseline. It publishes a complete catalog containing every rebuilt plugin under the new path. Later releases on that compatibility line may use incremental merges. Legacy PluginKit lines below v5 are immutable and the schema-3 release workflow rejects attempts to republish them. Never overwrite a catalog consumed by hosts that cannot parse the new schema.

## Local Development

The default local workflow is convention based:

```text
MacTools/
  Plugins/
    Demo/
      plugin.json
      Sources/
      Bundle/
      Tests/
```

External plugin repositories can use the same structure, as long as the manifest can resolve either a buildable project or a prebuilt bundle:

```text
MacToolsPlugins/
  Demo/
    plugin.json
    Sources/
    Bundle/
    Tests/
```

`plugin.json` declares the plugin ID, version, capabilities, bundle path, optional `releaseChannel`, license, and build scheme. In this repository `make generate`, `make build`, `make run`, and `make build-plugin` first scan `Plugins/*/plugin.json` and generate the local XcodeGen plugin targets. External repositories may provide their own `project.yml`, `.xcodeproj`, or the declared bundle directory. The package projection removes the source-only `build` section while retaining the runtime envelope, signing paths, and optional product metadata. The runtime payload contains that projected `plugin.json` and the signed `.bundle`; extra executables must already be copied into the bundle resources and listed in `plugin.json.package.signPaths` when they require an individual code signature. Official release packaging then adds the root GPL license and any product-specific third-party notices before the ZIP checksum and signed catalog entry are generated.

Current source and packaged manifests are validated against the complete runtime envelope before package copy or catalog projection. Source manifests use `productStrings` references; package manifests must contain the expanded projection and must match the source metadata when the source is available. A valid package can still generate a local catalog when its source repository is unavailable, in which case its projected manifest is authoritative. Legacy manifests must retain runtime-decodable `capabilities` and `permissions`, including the PluginKit v3 `capabilities.configuration` form; omitting newer product fields is accepted only below PluginKit 5 through the explicit `--allow-sparse-legacy` local-debug compatibility path. Release catalog generation rejects this mode.

From the MacTools repository, build all local plugins and generate the Debug catalog:

```bash
make build-plugin
```

Or build one plugin by directory name or plugin ID:

```bash
make build-plugin PLUGIN=Demo
make build-plugin PLUGIN=com.example.mactools.demo
```

Generated output lives under:

```text
build/LocalPlugins/
  Packages/*.mactoolsplugin
  catalog.dev.json
```

Then run MacTools:

```bash
make run
```

`make run` stages and verifies the latest Debug bundle at `~/Applications/MacTools Dev.app` with rollback on failure, then starts that installed executable directly so the catalog environment variable reaches the app process. If `MACTOOLS_PLUGIN_CATALOG_URL` is not already set and `build/LocalPlugins/catalog.dev.json` exists, Make uses that file automatically. Use `make install-debug-app` when the stable bundle should be updated without launching it.

You can override the fixed directories:

```bash
make build-plugin LOCAL_PLUGIN_SOURCE_DIR=/path/to/plugins LOCAL_PLUGIN_BUILD_DIR=/path/to/build
make run MACTOOLS_PLUGIN_CATALOG_URL=file:///path/to/catalog.dev.json
```

For Debug runs, the catalog URL scheme selects the verification mode. A `file://` URL uses the local development catalog policy, where signatures are optional. An `https://` URL uses the production catalog policy, where the catalog signature is required:

```bash
make run MACTOOLS_PLUGIN_CATALOG_URL=https://mactools.ggbond.app/plugins/v7/catalog.json
```

The app copies the package into its own staging and installed directories. Uninstall deletes only the installed copy under MacTools application support; it never deletes the plugin source directory or the local build directory.

## Public Nightly Catalog

The public Nightly channel publishes a separate, signed catalog under `docs/nightly/plugins/vN/catalog.json`. It never modifies or merges into the stable `docs/plugins/vN/catalog.json` catalog.

Each publishing Nightly workflow run performs one aggregate `Nightly` app build, then passes that build's products directory to `build-plugin-release-assets.sh --products-dir`. Every plugin package and the host app therefore come from the same source commit. The workflow publishes a complete catalog rather than an incremental delta. An early step in the same job skips scheduled publication if the selected source tree matches the source of the deployed Nightly appcast, excluding `docs/nightly/**`. Other repository changes are conservatively treated as relevant. Manual dispatch always publishes; an unavailable previous source or failed comparison also proceeds normally. No additional tracking files or commits are needed for this check.

Nightly package versions are generated artifacts using `source-major.run.attempt`, where `source-major` comes from the plugin's committed manifest and `run.attempt` comes from the producing GitHub Actions build. Retrying verification or publication reuses that build's artifact ID and version metadata, including catalog URLs; only rebuilding creates a new candidate. This produces valid, monotonically increasing versions without changing or pre-bumping source `plugin.json` files. Stable plugin releases continue to own committed manifest version bumps.

The workflow signs the complete catalog with the existing catalog key, verifies every package URL and PluginKit version, and publishes it together with the dedicated Nightly appcast. See [Nightly releases](../github-actions.md#nightly-releases) for enablement and update validation.

Nightly isolates app, catalog, helper, credential, hook, and CLI identities. See [channel isolation](../github-actions.md#channel-isolation) for the ownership boundaries and coexistence checks.

## Release Flow

Recommended production flow is an incremental batch plugin release:

1. Run `make release`.
2. Choose `plugin`, release mode, and `patch`/`minor`/`major`.
3. The helper analyzes the production catalog and shows the planned manifest bumps.
4. After confirmation, the helper syncs `main`, bumps changed plugin manifests when needed, compiles `release: plugin` changelog fragments into `CHANGELOG.md`, runs a release plan check, commits the bump, and pushes a batch tag such as `plugins-1.0.1`.
5. The `Plugin Release` GitHub Action reads the catalog for the current PluginKit version. The first release of a new ABI may fall back to the previous catalog only to compare versions.
6. In default `auto` mode, the workflow selects new plugins, plugins whose manifest version is higher than the previous catalog entry, and every plugin when shared `Sources/MacToolsPluginKit/` code changed since its previous package was built.
7. If package-relevant files changed inside a plugin or shared PluginKit code changed but that plugin version did not increase, the workflow fails before signing or uploading. A `pluginKitVersion` change automatically becomes a full `mode=all` rebuild and replaces the catalog for that ABI line; other exceptional shared paths can still be supplied explicitly with `--shared-path`.
8. The workflow builds, signs, zips, and uploads only the selected plugin packages.
9. For an ABI migration, the workflow generates a complete catalog from all rebuilt packages. For later releases within an ABI line, it generates a delta catalog and merges it into that line's catalog, keeping unchanged entries pointing at their existing assets.
10. The signed catalog is committed to its compatibility path. The released PluginKit v5/schema-2 catalog remains at `docs/plugins/v5/catalog.json`; Released PluginKit v6/schema 3 remains at `docs/plugins/v6/catalog.json`; new PluginKit v7 packages go to `docs/plugins/v7/catalog.json`.
11. `Deploy Pages` publishes the signed catalog to GitHub Pages.

The batch tag is stored per plugin entry through `package.url` and `releaseNotesURL`, so one catalog can point different plugins to different release tags without changing host code.
Plugin batch releases are published with `--latest=false`; only stable `v*` App releases may become the repository's GitHub Latest release.

An app signing failure does not require republishing an already verified plugin batch or catalog. For an inline workflow-only fix, keep the existing app tag and start a new `Release` run on `main` with that tag; see [App release recovery](../github-actions.md#app-release-recovery).

The GitHub Release body for each plugin batch is extracted from the matching `CHANGELOG.md` entry, such as `## [plugins-1.0.1]`.

An incremental release record contains only packages changed in that batch:

```text
GitHub Release: plugins-1.0.1
  calendar.mactoolsplugin.zip
  display-brightness.mactoolsplugin.zip
```

Unchanged plugin entries remain valid because the catalog preserves their previous URLs, checksums, and versions. They are not shown as updates in the app unless their catalog version is higher than the installed version.

The v7 migration changes the host ABI and source manifests’ `pluginKitVersion`, `minHostVersion`, and panel capabilities. Keep package versions unchanged until `make release` prepares a complete rebuilt batch. Do not hand-generate or overwrite signed catalogs. Publish the v7 batch and catalog, wait for deployment verification, and only then prepare the matching app release; release tooling owns version bumps and compiled changelogs.

`pluginKitVersion` is the PluginKit ABI boundary. When it changes, every plugin package must be rebuilt and each plugin's manifest version must increase during release so installed users see an update. The standard `make release` flow handles these manifest bumps automatically. The new host reads the new catalog and updates all installed plugins before loading any dynamic bundle. The catalog merge step rejects mixed PluginKit versions.

Within one PluginKit ABI line, a plugin that adopts a newly exported PluginKit type must set `minHostVersion` to the first MacTools app release that exports that symbol. This prevents an older host from accepting the manifest and then failing while loading the dynamic bundle.

Any change under `Sources/MacToolsPluginKit/` is conservatively treated as package-relevant for every plugin. `make release` automatically bumps the affected manifests in the release commit; feature PRs should not pre-bump unrelated plugins. This prevents an incremental catalog from retaining binaries built against an older copy of the shared framework.

When a full rebuild is needed, run the `Plugin Release` workflow manually with `mode=all`. To publish a controlled subset, use `mode=selected` and pass comma-separated plugin IDs or directory names in `plugins`.

Each zip keeps the package root:

```text
appearance.mactoolsplugin/
  plugin.json
  Appearance.bundle/
    Contents/
      Info.plist
      MacOS/Appearance
      Resources/
      _CodeSignature/
```

For authorized local signing validation, use the release asset script with an output path outside the published catalogs. This builds and signs packages; it does not publish a release:

```bash
make package-plugins-release \
  PLUGIN_CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  PLUGIN_CATALOG_PRIVATE_KEY_BASE64="$PLUGIN_CATALOG_PRIVATE_KEY_BASE64" \
  PLUGIN_RELEASE_TAG=plugins-1.0.1 \
  PLUGIN_RELEASE_SIGNED_CATALOG=build/PluginRelease/catalog.signed.json
```

Generated local output:

```text
build/PluginRelease/
  Assets/*.mactoolsplugin.zip
  catalog.json
  catalog.signed.json
```

External plugin repositories can use the lower-level tools directly. Run each with `--help` for its supported arguments:

| Script under `scripts/plugins/` | Purpose |
| --- | --- |
| `plan-plugin-release.py` | Compare manifests and package-relevant changes with a previous catalog |
| `build-plugin-release-assets.sh` | Build and sign all packages, or a subset selected with repeated `--plugin` arguments |
| `generate-plugin-catalog.sh` | Project validated packages and source metadata into a catalog |
| `merge-plugin-catalog.py` | Merge a delta into the same ABI line; use `--plugin-kit-version 7` for the current line |
| `sign-plugin-catalog.sh` | Sign the merged catalog with the configured Ed25519 key |

Use the selected compatibility line's catalog as the merge input. A previous ABI is only a version-comparison baseline for a complete rebuild, never a source of package entries to retain in the new catalog.

`--website-output` writes a package-URL-free deterministic projection for website builds. Referenced screenshots are copied beside it under `assets/` with checksum-based names. Use `--generated-at` in fixtures or reproducibility checks when the catalog timestamp must also be stable.

Catalog signing and app verification both use Foundation's sorted JSON representation before applying Ed25519 through CryptoKit. Release workflows also verify that the private signing key matches the public key embedded in the app before building packages.

Catalog generation rejects duplicate plugin IDs, malformed HTTPS URLs or timestamps, and packages larger than 200 MiB. ZIP packages are inspected from their central directory without extraction: archive paths and member types must be safe, symlinks must remain inside the package root, and member count and expanded size are bounded. Catalog projection of screenshots still requires the matching source assets.

The catalog private key, Developer ID identity, and GitHub token must come from local environment variables or CI secrets. Do not commit them. The catalog public key is safe to embed in the app as `PLUGIN_CATALOG_PUBLIC_KEY`.

## Runtime Lifecycle

Install, update, and uninstall are immediate at the UI contribution level:

- Installed plugins contribute their declared panel items, settings, permissions, and shortcuts.
- Uninstalled plugins are removed from UI immediately and package files are deleted. Scoped data is preserved by default. A manifest declaring `uninstallDataPolicy: "removePrivateData"` requires a destructive warning and host-owned cleanup of private directories, preferences, and the standardized Keychain item. See [local native plugins](local-native-plugins.md#package-layout) for cleanup and recovery rules.
- Batch updates resolve the currently updateable catalog entries and rebuild plugin management state once after successful package replacements.
- A declared feature-extraction migration may install its replacement package before updating the installed source package that retires the feature. Automatic migration requires the legacy preference marker; manually installing the destination also coordinates an older source even when that preference is not yet present. The host resolves both catalog packages before mutation, suspends a loaded source, installs and runtime-validates/activates the replacement, then retires the source. A validation or paired-update failure removes the new destination and restores the old loaded source. A completion marker makes the bridge one-time; completion is persisted before the write-ahead journal is cleared, and startup reconciles a stale journal left beside durable completion. If the source is explicitly uninstalled during recovery, the host durably records that intent before deleting its package; a later launch finishes the removal instead of reinstalling the source.
- Already-loaded native code is not force-unloaded in-process. The executable code is fully released after the app restarts.

This keeps the native bundle lifecycle aligned with macOS loadable bundle constraints while preserving a predictable management UI.
