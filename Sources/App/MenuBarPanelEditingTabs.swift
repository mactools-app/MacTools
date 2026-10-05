import AppKit
import MacToolsPluginKit
import SwiftUI

struct MenuBarPanelDeleteConfirmation: View {
    let panel: MenuBarPanelDefinition
    let onCancel: () -> Void
    let onDelete: () -> String?

    var body: some View {
        MenuBarPanelRemovalConfirmation(
            title: FeatureL10n.string("删除面板？"),
            message: AppL10n.feature(
                "此面板中的内容将回到各自的默认面板。",
                defaultValue: "此面板中的内容将保留并移至其他面板。"
            ),
            systemImage: panel.systemImage, actionTitle: FeatureL10n.string("删除"),
            errorLabel: FeatureL10n.string("无法删除面板"), identifier: "menuBarPanel.delete",
            isEnabled: !panel.isDefault, onCancel: onCancel, onConfirm: onDelete
        )
    }
}

struct MenuBarPanelRemovalConfirmation: View {
    let title: String
    let message: String
    let systemImage: String
    let actionTitle: String
    let errorLabel: String
    let identifier: String
    var isEnabled = true
    let onCancel: () -> Void
    let onConfirm: () -> String?
    @State private var errorMessage: String?
    @State private var presentationFocus = MenuBarPanelPopoverFocus()
    @Environment(\.menuBarPanelTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: PluginSystemImage.resolvedName(systemImage))
                    .font(.title3)
                    .foregroundStyle(theme.text.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
            }

            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(theme.status.critical)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(errorLabel + ": " + errorMessage)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                MenuBarPanelEditingButton(title: FeatureL10n.string("取消"), emphasis: .standard,
                                          role: .cancel) {
                    presentationFocus.end()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("\(identifier).cancel")
                MenuBarPanelEditingButton(title: actionTitle, emphasis: .prominent,
                                          role: .destructive, isEnabled: isEnabled) {
                    presentationFocus.end()
                    errorMessage = onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("\(identifier).confirm")
            }
        }
        .padding(14)
        .frame(width: 264)
        .background(theme.surfaces.panel)
        .background(MenuBarPanelPopoverFocusLifecycle(focus: presentationFocus).allowsHitTesting(false))
        .foregroundStyle(theme.text.primary)
        .accessibilityIdentifier("\(identifier).confirmation")
    }
}

/// End focus while the popover's SwiftUI responder proxies are still alive.
/// AppKit can retain a popover's key view in its parent window's responder chain.
@MainActor
final class MenuBarPanelPopoverFocus {
    weak var window: NSWindow?

    func end() {
        guard let window else { return }
        if let parent = window.parent, parent.firstResponder !== parent {
            parent.makeFirstResponder(nil)
        }
        if window.firstResponder !== window { window.makeFirstResponder(nil) }
    }
}

struct MenuBarPanelPopoverFocusLifecycle: NSViewRepresentable {
    let focus: MenuBarPanelPopoverFocus
    func makeNSView(context: Context) -> FocusView { FocusView(focus: focus) }
    func updateNSView(_ view: FocusView, context: Context) {}

    static func dismantleNSView(_ view: FocusView, coordinator: ()) {
        view.focus.end()
    }

    final class FocusView: NSView {
        let focus: MenuBarPanelPopoverFocus

        init(focus: MenuBarPanelPopoverFocus) {
            self.focus = focus
            super.init(frame: .zero)
            NotificationCenter.default.addObserver(self, selector: #selector(popoverWillClose(_:)),
                                                   name: NSPopover.willCloseNotification, object: nil)
        }

        required init?(coder: NSCoder) { nil }
        deinit { NotificationCenter.default.removeObserver(self) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focus.window = window
            if let window { MenuBarPanelWindowRegistry.markEditingPopover(window) }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window !== newWindow { focus.end() }
            super.viewWillMove(toWindow: newWindow)
        }

        @objc private func popoverWillClose(_ notification: Notification) {
            guard let popover = notification.object as? NSPopover, let window,
                  popover.contentViewController?.view.window === window else { return }
            focus.end()
        }
    }
}

/// Tabs share one width that adapts to the viewport and stays stable during a drag.
enum MenuBarPanelTabLayout {
    static let width: CGFloat = 26
    static let minimumWidth = width
    static let height = MenuBarPanelLayout.tabItemHeight
    static let spacing: CGFloat = 2
    static let inset = MenuBarPanelLayout.tabCapsuleInset
    static let stripHeight = height + inset * 2

    static func preferredWidth(count _: Int) -> CGFloat { width }

    static func contentWidth(count: Int, width: CGFloat = MenuBarPanelTabLayout.width) -> CGFloat {
        CGFloat(count) * width + CGFloat(max(0, count - 1)) * spacing + inset * 2
    }

    static func frame(at index: Int, width: CGFloat = MenuBarPanelTabLayout.width) -> CGRect {
        CGRect(x: inset + CGFloat(index) * (width + spacing), y: inset, width: width, height: height)
    }

    static func destination(centerX: CGFloat, count: Int, width: CGFloat = MenuBarPanelTabLayout.width) -> Int {
        min(max(Int(((centerX - inset - width / 2) / (width + spacing)).rounded()), 0), max(0, count - 1))
    }
}

struct MenuBarPanelTabs: NSViewRepresentable {
    let panels: [MenuBarPanelDefinition]
    let selectedPanelID: String
    let onSelect: (String) -> Void
    var isEditing = false
    var onMove: (String, Int) -> Void = { _, _ in }
    var onChangeIcon: (String) -> Void = { _ in }
    var itemDragSession: PanelLayoutEditingSession? = nil
    var onItemDragHover: (String) -> Void = { _ in }
    var onItemDrop: (String) -> Bool = { _ in false }
    @Environment(\.menuBarPanelTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @EnvironmentObject private var menuPresenter: MenuBarPanelMenuPresenter

    func makeNSView(context: Context) -> MenuBarPanelTabNavigationView {
        MenuBarPanelTabNavigationView()
    }

    static func dismantleNSView(_ view: MenuBarPanelTabNavigationView, coordinator: ()) {
        if let window = view.window, let focusedView = window.firstResponder as? NSView,
           focusedView.isDescendant(of: view) {
            window.makeFirstResponder(nil)
        }
    }

    func updateNSView(_ view: MenuBarPanelTabNavigationView, context: Context) {
        let strip = view.strip
        strip.menuPresenter = menuPresenter
        strip.onSelect = onSelect
        strip.onMove = onMove
        strip.onChangeIcon = onChangeIcon
        strip.itemDragSession = itemDragSession
        strip.onItemDragHover = onItemDragHover
        strip.onItemDrop = onItemDrop
        strip.isEditing = isEditing
        strip.reduceMotion = reduceMotion
        strip.selectionColor = NSColor(theme.surfaces.tabSelection)
        strip.hoverColor = NSColor(theme.surfaces.hover)
        strip.primaryColor = NSColor(theme.text.primary)
        strip.secondaryColor = NSColor(theme.text.secondary)
        strip.accentColor = NSColor(theme.accent)
        strip.update(panels: panels, selectedPanelID: selectedPanelID)
        view.configure(theme: theme, contrast: contrast)
        view.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuBarPanelTabNavigationView, context: Context) -> CGSize? {
        let fullWidth = MenuBarPanelTabLayout.contentWidth(
            count: panels.count, width: MenuBarPanelTabLayout.preferredWidth(count: panels.count)
        )
        return CGSize(width: min(proposal.width ?? fullWidth, fullWidth), height: MenuBarPanelTabLayout.stripHeight)
    }
}

@MainActor
final class MenuBarPanelTabNavigationView: NSView {
    let strip = MenuBarPanelTabStripView()
    private let scroll = NSScrollView()
    private let previousButton = MenuBarPanelIconControl()
    private let nextButton = MenuBarPanelIconControl()
    private let containerBackground = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(containerBackground)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.documentView = strip
        addSubview(scroll)
        for (button, symbol, label, action) in [
            (previousButton, "chevron.left", "向左滚动", #selector(scrollLeft)),
            (nextButton, "chevron.right", "向右滚动", #selector(scrollRight)),
        ] {
            button.setSymbol(symbol, pointSize: 9)
            button.setAccessibilityLabel(FeatureL10n.string(label))
            button.target = self
            button.action = action
            addSubview(button)
        }
        previousButton.setAccessibilityIdentifier("menuBarPanel.scrollLeft")
        nextButton.setAccessibilityIdentifier("menuBarPanel.scrollRight")
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateScrollButtons),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(theme: MenuBarPanelThemeStyle, contrast: ColorSchemeContrast) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            containerBackground.fillColor = NSColor(theme.surfaces.panel).cgColor
            containerBackground.strokeColor = NSColor(theme.surfaces.separator).cgColor
        }
        containerBackground.lineWidth = contrast == .increased ? 1 : 0.5
        for button in [previousButton, nextButton] {
            button.configureColors(selection: NSColor(theme.surfaces.tabSelection), hover: NSColor(theme.surfaces.hover),
                                   primary: NSColor(theme.text.primary), secondary: NSColor(theme.text.secondary))
        }
    }

    override func layout() {
        super.layout()
        let tabAreaWidth = bounds.width
        let tabArea = bounds.insetBy(dx: containerBackground.lineWidth / 2, dy: containerBackground.lineWidth / 2)
        containerBackground.path = CGPath(roundedRect: tabArea, cornerWidth: tabArea.height / 2,
                                         cornerHeight: tabArea.height / 2, transform: nil)
        let overflows = MenuBarPanelTabLayout.contentWidth(count: strip.panels.count, width: MenuBarPanelTabLayout.minimumWidth) > tabAreaWidth + 1
        let edgeWidth: CGFloat = overflows ? 18 : 0
        previousButton.isHidden = !overflows
        nextButton.isHidden = !overflows
        previousButton.frame = CGRect(x: 0, y: 0, width: edgeWidth, height: bounds.height)
        nextButton.frame = CGRect(x: tabAreaWidth - edgeWidth, y: 0, width: edgeWidth, height: bounds.height)
        strip.fitTabs(to: max(0, tabAreaWidth - edgeWidth * 2))
        scroll.frame = CGRect(x: edgeWidth, y: 0, width: max(0, tabAreaWidth - edgeWidth * 2), height: bounds.height)
        strip.revealSelectionIfNeeded()
        updateScrollButtons()
    }

    @objc private func updateScrollButtons() {
        previousButton.isEnabled = scroll.contentView.bounds.minX > 0.5
        nextButton.isEnabled = scroll.contentView.bounds.maxX < strip.bounds.maxX - 0.5
    }

    @objc private func scrollLeft() { scrollTabs(by: -1) }
    @objc private func scrollRight() { scrollTabs(by: 1) }

    private func scrollTabs(by direction: CGFloat) {
        let origin = scroll.contentView.bounds.minX + direction * (strip.tabWidth + MenuBarPanelTabLayout.spacing)
        scroll.contentView.scroll(to: CGPoint(x: min(max(origin, 0), max(0, strip.bounds.width - scroll.contentSize.width)), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

@MainActor
final class PanelLayoutTabSpringLoader {
    private var target: (panelID: String, token: String)?
    private var timer: Timer?

    func hover(panelID: String?, token: String?, activate: @escaping @MainActor (String, String) -> Void) {
        guard let panelID, let token else { cancel(); return }
        guard target?.panelID != panelID || target?.token != token else { return }
        cancel()
        target = (panelID, token)
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.target?.panelID == panelID, self.target?.token == token else { return }
                self.timer = nil
                activate(panelID, token)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        target = nil
    }
}

@MainActor
final class MenuBarPanelTabStripView: NSView, NSDraggingSource {
    private static let dragType = NSPasteboard.PasteboardType("com.ggbond.mactools.menu-bar-panel-tab")
    private(set) var panels: [MenuBarPanelDefinition] = []
    private(set) var previewIDs: [String] = []
    private(set) var draggedID: String?
    private(set) var tabWidth = MenuBarPanelTabLayout.width
    private var selectedPanelID = ""
    private var cells: [String: MenuBarPanelTabCell] = [:]
    private var dragGrabOffset: CGFloat = 0
    private var needsSelectionReveal = false
    private let insertionIndicator = NSView()
    var selectionColor = NSColor.controlAccentColor
    var hoverColor = NSColor.controlBackgroundColor
    var primaryColor = NSColor.labelColor
    var secondaryColor = NSColor.secondaryLabelColor
    var accentColor = NSColor.controlAccentColor
    var reduceMotion = false
    var isEditing = false {
        didSet { if !isEditing { finishReordering(commit: false); springLoader.cancel() } }
    }
    var onSelect: (String) -> Void = { _ in }
    var onMove: (String, Int) -> Void = { _, _ in }
    var onChangeIcon: (String) -> Void = { _ in }

    weak var menuPresenter: MenuBarPanelMenuPresenter?

    weak var itemDragSession: PanelLayoutEditingSession? {
        didSet { if itemDragSession?.token == nil { springLoader.cancel() } }
    }
    var onItemDragHover: (String) -> Void = { _ in }
    var onItemDrop: (String) -> Bool = { _ in false }
    private let springLoader = PanelLayoutTabSpringLoader()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([Self.dragType, PanelLayoutDragTransfer.pasteboardType])
        insertionIndicator.wantsLayer = true
        insertionIndicator.layer?.cornerRadius = 1
        insertionIndicator.isHidden = true
        addSubview(insertionIndicator)
        setAccessibilityIdentifier("menuBarPanel.editingTabs")
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(FeatureL10n.string("面板设置"))
    }

    required init?(coder: NSCoder) { nil }

    func update(panels: [MenuBarPanelDefinition], selectedPanelID: String) {
        let ids = panels.map(\.id)
        let orderChanged = self.panels.map(\.id) != ids
        let selectionChanged = self.selectedPanelID != selectedPanelID
        // An external reorder or removal invalidates a drag's original indices.
        if orderChanged { draggedID = nil; springLoader.cancel() }
        self.panels = panels
        self.selectedPanelID = selectedPanelID
        if draggedID == nil { previewIDs = ids }
        for id in Array(cells.keys) where !ids.contains(id) {
            cells.removeValue(forKey: id)?.removeFromSuperview()
        }
        for panel in panels {
            let cell: MenuBarPanelTabCell
            if let existing = cells[panel.id] {
                cell = existing
            } else {
                cell = MenuBarPanelTabCell(panelID: panel.id, strip: self)
                cells[panel.id] = cell
                addSubview(cell, positioned: .below, relativeTo: insertionIndicator)
            }
            cell.configure(panel: panel, selected: panel.id == selectedPanelID)
        }
        setFrameSize(CGSize(width: MenuBarPanelTabLayout.contentWidth(count: panels.count, width: tabWidth),
                            height: MenuBarPanelTabLayout.stripHeight))
        layoutTabs(animated: orderChanged && !selectionChanged)
        needsSelectionReveal = needsSelectionReveal || selectionChanged
        revealSelectionIfNeeded()
    }

    func fitTabs(to availableWidth: CGFloat) {
        guard !panels.isEmpty else { return }
        let gaps = CGFloat(panels.count - 1) * MenuBarPanelTabLayout.spacing + MenuBarPanelTabLayout.inset * 2
        let width = min(MenuBarPanelTabLayout.width, max(MenuBarPanelTabLayout.minimumWidth,
            floor((availableWidth - gaps) / CGFloat(panels.count))))
        guard width != tabWidth else { return }
        finishReordering(commit: false)
        tabWidth = width
        setFrameSize(CGSize(width: MenuBarPanelTabLayout.contentWidth(count: panels.count, width: width),
                            height: MenuBarPanelTabLayout.stripHeight))
        layoutTabs(animated: false)
        needsSelectionReveal = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finishReordering(commit: false); springLoader.cancel() }
        revealSelectionIfNeeded()
    }

    override func layout() {
        super.layout()
        revealSelectionIfNeeded()
    }

    fileprivate func revealSelectionIfNeeded() {
        guard needsSelectionReveal, draggedID == nil,
              let cell = cells[selectedPanelID], let scroll = enclosingScrollView,
              scroll.contentSize.width > 0 else { return }
        needsSelectionReveal = false
        scrollToVisible(cell.frame.insetBy(dx: -MenuBarPanelTabLayout.inset, dy: 0))
    }

    private func layoutTabs(animated: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !reduceMotion ? 0.16 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (index, id) in previewIDs.enumerated() {
                guard let cell = cells[id] else { continue }
                cell.animator().frame = MenuBarPanelTabLayout.frame(at: index, width: tabWidth)
                cell.alphaValue = id == draggedID ? 0.22 : 1
            }
        }
        insertionIndicator.isHidden = draggedID == nil
        if let draggedID, let index = previewIDs.firstIndex(of: draggedID) {
            let rect = MenuBarPanelTabLayout.frame(at: index, width: tabWidth)
            insertionIndicator.frame = CGRect(x: rect.minX, y: rect.minY + 6, width: 2, height: rect.height - 12)
            insertionIndicator.layer?.backgroundColor = accentColor.cgColor
        }
    }

    func selectPanel(_ id: String) {
        guard draggedID == nil, panels.contains(where: { $0.id == id }) else { return }
        if id == selectedPanelID {
            if isEditing { onChangeIcon(id) }
        } else {
            onSelect(id)
        }
    }

    func selectNeighbor(of id: String, offset: Int) {
        guard let index = panels.firstIndex(where: { $0.id == id }), panels.indices.contains(index + offset) else { return }
        let destination = panels[index + offset].id
        onSelect(destination)
        if let cell = cells[destination] { window?.makeFirstResponder(cell.selectionButton) }
    }

    func menu(forPanelID id: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard isEditing, let index = panels.firstIndex(where: { $0.id == id }) else { return menu }
        func append(_ title: String, symbol: String, action: Selector, enabled: Bool) {
            let item = NSMenuItem(title: FeatureL10n.string(title), action: action, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.representedObject = id
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        append("向左移动", symbol: "arrow.left", action: #selector(movePanelLeft(_:)), enabled: index > 0)
        append("向右移动", symbol: "arrow.right", action: #selector(movePanelRight(_:)), enabled: index < panels.count - 1)
        menu.addItem(.separator())
        append("更换图标", symbol: "square.grid.2x2", action: #selector(changeIcon(_:)), enabled: true)
        return menu
    }

    @objc private func movePanelLeft(_ sender: NSMenuItem) { move(sender, offset: -1) }
    @objc private func movePanelRight(_ sender: NSMenuItem) { move(sender, offset: 1) }

    private func move(_ sender: NSMenuItem, offset: Int) {
        guard let id = sender.representedObject as? String, let index = panels.firstIndex(where: { $0.id == id }),
              panels.indices.contains(index + offset) else { return }
        needsSelectionReveal = id == selectedPanelID
        onMove(id, index + (offset > 0 ? 2 : -1))
    }

    @objc private func changeIcon(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, panels.contains(where: { $0.id == id }) else { return }
        onChangeIcon(id)
    }

    func beginReordering(_ id: String) -> Bool {
        guard isEditing, draggedID == nil, panels.contains(where: { $0.id == id }) else { return false }
        draggedID = id
        previewIDs = panels.map(\.id)
        layoutTabs(animated: false)
        return true
    }

    func previewReordering(centerX: CGFloat) {
        guard let draggedID else { return }
        var ids = panels.map(\.id).filter { $0 != draggedID }
        ids.insert(draggedID, at: MenuBarPanelTabLayout.destination(centerX: centerX, count: panels.count, width: tabWidth))
        guard ids != previewIDs else { return }
        previewIDs = ids
        layoutTabs(animated: true)
    }

    func finishReordering(commit: Bool) {
        guard let draggedID else { return }
        let sourceIndex = panels.firstIndex { $0.id == draggedID }
        let destinationIndex = previewIDs.firstIndex(of: draggedID)
        self.draggedID = nil
        if commit, let sourceIndex, let destinationIndex, sourceIndex != destinationIndex {
            onMove(draggedID, destinationIndex + (destinationIndex > sourceIndex ? 1 : 0))
        } else {
            previewIDs = panels.map(\.id)
        }
        layoutTabs(animated: true)
    }

    func beginDragging(panelID: String, event: NSEvent, grabOffset: CGFloat) -> Bool {
        guard let cell = cells[panelID],
              let bitmap = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { return false }
        cell.cacheDisplay(in: cell.bounds, to: bitmap)
        let image = NSImage(size: cell.bounds.size)
        image.addRepresentation(bitmap)
        guard beginReordering(panelID) else { return false }
        dragGrabOffset = grabOffset
        let item = NSPasteboardItem()
        item.setString(panelID, forType: Self.dragType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let point = convert(event.locationInWindow, from: nil)
        let dragFrame = CGRect(x: point.x - grabOffset, y: cell.frame.minY, width: cell.frame.width, height: cell.frame.height)
        draggingItem.setDraggingFrame(dragFrame, contents: image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishReordering(commit: false)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func wantsPeriodicDraggingUpdates() -> Bool { draggedID != nil }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if acceptsItemDrag(sender) {
            updateItemDragHover(panelID: itemDragPanel(at: convert(sender.draggingLocation, from: nil)))
            return .move
        }
        springLoader.cancel()
        guard acceptsDrag(sender) else { return [] }
        autoScroll(at: convert(sender.draggingLocation, from: nil))
        let point = convert(sender.draggingLocation, from: nil)
        previewReordering(centerX: point.x - dragGrabOffset + tabWidth / 2)
        insertionIndicator.isHidden = false
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        springLoader.cancel()
        guard draggedID != nil else { return }
        previewIDs = panels.map(\.id)
        layoutTabs(animated: true)
        insertionIndicator.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        springLoader.cancel()
        if acceptsItemDrag(sender) {
            guard let id = itemDragPanel(at: convert(sender.draggingLocation, from: nil)) else { return false }
            return onItemDrop(id)
        }
        guard acceptsDrag(sender) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        previewReordering(centerX: point.x - dragGrabOffset + tabWidth / 2)
        finishReordering(commit: true)
        return true
    }

    func updateItemDragHover(panelID: String?) {
        let target = isEditing && panelID != selectedPanelID ? panelID : nil
        springLoader.hover(panelID: target, token: itemDragSession?.token) { [weak self] id, token in
            guard let self, self.isEditing, self.itemDragSession?.token == token,
                  self.panels.contains(where: { $0.id == id }) else { return }
            self.onItemDragHover(id)
        }
    }

    private func itemDragPanel(at point: CGPoint) -> String? {
        panels.first { cells[$0.id]?.frame.contains(point) == true }?.id
    }

    private func acceptsItemDrag(_ sender: NSDraggingInfo) -> Bool {
        guard isEditing, let session = itemDragSession, let token = session.token,
              (sender.draggingSource as? PanelLayoutNativeDragSource) === session.nativeDragSource else { return false }
        return sender.draggingPasteboard.string(forType: PanelLayoutDragTransfer.pasteboardType) == token
    }

    private func acceptsDrag(_ sender: NSDraggingInfo) -> Bool {
        guard (sender.draggingSource as? MenuBarPanelTabStripView) === self, let draggedID else { return false }
        return sender.draggingPasteboard.string(forType: Self.dragType) == draggedID
    }

    private func autoScroll(at point: NSPoint) {
        guard let scroll = enclosingScrollView else { return }
        let visible = visibleRect
        let delta: CGFloat = point.x < visible.minX + 24 ? -10 : (point.x > visible.maxX - 24 ? 10 : 0)
        let origin = min(max(scroll.contentView.bounds.minX + delta, 0), max(0, bounds.width - visible.width))
        guard abs(origin - scroll.contentView.bounds.minX) > 0.5 else { return }
        scroll.contentView.scroll(to: CGPoint(x: origin, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// A single capsule control supplies selection, hover, symbols, and activation
/// for normal tabs, editing tabs, and the add button.
@MainActor
class MenuBarPanelIconControl: NSControl {
    weak var menuPresenter: MenuBarPanelMenuPresenter?
    private let imageView = NSImageView()
    private var symbolName: String?
    private var symbolPointSize: CGFloat?
    private var hoverTrackingArea: NSTrackingArea?
    private var pressedAt: NSPoint?
    private var didBeginDrag = false
    private var selectionColor = NSColor.controlAccentColor
    private var hoverColor = NSColor.controlBackgroundColor
    private var primaryColor = NSColor.labelColor
    private var secondaryColor = NSColor.secondaryLabelColor
    private(set) var isHovered = false
    var isSelected = false {
        didSet { if oldValue != isSelected { updateAppearance() } }
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }
    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageView.imageScaling = .scaleNone
        addSubview(imageView)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    func setSymbol(_ name: String, pointSize: CGFloat = MenuBarPanelLayout.tabIconSize) {
        guard symbolName != name || symbolPointSize != pointSize else { return }
        symbolName = name
        symbolPointSize = pointSize
        imageView.image = NSImage(systemSymbolName: PluginSystemImage.resolvedName(name), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
    }

    func configureColors(selection: NSColor, hover: NSColor, primary: NSColor, secondary: NSColor) {
        selectionColor = selection
        hoverColor = hover
        primaryColor = primary
        secondaryColor = secondary
        updateAppearance()
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { menuPresenter?.cancel(from: self) }
        // Release focus while the old responder chain is still attached.
        if let window, window !== newWindow, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background = isSelected ? selectionColor : (isHovered && isEnabled ? hoverColor : .clear)
            layer?.backgroundColor = background.cgColor
            imageView.contentTintColor = isSelected ? primaryColor : secondaryColor
            imageView.alphaValue = isEnabled ? 1 : 0.4
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        pressedAt = convert(event.locationInWindow, from: nil)
        didBeginDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didBeginDrag, let pressedAt else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressedAt.x, point.y - pressedAt.y) >= 4 else { return }
        // AppKit may enter drag tracking before beginDraggingSession returns.
        didBeginDrag = true
        if !beginDrag(with: event, pressedAt: pressedAt) { didBeginDrag = false }
    }

    func beginDrag(with event: NSEvent, pressedAt: NSPoint) -> Bool { false }

    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil; didBeginDrag = false }
        guard !didBeginDrag, pressedAt != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate()
    }

    private func activate() {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        sendAction(action, to: target)
    }

    override func rightMouseDown(with event: NSEvent) {
        pressedAt = nil
        guard let menuPresenter, let menu = menu(for: event), !menu.items.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        menuPresenter.present(from: self, at: point) { menu }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49: activate()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        activate()
        return true
    }
}

@MainActor
private final class MenuBarPanelTabCell: NSView {
    let selectionButton = MenuBarPanelTabButton()
    private let panelID: String
    private weak var strip: MenuBarPanelTabStripView?

    override var isFlipped: Bool { true }

    init(panelID: String, strip: MenuBarPanelTabStripView) {
        self.panelID = panelID
        self.strip = strip
        super.init(frame: MenuBarPanelTabLayout.frame(at: 0))
        selectionButton.panelID = panelID
        selectionButton.strip = strip
        selectionButton.target = self
        selectionButton.action = #selector(selectTab)
        selectionButton.setAccessibilityIdentifier("menuBarPanel.tab.\(panelID)")
        selectionButton.setAccessibilityRole(.radioButton)
        addSubview(selectionButton)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        selectionButton.frame = bounds
    }

    func configure(panel: MenuBarPanelDefinition, selected: Bool) {
        let canEditIcon = selected && strip?.isEditing == true
        selectionButton.toolTip = canEditIcon ? FeatureL10n.string("更换图标") : panel.title
        selectionButton.setSymbol(panel.systemImage)
        selectionButton.isSelected = selected
        selectionButton.setAccessibilityLabel(panel.title)
        selectionButton.setAccessibilityValue(selected)
        selectionButton.setAccessibilityHelp(canEditIcon ? FeatureL10n.string("更换图标") : "")
        selectionButton.alphaValue = panel.isHidden && !selected ? 0.5 : 1
        if let strip {
            selectionButton.menuPresenter = strip.menuPresenter
            selectionButton.configureColors(selection: strip.selectionColor, hover: strip.hoverColor,
                                            primary: strip.primaryColor, secondary: strip.secondaryColor)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        strip?.isEditing == true ? strip?.menu(forPanelID: panelID) : nil
    }

    @objc private func selectTab() { strip?.selectPanel(panelID) }
}

@MainActor
private final class MenuBarPanelTabButton: MenuBarPanelIconControl {
    var panelID = ""
    weak var strip: MenuBarPanelTabStripView?

    override func beginDrag(with event: NSEvent, pressedAt: NSPoint) -> Bool {
        guard let strip, strip.isEditing else { return false }
        return strip.beginDragging(panelID: panelID, event: event, grabOffset: pressedAt.x)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        strip?.isEditing == true ? strip?.menu(forPanelID: panelID) : nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: strip?.selectNeighbor(of: panelID, offset: -1)
        case 124: strip?.selectNeighbor(of: panelID, offset: 1)
        default: super.keyDown(with: event)
        }
    }
}
