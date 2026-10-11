import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class XcodeCleanPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        XcodeCleanPluginProvider(context: context)
    }
}

@MainActor
private struct XcodeCleanPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let monitor = XcodeCleanRunningMonitor()
        let scanner = XcodeCleanScanner(localization: localization)
        let executor = XcodeCleanExecutor()
        let controller = XcodeCleanController(
            scanner: scanner,
            executor: executor,
            localization: localization
        )
        return [XcodeCleanPlugin(
            controller: controller,
            runningMonitor: monitor,
            localization: localization
        )]
    }
}

@MainActor
protocol XcodeCleanConfirmationPresenting: AnyObject {
    var isPresenting: Bool { get }

    func present(
        candidates: [XcodeCleanCandidate],
        anchorRect: NSRect?,
        onConfirm: @escaping (Set<XcodeCleanCandidate.ID>) -> Void,
        onCancel: @escaping () -> Void
    )
    func dismiss()
}

@MainActor
final class XcodeCleanConfirmWindowPresenter: XcodeCleanConfirmationPresenting {
    private var window: XcodeCleanConfirmWindow?
    private let localization: PluginLocalization

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
    }

    var isPresenting: Bool { window?.isVisible == true }

    func present(
        candidates: [XcodeCleanCandidate],
        anchorRect: NSRect?,
        onConfirm: @escaping (Set<XcodeCleanCandidate.ID>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss()

        let window = XcodeCleanConfirmWindow(
            candidates: candidates,
            localization: localization,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
        window.attachDismissHandler { [weak self] in
            self?.window = nil
        }
        position(window: window, anchorRect: anchorRect)
        PluginPresentationSafety.prepareForWindowOrdering(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }

    private func position(window: NSWindow, anchorRect: NSRect?) {
        let windowSize = window.frame.size

        if let anchorRect {
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

@MainActor
final class XcodeCleanPlugin:
    MacToolsPlugin, DropZoneAnchorProviding, PluginSettingsPresenting, PluginActionProviding {
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
        static let scan = "xcode-clean-scan"
        static let clean = "xcode-clean-clean"
        static let stop = "xcode-clean-stop"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "xcode-clean",
            title: localization.string("metadata.title", defaultValue: "Xcode 清理"),
            iconName: "hammer",
            iconTint: Color(nsColor: .systemBlue),
            order: 91,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "分类清理 Xcode DerivedData、设备支持、归档与缓存"
            )
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var anchorRectProvider: (() -> NSRect?)?
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    let controller: XcodeCleanControlling
    private let runningMonitor: XcodeCleanRunningMonitoring
    private let confirmationPresenter: XcodeCleanConfirmationPresenting
    private let localization: PluginLocalization
    private var isExpanded = false

    init(
        controller: XcodeCleanControlling,
        runningMonitor: XcodeCleanRunningMonitoring,
        confirmationPresenter: XcodeCleanConfirmationPresenting? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.controller = controller
        self.runningMonitor = runningMonitor
        self.localization = localization
        self.confirmationPresenter = confirmationPresenter ?? XcodeCleanConfirmWindowPresenter(localization: localization)

        self.controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
        self.runningMonitor.onStateChange = { [weak self] in
            guard let self else { return }
            self.controller.updateXcodeRunningState(self.runningMonitor.isXcodeRunning)
        }
    }

    func activate(context: PluginRuntimeContext) {
        runningMonitor.start()
        controller.updateXcodeRunningState(runningMonitor.isXcodeRunning)
    }

    func deactivate(reason: PluginDeactivationReason) {
        confirmationPresenter.dismiss()
        controller.cancelCurrentOperation()
        runningMonitor.stop()
    }

    func refresh() {
        runningMonitor.refresh()
        controller.updateXcodeRunningState(runningMonitor.isXcodeRunning)
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

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }
    var actionDefinitions: [ActionDefinition] {
        let scanTitle = localization.string("panel.action.scan", defaultValue: "扫描")
        return [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.scanAndReview),
                title: "\(metadata.title) · \(scanTitle)",
                description: metadata.defaultDescription,
                keywords: [metadata.title, scanTitle, "Xcode"],
                systemImage: "magnifyingglass",
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive, .cancellable],
                executionTimeoutSeconds: 300
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
        guard let controller = controller as? XcodeCleanController else { return nil }
        let localization = localization
        return .workspace(description: metadata.defaultDescription, scrolling: .host) { _ in
            XcodeCleanDetailView(
                controller: controller,
                localization: localization,
                showsHeader: false,
                contentPadding: 0,
                minimumContentHeight: 0
            )
        }
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
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    // MARK: - Private

    private func handleInvoke(controlID: String) {
        switch controlID {
        case ControlID.scan:
            controller.scan()
        case ControlID.clean:
            presentConfirmation()
        case ControlID.stop:
            controller.cancelCurrentOperation()
        default:
            break
        }
    }

    private func presentConfirmation() {
        guard let scanResult = controller.snapshot.scanResult else { return }
        let candidates = scanResult.cleanableCandidates
        guard !candidates.isEmpty else { return }

        confirmationPresenter.present(
            candidates: candidates,
            anchorRect: anchorRectProvider?(),
            onConfirm: { [weak self] selectedIDs in
                self?.controller.cleanSelected(candidateIDs: selectedIDs)
            },
            onCancel: {}
        )
    }

    private func buildDetail(for snapshot: XcodeCleanSnapshot) -> PluginPanelDetail {
        var controls: [PluginPanelControl] = []

        controls.append(
            PluginPanelControl(
                id: ControlID.scan,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: snapshot.phase == .scanning
                    ? localization.string("panel.action.scanning", defaultValue: "扫描中…")
                    : localization.string("panel.action.scan", defaultValue: "扫描"),
                actionIconSystemName: "magnifyingglass",
                isEnabled: snapshot.canScan
            )
        )

        controls.append(
            PluginPanelControl(
                id: ControlID.clean,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: snapshot.phase == .cleaning
                    ? localization.string("panel.action.cleaning", defaultValue: "清理中…")
                    : localization.string("panel.action.clean", defaultValue: "清理"),
                actionIconSystemName: "trash",
                actionBehavior: .dismissBeforeHandling,
                showsLeadingDivider: true,
                isEnabled: snapshot.canClean
            )
        )

        if snapshot.isBusy {
            controls.append(
                PluginPanelControl(
                    id: ControlID.stop,
                    kind: .actionRow,
                    options: [],
                    selectedOptionID: nil,
                    dateValue: nil,
                    minimumDate: nil,
                        displayedComponents: nil,
                        datePickerStyle: nil,
                        sectionTitle: nil,
                        actionTitle: localization.string("panel.action.stop", defaultValue: "停止"),
                        actionIconSystemName: "xmark.circle",
                        showsLeadingDivider: true,
                        isEnabled: true
                )
            )
        }

        return PluginPanelDetail(primaryControls: controls, secondaryPanel: nil)
    }

    private func subtitle(for snapshot: XcodeCleanSnapshot) -> String {
        if snapshot.isXcodeRunning {
            return localization.string("panel.subtitle.xcodeRunning", defaultValue: "请先退出 Xcode")
        }

        switch snapshot.phase {
        case .idle:
            return localization.string("panel.subtitle.idle", defaultValue: "等待扫描")
        case .scanning:
            return localization.string("panel.subtitle.scanning", defaultValue: "正在扫描…")
        case .scanned:
            if snapshot.isResultStale {
                return localization.string("panel.subtitle.stale", defaultValue: "勾选已更新，请重新扫描")
            }
            if let result = snapshot.scanResult {
                return localization.format(
                    "panel.subtitle.scanned",
                    defaultValue: "%d 项，%@",
                    result.cleanableCandidates.count,
                    byteText(result.cleanableSizeBytes)
                )
            }
            return localization.string("panel.subtitle.scanComplete", defaultValue: "扫描完成")
        case .cleaning:
            return localization.string("panel.subtitle.cleaning", defaultValue: "正在清理…")
        case .completed:
            if let result = snapshot.executionResult {
                return localization.format(
                    "panel.subtitle.completed",
                    defaultValue: "已释放 %@",
                    byteText(result.reclaimedBytes)
                )
            }
            return localization.string("panel.subtitle.cleanComplete", defaultValue: "清理完成")
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        XcodeCleanByteFormatter.string(fromByteCount: bytes)
    }
}
