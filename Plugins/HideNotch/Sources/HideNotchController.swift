import AppKit
import Foundation
import MacToolsPluginKit

@MainActor
final class HideNotchController: HideNotchWallpaperControlling {
    private struct NotificationObservation: @unchecked Sendable {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    var onStateChange: (() -> Void)?

    private let displayCatalog: HideNotchDisplayCatalogProviding
    private let maskManager: HideNotchDesktopMaskManaging
    private let localization: PluginLocalization
    private let stateStore: HideNotchStateStoring
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let logger = HideNotchLog.controller

    private var isProcessing = false
    private var pendingRefresh = false
    private var errorMessage: String?
    private var observationTokens: [NotificationObservation] = []
    private var debouncedRefreshTask: Task<Void, Never>?

    init(
        displayCatalog: HideNotchDisplayCatalogProviding = SystemHideNotchDisplayCatalog(),
        maskManager: HideNotchDesktopMaskManaging = HideNotchDesktopMaskManager(),
        stateStore: HideNotchStateStoring? = nil,
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "hide-notch"),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.localization = localization
        self.displayCatalog = displayCatalog
        self.maskManager = maskManager
        self.stateStore = stateStore ?? HideNotchStateStore(context: context)
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter

        installObservers()
    }

    deinit {
        debouncedRefreshTask?.cancel()

        for observation in observationTokens {
            observation.center.removeObserver(observation.token)
        }
    }

    func snapshot() -> HideNotchSnapshot {
        let supportedRecords = displayCatalog.listDisplayRecords().filter { $0.context.isSupported }
        let managedDisplayCount: Int

        if stateStore.desiredEnabled {
            managedDisplayCount = supportedRecords.reduce(into: 0) { count, record in
                if maskManager.managedDisplayIdentifiers.contains(record.context.displayIdentifier) {
                    count += 1
                }
            }
        } else {
            managedDisplayCount = 0
        }

        return HideNotchSnapshot(
            hasSupportedDisplay: !supportedRecords.isEmpty,
            supportedDisplayCount: supportedRecords.count,
            managedDisplayCount: managedDisplayCount,
            unsupportedVisibleDisplayCount: 0,
            pendingRestoreCount: 0,
            isEnabled: stateStore.desiredEnabled,
            isProcessing: isProcessing,
            isAwaitingDisplay: stateStore.desiredEnabled && supportedRecords.isEmpty,
            errorMessage: errorMessage
        )
    }

    func refresh() {
        scheduleSync()
    }

    func setEnabled(_ isEnabled: Bool) {
        stateStore.desiredEnabled = isEnabled
        errorMessage = nil
        scheduleSync(forceNotify: true)
    }

    func setEnabledAndWait(_ isEnabled: Bool) async -> HideNotchSyncResult {
        let previousValue = stateStore.desiredEnabled
        setEnabled(isEnabled)
        await waitForSynchronization()
        guard let targetError = errorMessage else {
            return stateStore.desiredEnabled == isEnabled
                ? .succeeded
                : .failed(message: PluginKitLocalization.actionUnavailable)
        }

        stateStore.desiredEnabled = previousValue
        if !previousValue {
            maskManager.hideAllMasks()
        }
        errorMessage = nil
        scheduleSync(forceNotify: true)
        await waitForSynchronization()
        if let rollbackError = errorMessage {
            return .failed(message: localizationFailure(
                target: targetError,
                rollback: rollbackError
            ))
        }
        errorMessage = targetError
        onStateChange?()
        return .failed(message: targetError)
    }

    private func waitForSynchronization() async {
        while isProcessing || pendingRefresh {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func localizationFailure(target: String, rollback: String) -> String {
        localization.format("error.rollbackFailed.format", defaultValue: "%@；恢复先前状态失败：%@", target, rollback)
    }

    private func scheduleSync(forceNotify: Bool = false) {
        if isProcessing {
            pendingRefresh = true
            if forceNotify {
                onStateChange?()
            }
            return
        }

        if !forceNotify,
           !stateStore.desiredEnabled,
           maskManager.managedDisplayIdentifiers.isEmpty {
            onStateChange?()
            return
        }

        isProcessing = true
        onStateChange?()

        Task { @MainActor [weak self] in
            self?.performSync()
        }
    }

    private func performSync() {
        let supportedRecords = displayCatalog.listDisplayRecords().filter { $0.context.isSupported }

        do {
            if stateStore.desiredEnabled {
                if supportedRecords.isEmpty {
                    maskManager.hideAllMasks()
                    logger.notice(
                        "hide-notch refresh skipped because no supported builtin notched display was found"
                    )
                } else {
                    try maskManager.synchronizeMasks(for: supportedRecords.map(\.context))
                    logger.info(
                        "hide-notch synchronized desktop masks count=\(supportedRecords.count, privacy: .public)"
                    )
                }
            } else {
                maskManager.hideAllMasks()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            logger.error(
                "hide-notch sync failed error=\(error.localizedDescription, privacy: .public)"
            )
        }

        isProcessing = false
        onStateChange?()

        if pendingRefresh {
            pendingRefresh = false
            scheduleSync()
        }
    }

    private func installObservers() {
        let activeSpaceToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedRefresh()
            }
        }
        observationTokens.append(
            NotificationObservation(center: workspaceNotificationCenter, token: activeSpaceToken)
        )

        let screensDidWakeToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedRefresh()
            }
        }
        observationTokens.append(
            NotificationObservation(center: workspaceNotificationCenter, token: screensDidWakeToken)
        )

        let screenParametersToken = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedRefresh()
            }
        }
        observationTokens.append(
            NotificationObservation(center: notificationCenter, token: screenParametersToken)
        )
    }

    private func scheduleDebouncedRefresh() {
        debouncedRefreshTask?.cancel()
        debouncedRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run { [weak self] in
                self?.refresh()
            }
        }
    }
}
