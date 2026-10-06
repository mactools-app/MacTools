import AppKit
import ApplicationServices
import Carbon
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class WindowLayoutsPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        WindowLayoutsPluginProvider(context: context)
    }
}

@MainActor
private struct WindowLayoutsPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [WindowLayoutsPlugin(context: context)]
    }
}

@MainActor
final class WindowLayoutsPlugin: MacToolsPlugin, AccessibilityPermissionRefreshing, DisplayTopologyRefreshing,
    PluginActionProviding, PluginActionPermissionProviding,
    PluginActionExposureProviding, PluginActionExecutionRevisionProviding,
    PluginActionSafetyStateChangeProviding,
    PluginActionShortcutSettingsProviding, PluginRetiredActionShortcutProviding,
    PluginActionShortcutPresetApplying, PluginActionShortcutReplacementTransactionApplying,
    PluginActionShortcutAssignmentChangeHandling, ObservableObject,
    PluginFocusedWindowTargetConsuming, PluginInputGestureClaimProviding,
    PluginInputGestureConflictConsuming
{
    private enum PermissionID { static let accessibility = "accessibility" }
    private enum SettingsID {
        static let gap = "gap"
        static let cyclesHalves = "cycles-halves"
        static let respectsStageManager = "respects-stage-manager"
        static let showsCommandFeedback = "shows-command-feedback"
        static let centeredGuidesEnabled = "centered-guides.enabled"
        static let modifierDragEnabled = "modifier-drag.enabled"
        static let modifierDragShowsIndicator = "modifier-drag.shows-indicator"
        static let reset = "reset"
        static let addCustom = "add-custom"
    }

    private enum RetiredActionID {
        static let nextDesktop = "move-to-next-desktop"
        static let previousDesktop = "move-to-previous-desktop"
        static let all: Set<String> = [nextDesktop, previousDesktop]
    }

    private struct ActionDescriptor {
        let operation: WindowLayoutOperation
        let title: String
        let description: String
        let systemImage: String
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "window-layouts",
            title: localization.string("metadata.title", defaultValue: "窗口布局"),
            iconName: "rectangle.3.group",
            iconTint: Color(nsColor: .systemTeal),
            order: 65,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "排列聚焦窗口并创建自定义布局"
            )
        )
    }
    var onStateChange: (() -> Void)?
    var onActionSafetyStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var previewActionShortcutPreset: ((
        Set<String>,
        [String: ShortcutBinding]
    ) -> PluginActionShortcutPresetPreview)?
    var applyActionShortcutPreset: ((Set<String>, [String: ShortcutBinding]) -> String?)?
    var currentActionShortcutBindings: ((Set<String>) -> [String: [ShortcutBinding]])?
    var performActionShortcutReplacementTransaction: ((
        Set<String>,
        [String: ShortcutBinding],
        () -> String?
    ) -> String?)?
    @Published private(set) var actionShortcutAssignmentRevision: UInt64 = 0
    @Published private(set) var customCommandSettingsRevision: UInt64 = 0
    @Published private(set) var customCommandDeletionError: String?
    var focusedWindowTargetProvider: (() -> PluginFocusedWindowTarget?)? {
        didSet {
            applicationTarget.targetProvider = focusedWindowTargetProvider
        }
    }

    private let localization: PluginLocalization
    private let store: WindowLayoutsStore
    private let executor: WindowLayoutExecuting
    private let applicationTarget: WindowLayoutsApplicationTarget
    private let accessibilityTrusted: @MainActor @Sendable () -> Bool
    private let requestAccessibilityTrust: @MainActor @Sendable (Bool) -> Bool
    private let makeModifierDragSession: @MainActor () -> any WindowModifierDragSessionManaging
    private var isAccessibilityGranted: Bool
    private var modifierDragSession: (any WindowModifierDragSessionManaging)?
    private var modifierDragError: String?
    private var modifierDragMonitorStartFailed = false
    private var externalGestureConflicts: [PluginInputGestureConflict] = []

    var actionExecutionRevision: UInt64 { store.revision }

    func actionShortcutAssignmentsDidChange() {
        actionShortcutAssignmentRevision &+= 1
    }

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "window-layouts"),
        executor: WindowLayoutExecuting? = nil,
        makeModifierDragSession: (@MainActor () -> any WindowModifierDragSessionManaging)? = nil,
        accessibilityTrusted: @escaping @MainActor @Sendable () -> Bool = AXIsProcessTrusted,
        requestAccessibilityTrust: @escaping @MainActor @Sendable (Bool) -> Bool = WindowLayoutsAccessibilityCheck.requestTrust
    ) {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        let store = WindowLayoutsStore(storage: context.storage)
        self.store = store
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.makeModifierDragSession = makeModifierDragSession ?? {
            WindowModifierDragSession(
                hudPresenter: WindowModifierDragHUDController(
                    movePointerTitleProvider: {
                        localization.string(
                            "settings.modifierDrag.hud.movePointer",
                            defaultValue: "Move the pointer to reposition the window"
                        )
                    },
                    movingWindowTitleProvider: {
                        localization.string(
                            "settings.modifierDrag.hud.movingWindow",
                            defaultValue: "Moving window — release the keys to finish"
                        )
                    }
                ),
                localizedErrorMessage: { error in
                    switch error {
                    case .noWindowUnderPointer:
                        return localization.string(
                            "error.noWindowUnderPointer",
                            defaultValue: "No movable window under pointer"
                        )
                    case .windowCannotMove:
                        return localization.string(
                            "error.windowCannotMove",
                            defaultValue: "Window cannot move"
                        )
                    case .accessibilityRequired:
                        return localization.string(
                            "error.accessibilityRequired",
                            defaultValue: "Accessibility required"
                        )
                    default:
                        return localization.string(
                            "error.frameWriteFailed",
                            defaultValue: "Unable to move window"
                        )
                    }
                }
            )
        }
        self.isAccessibilityGranted = accessibilityTrusted()
        let applicationTarget = WindowLayoutsApplicationTarget()
        self.applicationTarget = applicationTarget
        if let executor {
            self.executor = executor
        } else {
            let accessibilityWorker = WindowAccessibilityWorker()
            let frameAdapter = AccessibilityWindowFrameAdapter(worker: accessibilityWorker)
            self.executor = WindowLayoutService(
                focusedWindowResolver: SystemFocusedWindowResolver(
                    accessibilityTrusted: accessibilityTrusted,
                    frontmostTarget: { applicationTarget.target() },
                    worker: accessibilityWorker
                ),
                frameReader: frameAdapter,
                frameWriter: frameAdapter,
                fullScreenWriter: frameAdapter
            )
        }
        self.store.onMutation = { [weak self] in
            self?.customCommandSettingsRevision &+= 1
            self?.onStateChange?()
        }
        self.store.onSafetyPolicyMutation = { [weak self] in
            self?.onActionSafetyStateChange?()
        }
    }

    var activeInputGestureClaims: [PluginInputGestureClaim] {
        guard store.modifierDragEnabled,
              isAccessibilityGranted,
              !modifierDragMonitorStartFailed
        else { return [] }
        return [modifierDragClaim]
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localizedKey("permission.accessibility.title", "辅助功能"),
                description: localizedKey(
                    "permission.accessibility.description",
                    "用于读取并调整应用窗口的位置、大小和全屏状态。"
                )
            )
        ]
    }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: settingsSections)
    }

    var actionShortcutSettingsConfiguration: PluginActionShortcutSettingsConfiguration {
        PluginActionShortcutSettingsConfiguration(
            title: localizedKey("settings.shortcuts.title", "窗口布局快捷键"),
            description: localizedKey(
                "settings.shortcuts.description",
                "使用预设后，可单独修改任意全局快捷键。"
            ),
            actionIDs: Set(WindowLayoutOperation.allCases.map(\.rawValue) + store.customCommands.map(\.actionID))
        )
    }

    var retiredActionShortcutIDs: Set<String> { RetiredActionID.all }

    var actionDefinitions: [ActionDefinition] {
        let builtIns = actionDescriptors.map { descriptor in
            actionDefinition(
                actionID: descriptor.operation.rawValue,
                title: localizedKey(
                    "action.\(descriptor.operation.rawValue).title",
                    descriptor.title
                ),
                description: localizedKey(
                    "action.\(descriptor.operation.rawValue).description",
                    descriptor.description
                ),
                systemImage: descriptor.systemImage,
                externalInvocationPolicy: .allowed
            )
        }
        let custom = store.customCommands.map { command in
            actionDefinition(
                actionID: command.actionID,
                title: command.name,
                description: localizedKey(
                    "action.custom.description",
                    "应用自定义窗口大小和固定位置。"
                ),
                systemImage: "macwindow.on.rectangle",
                externalInvocationPolicy: command.allowExternalInvocation ? .allowed : .unavailable
            )
        }
        return builtIns + custom
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        guard actionKey.providerID == metadata.id,
              WindowLayoutOperation(rawValue: actionKey.actionID) != nil
                || store.customCommand(actionID: actionKey.actionID) != nil
        else { return [] }
        return [PermissionID.accessibility]
    }

    func exposurePolicy(
        for reference: ActionReference,
        on surface: ActionExposureSurface
    ) -> ActionExposurePolicy {
        .automatic
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.providerID == metadata.id else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        isAccessibilityGranted = accessibilityTrusted()
        guard isAccessibilityGranted else {
            return .unavailable(localizedMessage(for: .accessibilityRequired))
        }
        let actionID = reference.key.actionID
        if WindowLayoutOperation(rawValue: actionID) != nil
            || store.customCommand(actionID: actionID) != nil {
            return .available
        }
        return .unavailable(PluginKitLocalization.actionUnavailable)
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let actionID = invocation.reference.key.actionID
        guard invocation.reference.key.providerID == metadata.id else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        let options = executionOptions
        let successMessage = successFeedbackMessage(
            actionID: actionID,
            source: invocation.source
        )
        if let operation = WindowLayoutOperation(rawValue: actionID) {
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .failed(message: PluginKitLocalization.actionUnavailable) }
                guard self.accessibilityTrusted() else {
                    return .failed(message: self.localizedMessage(for: .accessibilityRequired))
                }
                return self.actionResult(
                    await self.executor.execute(operation, options: options),
                    successMessage: successMessage
                )
            }
        }
        guard let command = store.customCommand(actionID: actionID) else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionUnavailable) }
        }
        return ActionExecutionHandle { [weak self] in
            guard let self else { return .failed(message: PluginKitLocalization.actionUnavailable) }
            guard self.accessibilityTrusted() else {
                return .failed(message: self.localizedMessage(for: .accessibilityRequired))
            }
            return self.actionResult(
                await self.executor.execute(command, options: options),
                successMessage: successMessage
            )
        }
    }

    func handleShortcutAction(id: String) {
        let options = executionOptions
        let operation = WindowLayoutOperation(rawValue: id)
        let command = store.customCommand(actionID: id)
        Task { @MainActor [weak self] in
            guard let self, self.accessibilityTrusted() else { return }
            if let operation {
                _ = await self.executor.execute(operation, options: options)
            } else if let command {
                _ = await self.executor.execute(command, options: options)
            }
        }
    }

    func activate(context: PluginRuntimeContext) {
        refreshAccessibilityPermission()
        applyModifierDragConfiguration()
    }

    func deactivate(reason: PluginDeactivationReason) {
        stopModifierDragSession()
    }

    func refresh() {
        refreshAccessibilityPermission()
        applyModifierDragConfiguration()
    }

    func refreshDisplayTopology() {
        modifierDragSession?.cancelCenteredGuides()
    }

    func refreshAccessibilityPermission() {
        let previous = isAccessibilityGranted
        isAccessibilityGranted = accessibilityTrusted()
        if previous != isAccessibilityGranted {
            if isAccessibilityGranted {
                modifierDragError = nil
                modifierDragMonitorStartFailed = false
            } else if store.modifierDragEnabled {
                modifierDragError = localizedMessage(for: .accessibilityRequired)
            }
            applyModifierDragConfiguration()
            onStateChange?()
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.accessibility else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
        return PluginPermissionState(
            isGranted: isAccessibilityGranted,
            footnote: isAccessibilityGranted
                ? nil
                : localizedKey(
                    "permission.accessibility.footnote",
                    "在系统设置 → 隐私与安全性 → 辅助功能中允许 MacTools。"
                )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.accessibility else { return }
        isAccessibilityGranted = isAccessibilityGranted
            ? accessibilityTrusted()
            : requestAccessibilityTrust(true)
        onStateChange?()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setNumber(controlID, value, phase):
            guard phase == .committed else { return }
            if controlID == SettingsID.gap {
                store.setGap(value)
            } else {
                updateCustomNumber(controlID: controlID, value: value)
            }
        case let .setBoolean(controlID, value):
            if controlID == SettingsID.cyclesHalves {
                store.setCyclesHalves(value)
            } else if controlID == SettingsID.respectsStageManager {
                store.setRespectsStageManager(value)
                applyModifierDragConfiguration()
            } else if controlID == SettingsID.showsCommandFeedback {
                store.setShowsCommandFeedback(value)
            } else if controlID == SettingsID.centeredGuidesEnabled {
                store.setCenteredGuidesEnabled(value)
                refreshAccessibilityPermission()
                applyModifierDragConfiguration()
                if value && !isAccessibilityGranted { requestPermissionGuidance?(PermissionID.accessibility) }
            } else if controlID == SettingsID.modifierDragEnabled {
                setModifierDragEnabled(value)
            } else if controlID == SettingsID.modifierDragShowsIndicator {
                setShowsModifierDragIndicator(value)
            } else {
                updateBoolean(controlID: controlID, value: value)
            }
        case let .setSelection(controlID, optionID):
            updateCustomSelection(controlID: controlID, optionID: optionID)
        case let .setText(controlID, value, phase):
            guard phase == .committed else { return }
            updateText(controlID: controlID, value: value)
        case let .invoke(controlID):
            handleInvoke(controlID)
        }
    }

    private var executionOptions: WindowLayoutExecutionOptions {
        WindowLayoutExecutionOptions(
            gap: store.gap,
            cyclesHalves: store.cyclesHalves,
            respectsStageManager: store.respectsStageManager
        )
    }

    private func actionResult(
        _ result: Result<Void, WindowLayoutError>,
        successMessage: String?
    ) -> ActionExecutionResult {
        switch result {
        case .success: .succeeded(message: successMessage)
        case .failure(.executionCancelled): .cancelled
        case let .failure(error): .failed(message: localizedMessage(for: error))
        }
    }

    private func successFeedbackMessage(
        actionID: String,
        source: ActionExecutionSource
    ) -> String? {
        guard store.showsCommandFeedback,
              source == .globalShortcut || source == .trackpadGesture
        else {
            return nil
        }
        return actionDefinitions.first(where: { $0.key.actionID == actionID })?.title
    }

    private func actionDefinition(
        actionID: String,
        title: String,
        description: String,
        systemImage: String,
        externalInvocationPolicy: ActionExternalInvocationPolicy
    ) -> ActionDefinition {
        ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: actionID),
            title: title,
            description: description,
            keywords: [metadata.title, title, "window", "layout", "tile"],
            systemImage: systemImage,
            risk: .safe,
            externalInvocationPolicy: externalInvocationPolicy,
            capabilities: [.background, .foregroundInteractive, .cancellable],
            concurrencyPolicy: .serialize,
            executionTimeoutSeconds: 15
        )
    }

    private var settingsSections: [PluginSettingsSection] {
        var sections = [
            generalSettingsSection,
            modifierDragSettingsSection,
            shortcutPresetSection,
            customCommandOverviewSection,
        ]
        sections.append(contentsOf: store.customCommands.map(customCommandSection))
        return sections
    }

    private var modifierDragSettingsSection: PluginSettingsSection {
        PluginSettingsSection(
            id: "modifier-drag",
            title: localizedKey("settings.modifierDrag.sectionTitle", "修饰键拖移"),
            systemImage: "cursorarrow.motionlines",
            footer: modifierDragFooter
        ) { [weak self] _ in
            if let self {
                WindowModifierDragSettingsView(plugin: self)
            }
        }
    }

    var isModifierDragEnabled: Bool { store.modifierDragEnabled }
    var modifierDragModifiers: ShortcutModifiers { store.modifierDragModifiers }
    var showsModifierDragIndicator: Bool { store.modifierDragShowsIndicator }

    func setShowsModifierDragIndicator(_ enabled: Bool) {
        store.setModifierDragShowsIndicator(enabled)
        applyModifierDragConfiguration()
    }

    func setModifierDragModifiers(_ modifiers: ShortcutModifiers) {
        modifierDragError = nil
        modifierDragMonitorStartFailed = false
        store.setModifierDragModifiers(modifiers)
        applyModifierDragConfiguration()
    }

    func inputGestureConflictsDidChange(_ conflicts: [PluginInputGestureConflict]) {
        let previousConflict = modifierDragConflict
        externalGestureConflicts = conflicts
        guard previousConflict != modifierDragConflict else { return }
        applyModifierDragConfiguration()
    }

    func setModifierDragEnabled(_ enabled: Bool) {
        modifierDragError = nil
        modifierDragMonitorStartFailed = false
        guard enabled else {
            store.setModifierDragEnabled(false)
            applyModifierDragConfiguration()
            return
        }

        isAccessibilityGranted = accessibilityTrusted()
        if !isAccessibilityGranted {
            isAccessibilityGranted = requestAccessibilityTrust(true)
        }
        guard isAccessibilityGranted else {
            modifierDragError = localizedMessage(for: .accessibilityRequired)
            requestPermissionGuidance?(PermissionID.accessibility)
            onStateChange?()
            return
        }
        store.setModifierDragEnabled(true)
        applyModifierDragConfiguration()
    }

    private func applyModifierDragConfiguration() {
        guard store.centeredGuidesEnabled || (store.modifierDragEnabled && modifierDragConflict == nil),
              isAccessibilityGranted
        else {
            stopModifierDragSession()
            return
        }

        let session: any WindowModifierDragSessionManaging
        if let modifierDragSession {
            session = modifierDragSession
        } else {
            let newSession = makeModifierDragSession()
            newSession.onFailure = { [weak self] error in
                guard let self else { return }
                self.modifierDragError = self.localizedMessage(for: error)
                self.onStateChange?()
            }
            newSession.onSuccess = { [weak self] in
                guard let self, self.modifierDragError != nil else { return }
                self.modifierDragError = nil
                self.onStateChange?()
            }
            modifierDragSession = newSession
            session = newSession
        }
        session.configure(
            modifiers: store.modifierDragModifiers,
            showsIndicator: store.modifierDragShowsIndicator
        )
        session.configureFeatures(
            modifierDragEnabled: store.modifierDragEnabled && modifierDragConflict == nil,
            centeredGuidesEnabled: store.centeredGuidesEnabled,
            respectsStageManager: store.respectsStageManager
        )
        switch session.start() {
        case .success:
            modifierDragMonitorStartFailed = false
        case let .failure(error):
            session.stop()
            modifierDragSession = nil
            modifierDragMonitorStartFailed = true
            modifierDragError = localizedMessage(for: error)
            onStateChange?()
        }
    }

    private func stopModifierDragSession() {
        modifierDragSession?.stop()
        modifierDragSession = nil
    }

    private var modifierDragClaim: PluginInputGestureClaim {
        PluginInputGestureClaim(
            id: "pointer.move.modifiers.\(store.modifierDragModifiers.rawValue)",
            title: localizedKey("settings.modifierDrag.sectionTitle", "修饰键拖移")
                + " \(store.modifierDragModifiers.symbolString)"
        )
    }

    private var modifierDragConflict: PluginInputGestureConflict? {
        externalGestureConflicts.first(where: { $0.claim.id == modifierDragClaim.id })
    }

    private var centeredGuidesDescription: String {
        if store.centeredGuidesEnabled, modifierDragMonitorStartFailed {
            return localizedKey("settings.centeredGuides.unavailable", "无法启用窗口居中参考线，请检查辅助功能权限后重试。")
        }
        return localizedKey(
            "settings.centeredGuides.description",
            "拖移其他应用的窗口时显示参考线，靠近中心松开即可居中。需要辅助功能权限。"
        )
    }

    private var modifierDragFooter: String? {
        if store.modifierDragEnabled {
            if let conflict = modifierDragConflict {
                return localization.format(
                    "settings.modifierDrag.conflictFormat",
                    defaultValue: "该组合正由“%@”使用。修饰键拖移已暂停。",
                    conflict.ownerPluginTitle
                )
            }
            if let modifierDragError { return modifierDragError }
        }
        if store.modifierDragModifiers.rawValue.nonzeroBitCount == 1 {
            return localizedKey(
                "settings.modifierDrag.singleWarning",
                "单个修饰键容易误触，建议使用两个或更多修饰键。"
            )
        }
        return localizedKey(
            "settings.modifierDrag.footer",
            "仅按住所选组合键并移动指针，即可拖移指针下方最上层窗口；无需点击。"
        )
    }

    private var generalSettingsSection: PluginSettingsSection {
        PluginSettingsSection(
            id: "behavior",
            title: localizedKey("settings.behavior.title", "布局行为"),
            systemImage: "rectangle.3.group",
            rows: [
                PluginSettingsRow(
                    id: SettingsID.gap,
                    title: localizedKey("settings.gap.title", "窗口间距"),
                    description: localizedKey(
                        "settings.gap.description",
                        "同时应用于屏幕边缘和相邻平铺窗口。"
                    ),
                    systemImage: "rectangle.inset.filled",
                    control: .slider(
                        value: store.gap,
                        range: WindowLayoutsStore.gapRange,
                        step: 1,
                        valueFormat: PluginSettingsSliderValueFormat(suffix: " pt")
                    )
                ),
                PluginSettingsRow(
                    id: SettingsID.cyclesHalves,
                    title: localizedKey("settings.cycles.title", "循环半屏尺寸"),
                    description: localizedKey(
                        "settings.cycles.description",
                        "重复执行任一半屏命令时，在二分之一、三分之二和三分之一之间循环。"
                    ),
                    control: .toggle(isOn: store.cyclesHalves)
                ),
                PluginSettingsRow(
                    id: SettingsID.respectsStageManager,
                    title: localizedKey("settings.stageManager.title", "避让台前调度"),
                    description: localizedKey(
                        "settings.stageManager.description",
                        "台前调度缩略图可见时，不把窗口放到缩略图下方。"
                    ),
                    control: .toggle(isOn: store.respectsStageManager)
                ),
                PluginSettingsRow(
                    id: SettingsID.centeredGuidesEnabled,
                    title: localizedKey("settings.centeredGuides.title", "窗口居中参考线"),
                    description: centeredGuidesDescription,
                    control: .toggle(isOn: store.centeredGuidesEnabled)
                ),
                PluginSettingsRow(
                    id: SettingsID.showsCommandFeedback,
                    title: localizedKey("settings.feedback.title", "显示命令反馈"),
                    description: localizedKey(
                        "settings.feedback.description",
                        "使用全局快捷键或触控板手势时，短暂显示成功提示；失败始终显示。"
                    ),
                    control: .toggle(isOn: store.showsCommandFeedback)
                ),
                PluginSettingsRow(
                    id: SettingsID.reset,
                    title: localizedKey("settings.reset.title", "恢复默认设置"),
                    description: localizedKey(
                        "settings.reset.description",
                        "不会删除自定义命令。"
                    ),
                    control: .action(
                        title: localizedKey("settings.reset.button", "恢复"),
                        role: .normal
                    )
                )
            ]
        )
    }

    private var shortcutPresetSection: PluginSettingsSection {
        PluginSettingsSection(
            id: "shortcut-presets",
            title: localizedKey("settings.preset.sectionTitle", "快捷键预设"),
            systemImage: "keyboard"
        ) { [weak self] _ in
            if let self {
                WindowShortcutPresetSettingsView(plugin: self)
            }
        }
    }

    private var customCommandOverviewSection: PluginSettingsSection {
        PluginSettingsSection(
            id: "custom-commands",
            title: localizedKey("settings.custom.title", "自定义布局"),
            systemImage: "macwindow.on.rectangle",
            footer: customCommandDeletionError ?? localizedKey(
                "settings.custom.description",
                "可组合相对或固定大小、九点定位和偏移，并作为快捷键或 Run Link 使用。"
            ),
            rows: [
                PluginSettingsRow(
                    id: SettingsID.addCustom,
                    title: localizedKey("settings.custom.add.title", "创建自定义布局"),
                    control: .action(
                        title: localizedKey("settings.custom.add.button", "创建"),
                        role: .normal
                    )
                )
            ]
        )
    }

    private func customCommandSection(_ command: WindowCustomCommand) -> PluginSettingsSection {
        let prefix = "custom.\(command.id.uuidString.lowercased())"
        return PluginSettingsSection(
            id: prefix,
            title: command.name,
            systemImage: "macwindow",
            presentation: .edgeToEdge
        ) { [weak self] _ in
            if let self {
                WindowCustomCommandSettingsView(plugin: self, command: command)
            }
        }
        .headerAccessory { [weak self] _ in
            if let self {
                WindowCustomCommandHeaderActions(
                    commandID: command.id,
                    duplicateTitle: localizedKey(
                        "settings.custom.duplicate",
                        "复制命令"
                    ),
                    deleteTitle: localizedKey(
                        "settings.custom.delete",
                        "删除命令"
                    ),
                    onDuplicate: { self.duplicateCustomCommand(command.id) },
                    onDelete: { self.deleteCustomCommand(command.id) }
                )
            }
        }
    }

    func customCommand(id: UUID) -> WindowCustomCommand? {
        store.customCommand(id: id)
    }

    @discardableResult
    func updateCustomCommand(_ command: WindowCustomCommand) -> Bool {
        var normalized = command
        if normalized.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.name = localizedKey(
                "settings.custom.defaultName",
                "自定义布局"
            )
        }
        return store.updateCustomCommand(normalized)
    }

    var customCommandPreviewGap: CGFloat { CGFloat(store.gap) }

    func duplicateCustomCommand(_ id: UUID) {
        _ = store.duplicateCustomCommand(
            id: id,
            copySuffix: localizedKey("settings.custom.copySuffix", "副本")
        )
    }

    @discardableResult
    func deleteCustomCommand(_ id: UUID) -> Bool {
        guard let command = store.customCommand(id: id) else { return false }

        guard let performActionShortcutReplacementTransaction else {
            publishCustomCommandDeletionError(localizedKey(
                "settings.custom.delete.shortcutUnavailable",
                "删除前无法读取此布局的快捷键。"
            ))
            return false
        }

        let error = performActionShortcutReplacementTransaction(
            [command.actionID],
            [:]
        ) {
            guard self.store.removeCustomCommand(id: id) else {
                return self.localizedKey(
                    "settings.custom.delete.failed",
                    "无法删除自定义布局；其快捷键已恢复。"
                )
            }
            return nil
        }
        guard error == nil else {
            publishCustomCommandDeletionError(error)
            return false
        }

        publishCustomCommandDeletionError(nil)
        return true
    }

    private func publishCustomCommandDeletionError(_ error: String?) {
        guard customCommandDeletionError != error else { return }
        customCommandDeletionError = error
        customCommandSettingsRevision &+= 1
        onStateChange?()
    }

    func customCommandShortcutBinding(for id: UUID) -> ShortcutBinding? {
        guard let command = store.customCommand(id: id) else { return nil }
        if let binding = currentActionShortcutBindings?([command.actionID])[command.actionID]?.first {
            return binding
        }
        guard let preview = previewActionShortcutPreset?([command.actionID], [:]) else {
            return nil
        }
        return preview.items.first(where: { $0.actionID == command.actionID })?
            .currentBinding
    }

    func shortcutPresetCurrentBindings(for actionID: String) -> [ShortcutBinding] {
        if let bindings = currentActionShortcutBindings?([actionID])[actionID] {
            return bindings
        }
        guard let preview = previewActionShortcutPreset?([actionID], [:]),
              let currentBinding = preview.items.first(where: { $0.actionID == actionID })?
                .currentBinding else { return [] }
        return [currentBinding]
    }

    func recordCustomCommandShortcut(
        _ binding: ShortcutBinding,
        for id: UUID
    ) -> PluginShortcutRecordingResult {
        guard let command = store.customCommand(id: id),
              let applyActionShortcutPreset
        else {
            return .rejected(localizedKey(
                "settings.preset.unavailable",
                "当前无法应用快捷键预设。"
            ))
        }
        return .from(errorMessage: applyActionShortcutPreset(
            [command.actionID],
            [command.actionID: binding]
        ))
    }

    func clearCustomCommandShortcut(for id: UUID) -> PluginShortcutRecordingResult {
        guard let command = store.customCommand(id: id),
              let applyActionShortcutPreset
        else {
            return .rejected(localizedKey(
                "settings.preset.unavailable",
                "当前无法应用快捷键预设。"
            ))
        }
        return .from(errorMessage: applyActionShortcutPreset([command.actionID], [:]))
    }

    private func updateCustomNumber(controlID: String, value: Double) {
        guard let (id, field) = parsedEntityControl(controlID, prefix: "custom"),
              var command = store.customCommand(id: id)
        else { return }
        switch field {
        case "width-value": command.width = dimensionValue(command.width, value: value)
        case "height-value": command.height = dimensionValue(command.height, value: value)
        case "offset-x": command.offsetX = value
        case "offset-y": command.offsetY = value
        default: return
        }
        _ = store.updateCustomCommand(command)
    }

    private func updateBoolean(controlID: String, value: Bool) {
        if let (id, field) = parsedEntityControl(controlID, prefix: "custom"),
           field == "external", var command = store.customCommand(id: id) {
            command.allowExternalInvocation = value
            _ = store.updateCustomCommand(command)
        }
    }

    private func updateCustomSelection(controlID: String, optionID: String) {
        guard let (id, field) = parsedEntityControl(controlID, prefix: "custom"),
              var command = store.customCommand(id: id)
        else { return }
        switch field {
        case "width-mode": command.width = dimensionForMode(optionID, existing: command.width)
        case "height-mode": command.height = dimensionForMode(optionID, existing: command.height)
        case "anchor":
            guard let anchor = WindowLayoutAnchor(rawValue: optionID) else { return }
            command.anchor = anchor
        default: return
        }
        _ = store.updateCustomCommand(command)
    }

    private func updateText(controlID: String, value: String) {
        if let (id, field) = parsedEntityControl(controlID, prefix: "custom"),
           field == "name", var command = store.customCommand(id: id) {
            command.name = value
            _ = store.updateCustomCommand(command)
        }
    }

    private func handleInvoke(_ controlID: String) {
        switch controlID {
        case SettingsID.reset:
            modifierDragError = nil
            modifierDragMonitorStartFailed = false
            store.reset()
            applyModifierDragConfiguration()
        case SettingsID.addCustom:
            _ = store.addCustomCommand(
                name: localizedKey("settings.custom.defaultName", "自定义布局")
            )
        default:
            if let (id, field) = parsedEntityControl(controlID, prefix: "custom") {
                if field == "duplicate" {
                    _ = store.duplicateCustomCommand(
                        id: id,
                        copySuffix: localizedKey("settings.custom.copySuffix", "副本")
                    )
                }
                if field == "delete" { _ = deleteCustomCommand(id) }
            }
        }
    }

    private func parsedEntityControl(_ controlID: String, prefix: String) -> (UUID, String)? {
        guard controlID.hasPrefix("\(prefix)."), let parts = splitControlID(controlID),
              let id = UUID(uuidString: parts.id) else { return nil }
        return (id, parts.field)
    }

    private func splitControlID(_ controlID: String) -> (id: String, field: String)? {
        let parts = controlID.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    private func dimensionMode(_ dimension: WindowLayoutDimension) -> String {
        switch dimension {
        case .current: "current"
        case .points: "points"
        case .fraction: "fraction"
        }
    }

    private func dimensionForMode(
        _ mode: String,
        existing: WindowLayoutDimension
    ) -> WindowLayoutDimension {
        switch mode {
        case "current": .current
        case "points":
            if case let .points(value) = existing { .points(value) } else { .points(800) }
        default:
            if case let .fraction(value) = existing { .fraction(value) } else { .fraction(0.6) }
        }
    }

    private func dimensionValue(
        _ dimension: WindowLayoutDimension,
        value: Double
    ) -> WindowLayoutDimension {
        switch dimension {
        case .points: .points(value)
        case .fraction: .fraction(value / 100)
        case .current: .current
        }
    }

    @discardableResult
    func applyShortcutPreset(_ preset: WindowShortcutPreset) -> String? {
        applyShortcutPreset(
            preset,
            bindingsByActionID: shortcutPresetBindings(for: preset)
        )
    }

    @discardableResult
    func applyShortcutPreset(
        _ preset: WindowShortcutPreset,
        bindingsByActionID: [String: ShortcutBinding]
    ) -> String? {
        guard let applyActionShortcutPreset else {
            return localizedKey(
                "settings.preset.unavailable",
                "当前无法应用快捷键预设。"
            )
        }
        if let error = applyActionShortcutPreset(
            shortcutPresetActionIDs,
            bindingsByActionID
        ) {
            return error
        }
        store.setShortcutPreset(preset)
        return nil
    }

    func shortcutPresetPreview(
        for preset: WindowShortcutPreset
    ) -> PluginActionShortcutPresetPreview? {
        shortcutPresetPreview(
            bindingsByActionID: shortcutPresetBindings(for: preset)
        )
    }

    func shortcutPresetPreview(
        bindingsByActionID: [String: ShortcutBinding]
    ) -> PluginActionShortcutPresetPreview? {
        previewActionShortcutPreset?(
            shortcutPresetActionIDs,
            bindingsByActionID
        )
    }

    var currentShortcutPreset: WindowShortcutPreset? {
        WindowShortcutPreset.allCases.first { preset in
            guard let preview = shortcutPresetPreview(for: preset) else { return false }
            return preview.errorMessage == nil && !preview.hasChanges
        }
    }

    var currentShortcutPresetTitle: String {
        currentShortcutPreset.map(shortcutPresetTitle) ?? localizedKey(
            "settings.preset.custom",
            "自定义"
        )
    }

    var initialShortcutPreset: WindowShortcutPreset {
        currentShortcutPreset ?? store.shortcutPreset
    }

    func shortcutPresetTitle(_ preset: WindowShortcutPreset) -> String {
        switch preset {
        case .none:
            localizedKey("settings.preset.none", "无")
        case .controlOption:
            localizedKey("settings.preset.controlOption", "Control–Option (⌃⌥)")
        case .optionCommand:
            localizedKey("settings.preset.optionCommand", "Option–Command (⌥⌘)")
        case .controlOptionCommand:
            localizedKey(
                "settings.preset.controlOptionCommand",
                "Control–Option–Command (⌃⌥⌘)"
            )
        }
    }

    func shortcutPresetActionTitle(_ actionID: String) -> String {
        switch actionID {
        case RetiredActionID.nextDesktop:
            return localizedKey(
                "settings.preset.retiredNextDesktop",
                "已移除：移到下一个桌面"
            )
        case RetiredActionID.previousDesktop:
            return localizedKey(
                "settings.preset.retiredPreviousDesktop",
                "已移除：移到上一个桌面"
            )
        default:
            return actionDefinitions.first(where: {
                $0.key.actionID == actionID
            })?.title ?? actionID
        }
    }

    func shortcutBindingTitle(_ binding: ShortcutBinding?) -> String {
        guard let binding else {
            return localizedKey("settings.preset.unassigned", "未分配")
        }
        return ShortcutFormatter.displayString(for: binding)
    }

    func orderedShortcutPresetPreviewItems(
        _ preview: PluginActionShortcutPresetPreview
    ) -> [PluginActionShortcutPresetPreviewItem] {
        let itemsByActionID = Dictionary(
            uniqueKeysWithValues: preview.items.map { ($0.actionID, $0) }
        )
        let standardItems = shortcutPresetActionIDOrder.compactMap {
            itemsByActionID[$0]
        }
        let retiredItems = preview.items
            .filter { RetiredActionID.all.contains($0.actionID) && $0.changesBinding }
            .sorted { $0.actionID < $1.actionID }
        return standardItems + retiredItems
    }

    private var shortcutPresetActionIDOrder: [String] {
        [
            WindowLayoutOperation.leftHalf.rawValue,
            WindowLayoutOperation.rightHalf.rawValue,
            WindowLayoutOperation.topHalf.rawValue,
            WindowLayoutOperation.bottomHalf.rawValue,
            WindowLayoutOperation.maximize.rawValue,
            WindowLayoutOperation.center.rawValue,
        ]
    }

    private var shortcutPresetActionIDs: Set<String> {
        Set(shortcutPresetActionIDOrder).union(RetiredActionID.all)
    }

    func shortcutPresetBindings(
        for preset: WindowShortcutPreset
    ) -> [String: ShortcutBinding] {
        guard preset != .none else { return [:] }
        let modifiers: ShortcutModifiers
        let maximizeKeyCode: UInt16
        switch preset {
        case .none:
            return [:]
        case .controlOption:
            modifiers = [.control, .option]
            maximizeKeyCode = UInt16(kVK_Return)
        case .optionCommand:
            modifiers = [.option, .command]
            maximizeKeyCode = UInt16(kVK_ANSI_F)
        case .controlOptionCommand:
            modifiers = [.control, .option, .command]
            maximizeKeyCode = UInt16(kVK_Return)
        }
        return [
            WindowLayoutOperation.leftHalf.rawValue:
                ShortcutBinding(keyCode: UInt16(kVK_LeftArrow), modifiers: modifiers),
            WindowLayoutOperation.rightHalf.rawValue:
                ShortcutBinding(keyCode: UInt16(kVK_RightArrow), modifiers: modifiers),
            WindowLayoutOperation.topHalf.rawValue:
                ShortcutBinding(keyCode: UInt16(kVK_UpArrow), modifiers: modifiers),
            WindowLayoutOperation.bottomHalf.rawValue:
                ShortcutBinding(keyCode: UInt16(kVK_DownArrow), modifiers: modifiers),
            WindowLayoutOperation.maximize.rawValue:
                ShortcutBinding(keyCode: maximizeKeyCode, modifiers: modifiers),
            WindowLayoutOperation.center.rawValue:
                ShortcutBinding(keyCode: UInt16(kVK_ANSI_C), modifiers: modifiers),
        ]
    }

    private func localizedMessage(for error: WindowLayoutError) -> String {
        switch error {
        case .executionCancelled: localizedKey("error.executionCancelled", "窗口布局操作已取消。")
        case .executionQueueFull: localizedKey("error.executionQueueFull", "等待中的窗口布局操作过多。")
        case .accessibilityRequired: localizedKey("error.accessibilityRequired", "窗口布局需要辅助功能权限。")
        case .noFocusedWindow: localizedKey("error.noFocusedWindow", "没有可用的聚焦窗口。")
        case .noWindowUnderPointer: localizedKey(
            "error.noWindowUnderPointer",
            "指针下方没有可移动的窗口。"
        )
        case .windowUnavailable: localizedKey("error.windowUnavailable", "当前窗口已不可用。")
        case .windowCannotMove: localizedKey("error.windowCannotMove", "此窗口无法移动。")
        case .windowCannotResize: localizedKey("error.windowCannotResize", "此窗口无法调整大小。")
        case .windowCannotResizeFurther: localizedKey("error.windowCannotResizeFurther", "窗口无法进一步调整大小。")
        case .windowSizeConstrained: localizedKey(
            "error.windowSizeConstrained",
            "此应用限制了窗口可调整到的大小。"
        )
        case .fullScreenUnsupported: localizedKey("error.fullScreenUnsupported", "此窗口不支持切换全屏。")
        case .customCommandUnavailable: localizedKey("error.customCommandUnavailable", "找不到自定义窗口命令。")
        case .noDisplay: localizedKey("error.noDisplay", "找不到此窗口所在的显示器。")
        case .noOtherDisplay: localizedKey("error.noOtherDisplay", "没有其他可用显示器。")
        case .noPreviousFrame: localizedKey("error.noPreviousFrame", "此窗口没有可恢复的上一个位置。")
        case .frameReadFailed: localizedKey("error.frameReadFailed", "无法读取当前窗口的位置和大小。")
        case .frameWriteFailed: localizedKey("error.frameWriteFailed", "无法调整当前窗口。")
        }
    }

    private func localizedMessage(for error: WindowModifierDragMonitorStartError) -> String {
        switch error {
        case .eventTapUnavailable, .runLoopSourceUnavailable, .eventLoopUnavailable:
            localizedKey(
                "error.modifierDragMonitorUnavailable",
                "无法启动全局指针监控。请关闭后重新开启修饰键拖移。"
            )
        }
    }

    func localizedKey(_ key: String, _ fallback: String) -> String {
        localization.string(key, defaultValue: fallback)
    }

    func anchorTitle(_ anchor: WindowLayoutAnchor) -> String {
        switch anchor {
        case .topLeft: localizedKey("settings.anchor.topLeft", "左上")
        case .top: localizedKey("settings.anchor.top", "上方")
        case .topRight: localizedKey("settings.anchor.topRight", "右上")
        case .left: localizedKey("settings.anchor.left", "左侧")
        case .center: localizedKey("settings.anchor.center", "居中")
        case .right: localizedKey("settings.anchor.right", "右侧")
        case .bottomLeft: localizedKey("settings.anchor.bottomLeft", "左下")
        case .bottom: localizedKey("settings.anchor.bottom", "下方")
        case .bottomRight: localizedKey("settings.anchor.bottomRight", "右下")
        }
    }

    private var actionDescriptors: [ActionDescriptor] {
        [
            descriptor(.toggleFullScreen, "切换全屏", "切换当前窗口的 macOS 全屏状态。", "arrow.up.left.and.arrow.down.right"),
            descriptor(.leftHalf, "左半屏", "将当前窗口放到左半屏。", "rectangle.lefthalf.inset.filled"),
            descriptor(.rightHalf, "右半屏", "将当前窗口放到右半屏。", "rectangle.righthalf.inset.filled"),
            descriptor(.topHalf, "上半屏", "将当前窗口放到上半屏。", "rectangle.tophalf.inset.filled"),
            descriptor(.bottomHalf, "下半屏", "将当前窗口放到下半屏。", "rectangle.bottomhalf.inset.filled"),
            descriptor(.topLeftQuarter, "左上四分之一", "将当前窗口放到左上角。", "rectangle.split.2x2"),
            descriptor(.topRightQuarter, "右上四分之一", "将当前窗口放到右上角。", "rectangle.split.2x2"),
            descriptor(.bottomLeftQuarter, "左下四分之一", "将当前窗口放到左下角。", "rectangle.split.2x2"),
            descriptor(.bottomRightQuarter, "右下四分之一", "将当前窗口放到右下角。", "rectangle.split.2x2"),
            descriptor(.maximize, "最大化窗口", "填充显示器可用区域。", "rectangle.inset.filled"),
            descriptor(.maximizeHeight, "最大化高度", "保持宽度并填满可用高度。", "arrow.up.and.down"),
            descriptor(.maximizeWidth, "最大化宽度", "保持高度并填满可用宽度。", "arrow.left.and.right"),
            descriptor(.center, "居中窗口", "保持大小并将窗口居中。", "macwindow"),
            descriptor(.reasonableSize, "合理大小", "将窗口设为屏幕的 60%，最大 1025 × 900，并居中。", "rectangle.center.inset.filled"),
            descriptor(.moveToTopEdge, "移到顶部", "保持大小并移到屏幕顶部。", "arrow.up.to.line"),
            descriptor(.moveToBottomEdge, "移到底部", "保持大小并移到屏幕底部。", "arrow.down.to.line"),
            descriptor(.moveToLeftEdge, "移到左侧", "保持大小并移到屏幕左侧。", "arrow.left.to.line"),
            descriptor(.moveToRightEdge, "移到右侧", "保持大小并移到屏幕右侧。", "arrow.right.to.line"),
            descriptor(.firstThird, "左侧三分之一", "填充左侧三分之一。", "rectangle.leadingthird.inset.filled"),
            descriptor(.firstTwoThirds, "左侧三分之二", "填充左侧三分之二。", "rectangle.leadinghalf.inset.filled"),
            descriptor(.centerThird, "中间三分之一", "填充中间三分之一。", "rectangle.center.inset.filled"),
            descriptor(.lastTwoThirds, "右侧三分之二", "填充右侧三分之二。", "rectangle.trailinghalf.inset.filled"),
            descriptor(.lastThird, "右侧三分之一", "填充右侧三分之一。", "rectangle.trailingthird.inset.filled"),
            descriptor(.firstFourth, "第一个四分之一", "填充最左侧四分之一。", "rectangle.split.3x1"),
            descriptor(.secondFourth, "第二个四分之一", "填充第二个四分之一。", "rectangle.split.3x1"),
            descriptor(.thirdFourth, "第三个四分之一", "填充第三个四分之一。", "rectangle.split.3x1"),
            descriptor(.lastFourth, "最后一个四分之一", "填充最右侧四分之一。", "rectangle.split.3x1"),
            descriptor(.topLeftSixth, "左上六分之一", "填充左上六分之一。", "rectangle.split.3x3"),
            descriptor(.topCenterSixth, "中上六分之一", "填充中上六分之一。", "rectangle.split.3x3"),
            descriptor(.topRightSixth, "右上六分之一", "填充右上六分之一。", "rectangle.split.3x3"),
            descriptor(.bottomLeftSixth, "左下六分之一", "填充左下六分之一。", "rectangle.split.3x3"),
            descriptor(.bottomCenterSixth, "中下六分之一", "填充中下六分之一。", "rectangle.split.3x3"),
            descriptor(.bottomRightSixth, "右下六分之一", "填充右下六分之一。", "rectangle.split.3x3"),
            descriptor(.increaseWidth, "增加窗口宽度", "将当前窗口宽度增加 50 点。", "arrow.left.and.line.vertical.and.arrow.right"),
            descriptor(.decreaseWidth, "减少窗口宽度", "将当前窗口宽度减少 50 点。", "arrow.right.and.line.vertical.and.arrow.left"),
            descriptor(.increaseHeight, "增加窗口高度", "将当前窗口高度增加 50 点。", "arrow.up.and.line.horizontal.and.arrow.down"),
            descriptor(.decreaseHeight, "减少窗口高度", "将当前窗口高度减少 50 点。", "arrow.down.and.line.horizontal.and.arrow.up"),
            descriptor(.moveToNextDisplay, "移到下一台显示器", "保留相对位置和大小并移到下一台显示器。", "arrow.right.square"),
            descriptor(.moveToPreviousDisplay, "移到上一台显示器", "保留相对位置和大小并移到上一台显示器。", "arrow.left.square"),
            descriptor(.restorePreviousFrame, "恢复上一个窗口位置", "恢复最近一次保存的位置和大小。", "arrow.uturn.backward.square")
        ]
    }

    private func descriptor(
        _ operation: WindowLayoutOperation,
        _ title: String,
        _ description: String,
        _ systemImage: String
    ) -> ActionDescriptor {
        ActionDescriptor(operation: operation, title: title, description: description, systemImage: systemImage)
    }
}

@MainActor
private final class WindowLayoutsApplicationTarget {
    var targetProvider: (() -> PluginFocusedWindowTarget?)?

    func target() -> PluginFocusedWindowTarget? {
        if let target = targetProvider?(),
           !target.application.isTerminated,
           (target.application.processIdentifier != ProcessInfo.processInfo.processIdentifier
            || target.preferredWindowNumber != nil) {
            return target
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !application.isTerminated
        else {
            return nil
        }
        return PluginFocusedWindowTarget(application: application)
    }
}

@MainActor
private enum WindowLayoutsAccessibilityCheck {
    private static let trustedCheckOptionPromptKey = "AXTrustedCheckOptionPrompt"

    static func requestTrust(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        return AXIsProcessTrustedWithOptions(
            [trustedCheckOptionPromptKey: true] as CFDictionary
        )
    }
}
