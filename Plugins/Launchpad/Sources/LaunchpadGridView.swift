import AppKit
import MacToolsPluginKit
import SwiftUI

/// The launcher content: a focused search field over a horizontally **paged** app grid
/// (classic Launchpad layout).
///
/// Input model (Codex P0 #2/#3): the `NSSearchField` is first responder, so typing /
/// IME composition just works while the grid stays visible ("grid-first, type to
/// search"). Arrow keys move the grid selection and Return launches — routed through
/// the field's `doCommandBySelector`, which the system does NOT call during IME
/// composition, so a candidate-selecting Return never launches an app.
///
/// Paging (LP4b): macOS SwiftUI has no `PageTabViewStyle`, so pages are laid out in a
/// single clipped `HStack` and slid by an `offset`. `selectedIndex` is the source of
/// truth; the visible page is derived from it (`selectedIndex / perPage`), so keyboard
/// navigation, page dots and drag all stay consistent.
struct LaunchpadGridView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var catalog: LaunchpadAppCatalog
    /// Custom-order layout. Observed so a reorder / reset (which mutates `@Published layout`)
    /// re-evaluates `filtered` and re-renders — the overlay grid does NOT observe
    /// `onStateChange`, so this injection is the only reorder-refresh path (design §5.5 / R1).
    @ObservedObject var layoutStore: LaunchpadLayoutStore
    /// Shared across the root pages and the open folder; owns the finger-bound carry session.
    /// Injected (the overlay controller owns it) so overlay teardown can abort an in-flight carry —
    /// the floating icon is a separate NSWindow that would otherwise outlive the launcher.
    /// `@ObservedObject` so its `@Published` commit token re-renders this view: the commit visuals
    /// are requested from an AppKit mouseUp handler, where a captured-closure `@State` write
    /// doesn't invalidate. The token is VISUAL-only — data lands via the injected storeApplier.
    @ObservedObject var dragCoordinator: LaunchpadDragCoordinator
    /// Fixed column count, or `LaunchpadPreferences.autoColumns` (0) to fit to width.
    var columns: Int = LaunchpadPreferences.autoColumns
    /// Compact (centered panel) vs fullscreen — tightens padding and, since a small
    /// panel dismisses by clicking *outside* it (→ app resigns active), drops the
    /// inside-the-panel click-to-dismiss that fullscreen Launchpad uses.
    var isCompact: Bool = false
    /// Session grid metrics, injected by the overlay controller (single source, design
    /// §1.4): paging math, the AppKit page grids and the folder panel all read THIS —
    /// never a private mirror. No default on purpose (P2): construction must inject the
    /// session snapshot, so a new call site can't silently fall back to 64pt/labels-on.
    var metrics: LaunchpadGridMetrics
    /// Ids hidden from the grid (snapshot at open; the live set below seeds from it).
    var hiddenAppIDs: Set<String> = []
    /// Glass background recipe, snapshotted at `open()` like `windowMode` (design §5.4 —
    /// no live re-binding mid-session). Default = the standard preset's legacy rendering.
    var backgroundRecipe: LaunchpadBackgroundRecipe = .legacyUltraThin
    var localization: PluginLocalization = PluginLocalization(bundle: .main)
    var onActivate: (LaunchpadAppItem) -> Void
    var onReveal: (LaunchpadAppItem) -> Void
    var onHide: (LaunchpadAppItem) -> Void
    var onDismiss: () -> Void

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var currentPage = 0
    /// Hiding an app removes it from the grid immediately (live), while `onHide`
    /// persists it; seeded from `hiddenAppIDs` on appear.
    @State private var sessionHidden: Set<String> = []
    @State private var columnCount = 7
    @State private var rowCount = 5
    /// Visible order frozen at drag start, so a drop reorders against exactly what the user
    /// dragged — even if an async catalog reload lands mid-drag (design §5.3 / Codex P2).
    @State private var dragOrderSnapshot: [LaunchpadDisplayCell]?
    /// Live horizontal offset while an empty-space drag pages the grid (follow-the-cursor).
    @State private var pageDragTranslation: CGFloat = 0
    /// Debounces the end of a two-finger scroll — its accumulation lives here (shared), NOT in the
    /// per-page AppKit containers, so a sliding grid can't feed two totals into the offset.
    @State private var pageScrollEndWork: DispatchWorkItem?
    /// The open folder's id, or `nil` when no folder overlay is showing. Tapping a folder cell
    /// sets it; the scrim tap / typing / Esc clears it.
    @State private var openFolderID: String?
    /// Drives the open/close zoom explicitly. A `.transition` on the conditionally-inserted panel
    /// never animates reliably in this ZStack-over-AppKit hierarchy (the tuple-derived view has no
    /// stable identity), so the panel is always rendered while open and zoomed via this flag.
    @State private var folderShown = false
    /// Folder id whose rename field should grab focus + select-all once its panel is mounted —
    /// set by the context-menu rename action and the post-creation auto-open (design §2.5/§2.6).
    @State private var pendingRenameFocusID: String?
    /// Stable handle into the bridged rename field, so SwiftUI-side hooks (blank tap, folder
    /// close, in-folder drag start) can end the edit session explicitly (design §2.3/§2.7).
    @State private var renameController = LaunchpadFolderRenameController()
    /// Backs the `filtered` memoization. Reference type so cached cells persist across
    /// body passes; mutating it never invalidates the view (it is a pure cache).
    @State private var filteredCache = FilteredCache()
    /// Full ZStack size, captured via a background GeometryReader. The folder pop-out's
    /// `collapsedOffset` needs the whole container (its centre + the grid's chrome offset),
    /// not the post-chrome grid viewport `pagedGrid` measures. `.zero` until the first layout
    /// pass; the collapsed-offset fallback from the animation design catches that frame.
    @State private var containerSize: CGSize = .zero
    /// Shared chrome constants (search bar, paddings, page-dot reserve) — single-sourced
    /// in `LaunchpadLayoutMath.Chrome` so the settings preview can't drift (design §1.1).
    private var chrome: LaunchpadLayoutMath.Chrome { .standard(isCompact: isCompact) }
    private var semanticLayoutDirection: LayoutDirection {
        locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    /// Memoized: the reconcile projection is pure in these inputs, so a body pass
    /// that changes only paging state (`pageDragTranslation`) — i.e. every frame of
    /// a two-finger page swipe — reuses the cached cells instead of rebuilding the
    /// folder projection per frame. The cache key is the FULL input set; a stale key
    /// would surface wrong icons after paging, so every dependency is included and
    /// compared exactly (Array `==` is O(1) on the unchanged COW buffer during paging).
    private var filtered: [LaunchpadDisplayCell] {
        let inputs = FilteredInputs(
            apps: catalog.apps,
            layout: layoutStore.layout,
            sessionHidden: sessionHidden,
            searchText: searchText,
            folderEjectActive: dragCoordinator.folderEjectActive,
            carriedAppID: dragCoordinator.carriedAppID,
            carriedSourceFolderID: dragCoordinator.carriedSourceFolderID
        )
        return filteredCache.resolve(inputs) {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            // Search is a flat, folder-agnostic projection: every matching app surfaces as its own
            // `.app` cell, folders dissolved (design §6). Clearing the query returns to the layout.
            guard query.isEmpty else { return searchResults(query: query).map(LaunchpadDisplayCell.app) }
            // Layout state: custom order + folders via the pure reconcile projection. `layout == nil`
            // → alphabetical `.app`-only cells, byte-for-byte the previous behaviour (design §5.2:
            // output set == visible, only order differs).
            let cells = LaunchpadLayoutReconciler
                .reconcile(apps: catalog.apps, layout: layoutStore.layout, hidden: sessionHidden)
            // During a folder carry, hide the carried app from its source folder's thumbnail (display
            // only — the data isn't touched until release, preserving the drop-back-in revert).
            guard dragCoordinator.folderEjectActive,
                  let appID = dragCoordinator.carriedAppID,
                  let folderID = dragCoordinator.carriedSourceFolderID
            else { return cells }
            return cells.map { cell in
                guard case .folder(let id, let name, let items) = cell, id == folderID else { return cell }
                return .folder(id: id, name: name, items: items.filter { $0.id != appID })
            }
        }
    }

    /// The root-level apps among the display cells — folders excluded. Used when capturing the
    /// visible order before a reorder (a folder is already a layout node; only loose apps need
    /// folding into the layout).
    private func rootApps(of cells: [LaunchpadDisplayCell]) -> [LaunchpadAppItem] {
        cells.compactMap { if case .app(let item) = $0 { return item }; return nil }
    }

    /// Flat fuzzy search — ignores layout/folders entirely and never touches persistence
    /// (design §6); clearing the query returns to the reconciled layout for free.
    private func searchResults(query: String) -> [LaunchpadAppItem] {
        let visible = catalog.apps.filter { !sessionHidden.contains($0.id) }
        // Fuzzy (subsequence) match, ranked by relevance; ties keep alphabetical order.
        var scored: [(app: LaunchpadAppItem, score: Int)] = []
        for app in visible {
            if let s = LaunchpadFuzzy.score(name: app.name, query: query) {
                scored.append((app, s))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
        }
        return scored.map(\.app)
    }

    private var perPage: Int { max(1, columnCount * rowCount) }

    private var pageCount: Int {
        max(1, Int(ceil(Double(filtered.count) / Double(perPage))))
    }

    /// Main background, resolved from the session's recipe snapshot (never switches
    /// mid-session, so the case change carries no view-identity risk).
    /// - `.legacyUltraThin` (the default "standard" preset) is the pre-change path,
    ///   byte-identical: one `.ultraThinMaterial` fill doubling as the dismiss tap layer (G1).
    /// - `.glass` is the parameterised backdrop + a plain dim Rectangle (free — no second
    ///   effect view, §5.5 performance line) + a clear tap layer preserving the exact
    ///   click-to-dismiss semantics.
    @ViewBuilder
    private var backgroundLayer: some View {
        switch backgroundRecipe {
        case .legacyUltraThin:
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if !isCompact { onDismiss() } }
        case .glass(let material, let dimOpacity, let forcesDark):
            LaunchpadGlassBackdrop(
                material: material,
                blendingMode: .behindWindow,
                forcesDarkAppearance: forcesDark,
                // Compact panel: behind-window blur may ignore the host layer's corner
                // mask (AppKit gotcha, design §5.4 #4) — round the material itself too.
                cornerRadius: isCompact ? LaunchpadCompactPanelMetrics.cornerRadius : 0
            )
            .ignoresSafeArea()
            Rectangle()
                .fill(.black.opacity(dimOpacity))
                .ignoresSafeArea()
                .allowsHitTesting(false)
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { if !isCompact { onDismiss() } }
        }
    }

    var body: some View {
        ZStack {
            // Glass backdrop + click-to-dismiss on empty space (design §5.4). Icons and the
            // search field (AppKit NSViews) hit-test first and swallow their own clicks, so
            // only genuine empty space (gaps/margins) reaches the tap layer. In compact mode
            // the panel itself is the content, so inside clicks must NOT dismiss (outside
            // clicks deactivate the app → close). Stays OUTSIDE the paging `.offset` —
            // wrapping it would re-sample the desktop every paging frame (§5.5).
            backgroundLayer

            VStack(spacing: chrome.stackSpacing) {
                searchBar
                content
            }
            .padding(.top, chrome.topPadding)
            .padding(.bottom, chrome.bottomPadding)
            .padding(.horizontal, chrome.horizontalPadding)

            // Folder overlay = a frosted scrim + the folder panel. Both are rendered whenever a
            // folder is open and animated via `folderShown` (explicit scale/opacity, not a
            // transition — see the `folderShown` note). The grid below is interaction-disabled
            // while it's up, so a scrim tap reliably closes instead of being eaten by a cell.
            if let folder = openFolder {
                folderScrim
                    .opacity(folderShown ? 1 : 0)
                    .animation(folderShown ? folderOpenAnimation : folderCloseAnimation, value: folderShown)

                // iOS-style pop-out: the panel grows FROM the opened folder's grid cell, not from
                // the ZStack centre (animation design 2026-06-13). `collapsedOffset` slides the
                // (centred) panel onto that cell and `collapsedScale` shrinks it to a dot; opening
                // returns to `.zero` / `1`. offset + scale + opacity share ONE `.animation(value:
                // folderShown)` so the three never split into off-beat segments. No `.transition`
                // (the ZStack-over-AppKit tuple view has no stable identity — see `folderShown`).
                folderPanel(folder)
                    .scaleEffect(folderShown ? 1 : collapsedScale, anchor: .center)
                    .offset(folderShown ? .zero : collapsedOffset)
                    .opacity(folderShown ? 1 : 0)
                    .animation(folderShown ? folderOpenAnimation : folderCloseAnimation, value: folderShown)
            }
        }
        // Capture the full ZStack size for the folder pop-out's collapsed-offset math. Sits in a
        // background (never affects layout) and reports the container the centred panel lives in.
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear { containerSize = proxy.size }
                    .onChange(of: proxy.size) { _, size in containerSize = size }
            }
        )
        .onAppear {
            selectedIndex = 0; currentPage = 0; sessionHidden = hiddenAppIDs
            // The coordinator outlives this view (controller-owned): a previous session torn
            // down with its folder open would otherwise leave the Esc ladder's middle rung
            // armed forever — every later Esc would be swallowed by a folder that no longer
            // exists. Fresh session, fresh mirror.
            dragCoordinator.folderPanelDidChange(open: false)
        }
        // Mid-drag: the app left the folder → zoom the folder closed NOW while the drag continues
        // (kept mounted so the folder cell stays the live mouse-event target until release). Driven
        // by the coordinator's @Published flag so this runs in a tracked SwiftUI transaction.
        .onChange(of: dragCoordinator.folderEjectActive) { _, active in
            if active { withAnimation(folderCloseAnimation) { folderShown = false } }
        }
        // Release: VISUAL channel only. The store mutation already happened synchronously in
        // mouseUp through the coordinator's injected storeApplier (design §1.3) — if this view is
        // torn down before the token is consumed, only the close/re-select visuals are lost.
        .onChange(of: dragCoordinator.commitToken) { _, _ in
            guard let visual = dragCoordinator.pendingVisualCommit else { return }
            if case .folder = visual.origin {       // finish unmounting the (already zoomed) folder
                openFolderID = nil
                folderShown = false
                dragCoordinator.folderPanelDidChange(open: false)
            }
            // One animation for re-select + virtual-page collapse: the dot retracting and the
            // viewport falling back to the last real page read as a single motion (§6.2).
            withAnimation(pageSnap) {
                if let landingID = visual.landingID { relocateSelection(to: landingID) }
                currentPage = min(currentPage, pageCount - 1)
            }
            dragOrderSnapshot = nil
        }
        // Post-creation auto-open (design §2.6, R1=B): published at the settle REVEAL — never
        // mid-flight, where mounting the panel would fight the `settlingItemID` park visuals.
        // Declared after the commitToken handler so a folder-origin close lands first. Guards:
        // the board may have changed in the 0.25s flight (new carry adopted the gesture, typing
        // flattened to search, the folder dissolved) — then the reveal is consumed silently.
        .onChange(of: dragCoordinator.folderRevealToken) { _, _ in
            guard let id = dragCoordinator.revealedFolderID,
                  dragCoordinator.carrySession == nil,
                  isLayoutEditable,
                  folderCell(id) != nil
            else { return }
            pendingRenameFocusID = id
            openFolderPanel(id: id)
        }
        // Esc with a folder open (design §2.4 middle rung): the controller's key monitor can't
        // reach SwiftUI state, so it publishes a request and the view runs the real close path
        // (commit a live rename, zoom out). A stale request with no folder open is a no-op
        // (`closeFolder` guards on `openFolderID`).
        .onChange(of: dragCoordinator.folderCloseRequestToken) { _, _ in
            closeFolder()
        }
        // Safety net for the coordinator's folder-visibility mirror: the panel can die without
        // `closeFolder()` ever running (the open folder emptied or dissolved underneath) — re-sync
        // from the derived value so the Esc ladder can never get stuck on the folder rung.
        .onChange(of: openFolder?.id) { _, id in
            if id == nil { dragCoordinator.folderPanelDidChange(open: false) }
        }
        // Declared AFTER the commitToken handler — on a commit, the landing re-selection above
        // must win before this cancel-shaped fallback could run (§6.4, AR-8).
        .onChange(of: dragCoordinator.carryActive) { _, active in
            if active {
                // Entering a carry clears any in-flight two-finger paging residue: the deferred
                // snap work item would otherwise fire mid-carry with a stale translation (AC-6).
                pageScrollEndWork?.cancel()
                pageScrollEndWork = nil
                pageDragTranslation = 0
            } else if dragCoordinator.endReason == .cancelled {
                // A cancelled carry collapses the virtual tail page; clamp back with the snap.
                withAnimation(pageSnap) { currentPage = min(currentPage, pageCount - 1) }
            }
        }
        .onChange(of: searchText) { _, _ in
            // Design §9.1 row 6: typing mid-carry cancels the carry FIRST, before the folder
            // close and the page/selection reset. This keeps `editableAtBegin`'s safety premise
            // self-contained — a release can never classify against the flattened search cells
            // and write the store. (The folder grid's unmount hook is the second insurance: a
            // non-empty query dissolves folders, so the source grid leaves the window in this
            // same commit and would cancel too.)
            if dragCoordinator.carrySession != nil { dragCoordinator.cancelCarry(.searchActivated) }
            selectedIndex = 0; currentPage = 0
            closeFolder()        // typing dissolves folders into a flat search (animated close)
        }
        // Edge-dwell page flip (design §4.4): published by the dwell machine from the mouse-
        // tracking loop, applied here in a tracked transaction (never withAnimation inside a
        // mouse handler). Double insurance: a request withdrawn at release/cancel reads nil, and
        // a stale one is ignored unless a carry is actually live.
        .onChange(of: dragCoordinator.flipRequest) { _, request in
            guard let request, dragCoordinator.carrySession?.isCarrying == true else { return }
            goToPage(request.targetPage)
        }
    }

    private var searchBar: some View {
        LaunchpadSearchField(
            text: $searchText,
            localization: localization,
            onMove: handleMove,
            onLaunch: activateSelection,
            onCancel: handleCancel
        )
        .frame(width: chrome.searchBarWidth, height: chrome.searchBarHeight)
        .environment(\.layoutDirection, semanticLayoutDirection)
    }

    @ViewBuilder
    private var content: some View {
        if catalog.isLoading && catalog.apps.isEmpty {
            Spacer()
            ProgressView().controlSize(.large)
            Spacer()
        } else if filtered.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(
                    searchText.isEmpty
                        ? localization.string("grid.empty.noApps", defaultValue: "未找到应用")
                        : localization.string("grid.empty.noMatches", defaultValue: "无匹配应用")
                )
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .environment(\.layoutDirection, semanticLayoutDirection)
            Spacer()
        } else {
            pagedGrid
        }
    }

    /// Real pages plus one VIRTUAL tail page while a carry is live (design §6.1): an empty,
    /// zero-cost container appended from carry begin, so the page a dwell flips to is already
    /// mounted and registered. A drop on it lands at the global tail (§6.2 — the documented iOS
    /// divergence: no persistent sparse pages); afterwards the page collapses with the snap.
    private var displayPageCount: Int {
        pageCount + (dragCoordinator.carryActive && isLayoutEditable ? 1 : 0)
    }

    private var pagedGrid: some View {
        GeometryReader { geo in
            let visiblePage = min(currentPage, displayPageCount - 1)
            VStack(spacing: 10) {
                HStack(spacing: 0) {
                    ForEach(0..<displayPageCount, id: \.self) { page in
                        pageContent(page: page, columns: columnCount)
                            .frame(width: geo.size.width)
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .offset(x: -CGFloat(visiblePage) * geo.size.width + pageDragTranslation)
                .clipped()
                // OUTSIDE the .offset: this background's frame chain is clean of the paging
                // transform, so it measures the viewport (the visible page slot) in window space.
                .background(LaunchpadViewportRelay(coordinator: dragCoordinator,
                                                   pageCount: pageCount, perPage: perPage))
                // Paging is handled inside the AppKit grid: `onPageDrag` tracks an empty-space
                // drag live (follow-the-cursor) and `onPageSwipe` handles scroll; both share one
                // event-arbitration tree with per-item drag (design §5.1). Page changes animate
                // via `withAnimation` in the handlers (not a value-keyed modifier) so the live
                // drag offset and the snap stay one continuous motion.

                if displayPageCount > 1 {
                    pageIndicator(current: visiblePage)
                }
            }
            .onAppear {
                updateLayout(size: geo.size)
                dragCoordinator.currentPageDidChange(currentPage)   // @State resets per open; the coordinator outlives it
            }
            .onChange(of: geo.size) { _, size in updateLayout(size: size) }
            // Single funnel for page changes — every flip path (goToPage, snap, keyboard, hide,
            // search reset, …) mutates this one @State, so the coordinator can't miss one (§3.2).
            .onChange(of: currentPage) { _, page in dragCoordinator.currentPageDidChange(page) }
        }
    }

    /// One page rendered as an AppKit drag grid (per-item `NSDraggingSource`). Items are
    /// sliced from `filtered`; selection/activation/reorder use the global `filtered` order
    /// so navigation and ordering span the whole list.
    private func pageContent(page: Int, columns: Int) -> some View {
        let start = page * perPage
        let end = min(start + perPage, filtered.count)
        let items = start < end ? Array(filtered[start..<end]) : []
        return LaunchpadDragGrid(
            items: items,
            columns: columns,
            // Page capacity for the make-way overflow: rowCount is what sliced `items` above, so
            // the container's "off the right edge" threshold and the slice agree exactly (a
            // bounds-derived row count could drift from the indicator-reserve arithmetic).
            rows: rowCount,
            selectedID: selectedID,
            isCompact: isCompact,
            interactionEnabled: openFolder == nil,    // exactly matches overlay visibility
            // The critical seam (design §1.4): the root pages must run on the SAME
            // injected metrics as the paging math above, or the SwiftUI pager and the
            // AppKit grid disagree and cross-page carry drop points skew.
            metrics: metrics,
            localization: localization,
            iconProvider: { catalog.icon(for: $0) },
            onActivate: activateCell,
            onReveal: onReveal,
            onCopyPath: copyPath,
            onHide: hideApp,
            onMoveToFront: moveAppToFront,
            onMoveToEnd: moveAppToEnd,
            onSelect: selectCell,
            onReorder: handleReorder,
            onMakeFolder: handleMakeFolder,
            onAddToFolder: handleAddToFolder,
            // Context-menu folder actions (design §2.5, R2): rename opens the panel with the
            // title focused + selected; dissolve releases the apps back to the grid, no
            // confirmation (data is never lost — the folder is cheap to rebuild).
            onRenameFolder: { id in
                pendingRenameFocusID = id
                openFolderPanel(id: id)
            },
            onDissolveFolder: { id in
                let firstChild = folderCell(id)?.items.first?.id   // before dissolve: id vanishes after
                layoutStore.dissolveFolder(id)
                if let firstChild { relocateSelection(to: firstChild) }   // it inherits the folder's slot
            },
            onDragBegan: {
                // A root drag may escalate into a carry the moment it lifts (design §2.1): stage
                // the visible order + editability for the session (the commit resolves against
                // exactly what the user saw, §1.3) and clear paging residue synchronously — a
                // deferred scroll-snap work item must never fire mid-carry (§2.1-3 / AC-6).
                dragOrderSnapshot = filtered
                dragCoordinator.freezeVisibleOrder(filtered, editable: isLayoutEditable)
                pageScrollEndWork?.cancel()
                pageScrollEndWork = nil
                pageDragTranslation = 0
            },
            onPageSwipe: { direction in
                guard dragCoordinator.carrySession == nil else { return }   // §9.4 input freeze
                goToPage(min(currentPage, pageCount - 1) + direction)
            },
            onPageDrag: handlePageDrag,
            onPageScroll: handlePageScroll,
            onDismiss: onDismiss,
            allowsCustomOrderActions: isLayoutEditable,   // search = read-only projection
            coordinator: dragCoordinator,
            pageIndex: page
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Selected cell's layoutID for the AppKit cell highlight, derived from `selectedIndex`.
    private var selectedID: String? {
        filtered.indices.contains(selectedIndex) ? filtered[selectedIndex].layoutID : nil
    }

    /// App → launch; folder → open the overlay. Keeps the selection on whatever was activated.
    private func activateCell(_ cell: LaunchpadDisplayCell) {
        if let index = filtered.firstIndex(where: { $0.layoutID == cell.layoutID }) { selectedIndex = index }
        switch cell {
        case .app(let item): onActivate(item)
        case .folder(let id, _, _): openFolderPanel(id: id)
        }
    }

    /// Mount the folder panel and zoom it in on the next tick (the `folderShown` discipline).
    /// Shared by cell activation, the context-menu rename and the post-creation auto-open.
    private func openFolderPanel(id: String) {
        openFolderID = id
        folderShown = false
        dragCoordinator.folderPanelDidChange(open: true)   // arms the Esc ladder's middle rung
        DispatchQueue.main.async { if openFolderID == id { folderShown = true } }  // next tick → zoom
    }

    private func selectCell(_ layoutID: String) {
        if let index = filtered.firstIndex(where: { $0.layoutID == layoutID }) { selectedIndex = index }
    }

    private func copyPath(_ app: LaunchpadAppItem) {
        // Lightweight clipboard action — no lifecycle effect, so keep the launcher open.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(app.url.path, forType: .string)
    }

    private func hideApp(_ app: LaunchpadAppItem) {
        sessionHidden.insert(app.id)        // drop from this grid immediately
        selectedIndex = 0
        currentPage = 0
        onHide(app)                         // persist (settings page can restore)
    }

    /// First successful drop materialises the alphabetical snapshot into a layout, then
    /// applies the relative move; selection follows the dragged app by id to its new global
    /// index (design §5.3 / §5.5). Never writes while searching (search is read-only).
    private func handleReorder(_ draggedID: String, _ target: LaunchpadDropTarget) {
        // Reorder against the order frozen at drag start, not a list a mid-drag reload may
        // have changed (design §5.3 / Codex P2).
        let order = dragOrderSnapshot ?? filtered
        dragOrderSnapshot = nil
        // A drop that changes nothing visible must not flip alphabetical → custom mode (Codex P2).
        guard isLayoutEditable, !target.isNoOp(dragged: draggedID, in: order.map(\.layoutID)) else { return }
        layoutStore.captureVisibleOrder(rootApps(of: order))
        switch target {
        case .before(let id): layoutStore.move(id: draggedID, before: id)
        case .after(let id):  layoutStore.move(id: draggedID, after: id)
        }
        relocateSelection(to: draggedID)
    }

    /// Drag-to-stack: dropping app `draggedID` onto app `targetID` folds both into a new folder
    /// occupying the target's slot (iOS). Materialises against the order frozen at drag start —
    /// the same one the (frozen) AppKit page is showing — so the persisted order matches what the
    /// user saw, exactly like `handleReorder`. The target is always a drag-start cell, so it's in
    /// the snapshot. Selection follows to the *new folder's* id (the target app is now inside it).
    private func handleMakeFolder(_ targetID: String, _ draggedID: String) {
        let order = dragOrderSnapshot ?? filtered
        dragOrderSnapshot = nil
        guard isLayoutEditable, targetID != draggedID else { return }
        layoutStore.captureVisibleOrder(rootApps(of: order))
        let folderID = UUID().uuidString
        layoutStore.makeFolder(target: targetID, dragged: draggedID, name: folderDefaultName, id: folderID)
        relocateSelection(to: folderID)
        // macOS-native: a fresh folder opens with its name selected, ready to type (R1=B).
        // This legacy (coordinator-less) path has no settle flight, so open immediately.
        pendingRenameFocusID = folderID
        openFolderPanel(id: folderID)
    }

    /// Drag-to-stack onto an existing folder: app joins it.
    private func handleAddToFolder(_ folderID: String, _ appID: String) {
        let order = dragOrderSnapshot ?? filtered
        dragOrderSnapshot = nil
        guard isLayoutEditable else { return }
        layoutStore.captureVisibleOrder(rootApps(of: order))
        layoutStore.addToFolder(folderID, app: appID)
        relocateSelection(to: folderID)
    }

    private func moveAppToFront(_ app: LaunchpadAppItem) {
        guard isLayoutEditable, let first = filtered.first, first.layoutID != app.id else { return }
        layoutStore.captureVisibleOrder(rootApps(of: filtered))
        layoutStore.move(id: app.id, before: first.layoutID)
        relocateSelection(to: app.id)
    }

    private func moveAppToEnd(_ app: LaunchpadAppItem) {
        guard isLayoutEditable, let last = filtered.last, last.layoutID != app.id else { return }
        layoutStore.captureVisibleOrder(rootApps(of: filtered))
        layoutStore.move(id: app.id, after: last.layoutID)
        relocateSelection(to: app.id)
    }

    /// After a reorder, keep the selection on the moved item by layoutID (not position) and
    /// bring its page on screen (design §5.5: selection is identity-, not index-, anchored).
    private func relocateSelection(to id: String) {
        guard let index = filtered.firstIndex(where: { $0.layoutID == id }) else { return }
        selectedIndex = index
        currentPage = perPage > 0 ? index / perPage : 0
    }

    /// Reorders only apply in the layout state; search is a read-only flat projection.
    private var isLayoutEditable: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Name a freshly-stacked folder gets (persisted, so resolved in the user's language at creation).
    private var folderDefaultName: String {
        localization.string("folder.defaultName", defaultValue: "未命名")
    }

    private func pageIndicator(current: Int) -> some View {
        HStack(spacing: 9) {
            ForEach(0..<displayPageCount, id: \.self) { page in
                Circle()
                    .fill(Color.primary.opacity(page == current ? 0.55 : 0.18))
                    .frame(width: 7, height: 7)
                    .onTapGesture {
                        guard dragCoordinator.carrySession == nil else { return }   // §9.4 input freeze
                        goToPage(page)
                    }
                    // Mirror the cell fix: `.onTapGesture` is mouse-only, so VoiceOver /
                    // AX press needs an explicit action to actually change page. Carry the
                    // same input-freeze guard as the tap path (§9.4) so an AX-triggered flip
                    // can't move the grid out from under an in-flight carry.
                    .accessibilityAction {
                        guard dragCoordinator.carrySession == nil else { return }
                        goToPage(page)
                    }
                    .accessibilityLabel(
                        page >= pageCount
                            ? localization.string("grid.page.virtualLabel", defaultValue: "新页面")
                            : localization.format("grid.page.accessibilityLabel", defaultValue: "第 %d 页", page + 1)
                    )
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Layout + navigation

    private func updateLayout(size: CGSize) {
        // Pure capacity math lives in LaunchpadLayoutMath.pageGrid (shared with the
        // settings preview, design §1.2). Fixed columns that can't fit the width (e.g.
        // 12 × 96pt icons) are silently clamped to what fits (ruling A4, P2 default).
        let grid = LaunchpadLayoutMath.pageGrid(
            viewport: size,
            metrics: metrics,
            fixedColumns: columns == LaunchpadPreferences.autoColumns ? nil : columns
        )
        columnCount = grid.columns
        rowCount = grid.rows
        // Layout (and thus perPage) changed: keep the selection valid and re-derive the
        // visible page *from it*, so the source-of-truth selection is always on screen —
        // not stranded on a now-wrong page (Codex P1). Mid-carry the pull-back is exempt:
        // the carry may be hovering a page (incl. the virtual tail) with no selection on it,
        // and selection follows the carried item by id at commit instead (design §8).
        selectedIndex = min(max(selectedIndex, 0), max(0, filtered.count - 1))
        guard dragCoordinator.carrySession == nil else { return }
        currentPage = filtered.isEmpty ? 0 : selectedIndex / perPage
    }

    /// Book-style paged navigation: arrows move within the current page; pressing past an
    /// edge turns the page keeping the cross-axis position (→ at the rightmost column jumps
    /// to the next page's same row, etc.).
    private func handleMove(_ direction: LaunchpadSearchField.MoveDirection) {
        guard openFolder == nil, !filtered.isEmpty else { return }   // folder open → grid nav inert
        guard dragCoordinator.carrySession == nil else { return }    // §9.4: keyboard nav frozen mid-carry
        let cols = max(1, columnCount)
        let rows = max(1, rowCount)
        let per = perPage
        let page = selectedIndex / per
        let local = selectedIndex % per
        let col = local % cols
        let row = local / cols
        let lastPage = max(0, (filtered.count - 1) / per)

        var target = selectedIndex
        switch direction {
        case .right:
            if col < cols - 1, selectedIndex + 1 < filtered.count { target = selectedIndex + 1 }
            else if page < lastPage { target = (page + 1) * per + row * cols }          // next page, same row
        case .left:
            if col > 0 { target = selectedIndex - 1 }
            else if page > 0 { target = (page - 1) * per + row * cols + (cols - 1) }     // prev page, same row, last col
        case .up:
            if row > 0 { target = selectedIndex - cols }
            else if page > 0 { target = (page - 1) * per + (rows - 1) * cols + col }     // prev page, bottom row, same col
        case .down:
            if row < rows - 1, selectedIndex + cols < filtered.count { target = selectedIndex + cols }
            else if page < lastPage { target = (page + 1) * per + col }                 // next page, top row, same col
        }

        selectedIndex = min(max(target, 0), filtered.count - 1)
        withAnimation(pageSnap) { currentPage = selectedIndex / per }   // bring the selection's page on screen
    }

    private func goToPage(_ page: Int) {
        // A stale gesture/dot closure could fire after an async catalog update emptied the
        // list; avoid `filtered.count - 1 == -1` (Codex P2).
        guard !filtered.isEmpty else { selectedIndex = 0; currentPage = 0; return }
        let target = min(max(page, 0), displayPageCount - 1)   // == pageCount-1 outside a carry
        withAnimation(pageSnap) { currentPage = target }
        // Move selection onto the page so keyboard nav resumes from what's visible — except
        // mid-carry: selection follows the carried item by id at commit instead (design §8).
        guard dragCoordinator.carrySession == nil else { return }
        selectedIndex = min(target * perPage, filtered.count - 1)
    }

    private var pageSnap: Animation {
        .spring(response: LaunchpadPageAnimation.snapResponse,
                dampingFraction: LaunchpadPageAnimation.snapDamping)
    }

    /// Follow-cursor paging: while dragging empty space the page tracks the cursor; on release
    /// it snaps to the adjacent page past a threshold, otherwise springs back.
    private func handlePageDrag(_ translationX: CGFloat, width: CGFloat, ended: Bool) {
        guard dragCoordinator.carrySession == nil else { return }   // §9.4: edge dwell is the only mid-carry flip channel
        let pageW = max(1, width)                       // real page width from the AppKit grid (no @State race)
        let last = max(0, pageCount - 1)
        let cur = min(currentPage, last)
        var t = translationX
        // Rubber-band so you can't pull past the first / last page.
        if (cur == 0 && t > 0) || (cur == last && t < 0) { t *= 0.35 }
        t = min(max(t, -pageW), pageW)
        pageDragTranslation = t        // ended too: snap must read the RELEASE translation, not the previous frame's
        guard ended else { return }
        snapToNearestPage(width: pageW)
    }

    /// Two-finger trackpad paging. The raw delta arrives from whichever page container is under
    /// the (stationary) cursor; accumulating it HERE (shared) — not per-container — is what fixes
    /// the every-frame offset oscillation. The gesture ends when deltas stop for a beat (debounce),
    /// since trackpad phase is unreliable on slow drags.
    private func handlePageScroll(_ delta: CGFloat, _ width: CGFloat) {
        guard dragCoordinator.carrySession == nil else { return }   // §9.4 input freeze
        pageScrollEndWork?.cancel()
        let pageW = max(1, width)
        let last = max(0, pageCount - 1)
        let cur = min(currentPage, last)
        var t = pageDragTranslation + delta
        if cur == 0, t > 0 { t = min(t, pageW * 0.12) }            // soft over-pull at the ends
        else if cur == last, t < 0 { t = max(t, -pageW * 0.12) }
        else { t = min(max(t, -pageW), pageW) }
        pageDragTranslation = t
        let work = DispatchWorkItem { snapToNearestPage(width: pageW) }
        pageScrollEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Snap `pageDragTranslation` to the nearest page (advancing past a threshold), shared by the
    /// empty-space drag and the two-finger scroll on release.
    private func snapToNearestPage(width: CGFloat) {
        // Double insurance with the carry-entry residue clearing: the deferred scroll work item
        // must never snap mid-carry (§9.4; the entry hook already cancelled it and zeroed the
        // translation — this guard alone would freeze a stale offset on screen, AC-6/BC-2).
        guard dragCoordinator.carrySession == nil else { return }
        let pageW = max(1, width)
        let last = max(0, pageCount - 1)
        let cur = min(currentPage, last)
        let t = pageDragTranslation
        let threshold = max(45, pageW * 0.18)
        withAnimation(pageSnap) {
            if t <= -threshold, cur < last { currentPage = cur + 1 }
            else if t >= threshold, cur > 0 { currentPage = cur - 1 }
            pageDragTranslation = 0
        }
        selectedIndex = min(currentPage * perPage, max(0, filtered.count - 1))
    }

    private func activateSelection() {
        guard openFolder == nil, filtered.indices.contains(selectedIndex) else { return }
        activateCell(filtered[selectedIndex])
    }

    // MARK: - Folder overlay

    private func handleCancel() {
        if openFolderID != nil { closeFolder() } else { onDismiss() }
    }

    private func closeFolder() {
        guard let id = openFolderID else { return }
        // Disarm the Esc middle rung immediately (not at the unmount 0.34s later): a second
        // Esc during the zoom-out should already reach the close-overlay rung.
        dragCoordinator.folderPanelDidChange(open: false)
        // Closing with a rename in flight (scrim tap / typing-to-search) commits it first —
        // the panel may stay mounted for the zoom-out, so dismantle alone is too late (§2.3).
        renameController.endEditing(commit: true)
        folderShown = false                                    // zoom back out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            // Remove only if still closing THIS folder — a reopen (new id, or folderShown back true)
            // must not be wiped by this stale clear.
            if openFolderID == id, !folderShown { openFolderID = nil }
        }
    }

    /// Smooth, lightly-settled spring on open (a gentle zoom, minimal bounce — the iOS feel),
    /// a touch quicker on close.
    private var folderOpenAnimation: Animation { .spring(response: 0.50, dampingFraction: 0.78) }
    private var folderCloseAnimation: Animation { .spring(response: 0.32, dampingFraction: 0.92) }

    /// Collapsed scale of the folder panel — small enough to read as "from the cell" (~a folder
    /// thumbnail), not the historical 0.55 centre-zoom (animation design 2026-06-13).
    private let collapsedScale: CGFloat = 0.18

    /// Offset that anchors the collapsed (closed) folder panel onto its grid cell, so it grows
    /// FROM there (animation design 2026-06-13). Pure SwiftUI viewport math via
    /// `LaunchpadLayoutMath.folderCollapsedOffset` — no AppKit `convert`.
    ///
    /// Fallbacks (hard requirement — never sling the panel off-screen or compute on a half-laid-out
    /// frame): `.zero` (→ the historical centre zoom) whenever the open folder isn't found, isn't on
    /// the current page, or the container hasn't been measured yet. `firstIndex` is `nil`-guarded
    /// (the folder can dissolve within the close window) — same nil → hard-cut philosophy as the
    /// carry settle target.
    private var collapsedOffset: CGSize {
        guard containerSize.width > 0, containerSize.height > 0,
              let openID = openFolderID,
              let index = filtered.firstIndex(where: { $0.layoutID == openID })
        else { return .zero }
        let per = perPage
        let folderPage = index / per
        // The folder must be on the page that's actually on screen — a context-menu rename or a
        // post-create auto-open could target a folder on another page; fall back to centre then.
        guard folderPage == currentPage else { return .zero }
        let slot = index % per
        // Grid-container width = the post-chrome viewport `pagedGrid` measures (ZStack minus the
        // horizontal padding ring), the same width its slotRect uses, so the cell centre matches.
        let containerWidth = containerSize.width - 2 * chrome.horizontalPadding
        guard containerWidth > 0 else { return .zero }
        let cellRect = LaunchpadLayoutMath.slotRect(
            index: slot,
            columns: max(1, columnCount),
            containerWidth: containerWidth,
            metrics: metrics
        )
        return LaunchpadLayoutMath.folderCollapsedOffset(
            cellRect: cellRect,
            chrome: chrome,
            viewportSize: containerSize
        )
    }

    /// The open folder resolved from `filtered`, or `nil` when none is open *or* the open one
    /// no longer renders (emptied / dissolved underneath). Driving both the overlay and the
    /// grid's `interactionEnabled` off this one value keeps them from disagreeing — a stale
    /// `openFolderID` can never leave the grid frozen with no scrim to dismiss.
    private var openFolder: (id: String, name: String, items: [LaunchpadAppItem])? {
        openFolderID.flatMap(folderCell)
    }

    private func folderCell(_ id: String) -> (id: String, name: String, items: [LaunchpadAppItem])? {
        for cell in filtered {
            if case .folder(let fid, let name, let items) = cell, fid == id {
                return (fid, name, items)
            }
        }
        return nil
    }

    /// Frosted-glass dim behind the folder panel: a real NSVisualEffectView blur of the grid
    /// (SwiftUI `.blur` can't touch the embedded AppKit grid) + a slight darken, with a clear
    /// tap layer on top so a tap anywhere closes the folder.
    private var folderScrim: some View {
        ZStack {
            // G4: deliberately NOT linked to the background style in v1 — the folder scrim
            // is a surface floating over content, semantically independent of the backdrop.
            // Same materials the former private FrostedGlassScrim hardcoded.
            LaunchpadGlassBackdrop(
                material: isCompact ? .frosted : .launchpad,
                blendingMode: .withinWindow
            )
            .ignoresSafeArea()
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { closeFolder() }
        }
    }

    private func folderPanel(_ folder: (id: String, name: String, items: [LaunchpadAppItem])) -> some View {
        // Folder-local metrics: the session's icon size, but labels ALWAYS shown (ruling
        // A1 — finding an app inside a folder depends on its name; only the root grid
        // follows the hide-names switch). Re-derived through the single resolve entry
        // point, so when labels are globally shown this IS the injected session metrics.
        // The user's label-style selections (colour/weight/size) carry over from the
        // session metrics so the folder grid labels + big title share one appearance
        // (design 2026-06-13); these stay byte-compatible at the defaults.
        var folderMetrics = LaunchpadGridMetrics.resolve(
            LaunchpadAppearance(iconSide: metrics.iconSide, showsLabels: true))
        folderMetrics.labelColor = metrics.labelColor
        folderMetrics.labelFontSize = metrics.labelFontSize
        folderMetrics.labelFontWeight = metrics.labelFontWeight
        folderMetrics.folderTitleFontSize = metrics.folderTitleFontSize
        folderMetrics.folderTitleWeight = metrics.folderTitleWeight
        // The two-line strip follows the user's font size (only the larger tiers grow it past 32);
        // cellHeight stays the labels-shown formula (iconSide + 60) just like the root grid — the
        // fixed reserve already holds the band, so we don't widen the cell here.
        folderMetrics.labelHeight = LaunchpadGridMetrics.labelHeight(
            forFontSize: folderMetrics.labelFontSize, weight: folderMetrics.labelFontWeight)
        let cols = min(max(folder.items.count, 1), 5)              // Mac is wide; cap at 5 per row
        let rows = max(1, (folder.items.count + cols - 1) / cols)
        let gridW = CGFloat(cols) * folderMetrics.cellWidth + CGFloat(cols - 1) * folderMetrics.columnSpacing
        let gridH = CGFloat(rows) * folderMetrics.cellHeight + CGFloat(max(0, rows - 1)) * folderMetrics.rowSpacing
        // Cap the panel so a big folder can't outgrow the launcher (a compact panel is ~560-680pt
        // tall; fullscreen leaves ~700+ after chrome). Past the cap the grid scrolls; the grid's
        // scrollWheel bubbles up (folder grids don't page) so two-finger scrolling just works.
        let maxVisibleRows = isCompact ? 3 : 4
        let visibleRows = min(rows, maxVisibleRows)
        let visibleH = CGFloat(visibleRows) * folderMetrics.cellHeight + CGFloat(max(0, visibleRows - 1)) * folderMetrics.rowSpacing
        // Plate width cap, metrics-derived (design §1.1: 5 columns + the 30pt padding) —
        // replaces the historical 760 literal, which a 96pt icon row would overflow.
        // At the default 64pt this renders 672pt wide, a deliberate P2 appearance change
        // (the plate now hugs its content). Derivation + pins live in LaunchpadLayoutMath.
        let panelMaxWidth = LaunchpadLayoutMath.folderPanelMaxWidth(metrics: folderMetrics)

        return VStack(spacing: 18) {
            // Always-rendered inline-rename title: reads as a static title, edits on click
            // (design §2.2 — no Text↔TextField identity swap, no extra hover affordance, R4).
            LaunchpadFolderRenameField(
                folderID: folder.id,
                name: folder.name,
                placeholder: localization.string("folder.rename.placeholder", defaultValue: "文件夹名称"),
                titleColor: folderMetrics.labelColor.nsColor,
                titleFont: .systemFont(ofSize: folderMetrics.folderTitleFontSize,
                                       weight: folderMetrics.folderTitleWeight),
                focusRequestID: pendingRenameFocusID,
                controller: renameController,
                editGate: { dragCoordinator.carrySession == nil },   // mid-carry: no rename entry
                onCommit: { layoutStore.renameFolder(folder.id, name: $0, fallback: folderDefaultName) },
                onFocusRequestHandled: { pendingRenameFocusID = nil }
            )
            .frame(width: min(gridW, 360), height: 26)
            .environment(\.layoutDirection, semanticLayoutDirection)

            // ONE stable view identity for every folder size: an if/else here would swap SwiftUI
            // branches when the row count crosses the cap — and a mid-carry eject SHRINKS the item
            // count (the carried app is filtered out), so at the boundary the flip would dismantle
            // the grid mid-drag and the unmount hook would instantly cancel the eject it serves.
            // A ScrollView whose content fits is inert (scrolling disabled below the cap).
            ScrollView(.vertical) {
                folderGrid(folder, cols: cols, metrics: folderMetrics)
                    .frame(width: gridW, height: gridH)
            }
            .scrollDisabled(rows <= maxVisibleRows)
            .frame(width: gridW, height: visibleH)
            .launchpadHidingScrollEdgeEffect()
        }
        .padding(30)
        // Clicking the panel's own blank space (padding / title gaps) commits an in-flight
        // rename — a click on "nothing" never reaches the field's blur path by itself (§2.3).
        // Cells and the field are AppKit views that hit-test first, so they're unaffected.
        .contentShape(Rectangle())
        .onTapGesture { renameController.endEditing(commit: true) }
        // NOTE: this cap IS the rendered plate width, not a never-binding ceiling — a
        // maxWidth-only frame fills its proposal up to the cap, and the material
        // background below is applied to THIS frame. Both window modes propose more, so
        // every folder plate renders exactly `panelMaxWidth` wide (derivation above).
        .frame(maxWidth: panelMaxWidth)
        // TODO(G5): on macOS 26+ adopt `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))`
        // here (folder panel + compact floating panel only — the fullscreen backdrop stays an
        // NSVisualEffectView per HIG). `#available` gated, separate commit, Tahoe screenshots.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.10))
        )
        .shadow(color: .black.opacity(0.4), radius: 36, y: 16)
        .padding(40)
    }

    /// Same direct-tracking grid as the launcher itself → identical drag feel inside and
    /// outside a folder. Merge is disabled (no nested folders); reorder maps to the folder's
    /// child order; dragging a cell clearly OUT of the grid pulls the app out of the folder.
    private func folderGrid(
        _ folder: (id: String, name: String, items: [LaunchpadAppItem]),
        cols: Int,
        metrics: LaunchpadGridMetrics
    ) -> some View {
        LaunchpadDragGrid(
            items: folder.items.map { .app($0) },
            columns: cols,
            selectedID: nil,
            isCompact: isCompact,
            metrics: metrics,
            localization: localization,
            iconProvider: { catalog.icon(for: $0) },
            onActivate: { cell in
                if case .app(let appItem) = cell {
                    openFolderID = nil          // clear up front, in case launch doesn't tear down
                    dragCoordinator.folderPanelDidChange(open: false)
                    onActivate(appItem)
                }
            },
            onReveal: onReveal,
            onCopyPath: copyPath,
            onHide: hideApp,
            onMoveToFront: { app in
                guard let first = folder.items.first, first.id != app.id else { return }
                layoutStore.moveChildWithinFolder(folder.id, child: app.id, before: first.id)
            },
            onMoveToEnd: { app in
                guard let last = folder.items.last, last.id != app.id else { return }
                layoutStore.moveChildWithinFolder(folder.id, child: app.id, after: last.id)
            },
            onSelect: { _ in },
            onReorder: { id, target in
                switch target {
                case .before(let t): layoutStore.moveChildWithinFolder(folder.id, child: id, before: t)
                case .after(let t):  layoutStore.moveChildWithinFolder(folder.id, child: id, after: t)
                }
            },
            onMakeFolder: { _, _ in },
            onAddToFolder: { _, _ in },
            // Freeze the visible ROOT order (+ editability) the moment an in-folder drag begins:
            // if it escalates to an eject carry, the session adopts this snapshot so the commit's
            // captureVisibleOrder resolves against what the user saw, not a list a mid-carry
            // catalog reload may have changed (design §1.3 / constraint 15). A live rename commits
            // FIRST — grid cells never take first responder, so blur alone can't end it (§2.7) —
            // and its store write lands before the order freeze so the snapshot sees it.
            onDragBegan: {
                renameController.endEditing(commit: true)
                dragCoordinator.freezeVisibleOrder(filtered, editable: isLayoutEditable)
            },
            onPageSwipe: { _ in },
            onPageDrag: { _, _, _ in },
            onPageScroll: { _, _ in },
            onDismiss: {},
            allowFolderCreation: false,
            coordinator: dragCoordinator,
            folderContextID: folder.id
        )
    }
}

/// Measures the paging viewport (the visible page slot) in AppKit window space and pushes it to
/// the drag coordinator. It sits OUTSIDE the paging `.offset` — a render-only transform that never
/// enters the AppKit frame chain — so this view's own frame chain IS the viewport, with no per-page
/// correction and no y-flip guesswork (design §5.2; events pass through, hitTest nil).
private struct LaunchpadViewportRelay: NSViewRepresentable {
    let coordinator: LaunchpadDragCoordinator
    let pageCount: Int
    let perPage: Int

    final class RelayView: NSView {
        weak var coordinator: LaunchpadDragCoordinator?
        var pageCount = 1
        var perPage = 1

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            pushGeometry()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            pushGeometry()
        }

        func pushGeometry() {
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
            let rect = convert(bounds, to: nil)            // window space, y-up
            coordinator?.syncGeometry(LaunchpadPageGeometry(
                pageWidth: bounds.width,
                gridHeight: bounds.height,
                pageCount: pageCount,
                perPage: perPage,
                viewportMinX: rect.minX,
                viewportTopY: rect.maxY))                  // top edge in y-up space
        }
    }

    func makeNSView(context _: Context) -> RelayView {
        let view = RelayView()
        view.coordinator = coordinator
        return view
    }

    func updateNSView(_ view: RelayView, context _: Context) {
        view.coordinator = coordinator
        view.pageCount = pageCount
        view.perPage = perPage
        view.pushGeometry()
    }
}

/// The full dependency set of `LaunchpadGridView.filtered`. Equatable so the cache
/// can compare it exactly — every input that changes the projected cells is here,
/// so a cache hit can never serve stale icons.
private struct FilteredInputs: Equatable {
    var apps: [LaunchpadAppItem]
    var layout: LaunchpadLayout?
    var sessionHidden: Set<String>
    var searchText: String
    var folderEjectActive: Bool
    var carriedAppID: String?
    var carriedSourceFolderID: String?
}

/// Memo cache for the folder reconcile projection. During a page swipe the inputs are
/// unchanged (same COW buffers), so `resolve` returns the cached cells in O(1) without
/// rebuilding the projection each frame.
@MainActor
private final class FilteredCache {
    private var inputs: FilteredInputs?
    private var value: [LaunchpadDisplayCell] = []

    func resolve(_ newInputs: FilteredInputs, compute: () -> [LaunchpadDisplayCell]) -> [LaunchpadDisplayCell] {
        if let inputs, inputs == newInputs { return value }
        let computed = compute()
        inputs = newInputs
        value = computed
        return computed
    }
}

private extension View {
    /// Hides the macOS 26+ scroll edge effect — the faint line the system draws
    /// at a scroll view's edge — which otherwise shows as a stray bar across the
    /// top of an open folder's grid. No-op below macOS 26. The `#available`
    /// branch is fixed per OS (not a runtime row-count flip), so it does not
    /// violate the single-view-identity constraint the folder ScrollView needs.
    @ViewBuilder
    func launchpadHidingScrollEdgeEffect() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}
