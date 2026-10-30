import AppKit
import Carbon
import Combine
import QuartzCore
import SwiftUI
import MacToolsPluginKit

enum MenuBarPanelPresentationAction: Equatable {
    case open
    case switchPanel
    case focus

    static func resolve(
        isPanelShown: Bool,
        selectedTab: MenuBarPanelTab,
        requestedTab: MenuBarPanelTab
    ) -> MenuBarPanelPresentationAction {
        guard isPanelShown else {
            return .open
        }

        return selectedTab == requestedTab ? .focus : .switchPanel
    }
}

enum MenuBarPanelToggleAction: Equatable {
    case open
    case close
    case switchPanel

    static func resolve(
        isPanelShown: Bool,
        selectedTab: MenuBarPanelTab,
        requestedTab: MenuBarPanelTab
    ) -> MenuBarPanelToggleAction {
        guard isPanelShown else {
            return .open
        }

        return selectedTab == requestedTab ? .close : .switchPanel
    }
}

enum MenuBarPanelWindowRegistry {
    private static let secondaryPanelIdentifier = NSUserInterfaceItemIdentifier(
        "MacTools.MenuBarSecondaryPanel"
    )
    private static let editingPopoverIdentifier = NSUserInterfaceItemIdentifier(
        "MacTools.MenuBarEditingPopover"
    )

    @MainActor
    static func markSecondaryPanel(_ window: NSWindow) {
        window.identifier = secondaryPanelIdentifier
    }

    @MainActor
    static func markEditingPopover(_ window: NSWindow) {
        window.identifier = editingPopoverIdentifier
    }

    @MainActor
    static func isEditingPopover(_ window: NSWindow) -> Bool {
        window.identifier == editingPopoverIdentifier
    }

    @MainActor
    static func containsAuxiliaryPanelWindow(_ window: NSWindow) -> Bool {
        window.identifier == secondaryPanelIdentifier || isEditingPopover(window)
    }
}

enum MenuBarPanelKeyboardAction: Equatable {
    case dismissPanel
    case showSettings
    case showUnifiedSearch
    case selectTab(MenuBarPanelTab)

    @MainActor
    static func resolve(for event: NSEvent) -> MenuBarPanelKeyboardAction? {
        let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        if event.type == .keyDown,
           event.keyCode == UInt16(kVK_Escape),
           event.modifierFlags.intersection(relevantModifiers).isEmpty {
            return .dismissPanel
        }

        if MacToolsLocalKeyboardCommand.resolve(for: event) == .showSettings {
            return .showSettings
        }

        if MacToolsLocalKeyboardCommand.resolve(for: event) == .showUnifiedSearch {
            return .showUnifiedSearch
        }

        guard let tab = MenuBarPanelPresenter.keyboardShortcutTab(for: event) else {
            return nil
        }

        return .selectTab(tab)
    }
}

@MainActor
final class MenuBarPanelHostingController<Content: View>: NSHostingController<Content> {
    private let onUnhandledEscape: () -> Void

    init(
        rootView: Content,
        onUnhandledEscape: @escaping () -> Void
    ) {
        self.onUnhandledEscape = onUnhandledEscape
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func keyDown(with event: NSEvent) {
        guard MenuBarPanelKeyboardAction.resolve(for: event) == .dismissPanel else {
            super.keyDown(with: event)
            return
        }

        onUnhandledEscape()
    }

    override func cancelOperation(_ sender: Any?) {
        onUnhandledEscape()
    }
}

@MainActor
final class MenuBarPanelContainerController<Content: View>: NSViewController {
    private let hostingController: MenuBarPanelHostingController<Content>
    private let themeStore: MenuBarPanelThemeStore
    private let onUnhandledEscape: () -> Void

    init(
        hostingController: MenuBarPanelHostingController<Content>,
        themeStore: MenuBarPanelThemeStore,
        onUnhandledEscape: @escaping () -> Void
    ) {
        self.hostingController = hostingController
        self.themeStore = themeStore
        self.onUnhandledEscape = onUnhandledEscape
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = MenuBarPanelBackgroundView(themeStore: themeStore)
    }

    func refreshBackground() {
        guard isViewLoaded else { return }
        view.needsDisplay = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(hostingController)
        let hostedView = hostingController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostedView)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor)
        ])
    }

    override func keyDown(with event: NSEvent) {
        guard MenuBarPanelKeyboardAction.resolve(for: event) == .dismissPanel else {
            super.keyDown(with: event)
            return
        }

        onUnhandledEscape()
    }

    override func cancelOperation(_ sender: Any?) {
        onUnhandledEscape()
    }
}

private final class MenuBarPanelBackgroundView: NSView {
    private let themeStore: MenuBarPanelThemeStore

    init(themeStore: MenuBarPanelThemeStore) {
        self.themeStore = themeStore
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let appearance: MenuBarPanelThemeAppearance = isDark ? .dark : .light
        let style = MenuBarPanelThemeResolver.resolve(
            definition: themeStore.selectedDefinition(for: appearance),
            colorScheme: isDark ? .dark : .light,
            contrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                ? .increased
                : .standard
        )
        NSColor(style.surfaces.panel).setFill()
        NSBezierPath.fill(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

enum MenuBarPopoverGeometry {
    /// `hasFullSizeContent` makes `contentSize` describe the complete popover
    /// window instead of the unobscured content rect. The supported systems
    /// currently report 13 points on each edge. This is only a first-frame
    /// fallback; the live AppKit safe-area insets replace it after presentation.
    static let fallbackSafeAreaInsets = NSEdgeInsets(
        top: 13,
        left: 13,
        bottom: 13,
        right: 13
    )

    static func popoverSize(
        preserving contentSize: NSSize,
        safeAreaInsets: NSEdgeInsets
    ) -> NSSize {
        NSSize(
            width: contentSize.width + safeAreaInsets.left + safeAreaInsets.right,
            height: contentSize.height + safeAreaInsets.top + safeAreaInsets.bottom
        )
    }

    static func hasUsableInsets(_ insets: NSEdgeInsets) -> Bool {
        insets.top > 0 || insets.left > 0 || insets.bottom > 0 || insets.right > 0
    }
}

@MainActor
final class MenuBarPanelPresenter: NSObject {
    static let popoverBehavior: NSPopover.Behavior = .applicationDefined

    private typealias PanelKind = MenuBarPanelTab

    private let pluginHost: PluginHost
    private let appUpdater: AppUpdater
    private let menuBarPanelThemeStore: MenuBarPanelThemeStore
    private let onDismiss: () -> Void
    private let onOpenUpdate: () -> Void
    private let onOpenSettings: () -> Void
    private let onOpenUnifiedSearch: () -> Void
    private let onPresentDiskCleanConfiguration: () -> Void
    private let onPresentLaunchControlConfiguration: () -> Void
    private let onAllPanelsClosed: () -> Void

    private let popover = NSPopover()
    private let nativeMenuPresenter: MenuBarPanelMenuPresenter
    private let panelModel: MenuBarUnifiedPanelModel
    private let hostingController: MenuBarPanelHostingController<MenuBarUnifiedPanelContent>
    private let contentPresentation: MenuBarPanelPresentationModel
    private let containerController: MenuBarPanelContainerController<MenuBarUnifiedPanelContent>
    private var appearanceObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var runtimeLocaleCancellable: AnyCancellable?
    private var heightRefreshCancellables: Set<AnyCancellable> = []
    private var keyboardShortcutMonitor: Any?
    private var selectedPanel: PanelKind = .components
    private var panelContentSize = NSSize(
        width: MenuBarPanelLayout.baseWidth,
        height: MenuBarPanelLayout.minimumPanelHeight
    )
    private var popoverSafeAreaInsets = MenuBarPopoverGeometry.fallbackSafeAreaInsets
    private var hoverAnchorPanel: NSPanel?
    private var isHoverPanelPresentation = false
    private var isHidingHoverPanel = false
    private var hoverPanelRestingFrame: NSRect?
    private var hoverDismissGeneration: UInt = 0

    init(
        pluginHost: PluginHost,
        appUpdater: AppUpdater,
        menuBarPanelThemeStore: MenuBarPanelThemeStore = .shared,
        onDismiss: @escaping () -> Void,
        onOpenUpdate: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenUnifiedSearch: @escaping () -> Void,
        onPresentDiskCleanConfiguration: @escaping () -> Void,
        onPresentLaunchControlConfiguration: @escaping () -> Void,
        onAllPanelsClosed: @escaping () -> Void
    ) {
        self.pluginHost = pluginHost
        self.appUpdater = appUpdater
        self.menuBarPanelThemeStore = menuBarPanelThemeStore
        self.onDismiss = onDismiss
        self.onOpenUpdate = onOpenUpdate
        self.onOpenSettings = onOpenSettings
        self.onOpenUnifiedSearch = onOpenUnifiedSearch
        self.onPresentDiskCleanConfiguration = onPresentDiskCleanConfiguration
        self.onPresentLaunchControlConfiguration = onPresentLaunchControlConfiguration
        self.onAllPanelsClosed = onAllPanelsClosed

        let initialTab = MenuBarPanelTab(id: pluginHost.lastSelectedMenuBarPanelID)
        self.selectedPanel = initialTab
        let panelModel = MenuBarUnifiedPanelModel(
            selectedTab: initialTab,
            contentHeight: MenuBarPanelLayout.minimumContentHeight,
            maximumFeatureListHeight: MenuBarPanelLayout.maximumFeatureListHeight(for: nil),
            isPanelVisible: false
        )
        self.panelModel = panelModel
        let contentPresentation = MenuBarPanelPresentationModel(host: pluginHost)
        self.contentPresentation = contentPresentation
        let nativeMenuPresenter = MenuBarPanelMenuPresenter()
        self.nativeMenuPresenter = nativeMenuPresenter
        let hostingController = MenuBarPanelHostingController(
            rootView: MenuBarUnifiedPanelContent(
                pluginHost: pluginHost,
                nativeMenuPresenter: nativeMenuPresenter,
                presentation: contentPresentation,
                appUpdater: appUpdater,
                menuBarPanelThemeStore: menuBarPanelThemeStore,
                model: panelModel,
                onDismiss: onDismiss,
                onOpenUpdate: onOpenUpdate,
                onOpenSettings: onOpenSettings,
                onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
                onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration
            ),
            onUnhandledEscape: {
                if !panelModel.preventDismissalWhileEditing() { onDismiss() }
            }
        )
        self.hostingController = hostingController
        self.containerController = MenuBarPanelContainerController(
            hostingController: hostingController,
            themeStore: menuBarPanelThemeStore,
            onUnhandledEscape: {
                if !panelModel.preventDismissalWhileEditing() { onDismiss() }
            }
        )

        super.init()

        panelModel.onTabSelection = { [weak self] tab in
            self?.select(tab)
        }
        panelModel.onLayoutEditingChange = { [weak self] _ in
            self?.refreshHeightForVisiblePanel()
        }
        panelModel.onPanelDeletion = { [weak self] id in
            self?.deletePanel(id: id)
        }
        configure(popover)
        observeAppearancePreference()
        observeThemePreference()
        runtimeLocaleCancellable = PluginRuntimeLocalization.source.$revision
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.refreshLocalization()
                }
            }
        observePanelItemChanges()
        applyCurrentAppearance()
        prewarm()
    }

    isolated deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
        removeKeyboardShortcutMonitorIfNeeded()
        runtimeLocaleCancellable?.cancel()
    }

    var isAnyPanelShown: Bool {
        popover.isShown
    }

    private func refreshLocalization() {
        hostingController.rootView = MenuBarUnifiedPanelContent(
            pluginHost: pluginHost,
            nativeMenuPresenter: nativeMenuPresenter,
            presentation: contentPresentation,
            appUpdater: appUpdater,
            menuBarPanelThemeStore: menuBarPanelThemeStore,
            model: panelModel,
            onDismiss: onDismiss,
            onOpenUpdate: onOpenUpdate,
            onOpenSettings: onOpenSettings,
            onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
            onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration
        )
        scheduleHeightRefresh(for: tab(for: selectedPanel))
    }

    #if DEBUG
    var debugPopoverForTests: NSPopover {
        popover
    }

    var debugHasKeyboardShortcutMonitorForTests: Bool {
        keyboardShortcutMonitor != nil
    }

    var debugSelectedTabForTests: MenuBarPanelTab {
        tab(for: selectedPanel)
    }

    var debugPanelModelForTests: MenuBarUnifiedPanelModel { panelModel }
    #endif

    func toggleFeaturePanel(relativeTo button: NSStatusBarButton) {
        toggle(.features, relativeTo: button)
    }

    func toggleComponentPanel(relativeTo button: NSStatusBarButton) {
        toggle(.components, relativeTo: button)
    }

    func showFeaturePanel(relativeTo button: NSStatusBarButton) {
        present(.features, relativeTo: button)
    }

    func showDashboard(relativeTo button: NSStatusBarButton) {
        present(.components, relativeTo: button)
    }

    func showPanel(id: String, toggle shouldToggle: Bool, relativeTo button: NSStatusBarButton) {
        guard pluginHost.menuBarPanels.contains(where: { $0.id == id }) else { return }
        let panel = MenuBarPanelTab(id: id)
        if shouldToggle { toggle(panel, relativeTo: button) }
        else { present(panel, relativeTo: button) }
    }

    /// Fallback for a hidden status item: the same presentation using an
    /// invisible anchor at the menu-bar end instead of a status-item button.
    func toggleFeaturePanel(anchorRect: NSRect) {
        toggle(.features, relativeTo: hoverAnchorView(for: anchorRect))
    }

    func toggleComponentPanel(anchorRect: NSRect) {
        toggle(.components, relativeTo: hoverAnchorView(for: anchorRect))
    }

    func showFeaturePanel(anchorRect: NSRect) {
        present(.features, relativeTo: hoverAnchorView(for: anchorRect))
    }

    func showDashboard(anchorRect: NSRect) {
        present(.components, relativeTo: hoverAnchorView(for: anchorRect))
    }

    func showPanel(id: String, toggle shouldToggle: Bool, anchorRect: NSRect) {
        guard pluginHost.menuBarPanels.contains(where: { $0.id == id }) else { return }
        let panel = MenuBarPanelTab(id: id)
        if shouldToggle,
           popover.isShown,
           tab(for: selectedPanel).id == id {
            if panelModel.preventDismissalWhileEditing() {
                focus(popover)
            } else {
                dismissPanels()
            }
            return
        }
        present(panel, relativeTo: hoverAnchorView(for: anchorRect))
    }

    /// Presents the regular panel below an explicit screen rectangle. Used by
    /// plugin-owned hover surfaces such as the notch trigger.
    @discardableResult
    func presentPanelBelowAnchor(panelID: String?, anchorRect: NSRect) -> Bool {
        guard !anchorRect.isEmpty,
              anchorRect.width.isFinite,
              anchorRect.height.isFinite,
              !anchorRect.isNull else { return false }
        guard NSScreen.screens.contains(where: { $0.frame.intersects(anchorRect) }) else {
            return false
        }

        if popover.isShown {
            guard isHoverPanelPresentation else { return false }
            cancelHoverPanelDismissalIfNeeded()
            return true
        }

        guard let resolvedPanel = resolvedPanelForAnchor(panelID: panelID) else { return false }

        let anchorView = hoverAnchorView(for: anchorRect)
        isHoverPanelPresentation = true
        isHidingHoverPanel = false
        hoverPanelRestingFrame = nil
        present(resolvedPanel, relativeTo: anchorView, animates: true)
        return popover.isShown
    }

    /// Dismisses the panel presented below a plugin-owned anchor. Returns
    /// `false` when the host declines because the panel layout is being edited,
    /// so the caller can keep ownership and retry later.
    @discardableResult
    func dismissPanelBelowAnchor(animated: Bool) -> Bool {
        // Check the editing guard before any hide animation starts. Fading the
        // panel out first would leave it open but transparent after the close
        // is rejected.
        guard !panelModel.preventDismissalWhileEditing() else { return false }
        guard popover.isShown else {
            cleanupHoverAnchor()
            return true
        }
        guard isHoverPanelPresentation, animated,
              let window = popover.contentViewController?.view.window else {
            popover.performClose(nil)
            return true
        }

        hoverDismissGeneration &+= 1
        let generation = hoverDismissGeneration
        let restingFrame = window.frame
        hoverPanelRestingFrame = restingFrame
        isHidingHoverPanel = true

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(
                restingFrame.offsetBy(dx: 0, dy: Self.hoverPanelSlideDistance),
                display: true
            )
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hoverDismissGeneration == generation else { return }
                self.isHidingHoverPanel = false
                self.hoverPanelRestingFrame = nil
                self.popover.performClose(nil)
            }
        })
        return true
    }

    var presentedPanelScreenFrame: NSRect? {
        guard popover.isShown else { return nil }
        return popover.contentViewController?.view.window?.frame
    }

    func dismissPanels() {
        nativeMenuPresenter.cancel()
        guard !panelModel.preventDismissalWhileEditing() else { return }
        hoverDismissGeneration &+= 1
        isHidingHoverPanel = false
        hoverPanelRestingFrame = nil
        popover.performClose(nil)
    }

    var isTrackingNativeMenu: Bool { nativeMenuPresenter.isTrackingMenu }

    func containsPresentedWindow(_ window: NSWindow) -> Bool {
        window === popover.contentViewController?.view.window
            || MenuBarPanelWindowRegistry.containsAuxiliaryPanelWindow(window)
    }

    private func toggle(_ panel: PanelKind, relativeTo anchorView: NSView) {
        let action = MenuBarPanelToggleAction.resolve(
            isPanelShown: popover.isShown,
            selectedTab: tab(for: selectedPanel),
            requestedTab: tab(for: panel)
        )

        if action == .close {
            if panelModel.preventDismissalWhileEditing() {
                focus(popover)
            } else {
                dismissPanels()
            }
            return
        }

        present(panel, relativeTo: anchorView)
    }

    private func present(_ panel: PanelKind, relativeTo anchorView: NSView, animates: Bool = false) {
        let action = MenuBarPanelPresentationAction.resolve(
            isPanelShown: popover.isShown,
            selectedTab: tab(for: selectedPanel),
            requestedTab: tab(for: panel)
        )
        selectedPanel = panel
        updateContent(
            selectedTab: tab(for: panel),
            screen: anchorView.window?.screen ?? NSScreen.main,
            isPanelVisible: true
        )
        updatePanelSurfaceVisibility(for: tab(for: panel), isPanelVisible: true)

        if action != .open {
            focus(popover)
            scheduleHeightRefresh(for: tab(for: panel))
            return
        }

        isHoverPanelPresentation = animates
        show(popover, relativeTo: anchorView, animates: animates)
        scheduleHeightRefresh(for: tab(for: panel))
    }

    private func configure(_ popover: NSPopover) {
        // Dismissal is coordinated by MenuBarStatusItemController so sibling
        // panels can receive clicks without AppKit closing the popover first.
        popover.behavior = Self.popoverBehavior
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = containerController
        // Keep popover sizing single-sourced from MenuBarPanelLayout.
        // Letting SwiftUI also publish preferredContentSize can make AppKit
        // resize the shown popover a second time during tab switches.
        if #available(macOS 14.0, *) {
            // Extend the app-owned background into AppKit's attachment arrow
            // so it uses the same adaptive color as the panel body.
            popover.hasFullSizeContent = true
            hostingController.sizingOptions = []
        }
        AppAppearancePreference.stored().apply(to: containerController.view)
    }

    private func prewarm() {
        applyPopoverSize()
        containerController.loadViewIfNeeded()
        containerController.view.setFrameSize(popover.contentSize)
    }

    private func show(_ popover: NSPopover, relativeTo anchorView: NSView, animates: Bool) {
        applyCurrentAppearance()
        PluginPresentationSafety.prepareForWindowOrdering()
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        applyCurrentAppearance()
        if animates {
            animateHoverPanelIn()
        }
        focus(popover)
    }

    private static let hoverPanelSlideDistance: CGFloat = 18

    private func animateHoverPanelIn() {
        guard let window = popover.contentViewController?.view.window else { return }
        let targetFrame = window.frame
        hoverPanelRestingFrame = targetFrame
        window.setFrame(
            targetFrame.offsetBy(dx: 0, dy: Self.hoverPanelSlideDistance),
            display: false
        )
        window.alphaValue = 0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(targetFrame, display: true)
            window.animator().alphaValue = 1
        }
    }

    private func cancelHoverPanelDismissalIfNeeded() {
        guard isHidingHoverPanel else { return }
        hoverDismissGeneration &+= 1
        isHidingHoverPanel = false
        guard let window = popover.contentViewController?.view.window,
              let restingFrame = hoverPanelRestingFrame else { return }
        hoverPanelRestingFrame = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(restingFrame, display: true)
            window.animator().alphaValue = 1
        }
    }

    private func resolvedPanelForAnchor(panelID: String?) -> MenuBarPanelTab? {
        let visiblePanels = pluginHost.visibleMenuBarPanels
        guard !visiblePanels.isEmpty else { return nil }
        let requestedID = panelID ?? pluginHost.lastSelectedMenuBarPanelID
        let resolvedID = visiblePanels.first(where: { $0.id == requestedID })?.id
            ?? visiblePanels.first(where: { $0.id == MenuBarPanelDefinition.componentsID })?.id
            ?? visiblePanels.first?.id
        guard let resolvedID else { return nil }
        return MenuBarPanelTab(id: resolvedID)
    }

    private func hoverAnchorView(for anchorRect: NSRect) -> NSView {
        let panel: NSPanel
        if let hoverAnchorPanel {
            panel = hoverAnchorPanel
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.isFloatingPanel = true
            created.level = .statusBar
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = false
            created.ignoresMouseEvents = true
            created.hidesOnDeactivate = false
            created.isReleasedWhenClosed = false
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            created.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            hoverAnchorPanel = created
            panel = created
        }

        panel.setFrame(
            NSRect(x: anchorRect.midX - 0.5, y: anchorRect.minY - 1, width: 1, height: 1),
            display: false
        )
        panel.orderFrontRegardless()
        return panel.contentView ?? NSView(frame: .zero)
    }

    private func cleanupHoverAnchor() {
        hoverAnchorPanel?.orderOut(nil)
        hoverAnchorPanel = nil
        isHoverPanelPresentation = false
        isHidingHoverPanel = false
        hoverPanelRestingFrame = nil
        hoverDismissGeneration &+= 1
    }

    private func installKeyboardShortcutMonitorIfNeeded() {
        guard keyboardShortcutMonitor == nil else {
            return
        }

        // Panel navigation and Settings presentation are local key equivalents.
        // Escape is intentionally handled later by the hosting controller's
        // responder-chain cancelOperation fallback.
        keyboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleKeyboardShortcut(event) ?? event
        }
    }

    private func removeKeyboardShortcutMonitorIfNeeded() {
        guard let keyboardShortcutMonitor else {
            return
        }

        NSEvent.removeMonitor(keyboardShortcutMonitor)
        self.keyboardShortcutMonitor = nil
    }

    private func handleKeyboardShortcut(_ event: NSEvent) -> NSEvent? {
        guard
            popover.isShown,
            !nativeMenuPresenter.isTrackingMenu,
            let eventWindow = event.window,
            containsPresentedWindow(eventWindow)
        else {
            return event
        }

        if let index = Self.keyboardShortcutIndex(for: event),
           eventWindow === popover.contentViewController?.view.window {
            let panels = pluginHost.visibleMenuBarPanels
            if panels.indices.contains(index) { select(MenuBarPanelTab(id: panels[index].id)) }
            return nil
        }
        guard let action = MenuBarPanelKeyboardAction.resolve(for: event) else { return event }

        // Let the child popover consume Escape without ending the editing session.
        if action == .dismissPanel, MenuBarPanelWindowRegistry.isEditingPopover(eventWindow) {
            return event
        }

        if case .selectTab = action,
           eventWindow !== popover.contentViewController?.view.window {
            return event
        }

        if action == .dismissPanel, panelModel.preventDismissalWhileEditing() {
            return nil
        }

        if action == .dismissPanel,
           let firstResponder = eventWindow.firstResponder,
           firstResponder !== eventWindow {
            return event
        }

        performKeyboardAction(action)
        return nil
    }

    func performKeyboardAction(_ action: MenuBarPanelKeyboardAction) {
        switch action {
        case .dismissPanel:
            if !panelModel.preventDismissalWhileEditing() { onDismiss() }
        case .showSettings:
            onOpenSettings()
        case .showUnifiedSearch:
            onOpenUnifiedSearch()
        case let .selectTab(tab):
            select(tab)
        }
    }

    static func keyboardShortcutIndex(for event: NSEvent) -> Int? {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return nil }
        return [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].firstIndex(of: Int(event.keyCode))
    }

    // Internal so focused tests can validate layout-independent key matching.
    static func keyboardShortcutTab(for event: NSEvent) -> MenuBarPanelTab? {
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let modifiers = event.modifierFlags.intersection(shortcutModifiers)
        guard modifiers == .command else {
            return nil
        }

        switch event.keyCode {
        case UInt16(kVK_ANSI_1):
            return .components
        case UInt16(kVK_ANSI_2):
            return .features
        default:
            return nil
        }
    }

    private func focus(_ popover: NSPopover) {
        guard !nativeMenuPresenter.isPresenting else { return }
        let menuGeneration = nativeMenuPresenter.generation
        popover.contentViewController?.view.window?.makeKey()

        DispatchQueue.main.async { [weak self, weak popover] in
            guard let self, let popover, popover.isShown,
                  self.nativeMenuPresenter.generation == menuGeneration,
                  !self.nativeMenuPresenter.isPresenting else {
                return
            }

            guard let window = popover.contentViewController?.view.window else {
                return
            }

            window.makeKey()
            Self.clearAutomaticInitialFocus(in: window)
        }
    }

    /// Prevent SwiftUI from leaving the first toolbar button focused when the
    /// popover becomes key. Keyboard navigation can still focus controls
    /// normally after the popover opens.
    static func clearAutomaticInitialFocus(in window: NSWindow) {
        window.makeFirstResponder(nil)
    }

    private func observeAppearancePreference() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppAppearancePreference.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.applyCurrentAppearance()
            }
        }
    }

    private func observeThemePreference() {
        themeObserver = NotificationCenter.default.addObserver(
            forName: MenuBarPanelThemeStore.didChangeNotification,
            object: menuBarPanelThemeStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.containerController.refreshBackground()
            }
        }
    }

    private func observePanelItemChanges() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification))
            .sink { [weak self] _ in self?.refreshHeightForVisiblePanel() }
            .store(in: &heightRefreshCancellables)
        pluginHost.menuBarPanelContentDidChange
            .sink { [weak self] _ in
                // The host has finished publishing all content and layout changes.
                // Resolve selection and height together, before SwiftUI's next layout.
                self?.reconcilePanelConfiguration()
            }.store(in: &heightRefreshCancellables)
    }

    private func applyCurrentAppearance() {
        let preference = AppAppearancePreference.stored()
        preference.apply(to: hostingController.view)
        preference.apply(to: popover)
        containerController.refreshBackground()
    }

    private func setPopoverHeight(_ height: CGFloat) {
        let width = panelModel.contentWidth
        let currentSize = panelContentSize
        guard
            abs(currentSize.width - width) > 0.5
                || abs(currentSize.height - height) > 0.5
        else {
            return
        }

        panelContentSize = NSSize(width: width, height: height)
        applyPopoverSize()
    }

    private func applyPopoverSize() {
        let resolvedSize = MenuBarPopoverGeometry.popoverSize(
            preserving: panelContentSize,
            safeAreaInsets: popoverSafeAreaInsets
        )
        let currentSize = popover.contentSize
        guard
            abs(currentSize.width - resolvedSize.width) > 0.5
                || abs(currentSize.height - resolvedSize.height) > 0.5
        else {
            return
        }

        popover.contentSize = resolvedSize
    }

    private func synchronizePopoverSafeAreaInsets() {
        containerController.view.layoutSubtreeIfNeeded()
        let resolvedInsets = containerController.view.safeAreaInsets
        guard MenuBarPopoverGeometry.hasUsableInsets(resolvedInsets) else {
            return
        }

        guard
            abs(popoverSafeAreaInsets.top - resolvedInsets.top) > 0.5
                || abs(popoverSafeAreaInsets.left - resolvedInsets.left) > 0.5
                || abs(popoverSafeAreaInsets.bottom - resolvedInsets.bottom) > 0.5
                || abs(popoverSafeAreaInsets.right - resolvedInsets.right) > 0.5
        else {
            return
        }

        popoverSafeAreaInsets = resolvedInsets
        applyPopoverSize()
    }

    private func updateContent(
        selectedTab: MenuBarPanelTab,
        screen: NSScreen?,
        isPanelVisible: Bool
    ) {
        let heightResolution = resolveContentHeight(
            for: selectedTab,
            screen: screen
        )
        panelModel.update(
            selectedTab: selectedTab,
            contentHeight: heightResolution.contentHeight,
            maximumFeatureListHeight: heightResolution.maximumFeatureListHeight,
            isPanelVisible: isPanelVisible
        )
        setPopoverHeight(
            MenuBarPanelLayout.panelHeight(
                forContentHeight: heightResolution.contentHeight,
                showsEditingActionBar: panelModel.isEditingLayout
            )
        )
    }

    private func select(_ tab: MenuBarPanelTab) {
        guard pluginHost.menuBarPanels.contains(where: { $0.id == tab.id }),
              tab != panelModel.selectedTab else {
            return
        }

        selectedPanel = panelKind(for: tab)
        pluginHost.rememberMenuBarPanelSelection(id: tab.id)
        updateContent(
            selectedTab: tab,
            screen: popover.contentViewController?.view.window?.screen ?? NSScreen.main,
            isPanelVisible: popover.isShown
        )
        updatePanelSurfaceVisibility(for: tab, isPanelVisible: popover.isShown)
        scheduleHeightRefresh(for: tab)
    }

    private func deletePanel(id: String) -> String? {
        guard pluginHost.menuBarPanels.contains(where: { $0.id == id && !$0.isDefault }) else { return nil }
        if selectedPanel.id == id {
            // The tab and its editor are about to disappear. End their focus
            // before SwiftUI releases the associated responder proxies.
            popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
        var error: String?
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            error = pluginHost.deleteMenuBarPanel(id: id)
            guard error == nil else { return }
            // Publish one valid selection and its final size before SwiftUI renders
            // the removed tab or an empty intermediate editor.
            reconcilePanelConfiguration()
        }
        return error
    }

    private func reconcilePanelConfiguration() {
        let panels = pluginHost.visibleMenuBarPanels
        guard let selected = panels.first(where: { $0.id == selectedPanel.id }) ?? panels.first else { return }
        selectedPanel = MenuBarPanelTab(id: selected.id)
        guard popover.isShown else { return }
        updateContent(selectedTab: selectedPanel,
                      screen: popover.contentViewController?.view.window?.screen ?? NSScreen.main,
                      isPanelVisible: popover.isShown)
        updatePanelSurfaceVisibility(for: selectedPanel, isPanelVisible: popover.isShown)
    }

    private func scheduleHeightRefresh(for tab: MenuBarPanelTab) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else {
                return
            }

            self.refreshHeight(for: tab)
        }
    }

    private func refreshHeight(for tab: MenuBarPanelTab) {
        guard tab == self.tab(for: selectedPanel) else {
            return
        }

        let screen = popover.contentViewController?.view.window?.screen ?? NSScreen.main
        let heightResolution = resolveContentHeight(
            for: tab,
            screen: screen
        )
        panelModel.update(
            selectedTab: tab,
            contentHeight: heightResolution.contentHeight,
            maximumFeatureListHeight: heightResolution.maximumFeatureListHeight,
            isPanelVisible: popover.isShown
        )
        setPopoverHeight(
            MenuBarPanelLayout.panelHeight(
                forContentHeight: heightResolution.contentHeight,
                showsEditingActionBar: panelModel.isEditingLayout
            )
        )
    }

    private func refreshHeightForVisiblePanel() {
        guard popover.isShown else {
            return
        }

        refreshHeight(for: tab(for: selectedPanel))
    }

    private func resolveContentHeight(
        for tab: MenuBarPanelTab,
        screen: NSScreen?
    ) -> MenuBarPanelHeightResolution {
        let maximumWidth = MenuBarPanelWidth.maximum(visibleFrameWidth: screen?.visibleFrame.width)
        panelModel.updateWidth(MenuBarPanelWidth.resolved(
            preferred: pluginHost.preferredMenuBarPanelWidth, maximum: maximumWidth),
            maximum: maximumWidth)
        let surfaceWidth = panelModel.contentWidth - MenuBarPanelLayout.outerPadding * 2
        let maximumFeatureListHeight = MenuBarPanelLayout.maximumFeatureListHeight(for: screen)
        let components = pluginHost.componentItems(in: tab.id)
        let features = pluginHost.panelItems(in: tab.id)
        let entries = pluginHost.panelEntries(in: tab.id)
        let height: CGFloat
        if panelModel.isEditingLayout {
            let placement = ConfiguredMenuBarPanelLayout.placement(
                entries: entries, components: components, features: features, width: surfaceWidth
            )
            height = PanelLayoutDestination.editorContentHeight(
                itemHeight: placement.height,
                maximumHeight: max(
                    MenuBarPanelLayout.minimumPanelHeight - MenuBarPanelLayout.editingPanelChromeHeight,
                    MenuBarPanelLayout.maximumPanelHeight(for: screen)
                        - MenuBarPanelLayout.editingPanelChromeHeight - MenuBarPanelLayout.editingActionBarHeight
                )
            )
        } else {
            height = ConfiguredMenuBarPanelLayout.contentHeight(
                components: components, features: features, screen: screen, entries: entries, width: surfaceWidth
            )
        }
        return MenuBarPanelHeightResolution(contentHeight: height, maximumFeatureListHeight: maximumFeatureListHeight)
    }

    private func tab(for panel: PanelKind) -> MenuBarPanelTab { panel }
    private func panelKind(for tab: MenuBarPanelTab) -> PanelKind { tab }

    private func updatePanelSurfaceVisibility(for tab: MenuBarPanelTab, isPanelVisible: Bool) {
        contentPresentation.setVisible(isPanelVisible)
        pluginHost.setVisibleMenuBarPanel(isPanelVisible ? tab.id : nil)
    }

}

extension MenuBarPanelPresenter: NSPopoverDelegate {
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        popover !== self.popover || !panelModel.preventDismissalWhileEditing()
    }

    func popoverWillShow(_ notification: Notification) {
        guard let openingPopover = notification.object as? NSPopover, openingPopover === popover else {
            return
        }

        installKeyboardShortcutMonitorIfNeeded()
    }

    func popoverDidShow(_ notification: Notification) {
        guard let shownPopover = notification.object as? NSPopover, shownPopover === popover else {
            return
        }

        synchronizePopoverSafeAreaInsets()
    }

    func popoverDidClose(_ notification: Notification) {
        if let closedPopover = notification.object as? NSPopover, closedPopover === popover {
            nativeMenuPresenter.cancel()
            removeKeyboardShortcutMonitorIfNeeded()
            cleanupHoverAnchor()
            updateContent(
                selectedTab: tab(for: selectedPanel),
                screen: NSScreen.main,
                isPanelVisible: false
            )
            updatePanelSurfaceVisibility(
                for: tab(for: selectedPanel),
                isPanelVisible: false
            )
            onAllPanelsClosed()
        }
    }
}

struct MenuBarPanelTab: Hashable, Identifiable, CaseIterable {
    let id: String
    static let components = Self(id: MenuBarPanelDefinition.componentsID)
    static let features = Self(id: MenuBarPanelDefinition.featuresID)
    static let allCases: [Self] = [.components, .features]

    var systemImage: String { self == .features ? "switch.2" : "square.grid.2x2" }
    var accessibilityTitle: String {
        self == .features
            ? AppL10n.plugins("plugin.panel.features", defaultValue: "功能面板")
            : AppL10n.plugins("plugin.panel.components", defaultValue: "组件面板")
    }
}

struct MenuBarPanelHeightResolution: Equatable {
    let contentHeight: CGFloat
    let maximumFeatureListHeight: CGFloat
}

@MainActor
final class MenuBarUnifiedPanelModel: ObservableObject {
    private(set) var selectedTab: MenuBarPanelTab
    private(set) var contentHeight: CGFloat
    private(set) var maximumFeatureListHeight: CGFloat
    private(set) var isPanelVisible: Bool
    @Published private(set) var contentWidth = MenuBarPanelLayout.baseWidth
    @Published private(set) var maximumWidth = MenuBarPanelWidth.maximum(visibleFrameWidth: nil)

    func updateWidth(_ width: CGFloat, maximum: CGFloat) {
        if contentWidth != width { contentWidth = width }
        if maximumWidth != maximum { maximumWidth = maximum }
    }

    @Published private(set) var isEditingLayout = false
    let editingFeedback = MenuBarPanelEditingFeedback()
    var onTabSelection: ((MenuBarPanelTab) -> Void)?
    var onLayoutEditingChange: ((Bool) -> Void)?
    var onPanelDeletion: ((String) -> String?)?

    init(
        selectedTab: MenuBarPanelTab,
        contentHeight: CGFloat,
        maximumFeatureListHeight: CGFloat,
        isPanelVisible: Bool
    ) {
        self.selectedTab = selectedTab
        self.contentHeight = contentHeight
        self.maximumFeatureListHeight = maximumFeatureListHeight
        self.isPanelVisible = isPanelVisible
    }

    func update(
        selectedTab: MenuBarPanelTab,
        contentHeight: CGFloat,
        maximumFeatureListHeight: CGFloat,
        isPanelVisible: Bool
    ) {
        guard
            self.selectedTab != selectedTab
                || abs(self.contentHeight - contentHeight) > 0.5
                || abs(self.maximumFeatureListHeight - maximumFeatureListHeight) > 0.5
                || self.isPanelVisible != isPanelVisible
        else {
            return
        }

        if !isPanelVisible {
            endLayoutEditing(notifyingChange: false)
        }
        objectWillChange.send()
        self.selectedTab = selectedTab
        self.contentHeight = contentHeight
        self.maximumFeatureListHeight = maximumFeatureListHeight
        self.isPanelVisible = isPanelVisible
    }

    func selectTab(_ tab: MenuBarPanelTab) {
        onTabSelection?(tab)
    }

    func deletePanel(id: String) -> String? { onPanelDeletion?(id) }

    func beginLayoutEditing(visibleItemCount: Int) {
        guard isPanelVisible, !isEditingLayout else { return }
        editingFeedback.reset()
        isEditingLayout = true
        onLayoutEditingChange?(true)
    }

    @discardableResult
    func preventDismissalWhileEditing() -> Bool {
        guard isEditingLayout else { return false }
        editingFeedback.request()
        return true
    }

    @discardableResult
    func endLayoutEditing() -> Bool {
        endLayoutEditing(notifyingChange: true)
    }

    @discardableResult
    private func endLayoutEditing(notifyingChange: Bool) -> Bool {
        guard isEditingLayout else { return false }
        isEditingLayout = false
        if notifyingChange {
            onLayoutEditingChange?(false)
        }
        return true
    }

}

struct MenuBarUnifiedPanelContent: View {
    let pluginHost: PluginHost
    let nativeMenuPresenter: MenuBarPanelMenuPresenter
    @ObservedObject var presentation: MenuBarPanelPresentationModel
    @ObservedObject var appUpdater: AppUpdater
    @ObservedObject var menuBarPanelThemeStore: MenuBarPanelThemeStore
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    @ObservedObject var model: MenuBarUnifiedPanelModel
    @StateObject private var layoutEditingSession = PanelLayoutEditingSession()
    @State private var iconPickerPanel: MenuBarPanelDefinition?
    @State private var showsComponentLibrary = false
    @State private var showsWidthPicker = false
    @State private var additionRevealRequest: UUID?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let onDismiss: () -> Void
    let onOpenUpdate: () -> Void
    let onOpenSettings: () -> Void
    let onPresentDiskCleanConfiguration: () -> Void
    let onPresentLaunchControlConfiguration: () -> Void

    var body: some View {
        let _ = runtimeLocale.revision
        let _ = presentation.revision
        let appearance = MenuBarPanelThemeResolver.appearance(for: colorScheme)
        let theme = MenuBarPanelThemeResolver.resolve(
            definition: menuBarPanelThemeStore.selectedDefinition(for: appearance),
            colorScheme: colorScheme,
            contrast: colorSchemeContrast
        )
        let contentBodyHeight = MenuBarPanelLayout.contentBodyHeight(
            forContentHeight: model.contentHeight
        )

        VStack(spacing: MenuBarPanelLayout.rootSpacing) {
            MenuBarPanelHeader(
                selectedTab: model.selectedTab,
                availableUpdateVersion: appUpdater.availableUpdateVersion,
                canEditLayout: true,
                isEditingLayout: model.isEditingLayout,
                onTabSelection: handleTabSelection,
                onEditLayout: toggleLayoutEditing,
                onOpenUpdate: presentUpdate,
                onOpenSettings: presentSettings,
                onQuit: { NSApplication.shared.terminate(nil) },
                panels: pluginHost.visibleMenuBarPanels,
                onMovePanel: pluginHost.moveMenuBarPanel,
                onChangeIcon: showIconPicker,
                itemDragSession: layoutEditingSession,
                onItemDragHover: selectPanelDuringDrag,
                onItemDrop: dropItemOnPanel,
                canUndoLayout: layoutEditingSession.canUndo(in: pluginHost, panelID: model.selectedTab.id),
                editingFeedback: model.editingFeedback,
                onUndoLayout: undoLayoutEdit
            )
            .frame(maxWidth: .infinity)
            .frame(height: MenuBarPanelLayout.headerHeight)
            .padding(.horizontal, MenuBarPanelLayout.outerPadding)
            .popover(item: $iconPickerPanel, arrowEdge: .bottom) { panel in
                iconPickerContent(panel)
            }

            MenuBarPanelContentSurface(contentBodyHeight: contentBodyHeight, panelWidth: model.contentWidth) {
                panelContent(contentBodyHeight: contentBodyHeight)
            }

            if model.isEditingLayout {
                MenuBarPanelEditingActionBar(
                    onAddComponents: { showsComponentLibrary = true },
                    canAddPanel: pluginHost.menuBarPanels.count < MenuBarPanelDefinition.maximumCount,
                    onAddPanel: addPanel,
                    selectedPanel: pluginHost.menuBarPanels.first { $0.id == model.selectedTab.id },
                    onDeletePanel: { id in
                        let error = model.deletePanel(id: id)
                        if error == nil { layoutEditingSession.reset() }
                        return error
                    }
                ) {
                    panelWidthControl
                }
                .frame(height: MenuBarPanelLayout.editingActionBarHeight)
                .popover(isPresented: $showsComponentLibrary, arrowEdge: .trailing) {
                    PanelComponentLibrary(pluginHost: pluginHost, panelID: model.selectedTab.id) { entry in
                        guard pluginHost.addPanelItem(entry, to: model.selectedTab.id) else { return false }
                        layoutEditingSession.reset()
                        additionRevealRequest = UUID()
                        return true
                    }
                }
            }
        }
        .padding(.top, MenuBarPanelLayout.panelTopPadding)
        .padding(.bottom, model.isEditingLayout
            ? MenuBarPanelLayout.editingPanelBottomPadding : MenuBarPanelLayout.panelBottomPadding)
        .frame(
            width: model.contentWidth,
            height: MenuBarPanelLayout.panelHeight(
                forContentHeight: model.contentHeight,
                showsEditingActionBar: model.isEditingLayout
            ),
            alignment: .topLeading
        )
        .background {
            theme.surfaces.panel
        }
        .foregroundStyle(theme.text.primary)
        .tint(theme.accent)
        .id(runtimeLocale.revision)
        .environment(\.menuBarPanelSurfaceWidth, model.contentWidth - MenuBarPanelLayout.outerPadding * 2)
        .environmentObject(presentation)
        .environmentObject(nativeMenuPresenter)
        .environment(\.menuBarPanelTheme, theme)
        .environment(\.pluginComponentTheme, theme.componentTheme)
        .environment(\.locale, PluginRuntimeLocalization.locale)
        .environment(\.layoutDirection, layoutDirection)
        .onChange(of: model.isEditingLayout) { _, isEditing in
            if !isEditing {
                iconPickerPanel = nil
                showsComponentLibrary = false
                showsWidthPicker = false
                additionRevealRequest = nil
                layoutEditingSession.reset()
            }
        }
        .onChange(of: model.isPanelVisible) { _, visible in
            if !visible { showsWidthPicker = false }
        }
        .onChange(of: model.selectedTab) { _, _ in additionRevealRequest = nil }
        .onChange(of: pluginHost.menuBarPanels.map(\.id)) { _, ids in
            if let iconPickerPanel, !ids.contains(iconPickerPanel.id) {
                self.iconPickerPanel = nil
            }
        }
    }

    private var panelWidthControl: some View {
        let columnTitle = MenuBarPanelWidth.columnTitle(MenuBarPanelWidth.columns(
            forSurfaceWidth: model.contentWidth - MenuBarPanelLayout.outerPadding * 2))
        return MenuBarPanelEditingButton(title: MenuBarPanelWidth.title, emphasis: .standard) {
            showsWidthPicker = true
        }
        .help(MenuBarPanelWidth.title)
        .accessibilityLabel(MenuBarPanelWidth.title)
        .accessibilityValue(columnTitle)
        .accessibilityIdentifier("panel.width")
        .popover(isPresented: $showsWidthPicker, arrowEdge: .bottom) {
            if model.isEditingLayout {
                PanelWidthPicker(preferredWidth: pluginHost.preferredMenuBarPanelWidth,
                    maximumWidth: model.maximumWidth, onCommit: { width in
                        guard model.isEditingLayout else { return }
                        if let change = pluginHost.setMenuBarPanelWidth(width) {
                            layoutEditingSession.didSaveLayoutChange(change)
                        }
                    })
                .background(MenuWindowAccessor { window in
                    if let window { MenuBarPanelWindowRegistry.markEditingPopover(window) }
                }.allowsHitTesting(false))
                .onExitCommand { showsWidthPicker = false }
            }
        }
    }

    private func iconPickerContent(_ panel: MenuBarPanelDefinition) -> some View {
        PanelSymbolPicker(selected: panel.systemImage) { symbol in
            if var updated = pluginHost.menuBarPanels.first(where: { $0.id == panel.id }) {
                updated.systemImage = symbol
                pluginHost.updateMenuBarPanel(updated)
            }
            iconPickerPanel = nil
        }
        .background {
            MenuWindowAccessor { window in
                if let window { MenuBarPanelWindowRegistry.markEditingPopover(window) }
            }.allowsHitTesting(false)
        }
        .onExitCommand { iconPickerPanel = nil }
    }

    private var layoutDirection: LayoutDirection {
        PluginRuntimeLocalization.locale.language.characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }

    private var visibleItemCount: Int {
        pluginHost.panelEntries(in: model.selectedTab.id).count
    }

    @ViewBuilder
    private func panelContent(contentBodyHeight: CGFloat) -> some View {
        if model.isEditingLayout {
            PanelLayoutEditor(
                pluginHost: pluginHost,
                panelID: model.selectedTab.id,
                onDismiss: onDismiss,
                session: layoutEditingSession,
                revealBottomRequest: additionRevealRequest
            )
            .id(model.selectedTab)
            .frame(height: contentBodyHeight)
        } else {
            ConfiguredMenuBarPanelsContent(
                pluginHost: pluginHost, model: model, contentBodyHeight: contentBodyHeight,
                onDismiss: onDismiss, onOpenSettings: onOpenSettings,
                onEditLayout: toggleLayoutEditing,
                onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
                onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration
            )
        }
    }

    private func presentSettings() {
        onOpenSettings()
        onDismiss()
    }

    private func presentUpdate() {
        onOpenUpdate()
        onDismiss()
    }

    private func handleTabSelection(_ tab: MenuBarPanelTab) {
        guard model.selectedTab != tab else {
            return
        }

        layoutEditingSession.reset()
        model.selectTab(tab)
    }

    private func selectPanelDuringDrag(_ id: String) {
        guard model.isEditingLayout, layoutEditingSession.validateSource(in: pluginHost),
              pluginHost.visibleMenuBarPanels.contains(where: { $0.id == id }) else { return }
        layoutEditingSession.enterPanel(id, ids: pluginHost.panelEntries(in: id).map(\.id))
        if model.selectedTab.id != id { model.selectTab(MenuBarPanelTab(id: id)) }
    }

    private func dropItemOnPanel(_ id: String) -> Bool {
        guard model.isEditingLayout, layoutEditingSession.validateSource(in: pluginHost) else { return false }
        if id == layoutEditingSession.sourcePanelID {
            layoutEditingSession.cancel()
            return true
        }
        selectPanelDuringDrag(id)
        guard layoutEditingSession.validate(in: pluginHost, panelID: id) else { return false }
        let ids = pluginHost.panelEntries(in: id).map(\.id)
        layoutEditingSession.preview(offset: ids.count, ids: ids)
        guard let move = layoutEditingSession.finish(ids: ids) else { return false }
        return layoutEditingSession.commit(move, in: pluginHost, panelID: id)
    }

    private func addPanel() {
        guard let id = pluginHost.addMenuBarPanel() else { return }
        handleTabSelection(MenuBarPanelTab(id: id))
        showIconPicker(id)
    }

    private func showIconPicker(_ id: String) {
        guard let panel = pluginHost.menuBarPanels.first(where: { $0.id == id }) else { return }
        iconPickerPanel = panel
    }

    private func toggleLayoutEditing() {
        if model.isEditingLayout {
            model.endLayoutEditing()
            layoutEditingSession.reset()
            return
        }

        layoutEditingSession.reset()
        model.beginLayoutEditing(visibleItemCount: visibleItemCount)
    }

    private func undoLayoutEdit() {
        layoutEditingSession.undo(in: pluginHost, panelID: model.selectedTab.id)
    }

}

private struct MenuBarPanelContentSurface<Content: View>: View {
    let contentBodyHeight: CGFloat
    let panelWidth: CGFloat
    private let content: Content

    init(contentBodyHeight: CGFloat, panelWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.contentBodyHeight = contentBodyHeight
        self.panelWidth = panelWidth
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                width: panelWidth - MenuBarPanelLayout.outerPadding * 2,
                height: contentBodyHeight,
                alignment: .topLeading
            )
            .padding(.top, MenuBarPanelLayout.contentTopPadding)
            .padding(.horizontal, MenuBarPanelLayout.outerPadding)
            .padding(.bottom, MenuBarPanelLayout.contentBottomPadding)
            .frame(
                width: panelWidth,
                height: contentBodyHeight + MenuBarPanelLayout.contentVerticalPadding,
                alignment: .topLeading
            )
    }
}

struct MenuBarPanelHeader: View {
    let selectedTab: MenuBarPanelTab
    let availableUpdateVersion: String?
    let canEditLayout: Bool
    let isEditingLayout: Bool
    let onTabSelection: (MenuBarPanelTab) -> Void
    let onEditLayout: () -> Void
    let onOpenUpdate: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var panels: [MenuBarPanelDefinition] = MenuBarPanelDefinition.defaults
    var onMovePanel: (String, Int) -> Void = { _, _ in }
    var onChangeIcon: (String) -> Void = { _ in }
    var itemDragSession: PanelLayoutEditingSession? = nil
    var onItemDragHover: (String) -> Void = { _ in }
    var onItemDrop: (String) -> Bool = { _ in false }
    let canUndoLayout: Bool
    let editingFeedback: MenuBarPanelEditingFeedback
    let onUndoLayout: () -> Void

    var body: some View {
        if isEditingLayout {
            MenuBarPanelEditingControls(canUndoLayout: canUndoLayout, feedback: editingFeedback,
                onUndoLayout: onUndoLayout, onDone: onEditLayout) {
                    navigation
                }
        } else {
            ZStack {
                navigation.fixedSize()
                HStack(spacing: MenuBarPanelLayout.headerAccessorySpacing) {
                    Spacer(minLength: 8)
                    MenuBarPanelIconButton(
                        systemImage: "gearshape",
                        accessibilityTitle: AppL10n.settings("settings.window.title", defaultValue: "设置"),
                        action: onOpenSettings
                    )
                    MenuBarPanelOverflowMenu(
                        canEditLayout: canEditLayout,
                        availableUpdateVersion: availableUpdateVersion,
                        onEditLayout: onEditLayout,
                        onOpenUpdate: onOpenUpdate,
                        onQuit: onQuit
                    )
                }
            }
        }
    }

    private var navigation: some View {
        MenuBarPanelTabs(
            panels: panels, selectedPanelID: selectedTab.id,
            onSelect: { onTabSelection(MenuBarPanelTab(id: $0)) },
            isEditing: isEditingLayout, onMove: onMovePanel,
            onChangeIcon: onChangeIcon,
            itemDragSession: itemDragSession, onItemDragHover: onItemDragHover, onItemDrop: onItemDrop
        )
    }
}

/// Only the Done button subscribes, keeping attention feedback out of panel layout updates.
@MainActor
final class MenuBarPanelEditingFeedback {
    let requests = PassthroughSubject<Void, Never>()
    private var lastRequest: ContinuousClock.Instant?

    func request(at instant: ContinuousClock.Instant = .now) {
        // Native dismissal and the outside-click coordinator can report the same attempt.
        guard lastRequest.map({ $0.duration(to: instant) >= .milliseconds(600) }) ?? true else { return }
        lastRequest = instant
        requests.send()
    }

    func reset() { lastRequest = nil }
}

struct MenuBarPanelEditingControls<Navigation: View>: View {
    let canUndoLayout: Bool
    let feedback: MenuBarPanelEditingFeedback
    let onUndoLayout: () -> Void
    let onDone: () -> Void
    @ViewBuilder let navigation: Navigation

    var body: some View {
        MenuBarPanelEditingHeaderLayout {
            MenuBarPanelEditingButton(title: PanelLayoutCopy.undo, emphasis: .standard,
                                      isEnabled: canUndoLayout, action: onUndoLayout)
                .accessibilityIdentifier("panel.layout.undo")
            navigation
            MenuBarPanelEditingDoneButton(feedback: feedback, action: onDone)
        }
        .controlSize(.mini)
    }
}

/// Keep the tabs centered while giving both actions their own layout space.
private struct MenuBarPanelEditingHeaderLayout: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let side = max(sizes[0].width, sizes[2].width)
        return CGSize(width: proposal.width ?? sizes[1].width + (side + spacing) * 2,
                      height: proposal.height ?? sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        let navigationWidth = max(0, bounds.width - (max(leading.width, trailing.width) + spacing) * 2)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(leading))
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(width: navigationWidth, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(trailing))
    }
}

struct MenuBarPanelEditingActionBar<WidthControl: View>: View {
    var onAddComponents: () -> Void = {}
    var canAddPanel = true
    var onAddPanel: () -> Void = {}
    var selectedPanel: MenuBarPanelDefinition?
    var onDeletePanel: (String) -> String? = { _ in nil }
    @ViewBuilder let widthControl: WidthControl
    @State private var panelToDelete: MenuBarPanelDefinition?

    var body: some View {
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                addComponentsButton(compact: false)
                addComponentsButton(compact: true)
            }
            widthControl
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                panelActions(compact: false)
                panelActions(compact: true)
            }
        }
        .padding(.horizontal, MenuBarPanelLayout.outerPadding)
        .padding(.vertical, MenuBarPanelLayout.editingActionBarVerticalPadding)
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .popover(item: $panelToDelete, arrowEdge: .trailing) { panel in
            // Retain the addressed panel until the confirmation finishes closing.
            MenuBarPanelDeleteConfirmation(panel: panel, onCancel: { panelToDelete = nil }) {
                let error = onDeletePanel(panel.id)
                if error == nil { panelToDelete = nil }
                return error
            }
            .controlSize(.regular)
            .onExitCommand { panelToDelete = nil }
        }
        .onChange(of: selectedPanel?.id) { _, _ in panelToDelete = nil }
    }

    private func addComponentsButton(compact: Bool) -> some View {
        MenuBarPanelEditingButton(title: FeatureL10n.string("添加组件"),
                                  systemImage: compact ? "square.grid.2x2" : nil,
                                  emphasis: .standard, action: onAddComponents)
            .labelStyle(.iconOnly)
            .help(FeatureL10n.string("添加组件"))
            .accessibilityIdentifier("panel.layout.add")
    }

    private func panelActions(compact: Bool) -> some View {
        HStack(spacing: 6) {
            MenuBarPanelEditingButton(title: FeatureL10n.string("删除面板"),
                                      systemImage: compact ? "trash" : nil, emphasis: .standard,
                                      role: .destructive, isEnabled: selectedPanel?.isDefault == false) {
                panelToDelete = selectedPanel
            }
            .help(FeatureL10n.string("删除面板"))
            .accessibilityIdentifier("menuBarPanel.delete")
            MenuBarPanelEditingButton(title: FeatureL10n.string("添加面板"),
                                      systemImage: compact ? "plus.rectangle" : nil, emphasis: .standard,
                                      isEnabled: canAddPanel, action: onAddPanel)
                .help(FeatureL10n.string("添加面板"))
                .accessibilityIdentifier("menuBarPanel.add")
        }
        .labelStyle(.iconOnly)
    }
}

private struct MenuBarPanelEditingDoneButton: View {
    private struct FeedbackFrame {
        var offset: CGFloat = 0
        var highlight: Double = 0
    }

    let feedback: MenuBarPanelEditingFeedback
    let action: () -> Void
    @State private var feedbackTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MenuBarPanelEditingButton(title: PanelLayoutCopy.done, emphasis: .prominent, action: action)
            .accessibilityIdentifier("panel.layout.edit")
            .help(PanelLayoutCopy.finishEditingHint)
            .accessibilityHint(PanelLayoutCopy.finishEditingHint)
            .keyframeAnimator(initialValue: FeedbackFrame(), trigger: feedbackTrigger) { [reduceMotion] content, frame in
                content
                    .offset(x: reduceMotion ? 0 : frame.offset)
                    .brightness(reduceMotion ? frame.highlight * 0.14 : 0)
            } keyframes: { _ in
                KeyframeTrack(\.offset) {
                    CubicKeyframe(-3, duration: 0.06)
                    CubicKeyframe(3, duration: 0.08)
                    CubicKeyframe(-2, duration: 0.08)
                    CubicKeyframe(2, duration: 0.08)
                    CubicKeyframe(0, duration: 0.10)
                }
                KeyframeTrack(\.highlight) {
                    LinearKeyframe(1, duration: 0.08)
                    LinearKeyframe(1, duration: 0.20)
                    LinearKeyframe(0, duration: 0.12)
                }
            }
            .onReceive(feedback.requests) {
                feedbackTrigger += 1
                NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                    userInfo: [.announcement: PanelLayoutCopy.finishEditingHint,
                               .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
    }
}

struct MenuBarPanelOverflowMenu: View {
    let canEditLayout: Bool
    let availableUpdateVersion: String?
    let onEditLayout: () -> Void
    let onOpenUpdate: () -> Void
    let onQuit: () -> Void
    @State private var isHovered = false
    @Environment(\.menuBarPanelTheme) private var theme

    var body: some View {
        MenuBarPanelMenu(makeMenu: makeMenu) {
            MenuBarPanelIconLabel(
                systemImage: "ellipsis.circle",
                showsNotificationDot: availableUpdateVersion != nil,
                isHovered: isHovered
            )
        }
        .buttonStyle(.plain)
        .tint(theme.text.secondary)
        .help(availabilityLabel(AppL10n.search("search.footer.actions", defaultValue: "操作")))
        .accessibilityLabel(availabilityLabel(AppL10n.search("search.footer.actions", defaultValue: "操作")))
        .accessibilityIdentifier("panel.actions.menu")
        .onHover { isHovered = $0 }
    }

    private var updateAccessibilityTitle: String {
        availabilityLabel(AppL10n.settings("about.update.check", defaultValue: "检查更新"))
    }

    private func availabilityLabel(_ title: String) -> String {
        guard let version = availableUpdateVersion else { return title }
        let availability = AppL10n.settingsFormat("about.update.headline.availableFormat",
            defaultValue: "检测到新版本 %@", version)
        return "\(title)：\(availability)"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if canEditLayout {
            menu.addItem(MenuBarPanelMenuItem(PanelLayoutCopy.edit,
                image: NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil),
                identifier: "panel.layout.edit", action: onEditLayout))
            menu.addItem(.separator())
        }
        let update = MenuBarPanelMenuItem(
            AppL10n.settings("about.update.check", defaultValue: "检查更新"),
            image: MenuBarPanelUpdateIndicator.menuImage(showsBadge: availableUpdateVersion != nil, theme: theme),
            identifier: "panel.update.check", action: onOpenUpdate)
        update.setAccessibilityLabel(updateAccessibilityTitle)
        menu.addItem(update)
        menu.addItem(MenuBarPanelMenuItem(AppL10n.settings("app.quit", defaultValue: "退出"),
            image: NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right", accessibilityDescription: nil),
            identifier: "panel.quit", action: onQuit))
        return menu
    }
}

struct MenuBarPanelEditingButton: View {
    let title: String
    var systemImage: String? = nil
    let emphasis: MenuBarPanelEditingButtonStyle.Emphasis
    var role: ButtonRole? = nil
    var isEnabled = true
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(
            MenuBarPanelEditingButtonStyle(
                emphasis: emphasis,
                isHovered: isHovered
            )
        )
        .disabled(!isEnabled)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { isHovered = isEnabled && $0 }
    }
}

struct MenuBarPanelEditingButtonStyle: ButtonStyle {
    enum Emphasis {
        case standard
        case prominent
    }

    let emphasis: Emphasis
    let isHovered: Bool
    @Environment(\.controlSize) private var controlSize
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.menuBarPanelTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: controlSize == .mini || controlSize == .small ? 11 : 12,
                          weight: emphasis == .prominent ? .semibold : .medium))
            .foregroundStyle(foregroundColor(role: configuration.role))
            .padding(.horizontal, controlSize == .small || controlSize == .mini ? 8 : 12)
            .frame(minWidth: controlSize == .mini ? 40 : (controlSize == .small ? 42 : 64))
            .frame(height: controlSize == .mini ? MenuBarPanelLayout.headerAccessoryHeight : MenuBarPanelLayout.editingButtonHeight)
            .background {
                RoundedRectangle(cornerRadius: MenuBarPanelLayout.cornerRadius, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed, role: configuration.role))
                    .brightness(backgroundBrightness(isPressed: configuration.isPressed))
            }
            .overlay {
                if emphasis == .standard {
                    RoundedRectangle(cornerRadius: MenuBarPanelLayout.cornerRadius, style: .continuous)
                        .strokeBorder(
                            theme.surfaces.separator.opacity(isEnabled ? 0.8 : 0.45),
                            lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
                        )
                }
            }
            .contentShape(
                RoundedRectangle(cornerRadius: MenuBarPanelLayout.cornerRadius, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private func foregroundColor(role: ButtonRole?) -> Color {
        guard isEnabled else { return theme.text.disabled }
        if emphasis == .prominent { return role == .destructive ? .white : theme.text.onAccent }
        return role == .destructive ? theme.status.critical : theme.text.primary
    }

    private func backgroundColor(isPressed: Bool, role: ButtonRole?) -> Color {
        guard isEnabled else { return theme.surfaces.control.opacity(0.6) }
        switch emphasis {
        case .standard:
            if isPressed { return theme.surfaces.selected }
            return isHovered ? theme.surfaces.hover : theme.surfaces.control
        case .prominent:
            return role == .destructive ? theme.status.critical : theme.prominentControlFill
        }
    }

    private func backgroundBrightness(isPressed: Bool) -> Double {
        guard isEnabled, emphasis == .prominent else { return 0 }
        if isPressed { return -0.06 }
        return isHovered ? 0.04 : 0
    }
}

private struct MenuBarPanelIconButton: View {
    let systemImage: String
    let accessibilityTitle: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            MenuBarPanelIconLabel(
                systemImage: systemImage,
                isHovered: isHovered
            )
        }
        .buttonStyle(.plain)
        .help(accessibilityTitle)
        .accessibilityLabel(accessibilityTitle)
        .onHover { isHovered = $0 }
    }
}

private struct MenuBarPanelIconLabel: View {
    let systemImage: String
    var showsNotificationDot = false
    let isHovered: Bool
    @Environment(\.menuBarPanelTheme) private var theme

    var body: some View {
        Image(systemName: PluginSystemImage.resolvedName(systemImage))
            .font(.system(size: MenuBarPanelLayout.tabIconSize, weight: .semibold))
            .foregroundStyle(theme.text.secondary)
            .overlay(alignment: .bottomTrailing) {
                if showsNotificationDot {
                    Circle()
                        .fill(theme.status.warning)
                        .frame(width: MenuBarPanelUpdateIndicator.diameter, height: MenuBarPanelUpdateIndicator.diameter)
                        .overlay {
                            Circle()
                                .stroke(theme.surfaces.panel, lineWidth: 1)
                        }
                        .offset(x: 3, y: 3)
                }
            }
            .frame(width: MenuBarPanelLayout.headerAccessoryWidth, height: MenuBarPanelLayout.tabItemHeight)
            .background {
                Capsule()
                    .fill(isHovered ? theme.surfaces.hover : Color.clear)
            }
            .frame(width: MenuBarPanelLayout.headerAccessoryWidth, height: MenuBarPanelLayout.headerAccessoryHeight)
            .contentShape(Rectangle())
    }
}

private enum MenuBarPanelUpdateIndicator {
    static let diameter: CGFloat = 6

    static func menuImage(showsBadge: Bool, theme: MenuBarPanelThemeStyle) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(theme.text.secondary)]))
        let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage(size: NSSize(width: 16, height: 16))
        guard showsBadge else { return symbol }
        let warningColor = NSColor(theme.status.warning)
        let outlineColor = NSColor(theme.surfaces.panel)
        let offset = diameter / 2
        let size = NSSize(width: symbol.size.width + offset, height: symbol.size.height + offset)
        // Native menus consume an NSImage; compose the badge into it to preserve its color.
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(origin: CGPoint(x: 0, y: offset), size: symbol.size))
            let badge = NSRect(x: size.width - diameter, y: 0, width: diameter, height: diameter)
            warningColor.setFill()
            NSBezierPath(ovalIn: badge).fill()
            outlineColor.setStroke()
            let outline = NSBezierPath(ovalIn: badge.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
