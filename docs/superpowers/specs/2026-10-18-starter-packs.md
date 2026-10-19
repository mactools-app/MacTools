# Optional starter packs

Starter packs are host-owned Marketplace flows using the existing catalog installer, Settings history, panel library, and permission guidance. They do not introduce a package format or change plugin manifests.

## Shared catalog

`Sources/Resources/StarterPacks.json` is bundled into the host and imported directly by the website. It defines the stable IDs, localized names and summaries, plugin membership, permission summaries, and recommended panel items for seven packs:

- Everyday Essentials (`everyday`): six everyday controls with no macOS permission requirements.
- Windows & Workspace (`windows`): seven window, app-launching, and workspace tools.
- Writing & Clipboard (`writing`): six clipboard, input-language, translation, capture, and shortcut tools.
- Meetings & Presentations (`meetings`): seven calendar, audio, capture, and display tools.
- Displays & Desk (`displays`): seven display, lighting, audio, Sidecar, and Dock tools.
- Developer Tools (`developer`): seven package, script, shell, cache, network, and clipboard tools.
- Storage & Maintenance (`maintenance`): five disk analysis, cleanup, and eject tools.

Membership overlaps intentionally. Together the packs contain 33 unique plugins. Website checks validate referenced plugins, localized fallback titles, permission IDs, and recommended panel capabilities against the manifests.

Native pack titles, summaries, permission descriptions, and workflow copy cover all 12 supported app languages. Plugin fallback names match the localized manifests, including in an empty profile. The website retains its English and Chinese presentation.

## Selection and navigation

New users see Everyday Essentials suggested, with Start Empty and Restore Backup available. Existing users start with no packs selected and panel additions disabled. The chooser displays each pack's plugin list, installed count, and permission summary directly in a responsive one-, two-, or three-column grid.

Pack checkboxes are additive. Removing one retains plugins shared with another selected pack and never uninstalls anything. Review presents a stable, ordered union with one checkbox per plugin; unchecked rows remain visible and reversible. Individual exclusions survive adding or removing other packs. Select All respects those exclusions; Clear Selection resets them.

During onboarding, the footer provides Set up later. This opens Marketplace, saves the draft, and suppresses automatic onboarding until Continue setup is chosen. Closing the window or quitting preserves unfinished onboarding and its selected packs, exclusions, and layout options for the next launch. Start empty explicitly completes onboarding without installing anything. Existing users retain Back to Marketplace. The breadcrumb also links to Marketplace. Review shows pending downloads, optional panel additions, selected-plugin permissions, and optional grid changes. Existing grids are described as preserved rather than used to illustrate a new pack.

## Applying a combined selection

Only missing packages download. Each selected plugin installs once, and only usable plugins contribute reviewed placements. Existing items anywhere retain their placement and identity. Recommended items are deduplicated across packs; settings-only tools do not gain invented panel items. Installing does not run cleanup, scripts, or system actions.

When Action Grid and Window Layouts are selected, users can opt into Left Half, Right Half, and Maximize in an empty grid. Grid seeding and Control-Option-Space assignment are off by default. The host rechecks grid contents and shortcut assignments after installation. An occupied or unreadable grid is never overwritten; shortcut assignment uses the existing conflict validator.

Applying freezes the selected packs, plugin choices, and layout options. Further selection changes and links cannot replace a running batch. Stop finishes the current installation and skips remaining downloads. Partial failures retain successes; Review and Retry restores the applied selection and downloads only remaining packages. Background progress remains visible in Settings.

The catalog manager owns one shared refresh request. Startup, Marketplace, pack setup, plugin details, and backup import await that request; leaving a page does not cancel it. Missing-plugin downloads wait for a loaded catalog. Import previews show catalog failures and Retry, refresh installation choices after recovery, and still permit restoring available settings with explicit unavailable-item warnings.

Onboarding has explicit in-progress, deferred, and completed states. Generated panel defaults do not complete it. A successful batch or backup restore completes setup; stopped or failed batches remain resumable. Pack copy uses the same preferred-language matcher as plugin metadata, with an explicit Chinese script taking precedence over region.

## Website and external navigation

The website lists all packs and their member plugins at `/packs`, with shareable pages at `/packs/<pack-id>`. The home page highlights three packs and links to the complete collection. Each detail page links member plugin pages and opens `mactools://app/settings/starter-packs/<pack-id>` for review.

Pack headings and plugin lists show the same SF Symbols in the app and website, including before plugins are installed. The entire native pack card toggles selection with checkbox accessibility, keyboard activation, a selected border, and hover feedback. Website cards open their pack page while member plugin links retain their own destinations. “Start empty” completes onboarding and opens the regular Marketplace without installing plugins.

The chooser route omits the pack ID. A first pack link replaces the untouched first-run suggestion; later links add to the user's current selection. Routes only navigate: unknown IDs and query parameters are rejected. A running batch retains its reviewed selection and shows progress when another link arrives.

Plugin detail links can open before the catalog loads. They show loading, recoverable errors, or a confirmed unavailable state after resolution. Installed plugin details remain available offline; configuration links and executable actions retain their existing availability checks.

Website links require a MacTools release containing this feature. Publish the website and compatible app together. Updating source does not establish availability in the published app. Pack pages retain the existing language/theme controls, localized metadata, and cached-history restoration.
