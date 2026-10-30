import AppKit
import MacToolsPluginKit
import SwiftUI

/// Cell geometry, single-sourced (design §1.2). The default initialiser stays
/// byte-compatible with the historical hardcoded layout; appearance preferences go
/// through `LaunchpadGridMetrics.resolve(_:)` (LaunchpadLayoutMath.swift), the ONLY
/// resolution entry point.
struct LaunchpadGridMetrics: Equatable {
    var cellWidth: CGFloat = 116
    var cellHeight: CGFloat = 124
    var iconSide: CGFloat = 64        // smaller, airier icons (closer to iOS) inside the same pitch
    var columnSpacing: CGFloat = 8
    var rowSpacing: CGFloat = 16
    // Derived appearance fields (design §1.2), reverse-engineered from the previous
    // in-cell hardcodes (icon at y=8, label 8 below the icon, 32pt tall, labels shown)
    // so the defaults keep `LaunchpadGridMetrics()` byte-compatible.
    var showsLabels: Bool = true
    var iconTopInset: CGFloat = 8
    var labelGap: CGFloat = 8
    var labelHeight: CGFloat = 32
    // Label-style fields (design 2026-06-13): the "finished" values the cell injects.
    // The COLOR is stored as the preset enum, never as an `NSColor` — that keeps
    // `Equatable` clean (NSColor's `==` is unreliable across colour spaces) and the cell
    // resolves `.nsColor` at apply time. Weight is `NSFont.Weight`, a RawRepresentable
    // CGFloat, so it is Equatable-safe to store directly. Defaults reproduce the historical
    // implicit rendering — `.automatic` (→ `.labelColor`), 12pt, regular weight — so an
    // untouched `LaunchpadGridMetrics()` stays byte-compatible.
    var labelColor: LaunchpadLabelColor = .automatic
    var labelFontSize: CGFloat = 12
    var labelFontWeight: NSFont.Weight = .regular
    // Open-folder big-title style, derived in `resolve(_:)` so `LaunchpadFolderRenameField`
    // no longer hardcodes the font. Defaults match the historical title: `.title2` point
    // size, semibold weight.
    var folderTitleFontSize: CGFloat = LaunchpadGridMetrics.defaultFolderTitleFontSize
    var folderTitleWeight: NSFont.Weight = .semibold

    /// The historical folder-title point size (`Text(...).font(.title2.weight(.semibold))`),
    /// surfaced as a constant so both the default initialiser and `resolve(_:)` reference one
    /// source. `.title2` resolves to 17pt on macOS today; reading it keeps parity if Apple
    /// ever retunes the text style.
    static let defaultFolderTitleFontSize: CGFloat = NSFont.preferredFont(forTextStyle: .title2).pointSize
}

/// Where a dragged app should land, expressed as a *relative* position (never an absolute
/// index) so hidden/uninstalled drift can't pollute the persisted order (design §5.1).
enum LaunchpadDropTarget: Equatable {
    case before(String)
    case after(String)

    /// True when dropping `dragged` at this target leaves the visible `order` unchanged —
    /// dropping on itself, or onto the side it already neighbours. Lets the caller skip a
    /// reorder that would otherwise flip alphabetical → custom mode for no visible gain.
    func isNoOp(dragged: String, in order: [String]) -> Bool {
        guard let from = order.firstIndex(of: dragged) else { return true }
        switch self {
        case .before(let id):
            if dragged == id { return true }
            guard let to = order.firstIndex(of: id) else { return false }
            return from + 1 == to
        case .after(let id):
            if dragged == id { return true }
            guard let to = order.firstIndex(of: id) else { return false }
            return from == to + 1
        }
    }
}

/// Outcome of releasing an externally-carried (folder-ejected) app over the root grid. Mirrors
/// `commitDrop`'s three branches, but as DATA the coordinator/view maps to store ops — the carried
/// app has no cell in this grid, so the container can't fire onReorder/onMakeFolder itself.
enum LaunchpadExternalDropResult: Equatable {
    case makeFolder(targetAppID: String)
    case addToFolder(folderID: String)
    case reorder(LaunchpadDropTarget?)
}

/// One page of the launcher grid, rendered as a pure-AppKit subtree so per-item drag is tracked
/// directly via mouse events (the cell follows the cursor 1:1, like iOS — not NSDraggingSession)
/// and click/right-click are arbitrated by AppKit instead of fighting SwiftUI gestures.
/// Paging/selection/search stay in SwiftUI; this view only renders one page's items.
struct LaunchpadDragGrid: NSViewRepresentable {
    var items: [LaunchpadDisplayCell]
    var columns: Int
    /// Rows per page (page capacity = rows × columns), pushed by the SwiftUI pager so make-way
    /// overflow on a FULL page can fly out of the right edge instead of into a phantom row the
    /// container's unbounded row-major math would otherwise invent. 0 = uncapped (folder grids,
    /// which legitimately grow downward and scroll).
    var rows: Int = 0
    var selectedID: String?                            // the selected cell's layoutID
    var isCompact: Bool
    var interactionEnabled: Bool = true                // false while a folder overlay is up
    var metrics = LaunchpadGridMetrics()
    var localization = PluginLocalization(bundle: .main)   // context-menu titles
    var iconProvider: (LaunchpadAppItem) -> NSImage
    var onActivate: (LaunchpadDisplayCell) -> Void     // app → launch, folder → open
    var onReveal: (LaunchpadAppItem) -> Void
    var onCopyPath: (LaunchpadAppItem) -> Void
    var onHide: (LaunchpadAppItem) -> Void
    var onMoveToFront: (LaunchpadAppItem) -> Void
    var onMoveToEnd: (LaunchpadAppItem) -> Void
    var onSelect: (String) -> Void                     // layoutID
    var onReorder: (String, LaunchpadDropTarget) -> Void
    var onMakeFolder: (String, String) -> Void         // (targetAppID, draggedAppID) → new folder
    var onAddToFolder: (String, String) -> Void        // (folderID, draggedAppID)
    var onRenameFolder: (String) -> Void = { _ in }    // folderID — context-menu rename (19/P0a)
    var onDissolveFolder: (String) -> Void = { _ in }  // folderID — context-menu dissolve without confirmation (R2)
    var onDragBegan: () -> Void
    var onPageSwipe: (Int) -> Void
    var onPageDrag: (CGFloat, CGFloat, Bool) -> Void   // translationX, pageWidth, ended (empty-space mouse drag)
    var onPageScroll: (CGFloat, CGFloat) -> Void       // trackpad two-finger: raw deltaX, pageWidth — accumulated SHARED in SwiftUI (per-page containers must NOT each accumulate, or the offset oscillates)
    var onDismiss: () -> Void
    var allowFolderCreation: Bool = true               // false inside an open folder (no nested folders → never arm a merge)
    /// False while searching: the search list is a read-only flat projection, so a reorder drag
    /// would show make-way/merge cues whose drop is then discarded — don't start one, and drop
    /// the move-to-front and move-to-end menu items (their handlers no-op outside the layout state).
    var allowsCustomOrderActions: Bool = true
    var coordinator: LaunchpadDragCoordinator? = nil   // shared across root pages + the open folder; owns the finger-bound folder-exit handoff
    var folderContextID: String? = nil                 // non-nil only on the open folder's grid → its id, so an ejected app knows its source folder
    var pageIndex: Int? = nil                          // root page number; nil on the folder grid (folder grids never register as page containers)

    func makeNSView(context _: Context) -> LaunchpadGridContainerView {
        let view = LaunchpadGridContainerView()
        view.apply(grid: self)
        return view
    }

    func updateNSView(_ view: LaunchpadGridContainerView, context _: Context) {
        view.apply(grid: self)
    }
}

// MARK: - Container

final class LaunchpadGridContainerView: NSView {
    private var grid: LaunchpadDragGrid?
    private var cells: [LaunchpadGridCellView] = []
    private var columns = 7
    /// Rows per page; 0 = uncapped (folder grids / legacy fixtures keep unbounded row-major math).
    private var rows = 0
    private var metrics = LaunchpadGridMetrics()

    /// Slots this page can show. Beyond it a make-way gap has pushed a cell "to the next page" —
    /// its frame goes off the right edge (the viewport clip swallows it) instead of a phantom row.
    private var pageCapacity: Int { rows > 0 ? rows * columns : Int.max }

    /// While a drag session is live, defer rebuilding the cell views (so the dragged view
    /// isn't destroyed mid-flight) and remember the latest model to apply on drag end —
    /// the grid's `canSetItemViews` discipline.
    private var isDragging = false
    private var pendingGrid: LaunchpadDragGrid?

    /// Live visual order while a reorder drag hovers — cells animate aside so a gap opens at
    /// the slot under the cursor (Apple-style live reorder). `nil` when not dragging.
    private var dragOrder: [LaunchpadGridCellView]?
    private weak var draggedCell: LaunchpadGridCellView?

    /// Drag-to-stack (iOS folders): when the cursor moves into a cell's CENTRE zone the cell is
    /// armed as a stack target (create / join a folder on drop); the cell's outer EDGE zone stays
    /// reorder. This is driven purely by the movement `draggingUpdated` callbacks — never by a
    /// timer or AppKit's periodic updates, which a live drag session starves. Arming on entry
    /// means it survives the cursor then holding perfectly still (nothing disarms it), and the
    /// drop commits it. The armed target is read by the cell's `draw` to paint the merge cue.
    private(set) weak var stackTargetCell: LaunchpadGridCellView?

    /// External drag (an item carried OUTSIDE any container — ejected from a folder, or lifted
    /// from a root page in the carry model). For a folder eject the carried app is NOT among
    /// `cells`; for a root lift it IS, but parked off-screen as `anchorCell` and excluded from
    /// every layout/classification surface. Make-way opens a GAP by index (ACTIVE indexing — the
    /// anchor doesn't count) and merge arms a real cell target. Readable for the handoff tests
    /// (design §10-⑥): exactly one container is active at a time.
    private(set) var externalDragActive = false
    private(set) var externalGapIndex: Int?       // ACTIVE slot the carried item would occupy (make-way gap)
    private var externalDragAppID: String?
    /// False when the carried item is a folder — folders never merge (no nesting, design §1.5).
    private var externalAllowsMerge = true

    /// Root-page carry anchor (design §2): the lifted cell STAYS in `cells` — it must keep
    /// receiving the gesture's mouseDragged/mouseUp; `isHidden` or removeFromSuperview loses
    /// them permanently (D4 spike) — but is parked far off-screen by FRAME and excluded from
    /// every layout and classification path via `activeCells`. It never occupies `draggedCell`,
    /// so `beginExternalDrag`'s mutual-exclusion guard keeps its meaning untouched (§0 ruling 2).
    private(set) weak var anchorCell: LaunchpadGridCellView?
    /// Where the anchor parks: far outside any plausible window. NOT hidden, NOT alpha 0 —
    /// events must keep flowing and the view is not layer-backed.
    static let carryParkOrigin = NSPoint(x: -100_000, y: -100_000)
    /// The cells every layout/gap surface actually sees — the parked anchor is "not here".
    var activeCells: [LaunchpadGridCellView] { cells.filter { $0 !== anchorCell } }
    /// The gap (ACTIVE indexing) that reproduces the committed board with the anchor's own slot
    /// left empty — the seed layout at lift, and the settle target while a merge is armed.
    private var anchorSeedGap: Int? {
        guard let anchorCell else { return nil }
        return cells.firstIndex(where: { $0 === anchorCell })
    }

    /// Third leg of the layout-skip predicate (design §2.2/§7.3, AC-3): while the floating icon
    /// is flying to its slot, the landed cell — freshly rebuilt by the post-commit apply, or the
    /// still-parked source anchor — must never be written back to a slot by ANY layout pass.
    /// Only the coordinator's reveal (clearing `settlingItemID`) un-parks it.
    private func isParkedForSettle(_ cell: LaunchpadGridCellView) -> Bool {
        guard let settling = grid?.coordinator?.settlingItemID else { return false }
        return cell.layoutID == settling
    }

    // Empty-space drag (follow-cursor paging) + click (dismiss) tracking, plus scroll paging.
    private var gapDownPoint: NSPoint?
    private var gapMoved = false
    private var pageDragActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // NOT layer-backed: SwiftUI's `.offset` moving a layer-backed AppKit subtree during
        // follow-cursor paging leaves CA presentation-layer ghost trails. The reorder shuffle
        // still animates via the NSView animator proxy (no layer needed).
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }   // top-left origin → natural grid math

    var callbacks: LaunchpadDragGrid? { grid }

    /// The laid-out cell views, in committed order. Exposed for drag-to-stack unit tests.
    var cellViews: [LaunchpadGridCellView] { cells }

    /// True while a local drag is live OR this container is the source of a root carry (the
    /// parked anchor) — cells read this to suppress hover magnification, and the right-click
    /// guard reads it so a menu's tracking loop can't swallow the drag's mouseUp.
    var hasActiveDrag: Bool { draggedCell != nil || anchorCell != nil }

    /// While a folder overlay is up, the grid is inert: returning `nil` lets the click fall
    /// through to the SwiftUI scrim (which closes the folder) instead of being grabbed by a
    /// cell or the empty-space pager underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard grid?.interactionEnabled != false else { return nil }
        return super.hitTest(point)
    }

    func apply(grid: LaunchpadDragGrid) {
        // Registration must stay ABOVE the isDragging guard and read only the incoming `grid`
        // (self.grid stays stale during a deferred apply): during a cross-page carry the source
        // container has isDragging == true, and flipping away then back must still re-register it
        // or the handoff dies on the most common path (design §3.1). Pure dictionary write — it
        // never touches cells, so running it before the guard is safe.
        if let page = grid.pageIndex { grid.coordinator?.registerPageContainer(self, page: page) }
        guard !isDragging else { pendingGrid = grid; return }
        // Compare the full display cells (Equatable) so a folder rename / contents change still
        // rebuilds, whilst an offset/selection-only change during paging takes the fast path.
        let sameItems = cells.map(\.cell) == grid.items
        let sameColumns = columns == max(1, grid.columns)
        let sameRows = rows == max(0, grid.rows)
        // Metrics change with unchanged items must NOT take the fast path (design §1.3):
        // the cells would keep their old icon/label frames and never re-layout.
        let sameMetrics = metrics == grid.metrics
        self.grid = grid
        self.columns = max(1, grid.columns)
        self.rows = max(0, grid.rows)
        self.metrics = grid.metrics
        if sameItems && sameMetrics {
            for cell in cells { cell.isSelected = (cell.layoutID == grid.selectedID) }
            if !sameColumns || !sameRows { needsLayout = true }
        } else {
            rebuildCells(items: grid.items, selectedID: grid.selectedID)
            needsLayout = true
        }
        // Park the settling cell (design §7.3-2): the post-commit rebuild creates (or reuses) the
        // landed cell, but it must stay OFF-SCREEN until the floating icon finishes its flight —
        // surfacing it early would double the icon (grid cell + flying window). The layout-skip
        // predicate keeps it parked through every pass; the coordinator's reveal un-parks it.
        if let settling = grid.coordinator?.settlingItemID,
           let parked = cells.first(where: { $0.layoutID == settling }) {
            parked.setFrameOrigin(Self.carryParkOrigin)
        }
        // A container engaged while empty (late mount during a carry) gets the cursor replayed
        // now that cells exist — see LaunchpadDragCoordinator.containerDidApplyCells.
        if externalDragActive { grid.coordinator?.containerDidApplyCells(self) }
    }

    private func icons(for cell: LaunchpadDisplayCell) -> [NSImage] {
        guard let provider = grid?.iconProvider else { return [] }
        switch cell {
        case .app(let item): return [provider(item)]
        case .folder(_, _, let items): return items.prefix(9).map(provider)
        }
    }

    private func rebuildCells(items: [LaunchpadDisplayCell], selectedID: String?) {
        var reused: [LaunchpadGridCellView] = []
        for item in items {
            let cell = cells.first(where: { $0.layoutID == item.layoutID })
                ?? LaunchpadGridCellView(cell: item, icons: icons(for: item), metrics: metrics)
            cell.container = self
            cell.update(cell: item, icons: icons(for: item), metrics: metrics)
            cell.isSelected = (item.layoutID == selectedID)
            if cell.superview !== self { addSubview(cell) }
            reused.append(cell)
        }
        for stale in cells where !reused.contains(where: { $0 === stale }) {
            stale.removeFromSuperview()
        }
        cells = reused
    }

    override func layout() {
        super.layout()
        // While an item is being carried over this grid, preserve the make-way GAP —
        // a plain re-layout (e.g. triggered by the folder-close animation's re-render) would snap the
        // cells back to their committed slots and the make-way would "spring back".
        if externalDragActive {
            layoutCellsWithGap(animated: false)
        } else if anchorCell != nil {
            // Root carry handed off to another page: lay out COMPACT over activeCells so a stray
            // layout pass can never punch the anchor's hole back into the grid (design §2.2/AC-2).
            layoutCells(order: activeCells, animated: false)
        } else {
            layoutCells(order: dragOrder ?? cells, animated: false)
        }
    }

    /// The frame of grid slot `index` (row-major), in container coordinates. The math
    /// lives in `LaunchpadLayoutMath.slotRect` — shared with the settings layout
    /// preview so the two can only move together (anti-drift, same as `Chrome`).
    private func slotRect(_ index: Int) -> CGRect {
        LaunchpadLayoutMath.slotRect(
            index: index, columns: columns, containerWidth: bounds.width, metrics: metrics
        )
    }

    /// Position cells by their index in `order` — the live `dragOrder` while reordering (so
    /// the gap opens at the hover slot), otherwise the committed `cells`.
    private func layoutCells(order: [LaunchpadGridCellView], animated: Bool, settle: Bool = false) {
        guard !order.isEmpty else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                // Make-way (cells flowing aside as you drag): a smooth, slightly slower ease so it
                // reads as elegant, not a snap. Settle (the drop landing): a touch longer with a
                // gentle overshoot for a satisfying, iOS-like land.
                ctx.duration = settle ? 0.30 : 0.20
                ctx.timingFunction = settle
                    ? CAMediaTimingFunction(controlPoints: 0.34, 1.18, 0.5, 1)
                    : CAMediaTimingFunction(name: .easeInEaseOut)
                // Skip the lifted source cell — it follows the cursor (setFrameOrigin), not the
                // grid — the parked carry anchor, and the settling (still-flying) cell: none may
                // be written back to a slot until their reveal (design §2.2: the exclusion surface).
                for (index, cell) in order.enumerated()
                where cell !== draggedCell && cell !== anchorCell && !isParkedForSettle(cell) {
                    cell.animator().frame = slotRect(index)
                }
            }
        } else {
            // MUST also skip the dragged cell here — `layout()` uses this path during a drag, and
            // writing the dragged cell back to its slot fights `updateDirectDrag`'s 1:1 follow
            // (that tug-of-war was a source of the every-frame reorder flicker). Same for the
            // parked anchor and the settling cell: only the explicit reveal un-parks them.
            for (index, cell) in order.enumerated()
            where cell !== draggedCell && cell !== anchorCell && !isParkedForSettle(cell) {
                cell.frame = slotRect(index)
            }
        }
    }

    // MARK: Cell callbacks

    func activate(_ cell: LaunchpadGridCellView) { grid?.onActivate(cell.cell) }
    func select(_ cell: LaunchpadGridCellView) { grid?.onSelect(cell.layoutID) }

    /// Context menu: apps get the launch/reveal/order/hide set; folders get open / rename /
    /// dissolve (design §2.5, R2 — dissolve has no confirmation: the apps just return to the
    /// grid, nothing is lost). Folder cells never exist while searching (folders dissolve into
    /// flat results) and mid-drag suppression lives at the cell's `rightMouseDown`.
    func contextMenu(for cell: LaunchpadGridCellView) -> NSMenu? {
        guard let grid else { return nil }
        switch cell.cell {
        case .app(let app): return appContextMenu(app, grid: grid)
        case .folder: return folderContextMenu(cell.cell, grid: grid)
        }
    }

    private func appContextMenu(_ app: LaunchpadAppItem, grid: LaunchpadDragGrid) -> NSMenu {
        let loc = grid.localization
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = app
            menu.addItem(item)
        }
        add(loc.string("grid.menu.open", defaultValue: "打开"), #selector(menuOpen(_:)))
        menu.addItem(.separator())
        add(loc.string("grid.menu.revealInFinder", defaultValue: "在 Finder 中显示"), #selector(menuReveal(_:)))
        add(loc.string("grid.menu.copyPath", defaultValue: "拷贝路径"), #selector(menuCopy(_:)))
        menu.addItem(.separator())
        if grid.allowsCustomOrderActions {
            add(loc.string("grid.menu.moveToFront", defaultValue: "移到最前"), #selector(menuMoveFront(_:)))
            add(loc.string("grid.menu.moveToEnd", defaultValue: "移到最后"), #selector(menuMoveEnd(_:)))
            menu.addItem(.separator())
        }
        add(loc.string("grid.menu.hide", defaultValue: "隐藏"), #selector(menuHide(_:)))
        return menu
    }

    private func folderContextMenu(_ cell: LaunchpadDisplayCell, grid: LaunchpadDragGrid) -> NSMenu {
        let loc = grid.localization
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = cell           // carries the folder's display cell (id + name)
            menu.addItem(item)
        }
        add(loc.string("grid.menu.open", defaultValue: "打开"), #selector(menuOpenFolder(_:)))
        menu.addItem(.separator())
        add(loc.string("grid.menu.renameFolder", defaultValue: "重命名"), #selector(menuRenameFolder(_:)))
        add(loc.string("grid.menu.dissolveFolder", defaultValue: "解散文件夹"), #selector(menuDissolveFolder(_:)))
        return menu
    }

    private func menuApp(_ sender: NSMenuItem) -> LaunchpadAppItem? { sender.representedObject as? LaunchpadAppItem }
    private func menuFolderID(_ sender: NSMenuItem) -> String? {
        guard let cell = sender.representedObject as? LaunchpadDisplayCell,
              case .folder(let id, _, _) = cell else { return nil }
        return id
    }
    @objc private func menuOpen(_ sender: NSMenuItem) { menuApp(sender).map { grid?.onActivate(.app($0)) } }
    @objc private func menuReveal(_ sender: NSMenuItem) { menuApp(sender).map { grid?.onReveal($0) } }
    @objc private func menuCopy(_ sender: NSMenuItem) { menuApp(sender).map { grid?.onCopyPath($0) } }
    @objc private func menuMoveFront(_ sender: NSMenuItem) { menuApp(sender).map { grid?.onMoveToFront($0) } }
    @objc private func menuMoveEnd(_ sender: NSMenuItem) { menuApp(sender).map { grid?.onMoveToEnd($0) } }
    @objc private func menuHide(_ sender: NSMenuItem) { menuApp(sender).map { grid?.onHide($0) } }
    @objc private func menuOpenFolder(_ sender: NSMenuItem) {
        guard let cell = sender.representedObject as? LaunchpadDisplayCell else { return }
        grid?.onActivate(cell)
    }
    @objc private func menuRenameFolder(_ sender: NSMenuItem) { menuFolderID(sender).map { grid?.onRenameFolder($0) } }
    @objc private func menuDissolveFolder(_ sender: NSMenuItem) { menuFolderID(sender).map { grid?.onDissolveFolder($0) } }

    // MARK: Direct drag (mouse-tracked, like iOS — NOT NSDraggingSession)
    //
    // The system drag (NSDraggingSession) is the laggy "long-press / .onDrag" model: a separate
    // system-managed drag image, input latency, and a modal drag loop that starves timers. iOS
    // SpringBoard and the smooth SwiftUI reorder libraries instead track the pointer DIRECTLY and
    // move the real view 1:1. So the cell forwards its own mouse-drag here: the lifted cell follows
    // the cursor, the others spring aside, and a normal-run-loop dwell can drive pause-to-stack.

    /// Cursor offset within the dragged cell, so it follows the pointer keeping the grab point.
    private var dragGrabOffset = NSPoint.zero
    /// Last drag point in local coords — used on drop to detect an "escape" (dragged clearly out of
    /// the grid bounds → leave the folder).
    private var lastDragPoint: NSPoint?
    /// Last drag point in WINDOW coords — the coordinate space that survives the folder closing, so
    /// the eject commit can resolve the root drop slot.
    private var lastWindowDragPoint: NSPoint?

    func beginDirectDrag(_ cell: LaunchpadGridCellView, atWindowPoint windowPoint: NSPoint) {
        // New-gesture boundary: this entry fires exactly once per mouse gesture (the cell's
        // didDrag threshold latch), so the coordinator's cancelled-gesture latch is dropped
        // HERE, before any carry gate reads it. The latch's only other reset lives inside
        // onDragBegan → freezeVisibleOrder, which the root-lift gate runs BEFORE — without
        // this boundary one mid-carry cancel would wedge every later root drag (gate refuses
        // → reset unreachable → repeat forever).
        grid?.coordinator?.gestureBegan()
        // Root-page lift = a CARRY (design §1.5/§2.1): the same phantom model the folder eject
        // uses, so cross-page travel / edge flips / the virtual tail page all apply. Folder grids
        // keep the local state machine (in-folder reorder + the eject escalation); a grid with no
        // coordinator keeps the legacy local path — pinned by the existing test fleet.
        if grid?.folderContextID == nil, let coordinator = grid?.coordinator {
            beginCarryLift(cell, atWindowPoint: windowPoint, coordinator: coordinator)
            return
        }
        isDragging = true
        draggedCell = cell
        dragOrder = cells
        lastDragPoint = nil
        lastWindowDragPoint = nil
        disarmStackTarget()
        let p = convert(windowPoint, from: nil)
        dragGrabOffset = NSPoint(x: p.x - cell.frame.minX, y: p.y - cell.frame.minY)
        cell.isLifted = true                                   // picked-up look (scales the icon up)
        addSubview(cell, positioned: .above, relativeTo: nil)  // draw on top of its neighbours
        grid?.onDragBegan()                                    // freeze the visible order (§5.3)
    }

    /// Lift a root-page cell straight into a carry session (design §2.1, numbered order): the
    /// floating window IS the lifted visual, the cell stays in `cells` as an off-screen event
    /// anchor, and the visible page makes way through the same external-drag classification an
    /// ejected app uses.
    private func beginCarryLift(_ cell: LaunchpadGridCellView, atWindowPoint windowPoint: NSPoint,
                                coordinator: LaunchpadDragCoordinator) {
        // 1. Gate FIRST (BR-4): a refused lift leaves the container with zero state changes —
        //    the cell's didDrag has already consumed the gesture.
        guard coordinator.canBeginCarry,
              let anchorIndex = cells.firstIndex(where: { $0 === cell }) else { return }

        // 2. Container state. The anchor never occupies draggedCell/dragOrder — a dragOrder
        //    residue would make layout()'s fallback keep a hole after handoff (AC-2); the
        //    beginExternalDrag mutual-exclusion guard stays untouched (§0 ruling 2).
        isDragging = true
        anchorCell = cell
        lastDragPoint = nil
        lastWindowDragPoint = windowPoint
        disarmStackTarget()

        // 3. Freeze the visible order: the host view stages the snapshot + editability into the
        //    coordinator and clears any paging residue in the same closure (§2.1-3).
        grid?.onDragBegan()

        // 4. Floating visual keeps the GRAB POINT: the floating icon centre keeps the offset the
        //    cell's icon centre had from the cursor, so the lift doesn't visually jump (§2.1-4).
        //    Container is flipped (y down); screen space is y-up → negate the y delta.
        //    The cursor's page-local point comes from the PUSHED geometry, never the frame
        //    chain: `convert` is blind to the SwiftUI paging .offset, so on page > 0 it would
        //    skew the grab offset by page×pageWidth and the floating icon would ride that far
        //    from the cursor for the whole carry (design §5). Cold start (no geometry pushed
        //    yet) is page 0 by construction, where the frame chain IS correct; windowless
        //    harnesses treat the window point as already container-local.
        let p = coordinator.pageLocalPoint(fromWindow: windowPoint)
            ?? (window != nil ? convert(windowPoint, from: nil) : windowPoint)
        let iconCentre = NSPoint(x: cell.frame.minX + metrics.cellWidth / 2,
                                 y: cell.frame.minY + metrics.iconTopInset + metrics.iconSide / 2)
        let grabOffset = NSPoint(x: p.x - iconCentre.x, y: iconCentre.y - p.y)
        let isApp: Bool = { if case .app = cell.cell { return true }; return false }()
        let screen = window?.convertPoint(toScreen: windowPoint) ?? .zero

        // 5. Open the session: presents the floating icon and engages THIS page with
        //    beginExternalDrag (the anchor is already excluded from every active surface).
        guard coordinator.beginCarry(itemID: cell.layoutID, origin: .rootPage, isApp: isApp,
                                     icon: cell.carryVisual(), iconSide: metrics.iconSide,
                                     atScreenPoint: screen, aboveLevel: window?.level ?? .popUpMenu,
                                     grabOffset: grabOffset, sourceContainer: self) else {
            anchorCell = nil          // defensive rollback; the gate above makes this unreachable
            isDragging = false
            return
        }

        // 6. Seed the gap at the anchor's own slot: identity layout over activeCells — the board
        //    doesn't move, the original slot IS the make-way gap (iOS pick-up look, §2.1-5).
        seedExternalGap(at: anchorIndex)

        // 7. Park the anchor off-screen. NEVER isHidden (mouseDragged/mouseUp would be lost
        //    permanently — D4 spike) and never alpha 0 (non-layer-backed). isLifted stays false:
        //    the floating window carries the enlarged visual.
        cell.setFrameOrigin(Self.carryParkOrigin)
    }

    /// Seed the make-way gap (root lift: the anchor's own committed slot). With the anchor
    /// excluded from `activeCells` this is the IDENTITY layout — neighbours don't move.
    func seedExternalGap(at index: Int) {
        guard externalDragActive else { return }
        externalGapIndex = index
        layoutCellsWithGap(animated: false)
    }

    /// Commit-path anchor recovery (design §1.4-7/§7.3): clear the carry state, APPLY any
    /// deferred model (not drop: the source page must not keep a stale model), and let the next
    /// layout pass place the cell back into a real slot. On the hard-cut branch this runs in the
    /// mouseUp stack; on a flight settle it runs at the REVEAL — the deferred apply then already
    /// holds the post-commit model, so the source page reflows exactly once, never through the
    /// stale pre-commit snapshot mid-flight. While `settlingItemID` is set the cell stays parked
    /// regardless (the layout predicate), so calling this never surfaces it early.
    func endCarryAnchor() {
        guard anchorCell != nil else { return }
        anchorCell = nil
        isDragging = false
        lastDragPoint = nil
        lastWindowDragPoint = nil
        if let pending = pendingGrid {
            pendingGrid = nil
            apply(grid: pending)
        }
        needsLayout = true
    }

    /// Cancel-path anchor recovery (design §2.3): same mechanics — with the anchor back in the
    /// layout surfaces, the next layout pass writes it straight back to its real slot. Instant
    /// restore, fail-safe.
    func cancelCarryAnchor() {
        endCarryAnchor()
    }

    func updateDirectDrag(atWindowPoint windowPoint: NSPoint) {
        // Carry forwarding sits ABOVE the draggedCell guard (design §1.5/BR-7): a root carry has
        // no draggedCell, so the legacy position (inside the guard) would swallow every move.
        // Covers BOTH origins — the floating window is the icon now; classification is driven by
        // the coordinator against the CURRENT page's container, not necessarily this one.
        if let coord = grid?.coordinator, coord.carryActive {
            lastWindowDragPoint = windowPoint
            let screen = window?.convertPoint(toScreen: windowPoint) ?? .zero
            coord.carryMoved(atScreenPoint: screen, atWindowPoint: windowPoint)
            return
        }
        guard isDragging, let cell = draggedCell else { return }
        lastWindowDragPoint = windowPoint
        let p = convert(windowPoint, from: nil)
        lastDragPoint = p
        var origin = NSPoint(x: p.x - dragGrabOffset.x, y: p.y - dragGrabOffset.y)
        // Main grid: keep the lifted icon within the page so it can't be dragged off-screen / under
        // the launcher edge (iOS keeps the dragged icon on-screen). The OPEN FOLDER grid is exempt —
        // its cell must be free to leave the grid to trigger the eject.
        if grid?.folderContextID == nil {
            origin.x = min(max(origin.x, 0), max(0, bounds.width - cell.frame.width))
            origin.y = min(max(origin.y, 0), max(0, bounds.height - cell.frame.height))
        }
        cell.setFrameOrigin(origin)                           // 1:1 follow (clamped on the main grid)
        updateDrag(at: p)                                     // reflow the others / arm a merge target
        // Inside a folder: the moment the cell clearly leaves, begin the finger-bound eject — the
        // folder zooms closed and a floating icon takes over (see LaunchpadDragCoordinator).
        if let folderID = grid?.folderContextID, let coord = grid?.coordinator, draggedClearlyOutsideFolder(cell),
           let screen = window?.convertPoint(toScreen: windowPoint) {
            LaunchpadDragCoordinator.carryTrace("ARM eject app=\(cell.layoutID) window=\(windowPoint)")
            coord.beginEject(appID: cell.layoutID, sourceFolderID: folderID, icon: cell.primaryIcon,
                             iconSide: metrics.iconSide, atScreenPoint: screen, aboveLevel: window?.level ?? .popUpMenu)
        }
    }

    /// True when the DRAGGED CELL has clearly left the folder's cell cluster. Decided entirely in the
    /// container's OWN coordinate space — the cell's laid-out frame vs the visible grid rect — never
    /// via a window→view conversion. `convert(_:from:)` is unreliable through the folder overlay's
    /// SwiftUI `scaleEffect`/centering, which made small in-folder reorders falsely eject; the cell
    /// frame and the visible rect share one coordinate system, so this matches what the user sees.
    ///
    /// The boundary is the grid's VISIBLE rect, with no outward growth. The folder grid lives inside
    /// a clip view, so the instant the cell's centre leaves the visible rect the cell is clipped
    /// invisible. Ejecting exactly here raises the floating icon while the cell is still mostly
    /// visible — closing the gap that previously let the cell vanish into the clipped region 60-170pt
    /// before the eject (and the float) caught up. A reorder keeps the cell centre inside the visible
    /// rect, so it never trips this.
    private func draggedClearlyOutsideFolder(_ cell: LaunchpadGridCellView) -> Bool {
        let centre = NSPoint(x: cell.frame.midX, y: cell.frame.midY)
        // Primary boundary: the clip view's visible rect (the region the user can actually see).
        if let scrollView = enclosingScrollView {
            return !scrollView.documentVisibleRect.contains(centre)
        }
        // No clip view (not expected for a real folder grid — only windowless tests and any
        // detached fallback). Without a visible rect we can't tell "clipped" from "still shown",
        // so keep the previous generous slot-union zone: an in-grid reorder near the edge must
        // not falsely eject.
        let union = (0..<cells.count).map(slotRect).reduce(CGRect.null) { $0.union($1) }
        let base = union.isNull ? bounds : union
        let region = CGRect(x: base.minX - 60, y: base.minY - 110,
                            width: base.width + 120, height: base.height + 170)
        return !region.contains(centre)
    }

    /// Tear down the local drag state after an in-folder app is ejected to the root — no in-folder
    /// reorder is committed (the app left the folder).
    private func teardownDragState(_ cell: LaunchpadGridCellView) {
        disarmStackTarget()
        draggedCell = nil
        dragOrder = nil
        pendingGrid = nil           // an eject closes the folder; drop any deferred apply so the next drag starts clean
        isDragging = false
        cell.isLifted = false
        lastDragPoint = nil
        lastWindowDragPoint = nil
    }

    /// The grid is being unmounted — the folder closed under the drag (Esc / typing flattened the
    /// layout to search) or the whole overlay is being torn down. A live drag can never finish
    /// here (its mouseUp is lost with the view), so abort it: tear down the coordinator's floating
    /// eject window and settle any external make-way gap. Without this the floating icon window
    /// outlives the launcher and the next session's drags are wedged.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        if anchorCell != nil {
            // Root-carry source unmounting (filtered shrink / overlay teardown): the gesture's
            // mouseUp is lost with the view, so cancel is the only safe option (§9.1 row 3).
            // cancelCarry reaches back into cancelCarryAnchor via session.sourceContainer; the
            // explicit call below is the belt-and-braces for a session already gone. Runs BEFORE
            // the unregistration: the anchor restore can apply a deferred grid, which re-registers.
            grid?.coordinator?.cancelCarry(.anchorUnmounted)
            cancelCarryAnchor()
        }
        grid?.coordinator?.unregisterPageContainer(self)
        if let cell = draggedCell {
            if let coord = grid?.coordinator, grid?.folderContextID != nil, coord.ejectActive {
                coord.cancelEject()
            }
            teardownDragState(cell)
        }
        if externalDragActive { endExternalDrag() }
    }

    func endDirectDrag() { endDirectDrag(atWindowPoint: lastWindowDragPoint ?? .zero) }

    func endDirectDrag(atWindowPoint windowPoint: NSPoint) {
        // Release routing sits ABOVE the draggedCell guard (design §9.1 row 1 / BR-7): a root
        // carry has no draggedCell — at the legacy position the mouseUp would be swallowed and
        // the session wedged. The coordinator lands the DATA synchronously here (§1.4) and
        // reveals the source anchor itself (session.sourceContainer.endCarryAnchor).
        if let coord = grid?.coordinator, coord.carryActive {
            lastWindowDragPoint = windowPoint
            let revealBefore = coord.folderRevealToken
            coord.carryReleased(atWindowPoint: windowPoint)
            if let cell = draggedCell { teardownDragState(cell) }   // folder origin's local drag state
            // A folder commit auto-opens the new folder for inline rename, and the hard-cut reveal
            // now fires synchronously in this same mouseUp stack. Yanking first responder back to
            // the search field here would race — and usually beat — that rename focus, dropping the
            // typed name. Refocus search only when this release did NOT trigger a folder auto-open.
            if coord.folderRevealToken == revealBefore {
                refocusSearchField()
            }
            return
        }
        guard let cell = draggedCell else { return }
        lastWindowDragPoint = windowPoint

        // Finger-bound folder exit: if the eject is in flight (folder already closing) OR the cell is
        // released clearly outside, drop the app at the cursor's ROOT slot (not the tail). Releasing
        // INSIDE falls through to a normal in-folder reorder (the revert).
        if let coordinator = grid?.coordinator, let folderID = grid?.folderContextID,
           coordinator.ejectActive || draggedClearlyOutsideFolder(cell) {
            LaunchpadDragCoordinator.carryTrace("endDirectDrag COMMIT branch ejectActive=\(coordinator.ejectActive) clearlyOutside=\(draggedClearlyOutsideFolder(cell)) p=\(windowPoint)")
            coordinator.commitOut(folderID: folderID, appID: cell.layoutID, atWindowPoint: windowPoint)
            teardownDragState(cell)
            refocusSearchField()
            return
        }

        let settleOrder = dragOrder ?? cells
        let wasMerge = stackTargetCell != nil
        commitDrop(dragged: cell)                              // reorder or make/join folder (disarms)
        draggedCell = nil
        dragOrder = nil
        isDragging = false
        cell.isLifted = false
        lastDragPoint = nil
        if let pending = pendingGrid {
            pendingGrid = nil
            apply(grid: pending)                              // committed order already includes the move
            layoutCells(order: cells, animated: true, settle: true)
        } else {
            // Reorder: adopt the reflowed order as the committed `cells` NOW, so the async SwiftUI
            // apply finds `sameItems` and is a no-op — no instant snap/flicker after the glide.
            // (Merge changes the visible set, so let its apply rebuild into the new folder cell.)
            if !wasMerge { cells = settleOrder }
            layoutCells(order: settleOrder, animated: true, settle: true)   // elegant glide to the drop slot
        }
        refocusSearchField()
    }

    /// Return first-responder focus to the search field after a grid interaction, so typing
    /// and arrow-key navigation keep working (the field is the keyboard handler).
    func refocusSearchField() {
        guard let window, let field = Self.searchField(in: window.contentView) else { return }
        window.makeFirstResponder(field)
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }

    /// iOS folders, movement-driven + STABLE grid: reorder opens a gap only at the seam BETWEEN
    /// two icons; moving onto an icon's CENTRE keeps the grid exactly where it is and just
    /// highlights that icon as a merge target (release = create / join a folder). Arming never
    /// touches the layout, so the target stays put under the cursor.
    ///
    /// Classify the cursor against the cell currently under it: inside that cell's central icon
    /// rect → merge intent (arm it, leave the grid untouched); otherwise → reorder (slide the
    /// dragged gap to that cell's near side — one local shift, never a full-grid reset). Exposed
    /// so unit tests can drive it directly instead of a real `NSDraggingInfo`.
    func updateDrag(at point: NSPoint) {
        guard let dragged = draggedCell else { return }

        // Anti-jitter #1: keep an armed merge target while the cursor stays over its cell (+ a
        // little), so hovering near the merge-zone edge can't toggle merge↔reorder every frame.
        if let armed = stackTargetCell, armed.frame.insetBy(dx: -6, dy: -6).contains(point) { return }

        let slot = slotIndex(at: point, count: cells.count)
        guard cells.indices.contains(slot) else { return }

        // MERGE — classify against the COMMITTED layout (`cells`), NOT the reflowed `dragOrder`.
        // While reordering, the dragged's own gap can occupy this slot in `dragOrder`, so detecting
        // there makes the target read as "self" and silently kills merge (the regression). The
        // committed cell at this geometric slot is the real icon under the cursor. On arm, settle the
        // grid back to committed so that target sits exactly under the cursor and gets the highlight.
        let target = cells[slot]
        if grid?.allowFolderCreation != false, target !== dragged, dragged.cell.folderID == nil, mergeRect(forSlot: slot).contains(point) {
            if stackTargetCell !== target {
                setStackTarget(target)
                if dragOrder != cells {
                    dragOrder = cells
                    layoutCells(order: cells, animated: true)
                }
            }
            return
        }
        clearStackTarget()

        // REORDER — slide the dragged to the hovered cell's NEAR side (before / after). Inserting
        // *beside* the hovered cell (rather than absorbing its slot) keeps that cell where it is, so
        // the next frame can still detect a merge on it. The central merge rect is the dead-band
        // between "before" and "after", so a cursor sitting on the seam can't flap the order.
        guard var order = dragOrder else { return }
        let hovered = order[slot]
        if hovered === dragged { return }
        let m = mergeRect(forSlot: slot)
        let before: Bool
        if point.x < m.minX { before = true }
        else if point.x > m.maxX { before = false }
        else { return }                                   // central band → reserved for merge
        guard let cur = order.firstIndex(of: dragged) else { return }
        order.remove(at: cur)
        guard let hIdx = order.firstIndex(of: hovered) else { return }
        order.insert(dragged, at: before ? hIdx : hIdx + 1)
        if order != dragOrder {
            dragOrder = order
            // Animate the OTHER cells flowing aside (elegant make-way). This is safe — it fires only
            // on an order CHANGE (not every frame) and animates non-dragged cells to FIXED slots; the
            // earlier flicker was the *dragged* cell being re-targeted to a moving point each frame,
            // which `layoutCells` excludes (`where cell !== draggedCell`).
            layoutCells(order: order, animated: true)
        }
    }

    /// The central icon rect of a slot — the merge "hot zone" (icon-centred ~52×52); the seams
    /// to either side stay reorder.
    private func mergeRect(forSlot slot: Int) -> CGRect {
        let s = slotRect(slot)
        // Scales with the icon (design §1.1): 8 at the long-standing 64pt (regression
        // unchanged), floored at 6 so a 48pt icon keeps a usable 36×36 hot zone.
        let inset: CGFloat = max(6, metrics.iconSide * 0.125)
        return iconRect(in: s).insetBy(dx: inset, dy: inset)
    }

    private func setStackTarget(_ cell: LaunchpadGridCellView) {
        guard stackTargetCell !== cell else { return }
        stackTargetCell?.isMergeTarget = false
        stackTargetCell = cell
        cell.isMergeTarget = true
    }

    private func disarmStackTarget() { clearStackTarget() }

    private func clearStackTarget() {
        guard let target = stackTargetCell else { return }
        stackTargetCell = nil
        target.isMergeTarget = false
    }

    /// Resolve a drop: a dwelled-over target makes (app→app) or joins (app→folder) a folder;
    /// otherwise reorder against the live order. Called by `endDirectDrag`; also unit-tested
    /// directly (no real drag session needed).
    @discardableResult
    func commitDrop(dragged: LaunchpadGridCellView) -> Bool {
        let armed = stackTargetCell
        defer { disarmStackTarget() }

        if let target = armed, target !== dragged, dragged.cell.folderID == nil {
            if target.cell.folderID != nil {
                grid?.onAddToFolder(target.layoutID, dragged.layoutID)
            } else {
                grid?.onMakeFolder(target.layoutID, dragged.layoutID)
            }
            return true
        }

        // Otherwise reorder: the dragged app lands at `index` → after the cell before it, or
        // before the next cell when dropped at the very front.
        guard let order = dragOrder, let index = order.firstIndex(of: dragged) else { return false }
        let target: LaunchpadDropTarget
        if index > 0 { target = .after(order[index - 1].layoutID) }
        else if order.count > 1 { target = .before(order[index + 1].layoutID) }
        else { return false }
        grid?.onReorder(dragged.layoutID, target)
        return true
    }

    /// Resolve a root drop target from a CONTAINER-LOCAL point — the coordinator maps the window
    /// point through the pushed page geometry (`LaunchpadCarrySpace`), never through `convert`,
    /// which is blind to the SwiftUI paging offset. The carried item lands at the slot under the
    /// cursor (not the tail); the cursor's side of the slot midline picks before/after. An
    /// ejected app is not among `cells` (it's still in the folder); a root-carried one IS — its
    /// parked anchor resolves to a committed neighbour below, never to itself.
    func rootDropTarget(atContainerPoint p: NSPoint) -> LaunchpadDropTarget? {
        guard !cells.isEmpty else { return nil }
        let slot = slotIndex(at: p, count: cells.count)
        guard cells.indices.contains(slot) else { return nil }
        let target = cells[slot]
        if target === anchorCell {
            // The carried item's own slot: resolve relative to a committed NEIGHBOUR so the
            // commit's isNoOp guard reads it as "back where it started" — never as the anchor
            // itself, and never as a global-tail fallback.
            if let next = cells[(slot + 1)...].first(where: { $0 !== anchorCell }) {
                return .before(next.layoutID)
            }
            if let previous = cells[..<slot].last(where: { $0 !== anchorCell }) {
                return .after(previous.layoutID)
            }
            return nil
        }
        return p.x < slotRect(slot).midX ? .before(target.layoutID) : .after(target.layoutID)
    }

    /// Legacy window-point entrance (correct on page 0 only — kept for the cold-start fallback
    /// before the first geometry push; retire once §11 step 9 proves it unreachable).
    func rootDropTarget(atWindowPoint windowPoint: NSPoint) -> LaunchpadDropTarget? {
        rootDropTarget(atContainerPoint: window != nil ? convert(windowPoint, from: nil) : windowPoint)
    }

    // MARK: External drag (an app carried over this root grid after being ejected from a folder)

    /// Begin carrying an external item over this grid. Mutually exclusive with a real in-grid
    /// drag (the root-carry anchor never occupies `draggedCell`, so the SOURCE container itself
    /// passes this guard and can host the seed gap — design §0 ruling 2).
    func beginExternalDrag(appID: String, allowsMerge: Bool = true) {
        guard draggedCell == nil, !externalDragActive else { return }
        externalDragActive = true
        externalDragAppID = appID
        externalAllowsMerge = allowsMerge
        externalGapIndex = nil
        clearStackTarget()
    }

    /// Run the SAME make-way + merge classification an in-grid reorder uses (`updateDrag`), but for a
    /// phantom carried item: merge arms a real `cells` target (app → makeFolder, folder → addToFolder);
    /// otherwise a make-way GAP opens on the hovered cell's near side. Reuses mergeRect/slotIndex and
    /// the same central dead-band + sticky hysteresis so it can't flicker.
    /// The point is CONTAINER-LOCAL, mapped by the coordinator through the pushed page geometry —
    /// `convert` from window space is blind to the SwiftUI paging offset (page>0 misread).
    func updateExternalDrag(atContainerPoint point: NSPoint) {
        guard externalDragActive, draggedCell == nil, !cells.isEmpty, !activeCells.isEmpty else { return }
        if let armed = stackTargetCell, armed.frame.insetBy(dx: -6, dy: -6).contains(point) { return }
        // Classify against the COMMITTED slot owners — `cells` INCLUDING the anchor — so the
        // seeded identity display and the classification agree (mirrors the local drag, which
        // classifies against committed `cells` too). The GAP, however, lives in ACTIVE indexing
        // (the anchor is never laid out), so targets are mapped through `activeCells` below.
        let slot = slotIndex(at: point, count: cells.count)
        guard cells.indices.contains(slot) else { return }
        let target = cells[slot]
        if target === anchorCell {
            // The carried item's own committed slot: hovering yourself never arms or reflows —
            // it re-opens the original gap, so "jiggle in place and release" is a no-op return
            // and "drag back home" restores the board (design AR-1; local drag's `self` check).
            clearStackTarget()
            if externalGapIndex != anchorSeedGap {
                externalGapIndex = anchorSeedGap
                layoutCellsWithGap(animated: true)
            }
            return
        }
        if externalAllowsMerge, mergeRect(forSlot: slot).contains(point) {
            if stackTargetCell !== target {
                setStackTarget(target)
                // Settle to the COMMITTED board so the armed target sits exactly under the
                // cursor. With a parked anchor the committed board IS the seed-gap layout —
                // nil (fully compacted) only when no anchor is present (the eject case).
                let settleGap = anchorSeedGap
                if externalGapIndex != settleGap {
                    externalGapIndex = settleGap
                    layoutCellsWithGap(animated: true)
                }
            }
            return
        }
        clearStackTarget()
        let m = mergeRect(forSlot: slot)
        guard let targetActive = activeCells.firstIndex(where: { $0 === target }) else { return }
        let gap: Int
        if point.x < m.minX { gap = targetActive }
        else if point.x > m.maxX { gap = targetActive + 1 }
        else { return }                                    // central band → reserved for merge
        if gap != externalGapIndex {
            externalGapIndex = gap
            layoutCellsWithGap(animated: true)
        }
    }

    /// Legacy window-point entrance (correct on page 0 only — cold-start fallback before the first
    /// geometry push; windowless unit tests treat the point as already container-local).
    func updateExternalDrag(atWindowPoint windowPoint: NSPoint) {
        updateExternalDrag(atContainerPoint: window != nil ? convert(windowPoint, from: nil) : windowPoint)
    }

    /// Make-way for the carried item: lay ACTIVE cell `i` at `slotRect(i)`, shifted one slot
    /// forward once past `externalGapIndex`, leaving an empty slot under the cursor. (When the
    /// gap is nil this is the identity layout — i.e. the settle.) Iterates `activeCells`: the
    /// parked anchor must never be written back to a slot (design §2.2), and `draggedCell` keeps
    /// the shared skip discipline even though it can't coexist with an external drag.
    private func layoutCellsWithGap(animated: Bool) {
        func slot(for index: Int) -> Int {
            guard let gap = externalGapIndex, index >= gap else { return index }
            return index + 1
        }
        // A gap on a FULL page pushes the last cell past the page capacity. The container's
        // row-major math knows no page boundary, so an unguarded slotRect would invent a
        // phantom row BELOW the grid (visible — the strip only clips horizontally at the
        // viewport). Send the overflow cell out of the RIGHT edge instead: the clip swallows
        // it, the motion reads as "cascades to the next page", and the post-commit reconcile
        // slice puts it on the real next page (or back) while it is already off-screen.
        func frame(forSlot slot: Int) -> CGRect {
            guard slot >= pageCapacity else { return slotRect(slot) }
            let lastRow = slotRect(pageCapacity - 1)
            return CGRect(x: bounds.width + metrics.cellWidth, y: lastRow.minY,
                          width: metrics.cellWidth, height: metrics.cellHeight)
        }
        let order = activeCells
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for (i, cell) in order.enumerated()
                where cell !== draggedCell && !isParkedForSettle(cell) {
                    cell.animator().frame = frame(forSlot: slot(for: i))
                }
            }
        } else {
            for (i, cell) in order.enumerated()
            where cell !== draggedCell && !isParkedForSettle(cell) {
                cell.frame = frame(forSlot: slot(for: i))
            }
        }
    }

    /// Resolve the current external-drag state into a drop outcome WITHOUT tearing anything down
    /// (pure peek, design §7.1) — the coordinator commits the data first and ends the drag after.
    func resolveExternalDrop() -> LaunchpadExternalDropResult {
        if let target = stackTargetCell {
            if let fid = target.cell.folderID { return .addToFolder(folderID: fid) }
            return .makeFolder(targetAppID: target.layoutID)
        }
        // Gap → id mapping over activeCells: the parked anchor can never become a .before/.after
        // target, so a self-referential drop is structurally impossible (design §2.2; the seed
        // gap resolves to a frozen-order neighbour, which the commit's isNoOp guard absorbs).
        let active = activeCells
        guard let gap = externalGapIndex, !active.isEmpty else { return .reorder(nil) }
        if gap <= 0 { return .reorder(.before(active[0].layoutID)) }
        if gap >= active.count { return .reorder(.after(active[active.count - 1].layoutID)) }
        return .reorder(.after(active[gap - 1].layoutID))
    }

    /// Legacy resolve-and-teardown entrance (windowless test fixtures).
    func commitExternalDrag() -> LaunchpadExternalDropResult {
        defer { endExternalDrag() }
        return resolveExternalDrop()
    }

    /// Where the floating icon's flight should land, in CONTAINER coordinates (pure peek — design
    /// §7.1). An armed merge target answers its icon rect (the iOS absorb feel); an open make-way
    /// gap answers the empty slot's icon rect (the gap layout leaves slot `externalGapIndex`
    /// itself empty). nil when classification never settled — AND, deliberately, for an
    /// engaged-but-EMPTY page: the only empty engaged container in production is the VIRTUAL tail
    /// page (no sparse pages exist), which collapses the moment the release flips
    /// `carryActive = false` — the commitToken handler then snap-animates `currentPage` back to
    /// the last real page (§6.2) WHILE a 0.25s flight would still be airborne. A slot-0 flight
    /// would chase a viewport that is sliding away, and the landed cell reveals at the LAST REAL
    /// page's tail anyway (a root reorder never grows pageCount; a folder eject grows it only
    /// when the last real page was exactly full — undecidable here without re-deriving the store
    /// mutation). So every empty-page release answers nil and the coordinator degrades it to the
    /// hard-cut dismiss instead of an aimless flight.
    func settleTargetLocalRect() -> CGRect? {
        guard externalDragActive else { return nil }
        if let target = stackTargetCell { return iconRect(in: target.frame) }
        if let gap = externalGapIndex {
            // A gap at/after the page capacity (full page, last cell's right seam) has no
            // visible slot on THIS page — slotRect would aim the flight at the phantom row.
            // Degrade to the hard-cut dismiss, same as the empty-virtual-page nil above.
            guard gap < pageCapacity else { return nil }
            return iconRect(in: slotRect(gap))
        }
        return nil
    }

    /// The icon area inside a slot/cell frame — the cell's own `iconFrame`, offset into
    /// container coordinates (shared source: `LaunchpadGridMetrics.iconFrameInCell`).
    private func iconRect(in slot: CGRect) -> CGRect {
        metrics.iconFrameInCell.offsetBy(dx: slot.minX, dy: slot.minY)
    }

    /// Commit-path external-drag teardown while a settle flight is airborne (design §1.4-3/§7.3-1,
    /// BR-5): clear the flags but do NOT re-layout — the make-way frames freeze in place. The
    /// post-commit apply lays out the new committed model, which is slot-for-slot identical to
    /// the frozen gap layout, so the handover happens with zero motion. (`endExternalDrag` stays
    /// the cancel/handoff collapse, which DOES animate the gap closed.)
    func freezeExternalDrag() {
        externalDragActive = false
        externalDragAppID = nil
        externalAllowsMerge = true
        externalGapIndex = nil
        clearStackTarget()
    }

    /// Settle-flight reveal (design §7.3-3): the coordinator has already cleared
    /// `settlingItemID`, so the layout predicate no longer excludes the landed cell — one plain
    /// pass writes it straight into its slot, exactly under the just-landed floating icon.
    /// Idempotent and cheap; broadcast to every registered page (the landed cell lives on exactly
    /// one; a merge-into-folder leaves no cell anywhere, and the pass is then a no-op).
    func revealSettledCell() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Clear external-drag state and settle the make-way gap closed. On a root-carry SOURCE page
    /// this compacts over activeCells — the carried item "isn't on this page" while it travels;
    /// the parked anchor itself is untouched (only endCarryAnchor/cancelCarryAnchor reveal it).
    func endExternalDrag() {
        externalDragActive = false
        externalDragAppID = nil
        externalAllowsMerge = true
        externalGapIndex = nil
        clearStackTarget()
        layoutCellsWithGap(animated: true)
    }

    /// The page-local x spans of the outermost grid COLUMNS (pure peek): the edge turner
    /// exempts them so hovering an edge column reads as drop aiming, never as a flip request.
    /// Geometry only — gap state is deliberately ignored (slotIndex clamps every x to the last
    /// column, so "a gap is open" holds even with the cursor in the bare margin, and keying the
    /// exemption on it would kill right-edge flipping outright). nil while the page has no
    /// active cells (virtual tail page): an empty page has no drop slot to aim at — fail open.
    func outerColumnXSpans() -> (left: ClosedRange<CGFloat>, right: ClosedRange<CGFloat>)? {
        guard !activeCells.isEmpty else { return nil }
        let first = slotRect(0)
        let last = slotRect(columns - 1)
        return (first.minX...first.maxX, last.minX...last.maxX)
    }

    /// Grid slot (row-major index) under a point, clamped to the current item range.
    private func slotIndex(at point: NSPoint, count: Int) -> Int {
        let gridWidth = CGFloat(columns) * metrics.cellWidth + CGFloat(max(0, columns - 1)) * metrics.columnSpacing
        let leftInset = max(0, (bounds.width - gridWidth) / 2)
        let col = min(max(Int((point.x - leftInset) / (metrics.cellWidth + metrics.columnSpacing)), 0), columns - 1)
        let maxRow = max(0, (count - 1) / columns)
        let row = min(max(Int(point.y / (metrics.cellHeight + metrics.rowSpacing)), 0), maxRow)
        return min(max(row * columns + col, 0), max(0, count - 1))
    }

    // MARK: Scroll paging + gap click-to-dismiss

    /// Two-finger horizontal swipe pages the grid — the native Launchpad gesture. Paging is
    /// a scroll gesture (no mouse button), kept entirely separate from per-item click-drag,
    /// so swiping to page can never grab an app. Cells don't override `scrollWheel`, so a
    /// swipe over an icon bubbles up to here.
    override func scrollWheel(with event: NSEvent) {
        // The open-folder grid doesn't page — let the event bubble to the panel's enclosing
        // ScrollView so a folder taller than the visible cap can be two-finger scrolled.
        if grid?.folderContextID != nil { super.scrollWheel(with: event); return }
        // Scroll events aren't anchored to the mouse-down view, so they still arrive mid-carry —
        // edge dwell is the only flip channel while one is live (§9.4). Gate on the SESSION, not
        // `carryActive`: the settle flight (mouse already up) must also freeze paging, or the
        // floating icon lands on a page that just slid away (§8/BR-3b).
        if grid?.coordinator?.carrySession != nil { return }
        if event.hasPreciseScrollingDeltas {
            // Trackpad two-finger swipe: follow-the-finger paging — the SAME live-track + snap
            // as the empty-space mouse drag, so the two gestures feel identical.
            guard event.momentumPhase == [] else { return }      // ignore the inertial tail
            // Forward the RAW delta only — accumulation + end-debounce live in SwiftUI so they're
            // SHARED across all per-page containers. (Each page is a separate container; if each
            // kept its own running total, the sliding grid would feed two different totals into the
            // shared offset on alternating frames → the every-frame flicker.)
            grid?.onPageScroll(event.scrollingDeltaX, bounds.width)
        } else {
            // Mouse wheel (discrete notches): one notch → one page, on whichever axis moved.
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            guard delta != 0 else { return }
            grid?.onPageSwipe(delta < 0 ? 1 : -1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        gapDownPoint = event.locationInWindow   // window coords — stable while the page offsets
        gapMoved = false
        pageDragActive = false
    }

    /// A horizontal drag that starts on *empty space* (margins / gaps / below the grid —
    /// cells handle their own drags) pages the grid, follow-the-cursor: the page tracks the
    /// drag live and snaps once past a threshold on release. Can't grab an app because the
    /// press never landed on a cell.
    ///
    /// The delta is measured in WINDOW coordinates: the container itself slides via the SwiftUI
    /// page offset, so converting the point into its (moving) coordinate space would feed the
    /// offset back into the delta — an oscillation that shows up as ghosting. Window space is
    /// stable, so the drag tracks the real cursor displacement.
    override func mouseDragged(with event: NSEvent) {
        guard let start = gapDownPoint else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        if hypot(dx, dy) > 6 { gapMoved = true }
        if !pageDragActive {
            guard abs(dx) > 8, abs(dx) > abs(dy) else { return }   // commit to a horizontal page drag
            pageDragActive = true
        }
        grid?.onPageDrag(dx, bounds.width, false)                   // live: page follows the cursor
    }

    override func mouseUp(with event: NSEvent) {
        let start = gapDownPoint
        gapDownPoint = nil
        if pageDragActive {
            let dx = event.locationInWindow.x - (start?.x ?? 0)
            grid?.onPageDrag(dx, bounds.width, true)                // release: snap or spring back
            pageDragActive = false
        } else if !gapMoved, grid?.isCompact == false {
            // A click (no drag) on empty space dismisses in fullscreen.
            grid?.onDismiss()
        }
    }
}

// MARK: - Cell

final class LaunchpadGridCellView: NSView {
    private(set) var cell: LaunchpadDisplayCell
    /// The store-facing id (app path / folder uuid) for drag payload + reorder.
    var layoutID: String { cell.layoutID }
    /// The app icon, for the window-level floating view when this cell is ejected from a folder.
    var primaryIcon: NSImage? { imageView.image }

    /// The rendered label font / colour — surfaced so tests can verify that `init`/`update`
    /// actually apply the resolved label style (design 2026-06-13). Read-only; the cell owns
    /// the field.
    var labelFontForTesting: NSFont? { label.font }
    var labelColorForTesting: NSColor? { label.textColor }

    /// The floating-window visual for a carried cell (design §2.1-4): an app provides its icon
    /// image; a folder plate is DRAWN (no image view), so it must be snapshot via cacheDisplay.
    func carryVisual() -> NSImage? {
        if !imageView.isHidden { return imageView.image }
        let rect = iconFrame
        guard rect.width > 0, rect.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    private let imageView = NSImageView()        // single icon — apps only (hidden for folders)
    private let label = NSTextField(labelWithString: "")
    private var folderIcons: [NSImage] = []      // up to 9 child icons (3×3 preview), drawn for a folder cell
    private var metrics: LaunchpadGridMetrics
    weak var container: LaunchpadGridContainerView?

    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    /// While being directly dragged, the cell follows the cursor and its icon scales up (the
    /// iOS pick-up). It stays VISIBLE (unlike the old system-drag, which hid the source).
    var isLifted = false { didSet { if isLifted != oldValue { syncIconScale() } } }
    /// Armed as a folder merge target during a drag: the icon blooms slightly larger and a soft
    /// accent well is drawn behind it (iOS pre-merge feel).
    var isMergeTarget = false { didSet { if isMergeTarget != oldValue { syncIconScale(); needsDisplay = true } } }
    /// Cursor is over this cell → magnify the icon (macOS Dock-style). Suppressed while ANY cell is
    /// being dragged so passing the lifted icon over others doesn't make them twitch.
    var isHovered = false { didSet { if isHovered != oldValue { syncIconScale() } } }
    private var hoverTracking: NSTrackingArea?

    /// The icon scales up ~1.1× while HOVERED (macOS Dock-style magnification), being dragged, or
    /// armed as a merge target — ANIMATED over a short ease so it grows smoothly. Folders scale the
    /// same way (the whole plate enlarges) so a folder and an app feel identical to point at.
    private func syncIconScale() {
        let big = isHovered || isLifted || isMergeTarget
        let target = big ? mergeIconFrame : iconFrame
        if imageView.isHidden { needsDisplay = true }   // folder: the plate is drawn, redraw at the new size
        guard imageView.frame != target else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 1.12, 0.42, 1)  // soft, slightly springy
            imageView.animator().frame = target
        }
    }

    private var mouseDownPoint: NSPoint?
    private var didDrag = false
    private let dragThreshold: CGFloat = 6

    /// The icon area both the app image view and the folder thumbnail occupy. Sourced
    /// from `LaunchpadGridMetrics.iconFrameInCell` — shared with the settings layout
    /// preview (anti-drift: one formula, two consumers).
    private var iconFrame: CGRect { metrics.iconFrameInCell }

    /// The label strip below the icon. With labels hidden (`showsLabels == false`) the
    /// height collapses to 0 and the field is hidden — accessibility label and toolTip
    /// still carry the name (design §1.2). Shared source: `labelFrameInCell`.
    private var labelFrame: CGRect { metrics.labelFrameInCell }

    /// The icon area enlarged ~1.1× while armed as a merge target.
    private var mergeIconFrame: CGRect {
        iconFrame.insetBy(dx: -metrics.iconSide * 0.05, dy: -metrics.iconSide * 0.05)
    }

    init(cell: LaunchpadDisplayCell, icons: [NSImage], metrics: LaunchpadGridMetrics) {
        self.cell = cell
        self.metrics = metrics
        super.init(frame: CGRect(x: 0, y: 0, width: metrics.cellWidth, height: metrics.cellHeight))

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = iconFrame
        addSubview(imageView)

        label.frame = labelFrame
        label.isHidden = !metrics.showsLabels
        // Label-style injection (design 2026-06-13): size/weight from the chosen tier, color
        // from the preset. Defaults (`.medium` 12pt / regular / `.automatic` → `.labelColor`)
        // reproduce the historical rendering. `update` MUST re-apply both, or the same view
        // reused with new metrics keeps the old font/colour.
        label.font = .systemFont(ofSize: metrics.labelFontSize, weight: metrics.labelFontWeight)
        label.textColor = metrics.labelColor.nsColor
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        configure(cell: cell, icons: icons)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(cell: LaunchpadDisplayCell, icons: [NSImage], metrics: LaunchpadGridMetrics) {
        self.metrics = metrics
        imageView.frame = iconFrame
        label.frame = labelFrame
        label.isHidden = !metrics.showsLabels
        // Symmetric with `init`: re-apply the label style so reusing this view with new
        // metrics (e.g. the user changes the size/weight/colour preset) actually re-renders.
        // Omitting this would silently keep the previous appearance for already-mounted cells.
        label.font = .systemFont(ofSize: metrics.labelFontSize, weight: metrics.labelFontWeight)
        label.textColor = metrics.labelColor.nsColor
        configure(cell: cell, icons: icons)
    }

    /// Bind the view to a display cell: an app shows its single icon, a folder hides the image
    /// view and draws a 2×2 thumbnail of its first four children.
    private func configure(cell: LaunchpadDisplayCell, icons: [NSImage]) {
        self.cell = cell
        switch cell {
        case .app(let item):
            folderIcons = []
            imageView.isHidden = false
            imageView.image = icons.first
            if label.stringValue != item.name { label.stringValue = item.name }
            toolTip = item.name
        case .folder(_, let name, _):
            imageView.isHidden = true
            folderIcons = Array(icons.prefix(9))
            if label.stringValue != name { label.stringValue = name }
            toolTip = name
        }
        setAccessibilityLabel(label.stringValue)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isFolder: Bool = { if case .folder = cell { return true } else { return false } }()

        // App selection: a tight grey rounded square hugging the ICON (not the whole cell). Less
        // vertical inset than horizontal so the top stays inside the cell (the icon sits at y=8).
        if isSelected, !isFolder {
            let sel = iconFrame.insetBy(dx: -8, dy: -6)
            let path = NSBezierPath(roundedRect: sel, xRadius: sel.width * 0.24, yRadius: sel.width * 0.24)
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            path.fill()
        }
        if isMergeTarget { drawStackTargetCue() }       // behind the icon / thumbnail
        if isFolder { drawFolderThumbnail() }
        // Folder selection is drawn INTO the plate (drawFolderThumbnail): both outer treatments
        // tried here before — a grey fill behind the frosted plate (ugly halo) and an accent
        // ring around it (double frame over the plate's own background) — read as two stacked
        // shapes. Deepening the plate itself keeps one shape and matches the app wash language.
    }

    /// iOS-style folder tile: a frosted rounded "squircle" plate carrying a 3×3 preview of the
    /// first nine child icons. Drawn (not subviews) so the cell stays non-layer-backed — see the
    /// container's `init` note on why layer-backing here would ghost during follow-cursor paging.
    /// The folder plate, inset to match an app icon's VISIBLE footprint (app icons carry ~10%
    /// transparent padding inside their frame, so an un-inset plate looks bigger than the apps).
    private var folderPlateRect: CGRect { iconFrame.insetBy(dx: 6, dy: 6) }

    private func drawFolderThumbnail() {
        // Hover / lift / merge enlarges the whole plate ~1.1× — same magnification an app icon gets.
        let big = isHovered || isLifted || isMergeTarget
        let plate = big
            ? folderPlateRect.insetBy(dx: -folderPlateRect.width * 0.05, dy: -folderPlateRect.height * 0.05)
            : folderPlateRect
        let radius = plate.width * 0.29          // iOS squircle proportion
        let platePath = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

        // Frosted plate: a translucent fill that reads in both light and dark, plus a thin top
        // highlight and bottom shade for a subtle "raised glass" depth.
        NSColor.white.withAlphaComponent(0.10).setFill()
        platePath.fill()
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        platePath.fill()
        do {
            // Clip the highlight/shade to the plate so their straight full-width ends don't
            // bleed PAST the (large, 0.29×) rounded corners onto the cell background — at
            // y = maxY-2.5 the corner has already curved in ~8pt, so an unclipped `sh` drew a
            // faint horizontal "bar" sticking out below the plate's rounded bottom (apps have no
            // plate, hence no bar). Clipping makes both depth cues follow the squircle contour.
            NSGraphicsContext.saveGraphicsState()
            platePath.addClip()
            let hl = NSRect(x: plate.minX + 1, y: plate.minY + 1, width: plate.width - 2, height: 1.5)
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: hl, xRadius: 1, yRadius: 1).fill()
            let sh = NSRect(x: plate.minX + 1, y: plate.maxY - 2.5, width: plate.width - 2, height: 1.5)
            NSColor.black.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: sh, xRadius: 1, yRadius: 1).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Selected folder: deepen the plate itself along the SAME squircle path — the iOS folder
        // press look, and the same labelColor-wash language the app selection uses (the app's
        // wash hugs its icon because an app has no plate; the folder's goes into the plate).
        // No ring, no second shape — and the carried-folder snapshot (cacheDisplay) now picks up
        // a slightly deeper plate instead of the old accent ring baked into the floating icon.
        if isSelected {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            platePath.fill()
        }

        // Mini-icon grid, CENTRED and filled top-left first. 2×2 for ≤4 apps (bigger icons that
        // fill the plate, like iOS) and 3×3 for 5–9, so a small folder doesn't look sparse/empty.
        let count = folderIcons.count
        let cols = count <= 4 ? 2 : 3
        let inset: CGFloat = plate.width * (cols == 2 ? 0.17 : 0.12)
        let gap: CGFloat = plate.width * (cols == 2 ? 0.11 : 0.08)
        let mini = ((plate.width - inset * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols)).rounded(.down)
        let cornerR = mini * 0.24
        // Centre the actually-used rows/cols within the plate so 1–4 icons sit in the middle.
        let usedRows = Int((Double(min(count, cols * cols)) / Double(cols)).rounded(.up))
        let gridW = CGFloat(cols) * mini + CGFloat(cols - 1) * gap
        let gridH = CGFloat(usedRows) * mini + CGFloat(max(0, usedRows - 1)) * gap
        let originX = plate.minX + (plate.width - gridW) / 2
        let originY = plate.minY + (plate.height - gridH) / 2
        for (index, icon) in folderIcons.prefix(cols * cols).enumerated() {
            let col = index % cols, row = index / cols
            let rect = NSRect(
                x: originX + CGFloat(col) * (mini + gap),
                y: originY + CGFloat(row) * (mini + gap),
                width: mini, height: mini
            )
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: cornerR, yRadius: cornerR).addClip()
            // Keep child icons upright in the cell's top-left-origin coordinate system.
            icon.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// "Drop here to make / join a folder" cue on the armed merge target — a soft accent "well"
    /// (bloom) behind the enlarged icon, like iOS's pre-merge highlight. Light fill, no hard
    /// stroke, sized larger than the icon so it reads around a folder thumbnail too.
    private func drawStackTargetCue() {
        // Bloom around the (enlarged) icon, but keep the TOP inside the cell — `mergeIconFrame` sits
        // at y≈4.8, so a -6 vertical inset would push the cue above y=0 and clip on the first row.
        let zone = iconFrame.insetBy(dx: -6, dy: -4)
        let radius = zone.width * 0.30
        let path = NSBezierPath(roundedRect: zone, xRadius: radius, yRadius: radius)
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        path.fill()
        path.lineWidth = 1
        NSColor.controlAccentColor.withAlphaComponent(0.4).setStroke()
        path.stroke()
    }

    // MARK: Hover magnification (macOS Dock-style)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(ta)
        hoverTracking = ta
    }

    override func mouseEntered(with event: NSEvent) {
        guard container?.hasActiveDrag != true else { return }   // don't magnify while dragging
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) { isHovered = false }

    // MARK: Click vs direct drag (mouse-tracked — the cell receives all drag events itself)

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didDrag = false
        container?.select(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        if !didDrag {
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - start.x, point.y - start.y) > dragThreshold else { return }
            didDrag = true
            // Searching: read-only projection — never lift, so no make-way/merge cues whose drop
            // would be silently discarded. `didDrag` is STILL set so the gesture is consumed:
            // mouseUp must treat a long drag as a cancelled drag, not as a click that launches.
            guard container?.callbacks?.allowsCustomOrderActions != false else { return }
            container?.beginDirectDrag(self, atWindowPoint: event.locationInWindow)
        }
        container?.updateDirectDrag(atWindowPoint: event.locationInWindow)   // 1:1 follow (no-op when nothing lifted)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        if didDrag {
            container?.endDirectDrag(atWindowPoint: event.locationInWindow)
        } else {
            container?.activate(self)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Mid-drag right-click would open a menu whose tracking loop swallows the drag's mouseUp,
        // wedging the lifted cell and the deferred grid apply. Ignore it; finish the drag first.
        // The coordinator-level gate also covers a cross-page carry hovering a NON-source page,
        // where this container's own hasActiveDrag is false (design §9.1 row 10).
        guard container?.hasActiveDrag != true,
              container?.callbacks?.coordinator?.carryActive != true else { return }
        container?.select(self)   // highlight which app the menu targets (user feedback)
        guard let menu = container?.contextMenu(for: self) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        container?.refocusSearchField()   // keep arrow-key nav working after the menu closes
    }

    /// Claim mouse events tightly: the icon itself (+2px) and a label strip the width of the
    /// icon — NOT the whole cell. The surrounding padding and the dead band below the label fall
    /// through to the container so a drag/click there pages instead of grabbing the app. Keeps
    /// the per-app hit footprint close to the icon, like iOS (user: the range felt too large).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let icon = iconFrame.insetBy(dx: -2, dy: -2)
        // Hidden labels (design §1.2): the label strip is skipped outright — only the
        // icon (±2pt) claims events, everything else falls through to the pager.
        guard metrics.showsLabels else { return icon.contains(local) ? self : nil }
        let labelHit = NSRect(x: icon.minX, y: label.frame.minY, width: icon.width, height: label.frame.height)
        return (icon.contains(local) || labelHit.contains(local)) ? self : nil
    }

    override func accessibilityPerformPress() -> Bool {
        container?.activate(self)
        return true
    }
}
