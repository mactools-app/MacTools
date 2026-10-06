import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

enum KeepAwakeSettingsSearchEntryID {
    static let behavior = "behavior"
}

public final class KeepAwakePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        KeepAwakePluginProvider(context: context)
    }
}

@MainActor
private struct KeepAwakePluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let helperURL = context.resourceBundle.resourceURL?
            .appendingPathComponent("VirtualDisplayHelper", isDirectory: true)
            .appendingPathComponent("mactools-keep-awake-virtual-display-helper")
        let virtualDisplayManager = KeepAwakeVirtualDisplayManager(
            helperURL: helperURL,
            localization: localization
        )
        let userActivityMaintainer = KeepAwakeUserActivityMaintainer(
            localization: localization
        )
        return [
            KeepAwakePlugin(
                localization: localization,
                virtualDisplayManager: virtualDisplayManager,
                userActivityMaintainer: userActivityMaintainer
            )
        ]
    }
}

@MainActor
final class KeepAwakePlugin:
    MacToolsPlugin, PluginSettingsSearchProviding, DisplayTopologyRefreshing, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        var state = rowState
        state.compactIndicator = rowCompactIndicator
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    typealias SessionFactory = (
        PluginLocalization,
        @escaping (KeepAwakeSession.EndReason) -> Void
    ) -> any KeepAwakeSessionManaging

    private enum Timing {
        static let secondsPerMinute: TimeInterval = 60
    }

    private enum Symbol {
        static let screenTools = NSImage(
            systemSymbolName: "rectangle.and.hand.point.up.left",
            accessibilityDescription: nil
        ) == nil ? "display" : "rectangle.and.hand.point.up.left"
    }

    private enum StorageKey {
        static let persistentEnabled = "persistent-enabled"
        static let preferenceVersion = "behavior-preference-version"
        static let behavior = "display-behavior"

        enum Legacy {
            static let keepDisplayOn = "keep-display-on"
            static let preventAutomaticScreenLock = "prevent-automatic-screen-lock"
            static let awakeMode = "awake-mode"
            static let customPreventDisplaySleep = "custom-prevent-display-sleep"
            static let customPreventAutomaticScreenLock = "custom-prevent-automatic-screen-lock"
            static let customContinueWithLidClosed = "custom-continue-with-lid-closed"
            static let customKeepScreenBasedToolsWorking = "custom-keep-screen-based-tools-working"
            static let keepAwakeWithLidClosed = "keep-awake-with-lid-closed"
            static let keepDesktopAvailableWithLidClosed = "keep-desktop-available-with-lid-closed"
        }
    }

    private enum PreferenceVersion {
        static let current = 3
    }

    private struct PreferenceLoadResult {
        let preferences: KeepAwakePreferences
        let preservesFuturePayload: Bool
    }

    private enum ControlID {
        static let duration = "duration"
        static let behavior = "behavior"
    }

    private enum ActionID {
        static let toggle = "toggle"
        static let setEnabled = "set-enabled"
        static let startForDuration = "start-for-duration"
    }

    private enum ActionParameterID {
        static let enabled = "enabled"
        static let durationSeconds = "duration-seconds"
    }

    private enum VirtualDisplayIdentity {
        static let name = "MacTools Virtual Display"
        static let vendorNumber: UInt32 = 505
    }

    private enum DurationPreset: String {
        case forever
        case thirtyMinutes
        case oneHour
        case twoHours
        case fiveHours

        var timeInterval: TimeInterval? {
            switch self {
            case .forever:
                return nil
            case .thirtyMinutes:
                return 30 * 60
            case .oneHour:
                return 60 * 60
            case .twoHours:
                return 2 * 60 * 60
            case .fiveHours:
                return 5 * 60 * 60
            }
        }
    }

    private enum DurationOptionID {
        static let forever = DurationPreset.forever.rawValue
        static let thirtyMinutes = DurationPreset.thirtyMinutes.rawValue
        static let oneHour = DurationPreset.oneHour.rawValue
        static let twoHours = DurationPreset.twoHours.rawValue
        static let fiveHours = DurationPreset.fiveHours.rawValue
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "keep-awake",
            title: localization.string("metadata.title", defaultValue: "阻止休眠"),
            iconName: "moon",
            iconTint: Color(nsColor: .systemOrange),
            order: 50,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "保持 Mac 唤醒；可选保持屏幕常亮或让屏幕工具继续工作。MacBook 合盖运行要求连接电源"
            )
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "KeepAwakePlugin")
    private let localization: PluginLocalization
    private let sessionFactory: SessionFactory
    private let powerSourceMonitor: any KeepAwakePowerSourceMonitoring
    private let virtualDisplayManager: any KeepAwakeVirtualDisplayManaging
    private let userActivityMaintainer: any KeepAwakeUserActivityMaintaining
    private let displayProvider: any DisplayProviding
    private var storage: PluginStorage
    private var lastErrorMessage: String?
    private var session: (any KeepAwakeSessionManaging)?
    private var selectedDurationPreset: DurationPreset = .forever
    private var preferences: KeepAwakePreferences
    private var preservesFuturePreferencePayload: Bool
    private var powerSourceState: KeepAwakePowerSourceState
    private var hasActiveExternalDisplay: Bool
    private var virtualDisplayIsDesired = false
    private var virtualDisplayStartGeneration = 0
    private var virtualDisplayStartTask: Task<Void, Never>?
    private var isPreventingDisplaySleep = false
    private var scheduledEndDate: Date?
    private var timedStateRefreshTimer: Timer?
    private var pendingAutomaticFallback: PendingAutomaticFallback?
    private var pendingUserActivityCleanupError: Error?

    private struct PendingAutomaticFallback {
        let behavior: KeepAwakeBehavior
        let primaryError: Error
    }

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "keep-awake"),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        powerSourceMonitor: (any KeepAwakePowerSourceMonitoring)? = nil,
        virtualDisplayManager: (any KeepAwakeVirtualDisplayManaging)? = nil,
        userActivityMaintainer: (any KeepAwakeUserActivityMaintaining)? = nil,
        displayProvider: any DisplayProviding = SystemDisplayService(),
        sessionFactory: @escaping SessionFactory = { localization, onEnd in
            KeepAwakeSession(localization: localization, onEnd: onEnd)
        }
    ) {
        let resolvedPowerSourceMonitor = powerSourceMonitor ?? KeepAwakePowerSourceMonitor()
        self.localization = localization
        self.storage = context.storage
        self.sessionFactory = sessionFactory
        self.powerSourceMonitor = resolvedPowerSourceMonitor
        self.displayProvider = displayProvider
        self.virtualDisplayManager = virtualDisplayManager ?? KeepAwakeVirtualDisplayManager(
            helperURL: nil,
            localization: localization
        )
        self.userActivityMaintainer = userActivityMaintainer
            ?? KeepAwakeUserActivityMaintainer(localization: localization)
        self.powerSourceState = resolvedPowerSourceMonitor.currentState
        self.hasActiveExternalDisplay = Self.detectActiveExternalDisplay(
            using: displayProvider
        )
        let preferenceLoadResult = Self.loadPreferences(from: context.storage)
        self.preferences = preferenceLoadResult.preferences
        self.preservesFuturePreferencePayload = preferenceLoadResult.preservesFuturePayload

        resolvedPowerSourceMonitor.onChange = { [weak self] state in
            self?.handlePowerSourceChange(state)
        }
        self.virtualDisplayManager.onUnexpectedTermination = { [weak self] in
            self?.handleVirtualDisplayTermination()
        }
        self.userActivityMaintainer.onFailure = { [weak self] error in
            self?.handleUserActivityFailure(error)
        }
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: session != nil,
            isEnabled: true,
            isAvailable: true,
            detail: panelDetail,
            errorMessage: lastErrorMessage
        )
    }

    var rowCompactIndicator: PluginPanelRowCompactIndicator? {
        guard session != nil else {
            return nil
        }

        let icon: PluginPanelRowIndicatorIcon
        switch preferences.behavior {
        case .keepScreenBasedToolsWorking:
            icon = PluginPanelRowIndicatorIcon(
                systemImage: Symbol.screenTools,
                label: localization.string(
                    "panel.screenTools.indicator",
                    defaultValue: "屏幕工具"
                ),
                accessibilityLabel: localization.string(
                    "settings.mode.screenTools.title",
                    defaultValue: "让屏幕工具继续工作"
                )
            )
        case .keepDisplayOn:
            icon = PluginPanelRowIndicatorIcon(
                systemImage: "display",
                label: localization.string(
                    "panel.display.indicator",
                    defaultValue: "屏幕常亮"
                ),
                accessibilityLabel: localization.string(
                    "settings.display.keepOn",
                    defaultValue: "保持常亮"
                )
            )
        case .allowDisplayToTurnOff:
            return nil
        }

        return PluginPanelRowCompactIndicator(icons: [icon])
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: localization.string("metadata.title", defaultValue: "阻止休眠"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "保持 Mac 唤醒；可选保持屏幕常亮或让屏幕工具继续工作。MacBook 合盖运行要求连接电源"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "阻止休眠"),
                    localization.string(
                        "metadata.description",
                        defaultValue: "保持 Mac 唤醒；可选保持屏幕常亮或让屏幕工具继续工作。MacBook 合盖运行要求连接电源"
                    ),
                ],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: ActionParameterID.enabled,
                        title: localization.string("metadata.title", defaultValue: "阻止休眠"),
                        kind: .boolean
                    ),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.startForDuration),
                title: localization.string("metadata.title", defaultValue: "阻止休眠"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "保持 Mac 唤醒；可选保持屏幕常亮或让屏幕工具继续工作。MacBook 合盖运行要求连接电源"
                ),
                keywords: [metadata.title, "30min", "1h", "2h", "5h"],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: ActionParameterID.durationSeconds,
                        title: metadata.title,
                        kind: .integer
                    ),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        var entries = [
            ActionCatalogEntry(
                reference: toggleActionReference,
                title: localization.string(
                    "action.toggle.title",
                    defaultValue: "切换阻止休眠"
                ),
                subtitle: session == nil ? nil : panelSubtitle,
                presentationState: session == nil ? .inactive : .active
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: localization.string(
                    "action.enable.title",
                    defaultValue: "无限期阻止休眠"
                )
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: localization.string("action.disable.title", defaultValue: "停用阻止休眠")
            ),
        ]
        entries += [DurationPreset.thirtyMinutes, .oneHour, .twoHours, .fiveHours].map { preset in
            ActionCatalogEntry(
                reference: durationActionReference(preset),
                title: "\(metadata.title) · \(durationTitle(preset))"
            )
        }
        return entries
    }

    var settingsSearchEntries: [PluginSettingsSearchEntry] {
        [
            PluginSettingsSearchEntry(
                id: KeepAwakeSettingsSearchEntryID.behavior,
                title: localization.string(
                    "settings.mode.section",
                    defaultValue: "行为"
                ),
                description: localization.string(
                    "settings.mode.search.description",
                    defaultValue: "选择“阻止休眠”运行期间要保持可用的功能。"
                ),
                keywords: [
                    localization.string(
                        "settings.mode.keepMacAwake.title",
                        defaultValue: "允许屏幕关闭"
                    ),
                    localization.string(
                        "settings.display.keepOn",
                        defaultValue: "保持常亮"
                    ),
                    localization.string(
                        "settings.virtualDisplay.keepDesktopAvailable",
                        defaultValue: "让屏幕相关工具继续工作"
                    ),
                    localization.string(
                        "settings.lidClose.keepAwake",
                        defaultValue: "合盖保持唤醒"
                    ),
                ],
                systemImage: "slider.horizontal.3"
            )
        ]
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "behavior",
                    title: localization.string("settings.mode.section", defaultValue: "行为"),
                    systemImage: "slider.horizontal.3",
                    rows: [
                        PluginSettingsRow(
                            id: KeepAwakeSettingsSearchEntryID.behavior,
                            title: localization.string("settings.mode.section", defaultValue: "行为"),
                            systemImage: "moon.zzz",
                            helpItems: settingsBehaviorWarnings,
                            helpTone: .caution,
                            control: .choiceGroup(
                                selectionID: preferences.behavior.rawValue,
                                options: KeepAwakeBehavior.allCases.map {
                                    PluginSettingsOption(
                                        id: $0.rawValue,
                                        title: settingsBehaviorTitle($0),
                                        description: settingsBehaviorDescription($0),
                                        descriptionTone: $0 == .keepScreenBasedToolsWorking
                                            ? .caution
                                            : .neutral
                                    )
                                }
                            )
                        )
                    ]
                )
            ]
        )
    }

    func activate(context: PluginRuntimeContext) {
        storage = context.storage
        powerSourceMonitor.start()
        powerSourceState = powerSourceMonitor.currentState
        hasActiveExternalDisplay = Self.detectActiveExternalDisplay(using: displayProvider)
        let preferenceLoadResult = Self.loadPreferences(from: storage)
        preferences = preferenceLoadResult.preferences
        preservesFuturePreferencePayload = preferenceLoadResult.preservesFuturePayload

        guard storage.bool(forKey: StorageKey.persistentEnabled) else {
            return
        }

        selectedDurationPreset = .forever
        scheduledEndDate = nil
        applyKeepAwakeConfiguration()
    }

    func refresh() {
        if let pendingAutomaticFallback, session != nil {
            applyAutomaticFallback(
                to: pendingAutomaticFallback.behavior,
                because: pendingAutomaticFallback.primaryError
            )
        }

        retryPendingUserActivityCleanupIfNeeded()
        scheduleTimedStateRefreshIfNeeded()
    }

    func deactivate(reason: PluginDeactivationReason) {
        powerSourceMonitor.stop()
        do {
            try userActivityMaintainer.stop()
            pendingUserActivityCleanupError = nil
        } catch {
            logger.error(
                "failed to stop automatic screen-lock prevention during deactivation: \(error.localizedDescription, privacy: .public)"
            )
            pendingUserActivityCleanupError = error
            lastErrorMessage = error.localizedDescription
        }
        cancelVirtualDisplayStart()
        virtualDisplayManager.stop()
        guard reason.requiresStateCleanup else { return }
        session?.requestStop(reason: .userRequested)
    }

    func refreshDisplayTopology() {
        let hasExternalDisplay = Self.detectActiveExternalDisplay(using: displayProvider)
        guard hasExternalDisplay != hasActiveExternalDisplay else {
            return
        }

        hasActiveExternalDisplay = hasExternalDisplay
        reconcileVirtualDisplay()
        notifyChange()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setSwitch(isEnabled):
            setKeepAwakeEnabled(isEnabled)
        case .setDisclosureExpanded, .setNavigationSelection, .clearNavigationSelection:
            return
        case let .setSelection(controlID, optionID):
            switch controlID {
            case ControlID.duration:
                updateDurationPreset(using: optionID)
            case ControlID.behavior:
                guard let behavior = KeepAwakeBehavior(rawValue: optionID) else {
                    return
                }
                setBehavior(behavior)
            default:
                return
            }
        case .setDate, .setSlider, .invokeAction:
            return
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}

    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard case let .setSelection(controlID, optionID) = action,
              controlID == KeepAwakeSettingsSearchEntryID.behavior,
              let behavior = KeepAwakeBehavior(rawValue: optionID)
        else { return }
        setBehavior(behavior)
    }

    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let shouldBeEnabled: Bool
        switch invocation.reference.key.actionID {
        case ActionID.toggle:
            shouldBeEnabled = session == nil
            setKeepAwakeEnabled(shouldBeEnabled)
        case ActionID.setEnabled:
            guard case let .boolean(enabled)? = invocation.reference.parameters[ActionParameterID.enabled] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            shouldBeEnabled = enabled
            setKeepAwakeEnabled(enabled)
        case ActionID.startForDuration:
            guard case let .integer(seconds)? = invocation.reference.parameters[ActionParameterID.durationSeconds],
                  let preset = durationPreset(seconds: seconds) else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            shouldBeEnabled = true
            startKeepAwake(durationPreset: preset)
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }

        let failedMessage: String?
        if shouldBeEnabled, session == nil {
            failedMessage = localization.string(
                "error.enableFailed",
                defaultValue: "无法启用阻止休眠。"
            )
        } else if !shouldBeEnabled, let cleanupError = pendingUserActivityCleanupError {
            failedMessage = cleanupError.localizedDescription
        } else {
            failedMessage = nil
        }
        return ActionExecutionHandle {
            if let failedMessage {
                return .failed(message: failedMessage)
            }
            return .succeeded()
        }
    }

    private func actionReference(enabled: Bool) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
            parameters: try! ActionParameterSet([ActionParameterID.enabled: .boolean(enabled)])
        )
    }

    private var toggleActionReference: ActionReference {
        ActionReference(key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle))
    }

    private func durationActionReference(_ preset: DurationPreset) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.startForDuration),
            parameters: try! ActionParameterSet([
                ActionParameterID.durationSeconds: .integer(Int64(preset.timeInterval ?? 0)),
            ])
        )
    }

    private func durationPreset(seconds: Int64) -> DurationPreset? {
        [DurationPreset.thirtyMinutes, .oneHour, .twoHours, .fiveHours].first {
            Int64($0.timeInterval ?? 0) == seconds
        }
    }

    private func durationTitle(_ preset: DurationPreset) -> String {
        switch preset {
        case .forever: localization.string("panel.duration.forever", defaultValue: "永不")
        case .thirtyMinutes: "30min"
        case .oneHour: "1h"
        case .twoHours: "2h"
        case .fiveHours: "5h"
        }
    }

    private var panelSubtitle: String {
        guard session != nil else {
            return metadata.defaultDescription
        }

        if closedLidOperationIsWaitingForPower {
            return localization.string(
                "panel.subtitle.closedLidWaitingForPower",
                defaultValue: "合盖运行已暂停 · 正在等待电源"
            )
        }

        if let scheduledEndDate {
            let referenceDate = Date()
            let remaining = remainingTimeDescription(
                until: scheduledEndDate,
                referenceDate: referenceDate
            )
            let stopAt = KeepAwakeStopScheduleFormatting.absoluteStopLabel(
                until: scheduledEndDate,
                referenceDate: referenceDate,
                localization: localization
            )
            return localization.format(
                "panel.subtitle.timedFormat",
                defaultValue: "%@ · %@",
                remaining,
                stopAt
            )
        }

        return localization.string(
            "panel.duration.noAutomaticStop",
            defaultValue: "不会自动停止"
        )
    }

    private var panelDetail: PluginPanelDetail? {
        guard session != nil else {
            return nil
        }

        return PluginPanelDetail(
            primaryControls: [
                PluginPanelControl(
                    id: ControlID.duration,
                    kind: .segmented,
                    options: [
                        PluginPanelControlOption(
                            id: DurationOptionID.forever,
                            title: localization.string("panel.duration.forever", defaultValue: "永不")
                        ),
                        PluginPanelControlOption(id: DurationOptionID.thirtyMinutes, title: "30min"),
                        PluginPanelControlOption(id: DurationOptionID.oneHour, title: "1h"),
                        PluginPanelControlOption(id: DurationOptionID.twoHours, title: "2h"),
                        PluginPanelControlOption(id: DurationOptionID.fiveHours, title: "5h")
                    ],
                    selectedOptionID: selectedDurationPreset.rawValue,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: nil,
                    isEnabled: true
                ),
                PluginPanelControl(
                    id: ControlID.behavior,
                    kind: .segmented,
                    options: KeepAwakeBehavior.allCases.map {
                        PluginPanelControlOption(
                            id: $0.rawValue,
                            title: panelBehaviorTitle($0),
                            subtitle: panelBehaviorDescription($0)
                        )
                    },
                    selectedOptionID: preferences.behavior.rawValue,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: localization.string(
                        "settings.mode.section",
                        defaultValue: "行为"
                    ),
                    showsLeadingDivider: true,
                    isEnabled: true
                )
            ],
            secondaryPanel: nil
        )
    }

    private func setKeepAwakeEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            lastErrorMessage = nil
            clearPersistentEnabled()
            session?.requestStop(reason: .userRequested)

            if session == nil {
                resetSelectionToDefaults()
                notifyChange()
            }

            return
        }

        selectedDurationPreset = .forever
        lastErrorMessage = nil
        applyKeepAwakeConfiguration()
    }

    private func startKeepAwake(durationPreset: DurationPreset) {
        selectedDurationPreset = durationPreset
        lastErrorMessage = nil
        applyKeepAwakeConfiguration()
    }

    private func updateDurationPreset(using optionID: String) {
        guard let preset = DurationPreset(rawValue: optionID) else {
            return
        }

        selectedDurationPreset = preset
        lastErrorMessage = nil
        persistCurrentSelectionIfRunning()

        guard session != nil else {
            notifyChange()
            return
        }

        applyKeepAwakeConfiguration()
    }

    func setBehavior(_ behavior: KeepAwakeBehavior) {
        let behaviorChanged = preferences.behavior != behavior
        guard behaviorChanged || preservesFuturePreferencePayload else {
            return
        }

        lastErrorMessage = nil

        do {
            if behaviorChanged {
                try transitionBehavior(to: behavior)
            }
            pendingAutomaticFallback = nil
            preservesFuturePreferencePayload = false
            persistPreferences()
            notifyChange()
        } catch {
            logger.error("keep-awake behavior update failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            notifyChange()
        }
    }

    private func panelBehaviorDescription(_ behavior: KeepAwakeBehavior) -> String {
        if behavior == .keepScreenBasedToolsWorking {
            return localization.string(
                "panel.behavior.screenTools.description",
                defaultValue: "保持屏幕常亮并防止自动锁定。"
            )
        }
        return settingsBehaviorDescription(behavior)
    }

    private func panelBehaviorTitle(_ behavior: KeepAwakeBehavior) -> String {
        switch behavior {
        case .allowDisplayToTurnOff:
            localization.string("panel.behavior.default", defaultValue: "默认")
        case .keepDisplayOn:
            localization.string("panel.display.indicator", defaultValue: "屏幕常亮")
        case .keepScreenBasedToolsWorking:
            localization.string("panel.screenTools.indicator", defaultValue: "屏幕工具")
        }
    }

    private func settingsBehaviorTitle(_ behavior: KeepAwakeBehavior) -> String {
        switch behavior {
        case .allowDisplayToTurnOff:
            localization.string("settings.mode.keepMacAwake.title", defaultValue: "允许屏幕关闭")
        case .keepDisplayOn:
            localization.string("settings.display.keepOn", defaultValue: "保持常亮")
        case .keepScreenBasedToolsWorking:
            localization.string("settings.mode.screenTools.shortTitle", defaultValue: "屏幕工具")
        }
    }

    private func settingsBehaviorDescription(_ behavior: KeepAwakeBehavior) -> String {
        switch behavior {
        case .allowDisplayToTurnOff:
            localization.string(
                "settings.mode.keepMacAwake.description",
                defaultValue: "保持 Mac 唤醒；屏幕关闭与锁定仍遵循 macOS 设置。"
            )
        case .keepDisplayOn:
            localization.string(
                "settings.display.keepOn.description",
                defaultValue: "保持屏幕常亮。自动锁定仍遵循 macOS 设置。"
            )
        case .keepScreenBasedToolsWorking:
            localization.string(
                "settings.mode.screenTools.description",
                defaultValue: "保持屏幕可用并防止自动锁定，适用于 Codex Computer Use、桌面自动化、屏幕共享和远程控制。"
            )
        }
    }

    private var settingsBehaviorWarnings: [String] {
        guard preferences.behavior == .keepScreenBasedToolsWorking else { return [] }

        var messages: [String] = []
        if powerSourceState.isPortableMac {
            messages.append(localization.string(
                "settings.automaticLock.warning.closedLidPower",
                defaultValue: "合盖运行要求 MacBook 连接电源。"
            ))
            messages.append(localization.string(
                "settings.mode.screenTools.warning.ventilation",
                defaultValue: "保持 Mac 通风，切勿将其放入包中。"
            ))
            messages.append(localization.string(
                virtualDisplayManager.isAvailable
                    ? "settings.mode.screenTools.warning.experimental"
                    : "settings.mode.screenTools.warning.unavailable",
                defaultValue: virtualDisplayManager.isAvailable
                    ? "合盖软件显示器为实验性功能，macOS 更新后可能失效。"
                    : "当前插件包不包含合盖软件显示器组件。"
            ))
        }
        messages.append(localization.string(
            "settings.mode.screenTools.warning.manualLock",
            defaultValue: "手动锁定仍然有效；不会解锁已锁定的会话。"
        ))
        return messages
    }

    private func applyKeepAwakeConfiguration() {
        let hadRunningSession = session != nil
        let session = session ?? sessionFactory(localization) { [weak self] reason in
            self?.handleSessionEnd(reason)
        }
        let endDate = resolvedScheduledEndDate(referenceDate: Date())
        let capabilities = activeCapabilities
        let shouldPreventLidCloseSleep = capabilities.continueWithLidClosed
            && powerSourceState.canPreventLidCloseSleep
        let shouldPreventDisplaySleep = displaySleepPreventionShouldRun(
            capabilities: capabilities
        )

        do {
            try session.start(
                until: endDate,
                preventDisplaySleep: hadRunningSession ? shouldPreventDisplaySleep : false,
                preventLidCloseSleep: hadRunningSession ? shouldPreventLidCloseSleep : false
            )
            self.session = session
            isPreventingDisplaySleep = session.isPreventingDisplaySleep
            scheduledEndDate = endDate
            persistCurrentSelectionIfRunning()
            scheduleTimedStateRefreshIfNeeded()
            lastErrorMessage = nil
            do {
                try reconcileRuntimeConfiguration()
            } catch {
                handleRuntimeConfigurationFailure(error)
            }
            notifyChange()
        } catch {
            logger.error("keep-awake session update failed: \(error.localizedDescription, privacy: .public)")
            var cleanupError: Error?
            if !hadRunningSession {
                do {
                    try userActivityMaintainer.stop()
                    pendingUserActivityCleanupError = nil
                } catch {
                    logger.error(
                        "failed to clean up automatic screen-lock prevention after session start failure: \(error.localizedDescription, privacy: .public)"
                    )
                    pendingUserActivityCleanupError = error
                    cleanupError = error
                }
                cancelVirtualDisplayStart()
                virtualDisplayManager.stop()
            }
            lastErrorMessage = cleanupError?.localizedDescription ?? error.localizedDescription
            notifyChange()
        }
    }

    private var virtualDisplayShouldBePrepared: Bool {
        let capabilities = activeCapabilities
        return capabilities.keepScreenBasedToolsWorking
            && capabilities.continueWithLidClosed
            && powerSourceState.canRunVirtualDisplay
            && !hasActiveExternalDisplay
    }

    private var virtualDisplayShouldRun: Bool {
        session != nil && virtualDisplayShouldBePrepared
    }

    private var closedLidScreenServicesCanRun: Bool {
        return !powerSourceState.isPortableMac
            || !powerSourceState.isLidClosed
            || powerSourceState.isOnExternalPower
    }

    private var activeCapabilities: KeepAwakeCapabilities {
        preferences.capabilities
    }

    private func displaySleepPreventionShouldRun(
        capabilities: KeepAwakeCapabilities
    ) -> Bool {
        closedLidScreenServicesCanRun
            && (capabilities.preventDisplaySleep || virtualDisplayShouldBePrepared)
    }

    private func automaticLockPreventionShouldRun(
        capabilities: KeepAwakeCapabilities
    ) -> Bool {
        closedLidScreenServicesCanRun
            && capabilities.preventAutomaticScreenLock
    }

    private var closedLidOperationIsWaitingForPower: Bool {
        session != nil
            && activeCapabilities.continueWithLidClosed
            && powerSourceState.isPortableMac
            && powerSourceState.isLidClosed
            && !powerSourceState.isOnExternalPower
    }

    private func reconcileRuntimeConfiguration() throws {
        guard let session else {
            try userActivityMaintainer.stop()
            stopVirtualDisplayIfNeeded()
            return
        }

        let capabilities = activeCapabilities
        do {
            try session.setPreventLidCloseSleep(
                capabilities.continueWithLidClosed
                    && powerSourceState.canPreventLidCloseSleep
            )
        } catch {
            throw KeepAwakeRuntimeServiceError.lidClose(error)
        }

        do {
            try updateDisplaySleepAssertion(
                displaySleepPreventionShouldRun(capabilities: capabilities),
                session: session
            )
        } catch {
            throw KeepAwakeRuntimeServiceError.display(error)
        }

        guard automaticLockPreventionShouldRun(capabilities: capabilities) else {
            do {
                try userActivityMaintainer.stop()
                pendingUserActivityCleanupError = nil
            } catch {
                pendingUserActivityCleanupError = error
                throw KeepAwakeRuntimeServiceError.userActivityCleanup(error)
            }
            reconcileVirtualDisplay()
            return
        }

        do {
            try userActivityMaintainer.start()
            pendingUserActivityCleanupError = nil
        } catch {
            throw KeepAwakeRuntimeServiceError.userActivity(error)
        }
        reconcileVirtualDisplay()
    }

    private func transitionBehavior(to behavior: KeepAwakeBehavior) throws {
        guard preferences.behavior != behavior else {
            return
        }

        let previousPreferences = preferences
        let nextPreferences = KeepAwakePreferences(behavior: behavior)

        if previousPreferences.capabilities.preventAutomaticScreenLock,
           !nextPreferences.capabilities.preventAutomaticScreenLock {
            // Release the security-sensitive user-activity assertion before the
            // selected behavior can claim that automatic locking follows macOS.
            try userActivityMaintainer.stop()
        }

        preferences = nextPreferences
        do {
            try reconcileRuntimeConfiguration()
        } catch {
            preferences = previousPreferences
            try? reconcileRuntimeConfiguration()
            throw error
        }
    }

    private func applyAutomaticFallback(
        to behavior: KeepAwakeBehavior,
        because primaryError: Error
    ) {
        do {
            try transitionBehavior(to: behavior)
            pendingAutomaticFallback = nil
            persistPreferences()
            lastErrorMessage = primaryError.localizedDescription
        } catch {
            logger.error(
                "failed to clean up screen-tools behavior during fallback: \(error.localizedDescription, privacy: .public)"
            )
            pendingAutomaticFallback = PendingAutomaticFallback(
                behavior: behavior,
                primaryError: primaryError
            )
            lastErrorMessage = error.localizedDescription
        }
        notifyChange()
    }

    private func reconcileVirtualDisplay() {
        guard virtualDisplayShouldRun else {
            stopVirtualDisplayIfNeeded()
            return
        }

        guard !virtualDisplayIsDesired
                || (!virtualDisplayManager.isActive && virtualDisplayStartTask == nil)
        else {
            return
        }

        virtualDisplayIsDesired = true
        cancelVirtualDisplayStart()

        guard let session else {
            return
        }

        do {
            try updateDisplaySleepAssertion(true, session: session)
        } catch {
            failVirtualDisplayStart(error)
            return
        }

        let generation = virtualDisplayStartGeneration
        virtualDisplayStartTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.virtualDisplayManager.start()
                try Task.checkCancellation()

                guard generation == self.virtualDisplayStartGeneration,
                      self.virtualDisplayIsDesired,
                      self.virtualDisplayShouldRun
                else {
                    self.virtualDisplayManager.stop()
                    return
                }

                self.virtualDisplayStartTask = nil
                self.notifyChange()
            } catch is CancellationError {
                guard generation == self.virtualDisplayStartGeneration else {
                    return
                }
                self.virtualDisplayStartTask = nil
            } catch {
                guard generation == self.virtualDisplayStartGeneration,
                      self.virtualDisplayIsDesired
                else {
                    return
                }
                self.virtualDisplayStartTask = nil
                self.failVirtualDisplayStart(error)
            }
        }
    }

    private func stopVirtualDisplayIfNeeded() {
        guard virtualDisplayIsDesired
                || virtualDisplayStartTask != nil
                || virtualDisplayManager.isActive
        else {
            return
        }

        virtualDisplayIsDesired = false
        cancelVirtualDisplayStart()
        virtualDisplayManager.stop()
    }

    private func failVirtualDisplayStart(_ error: Error) {
        logger.error(
            "software display start failed: \(error.localizedDescription, privacy: .public)"
        )
        virtualDisplayIsDesired = false
        cancelVirtualDisplayStart()
        virtualDisplayManager.stop()
        applyAutomaticFallback(to: .keepDisplayOn, because: error)
    }

    private func handleRuntimeConfigurationFailure(_ error: Error) {
        let fallbackBehavior: KeepAwakeBehavior
        if let runtimeError = error as? KeepAwakeRuntimeServiceError {
            switch runtimeError {
            case .lidClose:
                fallbackBehavior = .keepDisplayOn
            case .display:
                fallbackBehavior = .allowDisplayToTurnOff
            case .userActivity:
                fallbackBehavior = .keepDisplayOn
            case let .userActivityCleanup(cleanupError):
                stopVirtualDisplayIfNeeded()
                pendingUserActivityCleanupError = cleanupError
                lastErrorMessage = cleanupError.localizedDescription
                notifyChange()
                return
            }
        } else {
            fallbackBehavior = preferences.behavior
        }

        stopVirtualDisplayIfNeeded()
        applyAutomaticFallback(to: fallbackBehavior, because: error)
    }

    private func cancelVirtualDisplayStart() {
        virtualDisplayStartGeneration += 1
        virtualDisplayStartTask?.cancel()
        virtualDisplayStartTask = nil
    }

    private func updateDisplaySleepAssertion(
        _ shouldPreventDisplaySleep: Bool,
        session: any KeepAwakeSessionManaging
    ) throws {
        guard isPreventingDisplaySleep != shouldPreventDisplaySleep else {
            return
        }

        try session.setPreventDisplaySleep(shouldPreventDisplaySleep)
        isPreventingDisplaySleep = shouldPreventDisplaySleep
    }

    private static func detectActiveExternalDisplay(
        using displayProvider: any DisplayProviding
    ) -> Bool {
        displayProvider.listConnectedDisplays().contains { display in
            guard !display.isBuiltin else {
                return false
            }

            return display.name != VirtualDisplayIdentity.name
                || display.vendorNumber != VirtualDisplayIdentity.vendorNumber
        }
    }

    private func resolvedScheduledEndDate(referenceDate: Date) -> Date? {
        selectedDurationPreset.timeInterval.map(referenceDate.addingTimeInterval)
    }

    private func remainingTimeDescription(
        until endDate: Date,
        referenceDate: Date
    ) -> String {
        let remainingDuration = max(endDate.timeIntervalSince(referenceDate), 0)
        let remainingMinutes = max(
            Int(ceil(remainingDuration / Timing.secondsPerMinute)),
            1
        )

        let hours = remainingMinutes / 60
        let minutes = remainingMinutes % 60

        if hours == 0 {
            return localization.format(
                "panel.duration.remainingMinutesFormat",
                defaultValue: "剩余 %d 分钟",
                remainingMinutes
            )
        }

        if minutes == 0 {
            return localization.format(
                "panel.duration.remainingHoursFormat",
                defaultValue: "剩余 %d 小时",
                hours
            )
        }

        return localization.format(
            "panel.duration.remainingHoursMinutesFormat",
            defaultValue: "剩余 %d 小时 %d 分钟",
            hours,
            minutes
        )
    }

    private func scheduleTimedStateRefreshIfNeeded() {
        invalidateTimedStateRefreshTimer()

        guard session != nil, let scheduledEndDate else {
            return
        }

        let remainingDuration = scheduledEndDate.timeIntervalSinceNow

        guard remainingDuration > 0 else {
            return
        }

        let remainder = remainingDuration.truncatingRemainder(dividingBy: Timing.secondsPerMinute)
        let nextRefreshInterval = remainder > 0 ? remainder : Timing.secondsPerMinute

        let timer = Timer(
            timeInterval: nextRefreshInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTimedStateRefreshTimerFired()
            }
        }
        timer.tolerance = min(1, nextRefreshInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        timedStateRefreshTimer = timer
    }

    private func handleTimedStateRefreshTimerFired() {
        guard session != nil, scheduledEndDate != nil else {
            invalidateTimedStateRefreshTimer()
            return
        }

        notifyChange()
        scheduleTimedStateRefreshIfNeeded()
    }

    private func invalidateTimedStateRefreshTimer() {
        timedStateRefreshTimer?.invalidate()
        timedStateRefreshTimer = nil
    }

    private func handleSessionEnd(_ reason: KeepAwakeSession.EndReason) {
        session = nil
        pendingAutomaticFallback = nil
        isPreventingDisplaySleep = false
        let cleanupError: Error?
        do {
            try userActivityMaintainer.stop()
            pendingUserActivityCleanupError = nil
            cleanupError = nil
        } catch {
            logger.error(
                "failed to release automatic screen-lock prevention after session end: \(error.localizedDescription, privacy: .public)"
            )
            pendingUserActivityCleanupError = error
            cleanupError = error
        }
        virtualDisplayIsDesired = false
        cancelVirtualDisplayStart()
        virtualDisplayManager.stop()
        resetSelectionToDefaults()

        switch (reason, cleanupError) {
        case (.userRequested, nil), (.completed, nil):
            lastErrorMessage = nil
        case let (.userRequested, error?), let (.completed, error?):
            lastErrorMessage = error.localizedDescription
        }

        notifyChange()
    }

    private func persistCurrentSelectionIfRunning() {
        guard session != nil, selectedDurationPreset == .forever else {
            clearPersistentEnabled()
            return
        }

        storage.set(true, forKey: StorageKey.persistentEnabled)
    }

    private func clearPersistentEnabled() {
        storage.removeObject(forKey: StorageKey.persistentEnabled)
    }

    private func persistPreferences() {
        guard !preservesFuturePreferencePayload else {
            return
        }
        Self.persist(preferences, to: storage)
    }

    private static func loadPreferences(from storage: PluginStorage) -> PreferenceLoadResult {
        let storedVersion = storage.integer(forKey: StorageKey.preferenceVersion)
        let storedBehavior = storage.string(forKey: StorageKey.behavior)
            .flatMap(KeepAwakeBehavior.init(rawValue:))

        if storedVersion > PreferenceVersion.current {
            return PreferenceLoadResult(
                preferences: KeepAwakePreferences(
                    behavior: storedBehavior ?? .allowDisplayToTurnOff
                ),
                preservesFuturePayload: true
            )
        }

        if storedVersion == PreferenceVersion.current,
           let storedBehavior {
            let behavior = storedBehavior
            let preferences = KeepAwakePreferences(behavior: behavior)
            removeLegacyPreferences(from: storage)
            return PreferenceLoadResult(
                preferences: preferences,
                preservesFuturePayload: false
            )
        }

        let behavior: KeepAwakeBehavior
        if let storedBehavior {
            // The replacement payload is written before the version marker. If
            // the process stopped between those writes, finish that migration.
            behavior = storedBehavior
        } else if storedVersion == 2 {
            behavior = migratedBehavior(
                keepDisplayOn: storage.bool(forKey: StorageKey.Legacy.keepDisplayOn),
                keepScreenBasedToolsWorking: storage.bool(
                    forKey: StorageKey.Legacy.preventAutomaticScreenLock
                )
            )
        } else {
            var keepDisplayOn = storage.bool(forKey: StorageKey.Legacy.keepDisplayOn)
                || storage.bool(forKey: StorageKey.Legacy.customPreventDisplaySleep)
            var keepScreenBasedToolsWorking = storage.bool(
                forKey: StorageKey.Legacy.preventAutomaticScreenLock
            )
                || storage.bool(forKey: StorageKey.Legacy.customPreventAutomaticScreenLock)
                || storage.bool(forKey: StorageKey.Legacy.customContinueWithLidClosed)
                || storage.bool(forKey: StorageKey.Legacy.customKeepScreenBasedToolsWorking)
                || storage.bool(forKey: StorageKey.Legacy.keepAwakeWithLidClosed)
                || storage.bool(forKey: StorageKey.Legacy.keepDesktopAvailableWithLidClosed)

            switch storage.string(forKey: StorageKey.Legacy.awakeMode) {
            case "keep-mac-awake":
                keepDisplayOn = false
                keepScreenBasedToolsWorking = false
            case "screen-based-tools":
                keepDisplayOn = true
                keepScreenBasedToolsWorking = true
            default:
                break
            }

            behavior = migratedBehavior(
                keepDisplayOn: keepDisplayOn,
                keepScreenBasedToolsWorking: keepScreenBasedToolsWorking
            )
        }

        let preferences = KeepAwakePreferences(behavior: behavior)

        // Write the complete replacement before deleting any legacy values so a
        // partially completed migration never loses the user's configuration.
        persist(preferences, to: storage)
        removeLegacyPreferences(from: storage)
        return PreferenceLoadResult(
            preferences: preferences,
            preservesFuturePayload: false
        )
    }

    private static func persist(
        _ preferences: KeepAwakePreferences,
        to storage: PluginStorage
    ) {
        storage.set(preferences.behavior.rawValue, forKey: StorageKey.behavior)
        storage.set(PreferenceVersion.current, forKey: StorageKey.preferenceVersion)
    }

    private static func removeLegacyPreferences(from storage: PluginStorage) {
        storage.removeObject(forKey: StorageKey.Legacy.keepDisplayOn)
        storage.removeObject(forKey: StorageKey.Legacy.preventAutomaticScreenLock)
        storage.removeObject(forKey: StorageKey.Legacy.awakeMode)
        storage.removeObject(forKey: StorageKey.Legacy.customPreventDisplaySleep)
        storage.removeObject(forKey: StorageKey.Legacy.customPreventAutomaticScreenLock)
        storage.removeObject(forKey: StorageKey.Legacy.customContinueWithLidClosed)
        storage.removeObject(forKey: StorageKey.Legacy.customKeepScreenBasedToolsWorking)
        storage.removeObject(forKey: StorageKey.Legacy.keepAwakeWithLidClosed)
        storage.removeObject(forKey: StorageKey.Legacy.keepDesktopAvailableWithLidClosed)
    }

    private static func migratedBehavior(
        keepDisplayOn: Bool,
        keepScreenBasedToolsWorking: Bool
    ) -> KeepAwakeBehavior {
        if keepScreenBasedToolsWorking {
            return .keepScreenBasedToolsWorking
        }
        if keepDisplayOn {
            return .keepDisplayOn
        }
        return .allowDisplayToTurnOff
    }

    private func handlePowerSourceChange(_ state: KeepAwakePowerSourceState) {
        guard state != powerSourceState else {
            return
        }

        powerSourceState = state

        guard session != nil else {
            reconcileVirtualDisplay()
            notifyChange()
            return
        }

        do {
            lastErrorMessage = nil
            try reconcileRuntimeConfiguration()
            notifyChange()
        } catch {
            logger.error("failed to reconcile keep-awake preferences after power change: \(error.localizedDescription, privacy: .public)")
            handleRuntimeConfigurationFailure(error)
        }
    }

    private func handleVirtualDisplayTermination() {
        guard activeCapabilities.keepScreenBasedToolsWorking else {
            return
        }

        let error = KeepAwakeRuntimeError(
            message: localization.string(
                "error.virtualDisplay.terminated",
                defaultValue: "软件显示器已停止；已切换为保持屏幕常亮。"
            )
        )
        virtualDisplayIsDesired = false
        cancelVirtualDisplayStart()
        virtualDisplayManager.stop()
        applyAutomaticFallback(to: .keepDisplayOn, because: error)
    }

    private func handleUserActivityFailure(_ error: Error) {
        guard activeCapabilities.preventAutomaticScreenLock else {
            return
        }

        logger.error(
            "automatic screen-lock prevention failed: \(error.localizedDescription, privacy: .public)"
        )
        stopVirtualDisplayIfNeeded()
        applyAutomaticFallback(to: .keepDisplayOn, because: error)
    }

    private func resetSelectionToDefaults() {
        selectedDurationPreset = .forever
        scheduledEndDate = nil
        invalidateTimedStateRefreshTimer()
    }

    private func retryPendingUserActivityCleanupIfNeeded() {
        guard let pendingError = pendingUserActivityCleanupError else {
            return
        }

        if session != nil,
           automaticLockPreventionShouldRun(capabilities: activeCapabilities) {
            pendingUserActivityCleanupError = nil
            if lastErrorMessage == pendingError.localizedDescription {
                lastErrorMessage = nil
            }
            return
        }

        do {
            try userActivityMaintainer.stop()
            pendingUserActivityCleanupError = nil
            if lastErrorMessage == pendingError.localizedDescription {
                lastErrorMessage = nil
            }
        } catch {
            logger.error(
                "failed to finish automatic screen-lock cleanup: \(error.localizedDescription, privacy: .public)"
            )
            pendingUserActivityCleanupError = error
            lastErrorMessage = error.localizedDescription
        }
    }

    private func notifyChange() {
        onStateChange?()
    }
}

private struct KeepAwakeRuntimeError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private enum KeepAwakeRuntimeServiceError: LocalizedError {
    case lidClose(Error)
    case display(Error)
    case userActivity(Error)
    case userActivityCleanup(Error)

    var errorDescription: String? {
        switch self {
        case let .lidClose(error),
             let .display(error),
             let .userActivity(error),
             let .userActivityCleanup(error):
            return error.localizedDescription
        }
    }
}

/// Formats the scheduled stop moment for Keep Awake subtitles.
enum KeepAwakeStopScheduleFormatting {
    static func absoluteStopLabel(
        until endDate: Date,
        referenceDate: Date,
        calendar: Calendar = .current,
        localization: PluginLocalization,
        locale: Locale = .current
    ) -> String {
        let timeZone = calendar.timeZone
        let timeText = timeString(from: endDate, locale: locale, timeZone: timeZone)

        if calendar.isDate(endDate, inSameDayAs: referenceDate) {
            return timeText
        }

        if let tomorrowStart = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: referenceDate)
        ), calendar.isDate(endDate, inSameDayAs: tomorrowStart) {
            return localization.format(
                "panel.subtitle.stopTomorrowAtTimeFormat",
                defaultValue: "明天 %@",
                timeText
            )
        }

        let dateText = dateString(
            from: endDate,
            referenceDate: referenceDate,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        return localization.format(
            "panel.subtitle.stopAtDateTimeFormat",
            defaultValue: "%@ %@",
            dateText,
            timeText
        )
    }

    private static func timeString(from date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        // Follow the user's locale and preferred 12/24-hour clock while keeping minutes explicit.
        if let format = DateFormatter.dateFormat(fromTemplate: "jm", options: 0, locale: locale) {
            formatter.dateFormat = format
        } else {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        }
        return formatter.string(from: date)
    }

    private static func dateString(
        from date: Date,
        referenceDate: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: referenceDate)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }
}
