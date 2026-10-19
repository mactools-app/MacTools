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

New users see a dedicated native setup window with three steps: Choose, Review, and Ready. Everyday Essentials is suggested among four recommended packs (Everyday, Windows, Writing, and Meetings); Browse All Seven expands the full collection. Each card shows its plugins immediately, and a combined sample panel preview updates with the selection. Start Empty and Restore Backup remain available.

The preview shows the bundled MacTools menu-bar icon, the actual panel header and row renderer, and sample widgets using the shared component surfaces. A neutral inset background separates the illustration from the setup window; a continuous popover arrow points at the icon in both layout directions. It retains the native 316-point panel width, follows the app appearance and panel theme, and scrolls its sample content independently from the selection. Native controls are rendered into read-only snapshots; the preview never loads plugins, requests permissions, invokes actions, or adds controls to keyboard navigation.

Existing users keep the complete chooser in Marketplace, starting with no packs selected and panel additions disabled. The chooser displays each pack's plugin list, installed count, and permission summary directly in a responsive one-, two-, or three-column grid. Settings opens independently from first-launch setup.

Pack checkboxes are additive. Removing one retains plugins shared with another selected pack and never uninstalls anything. Review presents a stable, ordered union with one checkbox per plugin; unchecked rows remain visible and reversible. Individual exclusions survive adding or removing other packs. Select All respects those exclusions; Clear Selection resets them.

During onboarding, Set Up Later opens Marketplace, saves the draft, and suppresses automatic onboarding until Continue Setup reopens the dedicated window. Closing asks for confirmation and explains that choices are preserved for the next launch, or that installation continues in the background. Quitting also preserves unfinished setup. Start Empty explicitly completes onboarding and opens Marketplace without installing anything. Restore Backup uses the same picker, preview, catalog recovery, and progress presentation as Settings; canceling returns to setup with its draft intact. Review shows pending downloads, optional panel additions, selected-plugin permissions, and optional grid changes. Existing grids are preserved.

Onboarding Review uses a compact plugin checklist with dividers and independent scrolling, with panel settings below and optional Action Grid settings collapsed initially. Ready confirms the selected packs, explains the MacTools menu-bar icon and where all seven packs remain available, and offers Edit Selection, Open Panel, and Explore Marketplace. When no panel can be opened, Marketplace is the single primary destination. Pack deep links open Review in the setup window while onboarding is unfinished, and in Settings for established users. Installation progress, stop, partial failures, and retry remain available in both presentations.

## Applying a combined selection

Only missing packages download. Each selected plugin installs once, and only usable plugins contribute reviewed placements. Existing items anywhere retain their placement and identity. Recommended items are deduplicated across packs; settings-only tools do not gain invented panel items. Installing does not run cleanup, scripts, or system actions.

When Action Grid and Window Layouts are selected, users can opt into Left Half, Right Half, and Maximize in an empty grid. Grid seeding and Control-Option-Space assignment are off by default. The host rechecks grid contents and shortcut assignments after installation. An occupied or unreadable grid is never overwritten; shortcut assignment uses the existing conflict validator.

Applying freezes the selected packs, plugin choices, and layout options. Further selection changes and links cannot replace a running batch. Stop finishes the current installation and skips remaining downloads. Partial failures retain successes; Review and Retry uses the latest saved draft and downloads only remaining packages. Previous results and their preview retain the applied snapshot without overwriting later edits. Continue Setup opens the saved selection; View Results explicitly opens the previous batch. Background progress remains visible in Settings.

Backup restoration and pack setup are mutually exclusive for their entire duration. The conflicting action stays disabled with an explanation, and the host rechecks before applying changes. Browsing and pending selections remain available.

The catalog manager owns one shared refresh request. Startup, Marketplace, pack setup, plugin details, and backup import await that request; leaving a page does not cancel it. Missing-plugin downloads wait for a loaded catalog. Import previews show catalog failures and Retry, refresh installation choices after recovery, and still permit restoring available settings with explicit unavailable-item warnings.

Onboarding has explicit in-progress, deferred, and completed states. Generated panel defaults do not complete it. A successful batch or backup restore completes setup; stopped or failed batches remain resumable. Pack copy uses the same preferred-language matcher as plugin metadata, with an explicit Chinese script taking precedence over region.

## Website and external navigation

The website lists all packs and their member plugins at `/packs`, with shareable pages at `/packs/<pack-id>`. The home page highlights three packs and links to the complete collection. Each detail page links member plugin pages and opens `mactools://app/settings/starter-packs/<pack-id>` for review.

Pack headings and plugin lists show the same SF Symbols in the app and website, including before plugins are installed. The entire native pack card toggles selection with checkbox accessibility, keyboard activation, a selected border, and hover feedback. Website cards open their pack page while member plugin links retain their own destinations. “Start empty” completes onboarding and opens the regular Marketplace without installing plugins.

The chooser route omits the pack ID. A first pack link replaces the untouched first-run suggestion; later links add to the user's current selection. Routes only navigate: unknown IDs and query parameters are rejected. A running batch retains its reviewed selection and shows progress when another link arrives.

Plugin detail links can open before the catalog loads. They show loading, recoverable errors, or a confirmed unavailable state after resolution. Installed plugin details remain available offline; configuration links and executable actions retain their existing availability checks.

Website links require a MacTools release containing this feature. Publish the website and compatible app together. Updating source does not establish availability in the published app. Pack pages retain the existing language/theme controls, localized metadata, and cached-history restoration.
