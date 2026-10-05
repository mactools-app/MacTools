# Localization audit — 2026-10-04

The 11-language approval and UI receipts below describe the original audit milestone. The latest-main integration at the end adds Turkish as the twelfth supported language; its translation additions are reviewed separately.

The final code review follow-up corrects all 12 Marketplace action-risk labels to describe low risk without promising that confirmation is unnecessary. Plural format validation checks argument types and positions while allowing natural count-free forms such as Arabic “no results.” The auditor also discovers Finder Sync's literal wrapper lookups, and the pull-request build now runs strict localization validation.

Scope: [issue #463](https://github.com/mactools-app/MacTools/issues/463), expanded to the host, all plugins, PluginKit, Finder Sync, App Intents, Marketplace metadata, and website language behavior. Baseline: `3442f9f8` on `origin/main`.

## Findings fixed

| Area | Finding and resulting behavior |
| --- | --- |
| Marketplace details | Missing section headings, settings links, unavailable/uninstall states, and external-link captions had no English resource. All new copy has translations for all 11 supported languages. |
| Marketplace metadata | Actions, requirements, and privacy showed raw schema codes; related plugins showed identifiers. Known vocabulary now has localized labels and locale-aware lists, while signed identifiers and unknown publisher-provided values remain intact. |
| Host controls | Added missing shortcut conflict/error dialogs, command labels, layout actions, panel controls, IP captions, and the command-palette position reset command. |
| Plugin copy | Filled missing Input Remapping input/trigger/direction labels, Trackpad Gestures conflict text, Keep Awake search copy, and AI Assistant prompt captions. Homebrew installation guidance now goes through its catalog. |
| Failure paths | Hide Notch rollback failures use its resource bundle. Trash read/empty failures retain typed errors and resolve their messages in the current language, including after a language change. |
| Formatting | AI Usage, Clipboard History, Disk Clean, Xcode Clean, Storage Explorer, Device Battery, Marketplace refresh timestamps, and automation summaries use the runtime locale for affected user-facing values. Protocol formats and filesystem paths are unchanged. |
| Retained state | AI Usage refreshes menu-bar presentation on a language change. Storage Explorer rebuilds localized rows and grouping from its retained snapshot, preserving selection and avoiding another filesystem scan. Its overflow group now uses the supplied localized name. |
| Translation coverage | Completed 12,110 missing language/key pairs across 1,414 existing keys in 16 catalogs. Every catalog key now covers all 11 supported languages. |
| Prevention | Added strict `make validate-localization`, included in `make script-tests`, and contract tests for the auditor, compiled translation resources, and retained Storage Explorer state. Missing supported-language translations fail validation. |

The final automated inventory contains **74 tables, 6,082 keys, and 6,724 source/schema resource references**. It includes 73 string catalogs and System Soft Restart's hand-authored `.strings` table. No discovered lookup lacks an English resource; no present translation is unfinished or empty; no checked format translation changes argument types. The change adds 185 keys and completes the existing Marketplace requirement captions in the remaining languages.

## Completed translation backlog

The first audit found **1,414 keys** with English resources but missing one or more supported-language translations: **12,110 missing language/key pairs**. These could show English in a different selected language. All those gaps are now filled; the strict final inventory reports **zero translation gaps**. Counts below describe the completed backlog.

| Catalog or plugin | Keys completed | Previously missing languages |
| --- | ---: | --- |
| Mac Settings | 459 | ar, de, es, fr, ja, ko, pt, ru, zh-Hant |
| Host FeatureUI | 166 | ar, de, es, fr, ja, ko, pt, ru, zh-Hant |
| AI Assistant | 148 | ar, de, es, fr, ja, ko, pt, ru |
| Window Layouts | 137 | ar, de, es, fr, ja, ko, pt, ru |
| Screenshot | 113 | ar, de, es, fr, ja, ko, pt, ru, zh-Hant |
| Apple Shortcuts | 101 | ar, de, es, fr, ja, ko, pt, ru |
| Window Switcher | 93 | ar, de, es, fr, ja, ko, pt, ru, zh-Hant |
| AI Usage | 58 | ar, de, es, fr, ja, ko, pt, ru, zh-Hant |
| Host Settings | 39 | ar, de, es, fr, ja, ko, pt, ru, zh-Hant |
| Siri | 32 | ar, de, es, fr, ja, ko, pt, ru, zh-Hant |
| Preferences Backup | 25 | ar, de, es, fr, ja, ko, pt, ru |
| Dock Lock | 14 | ar, de, es, ja, ko, pt, ru, zh-Hant |
| Homebrew | 10 | de, ko, ru |
| Appearance | 9 | ar, de, es, fr, ja, ko, pt, ru, zh-Hant |
| Auto Hide Menu Bar | 9 | ar, de, es, fr, ja, ko, pt, ru, zh-Hant |
| Host Search | 1 | ar, de, es, fr, ja, ko, pt, ru, zh-Hant |

Generate the per-key inventory with `python3 scripts/audit-localization.py --require-complete --json`.

Translations reuse unambiguous existing copy and combine machine-assisted drafts with context and terminology review. Context review corrected icon nouns, keyboard names, AI prompt actions, quota states, window controls, screen recording, and technical product names. New plugin names and descriptions use the existing Marketplace translations; Apple Shortcuts terminology was checked against Apple’s installed localization resources. Traditional Chinese drafts receive regional macOS terminology corrections. The backlog import preserved pre-existing translations, checked placeholder argument types, preserved prompt variables and URLs, and rejected empty text and draft markers. The independent reviews below corrected both imported drafts and affected source copy. All 11 languages have passed the agreed AI approval gate; human native-speaker review is an optional follow-up.

## Independent linguistic review

Eleven separate AI reviewers checked the changed copy, one reviewer per supported language, for meaning, grammar, natural UI phrasing, macOS terminology, and dynamic placeholders. English and Simplified Chinese review also included the existing source text behind the newly translated keys. The reviewers examined **16,064 unique phrases within their respective languages, covering 17,006 language/key entries**. This scope covers the translation change and its affected source copy; it is not a linguistic review of every pre-existing translation in the app.

Applied **2,874 phrase-level recommendations to 2,929 translation entries in 20 catalogs**. The integration checked full worksheet coverage, original values, printf argument mappings, prompt tokens, URLs, scoped locations, and the final applied values. Two Spanish/Portuguese hidden-status corrections apply only to Window Switcher; the generic host status remains unchanged. Forty-five Swift lookup and Marketplace fallback values now match the reviewed copy. No unresolved context ambiguities remain in the review reports.

| Language | Entries reviewed | Entries corrected |
| --- | ---: | ---: |
| Arabic | 1,592 | 307 |
| German | 1,602 | 172 |
| English | 1,602 | 55 |
| Spanish | 1,592 | 329 |
| French | 1,578 | 259 |
| Japanese | 1,592 | 332 |
| Korean | 1,602 | 387 |
| Portuguese | 1,592 | 274 |
| Russian | 1,602 | 316 |
| Simplified Chinese | 1,602 | 76 |
| Traditional Chinese | 1,050 | 422 |

Consequential findings included quota-cycle labels mistaken for reset countdowns, screen video described as audio, browser selection reading described as automatic selection, and privacy labels confusing IP geolocation or recognized barcodes with other concepts. Screenshot recognition labels now cover both QR codes and barcodes, matching its unrestricted Vision request. Count-neutral wording avoids invalid singular/plural combinations where callers do not select plural forms. Korean variable-name messages handle vowel/consonant-dependent particles.

Permission terminology was checked against installed Apple localization resources. The follow-up below verified the newer combined recording category and updated guidance to name both current and classic categories without assuming an OS version threshold. Root review checked the recommendations against actual callers and resolved source ambiguities, including identifying MacTools as the browser-control actor and distinguishing unavailable window information from an unavailable window.

Detailed worksheets, recommendations, approval decisions, and counts are retained locally under `build/LocalizationReview/LanguageReviews/` as ignored build artifacts. These reviewers provide independent AI linguistic proofreading, **not human native-speaker certification**. Interactive layout, direction, and language-switching results are recorded below.

## Two-model approval before interactive verification

The approved model plan used fresh reviewers with no access to the earlier recommendations or one another's initial findings. **GPT-6 Astra at extra-high reasoning** reviewed every phrase in the changed scope and its affected source copy: 16,058 phrases covering 17,006 language/key entries. **GPT-6.1 Sol at high reasoning** independently challenged permission, privacy, deletion, recovery, failure, count, and placeholder messages, all affected Marketplace vocabulary labels, and a reproducible sample of 100 other phrases per language: 6,051 phrases covering 6,379 entries. Phrase counts differ from the first review because the current copy was grouped again after its corrections.

Applied **112 additional translation-entry corrections in 15 catalogs**, with three Swift fallbacks aligned. Confirmed findings included IP geolocation mislabeled as a network location, browser-control permission messages omitting MacTools as the actor, Tab completion described as a completed status, recovery resolution described as successful restoration, and literal theme-name fields translated as schema concepts. Dynamic-name and count corrections preserve printf argument types and positions. Russian Stage Manager terminology follows [Apple's localized Mac guide](https://support.apple.com/ru-ru/guide/mac-help/mchl534ba392/mac).

Source review also corrected two promises across all 11 languages. Deleting a panel keeps its items together in another panel rather than restoring their original defaults. Cloud sync includes script text when the user opts to include that text in backups, so its description now discloses possible sensitive information instead of promising that all private data is excluded. Simplified Chinese automatic-appearance copy now explicitly limits automatic switching to Auto mode. The separate Edit button is named in source-text editing guidance.

Fresh final Astra and Sol reviewers independently checked **128 changed, contested, or source-affected phrases** against the integrated catalogs and current callers. This included three additional Traditional Chinese entries beyond the initial scope. Both final reviewers passed with no findings or unresolved context. At this pre-UI gate, the combined review covered **17,009 language/key entries**, including all **14,296 entries then changed from main**. Root integration verified every reviewed ID, recorded decisions for all 90 initial findings, preserved lookup keys and placeholders, and checked the final source and catalog hashes. One suggestion to add newer Screen & System Audio Recording navigation wording was deferred at this historical gate and resolved in the follow-up below.

| Language | Astra initial entries | Sol challenge entries | Final phrases rechecked | Approval |
| --- | ---: | ---: | ---: | --- |
| Arabic | 1,592 | 587 | 14 | AI-approved |
| German | 1,602 | 597 | 17 | AI-approved |
| English | 1,602 | 595 | 6 | AI-approved |
| Spanish | 1,592 | 596 | 8 | AI-approved |
| French | 1,578 | 593 | 11 | AI-approved |
| Japanese | 1,592 | 589 | 9 | AI-approved |
| Korean | 1,602 | 594 | 10 | AI-approved |
| Portuguese | 1,592 | 592 | 17 | AI-approved |
| Russian | 1,602 | 605 | 24 | AI-approved |
| Simplified Chinese | 1,602 | 597 | 5 | AI-approved |
| Traditional Chinese | 1,050 | 434 | 7 | AI-approved |

Pre-UI approval completed on 2026-10-04 against baseline `3442f9f8078ba5f6c9420e6c17602f4bf38a7caf` and this historical uncommitted content fingerprint:

```text
cdb19508f950abf60f3f0fa80609bc6faf247d833e618beb44d04c1ee450c48e
```

The fingerprint hashes the baseline plus the final catalog and Swift-source hash inventory. Per-packet hashes, reviewed IDs, findings, decisions, final reviews, validation logs, and the approval receipt are retained locally under `build/LocalizationReview/ModelSignoff/`. Approval means **AI-reviewed and approved**, not human native-speaker certification or interactive UI approval. Human review is optional under the agreed plan. The subsequent UI corrections and their approval receipt are recorded below; the historical fingerprint above does not identify the current files.

## Interactive UI verification

Completed after the Mac was unlocked, using a separately identified Debug app with isolated preferences and application data, 18 locally built plugin packages, and a disposable filesystem fixture. The user's regular MacTools installation and preferences were not changed. Native screenshots and accessibility trees were captured at the default 1040 × 720 settings-window size on macOS 27.

| Check | Result |
| --- | --- |
| Live language switching | General settings rendered in all 11 supported languages. Switching between Arabic and English mirrored the sidebar, content, controls, and app-owned accessibility copy without restarting. |
| Arabic surfaces | General, permissions, Marketplace list/detail/privacy, Input Remapping editor/action menu, Trackpad settings/editor, and Storage Explorer fixture were inspected interactively. Mixed Arabic/Latin product names, identifiers, and paths remained readable. |
| Long copy | German and Russian appearance controls fit without overlap. Appearance descriptions wrap, segmented controls keep their native label widths, and rows stack when necessary. |
| Titles and navigation | Long Arabic toolbar titles remain visible with truncation and full-title help. Input-flow arrows, folder drilldown/breadcrumbs, theme disclosure, and settings disclosures use semantic forward/backward direction. English title and flow direction were rechecked after switching back. |
| Custom sheets | Found Arabic sheets displaying translated copy in a left-to-right layout. All 18 custom sheet presentations now explicitly forward their presenter's locale and layout direction. Rendered Arabic theme, gesture-editor, and preferences-export sheets passed; the theme sheet returned to left-to-right after a live switch to English. Other sheets received source review and compilation, rather than individual interactive checks. |
| Keyboard and accessibility | Arabic and German ⌘K search, arrow-key selection, and Return navigation passed. The resulting page, selection hints, and app-owned accessibility labels changed with the language. This was accessibility-tree inspection, not a full VoiceOver session. |
| Retained Storage Explorer results | A 3.3 MB fixture scan and its selected Documents folder survived Arabic-to-English switching. A 7 MiB marker added after scanning remained absent, while scan age continued advancing: the language change did not rescan. Arabic-to-German retention also passed. No trash operation was executed. |

The UI pass also fixed clipped Marketplace refresh/update buttons and a recognized category rendered as a raw identifier. A focused **GPT-6 Astra extra-high** review and independent **GPT-6.1 Sol high** challenge examined 77 additional copy units across all 11 languages. Applied **34 corrections in four catalogs**, covering Arabic action names, gesture terminology, local development, Marketplace refresh, and appearance labels. Installed Apple localization resources provided terminology evidence. Root integration verified that these 34 substitutions were the only catalog changes since the pre-UI approval; keys, source values, translation states, and placeholders were preserved.

Sol independently reviewed the final UI deltas in **17 Swift source files**, including all 18 sheet presentations, with no actionable findings. The combined approval retains the historical two-model review, adds both models' copy-delta review and the final source review, and records successful rendered checks and validation. The first interactive round recorded this historical catalog/source inventory fingerprint:

```text
845d6dbcf1fc6241f335264a5f588c0ae59ec22bfe4600deaa3d5ce282375f01
```

That first-round receipt, exact catalog-delta verification, source hashes, review packets, test logs, screenshots, and accessibility trees are retained under `build/LocalizationReview/07a89fe5/UI/`. Representative evidence includes `arabic-title-final.png`, `arabic-theme-sheet-fixed.png`, `arabic-gesture-sheet-fixed.png`, `arabic-export-sheet-fixed.png`, `german-general-fixed.png`, and `english-storage-final-retained.png`. `arabic-layout-verified.jpg` provides a directly viewable Arabic layout example. The isolated review app was closed after verification. This report records the reviewed localization milestone; Git records the saved source snapshot.

## Follow-up coverage and prerequisites

A refreshed compiled-bundle check passed for all **55 permission-purpose translations** in `InfoPlist.strings` and all **209 Right Click translations** in the actual Finder extension, across all 11 languages. The App Intents framework contains extracted metadata for its action, entity, and shortcut. The isolated review app passed strict ad hoc signature verification. These receipts are retained under `build/LocalizationReview/07a89fe5/Remaining/`.

The unlocked follow-up found and fixed retained startup-language plugin introductions and permission-page feature names. A shared host contract test now checks English → Arabic → English, preserving distinct custom introductions. Logical navigation and disclosure glyphs now follow text direction across the remaining host/plugin surfaces; physical window positions, display movement, screenshot selection, Launchpad grid paging, and hidden menu-item order retain their physical direction.

An expanded audit of independent AppKit-to-SwiftUI hosting boundaries fixed locale and direction propagation in native windows, popovers, and HUDs. This covers AI Assistant, Translator, Clipboard History and its privacy/sequential-paste HUDs, Calendar popovers, System Status panels, Window Layouts HUDs, Quit Apps, System Soft Restart, Xcode Clean, Fix Damaged App, Sidecar cell editors, Launchpad text controls, hidden menu-item panels, Window Switcher, host detail panels, run-link feedback, and component-library previews. Native titles and accessibility copy refresh; cached bitmap previews are invalidated for the new language. Existing editor/selection identity, user content, physical placement, and operation state are preserved. Window Switcher retains typed failure diagnostics and reprojects their text without capturing again. These boundaries received independent source review and compilation; every window was not rendered interactively.

| Follow-up interactive check | Result |
| --- | --- |
| Arabic Window Layouts preset sheet | The current value stays on the right, the proposed value on the left, and the flow arrow points left. The sheet was cancelled without applying shortcuts. |
| Arabic Mac Settings profile editor | Labels and controls fit with right-to-left layout. The editor was cancelled without saving or applying system settings. |
| Shared live language switching | Window Layouts introductions and permission-page feature names updated from Arabic to English without restart. The updated Arabic recording guidance fit without clipping. |
| System recording category route | The app's permission action opened the native **Screen & System Audio Recording** pane on macOS 27. Its **System Audio Recording Only** subsection was also verified. No access switch was changed. |
| Fresh Calendar request | A nineteenth plugin was installed only in the isolated app. Request activation reached Calendar/TCC services, but the native prompt and denial were not verified: the computer-use tool blocks access to `com.apple.UserNotificationCenter`. The review app was closed without granting access. |

Screenshot and Translator permission guidance now names both **Screen & System Audio Recording** and **Screen Recording** in all 11 languages, using exact category names from installed Apple resources. The current category is also documented in [Apple's Mac guide](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac). Fresh Astra extra-high and Sol high reviewers independently reviewed all **22 entries**, corrected Traditional Chinese quote boundaries and Korean spacing, and polished Arabic, Spanish, and Portuguese phrasing. Both reviewers passed the final applied values with zero findings or uncertainties; both Chinese source fallbacks match.

Sol independently approved the frozen follow-up changes in **42 production Swift files and two focused test files**, including state preservation and physical-direction exclusions. The final gate verifies that the 22 guidance values are the only follow-up catalog substitutions, all earlier reviewed catalogs remain unchanged, source/test hashes match the reviewed snapshots, and validation receipts pass. The superseding catalog/source fingerprint is:

```text
41a0cb14c02c06e5b40ffc4e25313067cef5f100c8c364c274e9440450a6c0c5
```

The final follow-up receipt is `build/LocalizationReview/07a89fe5/Remaining/approval.json`. Source snapshots, both copy reviews, test logs, and exact delta checks are retained beside it. New rendered evidence under `UI/` includes `arabic-window-preset-fixed.jpg`, `arabic-mac-profile-sheet.jpg`, `arabic-permissions-followup.jpg`, and `english-window-layout-introduction-followup.jpg`. The isolated app was closed; the regular MacTools installation was untouched. This report records the reviewed localization milestone; Git records the saved source snapshot.

| Remaining integration | Prerequisite or limit |
| --- | --- |
| Finder activation and relaunch | A separate host/extension build now uses matching isolated bundle IDs, URL scheme, configuration path, and support store. Ad hoc verification passed; the Finder extension has not been enabled. A person must approve that permission before runtime verification. |
| Native permission prompt and denial | The user confirmed the fresh Calendar prompt was entirely English and granted it. The agent then revoked access only for the separate permission-test app and verified English and Arabic denial/recovery guidance. Native Don’t Allow selection itself was not tested. |
| Siri and Shortcuts registration | Native Shortcuts discovered the review app’s English action and description, but execution reported that Shortcuts could not communicate with the app. The new isolated build was not discovered. Siri invocation and actual Shortcuts execution remain pending. |
| VoiceOver speech | Keyboard navigation and accessibility text were inspected. VoiceOver caption inspection timed out twice, and no audio capture is exposed. VoiceOver was restored to its original off state; a person must verify speech. |
| Hardware/account flows | Require the relevant connected device or account and feature access; availability was not established for every flow. |
| Release signatures | Require a signed release build for inspection. No publishing, notarization, or tagging was performed. |

## Review boundaries

Source review covered literal UI/help/accessibility strings, computed localization wrappers, retained copy, formatter use, fallback resolution, bundle ownership, and manifest product-string projection. Existing manifest tests validate localized product metadata and generated website data. Vendor names such as Secret Access Key, process output, user text, file paths, native language names, search aliases, and protocol timestamps intentionally retain their original form. Finder Sync reads the host's language override across its process boundary; App Intents and permission dialogs also participate in system-managed localization.

The static auditor recognizes the repository's current wrappers and closed Marketplace vocabularies. It is not a Swift parser: arbitrary computed keys, interpolated App Intent phrases, custom future wrappers, and printf plural substitutions need compiler/feature coverage or review. Compiled-resource tests check singular translations in host, Right Click, PluginKit, App Intents, and plugin bundles; Info.plist permissions and `.stringsdict` plural selection remain outside that test.

The requested interactive Arabic layout, long German/Russian copy, live switching, and keyboard/accessibility checks are completed within the scope above. System-managed AppKit menus, dialogs, and accessibility role/symbol descriptions can retain the process launch language after an in-app language change; relaunch refreshes them. Arabic native folder-picker text was verified after an Arabic launch, and German native menus after a German launch. The subsequent guided session verified the Calendar permission prompt and denied-access guidance, as recorded above. Finder relaunch behavior, Siri invocation, actual Shortcuts execution, VoiceOver speech, hardware/account interactions, and signed release packages remain pending. The rendered checks do not cover every plugin screen or every macOS version. AI approval does not establish human native-speaker certification or every possible runtime localization path.

## Validation

- The final strict `make validate-localization` passed with zero missing supported-language translations; the final script suite repeated the 74-table, 6,082-key, 6,724-reference audit after the follow-up fixes.
- `make generate` and focused unsigned XCTest builds passed. Coverage includes compiled resources, Storage Explorer presentation/state, Trash permission failure behavior, Device Battery, AI Usage state, automation, search, host commands, and Hide Notch.
- The final compiled-resource XCTest passed after applying all linguistic corrections and aligning the affected fallbacks: one test passed, with no failures or skips.
- All 226 `make script-tests` checks passed after the linguistic review, including the localization auditor, changelog checks, manifest/generated-asset validation, and minimum-host compatibility checks. Foundation rendering also verified all eight changed positional formats, including recognition counts of 1, 2, and 11.
- Website `npm run build` and `npm test` passed, covering language preference changes, blocked storage, cached navigation, generated titles/metadata, and action feedback.
- `make validate-changelog` and `git diff --check` passed.
- After the two-model corrections, strict localization validation, all 226 script tests, and the compiled-resource XCTest passed again. The compiled-resource result recorded one passing test, no failures, and no skips. That pre-UI approval also verified both models' complete recheck coverage and its unchanged content fingerprint.

- After all interactive corrections, `make test TEST_FILTER='LocalizationResourceTests SettingsNavigationCoordinatorTests'` passed: eight tests, no failures or skips. All 226 script tests passed again, including strict localization and changelog validation. The first-round approval gate verified the exact 34-entry catalog delta and independent review hashes for its 17 changed UI source files.

After the expanded follow-up, all app/plugin targets compiled and **20 focused tests passed, with no failures or skips**. Coverage checks compiled resources, host metadata switching, secondary-panel state, Clipboard History action/paste state, Xcode Clean selections, run-link feedback, and Window Switcher preview/lifecycle behavior. All **226 script checks** passed with zero localization gaps, followed by final changelog and whitespace checks. The follow-up gate verifies the exact 22-entry copy delta, all 42 reviewed source hashes, both reviewed test hashes, and the superseding fingerprint above.

The local script suite required `SDKROOT` to point to the active Xcode macOS 26.5 SDK because `/usr/bin/python3` inherited a newer Command Line Tools SDK. The successful invocation was:

```sh
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk make script-tests
```

Focused native verification can be repeated with:

```sh
make test TEST_FILTER='LocalizationResourceTests EmptyTrashPluginTests DeviceBatteryPluginTests StorageExplorerControllerTests StorageExplorerPresentationTests AIUsageViewModelTests AutomationRuntimeTests'
```

## Draft PR integration

The reviewed localization milestone was saved as `b322e1f0c5347b15e661fe1cca4fc9b717a6b4c3`. The PR branch then integrated `origin/main` at `28c3bd43`, including Storage Explorer's retained-snapshot Trash behavior from #459. The merge preserves its snapshot accounting, cache ordering, navigation, selection, and failed-item review. Typed Trash failures now refresh their displayed messages after a language change without rescanning. The earlier catalog/source fingerprints identify their historical localization snapshots; they do not identify this merged source inventory.

Focused integration verification ran `make test TEST_FILTER='StorageExplorerControllerTests StorageExplorerSnapshotTests StorageExplorerProgressTests StorageExplorerPresentationTests'`: **42 tests passed, no failures or skips**. Failed and partial Trash tests also verify message refresh, retained review items, and an unchanged scan count. Test results and the separate integration review are retained under `build/LocalizationReview/07a89fe5/Remaining/`.

Full CI exposed a Clipboard History action-symbol mismatch: the reviewed runtime uses semantic `chevron.backward`, while the source manifest still declared `chevron.left`. The manifest and its two generated website projections now agree with the runtime. The existing `PluginRuntimeActionSnapshotTests` contract check passed after this correction. Sol independently approved both the Storage Explorer integration and the three exact manifest/generated deltas, with no findings or uncertainties. Historical signed catalogs remain unchanged.

Final `SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk make ci` passed against the integrated source and corrected metadata: **226 script checks, 2,657 native tests, no failures**, and the frozen PluginKit v7 binary client passed. Four Window Switcher desktop tests were skipped by their existing `MACTOOLS_RUN_DESKTOP_TESTS` opt-in gate. The earlier focused desktop session is recorded above; the full CI run did not opt into those checks. The exact summary and CI log are `Remaining/pr-ci-final-summary.json` and `Remaining/pr-ci-final.log`. All milestone translation catalogs remain unchanged after integration, and the separate review hashes match the merged controller/test and metadata/generated files.

Representative screenshots from the milestone UI session are committed for PR review:

| Entry point | Evidence |
| --- | --- |
| Settings → General, Arabic | [Before UI corrections](assets/localization-2026-10-04/arabic-general-before.jpg), [after UI corrections](assets/localization-2026-10-04/arabic-general-after.jpg) |
| Settings → General, switch Arabic → English | [English presentation](assets/localization-2026-10-04/english-after-arabic-switch.jpg) |
| Marketplace → AI Assistant | [Arabic details](assets/localization-2026-10-04/arabic-marketplace-detail.jpg) |
| Window Layouts → Shortcut Presets | [Arabic sheet](assets/localization-2026-10-04/arabic-window-preset.jpg) |

These images show the isolated review app and contain no permission settings or user documents. They precede the latest-main integration; no new Trash UI operation was performed. The subsequent guided session passed Arabic dark General settings, the dark theme picker, a custom themed panel, and switching to English with keyboard search. The automated evidence follow-up below supplies the additional theme screenshots and interaction recording.


## Guided checks and live metadata follow-up

On 2026-10-05, the user confirmed the Arabic dark settings, theme picker, custom panel, English keyboard interaction, and entirely English native Calendar permission prompt. The agent verified English relaunch menus, Calendar opening the selected date, and English/Arabic denied-access guidance after revoking only the permission-test app. The normal Nightly app’s access and preferences were preserved. Denial was established through System Settings revocation rather than the native prompt’s Don’t Allow button.

Automated interaction exposed another live-switching gap: Quit Apps’ command-palette name and description stayed English after switching to Arabic, although its native chooser was Arabic. The follow-up changes stored metadata in 58 plugins to current-language getters, reprojects cached Marketplace metadata without reloading plugin code, preserves stable IDs and business state, and retains structured errors in eight plugins so their app-owned text can be projected in the current language. Fan writer failures also retain typed app-owned reasons while preserving opaque system diagnostics. Cloudflare R2’s existing native upload windows and screenshot-pin tooltips observe language changes without restarting uploads, rewriting user input, or resetting progress/zoom.

The rebuilt isolated app passed English → Arabic → English switching for Quit Apps’ command-palette title, plugin subtitle, help, and native chooser. Both choosers were canceled without quitting apps. The Arabic System Soft Restart confirmation was inspected and canceled without executing a restart; its system-owned Cancel button retained the English process launch language.

Focused tests protect same-instance action presentation, cached host management metadata without loading/reactivating plugins, denied-permission presentation without restarting monitoring, and retained fan failure presentation without additional hardware writes. Existing fan and battery rollback tests remain part of verification. Exact check logs, stable source fingerprints, and the independent two-stage review receipt are retained locally under `build/LocalizationReview/07a89fe5/Manual/LiveRefreshFix/`. The guided checklist and isolated-build identities are recorded under `Manual/`.

The user requested that accessible UI checks be automated. Further human involvement is limited to actual permission decisions, speech output unavailable through the tools, unavailable device/account or macOS prerequisites, and signed release evidence. Shortcuts discovery alone does not establish successful invocation. AI language approval remains distinct from human native-speaker certification.

## Latest-main integration: Turkish support and Marketplace focus

Integrated canonical `main` at `569d8690`, including Turkish support from #462 and the Marketplace focus-outline fix from #465. Eighteen string-catalog conflicts were JSON formatting conflicts: a recursive three-way merge found no competing unequal translation edits. The semantic merge initially preserved all 66,433 existing non-Turkish catalog localizations and all 5,851 upstream Turkish catalog localizations.

The combined inventory exposed 232 Turkish gaps in copy added by this audit or in System Soft Restart’s hand-authored table. Added Turkish translations for those entries, preserving printf argument types and AI prompt variables. Turkish now participates in strict completeness validation, and the manifest schema declares the Turkish properties it requires. Regenerated website metadata uses all twelve locales. The strict inventory contains 74 tables, 6,083 keys, and 6,729 resource references, with no discovered translation gaps.

Earlier interactive screenshots, eleven-language linguistic approvals, and live-switching checks remain historical evidence for their recorded source snapshots. They do not establish Turkish runtime UI verification or a complete linguistic review of upstream Turkish copy. Source integration checks and independent review receipts are recorded under `build/LocalizationReview/07a89fe5/Manual/MainIntegration569d8690/`; outstanding device, account, speech, Finder activation, Siri/Shortcuts invocation, and additional UI-evidence checks remain as stated above.

A separate read-only AI language review examined all 232 Turkish additions, six standard templates, and eleven requirement names. It corrected the on/off control label, toggle-state wording, and Apple Shortcuts terminology. Input Monitoring captions and guidance also use Apple’s [Giriş İzleme](https://support.apple.com/tr-tr/guide/mac-help/mchl211c911f/14.0/mac/14.0) terminology, including 26 inherited Turkish catalog entries; Apple’s Turkish app name is [Kestirmeler](https://support.apple.com/tr-tr/guide/shortcuts-mac/apdf22b0444c/mac). This targeted AI review is not human native-speaker certification.

## Automated UI evidence follow-up

On 2026-10-05, automated checks used the compiled `c6e077e1` Debug app on macOS 27.0.1, with a separate bundle identifier, preferences, support store, and locally built Appearance/System Status plugins. Only the fixture received local ad hoc signatures. The regular app was unchanged; the isolated app was returned to English and closed after checking.

| Entry point and result | Evidence |
| --- | --- |
| General, Arabic dark appearance; right sidebar and readable controls | [Dark settings](assets/localization-2026-10-05/arabic-dark-general.jpg) |
| General → Theme; Arabic sheet direction and One Dark selection | [Default theme](assets/localization-2026-10-05/arabic-dark-theme-picker.jpg), [One Dark selected](assets/localization-2026-10-05/arabic-dark-custom-theme-picker.jpg) |
| Search → Panel 2; Arabic feature row with One Dark applied | [Custom themed panel](assets/localization-2026-10-05/arabic-custom-one-dark-panel.jpg) |
| Arabic → English; Command-K, search, Down/Up selection, Return opens Permissions | [10-second interaction capture](assets/localization-2026-10-05/arabic-english-keyboard-navigation.mp4), [English light settings](assets/localization-2026-10-05/english-light-general.jpg) |
| Turkish host and plugin settings; translated titles, controls, and wrapped descriptions | [General](assets/localization-2026-10-05/turkish-light-general.jpg), [System Status](assets/localization-2026-10-05/turkish-light-system-status-settings.jpg) |

The recording encodes 78 sequential live CUA window snapshots with their original elapsed timing; it contains no audio. The original JPEG captures are preserved, and the video decoded without errors. [Evidence metadata](assets/localization-2026-10-05/evidence.json) binds these artifacts to the checked source snapshot. No app code or translation resources changed during this evidence session. Both GitHub checks passed at `c6e077e1`.

The PR's representative light/dark/custom-theme and interaction evidence is complete. Turkish runtime rendering is now checked on these two representative pages; review of every upstream Turkish phrase and every plugin screen remains outside that result.

| Remaining check | Importance and automation limit |
| --- | --- |
| Finder activation, native permission decisions, Siri/Shortcuts execution | Important for the affected integrations. Permission approval needs the user; subsequent UI checks can be automated. The existing Shortcuts communication failure still needs diagnosis and successful execution. |
| VoiceOver speech | Important accessibility follow-up. Accessibility text and keyboard behavior are checked; spoken output needs human listening with the available tools. |
| Device/account flows and other supported macOS versions | Useful integration coverage when the required environment is available. Most checks can be automated after the prerequisite is supplied. |
| Broader Turkish proofreading and remaining windows/HUDs | Additional coverage can use AI review and accessible UI automation. It does not imply human native-speaker certification. |
| Signed release package | Required before release, with explicit release intent and signing setup. This PR does not publish, notarize, or tag a release. |

These remaining items do not prevent ordinary PR review. Cleanup and restart execution were not performed or counted as passing checks.
