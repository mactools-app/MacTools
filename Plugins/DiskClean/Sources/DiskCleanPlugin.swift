import Foundation
import SwiftUI
import MacToolsPluginKit

public final class DiskCleanPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DiskCleanPluginProvider(context: context)
    }
}

@MainActor
private struct DiskCleanPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        // Journal and audit logs both land here; fall back to the same convention when the host
        // provides no support directory.
        let storageDirectory = DiskCleanStorageLocation.resolve(supportDirectory: context.supportDirectory)
        let engine = DiskCleanScanEngine(localization: localization)
        // Shared journal + audit across sections and startup reconciliation so live cleanup and
        // recovery cannot race with separate instance-local locks.
        let journal = DiskCleanStagingJournal(directory: storageDirectory)
        let auditLog = DiskCleanAuditLog(directory: storageDirectory)
        let cleanupReadiness = DiskCleanCleanupReadiness(isReady: false)
        let executor = DiskCleanExecutor(
            storageDirectory: storageDirectory,
            journal: journal,
            auditLog: auditLog
        )

        func makeController(scope: DiskCleanScanScope) -> DiskCleanController {
            DiskCleanController(
                engine: engine,
                executor: executor,
                initialSnapshot: DiskCleanControllerSnapshot(
                    phase: .idle,
                    scope: scope,
                    scanResult: nil,
                    executionResult: nil,
                    isResultStale: false,
                    errorMessage: nil,
                    isCleanupReady: false
                ),
                localization: localization,
                cleanupReadiness: cleanupReadiness
            )
        }

        let purgeRoots = DiskCleanPurgeRootsModel()
        return [
            DiskCleanPlugin(
                controller: makeController(scope: .rules(choices: Set(DiskCleanChoice.allCases))),
                developerArtifactsController: makeController(scope: purgeRoots.scope),
                installersController: makeController(scope: .installers),
                purgeRoots: purgeRoots,
                localization: localization,
                storageDirectory: storageDirectory,
                journal: journal,
                auditLog: auditLog,
                cleanupReadiness: cleanupReadiness
            )
        ]
    }
}

@MainActor
final class DiskCleanPlugin: MacToolsPlugin, PluginSettingsPresenting, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    private enum ActionID {
        static let scanAndReview = "scan-and-review"
    }

    enum ControlID {
        static let scan = "disk-clean-scan"
        static let clean = "disk-clean-clean"
        static let confirmClean = "disk-clean-confirm-clean"
        static let cancelClean = "disk-clean-cancel-clean"
        static let openDetails = "disk-clean-open-details"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "disk-clean",
            title: localization.string("metadata.title", defaultValue: "磁盘清理"),
            iconName: "internaldrive",
            iconTint: Color(nsColor: .systemGreen),
            order: 90,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "扫描系统缓存、开发产物与残留安装包，默认移到废纸篓，执行前校验路径安全"
            )
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    /// Host injection: switch Settings to this plugin's configuration page (destination of "Open Details").
    var requestSettingsPresentation: (() -> Void)?

    private let controller: DiskCleanControlling
    /// Controllers for the two P2 sections on the detail page (design §10).
    ///
    /// They only appear in Settings and **do not wire `onStateChange`**: the menu-bar panel reflects
    /// the rules section only, so rebuilding the host menu on every P2 candidate stream would be
    /// pure overhead.
    private let developerArtifactsController: DiskCleanController
    private let installersController: DiskCleanController
    private let purgeRoots: DiskCleanPurgeRootsModel
    private let localization: PluginLocalization
    private let storageDirectory: URL
    private let journal: DiskCleanStagingJournal
    private let auditLog: DiskCleanAuditLog
    private let cleanupReadiness: DiskCleanCleanupReadiness
    private let reconciler: any DiskCleanStagingReconciling
    private var isExpanded = false

    init(
        controller: DiskCleanControlling = DiskCleanController(),
        developerArtifactsController: DiskCleanController = DiskCleanController(),
        installersController: DiskCleanController = DiskCleanController(),
        purgeRoots: DiskCleanPurgeRootsModel = DiskCleanPurgeRootsModel(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        storageDirectory: URL = DiskCleanStorageLocation.fallbackDirectory,
        journal: DiskCleanStagingJournal? = nil,
        auditLog: DiskCleanAuditLog? = nil,
        cleanupReadiness: DiskCleanCleanupReadiness = DiskCleanCleanupReadiness(isReady: true),
        reconciler: any DiskCleanStagingReconciling = DiskCleanStagingReconciler()
    ) {
        self.controller = controller
        self.developerArtifactsController = developerArtifactsController
        self.installersController = installersController
        self.purgeRoots = purgeRoots
        self.localization = localization
        self.storageDirectory = storageDirectory
        self.journal = journal ?? DiskCleanStagingJournal(directory: storageDirectory)
        self.auditLog = auditLog ?? DiskCleanAuditLog(directory: storageDirectory)
        self.cleanupReadiness = cleanupReadiness
        self.reconciler = reconciler
        self.controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
        // When scan roots change, push the new scope to the developer-artifacts section: if scope
        // and result diverge the Controller marks "rescan required". If this wire breaks, users
        // can clean with stale results against a folder they just removed.
        self.purgeRoots.onRootsChange = { [weak developerArtifactsController] roots in
            developerArtifactsController?.setScope(.developerArtifacts(roots: roots))
        }
    }

    var rowState: PluginPanelRowState {
        let snapshot = controller.snapshot

        return PluginPanelRowState(
            subtitle: subtitle(for: snapshot),
            isOn: snapshot.isBusy,
            isEnabled: true,
            isAvailable: true,
            detail: isExpanded ? buildDetail(for: snapshot) : nil,
            errorMessage: snapshot.errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: "full-disk-access",
                // PluginKit v5 has no Full Disk Access case. The host recognizes this
                // stable ID and provides the shared Full Disk Access presentation.
                kind: .automation,
                title: localization.string(
                    "permission.fullDiskAccess.title",
                    defaultValue: "完全磁盘访问"
                ),
                description: localization.string(
                    "permission.fullDiskAccess.description",
                    defaultValue: "用于扫描受 macOS 保护的缓存与应用数据；未授权时会安全跳过这些位置。"
                )
            ),
        ]
    }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }
    var actionDefinitions: [ActionDefinition] {
        let scanTitle = localization.string("panel.action.scan", defaultValue: "扫描")
        let reviewTitle = localization.string("panel.action.openDetails", defaultValue: "打开详情")
        return [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.scanAndReview),
                title: "\(metadata.title) · \(scanTitle)",
                description: "\(metadata.defaultDescription) · \(reviewTitle)",
                keywords: [metadata.title, scanTitle, reviewTitle],
                systemImage: "magnifyingglass",
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive, .cancellable],
                executionTimeoutSeconds: 600
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.actionID == ActionID.scanAndReview else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        return controller.snapshot.canScan
            ? .available
            : .unavailable(controller.snapshot.errorMessage ?? PluginKitLocalization.actionUnavailable)
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard invocation.reference.key.actionID == ActionID.scanAndReview else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionUnavailable) }
        }
        let controller = controller
        return ActionExecutionHandle(
            operation: { [weak self] in
                guard let self else { return .cancelled }
                guard controller.snapshot.canScan else {
                    return .failed(
                        message: controller.snapshot.errorMessage ?? PluginKitLocalization.actionUnavailable
                    )
                }
                self.requestSettingsPresentation?()
                controller.scan()
                while controller.snapshot.isBusy {
                    if Task.isCancelled { return .cancelled }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if let errorMessage = controller.snapshot.errorMessage {
                    return .failed(message: errorMessage)
                }
                return .succeeded()
            },
            cancel: {
                controller.cancelCurrentOperation()
            }
        )
    }

    var settingsPage: PluginSettingsPage? {
        guard let controller = controller as? DiskCleanController else {
            return nil
        }

        let localization = localization
        let historyProvider = DiskCleanAuditLogHistoryProvider(directory: storageDirectory)
        let developerArtifactsController = developerArtifactsController
        let installersController = installersController
        let purgeRoots = purgeRoots
        return .workspace(description: metadata.defaultDescription, scrolling: .host) { _ in
            DiskCleanDetailView(
                controller: controller,
                developerArtifactsController: developerArtifactsController,
                installersController: installersController,
                purgeRoots: purgeRoots,
                localization: localization,
                historyProvider: historyProvider,
                showsHeader: false,
                contentPadding: 0,
                minimumContentHeight: 0
            )
        }
    }

    func refresh() {}

    /// Startup reconciliation (design §7.6).
    ///
    /// If the previous run crashed between "renamed to staging name" and "disposition finished",
    /// only the journal still knows the orphan's original name. Recover it here: SafetyPolicy
    /// protects these objects from every scan, and reconciliation is the only other path that can
    /// touch them. Cleanup stays disabled until this finishes so a live clean cannot race recovery.
    func activate(context: PluginRuntimeContext) {
        let journal = journal
        let auditLog = auditLog
        let cleanupReadiness = cleanupReadiness
        let reconciler = reconciler
        let rulesController = controller as? DiskCleanController
        let developerController = developerArtifactsController
        let installersController = installersController
        Task.detached(priority: .utility) {
            // Shared journal instance is required: separate journals have separate locks and can
            // compact a live begin record while rename is still in flight.
            if let concrete = reconciler as? DiskCleanStagingReconciler {
                _ = concrete.reconcile(journal: journal, auditLog: auditLog)
            } else {
                await reconciler.reconcile(storageDirectory: journal.directory)
            }
            cleanupReadiness.markReady()
            await MainActor.run {
                rulesController?.refreshCleanupReadiness()
                developerController.refreshCleanupReadiness()
                installersController.refreshCleanupReadiness()
            }
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        controller.cancelCurrentOperation()
        developerArtifactsController.cancelCurrentOperation()
        installersController.cancelCurrentOperation()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(value):
            isExpanded = value
            onStateChange?()
        case let .invokeAction(controlID):
            handleInvoke(controlID: controlID)
        case .setSwitch,
             .setSelection,
             .setNavigationSelection,
             .clearNavigationSelection,
             .setDate,
             .setSlider:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == "full-disk-access" else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
        let isGranted = DiskCleanFullDiskAccessProbe.shared.hasFullDiskAccess
        return PluginPermissionState(
            isGranted: isGranted,
            footnote: isGranted ? nil : localization.string(
                "detail.fda.footnote",
                defaultValue: "授权后请退出并重新打开 MacTools，受保护位置才会加入扫描。"
            )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == "full-disk-access" else { return }
        DiskCleanFullDiskAccessGuide.openSettings()
    }
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    private func handleInvoke(controlID: String) {
        switch controlID {
        case ControlID.scan:
            controller.scan()
        case ControlID.clean:
            controller.clean()
        case ControlID.confirmClean:
            controller.confirmPendingClean()
        case ControlID.cancelClean:
            controller.cancelPendingClean()
        case ControlID.openDetails:
            requestSettingsPresentation?()
        default:
            break
        }
    }

    private func buildDetail(for snapshot: DiskCleanControllerSnapshot) -> PluginPanelDetail {
        let scanControl = PluginPanelControl(
            id: ControlID.scan,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.scan", defaultValue: "扫描"),
            actionIconSystemName: "magnifyingglass",
            isEnabled: snapshot.canScan
        )

        let cleanControl = PluginPanelControl(
            id: ControlID.clean,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: cleanActionTitle(for: snapshot),
            actionIconSystemName: "trash",
            showsLeadingDivider: true,
            isEnabled: snapshot.canClean
        )

        let openDetailsControl = PluginPanelControl(
            id: ControlID.openDetails,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.openDetails", defaultValue: "打开详情"),
            actionIconSystemName: "arrow.up.right.square",
            actionBehavior: .dismissBeforeHandling,
            isEnabled: true
        )

        // Permanent delete is two-step: during confirmation swap "Clean" for a Confirm/Cancel pair
        // so one button does not carry two meanings. Full styling (detail confirmationDialog, risk
        // colors) is left to M5.
        let actionControls = snapshot.phase == .confirming
            ? confirmationControls(for: snapshot)
            : [cleanControl]

        return PluginPanelDetail(
            primaryControls: [scanControl] + actionControls + [openDetailsControl],
            secondaryPanel: nil
        )
    }

    /// Clean-button title. Include selection count and estimated bytes, and state plainly what will
    /// happen for the chosen removal mode—trash mode is single-step, so the button itself is the
    /// last explanation (design §8.4).
    private func cleanActionTitle(for snapshot: DiskCleanControllerSnapshot) -> String {
        let count = snapshot.selection.selectedCount
        guard count > 0 else {
            return snapshot.removalMode == .trash
                ? localization.string("panel.action.trash", defaultValue: "移到废纸篓")
                : localization.string("panel.action.clean", defaultValue: "清理")
        }

        let bytes = byteText(snapshot.selection.selectedEstimatedBytes)
        switch snapshot.removalMode {
        case .trash:
            return localization.format(
                "panel.action.trashSelected",
                defaultValue: "移到废纸篓 · %d 项 · 约 %@",
                count,
                bytes
            )
        case .permanent:
            return localization.format(
                "panel.action.cleanSelected",
                defaultValue: "清理 · %d 项 · 约 %@",
                count,
                bytes
            )
        }
    }

    private func confirmationControls(for snapshot: DiskCleanControllerSnapshot) -> [PluginPanelControl] {
        let confirmTitle = snapshot.pendingPlan.map { plan in
            localization.format(
                "panel.action.confirmClean",
                defaultValue: "确认永久清理 %d 项 · 约 %@",
                plan.itemCount,
                byteText(plan.totalEstimatedBytes)
            )
        } ?? localization.string("panel.action.confirmCleanFallback", defaultValue: "确认永久清理")

        let confirmControl = PluginPanelControl(
            id: ControlID.confirmClean,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: confirmTitle,
            actionIconSystemName: "exclamationmark.triangle",
            showsLeadingDivider: true,
            isEnabled: true
        )

        let cancelControl = PluginPanelControl(
            id: ControlID.cancelClean,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.cancelClean", defaultValue: "取消"),
            actionIconSystemName: "xmark",
            isEnabled: true
        )

        return [confirmControl, cancelControl]
    }

    private func subtitle(for snapshot: DiskCleanControllerSnapshot) -> String {
        // While scanning, accumulate reclaimable estimate live (host publishes snapshots ~250ms-throttled).
        if snapshot.phase == .scanning, let result = snapshot.scanResult, !result.candidates.isEmpty {
            return localization.format(
                "panel.subtitle.scanning",
                defaultValue: "正在扫描 · %d 项，约 %@",
                result.cleanableCandidates.count,
                byteText(result.cleanableSizeBytes)
            )
        }

        if snapshot.phase == .scanned,
           !snapshot.isResultStale,
           !snapshot.isResultExpired,
           let result = snapshot.scanResult {
            // "(limited)" always derives from limitations (design §4.5, §8.2), not from "some
            // protected candidate happened to be scanned".
            let base = localization.format(
                "panel.subtitle.scanned",
                defaultValue: "%d 项，约 %@",
                result.cleanableCandidates.count,
                byteText(result.cleanableSizeBytes)
            )
            guard result.isLimited else { return base }
            return base + localization.string("panel.subtitle.limitedSuffix", defaultValue: "（受限）")
        }

        if snapshot.phase == .confirming, let plan = snapshot.pendingPlan {
            return localization.format(
                "panel.subtitle.confirming",
                defaultValue: "确认永久清理 %d 项 · 约 %@",
                plan.itemCount,
                byteText(plan.totalEstimatedBytes)
            )
        }

        if snapshot.phase == .completed,
           let result = snapshot.executionResult {
            if result.wasCancelled {
                return localization.format(
                    "panel.subtitle.cancelled",
                    defaultValue: "已停止 · 已处理 %d 项",
                    result.itemResults.count
                )
            }
            // Trash mode never says "reclaimed": objects still sit in Trash, so space is not truly freed (design §7.7).
            let defaultValue = result.mode == .trash ? "已移到废纸篓约 %@" : "已清理约 %@"
            return localization.format(
                result.mode == .trash ? "panel.subtitle.trashed" : "panel.subtitle.completed",
                defaultValue: defaultValue,
                byteText(result.reclaimedBytes)
            )
        }

        return snapshot.subtitle(localization: localization)
    }

    private func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(PluginRuntimeLocalization.locale))
    }
}
