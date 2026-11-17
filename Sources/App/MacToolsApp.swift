import AppKit
import AppIntents
import MacToolsAppIntents
import SwiftUI
@preconcurrency import UserNotifications

@main
struct MacToolsApp: App, AppIntentsPackage {
    @NSApplicationDelegateAdaptor(MacToolsAppDelegate.self) private var appDelegate

    nonisolated static var includedPackages: [any AppIntentsPackage.Type] {
        [MacToolsAppIntentsPackage.self]
    }

    init() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        AppLanguagePreference.applyStoredPreference()
        MacToolsAppShortcuts.refreshParameters()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // Settings is presented exclusively by AppWindowRouter. Remove the
            // placeholder scene's command so it can never expose an empty window.
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

@MainActor
final class MacToolsAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let maximumPendingURLCount = 32

    private let instanceCoordinator: AppInstanceCoordinator
    private let acceptedURLSchemes: Set<String>
    private let appleEventSenderPath: @MainActor () -> String?
    private var launchDisposition: AppInstanceLaunchDisposition?
    private var didFinishLaunching = false
    private var runtime: MacToolsAppRuntime?
    private var instanceCoordinationTask: Task<Void, Never>?
    private var pendingURLs = [URL]()
    #if DEBUG
    private var showSettingsForTesting: (() -> Void)?
    #endif

    override convenience init() {
        self.init(acceptedURLSchemes: RightClickURLRouter.bundleURLSchemes())
    }

    init(
        acceptedURLSchemes: Set<String>,
        appleEventSenderPath: @escaping @MainActor () -> String? = AppleEventSender.currentSenderPath
    ) {
        instanceCoordinator = AppInstanceCoordinator()
        self.acceptedURLSchemes = Set(acceptedURLSchemes.map { $0.lowercased() })
        self.appleEventSenderPath = appleEventSenderPath
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else {
            launchDisposition = .primary(recoveryRequested: false)
            return
        }

        launchDisposition = .secondary(.timedOut)
        let commandHandler = instanceCommandHandler()
        instanceCoordinationTask = Task { [weak self, instanceCoordinator, commandHandler] in
            let forwardingDeadline = AppInstanceCoordinator.makeForwardingDeadline()
            let settingsRecoveryDeadline = AppInstanceCoordinator.makeSettingsRecoveryDeadline(
                forwardingDeadline: forwardingDeadline
            )
            await instanceCoordinator.setCommandHandler(commandHandler)
            let disposition: AppInstanceLaunchDisposition
            if await instanceCoordinator.claimPrimaryPortIfPossible() {
                disposition = .primary(recoveryRequested: false)
            } else {
                disposition = await instanceCoordinator.resolveSecondaryLaunch(
                    requestSettings: false,
                    deadline: settingsRecoveryDeadline
                )
            }
            guard !Task.isCancelled else { return }
            await self?.completeLaunch(disposition, forwardingDeadline: forwardingDeadline)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        guard case let .primary(recoveryRequested) = launchDisposition else { return }
        startRuntime(recoveryRequested: recoveryRequested)
    }

    private func startRuntime(recoveryRequested: Bool) {
        // applicationWillFinishLaunching deliberately skips instance coordination in
        // XCTest. Its synthetic primary disposition must not start live plugins,
        // clipboard capture, Keychain access, or preference backups in test hosts.
        guard !isRunningTests, runtime == nil else { return }
        let runtime = MacToolsAppRuntime()
        self.runtime = runtime
        runtime.start(notificationDelegate: self)
        let urls = pendingURLs
        pendingURLs.removeAll()
        runtime.handle(urls: urls)
        if recoveryRequested {
            _ = requestSettingsRecovery()
        }
    }

    private func completeLaunch(
        _ disposition: AppInstanceLaunchDisposition,
        forwardingDeadline: Date
    ) async {
        switch disposition {
        case let .primary(recoveryRequested):
            launchDisposition = disposition
            if didFinishLaunching {
                startRuntime(recoveryRequested: recoveryRequested)
            }
        case let .secondary(result):
            var urlForwardingResult = AppInstanceForwardingOutcome.acknowledged
            while !pendingURLs.isEmpty && urlForwardingResult == .acknowledged {
                let urls = pendingURLs
                pendingURLs.removeAll()
                urlForwardingResult = await instanceCoordinator.forwardURLs(
                    urls,
                    deadline: forwardingDeadline
                )
                if urlForwardingResult == .becamePrimary {
                    pendingURLs.insert(contentsOf: urls, at: 0)
                    launchDisposition = .primary(recoveryRequested: false)
                    startRuntime(recoveryRequested: false)
                    return
                }
            }

            AppLog.instanceCoordination.notice(
                "Secondary instance terminating: \(String(describing: result), privacy: .public), deep links: \(String(describing: urlForwardingResult), privacy: .public)"
            )
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let runtime else {
            _ = enqueuePendingURLs(urls)
            return
        }
        runtime.handle(urls: urls)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        // linkd reopens the app to serve Spotlight and Shortcuts requests; that is
        // not a person asking for Settings.
        guard !isAppIntentsServiceEvent(context: "reopen") else { return false }
        // A click on one of MacTools' own notifications (a finished download) reopens the app too;
        // the notification's own action handles it, and Settings stays shut.
        if let path = appleEventSenderPath(), AppleEventSender.isNotificationService(path: path) {
            AppLog.appIntents.notice("Ignored reopen Apple Event from Notification Centre")
            return false
        }
        _ = requestSettingsRecovery()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // linkd quits apps it launched for an App Intent after a short idle period.
        // MacTools is a resident menu-bar utility whose features (for example Keep
        // Awake) must outlive the intent, so only that system quit is declined.
        isAppIntentsServiceEvent(context: "quit") ? .terminateCancel : .terminateNow
    }

    private func isAppIntentsServiceEvent(context: StaticString) -> Bool {
        guard let path = appleEventSenderPath(),
              AppleEventSender.isAppIntentsService(path: path)
        else {
            return false
        }
        AppLog.appIntents.notice("Ignored \(context, privacy: .public) Apple Event from the App Intents service")
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        instanceCoordinationTask?.cancel()
        instanceCoordinationTask = nil
        runtime?.terminate()
        Task { [instanceCoordinator] in
            await instanceCoordinator.invalidate()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// A plugin notification can name a file to show in Finder when it is clicked, such as a
    /// finished download. Only an existing absolute path is revealed; nothing is opened.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let path = response.notification.request.content.userInfo["MacTools.revealFileURL"] as? String
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let path, path.hasPrefix("/"),
           FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        completionHandler()
    }

    private func requestSettingsRecovery() -> AppInstanceResponse {
        #if DEBUG
        if let showSettingsForTesting {
            showSettingsForTesting()
            return .accepted
        }
        #endif

        return runtime?.showSettings() == true ? .accepted : .notReady
    }

    private func instanceCommandHandler() -> @Sendable (AppInstanceCommand) -> AppInstanceResponse {
        { [weak self] command in
            MainActor.assumeIsolated {
                self?.handleInstanceCommand(command) ?? .notReady
            }
        }
    }

    private func handleInstanceCommand(_ command: AppInstanceCommand) -> AppInstanceResponse {
        switch command.command {
        case AppInstanceCommand.probe:
            return .accepted
        case AppInstanceCommand.showSettings:
            return requestSettingsRecovery()
        case AppInstanceCommand.openURLs:
            let urls = command.urlStrings.compactMap(URL.init(string:))
            guard urls.count == command.urlStrings.count else { return .invalid }
            if let runtime {
                runtime.handle(urls: urls)
                return .accepted
            }
            return enqueuePendingURLs(urls) ? .accepted : .invalid
        default:
            return .unsupported
        }
    }

    private func enqueuePendingURLs(_ urls: [URL]) -> Bool {
        guard pendingURLs.count + urls.count <= Self.maximumPendingURLCount else {
            AppLog.instanceCoordination.warning("Rejected deep links because the launch queue is full")
            return false
        }
        guard urls.allSatisfy({
            AppURLRouter.acceptsDeferredInput($0, acceptedSchemes: acceptedURLSchemes)
        }) else {
            AppLog.instanceCoordination.warning("Rejected invalid deep link during launch")
            return false
        }
        guard AppInstanceCommand.openURLsRequest(pendingURLs + urls).fitsPayloadSizeLimit else {
            AppLog.instanceCoordination.warning("Rejected deep links above the launch payload limit")
            return false
        }
        pendingURLs.append(contentsOf: urls)
        return true
    }

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    #if DEBUG
    var hasStartedRuntimeForTesting: Bool { runtime != nil }

    func setShowSettingsForRecoveryForTesting(_ action: @escaping () -> Void) {
        showSettingsForTesting = action
    }

    func handleInstanceRecoveryCommandForTesting() -> AppInstanceResponse {
        instanceCommandHandler()(AppInstanceCommand.showSettingsRequest())
    }

    func handleInstanceURLsCommandForTesting(_ urls: [URL]) -> AppInstanceResponse {
        instanceCommandHandler()(AppInstanceCommand.openURLsRequest(urls))
    }

    func pendingURLsForTesting() -> [URL] {
        pendingURLs
    }
    #endif
}

/// Identifies the process that sent the Apple Event AppKit is currently handling.
enum AppleEventSender {
    static let appIntentsServicePath = "/usr/libexec/linkd"

    static func isAppIntentsService(path: String) -> Bool {
        path == appIntentsServicePath
    }

    /// Notification Centre and the notification daemon, which reopen an app when its notification is clicked.
    static func isNotificationService(path: String) -> Bool {
        path.hasPrefix("/System/Library/CoreServices/NotificationCenter.app/") || path == "/usr/sbin/usernoted"
    }

    @MainActor
    static func currentSenderPath() -> String? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
              pid > 0
        else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Keeps one-shot automation events from observing an incomplete action registry
/// while installed dynamic plugins are still loading or updating.
@MainActor
final class AutomationStartupCoordinator {
    private let startAutomaticRules: () -> Void
    private(set) var hasStarted = false
    private(set) var isPreparing = false

    init(startAutomaticRules: @escaping () -> Void) {
        self.startAutomaticRules = startAutomaticRules
    }

    func actionRegistryDidBecomeReady() {
        guard !hasStarted else { return }
        hasStarted = true
        startAutomaticRules()
    }

    func startAfterActionRegistryPreparation(
        _ prepare: @MainActor () async -> Void
    ) async {
        guard !hasStarted, !isPreparing else { return }
        isPreparing = true
        await prepare()
        isPreparing = false
        actionRegistryDidBecomeReady()
    }
}
