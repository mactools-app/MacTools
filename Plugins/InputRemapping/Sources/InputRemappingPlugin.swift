import AppKit
import ApplicationServices
import CoreGraphics
@preconcurrency import IOKit.hid
import MacToolsPluginKit
import SwiftUI

public final class InputRemappingPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        InputRemappingProvider(context: context)
    }
}

@MainActor
private struct InputRemappingProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            InputRemappingPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            )
        ]
    }
}

enum InputRemappingInputMonitoringStatus: Equatable {
    case granted
    case denied
    case unknown
}

enum InputRemappingRecordingTarget: Equatable {
    case input
    case shortcut
}

enum InputRemappingRecordingFailure: Equatable {
    case eventTapUnavailable
}

struct InputRemappingRecordingError: Equatable {
    let ruleID: UUID
    let target: InputRemappingRecordingTarget
    let failure: InputRemappingRecordingFailure
}

enum InputRemappingRecordingPermissionIssue: Equatable {
    case accessibility
    case inputMonitoring

    var permissionID: String {
        switch self {
        case .accessibility: "accessibility"
        case .inputMonitoring: "input-monitoring"
        }
    }
}

struct InputRemappingRecordingPermissionGuidance: Equatable {
    let issue: InputRemappingRecordingPermissionIssue
    let title: String
    let detail: String
}

@MainActor
final class InputRemappingButtonCaptureCoordinator: ObservableObject {
    @Published private(set) var recordingRuleID: UUID?
    @Published private(set) var recordingShortcutRuleID: UUID?
    @Published private(set) var preparingRuleID: UUID?
    @Published private(set) var preparingShortcutRuleID: UUID?
    @Published private(set) var recordingError: InputRemappingRecordingError?

    private let tap: any InputRemappingEventTapping
    private let scheduleArming: (@escaping @MainActor () -> Void) -> Void

    init(
        tap: any InputRemappingEventTapping,
        scheduleArming: @escaping (@escaping @MainActor () -> Void) -> Void = { operation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Task { @MainActor in operation() }
            }
        }
    ) {
        self.tap = tap
        self.scheduleArming = scheduleArming
    }

    func start(
        ruleID: UUID,
        onCapture: @escaping @MainActor (InputRemappingCapturedInput) -> Void,
        onFailure: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        cancel()
        recordingError = nil
        guard tap.start() else {
            recordingError = InputRemappingRecordingError(
                ruleID: ruleID,
                target: .input,
                failure: .eventTapUnavailable
            )
            onFailure()
            return false
        }
        preparingRuleID = ruleID
        scheduleArming { [weak self] in
            guard let self, self.preparingRuleID == ruleID else { return }
            self.preparingRuleID = nil
            self.recordingRuleID = ruleID
            guard self.tap.beginInputCapture({ [weak self] input in
                Task { @MainActor [weak self] in
                    guard let self, self.recordingRuleID == ruleID else { return }
                    self.recordingRuleID = nil
                    self.recordingError = nil
                    onCapture(input)
                }
            }) else {
                self.recordingRuleID = nil
                self.recordingError = InputRemappingRecordingError(
                    ruleID: ruleID,
                    target: .input,
                    failure: .eventTapUnavailable
                )
                onFailure()
                return
            }
        }
        return true
    }

    func cancel() {
        let hasActiveCapture = recordingRuleID != nil || recordingShortcutRuleID != nil
            || preparingRuleID != nil || preparingShortcutRuleID != nil
        recordingRuleID = nil
        recordingShortcutRuleID = nil
        preparingRuleID = nil
        preparingShortcutRuleID = nil
        recordingError = nil
        if hasActiveCapture {
            tap.cancelButtonCapture()
        }
    }

    func cancelFromEmergencyStop() {
        recordingRuleID = nil
        recordingShortcutRuleID = nil
        preparingRuleID = nil
        preparingShortcutRuleID = nil
        recordingError = nil
    }

    func startShortcut(
        ruleID: UUID,
        onCapture: @escaping @MainActor (ShortcutBinding) -> Void,
        onFailure: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        cancel()
        recordingError = nil
        guard tap.start() else {
            recordingError = InputRemappingRecordingError(
                ruleID: ruleID,
                target: .shortcut,
                failure: .eventTapUnavailable
            )
            onFailure()
            return false
        }
        preparingShortcutRuleID = ruleID
        scheduleArming { [weak self] in
            guard let self, self.preparingShortcutRuleID == ruleID else { return }
            self.preparingShortcutRuleID = nil
            self.recordingShortcutRuleID = ruleID
            guard self.tap.beginShortcutCapture({ [weak self] shortcut in
                Task { @MainActor [weak self] in
                    guard let self, self.recordingShortcutRuleID == ruleID else { return }
                    self.recordingShortcutRuleID = nil
                    self.recordingError = nil
                    onCapture(shortcut)
                }
            }) else {
                self.recordingShortcutRuleID = nil
                self.recordingError = InputRemappingRecordingError(
                    ruleID: ruleID,
                    target: .shortcut,
                    failure: .eventTapUnavailable
                )
                onFailure()
                return
            }
        }
        return true
    }

}

@MainActor
final class InputRemappingPlugin: MacToolsPlugin, AccessibilityPermissionRefreshing, PluginSettingsPresenting, PluginRuntimeLocalizationRefreshing, TrackpadGestureEventConsuming {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        let descriptor = rowDescriptor
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: descriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("widget.title", defaultValue: "快捷操作"),
                systemImage: metadata.iconName,
                control: .button,
                state: state,
                menuActionBehavior: descriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    private enum PermissionID {
        static let accessibility = "accessibility"
        static let inputMonitoring = "input-monitoring"
    }

    private enum SettingsID {
        static let rules = "rules"
    }

    private(set) var metadata: PluginMetadata
    let rowDescriptor: PluginPanelRowDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?
    var onTrackpadGestureClaimsChange: (() -> Void)?
    var requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)?

    let store: InputRemappingStore

    private let localization: PluginLocalization
    private let tap: any InputRemappingEventTapping
    private let buttonCapture: InputRemappingButtonCaptureCoordinator
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool
    private let inputMonitoringStatus: @MainActor () -> InputRemappingInputMonitoringStatus
    private let openURL: (URL) -> Void
    private let notificationCenter: NotificationCenter

    private var isAccessibilityGranted: Bool
    private var inputMonitoringState: InputRemappingInputMonitoringStatus
    private enum RuntimeError {
        case accessibilityRequired
        case inputMonitoringRequired
        case tapUnavailable
    }

    private var runtimeError: RuntimeError?

    private var errorMessage: String? {
        guard let runtimeError else { return nil }
        switch runtimeError {
        case .accessibilityRequired:
            return localization.string(
                "error.accessibilityRequired",
                defaultValue: "请先授予辅助功能权限以启用规则。"
            )
        case .inputMonitoringRequired:
            return localization.string(
                "error.inputMonitoringRequired",
                defaultValue: "请先授予输入监控权限以启用规则。"
            )
        case .tapUnavailable:
            return localization.string(
                "error.tapUnavailable",
                defaultValue: "无法启动输入监听，请检查权限后重试。"
            )
        }
    }
    private var applicationActivationObserver: NSObjectProtocol?
    private var ownedTrackpadGestures: Set<TrackpadGesture> = []

    init(
        context: PluginRuntimeContext,
        localization: PluginLocalization? = nil,
        tap: (any InputRemappingEventTapping)? = nil,
        buttonCapture: InputRemappingButtonCaptureCoordinator? = nil,
        accessibilityTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = { prompt in
            let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        },
        inputMonitoringStatus: @escaping @MainActor () -> InputRemappingInputMonitoringStatus = {
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted:
                .granted
            case kIOHIDAccessTypeDenied:
                .denied
            default:
                .unknown
            }
        },
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        notificationCenter: NotificationCenter = .default
    ) {
        let resolvedLocalization = localization ?? PluginLocalization(bundle: context.resourceBundle)
        self.localization = resolvedLocalization
        self.store = InputRemappingStore(storage: context.storage)
        self.tap = tap ?? InputRemappingEventTap()
        self.buttonCapture = buttonCapture ?? InputRemappingButtonCaptureCoordinator(tap: self.tap)
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.inputMonitoringStatus = inputMonitoringStatus
        self.openURL = openURL
        self.notificationCenter = notificationCenter
        self.isAccessibilityGranted = accessibilityTrusted()
        self.inputMonitoringState = inputMonitoringStatus()
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .keepPresented,
            buttonTitleProvider: {
                resolvedLocalization.string("panel.button.settings", defaultValue: "设置")
            }
        )
        self.metadata = Self.localizedMetadata(using: resolvedLocalization)

        self.tap.update(rules: store.rules)
        store.onRulesChange = { [weak self] in
            self?.applyConfiguration()
            self?.onTrackpadGestureClaimsChange?()
        }
        self.tap.emergencyStopHandler = { [weak self] in
            Task { @MainActor in
                self?.buttonCapture.cancelFromEmergencyStop()
                self?.store.disableUnsafeTriggers()
            }
        }
    }

    func activate(context: PluginRuntimeContext) {
        observeApplicationActivation()
        refreshPermissionState()
        applyConfiguration()
    }

    func refreshLocalization() {
        metadata = Self.localizedMetadata(using: localization)
        onStateChange?()
    }

    func deactivate(reason: PluginDeactivationReason) {
        buttonCapture.cancel()
        removeApplicationActivationObserver()
        tap.stop()
        onStateChange?()
    }

    private static func localizedMetadata(using localization: PluginLocalization) -> PluginMetadata {
        return PluginMetadata(
            id: "input-remapping",
            title: localization.string(
                "metadata.title",
                defaultValue: "Custom Shortcuts: Keyboard, Trackpad, Mouse"
            ),
            iconName: "arrow.left.arrow.right",
            iconTint: .purple,
            order: 57,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "Map inputs to actions"
            )
        )
    }

    func refresh() {
        refreshPermissionState()
        applyConfiguration()
        onStateChange?()
    }

    func refreshAccessibilityPermission() {
        refreshPermissionState()
        applyConfiguration()
    }

    var claimedTrackpadGestures: Set<TrackpadGesture> {
        Set(store.rules.compactMap(\.claimedTrackpadGesture))
    }

    func setOwnedTrackpadGestures(_ gestures: Set<TrackpadGesture>) {
        ownedTrackpadGestures = gestures
    }

    func receiveTrackpadGesture(_ gesture: TrackpadGesture, deviceID: UInt64) {
        guard isAccessibilityGranted,
              ownedTrackpadGestures.contains(gesture),
              let rule = store.rules.first(where: { $0.claimedTrackpadGesture == gesture })
        else { return }
        _ = tap.execute(rule.action)
    }

    var rowState: PluginPanelRowState {
        let enabledRuleCount = store.rules.filter(\.isRunnable).count
        let subtitle = enabledRuleCount == 0
            ? localization.string("panel.subtitle.noRules", defaultValue: "无规则")
            : localization.format(
                "panel.subtitle.activeRulesFormat",
                defaultValue: "%d 条活跃规则",
                enabledRuleCount
            )

        return PluginPanelRowState(
            subtitle: subtitle,
            isOn: enabledRuleCount > 0 && errorMessage == nil,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string(
                    "permission.accessibility.title",
                    defaultValue: "辅助功能"
                ),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于发送重映射后的鼠标点击和快捷键。"
                )
            ),
            PluginPermissionRequirement(
                id: PermissionID.inputMonitoring,
                kind: .inputMonitoring,
                title: localization.string(
                    "permission.inputMonitoring.title",
                    defaultValue: "输入监控"
                ),
                description: localization.string(
                    "permission.inputMonitoring.description",
                    defaultValue: "用于在系统范围内监听额外鼠标按键。所有处理均在本机完成。"
                )
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsPage: PluginSettingsPage? {
        .workspace(description: metadata.defaultDescription, scrolling: .host) { [weak self] _ in
            if let self {
                InputRemappingSettingsView(
                    store: self.store,
                    localization: self.localization,
                    buttonCapture: self.buttonCapture,
                    recordingPermissionGuidance: { self.recordingPermissionGuidance() },
                    requestRecordingPermission: { self.requestRecordingPermission($0) },
                    requestTrackpadGestureOwnership: self.requestTrackpadGestureOwnership,
                    isTrackpadGestureOwned: { self.ownedTrackpadGestures.contains($0) }
                )
            }
        }
        .onVisibilityChange { [weak self] visible in
            guard !visible else { return }
            self?.buttonCapture.cancel()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        if case .invokeAction = action {
            requestSettingsPresentation?()
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        switch permissionID {
        case PermissionID.accessibility:
            PluginPermissionState(
                isGranted: isAccessibilityGranted,
                footnote: isAccessibilityGranted ? nil : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "系统设置 → 隐私与安全性 → 辅助功能，允许 MacTools。"
                )
            )

        case PermissionID.inputMonitoring:
            PluginPermissionState(
                isGranted: isInputMonitoringGranted,
                footnote: isInputMonitoringGranted ? nil : localization.string(
                    "permission.inputMonitoring.footnote",
                    defaultValue: "系统设置 → 隐私与安全性 → 输入监控，允许 MacTools。"
                )
            )

        default:
            PluginPermissionState(isGranted: false, footnote: nil)
        }
    }

    func handlePermissionAction(id: String) {
        switch id {
        case PermissionID.accessibility:
            isAccessibilityGranted = requestAccessibilityTrust(true)
            refreshPermissionState()
            applyConfiguration()

        case PermissionID.inputMonitoring:
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            ) {
                openURL(url)
            }
            refreshPermissionState()
            applyConfiguration()

        default:
            return
        }
        onStateChange?()
    }

    func recordingPermissionGuidance() -> InputRemappingRecordingPermissionGuidance? {
        if !isAccessibilityGranted {
            return InputRemappingRecordingPermissionGuidance(
                issue: .accessibility,
                title: localization.string(
                    "permission.accessibility.title",
                    defaultValue: "Accessibility"
                ),
                detail: localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "System Settings → Privacy & Security → Accessibility: allow MacTools."
                )
            )
        }
        if inputMonitoringState == .denied {
            return InputRemappingRecordingPermissionGuidance(
                issue: .inputMonitoring,
                title: localization.string(
                    "permission.inputMonitoring.title",
                    defaultValue: "Input Monitoring"
                ),
                detail: localization.string(
                    "permission.inputMonitoring.footnote",
                    defaultValue: "System Settings → Privacy & Security → Input Monitoring: allow MacTools."
                )
            )
        }
        return nil
    }

    func requestRecordingPermission(_ issue: InputRemappingRecordingPermissionIssue) {
        handlePermissionAction(id: issue.permissionID)
    }

    private func refreshPermissionState() {
        isAccessibilityGranted = accessibilityTrusted()
        inputMonitoringState = inputMonitoringStatus()
    }

    private var isInputMonitoringGranted: Bool {
        inputMonitoringState == .granted
    }

    private func applyConfiguration() {
        tap.update(rules: store.rules)

        let runnableRules = store.rules.filter(\.isRunnable)
        guard !runnableRules.isEmpty else {
            if !tap.isCaptureSequenceActive {
                tap.stop()
            }
            runtimeError = nil
            onStateChange?()
            return
        }

        guard isAccessibilityGranted else {
            tap.stop()
            runtimeError = .accessibilityRequired
            onStateChange?()
            return
        }

        guard runnableRules.contains(where: \.requiresEventTap) else {
            if !tap.isCaptureSequenceActive {
                tap.stop()
            }
            runtimeError = nil
            onStateChange?()
            return
        }

        guard isInputMonitoringGranted else {
            tap.stop()
            runtimeError = .inputMonitoringRequired
            onStateChange?()
            return
        }

        if tap.start() {
            runtimeError = nil
        } else {
            runtimeError = .tapUnavailable
        }
        onStateChange?()
    }

    private func observeApplicationActivation() {
        guard applicationActivationObserver == nil else { return }
        applicationActivationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPermissionState()
                self.applyConfiguration()
            }
        }
    }

    private func removeApplicationActivationObserver() {
        guard let applicationActivationObserver else { return }
        notificationCenter.removeObserver(applicationActivationObserver)
        self.applicationActivationObserver = nil
    }
}

private struct InputRemappingSettingsView: View {

    @ObservedObject var store: InputRemappingStore
    let localization: PluginLocalization
    @ObservedObject var buttonCapture: InputRemappingButtonCaptureCoordinator
    let recordingPermissionGuidance: () -> InputRemappingRecordingPermissionGuidance?
    let requestRecordingPermission: (InputRemappingRecordingPermissionIssue) -> Void
    let requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)?
    let isTrackpadGestureOwned: (TrackpadGesture) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            HStack {
                Spacer()
                Button {
                    store.addRule()
                } label: {
                    Label(
                        localization.string("settings.addRule", defaultValue: "Add Mapping"),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if store.rules.isEmpty {
                VStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Image(systemName: "arrow.up.right.circle")
                        .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(localization.string("settings.empty.title", defaultValue: "Create your first mapping"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(
                        localization.string(
                            "settings.empty",
                            defaultValue: "Click Add Mapping above, then record an input and choose what it runs."
                        )
                    )
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
                .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
            } else {
                ForEach(store.rules) { rule in
                    InputRemappingRuleEditor(
                        rule: rule,
                        store: store,
                        localization: localization,
                        buttonCapture: buttonCapture,
                        recordingPermissionGuidance: recordingPermissionGuidance,
                        requestRecordingPermission: requestRecordingPermission,
                        requestTrackpadGestureOwnership: requestTrackpadGestureOwnership,
                        isTrackpadGestureOwned: isTrackpadGestureOwned
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }
}

private enum InputRemappingInputKind: String, CaseIterable, Identifiable {
    case keyboard
    case mouse
    case trackpad
    case scroll

    var id: Self { self }
    var symbolName: String {
        switch self {
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "hand.tap"
        case .scroll: "scroll"
        }
    }
}

private enum InputRemappingEditorLayout {
    static let inputControlWidth: CGFloat = 220
}

struct InputRemappingOutputRecordingSnapshot: Equatable {
    let action: InputRemappingRule.Action
    let outputConfigurationState: InputRemappingOutputConfigurationState
    let isEnabled: Bool

    init(rule: InputRemappingRule) {
        action = rule.action
        outputConfigurationState = rule.outputConfigurationState
        isEnabled = rule.isEnabled
    }

    func restore(_ rule: inout InputRemappingRule) {
        rule.action = action
        rule.outputConfigurationState = outputConfigurationState
        rule.isEnabled = isEnabled
    }
}

struct InputRemappingInputRecordingSnapshot: Equatable {
    let trigger: InputRemappingTrigger
    let isInputConfigured: Bool
    let isUnsafeTriggerConfirmed: Bool
    let isEnabled: Bool

    init(rule: InputRemappingRule) {
        trigger = rule.trigger
        isInputConfigured = rule.isInputConfigured
        isUnsafeTriggerConfirmed = rule.isUnsafeTriggerConfirmed
        isEnabled = rule.isEnabled
    }

    func restore(_ rule: inout InputRemappingRule) {
        rule.trigger = trigger
        rule.isInputConfigured = isInputConfigured
        rule.isUnsafeTriggerConfirmed = isUnsafeTriggerConfirmed
        rule.isEnabled = isEnabled
    }
}

@MainActor
func shouldShowShortcutRecordingControl(
    for rule: InputRemappingRule,
    buttonCapture: InputRemappingButtonCaptureCoordinator
) -> Bool {
    rule.outputConfigurationState == .recordingShortcut ||
        (rule.isOutputConfigured && rule.action.kind == .shortcut) ||
        buttonCapture.preparingShortcutRuleID == rule.id ||
        buttonCapture.recordingShortcutRuleID == rule.id
}

private struct InputRemappingRuleEditor: View {
    let rule: InputRemappingRule
    @ObservedObject var store: InputRemappingStore
    let localization: PluginLocalization
    @ObservedObject var buttonCapture: InputRemappingButtonCaptureCoordinator
    let recordingPermissionGuidance: () -> InputRemappingRecordingPermissionGuidance?
    let requestRecordingPermission: (InputRemappingRecordingPermissionIssue) -> Void
    let requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)?
    let isTrackpadGestureOwned: (TrackpadGesture) -> Bool

    @State private var draft: InputRemappingRule
    @State private var requiresSafetyConfirmation = false
    @State private var outputRecordingSnapshot: InputRemappingOutputRecordingSnapshot?
    @State private var inputRecordingSnapshot: InputRemappingInputRecordingSnapshot?

    init(
        rule: InputRemappingRule,
        store: InputRemappingStore,
        localization: PluginLocalization,
        buttonCapture: InputRemappingButtonCaptureCoordinator,
        recordingPermissionGuidance: @escaping () -> InputRemappingRecordingPermissionGuidance? = { nil },
        requestRecordingPermission: @escaping (InputRemappingRecordingPermissionIssue) -> Void = { _ in },
        requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)? = nil,
        isTrackpadGestureOwned: @escaping (TrackpadGesture) -> Bool = { _ in true }
    ) {
        self.rule = rule
        self.store = store
        self.localization = localization
        self.buttonCapture = buttonCapture
        self.recordingPermissionGuidance = recordingPermissionGuidance
        self.requestRecordingPermission = requestRecordingPermission
        self.requestTrackpadGestureOwnership = requestTrackpadGestureOwnership
        self.isTrackpadGestureOwned = isTrackpadGestureOwned
        _draft = State(initialValue: rule)
        _outputRecordingSnapshot = State(initialValue: nil)
        _inputRecordingSnapshot = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                inputColumn
                flowArrow
                outputColumn
                flowArrow
                contextColumn
            }

            Divider()

            InputRemappingRuleFooter(
                isEnabled: enabledBinding,
                enabledTitle: localization.string("settings.enabled", defaultValue: "Enabled"),
                deleteTitle: localization.string("settings.deleteMapping", defaultValue: "Delete mapping"),
                onDelete: deleteRule
            )
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .pluginSettingsCardBackground(.standard)
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .alert(
            localization.string("settings.keyboard.confirmation.title", defaultValue: "Enable this trigger?"),
            isPresented: $requiresSafetyConfirmation
        ) {
            Button(localization.string("settings.keyboard.confirmation.enable", defaultValue: "Enable")) {
                draft.isUnsafeTriggerConfirmed = true
                draft.isEnabled = true
                save()
            }
            Button(localization.string("settings.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(localization.string("settings.keyboard.confirmation.message", defaultValue: "This rule intercepts input system-wide. Press ⌃⌥⌘Esc at any time to disable unsafe shortcuts."))
        }
    }

    private var inputColumn: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text(localization.string("settings.mapping.when", defaultValue: "When I press"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            if buttonCapture.preparingRuleID == rule.id || buttonCapture.recordingRuleID == rule.id {
                inputCaptureControl
            } else if !draft.isInputConfigured {
                Button(localization.string("settings.input.record", defaultValue: "Record input")) {
                    startInputCapture()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                inputKindMenu
            }

            if draft.isInputConfigured {
                if inputKind == .trackpad {
                    Picker(localization.string("settings.trackpadGesture", defaultValue: "Trackpad gesture"), selection: trackpadGestureBinding) {
                        ForEach(TrackpadGesture.configurableCases) { gesture in
                            Text(trackpadGestureTitle(gesture)).tag(Optional(gesture))
                        }
                    }
                    .labelsHidden()
                }

                if case .mouseButton = draft.trigger {
                    Menu {
                        ForEach(InputRemappingMouseInteraction.allCases, id: \.self) { interaction in
                            Button(mouseInteractionTitle(interaction)) { mouseInteractionBinding.wrappedValue = interaction }
                        }
                    } label: {
                        mappingMenuLabel(
                            mouseInteractionTitle(draft.mouseInteraction),
                            systemImage: "cursorarrow",
                            width: InputRemappingEditorLayout.inputControlWidth
                        )
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let gesture = rule.claimedTrackpadGesture, !isTrackpadGestureOwned(gesture) {
                Text(localization.string(
                    "settings.mapping.usedByAnotherPlugin",
                    defaultValue: "This gesture is already used by another plugin."
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let recordingError = recordingError(for: .input) {
                recordingFailureView(recordingError, retry: startInputCapture)
            }
        }
        .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
    }

    private var outputColumn: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text(localization.string("settings.mapping.run", defaultValue: "Run"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            actionMenu

            if shouldShowShortcutRecordingControl(for: draft, buttonCapture: buttonCapture) {
                shortcutRecordingControl
            }
            if draft.outputConfigurationState == .recordingKeyTap ||
                (draft.isOutputConfigured && draft.action.kind == .keyTap) {
                keyTapSelectionControl
            }

            if let recordingError = recordingError(for: .shortcut) {
                recordingFailureView(recordingError, retry: startShortcutCapture)
            }
        }
        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
    }

    private var contextColumn: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text(localization.string("settings.mapping.where", defaultValue: "Where"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            Menu {
                Button(localization.string("settings.context.global", defaultValue: "Everywhere")) {}
                    .disabled(true)
            } label: {
                mappingMenuLabel(localization.string("settings.context.global", defaultValue: "Everywhere"), systemImage: "globe")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)

            if case let .keyboard(_, modifiers) = draft.trigger, modifiers.isEmpty {
                Text(localization.string("settings.keyboard.warning", defaultValue: "A key without modifiers overrides normal typing while the rule is enabled."))
                    .foregroundStyle(.orange)
            }
            if case .mouseButton = draft.trigger, draft.mouseInteraction != .click {
                Text(localization.string("settings.mouseInteraction.warning", defaultValue: "Double-click and long-press keep the original click available to avoid delaying or replaying input."))
                    .foregroundStyle(.secondary)
            }

        }
        .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
    }

    private var flowArrow: some View {
        Image(systemName: "arrow.forward")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .padding(.top, 31)
            .accessibilityHidden(true)
    }

    private var inputKindMenu: some View {
        Menu {
            Button {
                startInputCapture()
            } label: {
                Label(localization.string("settings.input.record", defaultValue: "Record input"), systemImage: "record.circle")
            }
            Divider()
            ForEach(InputRemappingInputKind.allCases) { kind in
                Button(inputKindTitle(kind)) { inputKindBinding.wrappedValue = kind }
            }
        } label: {
            mappingMenuLabel(
                triggerTitle,
                systemImage: inputKind.symbolName,
                width: InputRemappingEditorLayout.inputControlWidth
            )
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var actionMenu: some View {
        Menu {
            ForEach(InputRemappingRule.Action.Kind.allCases, id: \.self) { kind in
                Button(InputRemappingRule.Action.action(for: kind).kindTitle(localization: localization)) {
                    actionBinding.wrappedValue = kind
                }
            }
        } label: {
            mappingMenuLabel(
                actionTitle,
                systemImage: draft.outputConfigurationState == .needsSelection
                    || draft.action.kind == .shortcut
                    || draft.action.kind == .keyTap ? nil : actionSymbolName
            )
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    private func mappingMenuLabel(
        _ title: String,
        systemImage: String?,
        width: CGFloat? = nil
    ) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(PluginSettingsTheme.Typography.rowTitle)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var actionTitle: String {
        guard draft.outputConfigurationState != .needsSelection else {
            return localization.string("settings.action.choose", defaultValue: "Choose something to run")
        }
        return switch draft.action {
        case let .shortcut(shortcut): shortcutTitle(shortcut)
        case let .keyTap(keyTap): KeyboardKeyTapFormatter.displayString(for: keyTap)
        default: draft.action.title(localization: localization)
        }
    }

    private var actionSymbolName: String {
        switch draft.action {
        case .shortcut: "command"
        case .keyTap: "keyboard.badge.ellipsis"
        case .mouseBack: "arrow.left"
        case .mouseForward: "arrow.right"
        case .mouseMiddle: "computermouse"
        case .missionControl: "rectangle.3.group"
        case .spaceLeft: "arrow.left.to.line"
        case .spaceRight: "arrow.right.to.line"
        case .mediaPlayPause: "playpause"
        case .volumeDown: "speaker.wave.1"
        case .volumeUp: "speaker.wave.3"
        }
    }

    private func shortcutTitle(_ shortcut: ShortcutBinding) -> String {
        localization.format(
            "settings.shortcut.current",
            defaultValue: "%@%d",
            shortcut.modifiers.symbolString,
            shortcut.keyCode
        )
    }

    private var actionBinding: Binding<InputRemappingRule.Action.Kind> {
        Binding(
            get: { draft.action.kind },
            set: { kind in
                cancelRecording()
                if kind == .shortcut || kind == .keyTap {
                    outputRecordingSnapshot = InputRemappingOutputRecordingSnapshot(rule: draft)
                }
                draft.action = draft.action.replacingKind(kind)
                draft.outputConfigurationState = switch kind {
                case .shortcut: .recordingShortcut
                case .keyTap: .recordingKeyTap
                default: .configured
                }
                enableIfComplete()
                save()
            }
        )
    }

    private var inputKind: InputRemappingInputKind {
        switch draft.trigger {
        case .keyboard: .keyboard
        case .mouseButton: .mouse
        case .trackpadGesture: .trackpad
        case .scroll: .scroll
        }
    }

    private var inputKindBinding: Binding<InputRemappingInputKind> {
        Binding(
            get: { inputKind },
            set: { kind in
                cancelRecording()
                switch kind {
                case .keyboard:
                    draft.replaceTrigger(.keyboard(keyCode: 0, modifiers: []))
                case .mouse:
                    draft.replaceTrigger(.mouseButton(number: 0, modifiers: [], interaction: .click))
                case .trackpad:
                    let gesture = TrackpadGesture.threeFingerTap
                    draft.replaceTrigger(.trackpadGesture(gesture))
                case .scroll:
                    draft.replaceTrigger(.scroll(direction: .up, modifiers: []))
                }
                draft.isInputConfigured = true
                save()
            }
        )
    }

    private func inputKindTitle(_ kind: InputRemappingInputKind) -> String {
        switch kind {
        case .keyboard: localization.string("settings.input.kind.keyboard", defaultValue: "Keyboard")
        case .mouse: localization.string("settings.input.kind.mouse", defaultValue: "Mouse")
        case .trackpad: localization.string("settings.input.kind.trackpad", defaultValue: "Trackpad")
        case .scroll: localization.string("settings.input.kind.scroll", defaultValue: "Scroll")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { draft.isEnabled },
            set: { enabled in
                guard !enabled || (draft.isInputConfigured && draft.isOutputConfigured) else { return }
                guard enabled, InputRemappingRule.requiresExplicitConfirmation(for: draft.trigger) else {
                    draft.isEnabled = enabled
                    save()
                    return
                }
                requiresSafetyConfirmation = true
            }
        )
    }

    @ViewBuilder
    private var inputCaptureControl: some View {
        if buttonCapture.preparingRuleID == rule.id {
            captureStatus(
                title: localization.string("settings.input.preparing", defaultValue: "Preparing recording…"),
                detail: localization.string("settings.input.preparing.detail", defaultValue: "Release the Record Input button; listening starts next."),
                isPreparing: true
            )
        } else if buttonCapture.recordingRuleID == rule.id {
            captureStatus(
                title: localization.string("settings.input.recording", defaultValue: "Listening for an input"),
                detail: localization.string("settings.input.recording.detail", defaultValue: "Press a key, mouse button, or scroll once."),
                isPreparing: false
            )
        } else {
            EmptyView()
        }
    }

    private func startInputCapture() {
        cancelRecording()
        inputRecordingSnapshot = InputRemappingInputRecordingSnapshot(rule: draft)
        _ = buttonCapture.start(ruleID: rule.id, onCapture: { input in
            inputRecordingSnapshot = nil
            draft.replaceTrigger(input.trigger(interaction: draft.mouseInteraction))
            draft.isInputConfigured = true
            enableIfComplete()
            save()
        }, onFailure: restoreInputRecordingAfterFailure)
    }

    private func startShortcutCapture() {
        beginOutputRecordingIfNeeded()
        _ = buttonCapture.startShortcut(ruleID: rule.id, onCapture: { binding in
            outputRecordingSnapshot = nil
            draft.action = .shortcut(binding)
            draft.outputConfigurationState = .configured
            enableIfComplete()
            save()
        }, onFailure: restoreOutputRecordingAfterFailure)
    }

    @ViewBuilder
    private var shortcutRecordingControl: some View {
        if buttonCapture.preparingShortcutRuleID == rule.id {
            Label(localization.string("settings.shortcut.preparing", defaultValue: "Preparing shortcut recording…"), systemImage: "hourglass")
                .foregroundStyle(.tint)
            Text(localization.string("settings.shortcut.preparing.detail", defaultValue: "Release the Record Shortcut button; listening starts next."))
                .foregroundStyle(.secondary)
            Button(localization.string("settings.cancel", defaultValue: "Cancel")) {
                cancelOutputRecording()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if buttonCapture.recordingShortcutRuleID == rule.id {
            Label(localization.string("settings.shortcut.recording", defaultValue: "Press the shortcut"), systemImage: "record.circle")
                .foregroundStyle(.tint)
            Button(localization.string("settings.cancel", defaultValue: "Cancel")) {
                cancelOutputRecording()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button {
                startShortcutCapture()
            } label: {
                Text(localization.string("settings.shortcut.record", defaultValue: "Record shortcut"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var keyTapSelectionControl: some View {
        PluginKeyTapPicker(
            title: localization.string("action.singleKey", defaultValue: "Single Key"),
            selection: Binding(
                get: {
                    guard case let .keyTap(keyTap) = draft.action,
                          draft.outputConfigurationState == .configured
                    else { return nil }
                    return keyTap
                },
                set: { keyTap in
                    buttonCapture.cancel()
                    guard let keyTap else {
                        draft.outputConfigurationState = .recordingKeyTap
                        draft.isEnabled = false
                        save()
                        return
                    }
                    outputRecordingSnapshot = nil
                    draft.action = .keyTap(keyTap)
                    draft.outputConfigurationState = .configured
                    enableIfComplete()
                    save()
                }
            ),
            minWidth: InputRemappingEditorLayout.inputControlWidth
        )
    }

    private func enableIfComplete() {
        guard draft.isInputConfigured, draft.isOutputConfigured else {
            draft.isEnabled = false
            return
        }
        draft.isEnabled = !InputRemappingRule.requiresExplicitConfirmation(for: draft.trigger)
    }

    private func recordingError(for target: InputRemappingRecordingTarget) -> InputRemappingRecordingError? {
        guard let recordingError = buttonCapture.recordingError,
              recordingError.ruleID == rule.id,
              recordingError.target == target
        else {
            return nil
        }
        return recordingError
    }

    private func recordingFailureView(
        _ error: InputRemappingRecordingError,
        retry: @escaping () -> Void
    ) -> some View {
        let errorTitle = switch error.failure {
        case .eventTapUnavailable:
            localization.string(
                "settings.recording.error",
                defaultValue: "Recording could not start."
            )
        }
        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Label(
                errorTitle,
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.red)

            if let guidance = recordingPermissionGuidance() {
                Text(guidance.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Button(
                        localization.format(
                            "settings.recording.openFormat",
                            defaultValue: "Open %@",
                            guidance.title
                        )
                    ) {
                        requestRecordingPermission(guidance.issue)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    retryButton(retry: retry)
                }
            } else {
                Text(
                    localization.string(
                        "settings.recording.unavailable",
                        defaultValue: "Input capture is unavailable right now. Try again."
                    )
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                retryButton(retry: retry)
            }
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
    }

    private func retryButton(retry: @escaping () -> Void) -> some View {
        Button(localization.string("settings.recording.retry", defaultValue: "Try again"), action: retry)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
    }

    private func beginOutputRecordingIfNeeded() {
        guard outputRecordingSnapshot == nil else { return }
        outputRecordingSnapshot = InputRemappingOutputRecordingSnapshot(rule: draft)
    }

    private func restoreOutputRecordingAfterFailure() {
        guard let outputRecordingSnapshot else { return }
        outputRecordingSnapshot.restore(&draft)
        self.outputRecordingSnapshot = nil
        save()
    }

    private func restoreInputRecordingAfterFailure() {
        guard let inputRecordingSnapshot else { return }
        inputRecordingSnapshot.restore(&draft)
        self.inputRecordingSnapshot = nil
        save()
    }

    private func cancelRecording() {
        buttonCapture.cancel()
        outputRecordingSnapshot?.restore(&draft)
        outputRecordingSnapshot = nil
        inputRecordingSnapshot?.restore(&draft)
        inputRecordingSnapshot = nil
    }

    private func cancelOutputRecording() {
        let hadOutputRecordingSnapshot = outputRecordingSnapshot != nil
        cancelRecording()
        if !hadOutputRecordingSnapshot {
            draft.outputConfigurationState = .needsSelection
            draft.isEnabled = false
        }
        save()
    }

    private func captureStatus(title: String, detail: String, isPreparing: Bool) -> some View {
        InputRemappingCaptureStatus(
            title: title,
            detail: detail,
            isPreparing: isPreparing,
            cancelTitle: localization.string("settings.cancel", defaultValue: "Cancel"),
            onCancel: cancelRecording
        )
    }

    private var mouseInteractionBinding: Binding<InputRemappingMouseInteraction> {
        Binding(
            get: { draft.mouseInteraction },
            set: { interaction in
                cancelRecording()
                draft.mouseInteraction = interaction
                save()
            }
        )
    }

    private var trackpadGestureBinding: Binding<TrackpadGesture?> {
        Binding(
            get: { if case let .trackpadGesture(gesture) = draft.trigger { gesture } else { nil } },
            set: { gesture in
                guard let gesture else { return }
                cancelRecording()
                draft.replaceTrigger(.trackpadGesture(gesture))
                save()
            }
        )
    }

    private var triggerTitle: String {
        switch draft.trigger {
        case let .keyboard(keyCode, modifiers):
            return localization.format("settings.trigger.keyboard.format", defaultValue: "Key %@%d", modifiers.symbolString, keyCode)
        case let .mouseButton(number, modifiers, _):
            return localization.format("settings.trigger.mouse.format", defaultValue: "Mouse button %@%d", modifiers.symbolString, number)
        case let .scroll(direction, modifiers):
            return localization.format("settings.trigger.scroll.format", defaultValue: "Scroll %@%@", modifiers.symbolString, scrollTitle(direction))
        case let .trackpadGesture(gesture):
            return localization.format("settings.trigger.trackpad.format", defaultValue: "Trackpad %@", trackpadGestureTitle(gesture))
        }
    }

    private func trackpadGestureTitle(_ gesture: TrackpadGesture) -> String {
        localization.string(
            "settings.trackpadGesture.\(gesture.rawValue)",
            defaultValue: gesture.displayTitle
        )
    }

    private func mouseInteractionTitle(_ interaction: InputRemappingMouseInteraction) -> String {
        switch interaction {
        case .click: localization.string("settings.mouseInteraction.click", defaultValue: "Click")
        case .doubleClick: localization.string("settings.mouseInteraction.doubleClick", defaultValue: "Double-click")
        case .longPress: localization.string("settings.mouseInteraction.longPress", defaultValue: "Long press")
        }
    }

    private func scrollTitle(_ direction: InputRemappingScrollDirection) -> String {
        switch direction {
        case .up: localization.string("settings.scroll.up", defaultValue: "up")
        case .down: localization.string("settings.scroll.down", defaultValue: "down")
        case .left: localization.string("settings.scroll.left", defaultValue: "left")
        case .right: localization.string("settings.scroll.right", defaultValue: "right")
        }
    }

    private func deleteRule() {
        cancelRecording()
        store.delete(rule)
    }

    private func save() {
        store.replace(draft)
        if let gesture = draft.claimedTrackpadGesture {
            requestTrackpadGestureOwnership?(gesture)
        }
    }
}

private struct InputRemappingRuleFooter: View {
    @Binding var isEnabled: Bool
    let enabledTitle: String
    let deleteTitle: String
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Text(enabledTitle)
                .foregroundStyle(.secondary)
            DualClickToggle(isOn: $isEnabled)
                .accessibilityLabel(enabledTitle)
            DualClickIconButton(
                systemImage: "trash",
                accessibilityLabel: deleteTitle,
                action: onDelete
            )
        }
    }
}

private struct InputRemappingCaptureStatus: View {
    let title: String
    let detail: String
    let isPreparing: Bool
    let cancelTitle: String
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Label(title, systemImage: isPreparing ? "hourglass" : "record.circle")
                .font(PluginSettingsTheme.Typography.rowTitle)
                .foregroundStyle(.tint)
            Text(detail)
                .foregroundStyle(.secondary)
            Button(cancelTitle, action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

private struct DualClickToggle: NSViewRepresentable {
    @Binding var isOn: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isOn: $isOn)
    }

    func makeNSView(context: Context) -> DualClickSwitch {
        let control = DualClickSwitch()
        control.controlSize = .small
        control.target = context.coordinator
        control.action = #selector(Coordinator.didToggle(_:))
        return control
    }

    func updateNSView(_ control: DualClickSwitch, context: Context) {
        control.state = isOn ? .on : .off
    }

    @MainActor
    final class Coordinator: NSObject {
        private var isOn: Binding<Bool>

        init(isOn: Binding<Bool>) {
            self.isOn = isOn
        }

        @objc func didToggle(_ sender: NSSwitch) {
            isOn.wrappedValue = sender.state == .on
        }
    }
}

private final class DualClickSwitch: NSSwitch {
    override func rightMouseDown(with event: NSEvent) {
        state = state == .on ? .off : .on
        sendAction(action, to: target)
    }
}

private struct DualClickIconButton: NSViewRepresentable {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> DualClickButton {
        let button = DualClickButton()
        button.isBordered = false
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: accessibilityLabel)
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.target = context.coordinator
        button.action = #selector(Coordinator.didPress(_:))
        return button
    }

    func updateNSView(_ button: DualClickButton, context: Context) {
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: accessibilityLabel)
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
    }

    @MainActor
    final class Coordinator: NSObject {
        private let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func didPress(_ sender: NSButton) {
            action()
        }
    }
}

private final class DualClickButton: NSButton {
    override func rightMouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}
