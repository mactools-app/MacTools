import AppKit
import Combine
import MacToolsAppIntents
import MacToolsPluginKit
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class MacToolsAppRuntime {
    private let pluginHost = PluginHost(
        loadDynamicPluginsOnInit: false,
        preferencesBackupStore: PreferencesBackupStore(),
        enablesAutomaticPreferencesBackups: true
    )
    private let appUpdater = AppUpdater()
    private let menuBarIconSettings = MenuBarIconSettings()
    private let menuBarIconGallery = MenuBarIconGalleryLibrary()
    private let launchAtLoginController = LaunchAtLoginController()
    private let appearanceUserDefaults = UserDefaults.standard
    private let menuBarPanelThemeStore = MenuBarPanelThemeStore()
    private let pluginAutomaticUpdateVersionStore = PluginAutomaticUpdateVersionStore()
    private var windowRouter: AppWindowRouter?
    private var statusItemController: MenuBarStatusItemController?
    private var actionGridOverlayController: ActionGridOverlayController?
    private var appIntentCatalogCancellable: AnyCancellable?
    private var cliBrokerActivationCancellable: AnyCancellable?
    private lazy var cliDiscovery = CLIActionDiscovery(
        registry: pluginHost.actionRegistry,
        workflows: { [weak self] in self?.pluginHost.automationController.workflows ?? [] }
    )
    private lazy var cliActionRunner = CLIActionRunner(
        discovery: cliDiscovery,
        executor: pluginHost.actionExecutor
    )
    private lazy var cliHostBridge = CLIHostBridge(
        discovery: cliDiscovery,
        runner: cliActionRunner
    )
    private lazy var settingsRecoveryScheduler = SettingsRecoveryScheduler { [weak self] in
        self?.windowRouter?.showSettings()
    }
    private lazy var appIntentCoordinator = MacToolsAppIntentCoordinator(
        registry: pluginHost.actionRegistry,
        executor: pluginHost.actionExecutor,
        activityHandler: { [weak self] in
            self?.settingsRecoveryScheduler.noteBackgroundExecution()
        }
    )
    private lazy var automationStartupCoordinator = AutomationStartupCoordinator { [weak self] in
        self?.pluginHost.automationController.startAutomaticRules()
    }
    private lazy var runLinkFeedbackPresenter = SystemRunLinkFeedbackPresenter()
    private lazy var runLinkExecutionCoordinator = RunLinkExecutionCoordinator(
        registry: pluginHost.actionRegistry,
        executor: pluginHost.actionExecutor,
        runLinkService: pluginHost.actionRunLinkService,
        confirmationService: pluginHost.actionConfirmationService,
        feedbackPresenter: runLinkFeedbackPresenter
    )
    private lazy var appURLRouter = AppURLRouter(
        actionRejectionHandler: { [weak self] _, error in
            self?.runLinkExecutionCoordinator.presentRoutingRejection(error)
        }
    )

    func start(notificationDelegate: UNUserNotificationCenterDelegate) {
        AppAppearancePreference.applyStoredPreference(userDefaults: appearanceUserDefaults)
        launchAtLoginController.refreshStatus()
        UNUserNotificationCenter.current().delegate = notificationDelegate
        appIntentCoordinator.beginPreparation()
        appIntentCatalogCancellable = Publishers.CombineLatest(
            pluginHost.actionRegistry.$catalogRevision,
            pluginHost.actionRegistry.$availabilityRevision
        )
            .dropFirst()
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.appIntentCoordinator.actionCatalogDidChange()
            }

        let windowRouter = AppWindowRouter(
            pluginHost: pluginHost,
            appUpdater: appUpdater,
            menuBarIconSettings: menuBarIconSettings,
            menuBarIconGallery: menuBarIconGallery,
            launchAtLoginController: launchAtLoginController,
            menuBarPanelThemeStore: menuBarPanelThemeStore,
            appearanceUserDefaults: appearanceUserDefaults
        )
        self.windowRouter = windowRouter
        pluginHost.installFocusedHostWindowProvider { [weak windowRouter] in
            windowRouter?.focusedWindowLayoutTarget
        }
        pluginHost.actionExecutionFeedbackHandler = { [weak self] source, reference, actionTitle, outcome in
            self?.presentHeadlessActionFeedback(
                source: source,
                reference: reference,
                actionTitle: actionTitle,
                outcome: outcome
            )
        }
        let actionConfirmationService = AppActionConfirmationService { [weak self] in
            self?.windowRouter?.windowForActionConfirmation()
        }
        pluginHost.actionConfirmationService.setHandler { request in
            await actionConfirmationService.confirm(request)
        }
        let actionGridOverlayController = ActionGridOverlayController(pluginHost: pluginHost)
        self.actionGridOverlayController = actionGridOverlayController
        pluginHost.installActionGridPresenter { [weak self, weak actionGridOverlayController] entries, source in
            self?.pluginHost.captureCurrentFocusedWindowTarget()
            return actionGridOverlayController?.present(entries: entries, source: source) ?? false
        }
        statusItemController = MenuBarStatusItemController(
            pluginHost: pluginHost,
            windowRouter: windowRouter,
            appUpdater: appUpdater,
            iconSettings: menuBarIconSettings,
            menuBarPanelThemeStore: menuBarPanelThemeStore
        )

        startCLIHostIfAvailable()
        bootstrapDynamicPlugins()
        if pluginHost.starterPacks.needsOnboarding {
            windowRouter.showOnboarding()
        }
    }

    func showSettings() -> Bool {
        guard windowRouter != nil else { return false }
        settingsRecoveryScheduler.request()
        return true
    }

    func handle(urls: [URL]) {
        appURLRouter.handle(urls)
    }

    func terminate() {
        settingsRecoveryScheduler.cancel()
        cliBrokerActivationCancellable?.cancel()
        cliBrokerActivationCancellable = nil
        cliHostBridge.stop()
        pluginHost.flushAutomaticPreferencesBackupBeforeTermination()
        pluginHost.automationController.stopAutomaticRules()
        actionGridOverlayController?.close(restoringFocus: false)
        statusItemController?.dismissPanels()
        pluginHost.deactivateAllPlugins()
    }

    private func presentHeadlessActionFeedback(
        source: ActionExecutionSource,
        reference: ActionReference,
        actionTitle: String?,
        outcome: ActionExecutionOutcome
    ) {
        guard reference.key.providerID == "window-layouts",
              source == .globalShortcut || source == .trackpadGesture
        else {
            return
        }

        if let feedback = WindowLayoutActionFeedback.feedback(
            actionTitle: actionTitle,
            outcome: outcome
        ) {
            runLinkFeedbackPresenter.present(feedback)
        }
    }

    private func bootstrapDynamicPlugins() {
        let currentAppVersion = AppMetadata.versionDescription

        guard pluginHost.hasInstalledDynamicPlugins else {
            pluginHost.loadDynamicPluginsIfNeeded()
            pluginAutomaticUpdateVersionStore.markAutomaticUpdateChecked(
                currentAppVersion: currentAppVersion
            )
            completeBootstrap()
            return
        }

        let needsAutomaticUpdateCheck = pluginAutomaticUpdateVersionStore.needsAutomaticUpdateCheck(
            currentAppVersion: currentAppVersion
        )
        guard needsAutomaticUpdateCheck
            || pluginHost.hasPendingDynamicPluginExtractionMigration
        else {
            pluginHost.loadDynamicPluginsIfNeeded()
            completeBootstrap()
            return
        }

        Task { @MainActor in
            await automationStartupCoordinator.startAfterActionRegistryPreparation {
                let updateSucceeded = await pluginHost
                    .automaticUpdateInstalledPluginsBeforeLoading()
                if updateSucceeded {
                    pluginAutomaticUpdateVersionStore.markAutomaticUpdateChecked(
                        currentAppVersion: currentAppVersion
                    )
                }
            }
            appIntentCoordinator.actionRegistryDidBecomeReady()
            cliDiscovery.markReady()
            activateAppURLRouter()
        }
    }

    private func completeBootstrap() {
        automationStartupCoordinator.actionRegistryDidBecomeReady()
        appIntentCoordinator.actionRegistryDidBecomeReady()
        cliDiscovery.markReady()
        activateAppURLRouter()
    }

    private func startCLIHostIfAvailable() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        cliBrokerActivationCancellable = NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )
        .sink { _ in
            Task { @MainActor in
                CLIBrokerServiceController.shared.applicationDidBecomeActive()
            }
        }
        cliHostBridge.start()
        CLIInstallController.shared.start()
    }

    private func activateAppURLRouter() {
        appURLRouter.activate(
            presentationHandler: { [weak self] request in
                self?.pluginHost.appPresentationHandler?(request)
            },
            isPluginConfigurationAvailable: { [weak self] pluginID in
                self?.pluginHost.hasPluginSettings(pluginID: pluginID) == true
            },
            isMarketplaceDetailAvailable: { [weak self] target in
                self?.pluginHost.canPresentMarketplaceDetail(target: target) == true
            },
            actionIdentityResolver: { [weak self] request in
                self?.pluginHost.actionRunLinkService.resolve(request)
            },
            actionHandler: { [weak self] request, resolution in
                guard let self else { return .completed }
                if let resolution {
                    return await self.runLinkExecutionCoordinator.execute(resolution)
                }
                return await self.runLinkExecutionCoordinator.execute(request)
            }
        )
    }
}

@MainActor
final class SettingsRecoveryScheduler {
    private let delay: Duration
    private let suppressionDuration: Duration
    private let showSettings: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private var suppressionTask: Task<Void, Never>?
    private var isSuppressionActive = false

    init(
        delay: Duration = .milliseconds(400),
        suppressionDuration: Duration = .seconds(2),
        showSettings: @escaping @MainActor () -> Void
    ) {
        self.delay = delay
        self.suppressionDuration = suppressionDuration
        self.showSettings = showSettings
    }

    func request() {
        guard !isSuppressionActive else { return }
        task?.cancel()
        task = Task { @MainActor [weak self, delay] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            task = nil
            showSettings()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        clearSuppression()
    }

    func noteBackgroundExecution() {
        task?.cancel()
        task = nil
        isSuppressionActive = true
        suppressionTask?.cancel()
        suppressionTask = Task { @MainActor [weak self, suppressionDuration] in
            do {
                try await Task.sleep(for: suppressionDuration)
            } catch {
                return
            }
            self?.clearSuppression()
        }
    }

    private func clearSuppression() {
        suppressionTask?.cancel()
        suppressionTask = nil
        isSuppressionActive = false
    }

    #if DEBUG
    var hasPendingRequestForTesting: Bool { task != nil }
    var isSuppressionActiveForTesting: Bool { isSuppressionActive }

    func runPendingRequestForTesting() {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        showSettings()
    }
    #endif
}
