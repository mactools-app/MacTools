import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

// MARK: - Factory

public final class QuitAppsPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        QuitAppsPluginProvider(context: context)
    }
}

@MainActor
private struct QuitAppsPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [QuitAppsPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

// MARK: - Plugin

@MainActor
final class QuitAppsPlugin: MacToolsPlugin, DropZoneAnchorProviding, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        let descriptor = rowDescriptor
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: descriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("metadata.title", defaultValue: metadata.title),
                systemImage: metadata.iconName,
                control: .button,
                state: state,
                menuActionBehavior: descriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    private enum ActionID {
        static let chooseApps = "choose-apps"
    }

    // MARK: Metadata

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "quit-apps",
            title: localization.string("metadata.title", defaultValue: "退出应用"),
            iconName: "power",
            iconTint: Color(nsColor: .systemRed),
            order: 96,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "选择并退出正在运行的应用"
            )
        )
    }

    let rowDescriptor: PluginPanelRowDescriptor

    // MARK: DropZoneAnchorProviding

    var anchorRectProvider: (() -> NSRect?)?

    // MARK: Callbacks

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    // MARK: Private State

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "QuitAppsPlugin"
    )
    private let localization: PluginLocalization
    private let runningAppCountProvider: () -> Int
    private let selectionPresenter: (() -> Void)?
    private var selectionWindow: QuitAppsSelectionWindow?
    private var runningAppCount: Int = 0
    private var appObservers: [NSObjectProtocol] = []

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        runningAppCountProvider: @escaping () -> Int = {
            QuitAppsApplicationCatalog.currentApplicationCount()
        },
        selectionPresenter: (() -> Void)? = nil
    ) {
        self.localization = localization
        self.runningAppCountProvider = runningAppCountProvider
        self.selectionPresenter = selectionPresenter
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: { localization.string("panel.button.choose", defaultValue: "选择") }
        )
    }

    // MARK: - Panel row

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: runningAppCount > 0
                ? localization.format(
                    "panel.subtitle.runningCountFormat",
                    defaultValue: "正在运行 %d 个应用",
                    runningAppCount
                )
                : localization.string("panel.subtitle.none", defaultValue: "无正在运行的应用"),
            isOn: false,
            isEnabled: runningAppCount > 0,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.chooseApps),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "quit", "apps"],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.actionID == ActionID.chooseApps else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        return runningAppCount > 0
            ? .available
            : .unavailable(localization.string("panel.subtitle.none", defaultValue: "无正在运行的应用"))
    }

    // MARK: Lifecycle

    func activate(context: PluginRuntimeContext) {
        refreshRunningAppCount()
        setupAppObservers()
    }

    func deactivate(reason: PluginDeactivationReason) {
        removeAppObservers()
        closeSelectionWindow()
    }

    func refresh() {
        refreshRunningAppCount()
    }

    // MARK: Action

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case .invokeAction(let controlID):
            if controlID == "execute" {
                showSelectionWindow()
            }
        default:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let availability = actionAvailability(for: invocation.reference)
        guard availability.isAvailable else {
            return ActionExecutionHandle {
                .failed(message: availability.reason ?? PluginKitLocalization.actionUnavailable)
            }
        }
        showSelectionWindow()
        return ActionExecutionHandle { .succeeded() }
    }

    // MARK: Private – App Count

    private func refreshRunningAppCount() {
        let count = runningAppCountProvider()
        if runningAppCount != count {
            runningAppCount = count
            onStateChange?()
        }
    }

    private func setupAppObservers() {
        guard appObservers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        let launched = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshRunningAppCount() }
        }
        let terminated = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshRunningAppCount() }
        }
        appObservers = [launched, terminated]
    }

    private func removeAppObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for obs in appObservers { nc.removeObserver(obs) }
        appObservers.removeAll()
    }

    // MARK: Private – Window

    private func showSelectionWindow() {
        if let selectionPresenter {
            selectionPresenter()
            return
        }
        if let existing = selectionWindow, existing.isVisible {
            PluginPresentationSafety.prepareForWindowOrdering(existing)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = QuitAppsSelectionWindow(
            localization: localization,
            onDismiss: { [weak self] in
                self?.closeSelectionWindow()
            }
        )
        positionWindow(window)
        PluginPresentationSafety.prepareForWindowOrdering(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        selectionWindow = window
    }

    private func closeSelectionWindow() {
        guard let window = selectionWindow else { return }
        selectionWindow = nil
        window.dismiss(notifyingOwner: false)
    }

    private func positionWindow(_ window: NSWindow) {
        let windowSize = window.frame.size

        if let anchorRect = anchorRectProvider?() {
            let screenMaxX = NSScreen.main?.frame.maxX ?? 1440
            let rawX = anchorRect.midX - windowSize.width / 2
            let x = max(8, min(rawX, screenMaxX - windowSize.width - 8))
            let y = anchorRect.minY - windowSize.height - 4
            window.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        guard let screen = NSScreen.main else { return }
        let menuBarThickness = NSStatusBar.system.thickness
        let x = screen.frame.midX - windowSize.width / 2
        let y = screen.frame.maxY - menuBarThickness - windowSize.height - 12
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
