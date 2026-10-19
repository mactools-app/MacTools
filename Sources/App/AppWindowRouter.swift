import AppKit
import Carbon
import Combine
import SwiftUI
import MacToolsPluginKit

enum MacToolsLocalKeyboardCommand: Equatable {
    case showSettings
    case focusSearch
    case showUnifiedSearch
    case selectNumber(Int)
    case goBack
    case goForward
    case moveSidebarSelection(SettingsSidebarMoveDirection)

    static func resolve(for event: NSEvent) -> MacToolsLocalKeyboardCommand? {
        guard event.type == .keyDown else {
            return nil
        }

        let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let modifiers = event.modifierFlags.intersection(relevantModifiers)

        if modifiers == [.control, .command] {
            switch Int(event.keyCode) {
            case kVK_UpArrow:
                return .moveSidebarSelection(.previous)
            case kVK_DownArrow:
                return .moveSidebarSelection(.next)
            default:
                return nil
            }
        }

        guard modifiers == .command else {
            return nil
        }

        if let selectionNumber = physicalNumberRowSelection(for: event.keyCode) {
            return .selectNumber(selectionNumber)
        }

        switch Int(event.keyCode) {
        case kVK_ANSI_LeftBracket:
            return .goBack
        case kVK_ANSI_RightBracket:
            return .goForward
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case ",":
            return .showSettings
        case "f":
            return .focusSearch
        case "k":
            return .showUnifiedSearch
        default:
            return nil
        }
    }

    private static func physicalNumberRowSelection(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case UInt16(kVK_ANSI_1):
            1
        case UInt16(kVK_ANSI_2):
            2
        case UInt16(kVK_ANSI_3):
            3
        case UInt16(kVK_ANSI_4):
            4
        case UInt16(kVK_ANSI_5):
            5
        case UInt16(kVK_ANSI_6):
            6
        case UInt16(kVK_ANSI_7):
            7
        case UInt16(kVK_ANSI_8):
            8
        case UInt16(kVK_ANSI_9):
            9
        default:
            nil
        }
    }
}

@MainActor
final class MacToolsCommandWindow: NSWindow {
    var onLocalKeyboardCommand: ((MacToolsLocalKeyboardCommand) -> Bool)?
    weak var sidebarListView: NSTableView?
    var isSidebarInteractionEnabled: () -> Bool = { true }

    override func sendEvent(_ event: NSEvent) {
        restoreSidebarFocusIfNeeded(for: event)
        super.sendEvent(event)
    }

    func restoreSidebarFocusIfNeeded(for event: NSEvent) {
        guard
            event.type == .leftMouseDown,
            isSidebarInteractionEnabled(),
            let sidebarListView,
            sidebarListView.window === self,
            let contentView
        else {
            return
        }

        let location = sidebarListView.convert(event.locationInWindow, from: nil)
        guard sidebarListView.row(at: location) >= 0 else { return }

        // Hit testing takes a point in the receiver's superview coordinates.
        let hitLocation = contentView.superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        guard let hitView = contentView.hitTest(hitLocation),
              hitView === sidebarListView || hitView.isDescendant(of: sidebarListView) else {
            return
        }

        makeFirstResponder(sidebarListView)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard
            let command = MacToolsLocalKeyboardCommand.resolve(for: event),
            let onLocalKeyboardCommand
        else {
            return super.performKeyEquivalent(with: event)
        }

        guard onLocalKeyboardCommand(command) else {
            return super.performKeyEquivalent(with: event)
        }

        return true
    }
}

enum StandaloneCommandPaletteLayout {
    static let contentSize = NSSize(width: 720, height: 710)
    static let surfaceInset: CGFloat = 24
    static let surfaceInsets = NSEdgeInsets(
        top: surfaceInset,
        left: surfaceInset,
        bottom: surfaceInset,
        right: surfaceInset
    )

    static func frame(
        contentSize: NSSize = contentSize,
        pointerLocation: NSPoint,
        visibleFrames: [NSRect],
        position: WindowPosition = .defaultAnchor
    ) -> NSRect {
        guard let visibleFrame = visibleFrames.first(where: { $0.contains(pointerLocation) })
            ?? visibleFrames.first
        else {
            return NSRect(origin: .zero, size: contentSize)
        }

        return WindowSnapGeometry.frame(
            for: position,
            contentSize: contentSize,
            visibleFrame: visibleFrame
        )
    }
}

enum AppWindowPresentation {
    static func perform(
        isMiniaturized: Bool,
        activate: () -> Void,
        deminiaturize: () -> Void,
        orderFront: () -> Void
    ) {
        activate()
        if isMiniaturized {
            deminiaturize()
        }
        orderFront()
    }
}

enum AppDockVisibilityPolicy {
    static func activationPolicy(
        hasVisibleSettingsWindow: Bool
    ) -> NSApplication.ActivationPolicy {
        hasVisibleSettingsWindow ? .regular : .accessory
    }
}

@MainActor
enum AppDockVisibilityController {
    static func update(hasVisibleSettingsWindow: Bool) {
        update(
            hasVisibleSettingsWindow: hasVisibleSettingsWindow,
            isRunningTests: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            setActivationPolicy: NSApplication.shared.setActivationPolicy
        )
    }

    static func update(
        hasVisibleSettingsWindow: Bool,
        isRunningTests: Bool,
        setActivationPolicy: (NSApplication.ActivationPolicy) -> Bool
    ) {
        guard !isRunningTests else { return }
        _ = setActivationPolicy(
            AppDockVisibilityPolicy.activationPolicy(
                hasVisibleSettingsWindow: hasVisibleSettingsWindow
            )
        )
    }
}

@MainActor
final class StandaloneCommandPaletteState: ObservableObject {
    @Published private(set) var inputItem: ActionInputItem?
    @Published private(set) var presentationOrigin: UnifiedSearchPresentationOrigin?
    @Published private(set) var focusRequestID: UInt = 0
    @Published private(set) var resetRequestID: UInt = 0
    @Published private(set) var quickSelectionRequest: UnifiedSearchQuickSelectionRequest?
    @Published private(set) var localizationRevision: UInt = 0

    var isDismissalSuspended = false

    private var nextQuickSelectionRequestID: UInt = 0
    private var pendingExecutionCancellation: (() -> Void)?

    func prepareForPresentation(shortcutLabel: String, input: ActionInputItem? = nil) {
        isDismissalSuspended = false
        inputItem = input
        presentationOrigin = .globalShortcut(shortcutLabel)
        quickSelectionRequest = nil
        resetRequestID &+= 1
        focusRequestID &+= 1
    }

    func prepareForDismissal() {
        let cancellation = pendingExecutionCancellation
        pendingExecutionCancellation = nil
        cancellation?()
    }

    func setPendingExecutionCancellation(_ cancellation: (() -> Void)?) {
        pendingExecutionCancellation = cancellation
    }

    @discardableResult
    func requestQuickSelection(number: Int) -> Bool {
        guard (1...MacToolsSearchPresentation.quickSelectionLimit).contains(number) else {
            return false
        }

        nextQuickSelectionRequestID &+= 1
        quickSelectionRequest = UnifiedSearchQuickSelectionRequest(
            id: nextQuickSelectionRequestID,
            number: number
        )
        return true
    }

    @discardableResult
    func consumeQuickSelectionRequest(_ request: UnifiedSearchQuickSelectionRequest) -> Bool {
        guard quickSelectionRequest == request else {
            return false
        }

        quickSelectionRequest = nil
        return true
    }

    func refreshLocalization() {
        localizationRevision &+= 1
    }
}

@MainActor
final class MacToolsCommandPalettePanel: NSPanel {
    var onQuickSelection: ((Int) -> Bool)?
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if case let .selectNumber(number) = MacToolsLocalKeyboardCommand.resolve(for: event),
           onQuickSelection?(number) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

/// Keep the window frame owned by AppKit, as in Clipboard History. A top-level
/// NSHostingView can introduce window-level layout and safe-area treatment in
/// addition to the palette's own rounded surface.
@MainActor
final class CommandPaletteHostingContainer<Content: View>: NSView {
    let hostingView: NSHostingView<Content>

    init(rootView: Content) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hostingView.safeAreaRegions = []
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }
}

struct StandaloneCommandPaletteRootView: View {
    let pluginHost: PluginHost
    let launchAtLoginController: LaunchAtLoginController
    let appearanceUserDefaults: UserDefaults
    let commandPaletteRecentStore: CommandPaletteRecentStore
    @ObservedObject var state: StandaloneCommandPaletteState
    let actions: UnifiedSearchPaletteActions
    let dragCoordinator: WindowSnapCoordinator?

    var body: some View {
        GeometryReader { geometry in
            UnifiedSearchPaletteView(
                pluginHost: pluginHost,
                launchAtLoginController: launchAtLoginController,
                appearanceUserDefaults: appearanceUserDefaults,
                recentStore: commandPaletteRecentStore,
                availableSize: geometry.size,
                presentationOrigin: state.presentationOrigin,
                focusRequestID: state.focusRequestID,
                resetRequestID: state.resetRequestID,
                quickSelectionRequest: state.quickSelectionRequest,
                showsCustomShadow: true,
                actions: actions,
                initialInputItem: state.inputItem,
                dragCoordinator: dragCoordinator
            )
            .padding(StandaloneCommandPaletteLayout.surfaceInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(state.localizationRevision)
        .background(Color.clear)
        .environment(\.locale, PluginRuntimeLocalization.locale)
        .environment(
            \.layoutDirection,
            Self.layoutDirection(for: PluginRuntimeLocalization.locale)
        )
    }

    static func layoutDirection(for locale: Locale) -> LayoutDirection {
        locale.language.characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }
}

enum SettingsWindowLayout {
    static let defaultContentSize = NSSize(width: 1040, height: 720)
    static let minimumContentSize = NSSize(width: 860, height: 560)
}

enum StandaloneCommandPaletteSuccessfulExecutionFocusPolicy {
    static func shouldRestorePreviousApplication(
        paletteIsKey: Bool,
        applicationIsActive: Bool
    ) -> Bool {
        paletteIsKey && applicationIsActive
    }
}

@MainActor
final class AppWindowRouter: NSObject, NSWindowDelegate {
    private let pluginHost: PluginHost
    private let appUpdater: AppUpdater
    private let menuBarIconSettings: MenuBarIconSettings
    private let menuBarIconGallery: MenuBarIconGalleryLibrary
    private let launchAtLoginController: LaunchAtLoginController
    private let menuBarPanelThemeStore: MenuBarPanelThemeStore
    private let appearanceUserDefaults: UserDefaults
    let commandPaletteRecentStore: CommandPaletteRecentStore
    let windowPositionStore: WindowPositionStore
    private(set) var commandPaletteSnapCoordinator: WindowSnapCoordinator?
    private let settingsSidebarPreferences: SettingsSidebarPreferencesStore
    private let commandPaletteFocusRestoration: PluginPanelFocusRestoration
    private(set) var settingsWindow: NSWindow?
    private(set) var settingsNavigationCoordinator: SettingsNavigationCoordinator?
    private(set) var onboardingWindow: NSWindow?
    private(set) var onboardingNavigationCoordinator: SettingsNavigationCoordinator?
    private var onboardingImporter: PreferencesImportController?
    private(set) var commandPalettePanel: NSPanel?
    private(set) var commandPaletteState: StandaloneCommandPaletteState?
    private var runtimeLocaleCancellable: AnyCancellable?
    private let commandPaletteDismissal = PluginPanelDismissalMonitor()
    private var appearanceObserver: NSObjectProtocol?
    private var onProgrammaticSettingsPresentation: () -> Void = {}

    static var settingsWindowTitle: String {
        AppL10n.settings("settings.window.title", defaultValue: "设置")
    }

    static var commandPaletteWindowTitle: String {
        AppL10n.search("search.title", defaultValue: "搜索 MacTools")
    }

    var focusedWindowLayoutTarget: NSWindow? {
        if let settingsWindow,
           Self.isEligibleFocusedWindowLayoutTarget(
               isKeyWindow: settingsWindow.isKeyWindow,
               isVisible: settingsWindow.isVisible,
               isUnifiedSearchPresented: settingsNavigationCoordinator?.isUnifiedSearchPresented == true
           ) {
            return settingsWindow
        }
        return pluginHost.focusedPluginWindowLayoutTarget()
    }

    static func isEligibleFocusedWindowLayoutTarget(
        isKeyWindow: Bool,
        isVisible: Bool,
        isUnifiedSearchPresented: Bool
    ) -> Bool {
        isKeyWindow && isVisible && !isUnifiedSearchPresented
    }

    init(
        pluginHost: PluginHost,
        appUpdater: AppUpdater,
        menuBarIconSettings: MenuBarIconSettings,
        menuBarIconGallery: MenuBarIconGalleryLibrary,
        launchAtLoginController: LaunchAtLoginController,
        menuBarPanelThemeStore: MenuBarPanelThemeStore = .shared,
        appearanceUserDefaults: UserDefaults = .standard,
        commandPaletteFocusRestoration: PluginPanelFocusRestoration = .init(),
        windowPositionStore: WindowPositionStore = .shared
    ) {
        self.pluginHost = pluginHost
        self.appUpdater = appUpdater
        self.menuBarIconSettings = menuBarIconSettings
        self.menuBarIconGallery = menuBarIconGallery
        self.launchAtLoginController = launchAtLoginController
        self.menuBarPanelThemeStore = menuBarPanelThemeStore
        self.appearanceUserDefaults = appearanceUserDefaults
        self.windowPositionStore = windowPositionStore
        self.commandPaletteRecentStore = CommandPaletteRecentStore(
            userDefaults: appearanceUserDefaults
        )
        self.settingsSidebarPreferences = SettingsSidebarPreferencesStore(
            userDefaults: appearanceUserDefaults,
            preferencesBackupChangeReporter: pluginHost.preferencesBackupChangeReporter
        )
        self.commandPaletteFocusRestoration = commandPaletteFocusRestoration
        super.init()
        runtimeLocaleCancellable = PluginRuntimeLocalization.source.$revision
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.settingsWindow?.title = Self.settingsWindowTitle
                    self?.onboardingWindow?.title = FeatureL10n.string("MacTools 设置")
                    self?.commandPalettePanel?.setAccessibilityTitle(Self.commandPaletteWindowTitle)
                    self?.commandPaletteState?.refreshLocalization()
                }
            }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppAppearancePreference.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let preference = notification.object as? AppAppearancePreference else {
                return
            }
            Task { @MainActor [weak self] in
                preference.apply(to: self?.settingsWindow)
                preference.apply(to: self?.onboardingWindow)
                self?.applyCommandPaletteAppearance()
            }
        }
    }

    isolated deinit {
        runtimeLocaleCancellable?.cancel()
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    func showSettings() {
        presentSettings(.settings)
    }

    func showOnboarding(pack: StarterPack? = nil, step: StarterPackStep? = nil) {
        dismissCommandPalette(restoringFocus: false)
        let controller = pluginHost.starterPacks
        controller.resumeOnboarding()
        let requestedStep = controller.isRunning ? StarterPackStep.results : step
        let window = onboardingWindow ?? makeOnboardingWindow(initialStep: requestedStep ?? .choose)
        if let pack, !controller.isRunning {
            controller.includePackFromLink(pack)
            onboardingNavigationCoordinator?.navigate(to: .starterPacks(.review))
        } else if let requestedStep {
            onboardingNavigationCoordinator?.navigate(to: .starterPacks(requestedStep))
        }
        AppDockVisibilityController.update(hasVisibleSettingsWindow: true)
        show(window)
        onProgrammaticSettingsPresentation()
    }

    private func makeOnboardingWindow(initialStep: StarterPackStep) -> NSWindow {
        let navigation = SettingsNavigationCoordinator(initialDestination: .starterPacks(initialStep))
        let importer = PreferencesImportController(pluginHost: pluginHost)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = FeatureL10n.string("MacTools 设置")
        window.contentMinSize = NSSize(width: 900, height: 580)
        window.isReleasedWhenClosed = false
        window.delegate = self
        AppAppearancePreference.stored(in: appearanceUserDefaults).apply(to: window)
        let hostingView = NSHostingView(rootView: StarterPackOnboardingView(
            controller: pluginHost.starterPacks, host: pluginHost, navigation: navigation, importer: importer,
            onExit: { [weak self] in
                self?.onboardingWindow?.close()
                self?.presentSettings(.pluginMarketplace)
            },
            onOpenSettings: { [weak self] destination in
                self?.presentSettings(.settings)
                self?.settingsNavigationCoordinator?.navigate(to: destination)
            },
            onOpenPanel: { [weak self] panelID in
                self?.onboardingWindow?.close()
                self?.pluginHost.menuBarPanelPresentationHandler?(panelID, false)
            }
        ))
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.center()
        onboardingWindow = window
        onboardingNavigationCoordinator = navigation
        onboardingImporter = importer
        return window
    }

    func showUnifiedSearch() {
        pluginHost.captureCurrentFocusedWindowTarget()
        launchAtLoginController.refreshStatus()
        pluginHost.refreshActionPresentations(providerIDs: ["apple-shortcuts"])
        presentSettings(.settings)
        settingsNavigationCoordinator?.presentUnifiedSearch(origin: .keyboard)
    }

    func windowForActionConfirmation() -> NSWindow? {
        pluginHost.captureCurrentFocusedWindowTarget()
        presentSettings(.settings)
        return settingsWindow
    }

    func toggleCommandPalette() {
        settingsNavigationCoordinator?.dismissUnifiedSearch()

        if commandPalettePanel?.isVisible == true {
            dismissCommandPalette()
            return
        }

        showCommandPalette()
    }

    func showCommandPalette(input: ActionInputItem? = nil) {
        if let input, !pluginHost.actionInputRegistry.contains(input) { return }
        settingsNavigationCoordinator?.dismissUnifiedSearch()

        pluginHost.captureCurrentFocusedWindowTarget()
        launchAtLoginController.refreshStatus()
        pluginHost.refreshActionPresentations(providerIDs: ["apple-shortcuts"])
        onProgrammaticSettingsPresentation()
        let state = commandPaletteState ?? StandaloneCommandPaletteState()
        let panel = commandPalettePanel ?? makeCommandPalettePanel(state: state)
        commandPaletteState = state
        commandPalettePanel = panel

        let shortcutLabel = pluginHost.appShortcutItems.first {
            $0.action == .openCommandPalette
        }?.bindingText ?? ""
        state.prepareForPresentation(shortcutLabel: shortcutLabel, input: input)
        applyCommandPaletteAppearance()

        let screens = NSScreen.screens
        let pointerLocation = NSEvent.mouseLocation
        let orderedVisibleFrames = screens
            .filter { $0.frame.contains(pointerLocation) }
            .map(\.visibleFrame)
            + [NSScreen.main?.visibleFrame].compactMap { $0 }
            + screens.map(\.visibleFrame)
        let storedPosition = windowPositionStore.position(for: .commandPalette)
        panel.setFrame(
            StandaloneCommandPaletteLayout.frame(
                pointerLocation: pointerLocation,
                visibleFrames: orderedVisibleFrames,
                position: storedPosition
            ),
            display: true
        )
        commandPaletteFocusRestoration.prepareForPresentation()
        commandPaletteDismissal.start(
            for: panel,
            isSuspended: { [weak state] in state?.isDismissalSuspended == true },
            onDismiss: { [weak self] in self?.dismissCommandPalette(restoringFocus: false) }
        )
        PluginPanelPresentation.present(panel)
    }

    func dismissCommandPalette(restoringFocus: Bool = true) {
        commandPaletteDismissal.stop()
        commandPaletteSnapCoordinator?.cancelDragging()
        let wasVisible = commandPalettePanel?.isVisible == true
        if wasVisible {
            commandPaletteState?.prepareForDismissal()
        }
        commandPalettePanel?.orderOut(nil)
        commandPaletteFocusRestoration.dismiss(
            wasVisible: wasVisible,
            restoringFocus: restoringFocus
        )
    }

    private func applyCommandPaletteAppearance() {
        let preference = AppAppearancePreference.stored(in: appearanceUserDefaults)
        preference.apply(to: commandPalettePanel)
        preference.apply(to: commandPalettePanel?.contentView)
    }

    func setProgrammaticSettingsPresentationAction(_ action: @escaping () -> Void) {
        onProgrammaticSettingsPresentation = action
    }

    private func show(_ window: NSWindow) {
        AppWindowPresentation.perform(
            isMiniaturized: window.isMiniaturized,
            activate: {
                NSApplication.shared.activate(ignoringOtherApps: true)
            },
            deminiaturize: {
                window.deminiaturize(nil)
            },
            orderFront: {
                PluginPresentationSafety.prepareForWindowOrdering(window)
                window.makeKeyAndOrderFront(nil)
            }
        )
    }

    private func configureSettingsInitialResponder(
        in window: MacToolsCommandWindow,
        hostingView: NSView
    ) {
        window.layoutIfNeeded()

        let listViews = descendantViews(of: hostingView)
            .compactMap { $0 as? NSScrollView }
            .compactMap(\.documentView)
            .compactMap { $0 as? NSTableView }

        let sidebarList: NSTableView?
        if hostingView.userInterfaceLayoutDirection == .rightToLeft {
            sidebarList = listViews.max { lhs, rhs in
                lhs.convert(lhs.bounds, to: hostingView).maxX
                    < rhs.convert(rhs.bounds, to: hostingView).maxX
            }
        } else {
            sidebarList = listViews.min { lhs, rhs in
                lhs.convert(lhs.bounds, to: hostingView).minX
                    < rhs.convert(rhs.bounds, to: hostingView).minX
            }
        }

        if sidebarList?.acceptsFirstResponder == true {
            window.initialFirstResponder = sidebarList
            window.sidebarListView = sidebarList
        }
    }

    private func descendantViews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { subview in
            [subview] + descendantViews(of: subview)
        }
    }

    private func makeSettingsWindow() -> NSWindow {
        let navigationCoordinator = SettingsNavigationCoordinator(
            pluginHost: pluginHost,
            sidebarPreferences: settingsSidebarPreferences
        )
        navigationCoordinator.presentOnboarding = { [weak self] step in
            guard let self, pluginHost.starterPacks.canResumeOnboarding || onboardingWindow != nil else { return false }
            showOnboarding(step: step)
            return true
        }
        let window = MacToolsCommandWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowLayout.defaultContentSize),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.title = Self.settingsWindowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        AppAppearancePreference.stored(in: appearanceUserDefaults).apply(to: window)
        let hostingView = NSHostingView(
            rootView: SettingsView(
                pluginHost: pluginHost,
                presentation: SettingsNavigationPresentationModel(host: pluginHost),
                navigationCoordinator: navigationCoordinator,
                appUpdater: appUpdater,
                menuBarIconSettings: menuBarIconSettings,
                menuBarIconGallery: menuBarIconGallery,
                launchAtLoginController: launchAtLoginController,
                menuBarPanelThemeStore: menuBarPanelThemeStore,
                sidebarPreferences: settingsSidebarPreferences,
                appearanceUserDefaults: appearanceUserDefaults,
                commandPaletteRecentStore: commandPaletteRecentStore
            )
        )
        hostingView.sizingOptions = []
        window.contentView = hostingView
        configureSettingsInitialResponder(in: window, hostingView: hostingView)
        window.toolbarStyle = .unified
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.onLocalKeyboardCommand = { [weak self] command in
            self?.handleLocalKeyboardCommand(command) ?? false
        }
        window.isSidebarInteractionEnabled = { [weak navigationCoordinator] in
            navigationCoordinator?.isUnifiedSearchPresented == false
        }
        window.center()
        settingsNavigationCoordinator = navigationCoordinator
        return window
    }

    private func makeCommandPalettePanel(
        state: StandaloneCommandPaletteState
    ) -> MacToolsCommandPalettePanel {
        let panel = MacToolsCommandPalettePanel(
            contentRect: NSRect(origin: .zero, size: StandaloneCommandPaletteLayout.contentSize),
            styleMask: PluginPanelPresentation.styleMask.union(.fullSizeContentView),
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowSnapCoordinator(
            role: .commandPalette,
            positionStore: windowPositionStore,
            referenceInsets: StandaloneCommandPaletteLayout.surfaceInsets
        )
        commandPaletteSnapCoordinator = coordinator
        coordinator.attach(to: panel)

        let actions = UnifiedSearchPaletteActions(
            dismiss: { [weak self] in
                self?.dismissCommandPalette()
            },
            dismissAfterSuccessfulExecution: { [weak self] in
                self?.dismissCommandPaletteAfterSuccessfulExecution()
            },
            navigate: { [weak self] destination, target in
                self?.navigateFromStandaloneSearch(to: destination, target: target) ?? false
            },
            consumeQuickSelection: state.consumeQuickSelectionRequest,
            setPendingExecutionCancellation: { [weak state] cancellation in
                state?.setPendingExecutionCancellation(cancellation)
            },
            resetCommandPalettePosition: { [weak self] in
                self?.resetCommandPalettePosition()
            },
            setDismissalSuspended: { [weak state] suspended in
                state?.isDismissalSuspended = suspended
            }
        )
        let hostingView = CommandPaletteHostingContainer(
            rootView: StandaloneCommandPaletteRootView(
                pluginHost: pluginHost,
                launchAtLoginController: launchAtLoginController,
                appearanceUserDefaults: appearanceUserDefaults,
                commandPaletteRecentStore: commandPaletteRecentStore,
                state: state,
                actions: actions,
                dragCoordinator: coordinator
            )
        )
        panel.contentView = hostingView
        let preference = AppAppearancePreference.stored(in: appearanceUserDefaults)
        preference.apply(to: panel)
        preference.apply(to: hostingView)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Both entry points use the same shadow around the visible surface.
        // A second window shadow would outline the transparent outer padding.
        panel.hasShadow = false
        panel.level = .floating
        PluginPanelPresentation.configure(panel)
        panel.setAccessibilityTitle(Self.commandPaletteWindowTitle)
        panel.onQuickSelection = state.requestQuickSelection
        panel.onDismiss = { [weak self] in
            self?.dismissCommandPalette()
        }
        return panel
    }

    func resetCommandPalettePosition() {
        windowPositionStore.resetPosition(for: .commandPalette)
        if let panel = commandPalettePanel, panel.isVisible {
            let pointerLocation = NSEvent.mouseLocation
            let screens = NSScreen.screens
            let orderedVisibleFrames = screens
                .filter { $0.frame.contains(pointerLocation) }
                .map(\.visibleFrame)
                + [NSScreen.main?.visibleFrame].compactMap { $0 }
                + screens.map(\.visibleFrame)
            let defaultFrame = StandaloneCommandPaletteLayout.frame(
                pointerLocation: pointerLocation,
                visibleFrames: orderedVisibleFrames,
                position: .defaultAnchor
            )
            panel.setFrame(defaultFrame, display: true, animate: true)
        }
    }

    private func dismissCommandPaletteAfterSuccessfulExecution() {
        let shouldRestoreFocus = StandaloneCommandPaletteSuccessfulExecutionFocusPolicy
            .shouldRestorePreviousApplication(
                paletteIsKey: commandPalettePanel?.isKeyWindow == true,
                applicationIsActive: NSApp.isActive
            )
        dismissCommandPalette(restoringFocus: shouldRestoreFocus)
    }

    @discardableResult
    func navigateFromStandaloneSearch(
        to destination: SettingsNavigationDestination,
        target: SettingsSearchRevealTarget?
    ) -> Bool {
        let validator = settingsNavigationCoordinator
            ?? SettingsNavigationCoordinator(
                pluginHost: pluginHost,
                sidebarPreferences: settingsSidebarPreferences
            )
        guard validator.canNavigateFromSearch(to: destination, target: target) else {
            return false
        }

        dismissCommandPalette(restoringFocus: false)
        presentSettings(.settings)
        return settingsNavigationCoordinator?.navigateFromSearch(
            to: destination,
            target: target
        ) ?? false
    }

    func presentSettings(_ request: SettingsPresentationRequest) {
        if case let .starterPacks(pack) = request, pluginHost.starterPacks.canResumeOnboarding || onboardingWindow != nil {
            showOnboarding(pack: pack)
            return
        }
        dismissCommandPalette(restoringFocus: false)
        let window = settingsWindow ?? makeSettingsWindow()
        let pendingAppUpdateVersion: String?

        settingsNavigationCoordinator?.dismissUnifiedSearch()

        switch request {
        case .settings:
            pendingAppUpdateVersion = nil
        case .general:
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .general)
        case .permissions:
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .permissions)
        case .about:
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .about)
        case .appUpdate:
            pendingAppUpdateVersion = appUpdater.availableUpdateVersion
            settingsNavigationCoordinator?.navigate(to: .about)
        case .pluginMarketplace:
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .plugins(.marketplace))
        case let .starterPacks(pack):
            pendingAppUpdateVersion = nil
            pluginHost.starterPacks.resumeOnboarding()
            if let pack, !pluginHost.starterPacks.isRunning {
                pluginHost.starterPacks.includePackFromLink(pack)
            }
            settingsNavigationCoordinator?.navigate(to: .starterPacks(
                pluginHost.starterPacks.isRunning ? .results : pack == nil ? .choose : .review
            ))
        case let .pluginMarketplaceDetail(target):
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .marketplaceDetail(target))
        case let .pluginConfiguration(pluginID):
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .plugins(.configuration(pluginID)))
        case let .automationWorkflow(workflowID):
            pendingAppUpdateVersion = nil
            _ = settingsNavigationCoordinator?.navigateFromSearch(
                to: .plugins(.automation),
                target: .automation(.init(workflowID: workflowID))
            )
        case let .feature(pane):
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .plugins(pane))
        }

        let contentSize = window.contentView?.bounds.size ?? SettingsWindowLayout.defaultContentSize
        settingsWindow = window
        AppDockVisibilityController.update(hasVisibleSettingsWindow: true)
        show(window)
        // SwiftUI installs its toolbar when the window becomes visible. Finish that
        // layout before restoring the content size.
        window.layoutIfNeeded()
        window.setContentSize(contentSize)
        window.layoutIfNeeded()
        onProgrammaticSettingsPresentation()

        if case .appUpdate = request {
            settingsNavigationCoordinator?.requestAboutUpdateAction(
                version: pendingAppUpdateVersion
            )
        }

    }

    private func handleLocalKeyboardCommand(_ command: MacToolsLocalKeyboardCommand) -> Bool {
        switch command {
        case .showSettings:
            showSettings()
            return true
        case .focusSearch:
            return settingsNavigationCoordinator?.requestSearch() ?? false
        case .showUnifiedSearch:
            showUnifiedSearch()
            return true
        case let .selectNumber(number):
            guard let settingsNavigationCoordinator else {
                return false
            }

            if settingsNavigationCoordinator.requestUnifiedSearchQuickSelection(number: number) {
                return true
            }

            return settingsNavigationCoordinator.performSidebarNumberShortcut(number: number)
        case .goBack:
            guard
                let settingsNavigationCoordinator,
                !settingsNavigationCoordinator.isUnifiedSearchPresented,
                settingsNavigationCoordinator.canGoBack
            else {
                return false
            }
            settingsNavigationCoordinator.goBack()
            return true
        case .goForward:
            guard
                let settingsNavigationCoordinator,
                !settingsNavigationCoordinator.isUnifiedSearchPresented,
                settingsNavigationCoordinator.canGoForward
            else {
                return false
            }
            settingsNavigationCoordinator.goForward()
            return true
        case let .moveSidebarSelection(direction):
            guard
                let settingsNavigationCoordinator,
                !settingsNavigationCoordinator.isUnifiedSearchPresented
            else {
                return false
            }
            return settingsNavigationCoordinator.moveSidebarSelection(direction)
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === settingsWindow else {
            return frameSize
        }

        let minimumFrameSize = sender.frameRect(
            forContentRect: NSRect(origin: .zero, size: SettingsWindowLayout.minimumContentSize)
        ).size
        return NSSize(
            width: max(frameSize.width, minimumFrameSize.width),
            height: max(frameSize.height, minimumFrameSize.height)
        )
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === onboardingWindow else { return true }
        if onboardingImporter?.isBusy == true { NSSound.beep(); return false }
        let controller = pluginHost.starterPacks
        guard controller.canResumeOnboarding || controller.isRunning else { return true }
        let alert = NSAlert()
        alert.messageText = FeatureL10n.string("关闭设置？")
        alert.informativeText = FeatureL10n.string(controller.isRunning
            ? "安装将在后台继续，可在插件市场查看进度。"
            : "你的选择会保留，下次启动时可继续设置。")
        alert.addButton(withTitle: FeatureL10n.string("关闭设置"))
        alert.addButton(withTitle: FeatureL10n.string("继续设置"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === onboardingWindow {
            window.delegate = nil
            window.contentView = nil
            onboardingWindow = nil
            onboardingNavigationCoordinator = nil
            onboardingImporter = nil
            AppDockVisibilityController.update(hasVisibleSettingsWindow: settingsWindow?.isVisible == true)
            return
        }
        guard let window = notification.object as? NSWindow, window === settingsWindow else {
            return
        }

        window.delegate = nil
        window.contentView = nil
        settingsWindow = nil
        settingsNavigationCoordinator = nil
        AppDockVisibilityController.update(hasVisibleSettingsWindow: onboardingWindow?.isVisible == true)
    }
}
