---
name: mactools-release-preflight
description: Prepare MacTools app or plugin releases by consolidating unreleased changelogs and auditing PluginKit compatibility, plugin release scope, old/new app behavior, and release prerequisites. Use for release readiness checks, not release execution.
---

# MacTools Release Preflight

Produce an evidence-based release recommendation for this repository. Consolidate pending release notes directly; inspect everything else and report concrete conclusions and proposed changes.

## Scope and authority

Follow the repository's [AGENTS.md](../../../AGENTS.md). Run commands from the repository root.

This skill authorizes edits, merges, renames, and deletions only within `changes/unreleased/*.md`. Other checks are read-only apart from temporary reports and normal build/test outputs. Do not change app or plugin versions, minimum-host declarations, PluginKit APIs, release scripts, catalog routing, signed catalogs, or published release history just to make a check pass. Describe those fixes unless the user has separately authorized implementation.

Do not commit, push, tag, sign, notarize, publish, dispatch release workflows, or remove unrelated files through this skill. A separate explicit user instruction may authorize those actions; do not ask again for authorization already provided. Creating or editing this skill is not itself a request to run a release preflight.

Preserve the user's accepted decisions. For example, accepting continued use of already installed plugins does not require implementing historical downloads, but the download limitation must remain visible in the conclusion.

## Establish the release baseline

- Determine the intended app version, plugin batch, and stable or Nightly channel from the request and repository state. If the target is unclear, state a provisional assumption and continue independent checks; ask only where the answer changes the recommendation.
- Record the current commit, branch, working-tree changes, and relevant release tags. Include staged, unstaged, and relevant untracked changes in the audit. Do not discard existing edits.
- Compare host changes against the latest applicable released app tag. For each plugin, derive its actual previous package tag from its catalog entry's package or release-notes URL; do not assume every plugin last shipped in the latest batch.
- Inspect `Configs/AppVersion.xcconfig`, `PluginKitCompatibility.currentVersion`, plugin manifests, the selected catalog, and the release workflows. Keep app version, plugin package version, plugin batch tag, PluginKit ABI number, and catalog schema distinct.
- Check remote refs and deployed artifacts when release readiness depends on them. Local tags or tracking refs alone do not prove current remote state. If a baseline or remote check is unavailable, mark the affected conclusion unverified instead of inferring success.

Use the [release workflow](../../../docs/github-actions.md), [plugin catalog contract](../../../docs/plugins/plugin-catalog.md), and [development guidelines](../../../docs/plugins/development-guidelines.md) as maintained references. Read relevant implementations when a conclusion depends on actual behavior.

## Consolidate unreleased changelogs

Read all pending fragments and [changes/README.md](../../../changes/README.md) before editing.

- Group entries by release channel, change type, and user-visible feature. Merge overlapping or incremental descriptions into the final shipped behavior. Preserve unrelated improvements even when they share a plugin.
- Keep app and plugin impacts separate. Preserve meaningful distinctions between additions, fixes, removals, security changes, and compatibility requirements; correct a misclassification only when the underlying change supports it.
- Remove duplicate or superseded entries and internal-only noise without user-visible or durable maintenance value. Remove a source fragment only after preserving any unique relevant information elsewhere.
- Use concise English, familiar feature names, valid frontmatter, terminal punctuation, at most 220 characters, and at most two sentences per entry. Preserve useful `area` metadata. Split a crowded entry rather than dropping a compatibility limit or meaningful behavior.
- Check claims against the diff and released baseline. Do not invent capabilities, claim an unimplemented fix, or describe a proposed minimum-host correction as already applied. Report unresolved release claims with their recommended correction.
- Keep changes confined to pending fragments. Do not compile release notes, edit `CHANGELOG.md` or `Sources/Resources/ReleaseHistory.json`, or consume fragments using the release command.

Run `make validate-changelog` and `git diff --check` after editing. Record before/after counts and a short account of what was merged or removed. Inspect any remotely introduced fragments too; an earlier cleanup does not establish that the current collection is clean.

## Audit PluginKit and minimum-host requirements

Inspect the PluginKit diff against the released host, its consumers, and [the API minimum-host inventory](../../../scripts/tests/test_plugin_minimum_host_compatibility.py).

1. **Binary compatibility:** Review changes to existing public type layouts, enum cases, protocol requirements, initializer signatures, and client-compiled or inlined code in the context of the actual build settings. Separate compatible additions and host implementation changes from breaking changes. Do not raise the ABI number merely because all plugins will be rebuilt, or assume an unchanged number proves compatibility.
2. **API availability:** Identify the first host release that actually contains each newly consumed API. Confirm against the release tag, not just the current marketing version or inventory constants. Match the required host to every affected plugin's `minHostVersion`, documentation, and release claims.
3. **Host behavior:** Check features that reuse an existing field or protocol but need new host rendering or handling. A plugin may load successfully yet lose an action or feature on an older host. Determine whether a usable fallback exists.
4. **Version preparation:** If a required minimum exceeds the source's declared app version, report whether the existing checks require predeclaring the target marketing version. Ordinary package-version and build-number increments remain the release helper's responsibility.
5. **Evidence limits:** A frozen old-client test against a new framework supports old-plugin/new-app compatibility for its covered contract. It does not prove that a newly built plugin works on an old app or that all hardware behavior is correct.

Recommend retaining or changing the PluginKit ABI with reasons. List affected plugin IDs and exact proposed minimum-host changes. Leave implementation to a separately authorized task.

## Check both compatibility directions and distribution

Inspect the host's catalog URL selection, catalog verification, merge behavior, install/update filtering, and package loading. Start in `Sources/Core/Plugins/Dynamic/` and `scripts/plugins/merge-plugin-catalog.py`; inspect released host code where its behavior differs from current source.

Complete this matrix for the relevant versions and channel:

| Scenario | Required conclusion |
| --- | --- |
| Old app + already installed old plugin | Whether the plugin still loads, stays installed, and avoids incompatible updates. |
| Old app + newly published plugin | Which packages are eligible by ABI, minimum host, and other requirements; which features still need an app update. |
| Old app + first install or reinstall | Whether the post-publication catalog still exposes a compatible package and download URL, or blocks installation without a historical fallback. |
| New app + old plugin | Whether it loads before updating, including offline startup and failed plugin-update cases. |
| New app + newly published plugin | Whether host APIs, behavior, package metadata, and catalog format agree. |

Do not equate retaining an old package asset with keeping it discoverable in the marketplace. A catalog that replaces each plugin ID with its latest entry can preserve installed plugins while losing compatible first-install/reinstall options. Check this explicitly; do not assume a version-history fallback exists.

Explain the actual effect of an ABI/catalog migration: older hosts may retain their previous endpoint while the new host rejects previously installed packages until they are updated. Conversely, retaining an ABI can let older hosts receive compatible plugin updates while skipping others. Base any counts on current manifests and catalog routing.

If an uncovered scenario conflicts with the user's requirement, report the gap and a concrete option, such as preserving an old endpoint and routing new hosts to another catalog. Do not implement a new catalog architecture or invent a compatibility guarantee during the audit. An explicitly accepted limitation is not an unresolved blocker.

## Determine the plugin release scope

Assess runtime necessity and release-tool policy separately.

- For each previously published plugin, inspect its own source, packaged resources, manifest, and build changes since its package baseline. Follow the packaging and planner rules to distinguish package changes from tests or documentation.
- Classify plugins as new, changed within their package, selected only because of shared changes, unchanged, or removed. Shared-only selection does not prove that a plugin has no independent changes; inspect both.
- Identify whether shared changes are supplied by the host at runtime or require rebuilding client code/resources. Do not conclude that every shared implementation change intrinsically requires an ABI migration or a plugin rebuild.
- Read `scripts/release.py`, `scripts/plugins/plan-plugin-release.py`, and `.github/workflows/plugin-release.yml`. Report what `auto`, `selected`, and `all` would actually do, including partial-release guards. A script requiring all packages is a tooling constraint, distinct from a runtime incompatibility.
- Use inspection or verified read-only analysis functions, not `release_app()`, `release_plugin()`, or a full `make release` invocation. Even `--dry-run` may perform preflights and interactive steps. The standalone planner expects some version bumps to have happened already; a pre-bump failure is not by itself evidence of incompatible plugins.
- Check whether planner diffs use `HEAD` while manifests come from the working tree. Include pending changes separately and label the release plan provisional until those changes are committed.

Report the recommended scope, actual selection counts and reasons, and the consequence of omitting changed packages. Distinguish continued operation of old code from delivery of new fixes, translations, and features. Do not hardcode a plugin count or ABI version from a previous release.

## Validate and assess remaining prerequisites

Select checks according to the affected contracts and repository guidance.

- Always validate edited changelog fragments. Use `make script-tests` for API inventory, manifest, localization, generated-data, and release-planning checks when relevant.
- Use focused existing XCTest for catalog/install/update boundaries. Shared API/ABI changes or release-wide validation may require `make ci`, which includes the repository's frozen-client check. Reuse applicable successful evidence when the tested code has not changed; do not rerun the entire suite for changelog-only edits.
- For a stable release, when production catalog readiness matters, run `xcrun swift scripts/plugins/preflight-app-plugin-catalog.swift --app-version TARGET` with the resolved target. For Nightly, inspect its channel-specific workflow and catalog instead. Interpret the result against the catalog actually checked: a currently deployed old catalog passing does not prove that a future batch has already been published and deployed.
- Inspect release branch requirements, dirty/untracked files, remote/tag availability, pending notes for each intended channel, and source/deployment consistency. Report unrelated files rather than deleting or stashing them.
- Keep checks bounded and report failures or unavailable evidence. Do not read signing secrets or trigger publishing workflows merely to test access. Signing, notarization, and future deployment success remain unverified until their actual release steps run.

Separate manual preparation from work already performed by the current release helper: ordinary app/package version increments, build numbers, changelog compilation, commits/tags/pushes, and workflow-owned publication. Check the implementation before assigning ownership. Do not propose redundant manual version edits.

App and plugin releases are separate operations. Derive the recommended order from the actual catalog preflight and compatibility dependencies; when a new compatibility catalog is required, verify that it will be published and deployed before the dependent app release.

## Report the decision

Answer in the user's language; repository documentation and fragments remain English. Lead with whether preparation is complete, blocked by a concrete issue, or conditional on missing evidence.

Keep the report concise and include:

- Target versions, baseline, and any material assumptions.
- Changelog cleanup result and validation.
- PluginKit recommendation and proposed minimum-host corrections, if any.
- The compatibility matrix, including accepted limits and any unresolved download/reinstall issue.
- Recommended plugin scope versus current tooling's actual selection.
- Checks run, reused evidence, failures/skips, and what remains unverified.
- Prioritized manual actions with affected files and proposed changes; identify release-script-owned steps separately.

Distinguish technical readiness from an executable release state. Expected uncommitted changelog cleanup means the preparation may be complete while the release helper still requires a commit. Do not claim that a release has happened, or that all old-version scenarios are unaffected, merely because CI passes.
