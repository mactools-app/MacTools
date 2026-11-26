import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

enum MenuBarStatusItemInvocation: Equatable {
    case featurePanel
    case componentPanel

    static func invocation(
        for event: NSEvent?
    ) -> MenuBarStatusItemInvocation {
        // Option+left-click always triggers the right-click action.
        let isSecondary: Bool = {
            guard let event else { return false }
            let isLeftClick = event.type == .leftMouseDown || event.type == .leftMouseUp
            if isLeftClick, event.modifierFlags.contains(.option) {
                return true
            }
            return event.type == .rightMouseDown || event.type == .rightMouseUp
        }()

        return isSecondary ? .featurePanel : .componentPanel
    }
}

enum MenuBarStatusItemPresentationAction: Equatable {
    case composeActionInput(ActionInputItem)
    case presentSettings(SettingsPresentationRequest)
    case toggleCommandPalette
    case toggleComponentPanel
    case toggleFeaturePanel
    case showComponentPanel
    case showFeaturePanel
    case showUnifiedSearch

    init(request: AppPresentationRequest) {
        switch request {
        case let .composeActionInput(item):
            self = .composeActionInput(item)
        case let .settings(settingsRequest):
            self = .presentSettings(settingsRequest)
        case .toggleCommandPalette:
            self = .toggleCommandPalette
        case .toggleDashboard:
            self = .toggleComponentPanel
        case .toggleFeaturePanel:
            self = .toggleFeaturePanel
        case .showDashboard:
            self = .showComponentPanel
        case .showFeaturePanel:
            self = .showFeaturePanel
        case .showUnifiedSearch:
            self = .showUnifiedSearch
        }
    }
}

struct MenuBarGlobalMouseEvent: Equatable, Sendable {
    let screenX: Double
    let screenY: Double
}

enum MenuBarGlobalMouseEventPolicy {
    static func isStatusItemClick(
        for event: MenuBarGlobalMouseEvent,
        buttonFrame: NSRect?
    ) -> Bool {
        let location = NSPoint(x: event.screenX, y: event.screenY)
        guard let buttonFrame, !buttonFrame.isEmpty else { return false }
        return buttonFrame.contains(location)
    }
}

@MainActor
final class MenuBarStatusItemController: NSObject {
    private let pluginHost: PluginHost
    private let windowRouter: AppWindowRouter
    private let iconSettings: MenuBarIconSettings
    private let appUpdater: AppUpdater
    private var statusItem: NSStatusItem
    private var panelPresenter: MenuBarPanelPresenter!
    private var cancellables: Set<AnyCancellable> = []
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?
    private var dismissalGeneration: UInt = 0
    private var appearanceObserver: NSObjectProtocol?
    private var appTerminationObserver: NSObjectProtocol?
    private var statusItemWindowMoveObserver: NSObjectProtocol?
    private var animationTimer: DispatchSourceTimer?
    private var animationFrames: [NSImage] = []
    private var animationFrameIndex = 0
    private var animationFrameDuration: TimeInterval = 1.0 / MenuBarIconProcessing.animationFramesPerSecond
    private var currentFallbackPayload: MenuBarIconImagePayload?
    private let iconPresentation = MenuBarStatusIconPresentation()
    private var isIconUpdateScheduled = false
    private var iconAppearanceObserver: MenuBarIconAppearanceObserverView?

    init(
        pluginHost: PluginHost,
        windowRouter: AppWindowRouter,
        appUpdater: AppUpdater,
        iconSettings: MenuBarIconSettings,
        menuBarPanelThemeStore: MenuBarPanelThemeStore = .shared
    ) {
        self.pluginHost = pluginHost
        self.windowRouter = windowRouter
        self.iconSettings = iconSettings
        self.appUpdater = appUpdater
        MenuBarControlItemDefaults.prepareVisibleControlItem()
        PluginPresentationSafety.prepareForWindowOrdering()
        self.statusItem = NSStatusBar.system.statusItem(withLength: 0)
        self.statusItem.autosaveName = MenuBarControlItemDefaults.visibleAutosaveName
        super.init()
        panelPresenter = MenuBarPanelPresenter(
            pluginHost: pluginHost,
            appUpdater: appUpdater,
            menuBarPanelThemeStore: menuBarPanelThemeStore,
            onDismiss: { [weak self] in
                self?.requestPanelClose()
            },
            onOpenUpdate: { [weak self] in
                self?.windowRouter.presentSettings(.appUpdate)
            },
            onOpenSettings: { [weak self] in
                self?.windowRouter.showSettings()
            },
            onOpenUnifiedSearch: { [weak self] in
                self?.windowRouter.showCommandPalette()
            },
            onPresentDiskCleanConfiguration: { [weak self] in
                self?.pluginHost.presentPluginSettings(pluginID: "disk-clean")
            },
            onPresentLaunchControlConfiguration: { [weak self] in
                self?.pluginHost.presentPluginSettings(pluginID: "launch-control")
            },
            onAllPanelsClosed: { [weak self] in
                self?.removeDismissMonitorsIfNeeded()
            }
        )
        observeStatusItemPositionPersistence()
        configureStatusItem()
        observePluginHost()
        observeIconSettings()
        pluginHost.menuBarIconCoordinator.onPrimaryIconChange = { [weak self] in
            self?.updateStatusIcon()
        }
        updateStatusIcon()
        pluginHost.resetStatusItemPosition = { [weak self] in
            self?.resetStatusItemPosition()
        }
        pluginHost.statusItemButtonFrameProvider = { [weak self] in
            self?.statusItemButtonScreenRect()
        }
        pluginHost.appMenuBarIconVisibilityHandler = { [weak self] isVisible in
            self?.applyAppMenuBarIconVisibility(isVisible)
        }
        windowRouter.setProgrammaticSettingsPresentationAction { [weak self] in
            self?.requestPanelClose()
        }
        // This controller is the sole production owner of app-level presentation routing.
        pluginHost.menuBarPanelPresentationHandler = { [weak self] id, toggle in
            guard let self else { return }
            if self.usesFallbackPanelAnchor, let anchorRect = self.fallbackPanelAnchorRect {
                self.panelPresenter.showPanel(id: id, toggle: toggle, anchorRect: anchorRect)
            } else if let button = self.statusItem.button {
                self.panelPresenter.showPanel(id: id, toggle: toggle, relativeTo: button)
            } else {
                return
            }
            self.handlePresentationResult()
        }
        pluginHost.anchoredMenuBarPanelPresentationHandler = { [weak self] request, pluginID, storage in
            guard let self else { return false }
            let style: NotchHoverPanelStyle = pluginID == NotchHoverPanelStyle.pluginID
                ? .stored(in: storage)
                : .classic
            let presented = self.panelPresenter.presentPanelBelowAnchor(
                panelID: request.panelID,
                anchorRect: request.anchorRect,
                style: style
            )
            if presented { self.handlePresentationResult() }
            return presented
        }
        pluginHost.anchoredMenuBarPanelDismissalHandler = { [weak self] animated in
            self?.panelPresenter.dismissPanelBelowAnchor(animated: animated) ?? false
        }
        pluginHost.anchoredMenuBarPanelFrameProvider = { [weak self] in
            self?.panelPresenter.presentedPanelScreenFrame
        }
        pluginHost.anchoredMenuBarPanelVisibilityProvider = { [weak self] in
            self?.panelPresenter.isAnyPanelShown ?? false
        }
        pluginHost.appPresentationHandler = { [weak self, weak windowRouter] request in
            switch MenuBarStatusItemPresentationAction(request: request) {
            case let .composeActionInput(item):
                windowRouter?.showCommandPalette(input: item)
            case let .presentSettings(settingsRequest):
                windowRouter?.presentSettings(settingsRequest)
            case .toggleCommandPalette:
                windowRouter?.toggleCommandPalette()
            case .toggleComponentPanel:
                self?.toggleDashboard()
            case .toggleFeaturePanel:
                self?.toggleFeaturePanel()
            case .showComponentPanel:
                self?.showDashboard()
            case .showFeaturePanel:
                self?.showFeaturePanel()
            case .showUnifiedSearch:
                windowRouter?.showCommandPalette()
            }
        }
    }

    private func statusItemButtonScreenRect() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    isolated deinit {
        animationTimer?.cancel()
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
        if let appTerminationObserver {
            NotificationCenter.default.removeObserver(appTerminationObserver)
        }
        if let statusItemWindowMoveObserver {
            NotificationCenter.default.removeObserver(statusItemWindowMoveObserver)
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
    }

    func dismissPanels() {
        panelPresenter.dismissPanels()
        if !panelPresenter.isAnyPanelShown {
            removeDismissMonitorsIfNeeded()
        }
    }

    func showDashboard() {
        if usesFallbackPanelAnchor, let anchorRect = fallbackPanelAnchorRect {
            panelPresenter.showDashboard(anchorRect: anchorRect)
            handlePresentationResult()
            return
        }

        guard let button = statusItem.button else {
            AppLog.pluginHost.error("Cannot show Dashboard because the status item button is unavailable")
            return
        }

        panelPresenter.showDashboard(relativeTo: button)
        handlePresentationResult()
    }

    func showFeaturePanel() {
        if usesFallbackPanelAnchor, let anchorRect = fallbackPanelAnchorRect {
            panelPresenter.showFeaturePanel(anchorRect: anchorRect)
            handlePresentationResult()
            return
        }

        guard let button = statusItem.button else {
            AppLog.pluginHost.error("Cannot show Feature Panel because the status item button is unavailable")
            return
        }

        panelPresenter.showFeaturePanel(relativeTo: button)
        handlePresentationResult()
    }

    func toggleDashboard() {
        if usesFallbackPanelAnchor, let anchorRect = fallbackPanelAnchorRect {
            panelPresenter.toggleComponentPanel(anchorRect: anchorRect)
            handlePresentationResult()
            return
        }

        guard let button = statusItem.button else {
            AppLog.pluginHost.error("Cannot toggle Dashboard because the status item button is unavailable")
            return
        }

        toggleComponentPanel(relativeTo: button)
    }

    func toggleFeaturePanel() {
        if usesFallbackPanelAnchor, let anchorRect = fallbackPanelAnchorRect {
            panelPresenter.toggleFeaturePanel(anchorRect: anchorRect)
            handlePresentationResult()
            return
        }

        guard let button = statusItem.button else {
            AppLog.pluginHost.error("Cannot toggle Feature Panel because the status item button is unavailable")
            return
        }

        toggleFeaturePanel(relativeTo: button)
    }

    private var usesFallbackPanelAnchor: Bool {
        !statusItem.isVisible
    }

    /// Approximate anchor at the menu-bar end for surfaces that normally point
    /// at the status item, used while the main icon is hidden by a plugin.
    private var fallbackPanelAnchorRect: NSRect? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return NSRect(
            x: screen.frame.maxX - 160,
            y: screen.frame.maxY - menuBarHeight,
            width: 160,
            height: menuBarHeight
        )
    }

    private func applyAppMenuBarIconVisibility(_ isVisible: Bool) {
        statusItem.isVisible = isVisible
    }

    private func requestPanelClose() {
        dismissPanels()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemAction(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.toolTip = AppMetadata.appName
        statusItem.length = NSStatusItem.variableLength
        button.imagePosition = .imageOnly
        iconPresentation.reset()

        iconAppearanceObserver?.onChange = nil
        iconAppearanceObserver?.removeFromSuperview()
        let observer = MenuBarIconAppearanceObserverView(frame: .zero)
        observer.setAccessibilityElement(false)
        observer.onChange = { [weak self] in
            self?.scheduleStatusIconUpdate()
        }
        button.addSubview(observer)
        iconAppearanceObserver = observer

        // MacTools intentionally uses one target/action route on every OS.
        // AppKit's expanded-interface delegate models one undifferentiated
        // interface and carries no NSEvent, so it cannot represent the app's
        // distinct left- and right-click panels without a competing owner.
    }

    private func observePluginHost() {
        pluginHost.automationController.$activeRunIDs
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        // Observe the version itself so the tooltip follows version changes;
        // the icon image is only redrawn when availability flips.
        appUpdater.$availableUpdateVersion
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleStatusIconUpdate()
            }
            .store(in: &cancellables)
    }

    private func observeIconSettings() {
        iconSettings.$settingsRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleStatusIconUpdate() }
        }
    }

    private func scheduleStatusIconUpdate() {
        guard !isIconUpdateScheduled else { return }
        isIconUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isIconUpdateScheduled = false
            updateStatusIcon()
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let context = PluginMenuBarIconRenderContext(
            pointSize: CGSize(width: 24, height: 24),
            displayScale: button.window?.backingScaleFactor ?? 2,
            appearance: button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        )
        if let snapshot = pluginHost.menuBarIconCoordinator.snapshot(context: context) {
            let key = MenuBarStatusIconPresentation.Key(
                source: .plugin(
                    generation: pluginHost.menuBarIconCoordinator.primaryIconGeneration,
                    revision: snapshot.revision
                ),
                context: context,
                runningAutomationCount: pluginHost.automationController.activeRunIDs.count,
                hasAvailableUpdate: hasAvailableUpdate
            )
            if iconPresentation.present(
                on: button, key: key,
                tooltip: "\(statusTooltip)\n\(snapshot.tooltip)",
                accessibilityDescription: "\(statusTooltip)\n\(snapshot.accessibilityDescription)",
                makeImage: {
                    guard let image = snapshot.image.copy() as? NSImage else { return nil }
                    // Never mutate a provider's shared image.
                    image.size = context.pointSize
                    image.isTemplate = snapshot.isTemplate
                    return statusImage(image, isTemplate: snapshot.isTemplate, appearance: context.appearance)
                }
            ) {
                currentFallbackPayload = nil
                animationTimer?.cancel()
                animationTimer = nil
                animationFrames = []
                return
            }
        }
        let payload = iconSettings.imagePayload(for: button.effectiveAppearance)
        if currentFallbackPayload != payload {
            currentFallbackPayload = payload
            configureAnimationIfNeeded(payload)
        }
        iconPresentation.present(
            on: button,
            key: .init(source: .fallback(payload: payload, frameIndex: animationFrameIndex),
                       context: context, runningAutomationCount: pluginHost.automationController.activeRunIDs.count,
                       hasAvailableUpdate: hasAvailableUpdate),
            tooltip: statusTooltip,
            accessibilityDescription: statusTooltip
        ) {
            let frame = animationFrames.indices.contains(animationFrameIndex) ? animationFrames[animationFrameIndex] : payload.image
            frame.isTemplate = payload.isTemplate
            return statusImage(frame, isTemplate: payload.isTemplate, appearance: context.appearance)
        }
    }

    private var automationActivityTooltip: String {
        guard !pluginHost.automationController.activeRunIDs.isEmpty else {
            return AppMetadata.appName
        }
        return "\(AppMetadata.appName) · \(FeatureL10n.string("运行中"))"
    }

    private var hasAvailableUpdate: Bool {
        appUpdater.availableUpdateVersion != nil
    }

    private var statusTooltip: String {
        guard let version = appUpdater.availableUpdateVersion else {
            return automationActivityTooltip
        }
        let availability = AppL10n.settingsFormat(
            "about.update.headline.availableFormat",
            defaultValue: "检测到新版本 %@",
            version
        )
        return "\(automationActivityTooltip)\n\(availability)"
    }

    private func statusImage(
        _ source: NSImage,
        isTemplate: Bool? = nil,
        appearance: PluginMenuBarIconRenderContext.Appearance
    ) -> NSImage {
        let showsAutomationBadge = !pluginHost.automationController.activeRunIDs.isEmpty
        let showsUpdateBadge = hasAvailableUpdate
        guard showsAutomationBadge || showsUpdateBadge else {
            return source
        }

        let sourceIsTemplate = isTemplate ?? source.isTemplate
        // A colored update badge requires a non-template image, so template glyphs are
        // tinted manually to match the menu bar appearance.
        let tintsGlyph = showsUpdateBadge && sourceIsTemplate
        let glyphTint: NSColor = appearance == .dark ? .white : NSColor.black.withAlphaComponent(0.85)
        let size = source.size
        let image = NSImage(size: size, flipped: false) { bounds in
            if tintsGlyph {
                let glyph = NSImage(size: bounds.size, flipped: false) { glyphBounds in
                    source.draw(in: glyphBounds)
                    glyphTint.setFill()
                    glyphBounds.fill(using: .sourceAtop)
                    return true
                }
                glyph.draw(in: bounds)
            } else {
                source.draw(in: bounds)
            }
            let diameter = max(4, min(7, min(bounds.width, bounds.height) * 0.34))
            if showsAutomationBadge {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: bounds.maxX - diameter,
                    y: bounds.minY,
                    width: diameter,
                    height: diameter
                )).fill()
            }
            if showsUpdateBadge {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: bounds.maxX - diameter,
                    y: bounds.maxY - diameter,
                    width: diameter,
                    height: diameter
                )).fill()
            }
            return true
        }
        image.isTemplate = showsUpdateBadge ? false : sourceIsTemplate
        return image
    }

    private func observeStatusItemPositionPersistence() {
        appTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MenuBarControlItemDefaults.snapshotVisibleControlItemPreferredPosition()
        }

        statusItemWindowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let movedWindowIdentifier = (notification.object as? NSWindow).map { ObjectIdentifier($0) }
            DispatchQueue.main.async {
                self?.snapshotVisibleControlItemPreferredPositionIfNeeded(
                    forMovedWindowIdentifier: movedWindowIdentifier
                )
            }
        }
    }

    private func snapshotVisibleControlItemPreferredPositionIfNeeded(
        forMovedWindowIdentifier movedWindowIdentifier: ObjectIdentifier?
    ) {
        guard
            let movedWindowIdentifier,
            let statusItemWindow = statusItem.button?.window,
            movedWindowIdentifier == ObjectIdentifier(statusItemWindow)
        else {
            return
        }

        MenuBarControlItemDefaults.snapshotVisibleControlItemPreferredPosition()
    }

    private func resetStatusItemPosition() {
        // Dismiss panels while their owning status item is still alive.
        requestPanelClose()

        let oldItem = statusItem
        PluginPresentationSafety.prepareForWindowOrdering()
        NSStatusBar.system.removeStatusItem(oldItem)
        MenuBarControlItemDefaults.resetVisibleControlItemPosition()
        MenuBarControlItemDefaults.snapshotVisibleControlItemPreferredPosition()

        PluginPresentationSafety.prepareForWindowOrdering()
        let newItem = NSStatusBar.system.statusItem(withLength: 0)
        newItem.autosaveName = MenuBarControlItemDefaults.visibleAutosaveName
        newItem.isVisible = pluginHost.isAppMenuBarIconVisible
        statusItem = newItem

        configureStatusItem()
        updateStatusIcon()
    }

    private func configureAnimationIfNeeded(_ payload: MenuBarIconImagePayload) {
        animationTimer?.cancel()
        animationTimer = nil
        animationFrames = []
        animationFrameIndex = 0
        animationFrameDuration = max(payload.frameDuration, 0.04)

        guard payload.isAnimated else {
            return
        }

        animationFrames = payload.animationFrames
        scheduleAnimationTimer()
    }

    private func scheduleAnimationTimer() {
        animationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + animationFrameDuration,
            repeating: animationFrameDuration,
            leeway: .milliseconds(Int((animationFrameDuration * 500).rounded()))
        )
        timer.setEventHandler { [weak self] in
            self?.advanceAnimationFrame()
        }
        animationTimer = timer
        timer.resume()
    }

    private func advanceAnimationFrame() {
        guard
            !animationFrames.isEmpty,
            statusItem.button != nil
        else {
            animationTimer?.cancel()
            animationTimer = nil
            return
        }

        animationFrameIndex = (animationFrameIndex + 1) % animationFrames.count
        updateStatusIcon()
    }

    @objc
    private func handleStatusItemAction(_ sender: NSStatusBarButton) {
        let invocation = MenuBarStatusItemInvocation.invocation(for: NSApp.currentEvent)
        let id = invocation == .componentPanel
            ? pluginHost.lastSelectedMenuBarPanelID : pluginHost.visibleMenuBarPanels.last?.id
        if let id { panelPresenter.showPanel(id: id, toggle: true, relativeTo: sender) }
        handlePresentationResult()
    }

    private func toggleFeaturePanel(relativeTo button: NSStatusBarButton) {
        panelPresenter.toggleFeaturePanel(relativeTo: button)
        handlePresentationResult()
    }

    private func toggleComponentPanel(relativeTo button: NSStatusBarButton) {
        panelPresenter.toggleComponentPanel(relativeTo: button)
        handlePresentationResult()
    }

    private func handlePresentationResult() {
        guard panelPresenter.isAnyPanelShown else {
            return
        }

        installDismissMonitorsIfNeeded()
    }

    private func installDismissMonitorsIfNeeded() {
        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]

        if localEventMonitor == nil {
            dismissalGeneration &+= 1
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
                self?.handleLocalMouseEvent(event) ?? event
            }
        }

        installGlobalMouseMonitorIfNeeded()

        if appActivationObserver == nil {
            appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard !Self.isCurrentApplicationActivationNotification(notification) else {
                    return
                }

                let generation = MainActor.assumeIsolated { self?.dismissalGeneration }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.dismissalGeneration == generation else { return }
                    self.requestPanelClose()
                }
            }
        }
    }

    private func removeDismissMonitorsIfNeeded() {
        dismissalGeneration &+= 1
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }

        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    private func handleLocalMouseEvent(_ event: NSEvent) -> NSEvent {
        guard panelPresenter.isAnyPanelShown else {
            removeDismissMonitorsIfNeeded()
            return event
        }

        // Native menu tracking owns its menu windows and consumes the dismissal click.
        // Those windows are not members of the popover's auxiliary-window registry.
        guard !panelPresenter.isTrackingNativeMenu else { return event }

        guard !isEventInsidePresentedPanel(event), !isEventInsideStatusButton(event) else {
            return event
        }

        requestPanelClose()
        return event
    }

    private func installGlobalMouseMonitorIfNeeded() {
        guard globalEventMonitor == nil else { return }
        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            let location = event.locationInWindow
            let snapshot = MenuBarGlobalMouseEvent(
                screenX: Double(location.x),
                screenY: Double(location.y)
            )
            let generation = self?.dismissalGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.dismissalGeneration == generation else { return }
                self.handleGlobalMouseEvent(snapshot)
            }
        }
    }

    private func handleGlobalMouseEvent(_ event: MenuBarGlobalMouseEvent) {
        if MenuBarGlobalMouseEventPolicy.isStatusItemClick(
            for: event,
            buttonFrame: statusItemButtonScreenRect()
        ) {
            return
        }

        guard panelPresenter.isAnyPanelShown else { return }
        requestPanelClose()
    }

    private func isEventInsidePresentedPanel(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window else {
            return false
        }

        return panelPresenter.containsPresentedWindow(eventWindow)
    }

    private func isEventInsideStatusButton(_ event: NSEvent) -> Bool {
        guard
            let button = statusItem.button,
            event.window === button.window
        else {
            return false
        }

        let pointInButton = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(pointInButton)
    }

    nonisolated private static func isCurrentApplicationActivationNotification(_ notification: Notification) -> Bool {
        guard
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            return false
        }

        return activatedApplication.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

}

private final class MenuBarIconAppearanceObserverView: NSView {
    var onChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() { onChange?() }
    override func viewDidChangeBackingProperties() { onChange?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
