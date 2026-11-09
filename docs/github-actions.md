# Build and release workflows

Workflow definitions live in [`.github/workflows/`](../.github/workflows/). Ordinary contributions use the Build checks; release preparation, signing, notarization, and publication are maintainer operations.

## Workflow overview

| Workflow | Trigger | Result |
| --- | --- | --- |
| Build | Pull request, `main` push, or manual run | Script tests, XCTest, frozen PluginKit client verification, unsigned Nightly validation, and website checks; non-PR runs also compile Release |
| Prepare Release | Manual | Validates and commits version/changelog changes, pushes a tag, and optionally dispatches the release workflow |
| Release | App version tag or manual tag input | Signed and notarized DMG, GitHub Release, Sparkle appcast, and stable download metadata |
| Plugin Release | `plugins-*` tag or manual batch tag | Signed plugin packages and the catalog for the selected PluginKit version |
| Nightly | Daily at 06:00 UTC when enabled, or manual | Separate Nightly app, Apple silicon CLI, complete plugin set, appcast, and catalog from one source commit |
| Homebrew Cask Update | Manual | A version update PR to the official Homebrew cask |
| Deploy Pages | Relevant source/metadata push, successful release workflow, or manual | Astro website and static release resources on GitHub Pages |

Build does not publish releases. A manual Build run can upload a Debug app artifact for local debugging; failed native tests upload their result bundle. Neither is a distribution channel.

Deploy Pages watches website sources, plugin manifests/localizations/Marketplace assets, metadata generators, app download metadata, icon-gallery assets, and Nightly metadata. See [`pages.yml`](../.github/workflows/pages.yml) for the exact paths.

## Repository setup

Configure repository secrets in **Settings → Secrets and variables → Actions**:

| Secret | Purpose |
| --- | --- |
| `APPLE_DEVELOPMENT_TEAM` | Apple Developer Team ID |
| `BUNDLE_IDENTIFIER_PREFIX` | App identifier prefix; the stable app uses `<prefix>.mactools` |
| `DEVELOPER_ID_CERT_P12` | Base64-encoded Developer ID Application certificate and private key |
| `DEVELOPER_ID_CERT_PASSWORD` | Password for the exported `.p12` |
| `ASC_API_KEY_P8_BASE64` | Base64-encoded App Store Connect API key for notarization |
| `ASC_API_KEY_ID` | App Store Connect key ID |
| `ASC_API_ISSUER_ID` | App Store Connect issuer ID |
| `SPARKLE_PRIVATE_KEY` | Existing Sparkle EdDSA private key |
| `PLUGIN_CATALOG_PRIVATE_KEY_BASE64` | Plugin catalog Ed25519 private key |
| `HOMEBREW_GITHUB_API_TOKEN` | Optional token for `brew bump-cask-pr`, with permission to open the upstream PR |

Export the Developer ID certificate and private key from Keychain Access as a password-protected `.p12`. Download the notarization `.p8` from App Store Connect and record its key and issuer IDs. Encode each file locally for its secret, for example:

```bash
base64 -i DeveloperIDApplication.p12 | tr -d '\n' | pbcopy
```

Keep certificates, private keys, passwords, and `LocalConfig.xcconfig` out of the repository. The Sparkle key must match `SPARKLE_PUBLIC_ED_KEY` in `project.yml`; the separate catalog key must match `PLUGIN_CATALOG_PUBLIC_KEY` embedded in the app. Do not replace an existing key as part of routine CI setup. Nightly and plugin release workflows check the catalog key pair before expensive build or signing work.

Allow release workflows to write repository content in **Settings → Actions → General → Workflow permissions**. Set **Settings → Pages → Build and deployment → Source** to **GitHub Actions** so the repository's deployment workflow owns publication.

## App releases

The preferred entry point is **Actions → Prepare Release → Run workflow**:

1. Choose `type=app` and enter the version without `v`.
2. Leave `release` enabled to dispatch Release after preparation. Disabling it still commits version changes and pushes the tag.
3. Review the resulting preparation and release checks.

The local equivalent is:

```bash
make release
```

The helper previews the version change, then synchronizes `main`, validates, compiles app changelog fragments, commits, and pushes the app tag after confirmation. `Configs/AppVersion.xcconfig` supplies the app and embedded extensions' marketing version and build number. If source already declares an unreleased version above the latest app tag, the helper can use that version and increment only the build.

Changes to `Sources/MacToolsPluginKit/` since the latest app tag require an explicit compatibility check. `--yes` does not bypass this prompt; a noninteractive run stops so the maintainer can review it in an interactive terminal.

The Release workflow checks that the tag matches the source version, signs the embedded CLI broker before the app, notarizes, and publishes. Stable app releases become GitHub Latest and update `docs/app-release.json`; prereleases do not replace stable download metadata. Homebrew updates use their separate workflow.

When the host changes catalog compatibility lines, publish the matching plugin batch and verify its deployed signed catalog **before** preparing the app release. Both release preparation and publication enforce this preflight.

Stable CLI publication is currently disabled by `STABLE_CLI_ENABLED: "false"` in [`release.yml`](../.github/workflows/release.yml). Installer support in source does not mean stable CLI assets are published. Follow the [CLI release gates](plugins/cli-release.md) before changing this switch.

### App release recovery

For an inline workflow failure with otherwise correct tagged source, push the workflow fix to `main` and start a new Release run on `main` with the existing tag:

```bash
gh workflow run release.yml --ref main -f tag=v1.3.0
```

The workflow definition comes from `main`; app source, scripts, version, catalog, and release notes still come from the tag. **Re-run jobs** on the old run retains its original workflow revision. A source or checked-in script fix needs an updated release source; selecting `main` does not replace tagged files. An already verified plugin batch does not need republishing for an app-only signing fix.

## Plugin releases

Use Prepare Release with `type=plugin`, a batch version without `plugins-`, and a release mode:

| Mode | Use |
| --- | --- |
| `auto` | Detect changed packages and catalog metadata |
| `selected` | Publish the IDs or directories listed in `plugins` |
| `all` | Rebuild the complete plugin set |

The local entry point is `make release ARGS="--type plugin"`. Normal feature PRs should not bump manifest versions: preparation identifies package-relevant changes and increments affected `plugin.json.version` values. Shared PluginKit changes are package-relevant for every plugin. ABI or catalog-schema migrations require a complete rebuild.

Plugin Release validates the plan and performs one unsigned aggregate `Release` build of the app and plugins, sharing compiled dependencies. It checks that every selected bundle exists, then reuses the products directory to sign and package only the selected plugins with licenses/notices. Build and packaging are separate steps, and the job has a 120-minute timeout. The batch publishes with `--latest=false`. Within one compatibility line, it merges updated entries into the signed catalog; unchanged entries retain their existing assets. A no-change plan creates no release, while a catalog-only change skips compilation and may publish without new ZIPs.

The current line is **PluginKit 7 / catalog schema 3**, published at `docs/plugins/v7/catalog.json`. Prior catalog lines remain available to their released hosts. Never merge packages from different ABIs or overwrite a compatibility catalog with a schema its clients cannot read.

See [Plugin catalog](plugins/plugin-catalog.md) for package metadata, compatibility, local catalogs, and lower-level tooling.

For an inline workflow-only failure with correct tagged source, push the fix to `main` and start a new run using the existing batch tag and intended mode:

```bash
gh workflow run plugin-release.yml --ref main -f tag=plugins-2.1.0 -f mode=all
```

The workflow comes from `main`; plugin source, packaging scripts, versions, and release notes still come from the tag. **Re-run jobs** retains the failed run's workflow revision. Keep the original tag in place; a fix to tagged source or scripts requires a separate release-source decision.

## Nightly releases

Nightly reuses the nine required signing and publication secrets above. To enable the schedule:

1. Run Nightly manually on `main`. Verify the prerelease, signatures, notarization, `docs/nightly/appcast.xml`, and `docs/nightly/plugins/v7/catalog.json`. Install the app and at least one matching plugin.
2. Run it again and verify the installed app's N → N+1 Sparkle update and plugin synchronization. Complete the relevant [CLI acceptance checks](testing/cli-nightly-distribution.md) using artifacts from that same release.
3. Set repository variable `ENABLE_NIGHTLY_RELEASES=true`. Remove it or change its value to pause scheduled publication; manual validation remains available.

Manual refs must be ancestors of `origin/main` and support Nightly release interface v4, including sealed CLI installation metadata and the unchanged GPL license in the CLI archive. The workflow validates this before accessing release credentials.

Scheduled runs compare the selected source with the source advertised by the deployed Nightly appcast, ignoring generated `docs/nightly/**` changes. An unchanged source skips publication. Manual runs always publish; missing or invalid comparison data also proceeds with publication.

Each candidate uses a unique `nightly-<run>-<attempt>` release and plugin versions of `source-major.run.attempt`. Build/signing, credential-free CLI execution, and publication are separate jobs connected by one immutable artifact. Failed pre-publication verification can use **Re-run failed jobs** to reuse that artifact. If the release is already public or draft cleanup failed, use **Re-run all jobs** to create a new candidate. Existing public assets are never overwritten.

Retention keeps the latest 14 matching Nightly prereleases and protects builds referenced by the committed or deployed appcast. Failed candidates and abandoned workflow-owned drafts are cleaned separately; stable and unrelated releases are excluded.

### Channel isolation

Before enabling scheduled distribution or changing these integrations, verify the affected coexistence behavior:

| Integration | Nightly boundary |
| --- | --- |
| App | Separate bundle ID, name, URL scheme, Application Support root, appcast, and catalog |
| Fan Control / Battery Charge Limit | Separate `.smc-helper.nightly` privileged helper paths and signing identifiers; hardware state is still shared |
| Translator / Cloudflare R2 | Separate `.nightly` Keychain services, without migration or fallback to stable credentials |
| Activity Bar | Separate socket and hook filenames; installing/removing one channel's hooks preserves the other |
| CLI | Separate command, broker identity, managed store, and background-item registration |
| Trackpad listener | Shared lock prevents competing hardware listeners |

Use separate test credentials and exercise one hardware-control policy at a time. Check update, removal, and reversed installation order where ownership changes. The [Nightly CLI guide](testing/cli-nightly-distribution.md) covers signed archive, permissions, broker, and installed-app validation.

## Release notes

`CHANGELOG.md` is the canonical source for app and plugin release notes. Add concise English fragments under `changes/unreleased/` for user-visible changes:

```markdown
---
release: app
type: fixed
area: Finder Integration
---

Finder right-click menu items now stay hidden when the plugin is disabled.
```

Use `release: app` or `release: plugin`. Types are `added`, `changed`, `fixed`, `security`, `removed`, `deprecated`, `maintenance`, and `summary`. Keep each entry within 220 characters and two sentences. Describe the user or maintainer impact; omit implementation history, test-only changes, and repeated wording. If both channels need an entry, describe their distinct impacts separately.

Run `make validate-changelog` whenever fragments change. Release preparation consumes only the selected channel's fragments into its `v*` or `plugins-*` section and regenerates `Sources/Resources/ReleaseHistory.json`. About shows the 10 most recent entries. After an intentional historical edit, regenerate with `python3 scripts/changelog.py export-history`.

GitHub Release bodies use the matching changelog section. Sparkle adds plugin entries released since the previous app version under Plugin Updates. Optional `.github/release-highlights/<app-tag>.md` content appears above the generated app notes and in Sparkle.

## Homebrew and credentials

Homebrew Cask Update selects a stable `v*` release containing both `MacTools.dmg` and `MacTools.sha256`. It preserves the cask's versioned URL template when opening the upstream PR. Plugin batches and prereleases are excluded.

PR builds do not read release secrets. Build uses read-only repository access; publication jobs receive only the permissions their operations require. Signing uses a temporary keychain, and private key files are removed after use. CLI execution happens in a separate verification job without signing secrets or repository write credentials. Catalog signing uses Swift/CryptoKit and the same Foundation JSON canonicalization as the app.
