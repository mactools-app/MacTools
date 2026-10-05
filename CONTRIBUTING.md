# Contributing to MacTools

**English** · [简体中文](CONTRIBUTING.zh-CN.md)

Help improve a native, lightweight macOS utility collection. Bug fixes, plugins, translations, documentation, and focused UI improvements are welcome. Keep each pull request about one problem and verify the behavior you change.

## Before you start

Search [existing issues](https://github.com/ggbond268/MacTools/issues) and pull requests first. Discuss new plugins, public PluginKit APIs, and substantial interaction changes in an issue before implementation. Describe the user need, proposed behavior, and tradeoffs. Prefer English for commit messages and PR titles; clear reports in Chinese are also welcome.

### Issue format

Use the [Bug report](.github/ISSUE_TEMPLATE/bug_report.yml) or [Feature request](.github/ISSUE_TEMPLATE/feature_request.yml) form. Give the title a concrete symptom or outcome, such as “Calendar panel does not refresh after wake.”

| Report | Include |
| --- | --- |
| Bug | Reproduction steps or observations, expected and actual behavior, frequency, app version/channel, plugin version, macOS version, and Mac chip. Add relevant displays, devices, permissions, or logs. |
| UI issue | A screenshot showing the affected panel or window; a short recording for interaction problems. Include app language, appearance, and display scaling when relevant. |
| Performance issue | The workload, whether the panel is open or closed, approximate duration, and CPU/memory/Energy Impact observations. Include a baseline when available. |
| Feature or plugin | The problem and use case, proposed interaction, current workaround, alternatives, and required system access. |

Remove credentials, private content, and identifying account details from attachments. Report one problem per issue; link related reports instead of duplicating them.

## Build and run

Use macOS, an Xcode toolchain supporting Swift 6, and XcodeGen. The app targets macOS 14+; individual APIs may require newer versions. The [Build workflow](.github/workflows/build.yml) defines the CI environment.

```bash
brew install xcodegen
make setup
```

Fill in `DEVELOPMENT_TEAM` and a stable `BUNDLE_IDENTIFIER_PREFIX` in the generated `LocalConfig.xcconfig`, then run:

```bash
make run
```

This builds the app and plugins, syncs the Debug catalog, and installs `~/Applications/MacTools Dev.app`. A full Debug sync moves packages absent from the checkout into a recoverable quarantine; a filtered sync preserves unrelated packages.

| Command | Purpose |
| --- | --- |
| `make generate` | Generate plugin targets and the Xcode project. Use this instead of bare `xcodegen generate`. |
| `make build` | Compile the app and its plugin targets. |
| `make sync-debug-plugins PLUGIN=calendar` | Build the app targets, then sync only the selected Debug plugin without launching the app. |
| `make build-plugin PLUGIN=calendar` | Validate a standalone plugin package and its Debug catalog. |

Keep local configuration, credentials, generated projects, and build products out of commits. See [local plugin development](docs/plugins/local-native-plugins.md) for package setup and debugging.

## Where changes belong

| Path | Responsibility |
| --- | --- |
| `Sources/App/` | Menu-bar panels, settings, windows, and app routing. |
| `Sources/Core/` | Plugin hosting, actions, permissions, shortcuts, storage, and updates. |
| `Sources/MacToolsPluginKit/` | Shared plugin protocols, declarative UI, and runtime context. |
| `Plugins/<PluginName>/` | `plugin.json`, `Sources/`, `Bundle/`, resources, and adjacent `Tests/`. |
| `Tests/` | Shared App/Core tests. |
| `docs/plugins/` | Feature contracts and plugin development guides. |

Ordinary plugins do not need root `project.yml` edits. Put necessary build overrides in the plugin's own `project.yml`; app extensions such as Finder Sync must be embedded by the host.

## Development standards

Follow the [plugin development standards](docs/plugins/development-guidelines.md) and the adjacent implementation. The common requirements are:

- **Respect the host contract.** Implement `MacToolsPlugin`, publish stable `panelItems`, and keep manifest capabilities, action policies, permissions, and minimum-host requirements consistent with runtime behavior. Reuse host actions and shortcuts.
- **Match native macOS.** Prefer system controls, semantic fonts and colors, and native keyboard, focus, and accessibility behavior. Keep equivalent controls consistent across settings, menu-bar panels, widgets, and floating windows, with density appropriate to each surface. Follow the [shared UI rules](docs/plugins/development-guidelines.md#visual-and-interaction-design), reuse host renderers and shared themes, and extend shared components when needed. Localize user-facing copy and verify long labels.
- **Reuse typography roles.** Follow the [typography contract](docs/plugins/typography.md) for titles, supporting text, numbers, and AppKit text measurement. `PluginTypography` and `PluginMetricValue` require host 2.0.0; declare that minimum when consuming these new APIs.
- **Build reusable widgets.** Support zero or multiple placements, isolated previews, view recycling, and independent per-placement presentation state. See [panel items](docs/plugins/panel-items.md).
- **Keep background work economical.** Use cached snapshots, event-driven updates, bounded asynchronous work, and visibility-aware presentation. Preserve intentional monitoring while hidden; stop owned work on deactivation. See [performance requirements](docs/plugins/development-guidelines.md#performance-and-energy).
- **Preserve user control.** Handle denied permissions, cancellation, unsupported hardware, and system changes. Keep existing confirmations, recovery paths, and destructive-operation safeguards.

Shared filesystem metadata code lives in `Sources/MacToolsFileSystem`. Disk Clean and Storage Explorer link this static module into their bundles; their core targets use it as a build dependency. Keep cleanup policy in the owning plugin and run both plugins' filesystem tests after changing the shared parser.

## Validation

Keep a compact suite covering the main user flow and consequential boundaries such as data loss, permission checks, cancellation, or compatibility. Reuse existing coverage across layers. A past bug alone does not require a permanent test; omit unlikely combinations in settled code unless their recurrence would have a significant impact. See the [core test scope](docs/testing/core-tests.md).

There is no per-PR test-count or coverage-percentage target. Do not add tests that merely repeat the implementation, assert private call sequences, or check fixed wording, colors, and spacing. Choose checks by their distinct behavior and risk, not their UI/unit/integration label. Use manual review for appearance and keep desktop-dependent evidence checks on demand; retain automated integration checks when they establish a critical outcome that cheaper tests cannot cover.

Run the smallest relevant test class or method. For example:

```bash
make test TEST_FILTER=ActionExecutorTests
```

Use `TEST_FILTER=ClassName/testMethod` for one method, or `make test` for all retained XCTest cases. The target regenerates the project and uses serial execution with per-test timeouts. `make script-tests` validates tooling separately; `make ci` also checks frozen-client binary compatibility. Use temporary directories, fixtures, and fake services rather than real user data or accounts. Broaden validation only for failures, shared contracts, or other affected behavior.

Unsigned XCTest builds use `build/DerivedDataTests` by default, separate from the signed app used by `make run`. Override `TEST_DERIVED_DATA` when needed, keeping it separate from `DERIVED_DATA` to avoid leaving a test bundle inside the installed app.

For copy and catalog changes, run `make validate-localization` to check English resources, complete coverage of all 11 supported languages, and translation format contracts. `make script-tests` includes this audit and fails when a translation is missing. To inspect per-key findings, run `python3 scripts/audit-localization.py --require-complete --json`. Follow the [plugin localization rules](docs/plugins/development-guidelines.md#protocols-and-ownership), and manually check language switching and affected UI layout. Action-symbol changes must keep manifests and runtime definitions consistent; verify them with `make test TEST_FILTER=PluginRuntimeActionSnapshotTests`.

| Change | Verification scope |
| --- | --- |
| App or plugin behavior | Compile and run relevant existing tests. Add coverage only for missing core behavior or a regression; manually check hardware/system integration where needed. |
| UI or widgets | Attach the UI evidence below. Check affected interactions; add logic tests only when state, actions, or lifecycle change. |
| PluginKit API/ABI or cross-module behavior | `make ci` before pushing these code changes; it includes script tests, XCTest, and frozen-client compatibility. Register newly introduced APIs in `scripts/tests/test_plugin_minimum_host_compatibility.py`; consumers of already listed APIs need a compatible `minHostVersion`, not another inventory entry. |
| Scripts, manifests, or catalogs | Focused script tests for isolated logic; `make script-tests` for package/schema/compatibility changes or new public API consumers. Regenerate website data with `python3 scripts/plugins/generate_website_plugin_data.py` after metadata/action changes. |
| Panel drag routing or hit testing | Run the relevant layout state tests, then manually check the affected [panel interactions](docs/testing/panel-layout-editing.md). |
| Changelog fragments | `make validate-changelog` before committing or pushing. |
| Documentation only | Check changed links, examples, formatting, and rendered layout; no app build is needed. |

Plugins using `PluginFloatingPanelSurface`, `PluginFloatingPanelShape`, or `PluginFloatingPanelAppearance` require MacTools 2.0.0 or later. Keep menu-bar themes separate from this system-managed floating-panel preference.

## Submit a pull request

Use the [PR template](.github/PULL_REQUEST_TEMPLATE.md). Explain the problem, resulting behavior, verification, and relevant limitations. Link the issue and keep unrelated refactoring or formatting out of the diff. Contributors remain responsible for understanding and testing all submitted code, including assisted code.

**UI changes require before/after screenshots.** For a new surface, provide the resulting UI and describe its entry point. Include light and dark appearances for visual changes and a representative custom theme when theme behavior changes. Use a short recording for dragging, focus, keyboard navigation, or other behavior a still image cannot demonstrate. Show enough of the surrounding window to assess layout; remove private content.

Check the interactions, states, translations, and window sizes affected by the change; this is not an exhaustive checklist for every PR. Include a comparable before/after observation when changing background workload, sampling frequency, large-data rendering, or claiming a performance improvement; routine UI edits do not need profiling. See the [measurement guide](docs/plugins/development-guidelines.md#performance-and-energy).

Before requesting review:

- [ ] Relevant checks pass; the PR lists commands, results, and any checks that could not run.
- [ ] UI evidence is attached when applicable, and the design follows native macOS conventions and shared components and themes.
- [ ] Root READMEs stay concise and cover installation, requirements, and major capabilities; feature guides change only for durable instructions, important limitations, or recovery steps. Minor changes need no guide; user-visible app and plugin changes include the required English fragment in `changes/unreleased/`.
- [ ] Manifest metadata, API compatibility, permissions, and action policies match the implementation.
- [ ] Third-party sources and licenses are recorded; no secrets, local configuration, or unrelated generated files are included.

Changelog fragments use `release: app` or `release: plugin` and a supported `type`. Keep each entry within 220 characters and two sentences. If both channels are affected, explain each impact separately. Documentation-only changes do not need a release fragment. See [changelog instructions](changes/README.md).

## Licensing and releases

Contributions must follow [LICENSE](LICENSE) and [LICENSING.md]. Project-authored app, CLI, PluginKit, official plugins, tooling, and documentation use **GPL-3.0-only**. Submit only material you have the right to contribute under the applicable terms. Third-party material retains its own notices; record its source, exact revision, affected products, source paths, and license text in [ThirdPartyNotices](Sources/Resources/ThirdPartyNotices/manifest.json). Plugins accepted into the official catalog must use GPLv3-compatible terms unless the licensing policy documents an exception. Icon contributions also follow the [asset catalog rules](docs/icon-gallery.md).

Releases are maintainer-owned. Feature PRs should not pre-bump plugin versions, change signed catalogs, or regenerate release history. Follow the [release workflow](docs/github-actions.md), [plugin catalog](docs/plugins/plugin-catalog.md), and [CLI release gates](docs/plugins/cli-release.md) for release work.
