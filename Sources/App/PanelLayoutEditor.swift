import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

/// Drag previews stay local; only completed operations change the host's layout.
struct PanelLayoutEditor: View {
    @ObservedObject var pluginHost: PluginHost
    let panelID: String
    let onDismiss: () -> Void
    let revealBottomRequest: UUID?
    @StateObject private var session: PanelLayoutEditingSession
    @StateObject private var scroller = PanelLayoutDragScroller()
    @StateObject private var dropGeometryCache = PanelLayoutDropGeometryCache()
    @State private var hover = PanelLayoutHoverState()
    @State private var entryToRemove: MenuBarPanelLayoutEntry?
    @State private var removalSourceRect = CGRect.zero
    @Namespace private var popoverCoordinateSpace
    @Environment(\.menuBarPanelTheme) private var theme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(pluginHost: PluginHost, panelID: String, onDismiss: @escaping () -> Void,
         session: @autoclosure @escaping () -> PanelLayoutEditingSession = PanelLayoutEditingSession(),
         revealBottomRequest: UUID? = nil) {
        self.pluginHost = pluginHost
        self.panelID = panelID
        self.onDismiss = onDismiss
        self.revealBottomRequest = revealBottomRequest
        self._session = StateObject(wrappedValue: session())
    }

    private var entries: [MenuBarPanelEntry] { pluginHost.panelEntries(in: panelID) }
    private var ids: [String] { entries.map(\.id) }

    var body: some View {
        let source = session.sourcePanelID.flatMap { sourcePanel in
            pluginHost.componentItems(in: sourcePanel).first { $0.id == session.sourceID }
        }
        let layout = PanelLayoutEditorSnapshot(pluginHost: pluginHost, panelID: panelID,
                                              cache: dropGeometryCache, source: source)
        GeometryReader { geometry in
            Group {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        visibleContent(layout)
                            .frame(minHeight: geometry.size.height, alignment: .topLeading)
                            .contentShape(Rectangle())
                            .onDrop(of: [PanelLayoutDragTransfer.type], delegate: PanelLayoutDropDelegate(
                                session: session, ids: { ids }, validate: { session.validate(in: pluginHost, panelID: panelID) },
                                update: { updateDestination($0, layout: layout) },
                                stopScrolling: scroller.stop, commit: commit
                            ))
                    }
                    .frame(maxWidth: .infinity)
                    .background(PanelLayoutScrollAnchor(scroller: scroller, hover: hover, bottomRequest: revealBottomRequest))
                }
                .overlay {
                    if layout.ids.isEmpty {
                        emptyState.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                    }
                }
                .onChange(of: layout.ids) {
                    session.reconcile(ids: layout.ids, panelID: panelID)
                    scroller.stop()
                }
                .onChange(of: layout.frames) {
                    if session.destinationPanelID == nil || session.destinationPanelID == panelID { session.invalidate() }
                    scroller.stop()
                }
                .onChange(of: session.token) { _, token in
                    hover.setDragging(token != nil)
                    if token == nil { scroller.stop() }
                }
                .onAppear { hover.setDragging(session.token != nil) }
                .onDisappear { scroller.stop() }
                .environment(\.panelLayoutScrollToItem, { id in
                    DispatchQueue.main.async {
                        let updated = PanelLayoutEditorSnapshot(pluginHost: pluginHost, panelID: panelID)
                        if let frame = updated.frames.first(where: { $0.id == id })?.frame {
                            scroller.reveal(frame)
                        }
                    }
                })
            }
            .coordinateSpace(name: popoverCoordinateSpace)
            .popover(item: $entryToRemove, attachmentAnchor: removalAttachment(in: geometry.size),
                     arrowEdge: .trailing) { item in
                MenuBarPanelRemovalConfirmation(
                    title: FeatureL10n.string("移除组件？"),
                    message: FeatureL10n.format("将从此面板移除“%@”。你可以从添加组件中重新添加。", item.item.title),
                    systemImage: item.item.iconName, actionTitle: FeatureL10n.string("移除"),
                    errorLabel: FeatureL10n.string("无法移除组件"), identifier: "panel.layout.remove",
                    onCancel: { entryToRemove = nil }, onConfirm: {
                        scroller.stop()
                        session.reset()
                        entryToRemove = nil
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            _ = pluginHost.removePanelEntry(item.entry, from: panelID)
                        }
                        return nil
                    }
                )
                .onExitCommand { entryToRemove = nil }
            }
            .onChange(of: session.feedback) { _, feedback in
                guard feedback != .guidance else { return }
                announce(feedback.message)
            }
        }
    }

    private func removalAttachment(in size: CGSize) -> PopoverAttachmentAnchor {
        guard removalSourceRect.height > 0, size.width > 0, size.height > 0 else { return .rect(.bounds) }
        // Keep the popover beside the viewport, at the clicked control's height.
        // AppKit handles screen-edge avoidance; no window coordinates are needed.
        let height = min(removalSourceRect.height, size.height)
        let y = min(max(removalSourceRect.minY, 0), size.height - height)
        return .rect(.rect(CGRect(x: 0, y: y, width: size.width, height: height)))
    }

    private func visibleContent(_ layout: PanelLayoutEditorSnapshot) -> some View {
        let positions = layout.frames
        let indices = Dictionary(uniqueKeysWithValues: layout.ids.enumerated().map { ($0.element, $0.offset) })
        return PanelViewportStack(frames: layout.itemFrames(rightToLeft: layoutDirection == .rightToLeft),
                              width: ComponentPanelLayout.gridWidth,
                              height: PanelLayoutDestination.visibleContentHeight(itemHeight: layout.height),
                              retainedIDs: Set([session.sourceID, hover.focusedItemID].compactMap { $0 })) { id in
            if let item = layout.items[id], let index = indices[id] {
                reorderItem(item, feature: layout.features[item.entry.id], index: index, count: layout.ids.count)
                    .environment(\.layoutDirection, layoutDirection)
            }
        }
        .overlay(alignment: .topLeading) {
            PanelLayoutInsertionMarker(preview: session.dragPreview)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: positions)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var emptyState: some View {
        Text(FeatureL10n.string("点击添加组件，为此面板添加内容"))
            .font(.subheadline)
            .foregroundStyle(theme.text.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .accessibilityIdentifier("panel.layout.empty")
    }

    private func reorderItem(_ item: MenuBarPanelLayoutEntry, feature: PluginPanelRowSnapshot?, index: Int, count: Int) -> some View {
        PanelLayoutReorderItem(
            id: item.id, title: item.item.title, icon: item.item.iconName, index: index, count: count,
            isDragging: session.sourceID == item.id, panels: pluginHost.menuBarPanels, panelID: panelID,
            hover: hover, hoverState: hover.state(for: item.id),
            nativeSource: session.nativeDragSource,
            popoverCoordinateSpace: popoverCoordinateSpace,
            move: { commit(.init(id: item.id, offset: $0)) },
            remove: { sourceRect in
                removalSourceRect = sourceRect
                entryToRemove = item
            },
            moveToPanel: { move(item.entry, to: $0) }
        ) {
            if item.entry.kind == .widget {
                pluginHost.componentViewItem(for: item.entry.id, dismiss: onDismiss).content
            } else if let feature {
                FeatureRowView(
                    item: feature,
                    indicator: pluginHost.rowIndicator(for: feature.id),
                    compactIndicator: pluginHost.rowCompactIndicator(for: feature.id),
                    onDisclosureToggle: { _ in }, onSelectionChange: { _, _ in },
                    onNavigationSelectionChange: { _, _ in }, onNavigationHoverChange: { _, _, _ in },
                    onNavigationRowFrameChange: { _, _, _ in }, onDateChange: { _, _ in },
                    onSwitchChange: { _ in false }, onSliderChange: { _, _, _ in },
                    onActionInvoke: { _, _ in }
                )
            }
        } beginDrag: {
            scroller.stop()
            return session.begin(entry: item.entry, panelID: panelID, ids: ids)
        } endDrag: { [weak session, weak scroller] token in
            guard let session, session.token == token else { return }
            scroller?.stop()
            session.sourceEnded(token: token)
        }
    }

    private func move(_ entry: MenuBarPanelEntry, to destination: String) {
        scroller.stop(); session.reset()
        _ = pluginHost.transferPanelEntry(entry, from: panelID, to: destination, at: pluginHost.panelEntries(in: destination).count)
    }

    private func updateDestination(_ point: CGPoint, layout: PanelLayoutEditorSnapshot) {
        guard session.validate(in: pluginHost, panelID: panelID) else { scroller.stop(); return }
        preview(at: point, layout: layout)
        scroller.start { preview(at: $0, layout: layout) }
    }

    private func preview(at point: CGPoint, layout: PanelLayoutEditorSnapshot) {
        let target = layout.dropGeometry.target(at: point, rightToLeft: layoutDirection == .rightToLeft)
        session.preview(target: target, ids: layout.ids)
    }

    private func commit(_ move: PanelLayoutEditingSession.Move) {
        scroller.stop()
        session.commit(move, in: pluginHost, panelID: panelID)
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }
}

/// Resolve the host's ordering and packing once per content update, then reuse the
/// same geometry for rendering, pointer movement, and drag autoscrolling.
@MainActor
private struct PanelLayoutEditorSnapshot {
    let ids: [String]
    let items: [String: MenuBarPanelLayoutEntry]
    let features: [String: PluginPanelRowSnapshot]
    let frames: [PanelLayoutEntryFrame]
    let height: CGFloat
    let dropGeometry: PanelLayoutDropGeometry

    func itemFrames(rightToLeft: Bool) -> [PanelItemFrame] {
        frames.map { position in
            var frame = position.frame
            if rightToLeft { frame.origin.x = ComponentPanelLayout.gridWidth - frame.maxX }
            return PanelItemFrame(id: position.id, frame: frame)
        }
    }

    init(pluginHost: PluginHost, panelID: String, cache: PanelLayoutDropGeometryCache? = nil,
         source: PluginPanelWidgetSnapshot? = nil) {
        let entries = pluginHost.panelEntries(in: panelID)
        let components = pluginHost.componentItems(in: panelID)
        let features = pluginHost.panelItems(in: panelID)
        let placement = ConfiguredMenuBarPanelLayout.placement(
            entries: entries, components: components, features: features
        )
        ids = entries.map(\.id)
        items = Dictionary(uniqueKeysWithValues: pluginHost.panelLayoutEntries(in: panelID).map { ($0.id, $0) })
        self.features = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0) })
        frames = PanelLayoutEntryFrame.frames(entries: entries, placement: placement)
        dropGeometry = cache?.geometry(entries: entries, components: components, features: features,
                                       frames: frames, source: source) ?? PanelLayoutDropGeometry(frames: frames)
        height = placement.height
    }
}

private struct PanelLayoutInsertionMarker: View {
    @ObservedObject var preview: PanelLayoutDragPreview
    @Environment(\.menuBarPanelTheme) private var theme

    var body: some View {
        if let target = preview.target, let marker = target.markerFrame {
            RoundedRectangle(cornerRadius: target.isVacancy ? 8 : 1)
                .fill(theme.accent.opacity(target.isVacancy ? 0.12 : 1))
                .overlay {
                    if target.isVacancy {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(theme.accent, lineWidth: 2)
                    }
                }
                .frame(width: marker.width, height: marker.height)
                .offset(x: marker.minX, y: marker.minY)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private struct PanelLayoutScrollToItemKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (String) -> Void = { _ in }
}

private extension EnvironmentValues {
    var panelLayoutScrollToItem: @MainActor @Sendable (String) -> Void {
        get { self[PanelLayoutScrollToItemKey.self] }
        set { self[PanelLayoutScrollToItemKey.self] = newValue }
    }
}

private struct PanelLayoutReorderItem<Content: View>: View {
    let id: String
    let title: String
    let icon: String
    let index: Int
    let count: Int
    let isDragging: Bool
    let panels: [MenuBarPanelDefinition]
    let panelID: String
    let hover: PanelLayoutHoverState
    @ObservedObject var hoverState: PanelLayoutItemHoverState
    let nativeSource: PanelLayoutNativeDragSource
    let popoverCoordinateSpace: Namespace.ID
    let move: (Int) -> Void
    let remove: (CGRect) -> Void
    let moveToPanel: (String) -> Void
    @ViewBuilder let content: Content
    let beginDrag: () -> String?
    let endDrag: (String) -> Void
    @Environment(\.menuBarPanelTheme) private var theme
    @Environment(\.panelLayoutScrollToItem) private var scrollToItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Control: Hashable { case remove, moveTo, more }
    @Environment(\.layoutDirection) private var layoutDirection
    @FocusState private var focusedControl: Control?

    private var showsControls: Bool { hoverState.isActive }

    var body: some View {
        ZStack {
            // Preserve the plugin's enabled appearance while excluding its content
            // from pointer input, keyboard focus, and accessibility actions.
            content
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .compositingGroup()
                .blur(radius: showsControls ? 2 : 0)
                .overlay { theme.surfaces.panel.opacity(showsControls ? 0.22 : 0) }
                .clipShape(RoundedRectangle(cornerRadius: MenuBarPanelLayout.cornerRadius))
                .opacity(isDragging ? 0.32 : 1)
                .scaleEffect(isDragging ? 0.985 : 1)
                .allowsHitTesting(false)
                .focusable(false)
                .accessibilityHidden(true)
            GeometryReader { proxy in
                let metrics = PanelLayoutItemControlsLayout(size: proxy.size)
                PanelLayoutControls(metrics: metrics, rightToLeft: layoutDirection == .rightToLeft) {
                    if metrics.isCompact {
                        MenuBarPanelMenu(makeMenu: { compactMenu(proxy: proxy, metrics: metrics) }) {
                            controlIcon("ellipsis", side: metrics.buttonSide, preferredIconSide: 14)
                        }
                        .focused($focusedControl, equals: .more)
                        .help(PanelLayoutCopy.position(title, index: index, count: count))
                        .accessibilityLabel(PanelLayoutCopy.position(title, index: index, count: count))
                        .accessibilityIdentifier("panel.layout.more.\(id)")
                    } else {
                        Button { requestRemoval(proxy: proxy, metrics: metrics) } label: {
                            controlIcon("trash", side: metrics.buttonSide)
                        }
                        .focused($focusedControl, equals: .remove)
                        .help(FeatureL10n.string("移除组件"))
                        .accessibilityLabel(FeatureL10n.string("移除组件"))
                        .accessibilityIdentifier("panel.layout.remove.\(id)")

                        MenuBarPanelMenu(makeMenu: { destinationMenu(showsHeading: true) }) {
                            controlIcon("arrow.forward.square", side: metrics.buttonSide)
                        }
                        .focused($focusedControl, equals: .moveTo)
                        .help(FeatureL10n.string("移动到"))
                        .accessibilityLabel(FeatureL10n.string("移动到"))
                        .accessibilityIdentifier("panel.layout.moveTo.\(id)")

                        MenuBarPanelMenu(makeMenu: orderingMenu) {
                            controlIcon("ellipsis.circle", side: metrics.buttonSide)
                        }
                        .focused($focusedControl, equals: .more)
                        .accessibilityLabel(PanelLayoutCopy.position(title, index: index, count: count))
                        .accessibilityIdentifier("panel.layout.more.\(id)")
                    }
                }
                .accessibilityHint(PanelLayoutCopy.hint)
                .accessibilityAction(named: PanelLayoutCopy.earlier) { if index > 0 { perform(index - 1) } }
                .accessibilityAction(named: PanelLayoutCopy.later) { if index < count - 1 { perform(index + 2) } }
                .accessibilityAction(named: PanelLayoutCopy.beginning) { perform(0) }
                .accessibilityAction(named: PanelLayoutCopy.end) { perform(count) }
                .buttonStyle(.plain)
                .tint(theme.text.primary)
                .foregroundStyle(theme.text.primary)
                .fixedSize()
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)
        }
        // Retire the previous owner immediately, so fast scrolling never stacks
        // fading toolbars. Only the new owner's entrance is animated.
        .animation(showsControls && !reduceMotion ? .easeOut(duration: 0.12) : nil, value: showsControls)
        .overlay {
            PanelLayoutDragSource(id: id, title: title, icon: icon, showsControls: showsControls,
                                  isDraggable: true, rightToLeft: layoutDirection == .rightToLeft, hover: hover, nativeSource: nativeSource, begin: beginDrag, end: endDrag)
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDragging || (showsControls && focusedControl != nil) ? theme.accent : .clear, lineWidth: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onChange(of: focusedControl) { _, control in
            hover.focusChanged(id: id, isFocused: control != nil)
            if control != nil { scrollToItem(id) }
        }
        .id(id)
    }

    private func orderingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuBarPanelMenuItem(PanelLayoutCopy.earlier, isEnabled: index > 0) { perform(index - 1) })
        menu.addItem(MenuBarPanelMenuItem(PanelLayoutCopy.later, isEnabled: index < count - 1) { perform(index + 2) })
        menu.addItem(MenuBarPanelMenuItem(PanelLayoutCopy.beginning, isEnabled: index > 0) { perform(0) })
        menu.addItem(MenuBarPanelMenuItem(PanelLayoutCopy.end, isEnabled: index < count - 1) { perform(count) })
        return menu
    }

    private func destinationMenu(showsHeading: Bool = false) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if showsHeading {
            let heading = NSMenuItem(title: FeatureL10n.string("移动到"), action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            menu.addItem(.separator())
        }
        for panel in panels where panel.id != panelID {
            menu.addItem(MenuBarPanelMenuItem(panel.title,
                image: NSImage(systemSymbolName: PluginSystemImage.resolvedName(panel.systemImage),
                               accessibilityDescription: nil)) { moveToPanel(panel.id) })
        }
        return menu
    }

    private func compactMenu(proxy: GeometryProxy, metrics: PanelLayoutItemControlsLayout) -> NSMenu {
        let menu = orderingMenu()
        let destination = NSMenuItem(title: FeatureL10n.string("移动到"), action: nil, keyEquivalent: "")
        destination.submenu = destinationMenu()
        destination.isEnabled = destination.submenu?.items.isEmpty == false
        menu.addItem(destination)
        menu.addItem(.separator())
        menu.addItem(MenuBarPanelMenuItem(FeatureL10n.string("移除组件"),
            image: NSImage(systemSymbolName: "trash", accessibilityDescription: nil),
            identifier: "panel.layout.remove.\(id)") { requestRemoval(proxy: proxy, metrics: metrics) })
        return menu
    }

    private func requestRemoval(proxy: GeometryProxy, metrics: PanelLayoutItemControlsLayout) {
        let controls = metrics.frame(in: proxy.frame(in: .named(popoverCoordinateSpace)))
        let button = metrics.buttonFrame(at: 0, rightToLeft: layoutDirection == .rightToLeft)
        let anchor = button.offsetBy(dx: controls.minX, dy: controls.minY)
        // Let a compact menu finish dismissing before presenting confirmation.
        DispatchQueue.main.async { remove(anchor) }
    }

    private func controlIcon(_ symbol: String, side: CGFloat, preferredIconSide: CGFloat = 16) -> some View {
        let iconSide = max(1, min(preferredIconSide, side - 4))
        return Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .font(.system(size: iconSide, weight: .semibold))
            .frame(width: iconSide, height: iconSide)
            .frame(width: side, height: side)
            .contentShape(Rectangle())
    }

    private func perform(_ offset: Int) {
        move(offset)
        scrollToItem(id)
    }
}

enum PanelLayoutDragTransfer {
    static let type = UTType(exportedAs: "com.mactools.panel-layout-item")

    static let pasteboardType = NSPasteboard.PasteboardType(type.identifier)

    static func pasteboardItem(token: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(token, forType: pasteboardType)
        return item
    }

    static func accepts(
        providers: [NSItemProvider],
        hasActiveSession: Bool,
        sessionIsValid: Bool
    ) -> Bool {
        accepts(
            hasRegisteredPayload: providers.contains {
                $0.hasItemConformingToTypeIdentifier(type.identifier)
            },
            hasActiveSession: hasActiveSession,
            sessionIsValid: sessionIsValid
        )
    }

    static func accepts(
        hasRegisteredPayload: Bool,
        hasActiveSession: Bool,
        sessionIsValid: Bool
    ) -> Bool {
        guard hasActiveSession, sessionIsValid else { return false }
        return hasRegisteredPayload
    }
}

private struct PanelLayoutDropDelegate: DropDelegate {
    let session: PanelLayoutEditingSession
    let ids: () -> [String]
    let validate: () -> Bool
    let update: (CGPoint) -> Void
    let stopScrolling: () -> Void
    let commit: (PanelLayoutEditingSession.Move) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        PanelLayoutDragTransfer.accepts(
            hasRegisteredPayload: info.hasItemsConforming(
                to: [PanelLayoutDragTransfer.type]
            ),
            hasActiveSession: session.token != nil,
            sessionIsValid: validate()
        )
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        update(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        stopScrolling()
        session.leave()
    }

    func performDrop(info: DropInfo) -> Bool {
        stopScrolling()
        guard validateDrop(info: info) else { session.cancel(); return false }
        update(info.location)
        stopScrolling()
        guard let move = session.finish(ids: ids()) else { return true }
        commit(move)
        return true
    }
}
