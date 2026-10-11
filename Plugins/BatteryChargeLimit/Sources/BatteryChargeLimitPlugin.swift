import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

// MARK: - Bundle Factory

public final class BatteryChargeLimitPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        BatteryChargeLimitPluginProvider(context: context)
    }
}

@MainActor
private struct BatteryChargeLimitPluginProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] {
        return [
            BatteryChargeLimitPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

// MARK: - Control IDs

private enum ControlID {
    static let enableAction    = "battery-enable-action"
    static let limitSlider     = "battery-limit-slider"
    static let chargeAction    = "battery-charge-action"
    static let dischargeAction = "battery-discharge-action"
    static let manageSettings  = "battery-manage-settings"
    static let missingHelper   = "battery-missing-helper"
}

// MARK: - Plugin

@MainActor
final class BatteryChargeLimitPlugin: MacToolsPlugin, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    private enum ActionID {
        static let setEnabled = "set-enabled"
        static let setLimit = "set-limit"
        static let hold = "hold"
        static let resume = "resume"
        static let discharge = "discharge"
    }

    private enum ActionParameterID {
        static let enabled = "enabled"
        static let limit = "limit"
    }

    // MARK: Metadata

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "battery-charge-limit",
            title: localization.string("metadata.title", defaultValue: "电池充电上限"),
            iconName: "battery.100.bolt",
            iconTint: Color(nsColor: .systemGreen),
            order: 48,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "限制电池充电至指定上限"
            )
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    // MARK: Callbacks

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    // MARK: State

    let store: BatteryChargeLimitStore
    private let localization: PluginLocalization
    private let reader: any BatteryChargeLimitReading
    private let writer: any BatteryChargeLimitWriting

    private var isExpanded = false
    private var batterySnapshot: BatterySnapshot = .empty
    private var capabilities: BatterySMCCapabilities = .none
    private enum RetainedError {
        case hardware(BatteryChargeWriteError, rollbackError: BatteryChargeWriteError?)
        case persistence(
            storageRollbackSucceeded: Bool,
            hardwareRollbackError: BatteryChargeWriteError?
        )
    }

    private var lastError: RetainedError?
    private var lastErrorMessage: String? {
        switch lastError {
        case .hardware(let error, let rollbackError):
            return actionFailureMessage(targetError: error, rollbackError: rollbackError)
        case .persistence(let storageRollbackSucceeded, let hardwareRollbackError):
            var message = localization.string(
                "error.persistence.failed",
                defaultValue: "无法保存电池充电设置。"
            )
            if !storageRollbackSucceeded {
                message += " " + localization.string(
                    "error.persistence.rollbackFailed",
                    defaultValue: "恢复先前设置失败。"
                )
            }
            if let hardwareRollbackError {
                message += " " + localization.format(
                    "error.persistence.hardwareRollbackFailed",
                    defaultValue: "恢复先前硬件状态失败：%@",
                    localizedDescription(for: hardwareRollbackError)
                )
            }
            return message
        case nil:
            return nil
        }
    }
    private var requiresSMCCleanup = false
    private var monitoringTask: Task<Void, Never>?
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?

    // MARK: Init

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "battery-charge-limit"),
        reader: any BatteryChargeLimitReading = BatteryChargeLimitReader(),
        writer: (any BatteryChargeLimitWriting)? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.store = BatteryChargeLimitStore(storage: context.storage)
        self.reader = reader
        self.writer = writer ?? BatteryChargeLimitWriter(resourceBundle: context.resourceBundle)
    }

    // MARK: - Lifecycle

    func activate(context: PluginRuntimeContext) {
        batterySnapshot = reader.readSnapshot()

        // Re-assert the persisted mode after app restart. SMC keys can be
        // reset by firmware across sleep/hibernation, so on launch we
        // re-apply whatever the user last had configured.
        if store.isEnabled {
            capabilities = writer.probeCapabilities()
            startActiveMonitoring()
            applyCurrentMode(reason: "activate")
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        stopActiveMonitoring()
        if reason.requiresStateCleanup {
            restoreUnrestrictedChargingIfNeeded(reason: String(describing: reason), requireInstalledHelper: true)
        }
    }

    func refresh() {
        batterySnapshot = reader.readSnapshot()
        evaluateAutoTransitions()
        onStateChange?()
    }

    // MARK: - Panel row

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: store.isEnabled,
            isEnabled: batterySnapshot.hasBattery,
            isAvailable: batterySnapshot.hasBattery,
            detail: isExpanded ? buildDetail() : nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        let executionCapabilities: ActionExecutionCapabilities =
            writer.isInstalledHelperAvailable
                ? [.automatic, .background, .foregroundInteractive]
                : [.foregroundInteractive]
        return [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "battery", "charge"],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: ActionParameterID.enabled,
                        title: metadata.title,
                        kind: .boolean
                    ),
                ],
                confirmation: actionConfirmation,
                externalInvocationPolicy: .confirmAlways,
                capabilities: executionCapabilities
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setLimit),
                title: localization.string("settings.limit.title", defaultValue: "充电上限"),
                description: localization.string(
                    "settings.limit.description",
                    defaultValue: "达到此电量后自动停止充电。"
                ),
                keywords: [metadata.title, "battery", "limit"],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: ActionParameterID.limit,
                        title: localization.string("settings.limit.target", defaultValue: "目标电量"),
                        kind: .integer
                    ),
                ],
                confirmation: actionConfirmation,
                externalInvocationPolicy: .confirmAlways,
                capabilities: executionCapabilities
            ),
            batteryModeActionDefinition(
                actionID: ActionID.hold,
                title: localization.string("panel.action.stopCharging", defaultValue: "停止充电"),
                systemImage: "bolt.slash.fill",
                capabilities: executionCapabilities
            ),
            batteryModeActionDefinition(
                actionID: ActionID.resume,
                title: localization.string("panel.action.startCharging", defaultValue: "开始充电"),
                systemImage: "bolt.fill",
                capabilities: executionCapabilities
            ),
            batteryModeActionDefinition(
                actionID: ActionID.discharge,
                title: localization.format(
                    "panel.action.dischargeToLimit",
                    defaultValue: "强制放电至 %d%%",
                    store.limitPercent
                ),
                systemImage: "minus.circle",
                risk: .confirmationRequired,
                capabilities: executionCapabilities
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        var entries = [
            ActionCatalogEntry(
                reference: enabledActionReference(true),
                title: localization.string("panel.action.enable", defaultValue: "启用充电上限")
            ),
            ActionCatalogEntry(
                reference: enabledActionReference(false),
                title: localization.string("panel.action.disable", defaultValue: "停用充电上限")
            ),
        ]
        entries += [50, 60, 70, 80, 90, 100].map { limit in
            ActionCatalogEntry(
                reference: limitActionReference(limit),
                title: "\(localization.string("settings.limit.title", defaultValue: "充电上限")) · \(limit)%"
            )
        }
        entries += actionDefinitions
            .filter { [ActionID.hold, ActionID.resume, ActionID.discharge].contains($0.key.actionID) }
            .map {
                ActionCatalogEntry(reference: ActionReference(key: $0.key), title: $0.title)
            }
        return entries
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard batterySnapshot.hasBattery else {
            return .unavailable(localization.string("panel.subtitle.noBattery", defaultValue: "未检测到电池"))
        }
        guard writer.isHelperAvailable else {
            return .unavailable(localization.string(
                "panel.action.missingHelper",
                defaultValue: "电池控制组件缺失"
            ))
        }

        switch reference.key.actionID {
        case ActionID.setEnabled, ActionID.setLimit:
            return .available
        case ActionID.hold, ActionID.resume:
            return store.isEnabled ? .available : .unavailable(
                localization.string("panel.action.enable", defaultValue: "启用充电上限")
            )
        case ActionID.discharge:
            guard store.isEnabled,
                  capabilities.canForceDischarge,
                  let level = batterySnapshot.levelPercent,
                  level > store.limitPercent else {
                return .unavailable(PluginKitLocalization.actionUnavailable)
            }
            return .available
        default:
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
    }


    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "charge-limit",
                    title: localization.string("settings.limit.title", defaultValue: "充电上限"),
                    systemImage: "battery.75",
                    rows: [
                        PluginSettingsRow(
                            id: ControlID.limitSlider,
                            title: localization.string("settings.limit.target", defaultValue: "目标电量"),
                            description: localization.string(
                                "settings.limit.description",
                                defaultValue: "达到此电量后自动停止充电。"
                            ),
                            systemImage: "battery.75percent",
                            control: .slider(
                                value: Double(store.limitPercent),
                                range: Double(BatteryChargeLimits.minimumPercent)...Double(BatteryChargeLimits.maximumPercent),
                                step: Double(BatteryChargeLimits.percentStep),
                                valueFormat: .percentage
                            )
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "charging-behavior",
                    title: localization.string("settings.behavior.title", defaultValue: "充电行为"),
                    systemImage: "bolt.badge.checkmark",
                    rows: [
                        PluginSettingsRow(
                            id: "no-auto-resume",
                            title: localization.string(
                                "settings.behavior.noAutoResume.title",
                                defaultValue: "不自动恢复充电"
                            ),
                            description: localization.string(
                                "settings.behavior.noAutoResume.description",
                                defaultValue: "电量低于上限时不会自动充电，需要在菜单栏点击「开始充电」才会继续。"
                            ),
                            systemImage: "pause.circle",
                            control: .status(
                                text: localization.string("settings.status.enabled", defaultValue: "默认行为"),
                                systemImage: "checkmark.circle.fill",
                                tone: .positive,
                                actionTitle: nil
                            )
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "hardware-compatibility",
                    title: localization.string("settings.compatibility.title", defaultValue: "硬件兼容"),
                    systemImage: "cpu",
                    rows: hardwareCompatibilityRows
                )
            ]
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            isExpanded = expanded
            if !expanded { lastError = nil }
            onStateChange?()

        case let .setSlider(controlID, value, phase):
            guard controlID == ControlID.limitSlider, phase == .ended else { return }
            handleLimitChange(Int(value))

        case let .invokeAction(controlID):
            handleInvokeAction(controlID)

        case .setSwitch, .setSelection, .setNavigationSelection, .clearNavigationSelection, .setDate:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard case let .setNumber(controlID, value, phase) = action,
              controlID == ControlID.limitSlider,
              phase == .committed
        else { return }
        handleLimitChange(Int(value.rounded()))
    }
    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let availability = actionAvailability(for: invocation.reference)
        guard availability.isAvailable else {
            return ActionExecutionHandle {
                .failed(message: availability.reason ?? PluginKitLocalization.actionUnavailable)
            }
        }

        return ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            return self.performCanonicalAction(invocation)
        }
    }

    private func performCanonicalAction(
        _ invocation: ActionInvocation
    ) -> ActionExecutionResult {
        guard invocation.mode != .background || writer.isInstalledHelperAvailable else {
            return .failed(message: PluginKitLocalization.actionUnavailable)
        }

        let succeeded: Bool
        switch invocation.reference.key.actionID {
        case ActionID.setEnabled:
            guard case let .boolean(enabled)? = invocation.reference.parameters[ActionParameterID.enabled] else {
                return .failed(message: PluginKitLocalization.actionInvalidParameters)
            }
            if enabled, store.isEnabled {
                succeeded = applyCurrentMode(reason: "canonical-set-enabled-reassert") == nil
            } else {
                succeeded = handleEnableToggle(enabled)
            }
        case ActionID.setLimit:
            guard case let .integer(limit)? = invocation.reference.parameters[ActionParameterID.limit],
                  limit >= BatteryChargeLimits.minimumPercent,
                  limit <= BatteryChargeLimits.maximumPercent else {
                return .failed(message: PluginKitLocalization.actionInvalidParameters)
            }
            succeeded = handleLimitChange(Int(limit))
        case ActionID.hold:
            succeeded = setModeFromAction(.holdAtLimit)
        case ActionID.resume:
            succeeded = setModeFromAction(.charging)
        case ActionID.discharge:
            succeeded = setModeFromAction(.discharging)
        default:
            return .failed(message: PluginKitLocalization.actionInvalidParameters)
        }

        let failureMessage = lastErrorMessage ?? PluginKitLocalization.actionUnavailable
        return succeeded ? .succeeded() : .failed(message: failureMessage)
    }

    private var hardwareCompatibilityRows: [PluginSettingsRow] {
        var rows = [
            PluginSettingsRow(
                id: "control-method",
                title: localization.string("settings.compatibility.controlMethod", defaultValue: "充电控制方式"),
                systemImage: "cpu",
                control: .status(
                    text: capabilityDescription,
                    systemImage: capabilities.canInhibit ? "checkmark.circle.fill" : "xmark.circle.fill",
                    tone: capabilities.canInhibit ? .positive : .caution,
                    actionTitle: nil
                )
            )
        ]

        if capabilities.canForceDischarge {
            rows.append(
                PluginSettingsRow(
                    id: "force-discharge",
                    title: localization.string("settings.compatibility.forceDischarge", defaultValue: "强制放电"),
                    systemImage: "battery.25",
                    control: .status(
                        text: localization.string(
                            "settings.compatibility.forceDischarge.supported",
                            defaultValue: "支持（SMC）"
                        ),
                        systemImage: "checkmark.circle.fill",
                        tone: .positive,
                        actionTitle: nil
                    )
                )
            )
        }

        if capabilities.isBCLMOnly {
            rows.append(
                PluginSettingsRow(
                    id: "intel-limit",
                    title: localization.string("settings.compatibility.intelLimit.title", defaultValue: "Intel Mac 限制"),
                    description: localization.string(
                        "settings.compatibility.intelLimit.description",
                        defaultValue: "当前 Mac 仅支持 BCLM，电量低于上限时仍可能被系统自动充至上限。"
                    ),
                    systemImage: "exclamationmark.triangle",
                    control: .status(
                        text: localization.string("settings.status.limited", defaultValue: "有限支持"),
                        systemImage: "exclamationmark.triangle.fill",
                        tone: .caution,
                        actionTitle: nil
                    )
                )
            )
        }
        return rows
    }

    private var capabilityDescription: String {
        if capabilities.hasCHTE { return "CHTE (macOS 26+)" }
        if capabilities.hasCH0BC { return "CH0B + CH0C (Apple Silicon)" }
        if capabilities.hasBCLM { return "BCLM (Intel)" }
        return localization.string(
            "settings.compatibility.noSMCKey",
            defaultValue: "未检测到可用的 SMC 充电控制键"
        )
    }

    // MARK: - User Actions

    @discardableResult
    private func handleEnableToggle(_ value: Bool) -> Bool {
        if value {
            // Probe capabilities lazily — the helper install prompt happens
            // on first call. Surface a clear error if the hardware can't be
            // inhibited.
            capabilities = writer.probeCapabilities()
            if !capabilities.canInhibit && writer.isHelperAvailable {
                lastError = .hardware(.noSupportedSMCKey, rollbackError: nil)
                onStateChange?()
                return false
            }
        }
        var candidate = store.state
        candidate.isEnabled = value
        candidate.mode = .holdAtLimit
        return transition(to: candidate, reason: value ? "user-enable" : "user-disable")
    }

    @discardableResult
    private func handleLimitChange(_ percent: Int) -> Bool {
        var candidate = store.state
        candidate.limitPercent = percent
        if candidate.isEnabled { candidate.mode = .holdAtLimit }
        return transition(to: candidate, reason: "limit-change")
    }

    private func handleInvokeAction(_ controlID: String) {
        switch controlID {
        case ControlID.enableAction:
            handleEnableToggle(!store.isEnabled)

        case ControlID.chargeAction:
            handleChargeActionTap()

        case ControlID.dischargeAction:
            handleDischargeActionTap()

        case ControlID.manageSettings:
            // The host intercepts this action and opens the plugin's settings
            // configuration page. No-op here.
            break

        default:
            break
        }
    }

    private func handleChargeActionTap() {
        guard store.isEnabled else { return }
        let targetMode: BatteryChargeMode
        switch store.mode {
        case .holdAtLimit:
            // User explicitly asks to start charging. Move to .charging; the
            // monitoring loop will revert to .holdAtLimit when the battery
            // reaches the limit.
            targetMode = .charging
        case .charging:
            // User asks to stop charging — return to .holdAtLimit.
            targetMode = .holdAtLimit
        case .discharging:
            // Treat as "stop discharging and hold at current level."
            targetMode = .holdAtLimit
        }
        _ = setModeFromAction(targetMode)
    }

    private func handleDischargeActionTap() {
        guard store.isEnabled, capabilities.canForceDischarge else { return }
        let targetMode: BatteryChargeMode = store.mode == .discharging
            ? .holdAtLimit
            : .discharging
        _ = setModeFromAction(targetMode)
    }

    private var actionConfirmation: ActionConfirmation {
        ActionConfirmation(
            title: metadata.title,
            message: metadata.defaultDescription,
            confirmButtonTitle: metadata.title
        )
    }

    private func batteryModeActionDefinition(
        actionID: String,
        title: String,
        systemImage: String,
        risk: ActionRisk = .safe,
        capabilities: ActionExecutionCapabilities
    ) -> ActionDefinition {
        ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: actionID),
            title: title,
            description: metadata.defaultDescription,
            keywords: [metadata.title, title, "battery", "charge"],
            systemImage: systemImage,
            risk: risk,
            confirmation: actionConfirmation,
            externalInvocationPolicy: .confirmAlways,
            capabilities: capabilities
        )
    }

    private func enabledActionReference(_ enabled: Bool) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
            parameters: try! ActionParameterSet([ActionParameterID.enabled: .boolean(enabled)])
        )
    }

    private func limitActionReference(_ limit: Int) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setLimit),
            parameters: try! ActionParameterSet([ActionParameterID.limit: .integer(Int64(limit))])
        )
    }

    @discardableResult
    private func setModeFromAction(_ mode: BatteryChargeMode) -> Bool {
        guard store.isEnabled else { return false }
        var candidate = store.state
        candidate.mode = mode
        return transition(to: candidate, reason: "canonical-action")
    }

    private func actionFailureMessage(
        targetError: BatteryChargeWriteError,
        rollbackError: BatteryChargeWriteError?
    ) -> String {
        let targetMessage = localizedDescription(for: targetError)
        guard let rollbackError else { return targetMessage }
        return localization.format(
            "error.action.rollbackFailed",
            defaultValue: "%@；恢复先前状态失败：%@",
            targetMessage,
            localizedDescription(for: rollbackError)
        )
    }

    // MARK: - State Application

    @discardableResult
    private func applyCurrentMode(reason: String) -> BatteryChargeWriteError? {
        apply(store.state, reason: reason)
    }

    @discardableResult
    private func apply(
        _ state: BatteryChargeLimitState,
        reason: String
    ) -> BatteryChargeWriteError? {
        guard state.isEnabled else {
            return restoreUnrestrictedCharging(reason: reason, requireInstalledHelper: false)
        }

        let error: BatteryChargeWriteError?
        switch state.mode {
        case .holdAtLimit:
            let dischargeError = setForceDischarge(false)
            let inhibitError = inhibitCharging(limitPercent: state.limitPercent)
            error = dischargeError ?? inhibitError

        case .charging:
            error = restoreUnrestrictedCharging(reason: reason, requireInstalledHelper: false)

        case .discharging:
            // Force-discharge implies the inhibit keys must also be set so
            // the adapter doesn't fight us by charging back up.
            let inhibitError = inhibitCharging(limitPercent: state.limitPercent)
            let dischargeError = setForceDischarge(true)
            error = inhibitError ?? dischargeError
        }
        if let error {
            lastError = .hardware(error, rollbackError: nil)
            BatteryChargeLimitLog.plugin.error("Mode apply failed (\(reason, privacy: .public)): \(self.localizedDescription(for: error), privacy: .public)")
        } else {
            lastError = nil
        }
        onStateChange?()
        return error
    }

    private func transition(
        to candidate: BatteryChargeLimitState,
        reason: String
    ) -> Bool {
        let previous = store.state
        let requiresHardwareApplication = candidate.isEnabled || previous.isEnabled
        if requiresHardwareApplication, let targetError = apply(candidate, reason: reason) {
            let rollbackError = apply(previous, reason: "\(reason)-hardware-rollback")
            lastError = .hardware(targetError, rollbackError: rollbackError)
            onStateChange?()
            return false
        }

        let persistenceResult = store.commit(candidate)
        guard persistenceResult == .committed else {
            let hardwareRollbackError = requiresHardwareApplication
                ? apply(previous, reason: "\(reason)-persistence-rollback")
                : nil
            let storageRollbackSucceeded: Bool
            if case let .rejected(rollbackSucceeded) = persistenceResult {
                storageRollbackSucceeded = rollbackSucceeded
            } else {
                storageRollbackSucceeded = true
            }
            lastError = .persistence(
                storageRollbackSucceeded: storageRollbackSucceeded,
                hardwareRollbackError: hardwareRollbackError
            )
            onStateChange?()
            return false
        }

        if candidate.isEnabled {
            startActiveMonitoring()
        } else {
            stopActiveMonitoring()
        }
        lastError = nil
        onStateChange?()
        return true
    }

    /// Automatic mode transitions driven by battery level changes.
    /// Crucially, we DO NOT transition out of `.holdAtLimit` here — the user's
    /// design choice is that "below limit, charging stays off until manual resume."
    private func evaluateAutoTransitions() {
        guard store.isEnabled, let level = batterySnapshot.levelPercent else { return }

        switch store.mode {
        case .charging where level >= store.limitPercent:
            var candidate = store.state
            candidate.mode = .holdAtLimit
            _ = transition(to: candidate, reason: "auto-reached-limit")

        case .discharging where level <= store.limitPercent:
            var candidate = store.state
            candidate.mode = .holdAtLimit
            _ = transition(to: candidate, reason: "auto-discharged-to-limit")

        case .holdAtLimit:
            // Re-assert the inhibit periodically — firmware can reset SMC
            // keys across sleep, adapter unplug/replug, and rare hibernation
            // events. Cheap to re-issue.
            if batterySnapshot.state == .charging {
                applyCurrentMode(reason: "re-assert-inhibit")
            }

        default:
            break
        }
    }

    // MARK: - Monitoring

    private func startActiveMonitoring() {
        startMonitoring()
        registerSleepWakeObservers()
    }

    private func stopActiveMonitoring() {
        unregisterSleepWakeObservers()
        stopMonitoring()
    }

    private func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.batterySnapshot = self?.reader.readSnapshot() ?? .empty
                self?.evaluateAutoTransitions()
                self?.onStateChange?()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    private func registerSleepWakeObservers() {
        guard sleepObserver == nil, wakeObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemWillSleep() }
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemDidWake() }
        }
    }

    private func unregisterSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let obs = sleepObserver { center.removeObserver(obs) }
        if let obs = wakeObserver { center.removeObserver(obs) }
        sleepObserver = nil
        wakeObserver = nil
    }

    private func handleSystemWillSleep() {
        // Keep the inhibit in place on sleep so the Mac doesn't quietly
        // charge past the limit while the user is away.
        guard store.isEnabled else { return }
        BatteryChargeLimitLog.plugin.info("System will sleep — current mode: \(String(describing: self.store.mode), privacy: .public)")
    }

    private func handleSystemDidWake() {
        guard store.isEnabled else { return }
        batterySnapshot = reader.readSnapshot()
        applyCurrentMode(reason: "did-wake")
        BatteryChargeLimitLog.plugin.info("System did wake — re-asserted mode: \(String(describing: self.store.mode), privacy: .public)")
    }

    // MARK: - Panel Builder

    private var panelSubtitle: String {
        guard batterySnapshot.hasBattery else {
            return localization.string("panel.subtitle.noBattery", defaultValue: "未检测到电池")
        }
        let level = batterySnapshot.levelPercent ?? 0

        if !store.isEnabled {
            return localization.format("panel.subtitle.disabled", defaultValue: "未启用 · %d%%", level)
        }

        let limit = store.limitPercent
        switch store.mode {
        case .holdAtLimit:
            if level >= limit {
                return localization.format(
                    "panel.subtitle.limitReached",
                    defaultValue: "已达上限 · %d%% / %d%%",
                    level,
                    limit
                )
            }
            return localization.format(
                "panel.subtitle.chargingStopped",
                defaultValue: "已停止充电 · %d%% / %d%%",
                level,
                limit
            )
        case .charging:
            return localization.format("panel.subtitle.charging", defaultValue: "充电中 · %d%% → %d%%", level, limit)
        case .discharging:
            return localization.format("panel.subtitle.discharging", defaultValue: "放电中 · %d%% → %d%%", level, limit)
        }
    }

    private func buildDetail() -> PluginPanelDetail {
        var controls: [PluginPanelControl] = []

        // 1. Enable/disable toggle as the first row.
        let enableTitle = store.isEnabled
            ? localization.string("panel.action.disable", defaultValue: "停用充电上限")
            : localization.string("panel.action.enable", defaultValue: "启用充电上限")
        let enableIcon = store.isEnabled ? "checkmark.circle.fill" : "circle"
        controls.append(PluginPanelControl(
            id: ControlID.enableAction,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: enableTitle,
            actionIconSystemName: enableIcon,
            isEnabled: writer.isHelperAvailable
        ))

        if store.isEnabled {
            // 2. Limit slider — shown only when enabled
            controls.append(PluginPanelControl(
                id: ControlID.limitSlider,
                kind: .slider,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: localization.string("panel.section.limit", defaultValue: "充电上限"),
                sliderValue: Double(store.limitPercent),
                sliderBounds: Double(BatteryChargeLimits.minimumPercent)...Double(BatteryChargeLimits.maximumPercent),
                sliderStep: Double(BatteryChargeLimits.percentStep),
                valueLabel: "\(store.limitPercent)%",
                isEnabled: true
            ))

            // 3. Charge/stop button — context-sensitive title and icon
            let chargeTitle: String
            let chargeIcon: String
            switch store.mode {
            case .holdAtLimit:
                chargeTitle = localization.string("panel.action.startCharging", defaultValue: "开始充电")
                chargeIcon = "bolt.fill"
            case .charging:
                chargeTitle = localization.string("panel.action.stopCharging", defaultValue: "停止充电")
                chargeIcon = "bolt.slash.fill"
            case .discharging:
                chargeTitle = localization.string("panel.action.stopDischarging", defaultValue: "停止放电")
                chargeIcon = "stop.fill"
            }
            controls.append(PluginPanelControl(
                id: ControlID.chargeAction,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: chargeTitle,
                actionIconSystemName: chargeIcon,
                showsLeadingDivider: true,
                isEnabled: true
            ))

            // 4. Force-discharge button — only when supported AND battery is
            //    currently above the limit (otherwise it's a no-op).
            if capabilities.canForceDischarge,
               let level = batterySnapshot.levelPercent,
               level > store.limitPercent
            {
                let title = store.mode == .discharging
                    ? localization.string("panel.action.stopDischarging", defaultValue: "停止放电")
                    : localization.format(
                        "panel.action.dischargeToLimit",
                        defaultValue: "强制放电至 %d%%",
                        store.limitPercent
                    )
                controls.append(PluginPanelControl(
                    id: ControlID.dischargeAction,
                    kind: .actionRow,
                    options: [],
                    selectedOptionID: nil,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: nil,
                    actionTitle: title,
                    actionIconSystemName: "minus.circle",
                    isEnabled: true
                ))
            }
        }

        // 5. Open settings page
        controls.append(PluginPanelControl(
            id: ControlID.manageSettings,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.settings", defaultValue: "设置…"),
            actionIconSystemName: "slider.horizontal.3",
            actionBehavior: .dismissBeforeHandling,
            showsLeadingDivider: true,
            isEnabled: true
        ))

        // 6. Missing helper warning
        if !writer.isHelperAvailable {
            controls.append(PluginPanelControl(
                id: ControlID.missingHelper,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: localization.string("panel.action.missingHelper", defaultValue: "电池控制组件缺失"),
                actionIconSystemName: "exclamationmark.triangle",
                actionBehavior: .dismissBeforeHandling,
                showsLeadingDivider: true,
                isEnabled: false
            ))
        }

        return PluginPanelDetail(primaryControls: controls, secondaryPanel: nil)
    }

    private func localizedDescription(for error: BatteryChargeWriteError) -> String {
        error.localizedDescription(localization: localization)
    }

    @discardableResult
    private func inhibitCharging(limitPercent: Int) -> BatteryChargeWriteError? {
        let error = writer.inhibitCharging(limitPercent: limitPercent)
        markCleanupRequiredIfNeeded(after: error)
        return error
    }

    @discardableResult
    private func setForceDischarge(_ on: Bool) -> BatteryChargeWriteError? {
        let error = writer.setForceDischarge(on)
        if on {
            markCleanupRequiredIfNeeded(after: error)
        }
        return error
    }

    private func markCleanupRequiredIfNeeded(after error: BatteryChargeWriteError?) {
        if error == nil || error?.mayHaveChangedSMCState == true {
            requiresSMCCleanup = true
        }
    }

    private func restoreUnrestrictedChargingIfNeeded(reason: String, requireInstalledHelper: Bool) {
        guard requiresSMCCleanup else {
            BatteryChargeLimitLog.plugin.info("Skipped SMC charge cleanup for \(reason, privacy: .public); no active charge-control state")
            return
        }

        _ = restoreUnrestrictedCharging(reason: reason, requireInstalledHelper: requireInstalledHelper)
    }

    @discardableResult
    private func restoreUnrestrictedCharging(
        reason: String,
        requireInstalledHelper: Bool
    ) -> BatteryChargeWriteError? {
        guard !requireInstalledHelper || writer.isInstalledHelperAvailable else {
            BatteryChargeLimitLog.plugin.info("Skipped SMC charge cleanup for \(reason, privacy: .public); helper is not installed")
            return nil
        }

        let dischargeError = writer.setForceDischarge(false)
        let resumeError = writer.resumeCharging()

        if resumeError == nil && dischargeError == nil {
            requiresSMCCleanup = false
            BatteryChargeLimitLog.plugin.info("Cleared SMC charge-control state for \(reason, privacy: .public)")
            return nil
        } else {
            BatteryChargeLimitLog.plugin.error("Failed to fully clear SMC charge-control state for \(reason, privacy: .public)")
            return dischargeError ?? resumeError
        }
    }
}

private extension BatteryChargeWriteError {
    var mayHaveChangedSMCState: Bool {
        if case .writeFailed = self {
            return true
        }

        return false
    }
}
