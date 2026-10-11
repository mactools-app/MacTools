import AppKit
import Carbon.HIToolbox
import Combine
import MacToolsPluginKit

@MainActor
final class WindowSwitcherOverlayController: NSObject, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate {
    var onShortcutChange: ((WindowSwitcherAppEntry, String?) -> WindowSwitcherShortcutCustomizationResult)?
    private var recordingEntryID: String?
    var onSelect: ((WindowSwitcherAppEntry) -> Void)?
    var onClose: ((WindowSwitcherAppEntry) -> Void)?
    var onQuit: ((WindowSwitcherAppEntry) -> Void)?
    var onCancel: (() -> Void)?
    var onSessionChange: ((WindowSwitcherSession) -> Void)?
    var onPreviewChange: ((Bool) -> Void)?
    var onModeChange: ((WindowSwitcherMode) -> Void)?
    var onSearchEditingChange: ((Bool) -> Void)?
    var onMenuTrackingChange: ((Bool) -> Void)?
    private var menuGeneration = 0
    private(set) var isPresentingMenu = false
    private var releasedDuringMenu = false
    var isEditingSearch: Bool { search.currentEditor() != nil }
    private(set) var session: WindowSwitcherSession?

    private final class Panel: NSPanel {
        var searchShortcutHandler: ((NSEvent) -> Bool)?
        var shortcutHandler: ((NSEvent) -> Bool)?
        var searchEventFilter: ((NSEvent) -> NSEvent)?
        var searchTransitionHandler: ((NSEvent) -> Bool)?
        override func sendEvent(_ event: NSEvent) {
            if event.type == .magnify {
                WindowSwitcherPinchDiagnostics.record("panel magnify phase=\(event.phase.rawValue) delta=\(event.magnification) key=\(isKeyWindow) active=\(NSApp.isActive)")
            }
            if searchShortcutHandler?(event) == true { return }
            let filtered = searchEventFilter?(event) ?? event
            if filtered.type == .keyDown {
                if shortcutHandler?(filtered) == true || searchTransitionHandler?(filtered) == true { return }
            }
            super.sendEvent(filtered)
        }
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if searchShortcutHandler?(event) == true { return true }
            let filtered = searchEventFilter?(event) ?? event
            if filtered.modifierFlags != event.modifierFlags {
                // Consume the original chord so AppKit cannot retry menus with
                // the held Command modifier after native text input handles it.
                firstResponder?.keyDown(with: filtered)
                return true
            }
            return shortcutHandler?(event) == true || searchTransitionHandler?(event) == true || super.performKeyEquivalent(with: event)
        }
    }
    private final class Table: NSTableView {
        var contextMenuForRow: ((Int) -> NSMenu?)?
        override func menu(for event: NSEvent) -> NSMenu? {
            contextMenuForRow?(row(at: convert(event.locationInWindow, from: nil)))
        }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control), let menu = menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            } else { super.mouseDown(with: event) }
        }
        var keyHandler: ((NSEvent) -> Bool)?
        override func keyDown(with event: NSEvent) {
            if keyHandler?(event) != true { super.keyDown(with: event) }
        }
    }
    private final class ModeButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    private let chooserFocus: WindowSwitcherChooserFocus
    private var isAcquiringChooserFocus = false
    private let dismissalMonitor = PluginPanelDismissalMonitor()
    // Trackpad magnification is routed to the active app. An activating chooser
    // receives the first pinch without requiring a click on its preview.
    private let panel = Panel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    private let table = Table()
    private let cards = WindowSwitcherCardCollection()
    private let cardScroll = NSScrollView()
    private let listScroll = NSScrollView()
    private let layoutPicker = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    var onLayoutChange: ((WindowSwitcherLayout) -> Void)?
    private var usesList = false
    private var cardColumns = 1
    private var previewHeight: NSLayoutConstraint!
    private var cardHeight: NSLayoutConstraint!
    private var listHeight: NSLayoutConstraint!
    private var initialResultCount = 0
    private struct SizePreference: Hashable {
        var list: Bool
        var preview: Bool
    }
    private var preferredSizes: [SizePreference: NSSize] = [:]
    private struct Placement {
        var origin: NSPoint
        var displayID: NSNumber?
    }
    private var preferredPositions: [SizePreference: Placement] = [:]
    private var sizingScope: WindowSwitcherSession.Scope?
    private var sizingDisplay: UInt32?
    private var applyingPanelLayout = false
    private let more = WindowSwitcherToolbarButton(title: "", target: nil, action: nil)
    private final class SearchField: NSTextField {
        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
        var onFocus: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocus?() }
            return accepted
        }
    }
    private let search = SearchField()
    private let scope = WindowSwitcherScopeControl()
    private var minimumScopeWidth: NSLayoutConstraint!
    private let display = NSPopUpButton()
    private let modeButton = ModeButton(frame: .zero)
    private let modeHint = NSTextField(labelWithString: "")
    private var configuredMode: WindowSwitcherMode = .searchSelect
    private var activeMode: WindowSwitcherMode = .searchSelect
    private let enterSearchButton = WindowSwitcherToolbarButton(title: "", target: nil, action: nil)
    private let searchHeader = NSStackView()
    private let inlineSearch = NSView()
    private var inlineSearchWidth: NSLayoutConstraint!
    private var inlineSearchMinimumWidth: NSLayoutConstraint!
    private var searchSurfaceHeight: NSLayoutConstraint!
    private var searchLeading: NSLayoutConstraint!
    private var usesInlineSearch = false
    private var isInlineSearchExpanded = false
    private var modeBeforeSearch: (isPersistent: Bool, usesDirectKeys: Bool)?
    private let previewDivider = NSBox()
    private let count = NSTextField(labelWithString: "")
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let previewImage = WindowSwitcherPreviewStage()
    private var localPinchMonitor: Any?
    private var globalPinchMonitor: Any?
    private let dragHandle = WindowSwitcherDragHandle()
    private let snapCoordinator = PluginWindowSnapCoordinator()
    nonisolated(unsafe) private var scrollObservers: [NSObjectProtocol] = []
    private var loadingTask: Task<Void, Never>?
    private var searchTransitionTask: Task<Void, Never>?
    private var showsSearchTransition = false
    private let dragBar = NSView()
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let previewTitle = NSTextField(labelWithString: "")
    private let previewPane = NSStackView()
    private let preview: WindowSwitcherPreview
    private let localization: PluginLocalization
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let quitButton = NSButton(title: "", target: nil, action: nil)
    private let openButton = NSButton(title: "", target: nil, action: nil)
    private let previewButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let searchSurface = WindowSwitcherHeaderSurface()
    private let searchIcon = NSImageView()
    private let clearSearchButton = WindowSwitcherToolbarButton()
    private let recordingCancel = NSButton(title: "", target: nil, action: nil)
    private var rows: [WindowSwitcherAppEntry] = []
    private var currentPID: pid_t?
    private var acceptsSearchFocus = false
    private var updating = false
    private var closing = false
    private var previewedEntry: WindowSwitcherAppEntry?
    private var previewedPermission: Bool?
    private var showsPreview = false
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    private var updatingViewport = false
    private var actionDiagnostic: WindowSwitcherDiagnostic?
    private var actionMessage: String? { actionDiagnostic?.message(using: localization) }
    private var renderedSession: WindowSwitcherSession?
    private var searchHeldModifiers: NSEvent.ModifierFlags = []
    private var localizationSubscription: AnyCancellable?
    private var needsLocalizationRefresh = false

    init(localization: PluginLocalization = PluginLocalization(bundle: .main), preview: WindowSwitcherPreview? = nil,
         focus: WindowSwitcherChooserFocus? = nil) {
        self.chooserFocus = focus ?? WindowSwitcherChooserFocus()
        self.localization = localization
        self.preview = preview ?? WindowSwitcherPreview(localization: localization)
        super.init()
        buildPanel()
        previewImage.onRequestFocus = { [weak self] in
            self?.focusPreviewNow()
        }
        previewImage.onRequestDetail = { [weak self] in self?.preview.requestDetail() }
        previewImage.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        previewImage.contextMenu = { [weak self] in self?.previewZoomMenu(tracksMenu: true) }
        self.preview.onChange = { [weak self] image, message in
            guard let self else { return }
            if message != nil {
                self.previewImage.clearTransition()
                self.previewImage.cancelPendingMagnification()
            }
            self.previewImage.image = image
            self.loadingTask?.cancel()
            self.previewLabel.isHidden = image != nil || message == nil
            self.previewLabel.stringValue = message ?? ""
            if image == nil, message == nil {
                self.loadingTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled, let self, self.isVisible else { return }
                    self.previewLabel.stringValue = self.localization.string("preview.loading", defaultValue: "正在加载预览…")
                    self.previewLabel.isHidden = false
                }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isVisible else { return }
                self.layoutPanel(preservePosition: true); self.render(forceRevealSelection: true)
            }
        }
        localizationSubscription = PluginRuntimeLocalization.source.$revision
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.refreshLocalization() }
            }
        refreshLocalization()
    }

    isolated deinit {
        localizationSubscription?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        scrollObservers.forEach(NotificationCenter.default.removeObserver)
        if let localPinchMonitor { NSEvent.removeMonitor(localPinchMonitor) }
        if let globalPinchMonitor { NSEvent.removeMonitor(globalPinchMonitor) }
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ session: WindowSwitcherSession, currentPID: pid_t?, showsPreview: Bool,
              preferredLayout: WindowSwitcherLayout? = nil, mode: WindowSwitcherMode? = nil) {
        acceptsSearchFocus = false
        menuGeneration += 1
        isPresentingMenu = false
        releasedDuringMenu = false
        searchTransitionTask?.cancel()
        showsSearchTransition = false
        self.session = session
        configuredMode = mode ?? (session.usesDirectKeys ? .keyWindow : session.isPersistent ? .searchSelect : .directCycle)
        activeMode = configuredMode
        previewImage.prefersGestureFocus = configuredMode == .directCycle
        self.currentPID = currentPID
        self.showsPreview = showsPreview
        renderedSession = nil
        initialResultCount = session.sizingResultCount
        sizingScope = session.scope
        sizingDisplay = session.display
        usesList = preferredLayout.map { $0 == .list } ?? false
        panel.isMovableByWindowBackground = false
        dragBar.isHidden = !session.isPersistent
        if session.isPersistent { panel.styleMask.insert(.resizable) }
        else { panel.styleMask.remove(.resizable) }
        searchHeldModifiers = []
        previewButton.state = showsPreview ? .on : .off
        search.stringValue = session.query
        clearSearchButton.isHidden = session.query.isEmpty
        searchSurface.isFocused = false
        configureSearchPresentation(inline: true)
        if configuredMode == .searchSelect { expandInlineSearch(animated: false) }
        actionDiagnostic = nil
        previewedEntry = nil; previewedPermission = nil
        render()
        layoutPanel()
        render(forceRevealSelection: true)
        chooserFocus.prepare()
        dismissalMonitor.start(
            for: panel,
            isSuspended: { [weak self] in
                guard let self else { return true }
                return closing || isAcquiringChooserFocus || isPresentingMenu
            },
            onDismiss: { [weak self] in
                self?.chooserFocus.release(restoring: false)
                self?.onCancel?()
            }
        )
        PluginPanelPresentation.present(panel)
        startPinchEventDiagnostics()
        if WindowSwitcherPinchDiagnostics.isEnabled {
            let pointer = NSEvent.mouseLocation
            WindowSwitcherPinchDiagnostics.record("show panel key=\(panel.isKeyWindow) active=\(NSApp.isActive) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) top=\(NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0)) chooser=\(panel.windowNumber) nonactivating=\(panel.styleMask.contains(.nonactivatingPanel)) persistent=\(session.isPersistent) directKeys=\(session.usesDirectKeys)")
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        acceptsSearchFocus = true
        if session.isPersistent && !session.usesDirectKeys {
            panel.makeFirstResponder(search)
        } else {
            panel.makeFirstResponder(usesList ? table : cards)
        }
        previewImage.focusIfPointerInside()
        noteCyclingInput()
    }

    func update(_ value: WindowSwitcherSession) {
        session = value
        render()
    }

    func hide(restoringFocus: Bool = true) {
        WindowSwitcherPinchDiagnostics.record("hide panel key=\(panel.isKeyWindow) active=\(NSApp.isActive)")
        stopPinchEventDiagnostics()
        dismissalMonitor.stop()
        acceptsSearchFocus = false
        menuGeneration += 1
        isPresentingMenu = false
        releasedDuringMenu = false
        searchTransitionTask?.cancel()
        showsSearchTransition = false
        recordingEntryID = nil
        closing = true
        panel.orderOut(nil)
        chooserFocus.release(restoring: restoringFocus)
        closing = false
        session = nil
        modeBeforeSearch = nil
        renderedSession = nil
        searchHeldModifiers = []
        previewedEntry = nil; previewedPermission = nil
        previewImage.clearTransition()
        previewImage.cancelPendingMagnification()
        preview.cancel()
        loadingTask?.cancel()
        snapCoordinator.cancelDragging()
    }

    private func startPinchEventDiagnostics() {
        guard WindowSwitcherPinchDiagnostics.isEnabled else { return }
        stopPinchEventDiagnostics()
        let gestureEvents: NSEvent.EventTypeMask = [.magnify, .scrollWheel, .gesture, .smartMagnify, .rotate]
        localPinchMonitor = NSEvent.addLocalMonitorForEvents(matching: gestureEvents) { [weak self] event in
            guard let self, self.isVisible else { return event }
            let mouseLocation = NSEvent.mouseLocation
            let point = self.previewImage.convert(
                self.panel.convertPoint(fromScreen: mouseLocation), from: nil)
            let insidePreview = self.previewImage.bounds.contains(point)
            if insidePreview || event.type == .magnify {
                let topWindow = NSWindow.windowNumber(at: mouseLocation, belowWindowWithWindowNumber: 0)
                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
                let change = event.type == .magnify ? event.magnification :
                    event.type == .scrollWheel ? event.scrollingDeltaY : 0
                WindowSwitcherPinchDiagnostics.record(
                    "local event=\(event.type.rawValue) phase=\(event.phase.rawValue) delta=\(change) window=\(event.windowNumber) chooser=\(self.panel.windowNumber) top=\(topWindow) previewPointer=\(insidePreview) key=\(self.panel.isKeyWindow) active=\(NSApp.isActive) frontmost=\(frontmostPID)")
            }
            return event
        }
        globalPinchMonitor = NSEvent.addGlobalMonitorForEvents(matching: gestureEvents) { [weak self] event in
            let eventType = event.type.rawValue
            let phase = event.phase.rawValue
            let windowNumber = event.windowNumber
            let change = event.type == .magnify ? event.magnification :
                event.type == .scrollWheel ? event.scrollingDeltaY : 0
            Task { @MainActor [weak self] in
                guard let self, self.isVisible else { return }
                let mouseLocation = NSEvent.mouseLocation
                let point = self.previewImage.convert(
                    self.panel.convertPoint(fromScreen: mouseLocation), from: nil)
                guard self.previewImage.bounds.contains(point) || eventType == NSEvent.EventType.magnify.rawValue else { return }
                let topWindow = NSWindow.windowNumber(at: mouseLocation, belowWindowWithWindowNumber: 0)
                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
                WindowSwitcherPinchDiagnostics.record(
                    "global event=\(eventType) phase=\(phase) delta=\(change) window=\(windowNumber) chooser=\(self.panel.windowNumber) top=\(topWindow) previewPointer=\(self.previewImage.bounds.contains(point)) key=\(self.panel.isKeyWindow) active=\(NSApp.isActive) frontmost=\(frontmostPID)")
            }
        }
        WindowSwitcherPinchDiagnostics.record("gesture monitors local=\(localPinchMonitor != nil) global=\(globalPinchMonitor != nil)")
    }

    private func stopPinchEventDiagnostics() {
        if let localPinchMonitor { NSEvent.removeMonitor(localPinchMonitor) }
        if let globalPinchMonitor { NSEvent.removeMonitor(globalPinchMonitor) }
        localPinchMonitor = nil
        globalPinchMonitor = nil
    }

    func showMessage(_ diagnostic: WindowSwitcherDiagnostic) {
        actionDiagnostic = diagnostic
        updateModeIndicator()
        updateShortcutBadges()
        footer.stringValue = "⚠︎ " + diagnostic.message(using: localization)
        footer.isHidden = recordingEntryID != nil
    }

    private var shortcutRecordingHelp: String {
        localization.string("chooser.recordAssignedHelp", defaultValue: "使用字母或数字，可组合 ⌘。按 ⌫ 恢复自动分配，Esc 取消。")
    }

    @objc private func cancelShortcutRecording() {
        recordingEntryID = nil; actionDiagnostic = nil; render()
        panel.makeFirstResponder(usesList ? table : cards)
    }

    private func layoutPanel(preservePosition: Bool = false, resizeToContent: Bool = false) {
        applyingPanelLayout = true
        defer { applyingPanelLayout = false }
        let currentScreen = panel.screen ?? NSScreen.screens.max {
            ($0.frame.intersection(panel.frame).width * $0.frame.intersection(panel.frame).height)
                < ($1.frame.intersection(panel.frame).width * $1.frame.intersection(panel.frame).height)
        }
        guard let screen = (preservePosition ? currentScreen : nil)
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let usePreview = showsPreview && screen.visibleFrame.height >= 600
        let previewVisibilityChanged = previewPane.isHidden == usePreview
        previewPane.isHidden = !usePreview
        previewDivider.isHidden = !usePreview
        panel.contentMinSize = NSSize(width: min(560, max(0, screen.visibleFrame.width - 24)),
                                      height: min(usePreview ? 420 : 260, max(0, screen.visibleFrame.height - 24)))
        var frame = WindowSwitcherSession.panelFrame(visibleFrame: screen.visibleFrame, preview: usePreview,
                                                     count: initialResultCount, layout: usesList ? .list : .grid)
        if session?.isPersistent == true, let preferredSize = preferredSizes[SizePreference(list: usesList, preview: usePreview)] {
            frame.size = NSSize(width: min(preferredSize.width, screen.visibleFrame.width - 24), height: min(preferredSize.height, screen.visibleFrame.height - 24))
            frame.origin = CGPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.midY - frame.height / 2)
        }
        if !preservePosition, session?.isPersistent == true,
           let placement = preferredPositions[SizePreference(list: usesList, preview: usePreview)],
           placement.displayID == screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            frame.origin = CGPoint(
                x: min(max(placement.origin.x, screen.visibleFrame.minX + 12), screen.visibleFrame.maxX - frame.width - 12),
                y: min(max(placement.origin.y, screen.visibleFrame.minY + 12), screen.visibleFrame.maxY - frame.height - 12))
        }
        if preservePosition {
            if !resizeToContent && !previewVisibilityChanged {
                frame.size = NSSize(width: min(panel.frame.width, screen.visibleFrame.width - 24),
                                    height: min(panel.frame.height, screen.visibleFrame.height - 24))
            }
            // Keep the search bar at the same height while the preview expands
            // below it. Clamp the result when a display edge limits that space.
            frame.origin = CGPoint(x: min(max(panel.frame.midX - frame.width / 2, screen.visibleFrame.minX + 12), screen.visibleFrame.maxX - frame.width - 12),
                                   y: min(max(panel.frame.maxY - frame.height, screen.visibleFrame.minY + 12), screen.visibleFrame.maxY - frame.height - 12))
        }
        if !usePreview {
            previewImage.clearTransition()
            preview.cancel(); previewedEntry = nil; previewedPermission = nil
        }
        panel.setFrame(frame, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        updateViewportLayout()
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func updateViewportLayout() {
        guard !updatingViewport else { return }
        updatingViewport = true
        defer { updatingViewport = false }
        cardScroll.tile()
        if let flow = cards.collectionViewLayout as? NSCollectionViewFlowLayout {
            let width = max(1, cardScroll.contentSize.width - flow.sectionInset.left - flow.sectionInset.right)
            cardColumns = max(1, Int((width + flow.minimumInteritemSpacing) / 132))
            let size = NSSize(width: max(1, floor((width - CGFloat(cardColumns - 1) * flow.minimumInteritemSpacing) / CGFloat(cardColumns))), height: 88)
            if flow.itemSize != size { flow.itemSize = size; flow.invalidateLayout() }
        }
        let naturalRows = min(2, max(1, (initialResultCount + cardColumns - 1) / cardColumns))
        // The preview takes the remaining space. At small sizes, only one card
        // row remains visible; the collection scrolls without enlarging the panel.
        let availableForCards = max(110, panel.frame.height * 0.34)
        cardHeight.constant = min(CGFloat(naturalRows) * 96 + 8, availableForCards)
        cardHeight.isActive = !previewPane.isHidden && !usesList
        listHeight.constant = min(CGFloat(min(4, max(1, initialResultCount))) * 56, availableForCards)
        listHeight.isActive = !previewPane.isHidden && usesList
        previewHeight.constant = max(100, panel.frame.height * 0.44)
    }

    private func buildPanel() {
        panel.identifier = NSUserInterfaceItemIdentifier("WindowSwitcherChooser")
        panel.searchShortcutHandler = { [weak self] event in self?.handleSearchShortcut(event) ?? false }
        panel.searchEventFilter = { [weak self] event in self?.filterSearchEvent(event) ?? event }
        panel.searchTransitionHandler = { [weak self] event in
            guard let self, let session, !session.isPersistent,
                  !session.invocationModifiers.intersection(event.modifierFlags).isEmpty,
                  let text = event.charactersIgnoringModifiers, !text.isEmpty,
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
            return handleKey(event)
        }
        panel.shortcutHandler = { [weak self] event in self?.handleChooserShortcut(event) ?? false }
        panel.level = .popUpMenu
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        PluginPanelPresentation.configure(panel)
        panel.delegate = self
        let effect = WindowSwitcherPaletteSurface()
        panel.contentView = effect
        snapCoordinator.attach(to: panel)
        dragHandle.onDragBegan = { [weak self] in self?.snapCoordinator.startDragging() }
        dragHandle.toolTip = localization.string("chooser.dragHandle", defaultValue: "拖移以移动")
        dragHandle.setAccessibilityLabel(dragHandle.toolTip)
        dragHandle.setAccessibilityIdentifier("mactools.window-switcher.drag-handle")
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        dragBar.addSubview(dragHandle)
        let title = NSTextField(labelWithString: localization.string("chooser.title", defaultValue: "窗口切换"))
        title.font = PluginTypography.pageTitle.nsFont
        search.placeholderString = localization.string("chooser.search", defaultValue: "搜索窗口标题或应用")
        search.onFocus = { [weak self] in
            guard let self, self.acceptsSearchFocus, !self.updating else { return }
            if self.session?.isPersistent == false {
                self.searchHeldModifiers = (self.session?.invocationModifiers ?? []).intersection(NSEvent.modifierFlags)
            }
            self.searchSurface.isFocused = true
            self.onSearchEditingChange?(true)
        }
        search.delegate = self
        search.identifier = NSUserInterfaceItemIdentifier("window-switcher-search")
        search.setAccessibilitySubrole(.searchField)
        search.setAccessibilityLabel(localization.string("chooser.search", defaultValue: "搜索窗口标题或应用"))
        search.font = PluginTypography.body.nsFont
        search.controlSize = .regular
        search.cell?.usesSingleLineMode = true
        search.cell?.isScrollable = true
        search.isBordered = false; search.isBezeled = false; search.drawsBackground = false; search.focusRingType = .none
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.setAccessibilityElement(false)
        searchLeading = search.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor,
            constant: PluginPaletteMetrics.searchHorizontalPadding + 26)
        clearSearchButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        clearSearchButton.contentTintColor = .secondaryLabelColor
        clearSearchButton.target = self; clearSearchButton.action = #selector(clearSearch)
        clearSearchButton.identifier = NSUserInterfaceItemIdentifier("window-switcher-clear-search")
        clearSearchButton.setAccessibilityLabel(localization.string("chooser.clearSearch", defaultValue: "清除搜索"))
        clearSearchButton.toolTip = localization.string("chooser.clearSearch", defaultValue: "清除搜索")
        for view in [searchIcon, search, clearSearchButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            searchSurface.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor, constant: PluginPaletteMetrics.searchHorizontalPadding),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),
            searchIcon.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            searchLeading,
            search.trailingAnchor.constraint(equalTo: clearSearchButton.leadingAnchor, constant: -8),
            search.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            clearSearchButton.trailingAnchor.constraint(equalTo: searchSurface.trailingAnchor, constant: -8),
            clearSearchButton.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            clearSearchButton.widthAnchor.constraint(equalToConstant: 24),
            clearSearchButton.heightAnchor.constraint(equalToConstant: 24)
        ])
        scope.identifier = NSUserInterfaceItemIdentifier("window-switcher-scope")
        scope.target = self; scope.action = #selector(scopeChanged)
        scope.selectedSegment = 0
        display.target = self; display.action = #selector(displayChanged)
        display.setAccessibilityLabel(localization.string("chooser.displayFilter", defaultValue: "显示器筛选"))
        count.font = PluginTypography.detail.nsFont; count.textColor = .secondaryLabelColor
        previewButton.target = self; previewButton.action = #selector(previewChanged)
        more.identifier = NSUserInterfaceItemIdentifier("window-switcher-options")
        more.controlSize = .small
        more.target = self; more.action = #selector(showOptions)
        more.contentTintColor = .secondaryLabelColor
        more.imagePosition = .imageOnly
        more.setAccessibilityLabel(localization.string("chooser.more", defaultValue: "更多选项"))
        searchHeader.addArrangedSubview(searchSurface)
        searchHeader.orientation = .horizontal; searchHeader.alignment = .centerY
        layoutPicker.target = self; layoutPicker.action = #selector(layoutChanged)
        layoutPicker.identifier = NSUserInterfaceItemIdentifier("window-switcher-layout")
        layoutPicker.controlSize = .small
        let toolbarSymbols = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        layoutPicker.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)?
            .withSymbolConfiguration(toolbarSymbols), forSegment: 0)
        layoutPicker.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)?
            .withSymbolConfiguration(toolbarSymbols), forSegment: 1)
        let filters = NSStackView(views: [scope, display, NSView(), count, inlineSearch, enterSearchButton, more, layoutPicker])
        filters.orientation = .horizontal; filters.alignment = .centerY
        filters.spacing = 8
        filters.heightAnchor.constraint(equalToConstant: 32).isActive = true
        scope.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scope.setContentHuggingPriority(.required, for: .horizontal)
        let scroll = listScroll
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window")))
        table.headerView = nil; table.rowHeight = 54; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear; table.selectionHighlightStyle = .regular
        table.dataSource = self; table.delegate = self
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel(localization.string("chooser.list", defaultValue: "窗口列表"))
        table.contextMenuForRow = { [weak self] row in self?.contextMenu(forRow: row) }
        table.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        scroll.documentView = table
        cardScroll.hasVerticalScroller = true; cardScroll.autohidesScrollers = true; cardScroll.drawsBackground = false
        let flow = NSCollectionViewFlowLayout()
        flow.itemSize = NSSize(width: 132, height: 88)
        flow.minimumInteritemSpacing = 8; flow.minimumLineSpacing = 8
        flow.sectionInset = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        cards.collectionViewLayout = flow
        cards.register(WindowSwitcherCardItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("window-card"))
        cards.isSelectable = true; cards.allowsMultipleSelection = false
        cards.backgroundColors = [.clear]
        cards.dataSource = self; cards.delegate = self
        cards.contextMenuForItem = { [weak self] path in self?.contextMenu(forRow: path.item) }
        cards.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        cardScroll.documentView = cards
        previewLabel.identifier = NSUserInterfaceItemIdentifier("window-preview-status")
        previewLabel.font = PluginTypography.detail.nsFont; previewLabel.textColor = .labelColor
        previewPane.orientation = .vertical; previewPane.alignment = .leading
        previewPane.distribution = .fill
        previewPane.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        previewPane.spacing = 8; previewPane.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        previewTitle.font = PluginTypography.body.nsFont
        previewTitle.lineBreakMode = .byTruncatingMiddle
        previewTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewLabel.alignment = .center
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewImage.addSubview(previewLabel)
        previewPane.addArrangedSubview(previewTitle); previewPane.addArrangedSubview(previewImage)
        previewDivider.boxType = .separator
        previewDivider.identifier = NSUserInterfaceItemIdentifier("window-preview-divider")
        let body = NSStackView(views: [cardScroll, scroll, previewDivider, previewPane])
        body.orientation = .vertical; body.distribution = .fill; body.spacing = 12; body.alignment = .leading
        previewHeight = previewImage.heightAnchor.constraint(equalToConstant: 360)
        previewHeight.priority = NSLayoutConstraint.Priority(1)
        cardHeight = cardScroll.heightAnchor.constraint(equalToConstant: 224)
        // A preferred row count must not become AppKit's live-resize minimum.
        cardHeight.priority = NSLayoutConstraint.Priority(49)
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 224)
        listHeight.priority = NSLayoutConstraint.Priority(49)
        previewImage.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        empty.font = PluginTypography.detail.nsFont; empty.textColor = .labelColor
        openButton.target = self; openButton.action = #selector(openSelected); openButton.bezelStyle = .rounded
        closeButton.target = self; closeButton.action = #selector(closeSelected); closeButton.bezelStyle = .rounded
        quitButton.target = self; quitButton.action = #selector(quitSelected); quitButton.bezelStyle = .rounded
        footer.font = PluginTypography.detail.nsFont; footer.textColor = .labelColor
        footer.lineBreakMode = .byWordWrapping
        footer.maximumNumberOfLines = 0
        let actions = NSStackView(views: [openButton, closeButton, quitButton, NSView()])
        actions.orientation = .horizontal
        modeButton.font = PluginTypography.sectionTitle.nsFont
        modeButton.identifier = NSUserInterfaceItemIdentifier("window-switcher-mode")
        modeButton.bezelStyle = .inline
        modeButton.isBordered = true
        modeButton.showsBorderOnlyWhileMouseInside = true
        modeButton.imagePosition = .imageLeading
        modeButton.target = self; modeButton.action = #selector(cycleMode)
        modeHint.font = PluginTypography.detail.nsFont
        modeHint.textColor = .labelColor
        modeHint.identifier = NSUserInterfaceItemIdentifier("window-switcher-mode-hint")
        modeHint.lineBreakMode = .byTruncatingTail
        modeHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modeButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        enterSearchButton.controlSize = .small
        enterSearchButton.imagePosition = .imageOnly
        enterSearchButton.contentTintColor = .secondaryLabelColor
        enterSearchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        enterSearchButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        more.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        enterSearchButton.target = self; enterSearchButton.action = #selector(toggleInlineSearch)
        enterSearchButton.identifier = NSUserInterfaceItemIdentifier("window-switcher-enter-search")
        inlineSearch.wantsLayer = true
        inlineSearch.layer?.masksToBounds = true
        inlineSearchWidth = inlineSearch.widthAnchor.constraint(equalToConstant: 0)
        inlineSearchWidth.priority = NSLayoutConstraint.Priority(500)
        inlineSearchMinimumWidth = inlineSearch.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        inlineSearchMinimumWidth.priority = .defaultHigh
        minimumScopeWidth = scope.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        minimumScopeWidth.priority = .defaultHigh
        let minimumDisplayWidth = display.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        minimumDisplayWidth.priority = .defaultHigh
        let modeRow = NSStackView(views: [modeButton, modeHint, NSView(), recordingCancel])
        modeRow.orientation = .horizontal; modeRow.alignment = .centerY; modeRow.spacing = 8
        modeRow.heightAnchor.constraint(equalToConstant: 32).isActive = true
        recordingCancel.target = self; recordingCancel.action = #selector(cancelShortcutRecording)
        recordingCancel.bezelStyle = .rounded; recordingCancel.controlSize = .small
        recordingCancel.identifier = NSUserInterfaceItemIdentifier("window-shortcut-recording-cancel")
        recordingCancel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [searchHeader, filters, modeRow, body, empty, footer])
        stack.orientation = .vertical; stack.distribution = .fill; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.contentContainer.addSubview(stack)
        dragBar.translatesAutoresizingMaskIntoConstraints = false
        effect.contentContainer.addSubview(dragBar)
        searchSurfaceHeight = searchSurface.heightAnchor.constraint(equalToConstant: PluginPaletteMetrics.toolbarControlSize.height)
        NSLayoutConstraint.activate([
            dragBar.topAnchor.constraint(equalTo: effect.topAnchor),
            dragBar.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            dragBar.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            dragBar.heightAnchor.constraint(equalToConstant: 15),
            searchSurfaceHeight,
            inlineSearchWidth,
            inlineSearchMinimumWidth,
            minimumScopeWidth,
            minimumDisplayWidth,
            inlineSearch.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            inlineSearch.heightAnchor.constraint(equalToConstant: 32),
            enterSearchButton.widthAnchor.constraint(equalToConstant: 28),
            enterSearchButton.heightAnchor.constraint(equalToConstant: 28),
            dragHandle.widthAnchor.constraint(equalToConstant: 72),
            dragHandle.heightAnchor.constraint(equalToConstant: 15),
            dragHandle.centerXAnchor.constraint(equalTo: dragBar.centerXAnchor),
            dragHandle.centerYAnchor.constraint(equalTo: dragBar.centerYAnchor),
            more.widthAnchor.constraint(equalToConstant: 28),
            more.heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14),
            previewPane.widthAnchor.constraint(equalTo: body.widthAnchor),
            previewDivider.widthAnchor.constraint(equalTo: body.widthAnchor),
            previewDivider.heightAnchor.constraint(equalToConstant: 1),
            previewHeight,
            previewImage.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            cardScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            previewImage.widthAnchor.constraint(equalTo: previewPane.widthAnchor),
            previewTitle.widthAnchor.constraint(equalTo: previewPane.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: previewImage.widthAnchor, constant: -32),
            previewLabel.centerXAnchor.constraint(equalTo: previewImage.centerXAnchor),
            previewLabel.centerYAnchor.constraint(equalTo: previewImage.centerYAnchor),
            scroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            cardScroll.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
        for view in [searchHeader, filters, modeRow, body, empty, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        cardScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        display.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        panel.autorecalculatesKeyViewLoop = true
        for clip in [cardScroll.contentView, listScroll.contentView] {
            clip.postsBoundsChangedNotifications = true
            scrollObservers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: clip, queue: .main) { [weak self, weak clip] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.updateViewportLayout()
                        guard let clip,
                              clip === (self.usesList ? self.listScroll : self.cardScroll).contentView else { return }
                        self.updateShortcutBadges()
                    }
                })
        }
    }

    private func configureSearchPresentation(inline: Bool) {
        usesInlineSearch = inline
        isInlineSearchExpanded = false
        modeBeforeSearch = nil
        searchSurface.removeFromSuperview()
        searchHeader.isHidden = inline
        inlineSearch.isHidden = !inline
        enterSearchButton.isHidden = !inline
        searchIcon.isHidden = inline
        search.font = PluginTypography.body.nsFont
        searchLeading.constant = inline ? 10 : PluginPaletteMetrics.searchHorizontalPadding + 26
        searchSurfaceHeight.constant = inline ? 32 : PluginPaletteMetrics.toolbarControlSize.height
        searchSurface.isHidden = inline
        inlineSearchWidth.constant = 0
        inlineSearchMinimumWidth.constant = 0
        if inline {
            inlineSearch.addSubview(searchSurface)
            searchSurface.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                searchSurface.leadingAnchor.constraint(equalTo: inlineSearch.leadingAnchor),
                searchSurface.trailingAnchor.constraint(equalTo: inlineSearch.trailingAnchor),
                searchSurface.centerYAnchor.constraint(equalTo: inlineSearch.centerYAnchor)
            ])
        } else {
            searchHeader.addArrangedSubview(searchSurface)
        }
    }

    private func expandInlineSearch(animated: Bool = true) {
        guard usesInlineSearch, !isInlineSearchExpanded else { return }
        isInlineSearchExpanded = true
        panel.contentView?.layoutSubtreeIfNeeded()
        searchSurface.isHidden = false
        inlineSearchMinimumWidth.constant = 150
        if !animated {
            inlineSearchWidth.constant = 240
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            context.allowsImplicitAnimation = true
            inlineSearchWidth.constant = 240
            panel.contentView?.layoutSubtreeIfNeeded()
        }
    }

    @objc private func toggleInlineSearch() {
        guard usesInlineSearch, isInlineSearchExpanded else { enterSearch(); return }
        // End composition before clearing the query so the field editor cannot
        // publish a final text update and reopen the collapsed field.
        panel.makeFirstResponder(usesList ? table : cards)
        isInlineSearchExpanded = false
        searchSurface.isHidden = true
        search.stringValue = ""
        clearSearchButton.isHidden = true
        searchHeldModifiers = []
        searchTransitionTask?.cancel()
        showsSearchTransition = false
        inlineSearchMinimumWidth.constant = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            context.allowsImplicitAnimation = true
            inlineSearchWidth.constant = 0
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        guard var session else { return }
        session.query = ""
        if let modeBeforeSearch {
            session.isPersistent = modeBeforeSearch.isPersistent
            session.usesDirectKeys = modeBeforeSearch.usesDirectKeys
        }
        modeBeforeSearch = nil
        activeMode = configuredMode
        previewImage.prefersGestureFocus = configuredMode == .directCycle
        session.normalizeSelection()
        self.session = session
        actionDiagnostic = nil
        onSessionChange?(session)
        render()
    }

    private func updateSearchButton() {
        let expanded = usesInlineSearch && isInlineSearchExpanded
        enterSearchButton.image = NSImage(systemSymbolName: expanded ? "xmark" : "magnifyingglass", accessibilityDescription: nil)
        let label = expanded ? localization.string("chooser.closeSearch", defaultValue: "关闭搜索")
            : localization.string("chooser.search", defaultValue: "搜索窗口标题或应用")
        enterSearchButton.toolTip = expanded ? label : search.toolTip
        enterSearchButton.setAccessibilityLabel(label)
    }

    private func localizeControls() {
        panel.title = localization.string("chooser.title", defaultValue: "窗口切换")
        panel.setAccessibilityLabel(panel.title)
        dragHandle.toolTip = localization.string("chooser.dragHandle", defaultValue: "拖移以移动")
        dragHandle.setAccessibilityLabel(dragHandle.toolTip)
        search.placeholderString = localization.string("chooser.search", defaultValue: "搜索窗口标题或应用")
        search.setAccessibilityLabel(search.placeholderString)
        clearSearchButton.toolTip = localization.string("chooser.clearSearch", defaultValue: "清除搜索")
        clearSearchButton.setAccessibilityLabel(clearSearchButton.toolTip)
        display.setAccessibilityLabel(localization.string("chooser.displayFilter", defaultValue: "显示器筛选"))
        more.setAccessibilityLabel(localization.string("chooser.more", defaultValue: "更多选项"))
        table.setAccessibilityLabel(localization.string("chooser.list", defaultValue: "窗口列表"))
        layoutPicker.setToolTip(localization.string("chooser.cards", defaultValue: "卡片视图") + " · ⌘⌥1", forSegment: 0)
        layoutPicker.setToolTip(localization.string("chooser.list", defaultValue: "窗口列表") + " · ⌘⌥2", forSegment: 1)
        layoutPicker.setAccessibilityLabel(localization.string("chooser.layout", defaultValue: "窗口视图"))
        cards.setAccessibilityLabel(localization.string("chooser.cards", defaultValue: "卡片视图"))
        // Keep an active filter visible even if its last sibling window closes.
        // Otherwise there is no useful app scope to offer for a single window.
        let showsAppScope = session.map { $0.scope != .all || $0.canSwitchCurrentApplication($0.scopeTargetPID) } ?? false
        let segmentCount = showsAppScope ? 2 : 1
        if scope.segmentCount != segmentCount { scope.segmentCount = segmentCount }
        scope.setLabel(localization.string("chooser.all", defaultValue: "全部窗口"), forSegment: 0)
        minimumScopeWidth.constant = scope.minimumContentWidth
        let scopeApp = session?.entries.first { $0.processIdentifier == session?.scopeTargetPID }?.appName
        if showsAppScope {
            scope.setLabel(scopeApp.map { localization.format("chooser.appWindows", defaultValue: "%@ 的窗口", $0) }
                ?? localization.string("chooser.current", defaultValue: "当前应用"), forSegment: 1)
            scope.setEnabled(true, forSegment: 1)
        }
        closeButton.title = localization.string("chooser.close", defaultValue: "关闭窗口")
        quitButton.title = localization.string("chooser.quit", defaultValue: "退出应用")
        openButton.title = localization.string("chooser.open", defaultValue: "打开窗口")
        previewButton.title = localization.string("chooser.preview", defaultValue: "预览")
        more.menu = NSMenu()
        more.menu?.delegate = self
        more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        for (label, action) in [(localization.string("chooser.preview", defaultValue: "预览"), #selector(togglePreviewFromMenu)),
                                (localization.string("chooser.close", defaultValue: "关闭窗口"), #selector(contextClose(_:))),
                                (localization.string("chooser.quit", defaultValue: "退出应用"), #selector(contextQuit(_:)))] {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = session?.selected
            item.keyEquivalent = action == #selector(togglePreviewFromMenu) ? "p" : action == #selector(contextClose(_:)) ? "w" : "q"
            if session?.usesDirectKeys == true || session?.protectedCommandKeys.contains(item.keyEquivalent) == true {
                item.keyEquivalent = ""
            }
            item.keyEquivalentModifierMask = .command
            if action == #selector(togglePreviewFromMenu) { item.state = showsPreview ? .on : .off }
            if action == #selector(contextClose(_:)) { item.isEnabled = session?.selected?.isWindowEntry == true }
            if action == #selector(contextQuit(_:)) {
                more.menu?.addItem(.separator())
                if let entry = session?.selected {
                    item.title = localization.format("chooser.quitApp", defaultValue: "退出 %@", entry.appName)
                }
                item.isEnabled = session?.selected != nil
            }
            if action == #selector(contextClose(_:)) { item.isEnabled = session?.selected.map(canClose) ?? false }
            more.menu?.addItem(item)
        }
        if session?.usesDirectKeys == true {
            let edit = NSMenuItem(title: localization.string("chooser.editAssigned", defaultValue: "修改所选快捷键…"), action: #selector(editSelectedShortcut), keyEquivalent: "")
            edit.target = self
            more.menu?.addItem(edit)
        }
        more.menu?.addItem(.separator())
        let resetSize = NSMenuItem(title: localization.string("chooser.resetSize", defaultValue: "重置大小"),
                                   action: #selector(resetPanelSize), keyEquivalent: "")
        resetSize.target = self
        more.menu?.addItem(resetSize)
        let zoom = NSMenuItem(title: localization.string("preview.zoom", defaultValue: "预览缩放"), action: nil, keyEquivalent: "")
        zoom.submenu = previewZoomMenu()
        more.menu?.addItem(zoom)
        previewImage.setAccessibilityLabel(localization.string("chooser.preview", defaultValue: "预览"))
        previewImage.toolTip = localization.string("preview.zoomHelp", defaultValue: "在预览上双指缩放。放大后拖移或用方向键平移，双击恢复适合窗口。")
        previewImage.setAccessibilityHelp(previewImage.toolTip)
        let shortcuts = NSMenuItem(title: localization.string("chooser.shortcuts", defaultValue: "键盘快捷键"), action: nil, keyEquivalent: "")
        let help = NSMenu()
        for (key, fallback, chord) in [
            ("chooser.quickSelect", "打开可见窗口", "⌘1–9"),
            ("chooser.cards", "卡片视图", "⌘⌥1"), ("chooser.list", "窗口列表", "⌘⌥2"),
            ("chooser.all", "全部窗口", "⌘⇧1"), ("chooser.current", "当前应用", "⌘⇧2"),
            ("chooser.search", "搜索", "⌘F"), ("chooser.preview", "预览", "⌘P"),
            ("chooser.displayFilter", "显示器筛选", "⌘D"), ("chooser.more", "更多选项", "⌘K"),
            ("chooser.open", "打开窗口", "Return"), ("chooser.cancel", "取消", "Esc"),
            ("chooser.close", "关闭窗口", "⌘W"), ("chooser.quit", "退出应用", "⌘Q"),
            ("chooser.contextActions", "窗口操作", "⇧F10"),
            (session?.usesDirectKeys == true ? "chooser.selectWindow" : "chooser.focusNext",
             session?.usesDirectKeys == true ? "选择窗口" : "下一个控件", "Tab / ⇧Tab")
        ] {
            if session?.usesDirectKeys == true && chord.hasPrefix("⌘") && chord != "⌘F" { continue }
            if ["⌘W", "⌘Q"].contains(chord), session?.protectedCommandKeys.contains(chord == "⌘W" ? "w" : "q") == true { continue }
            let item = NSMenuItem(title: localization.string(key, defaultValue: fallback) + "   " + chord, action: nil, keyEquivalent: "")
            item.isEnabled = false
            help.addItem(item)
        }
        shortcuts.submenu = help
        more.menu?.addItem(shortcuts)
        more.menu?.addItem(.separator())
        let dismiss = NSMenuItem(title: localization.string("chooser.dismiss", defaultValue: "关闭窗口切换器"),
                                 action: #selector(cancelSelection), keyEquivalent: "\u{1b}")
        dismiss.keyEquivalentModifierMask = []
        dismiss.identifier = NSUserInterfaceItemIdentifier("window-switcher-dismiss")
        dismiss.target = self
        more.menu?.addItem(dismiss)
        more.toolTip = localization.string("chooser.more", defaultValue: "更多选项") + (session?.usesDirectKeys == true ? "" : " · ⌘K")
        more.menu?.autoenablesItems = false
        scope.setToolTip("\(scope.label(forSegment: 0) ?? "") · ⌘⇧1", forSegment: 0)
        if showsAppScope { scope.setToolTip("\(scope.label(forSegment: 1) ?? "") · ⌘⇧2", forSegment: 1) }
        display.toolTip = "\(localization.string("chooser.displayFilter", defaultValue: "显示器筛选")) · ⌘D"
        previewButton.title += " ⌘P"
        search.toolTip = localization.string("chooser.search", defaultValue: "搜索窗口标题或应用") + " · ⌘F"
        updateSearchButton()
        if session?.usesDirectKeys == true {
            scope.setToolTip(scope.label(forSegment: 0), forSegment: 0)
            if showsAppScope { scope.setToolTip(scope.label(forSegment: 1), forSegment: 1) }
            layoutPicker.setToolTip(localization.string("chooser.cards", defaultValue: "卡片视图"), forSegment: 0)
            layoutPicker.setToolTip(localization.string("chooser.list", defaultValue: "窗口列表"), forSegment: 1)
            display.toolTip = localization.string("chooser.displayFilter", defaultValue: "显示器筛选")
        }
    }

    private func refreshLocalization() {
        guard !isPresentingMenu else {
            needsLocalizationRefresh = true
            return
        }
        needsLocalizationRefresh = false
        let direction: NSUserInterfaceLayoutDirection =
            PluginRuntimeLocalization.locale.language.characterDirection == .rightToLeft
                ? .rightToLeft : .leftToRight
        if search.userInterfaceLayoutDirection != direction {
            search.userInterfaceLayoutDirection = direction
            search.cell?.userInterfaceLayoutDirection = direction
        }
        search.alignment = .natural
        if !previewLabel.isHidden {
            // Update retained feedback without touching the image, zoom, or active capture.
            previewLabel.stringValue = preview.statusMessage
                ?? localization.string("preview.loading", defaultValue: "正在加载预览…")
        }
        if session == nil {
            localizeControls()
        } else {
            // An unchanged session does not reload cells or reveal a different window.
            render()
            refreshVisibleEntryLabels()
        }
    }

    private func refreshVisibleEntryLabels() {
        if usesList {
            for row in 0..<min(rows.count, table.numberOfRows) {
                guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSStackView,
                      let labels = cell.arrangedSubviews.compactMap({ $0 as? NSStackView }).first,
                      let title = labels.arrangedSubviews.first as? NSTextField,
                      let subtitle = labels.arrangedSubviews.last as? NSTextField else { continue }
                configureListLabels(title: title, subtitle: subtitle, entry: rows[row])
            }
        } else {
            for item in cards.visibleItems() {
                guard let card = item as? WindowSwitcherCardItem,
                      let path = cards.indexPath(for: item), rows.indices.contains(path.item) else { continue }
                let entry = rows[path.item]
                card.configure(
                    icon: entry.icon,
                    title: highlighted(Self.gridTitle(entry.localizedGridTitle(using: localization),
                        appName: entry.appName, query: session?.query ?? ""), query: session?.query ?? ""),
                    appName: entry.appName
                )
            }
        }
    }

    private func render(forceRevealSelection: Bool = false) {
        guard var session else { return }
        if let recordingEntryID, !session.entries.contains(where: { $0.id == recordingEntryID }) || !session.usesDirectKeys {
            self.recordingEntryID = nil
            actionDiagnostic = nil
        }
        localizeControls()
        updateModeIndicator()
        session.normalizeSelection(); self.session = session
        dragBar.isHidden = !session.isPersistent
        if session.isPersistent, !panel.styleMask.contains(.resizable) { panel.styleMask.insert(.resizable) }
        else if !session.isPersistent, panel.styleMask.contains(.resizable) { panel.styleMask.remove(.resizable) }
        let revealSelection = forceRevealSelection || renderedSession == nil || renderedSession?.selectedID != session.selectedID
            || renderedSession?.query != session.query || renderedSession?.scope != session.scope
            || renderedSession?.display != session.display
        listScroll.isHidden = !usesList
        cardScroll.isHidden = usesList
        layoutPicker.selectedSegment = usesList ? 1 : 0
        if sizingScope != session.scope || sizingDisplay != session.display {
            sizingScope = session.scope
            sizingDisplay = session.display
            initialResultCount = session.sizingResultCount
            layoutPanel(preservePosition: true, resizeToContent: true)
        }
        let activeScroll = usesList ? listScroll : cardScroll
        let viewport = activeScroll.contentView.bounds.origin
        updating = true
        let needsReload = renderedSession == nil || rows != session.results
            || renderedSession?.query != session.query || renderedSession?.usesDirectKeys != session.usesDirectKeys
        rows = session.results
        // Selection alone must not replace a button while AppKit tracks its click.
        if needsReload {
            if usesList { table.reloadData() }
            else { cards.reloadData(); cards.layoutSubtreeIfNeeded() }
        }
        if let index = rows.firstIndex(where: { $0.id == session.selectedID }) {
            if usesList { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            let path = IndexPath(item: index, section: 0)
            if !usesList { cards.selectionIndexPaths = [path] }
            if revealSelection { revealSelectedItem(at: index, path: path) }
        } else { table.deselectAll(nil); cards.selectionIndexPaths = [] }
        if !revealSelection {
            activeScroll.contentView.scroll(to: viewport)
            activeScroll.reflectScrolledClipView(activeScroll.contentView)
        }
        renderedSession = session
        count.isHidden = true
        display.isHidden = session.displays.count < 2 && session.display == nil
        count.stringValue = localization.format("chooser.count", defaultValue: "%d 个窗口", rows.count)
        scope.selectedSegment = session.scope == .all ? 0 : 1
        display.removeAllItems(); display.addItem(withTitle: localization.string("chooser.allDisplays", defaultValue: "所有显示器"))
        for screen in session.displays {
            display.addItem(withTitle: screen.name)
            display.lastItem?.representedObject = NSNumber(value: screen.id)
            if session.display == screen.id { display.select(display.lastItem) }
        }
        if let selectedDisplay = session.display, !session.displays.contains(where: { $0.id == selectedDisplay }) {
            // Keep the visible control honest if the selected display has lost
            // its last window or disconnected while this session is open.
            display.addItem(withTitle: localization.string("chooser.emptyDisplay", defaultValue: "所选显示器暂无窗口"))
            display.lastItem?.representedObject = NSNumber(value: selectedDisplay)
            display.select(display.lastItem)
        }
        let selected = session.selected
        previewTitle.stringValue = selected.map { entry in
            let title = entry.localizedDisplayName(using: localization)
            return title.caseInsensitiveCompare(entry.appName) == .orderedSame ? title : "\(entry.appName) · \(title)"
        } ?? ""
        closeButton.isEnabled = selected?.isWindowEntry == true && selected?.metadataUnavailable == false
        quitButton.isEnabled = selected != nil; openButton.isEnabled = selected != nil
        empty.stringValue = rows.isEmpty ? localization.string("chooser.empty", defaultValue: "没有匹配的窗口。窗口信息可能仍在更新。") : ""
        empty.isHidden = !rows.isEmpty
        footer.stringValue = actionMessage.map { "⚠︎ " + $0 } ?? ""
        footer.isHidden = actionMessage == nil || recordingEntryID != nil
        updating = false
        updateShortcutBadges()
        if showsPreview && !previewPane.isHidden, selected != previewedEntry || preview.isPermissionGranted != previewedPermission {
            WindowSwitcherPinchDiagnostics.record("selection preview changed window=\(selected?.isWindowEntry == true) image=\(previewImage.image != nil) outgoing=\(previewImage.hasOutgoingImage)")
            if selected?.id != previewedEntry?.id || selected?.processIdentifier != previewedEntry?.processIdentifier ||
                selected?.applicationLaunchDate != previewedEntry?.applicationLaunchDate || selected?.windowNumber != previewedEntry?.windowNumber {
                if selected?.isWindowEntry == true {
                    previewImage.retireImage()
                } else {
                    previewImage.clearTransition()
                    previewImage.cancelPendingMagnification()
                    previewImage.image = nil
                }
            }
            previewedEntry = selected
            previewedPermission = preview.isPermissionGranted
            preview.select(selected?.isWindowEntry == true ? selected : nil)
        }
    }

    /// Reveal after the final viewport geometry is known. AppKit's nearest-edge
    /// collection scroll can leave a card clipped when the panel shrinks, so the
    /// item's full rectangle is the authoritative reveal target.
    private func revealSelectedItem(at index: Int? = nil, path: IndexPath? = nil) {
        guard let selectedID = session?.selectedID,
              let index = index ?? rows.firstIndex(where: { $0.id == selectedID }) else { return }
        // Visibility and height constraints belong to ancestor stack views.
        // Resolve those before asking either document view to reveal an item.
        panel.contentView?.layoutSubtreeIfNeeded()
        if usesList {
            listScroll.layoutSubtreeIfNeeded()
            table.scrollRowToVisible(index)
            _ = table.scrollToVisible(table.rect(ofRow: index))
            return
        }
        let path = path ?? IndexPath(item: index, section: 0)
        cardScroll.layoutSubtreeIfNeeded()
        cards.layoutSubtreeIfNeeded()
        cards.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge.union(.nearestVerticalEdge))
        cards.layoutSubtreeIfNeeded()
        if let frame = cards.layoutAttributesForItem(at: path)?.frame {
            _ = cards.scrollToVisible(frame)
        }
    }

    @objc private func layoutChanged() {
        usesList = layoutPicker.selectedSegment == 1
        onLayoutChange?(usesList ? .list : .grid)
        renderedSession = nil
        listScroll.isHidden = !usesList
        cardScroll.isHidden = usesList
        cardHeight.isActive = !usesList && !previewPane.isHidden
        layoutPanel(preservePosition: true, resizeToContent: true)
        render(forceRevealSelection: true)
        panel.makeFirstResponder(usesList ? table : cards)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("window-card"), for: indexPath)
        if let item = item as? WindowSwitcherCardItem, rows.indices.contains(indexPath.item) {
            let entry = rows[indexPath.item]
            item.configure(icon: entry.icon, title: highlighted(Self.gridTitle(entry.localizedGridTitle(using: localization), appName: entry.appName, query: session?.query ?? ""), query: session?.query ?? ""),
                           appName: entry.appName)
            item.onOpen = { [weak self] in self?.onSelect?(entry) }
            item.assignedShortcut = session?.usesDirectKeys == true ? entry.shortcutDisplay : nil
            item.isRecordingShortcut = entry.id == recordingEntryID
            item.shortcutHelp = entry.id == recordingEntryID ? shortcutRecordingHelp
                : localization.string("chooser.changeKey", defaultValue: "修改快捷键…")
            item.onEditShortcut = { [weak self] in self?.beginShortcutRecording(entry.id) }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !updating, let index = indexPaths.first?.item, rows.indices.contains(index), var session else { return }
        session.selectedID = rows[index].id
        self.session = session; actionDiagnostic = nil
        onSessionChange?(session); render()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let icon = NSImageView(image: entry.icon ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let title = NSTextField(labelWithString: "")
        title.font = PluginTypography.body.nsFont; title.lineBreakMode = .byTruncatingMiddle
        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = PluginTypography.detail.nsFont; subtitle.textColor = .secondaryLabelColor; subtitle.lineBreakMode = .byTruncatingTail
        configureListLabels(title: title, subtitle: subtitle, entry: entry)
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        let badge = WindowSwitcherShortcutBadge(title: "", target: self, action: #selector(editListShortcut(_:)))
        badge.isBordered = session?.usesDirectKeys == true
        badge.bezelStyle = .texturedRounded
        badge.controlSize = .small
        badge.title = session?.usesDirectKeys == true ? (entry.shortcutDisplay ?? "") : ""
        badge.tag = row
        badge.identifier = NSUserInterfaceItemIdentifier("window-shortcut-badge")
        badge.font = PluginTypography.code.nsFont
        badge.contentTintColor = .labelColor
        badge.isRecording = entry.id == recordingEntryID
        badge.toolTip = badge.isRecording ? shortcutRecordingHelp
            : localization.string("chooser.changeKey", defaultValue: "修改快捷键…")
        badge.widthAnchor.constraint(equalToConstant: 40).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let cell = NSStackView(views: [icon, labels, NSView(), badge])
        cell.orientation = .horizontal; cell.spacing = 10
        cell.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        return cell
    }

    private func configureListLabels(title: NSTextField, subtitle: NSTextField, entry: WindowSwitcherAppEntry) {
        let displayName = entry.localizedDisplayName(using: localization)
        title.attributedStringValue = highlighted(displayName, query: session?.query ?? "")
        let parts = [displayName.caseInsensitiveCompare(entry.appName) == .orderedSame ? nil : entry.appName, entry.displayNameContext,
                     entry.isMinimized ? localization.string("window.minimized", defaultValue: "已最小化") : nil,
                     entry.isOnOtherDesktop ? localization.string("window.otherDesktop", defaultValue: "其他桌面") : nil,
                     entry.isOnFullscreenSpace ? localization.string("window.fullscreen", defaultValue: "全屏") : nil,
                     entry.isHidden ? localization.string("window.hidden", defaultValue: "已隐藏") : nil,
                     entry.metadataUnavailable ? localization.string("window.unavailable", defaultValue: "窗口信息暂不可用") : nil,
                     entry.isWindowEntry ? nil : localization.string("window.none", defaultValue: "无可用窗口")]
        subtitle.attributedStringValue = highlighted(parts.compactMap { $0 }.joined(separator: " · "), query: session?.query ?? "")
    }

    static func matchRanges(in text: String, query: String) -> [NSRange] {
        query.split(whereSeparator: \.isWhitespace).flatMap { term in
            var ranges: [NSRange] = []
            var start = text.startIndex
            while start < text.endIndex, let range = text.range(of: String(term),
                options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
                ranges.append(NSRange(range, in: text)); start = range.upperBound
            }
            return ranges
        }
    }

    static func gridTitle(_ title: String, appName: String, query: String) -> String {
        let appOnlyMatch = query.split(whereSeparator: \.isWhitespace).contains { term in
            matchRanges(in: title, query: String(term)).isEmpty && !matchRanges(in: appName, query: String(term)).isEmpty
        }
        return appOnlyMatch ? "\(title)\n\(appName)" : title
    }

    private func highlighted(_ text: String, query: String) -> NSAttributedString {
        WindowSwitcherAppearance.highlighted(text, ranges: Self.matchRanges(in: text, query: query))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, rows.indices.contains(table.selectedRow), var session else { return }
        session.selectedID = rows[table.selectedRow].id
        self.session = session
        actionDiagnostic = nil
        onSessionChange?(session)
        render()
    }

    private func beginSearch() {
        guard var session else { return }
        let needsRender = !session.isPersistent || session.usesDirectKeys || (usesInlineSearch && !isInlineSearchExpanded)
        if usesInlineSearch, !isInlineSearchExpanded {
            modeBeforeSearch = (session.isPersistent, session.usesDirectKeys)
        }
        expandInlineSearch()
        if !session.isPersistent {
            showsSearchTransition = true
            searchTransitionTask?.cancel()
            searchTransitionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.showsSearchTransition = false
                self.updateModeIndicator()
            }
        }
        recordingEntryID = nil
        activeMode = .searchSelect
        previewImage.prefersGestureFocus = false
        session.beginSearch(); self.session = session
        onSessionChange?(session)
        if needsRender { render() }
    }

    @objc private func enterSearch() {
        enterSearch(holding: NSEvent.modifierFlags)
    }

    private func enterSearch(holding modifiers: NSEvent.ModifierFlags) {
        if let session, !session.isPersistent {
            searchHeldModifiers = session.invocationModifiers.intersection(modifiers)
        } else {
            searchHeldModifiers.formIntersection(modifiers)
        }
        beginSearch()
        panel.makeFirstResponder(search)
    }

    func noteCyclingInput() { updateModeIndicator() }

    @objc private func cycleMode() {
        guard recordingEntryID == nil else { return }
        onModeChange?(configuredMode.next)
    }

    func applyMode(_ mode: WindowSwitcherMode, session value: WindowSwitcherSession) {
        configuredMode = mode
        activeMode = mode
        previewImage.prefersGestureFocus = mode == .directCycle
        searchTransitionTask?.cancel()
        showsSearchTransition = false
        searchHeldModifiers = []
        modeBeforeSearch = nil
        if isEditingSearch { panel.makeFirstResponder(usesList ? table : cards) }
        search.stringValue = ""
        clearSearchButton.isHidden = true
        if !usesInlineSearch { configureSearchPresentation(inline: true) }
        if mode == .searchSelect {
            expandInlineSearch(animated: false)
        } else if isInlineSearchExpanded {
            isInlineSearchExpanded = false
            searchSurface.isHidden = true
            inlineSearchWidth.constant = 0
            inlineSearchMinimumWidth.constant = 0
        }
        session = value
        renderedSession = nil
        render()
        layoutPanel(preservePosition: true, resizeToContent: true)
        render(forceRevealSelection: true)
        panel.makeFirstResponder(mode == .searchSelect ? search : (usesList ? table : cards))
    }

    private func updateModeIndicator() {
        guard let session else { return }
        let keys = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { session.invocationModifiers.contains($0.0) }.map(\.1).joined()
        let releaseKeys = keys.isEmpty ? localization.string("chooser.modifierKeys", defaultValue: "修饰键") : keys
        modeButton.title = localization.string(activeMode == .searchSelect ? "chooser.modeSearch" : "chooser.modeCycle",
            defaultValue: activeMode == .searchSelect ? "搜索选择" : "循环切换")
        modeHint.stringValue = activeMode == .searchSelect || session.isPersistent
            ? localization.string("chooser.modeSearchHint", defaultValue: "回车切换 · Esc 关闭")
            : localization.format("chooser.modeCycleHint", defaultValue: "松开 %@ 切换", releaseKeys)
        if session.isPersistent && showsSearchTransition {
            modeHint.stringValue = localization.format("chooser.searchTransitionHint",
                defaultValue: "可松开 %@，此窗口会保持打开。", releaseKeys)
        }
        modeButton.image = NSImage(systemSymbolName: activeMode == .searchSelect ? "magnifyingglass" : "arrow.2.circlepath",
                                   accessibilityDescription: modeButton.title)
        if activeMode == .keyWindow {
            modeButton.title = localization.string("settings.mode.legacy", defaultValue: "按键直达")
            modeHint.stringValue = localization.string("chooser.legacyHint", defaultValue: "按快捷键切换 · 点击按键修改")
            modeButton.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: modeButton.title)
        }
        let isRecording = recordingEntryID != nil
        if isRecording {
            modeHint.stringValue = actionMessage ?? localization.string("chooser.recordAssigned", defaultValue: "按下新快捷键 · ⌫ 恢复自动")
        }
        modeHint.isHidden = false
        modeHint.toolTip = isRecording ? shortcutRecordingHelp : nil
        modeHint.setAccessibilityHelp(modeHint.toolTip)
        modeButton.toolTip = localization.string("chooser.changeMode", defaultValue: "点击切换模式")
        modeButton.setAccessibilityLabel(modeButton.title)
        modeButton.setAccessibilityHelp(modeButton.toolTip)
        modeButton.isEnabled = !isRecording
        recordingCancel.title = localization.string("chooser.cancel", defaultValue: "取消")
        recordingCancel.isHidden = !isRecording
        inlineSearch.isHidden = isRecording || !usesInlineSearch
        enterSearchButton.isHidden = isRecording || !usesInlineSearch
        more.isHidden = isRecording
        layoutPicker.isHidden = isRecording
        search.placeholderString = localization.string("chooser.search", defaultValue: "搜索窗口标题或应用")
    }

    func controlTextDidBeginEditing(_ obj: Notification) { searchSurface.isFocused = true; onSearchEditingChange?(true) }
    func controlTextDidEndEditing(_ obj: Notification) { searchSurface.isFocused = false; onSearchEditingChange?(false) }
    @objc private func clearSearch() {
        search.stringValue = ""
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        panel.makeFirstResponder(search)
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = search.stringValue
        clearSearchButton.isHidden = query.isEmpty
        beginSearch()
        guard var session else { return }
        session.query = query; session.normalizeSelection()
        self.session = session; actionDiagnostic = nil
        onSessionChange?(session); render()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveVertically(1)
        case #selector(NSResponder.moveUp(_:)): moveVertically(-1)
        case #selector(NSResponder.insertNewline(_:)): openSelected()
        case #selector(NSResponder.cancelOperation(_:)): onCancel?()
        default: return false
        }
        return true
    }

    @discardableResult
    func handleChooserShortcut(_ event: NSEvent) -> Bool {
        if handleSearchShortcut(event) { return true }
        if event.keyCode == UInt16(kVK_F10),
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .shift {
            showSelectedContextMenu()
            return true
        }
        if recordingEntryID != nil { return recordShortcut(event) }
        if handleDirectTabNavigation(event) { return true }
        if session?.usesDirectKeys == true { return handleDirectKey(event) }
        guard session != nil, var key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        // Shift-number characters are punctuation on many layouts. Match the
        // physical number row for chooser commands, as native quick-open does.
        if let number = [18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9"][Int(event.keyCode)] {
            key = number
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.contains(.command) else { return false }
        let digit = Int(key).flatMap { (1...9).contains($0) ? $0 : nil }
        let zoomKey = (modifiers == .command && ["+", "=", "-", "0"].contains(key)) ||
            (modifiers == [.command, .shift] && ["+", "="].contains(key))
        let recognized = zoomKey || (modifiers == .command && (digit != nil || ["d", "p", "w", "q", "k"].contains(key)))
            || ((modifiers == [.command, .option] || modifiers == [.command, .shift]) && ["1", "2"].contains(key))
        guard recognized else { return false }
        if let editor = search.currentEditor() as? NSTextView, editor.hasMarkedText() { return true }
        if session?.isPersistent == false, session?.invocationModifiers.contains(.command) == true,
           digit == nil { return false }
        if ["w", "q"].contains(key), session?.protectedCommandKeys.contains(key) == true { return true }
        if zoomKey {
            guard session?.protectedCommandKeys.contains(key) != true,
                  !(["+", "="].contains(key) && session?.protectedCommandKeys.isDisjoint(with: ["+", "="]) == false) else { return true }
            if key == "0" { fitPreview() }
            else if key == "-" { zoomPreviewOut() }
            else { zoomPreviewIn() }
        } else if modifiers == [.command, .option] {
            layoutPicker.selectedSegment = key == "1" ? 0 : 1; layoutChanged()
        } else if modifiers == [.command, .shift] {
            if key == "1" || session?.canSwitchCurrentApplication(session?.scopeTargetPID) == true { scope.selectedSegment = key == "1" ? 0 : 1; scopeChanged() }
        } else if let digit {
            selectVisibleWindow(at: digit - 1, activate: session?.isPersistent == true)
        } else {
            switch key {
            case "d": display.performClick(nil)
            case "p": previewButton.state = showsPreview ? .off : .on; previewChanged()
            case "k": more.performClick(nil)
            case "w": closeSelected()
            case "q": quitSelected()
            default: return false
            }
        }
        return true
    }

    private func handleSearchShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let session, recordingEntryID == nil,
              event.charactersIgnoringModifiers?.lowercased() == "f" else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let heldModifiers = session.isPersistent ? searchHeldModifiers : session.invocationModifiers
        let shortcutModifiers = modifiers.subtracting(heldModifiers.subtracting(.command))
        guard shortcutModifiers == .command else { return false }
        // Consume Find before modifier filtering can turn Command-F into text.
        if (search.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            enterSearch(holding: event.modifierFlags)
        }
        return true
    }

    private func handleDirectTabNavigation(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == UInt16(kVK_Tab),
              session?.usesDirectKeys == true, recordingEntryID == nil,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        move(event.modifierFlags.contains(.shift) ? -1 : 1)
        return true
    }

    private func directToken(_ event: NSEvent) -> String? {
        guard event.modifierFlags.intersection([.control, .option]).isEmpty,
              let character = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
        return WindowSwitcherSelectionShortcut(key: String(character), usesCommand: event.modifierFlags.contains(.command))?.storageValue
    }

    private func handleDirectKey(_ event: NSEvent) -> Bool {
        guard let token = directToken(event) else { return false }
        if let entry = session?.results.first(where: { $0.shortcutToken == token }) { onSelect?(entry) }
        else { NSSound.beep() }
        return true
    }

    @objc private func editListShortcut(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        if session?.usesDirectKeys == true { beginShortcutRecording(rows[sender.tag].id) }
        else if var session {
            session.selectedID = rows[sender.tag].id
            self.session = session; onSessionChange?(session)
            onSelect?(rows[sender.tag])
        }
    }

    @objc private func editSelectedShortcut() {
        if let id = session?.selectedID { beginShortcutRecording(id) }
    }

    private func beginShortcutRecording(_ id: String) {
        guard session?.usesDirectKeys == true, session?.entries.contains(where: { $0.id == id }) == true else { return }
        recordingEntryID = id
        actionDiagnostic = nil
        session?.selectedID = id
        if let session { onSessionChange?(session) }
        render()
        panel.makeKey()
        // Keep key input in the chooser after a badge or menu click, rather
        // than leaving focus on the button or a previously active editor.
        panel.makeFirstResponder(usesList ? table : cards)
    }

    private func recordShortcut(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) {
            cancelShortcutRecording(); return true
        }
        guard let id = recordingEntryID, let entry = session?.entries.first(where: { $0.id == id }) else {
            cancelShortcutRecording(); return true
        }
        let clear = [UInt16(kVK_Delete), UInt16(kVK_ForwardDelete)].contains(event.keyCode)
        let token = directToken(event)
        guard clear || token != nil else { NSSound.beep(); return true }
        switch onShortcutChange?(entry, clear ? nil : token) ?? .unavailable {
        case .updated(let entries):
            recordingEntryID = nil; actionDiagnostic = nil
            session?.entries = entries
            onSessionChange?(session!); renderedSession = nil; render()
        case .conflict:
            showMessage(.assignedConflict)
        case .unavailable:
            recordingEntryID = nil
            showMessage(.assignedUnavailable)
        }
        return true
    }

    func visibleShortcutRows() -> [Int] {
        if usesList {
            let loadedRows = 0..<min(rows.count, table.numberOfRows)
            return Array(loadedRows.filter { table.visibleRect.contains(table.rect(ofRow: $0)) }.prefix(9))
        }
        guard let layout = cards.collectionViewLayout else { return [] }
        return Array(layout.layoutAttributesForElements(in: cards.visibleRect)
            .filter { $0.representedElementCategory == .item && cards.visibleRect.contains($0.frame) }
            .compactMap { $0.indexPath?.item }.sorted().prefix(9))
    }

    private func selectVisibleWindow(at index: Int, activate: Bool) {
        let visible = visibleShortcutRows()
        guard visible.indices.contains(index), rows.indices.contains(visible[index]), var session else { return }
        let target = rows[visible[index]]
        session.selectedID = target.id
        self.session = session
        onSessionChange?(session)
        if activate { onSelect?(target) }
        else { render() }
    }

    private func updateShortcutBadges() {
        guard !updating, !applyingPanelLayout, !updatingViewport else { return }
        let visible = session?.isPersistent == true ? visibleShortcutRows() : []
        if usesList {
            // The hidden table may still hold an older snapshot until render reloads it.
            for row in 0..<min(rows.count, table.numberOfRows) {
                guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
                func findBadge(_ view: NSView) -> WindowSwitcherShortcutBadge? {
                    if view.identifier?.rawValue == "window-shortcut-badge" { return view as? WindowSwitcherShortcutBadge }
                    return view.subviews.lazy.compactMap(findBadge).first
                }
                let badge = findBadge(cell)
                badge?.title = session?.usesDirectKeys == true ? (rows[row].shortcutDisplay ?? "") : (visible.firstIndex(of: row).map { "⌘\($0 + 1)" } ?? "")
                badge?.refusesFirstResponder = session?.usesDirectKeys != true
                badge?.isRecording = rows[row].id == recordingEntryID
                badge?.toolTip = badge?.isRecording == true ? shortcutRecordingHelp
                    : localization.string("chooser.changeKey", defaultValue: "修改快捷键…")
            }
        } else {
            for item in cards.visibleItems() {
                guard let card = item as? WindowSwitcherCardItem, let path = cards.indexPath(for: item), rows.indices.contains(path.item) else { continue }
                card.assignedShortcut = session?.usesDirectKeys == true ? rows[path.item].shortcutDisplay : nil
                card.isRecordingShortcut = rows[path.item].id == recordingEntryID
                card.shortcutHelp = card.isRecordingShortcut ? shortcutRecordingHelp
                    : localization.string("chooser.changeKey", defaultValue: "修改快捷键…")
                card.shortcutNumber = session?.usesDirectKeys == true ? nil : visible.firstIndex(of: path.item).map { $0 + 1 }
            }
        }
    }

    private func handleKey(_ original: NSEvent) -> Bool {
        if handleSearchShortcut(original) { return true }
        var event = original
        if recordingEntryID != nil { return recordShortcut(event) }
        if handleDirectTabNavigation(event) { return true }
        if session?.usesDirectKeys == true, handleDirectKey(event) { return true }
        switch Int(event.keyCode) {
        case kVK_Tab:
            if event.modifierFlags.contains(.shift) { panel.selectPreviousKeyView(nil) }
            else { panel.selectNextKeyView(nil) }
        case kVK_Escape: onCancel?()
        case kVK_DownArrow: moveVertically(1)
        case kVK_UpArrow: moveVertically(-1)
        case kVK_RightArrow: move(1)
        case kVK_LeftArrow: move(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter: openSelected()
        default:
            if session?.usesDirectKeys == true { return true }
            if session?.isPersistent == false, let modifiers = session?.invocationModifiers {
                // The held invocation chord is navigation state, not an editing
                // modifier. Continue suppressing it until its physical release.
                searchHeldModifiers = modifiers.intersection(event.modifierFlags)
                event = filterSearchEvent(event)
            }
            let command = event.modifierFlags.contains(.command)
            let key = event.charactersIgnoringModifiers?.lowercased()
            if command && key != "v" { return false }
            guard let text = event.charactersIgnoringModifiers, !text.isEmpty,
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
            beginSearch()
            panel.makeFirstResponder(search)
            if command && key == "v" {
                (search.currentEditor() as? NSTextView)?.paste(nil)
            } else if !command {
                search.currentEditor()?.interpretKeyEvents([event])
            }
        }
        return true
    }

    func filterSearchEvent(_ event: NSEvent) -> NSEvent {
        if event.type == .flagsChanged {
            searchHeldModifiers.formIntersection(event.modifierFlags)
            return event
        }
        guard event.type == .keyDown, !searchHeldModifiers.isEmpty else { return event }
        searchHeldModifiers.formIntersection(event.modifierFlags)
        guard !searchHeldModifiers.isEmpty else { return event }
        let flags = event.modifierFlags.subtracting(searchHeldModifiers)
        return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: flags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.charactersIgnoringModifiers ?? "", charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }

    private func moveVertically(_ direction: Int) {
        guard !usesList else { move(direction); return }
        guard let session, let index = rows.firstIndex(where: { $0.id == session.selectedID }) else { return }
        let row = index / cardColumns
        let targetRow = row + direction
        guard targetRow >= 0, targetRow <= (rows.count - 1) / cardColumns else { return }
        let target = min(rows.count - 1, targetRow * cardColumns + index % cardColumns)
        move(target - index)
    }

    private func move(_ delta: Int) {
        guard var session else { return }
        session.advance(delta); self.session = session; actionDiagnostic = nil
        noteCyclingInput()
        onSessionChange?(session); render()
    }
    private func canClose(_ entry: WindowSwitcherAppEntry) -> Bool {
        entry.isWindowEntry && !entry.metadataUnavailable
    }

    func contextMenu(forRow row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for (key, fallback, action) in [
            ("chooser.switchWindow", "切换到窗口", #selector(contextSwitch(_:))),
            ("chooser.close", "关闭窗口", #selector(contextClose(_:))),
            ("chooser.quitApp", "退出 %@", #selector(contextQuit(_:)))
        ] {
            if action == #selector(contextQuit(_:)) { menu.addItem(.separator()) }
            let title = action == #selector(contextQuit(_:))
                ? localization.format(key, defaultValue: fallback, entry.appName)
                : localization.string(key, defaultValue: fallback)
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            if action == #selector(contextClose(_:)) { item.isEnabled = canClose(entry) }
            menu.addItem(item)
        }
        if session?.usesDirectKeys == true {
            menu.addItem(.separator())
            let edit = NSMenuItem(title: localization.string("chooser.changeKey", defaultValue: "修改快捷键…"), action: #selector(contextEditKey(_:)), keyEquivalent: "")
            edit.target = self; edit.representedObject = entry
            menu.addItem(edit)
        }
        return menu
    }

    @objc private func contextEditKey(_ sender: NSMenuItem) {
        if let target = contextTarget(sender) { beginShortcutRecording(target.id) }
    }

    private func contextTarget(_ sender: NSMenuItem) -> WindowSwitcherAppEntry? {
        guard let target = sender.representedObject as? WindowSwitcherAppEntry,
              session?.entries.contains(where: { $0.id == target.id && $0.processIdentifier == target.processIdentifier }) == true else { return nil }
        return target
    }
    @objc private func contextSwitch(_ sender: NSMenuItem) { if let target = contextTarget(sender) { onSelect?(target) } }
    @objc private func contextClose(_ sender: NSMenuItem) { if let target = contextTarget(sender), canClose(target) { beginSearch(); onClose?(target) } }
    @objc private func contextQuit(_ sender: NSMenuItem) { if let target = contextTarget(sender) { beginSearch(); onQuit?(target) } }

    private func showSelectedContextMenu() {
        guard let row = rows.firstIndex(where: { $0.id == session?.selectedID }), let menu = contextMenu(forRow: row) else { return }
        let anchor: NSView
        if usesList { anchor = table.view(atColumn: 0, row: row, makeIfNecessary: true) ?? table }
        else { anchor = cards.item(at: row)?.view ?? cards }
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), in: anchor)
    }

    private func previewZoomMenu(tracksMenu: Bool = false) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if tracksMenu { menu.delegate = self }
        for (key, fallback, action, equivalent) in [
            ("preview.zoomIn", "放大", #selector(zoomPreviewIn), "+"),
            ("preview.zoomOut", "缩小", #selector(zoomPreviewOut), "-"),
            ("preview.fit", "适合窗口", #selector(fitPreview), "0")
        ] {
            // Keep legacy assignments authoritative. The same actions remain
            // reachable through the menu without advertising conflicting keys.
            let hasShortcut = session?.usesDirectKeys != true && session?.isPersistent == true &&
                session?.protectedCommandKeys.contains(equivalent) != true &&
                !(equivalent == "+" && session?.protectedCommandKeys.contains("=") == true)
            let item = NSMenuItem(title: localization.string(key, defaultValue: fallback), action: action,
                                  keyEquivalent: hasShortcut ? equivalent : "")
            item.target = self
            item.keyEquivalentModifierMask = .command
            menu.addItem(item)
        }
        updatePreviewZoomMenu(menu)
        return menu
    }

    private func updatePreviewZoomMenu(_ menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { updatePreviewZoomMenu(submenu) }
            if item.action == #selector(zoomPreviewIn) {
                item.isEnabled = showsPreview && previewImage.image != nil && previewImage.zoomScale < 4
            } else if item.action == #selector(zoomPreviewOut) || item.action == #selector(fitPreview) {
                item.isEnabled = showsPreview && previewImage.image != nil && previewImage.zoomScale > 1
            }
        }
    }

    @objc private func zoomPreviewIn() { changePreviewZoom(1.25) }
    @objc private func zoomPreviewOut() { changePreviewZoom(0.8) }
    @objc private func fitPreview() {
        guard showsPreview else { return }
        previewImage.fit()
    }
    private func changePreviewZoom(_ factor: CGFloat) {
        guard showsPreview, previewImage.image != nil else { return }
        previewImage.zoom(by: factor)
        panel.makeFirstResponder(previewImage)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updatePreviewZoomMenu(menu)
        menuGeneration += 1
        isPresentingMenu = true
        releasedDuringMenu = false
        onMenuTrackingChange?(true)
    }
    func menuDidClose(_ menu: NSMenu) {
        isPresentingMenu = false
        onMenuTrackingChange?(false)
        let shouldDismissReleasedCycle = releasedDuringMenu
        releasedDuringMenu = false
        let generation = menuGeneration
        // Let a chosen menu action run before dismissing a released cycling session.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.menuGeneration == generation else { return }
            if self.needsLocalizationRefresh { self.refreshLocalization() }
            guard self.session != nil else { return }
            if (shouldDismissReleasedCycle && self.session?.isPersistent == false) || !self.panel.isKeyWindow {
                self.onCancel?()
            }
        }
    }
    func deferReleaseForMenu() -> Bool {
        guard isPresentingMenu else { return false }
        releasedDuringMenu = true
        return true
    }

    @objc private func showOptions() {
        more.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.minY - 4), in: more)
    }

    @objc private func openSelected() { if let entry = session?.selected { onSelect?(entry) } }
    @objc private func cancelSelection() { onCancel?() }
    @objc private func closeSelected() { if let entry = session?.selected, canClose(entry) { beginSearch(); onClose?(entry) } }
    @objc private func quitSelected() { if let entry = session?.selected { beginSearch(); onQuit?(entry) } }
    @objc private func scopeChanged() {
        guard var session else { return }
        guard scope.selectedSegment != 1 || session.canSwitchCurrentApplication(session.scopeTargetPID) else { render(); return }
        session.scope = scope.selectedSegment == 1 ? session.scopeTargetPID.map(WindowSwitcherSession.Scope.currentApplication) ?? .all : .all
        session.normalizeSelection(); self.session = session
        actionDiagnostic = nil; onSessionChange?(session); render()
    }
    @objc private func displayChanged() {
        guard var session else { return }
        session.display = (display.selectedItem?.representedObject as? NSNumber)?.uint32Value
        session.normalizeSelection(); self.session = session
        actionDiagnostic = nil; onSessionChange?(session); render()
    }
    @objc private func togglePreviewFromMenu() {
        previewButton.state = showsPreview ? .off : .on
        previewChanged()
    }

    func windowDidResize(_ notification: Notification) {
        guard panel.isVisible, session?.isPersistent == true else { return }
        if !applyingPanelLayout {
            preferredSizes[SizePreference(list: usesList, preview: !previewPane.isHidden)] = panel.frame.size
        }
        updateViewportLayout()
        revealSelectedItem()
    }

    func windowDidMove(_ notification: Notification) {
        guard panel.isVisible, session?.isPersistent == true, !applyingPanelLayout else { return }
        preferredPositions[SizePreference(list: usesList, preview: !previewPane.isHidden)] = Placement(
            origin: panel.frame.origin,
            displayID: panel.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
    }

    @objc private func resetPanelSize() {
        preferredSizes.removeValue(forKey: SizePreference(list: usesList, preview: !previewPane.isHidden))
        initialResultCount = session?.sizingResultCount ?? 0
        layoutPanel(preservePosition: true, resizeToContent: true)
        render(forceRevealSelection: true)
    }

    private func focusPreviewNow() {
        guard panel.isVisible, !previewPane.isHidden else { return }
        WindowSwitcherPinchDiagnostics.record("focus begin key=\(panel.isKeyWindow) active=\(NSApp.isActive)")
        // Prepare foreground ownership when the preview needs native gesture delivery.
        isAcquiringChooserFocus = true
        defer { isAcquiringChooserFocus = false }
        if !NSApp.isActive || !panel.isKeyWindow { chooserFocus.acquire() }
        panel.makeKey()
        if previewImage.prefersGestureFocus { panel.makeFirstResponder(previewImage) }
        WindowSwitcherPinchDiagnostics.record("focus requested key=\(panel.isKeyWindow) active=\(NSApp.isActive) previewResponder=\(panel.firstResponder === previewImage)")
        if WindowSwitcherPinchDiagnostics.isEnabled {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.panel.isVisible else { return }
                WindowSwitcherPinchDiagnostics.record("focus settled key=\(self.panel.isKeyWindow) active=\(NSApp.isActive) previewResponder=\(self.panel.firstResponder === self.previewImage)")
            }
        }
    }

    @objc private func previewChanged() {
        showsPreview = previewButton.state == .on
        onPreviewChange?(showsPreview)
        previewedEntry = nil; previewedPermission = nil
        if !showsPreview { preview.cancel() }
        layoutPanel(preservePosition: true, resizeToContent: true); render(forceRevealSelection: true)
    }
}
