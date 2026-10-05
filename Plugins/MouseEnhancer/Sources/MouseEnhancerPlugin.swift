import AppKit
import Foundation
@preconcurrency import IOKit.hid
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class MouseEnhancerPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        MouseEnhancerPluginProvider(context: context)
    }
}

@MainActor
private struct MouseEnhancerPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            MouseEnhancerPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

enum MouseEnhancerInputMonitoringAuthorizationStatus {
    case granted
    case denied
    case unknown
}

enum MouseEnhancerHostCompatibility {
    static let featureExtractionHostVersion = "1.2.0"

    static func ownsLegacyMiddleClick(hostVersion: String?) -> Bool {
        guard let hostVersion else { return false }
        return compare(hostVersion, featureExtractionHostVersion) == .orderedAscending
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map(numericPrefix)
        let right = rhs.split(separator: ".").map(numericPrefix)
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart < rightPart { return .orderedAscending }
            if leftPart > rightPart { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericPrefix(_ component: Substring) -> Int {
        Int(component.prefix(while: \.isNumber)) ?? 0
    }
}

@MainActor
final class MouseEnhancerPlugin:
    MacToolsPlugin, AccessibilityPermissionRefreshing, PluginApplicationActivityStateHandling, DisplayTopologyRefreshing, PluginSettingsPresenting {
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

    private enum PermissionID {
        static let accessibility = "accessibility"
        static let inputMonitoring = "input-monitoring"
    }

    private enum SettingsID {
        static let mouseVertical = "mouse-vertical"
        static let mouseHorizontal = "mouse-horizontal"
        static let trackpadVertical = "trackpad-vertical"
        static let trackpadHorizontal = "trackpad-horizontal"
        static let middleClick = "middle-click"
        static let middleClickFingerCount = "middle-click-finger-count"
        static let mouseSmoothScrolling = "mouse-smooth-scrolling"
        static let mouseScrollDuration = "mouse-scroll-duration"
        static let mouseScrollStep = "mouse-scroll-step"
        static let mouseScrollGain = "mouse-scroll-gain"
        static let trackpadScrollStep = "trackpad-scroll-step"
        static let trackpadScrollGain = "trackpad-scroll-gain"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "mouse-enhancer",
            title: localization.string("metadata.title", defaultValue: "鼠标增强"),
            iconName: "computermouse",
            iconTint: Color(nsColor: .systemTeal),
            order: 56,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "分别调整鼠标与触控板的滚动方向"
            )
        )
    }
    let rowDescriptor: PluginPanelRowDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    let store: MouseEnhancerStore

    private let localization: PluginLocalization
    private let session: any MouseEnhancerSessionManaging
    private let makeMiddleClickSession: @MainActor () -> any MouseEnhancerMiddleClickSessionManaging
    private let ownsLegacyMiddleClick: Bool
    private var middleClickSession: (any MouseEnhancerMiddleClickSessionManaging)?
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool
    private let inputMonitoringAuthorizationStatus: @MainActor () -> MouseEnhancerInputMonitoringAuthorizationStatus
    private let openURL: (URL) -> Void
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "MouseEnhancerPlugin"
    )

    private var isAccessibilityGranted: Bool
    private enum RuntimeError {
        case accessibilityRevoked
        case accessibilityRequired
        case tapUnavailable
    }

    private var runtimeError: RuntimeError?

    private var lastErrorMessage: String? {
        guard let runtimeError else { return nil }
        switch runtimeError {
        case .accessibilityRevoked:
            return localization.string(
                "error.accessibilityRevoked",
                defaultValue: "辅助功能权限已关闭，鼠标增强已暂停。"
            )
        case .accessibilityRequired:
            return localization.string(
                "error.accessibilityRequired",
                defaultValue: "鼠标增强需要辅助功能权限，请先前往设置完成授权。"
            )
        case .tapUnavailable:
            return localization.string(
                "error.tapUnavailable",
                defaultValue: "无法启动滚动事件监听，请确认辅助功能授权后重试。"
            )
        }
    }
    private var applicationActivityState: PluginApplicationActivityState = .interactive

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "mouse-enhancer"),
        session: (any MouseEnhancerSessionManaging)? = nil,
        makeMiddleClickSession: @escaping @MainActor () -> any MouseEnhancerMiddleClickSessionManaging = {
            MouseEnhancerMiddleClickSession()
        },
        hostVersion: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        accessibilityTrusted: @escaping @MainActor () -> Bool = MouseEnhancerAccessibilityCheck.isTrusted,
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = MouseEnhancerAccessibilityCheck.requestTrust(prompt:),
        inputMonitoringAuthorizationStatus: @escaping @MainActor () -> MouseEnhancerInputMonitoringAuthorizationStatus = MouseEnhancerPlugin.currentInputMonitoringAuthorizationStatus,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.localization = localization
        self.store = MouseEnhancerStore(storage: context.storage)
        self.session = session ?? MouseEnhancerSession()
        self.makeMiddleClickSession = makeMiddleClickSession
        self.ownsLegacyMiddleClick = MouseEnhancerHostCompatibility.ownsLegacyMiddleClick(
            hostVersion: hostVersion
        )
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.inputMonitoringAuthorizationStatus = inputMonitoringAuthorizationStatus
        self.openURL = openURL
        self.isAccessibilityGranted = accessibilityTrusted()
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .keepPresented,
            buttonTitleProvider: { localization.string("panel.button.settings", defaultValue: "设置") }
        )
    }

    func activate(context: PluginRuntimeContext) {
        refreshAccessibilityPermission()
        applyCurrentConfiguration()
        applyMiddleClickConfiguration()
    }

    func deactivate(reason: PluginDeactivationReason) {
        guard reason.requiresStateCleanup else {
            return
        }

        session.deactivate()
        stopMiddleClickSession()
        onStateChange?()
    }

    func refresh() {
        refreshAccessibilityPermission()
        applyCurrentConfiguration()
        applyMiddleClickConfiguration()
        onStateChange?()
    }

    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        let wasInteractive = applicationActivityState == .interactive
        let isInteractive = state == .interactive
        applicationActivityState = state

        guard wasInteractive != isInteractive else { return }
        if isInteractive {
            session.inputActivityDidBecomeAvailable()
        } else {
            session.inputActivityDidBecomeUnavailable()
        }
    }

    func refreshDisplayTopology() {
        session.displayTopologyDidChange()
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于监听和调整滚动事件。"
                )
            ),
            PluginPermissionRequirement(
                id: PermissionID.inputMonitoring,
                kind: .inputMonitoring,
                title: localization.string("permission.inputMonitoring.title", defaultValue: "输入监控"),
                description: localization.string(
                    "permission.inputMonitoring.description",
                    defaultValue: "用于区分鼠标滚轮和触控板手势。"
                )
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsPage: PluginSettingsPage? {
        var trackpadRows = [
            toggleRow(
                id: SettingsID.trackpadVertical,
                title: localization.string("settings.trackpad.vertical.title", defaultValue: "垂直反转"),
                description: localization.string("settings.trackpad.vertical.description", defaultValue: "反转触控板和 Magic Mouse 上下滚动方向。"),
                icon: "arrow.up.and.down",
                isOn: store.configuration.reverseTrackpadVertical
            ),
            toggleRow(
                id: SettingsID.trackpadHorizontal,
                title: localization.string("settings.trackpad.horizontal.title", defaultValue: "水平反转"),
                description: localization.string("settings.trackpad.horizontal.description", defaultValue: "反转触控板和 Magic Mouse 左右滚动方向。"),
                icon: "arrow.left.and.right",
                isOn: store.configuration.reverseTrackpadHorizontal
            ),
            scrollStepRow(
                id: SettingsID.trackpadScrollStep,
                title: localization.string("settings.trackpad.scrollStep.title", defaultValue: "滚动步长"),
                description: localization.string(
                    "settings.trackpad.scrollStep.description",
                    defaultValue: "触控板每次滚动的最短距离，过小的滚动会被补足到该步长，0 为不调整。"
                ),
                value: store.configuration.trackpadScrollStep
            ),
            scrollGainRow(
                id: SettingsID.trackpadScrollGain,
                title: localization.string("settings.trackpad.scrollGain.title", defaultValue: "滚动速度"),
                description: localization.string(
                    "settings.trackpad.scrollGain.description",
                    defaultValue: "触控板滚动距离的增益倍数，1.0× 为不调整。"
                ),
                value: store.configuration.trackpadScrollGain
            )
        ]
        if ownsLegacyMiddleClick {
            trackpadRows.append(
                toggleRow(
                    id: SettingsID.middleClick,
                    title: localization.string("settings.middleClick.title", defaultValue: "模拟鼠标中键"),
                    description: localization.string("settings.middleClick.description", defaultValue: "触控板轻点模拟鼠标中键点击。"),
                    icon: "hand.tap",
                    isOn: store.configuration.middleClickEnabled
                )
            )
            trackpadRows.append(
                PluginSettingsRow(
                    id: SettingsID.middleClickFingerCount,
                    title: localization.string("settings.middleClick.fingerCount.title", defaultValue: "手指数量"),
                    description: localization.string(
                        "settings.middleClick.fingerCount.description",
                        defaultValue: "用指定数量的手指在触控板上轻点，将模拟鼠标中键点击。"
                    ),
                    systemImage: "hand.raised",
                    isEnabled: store.configuration.middleClickEnabled,
                    isVisible: store.configuration.middleClickEnabled,
                    control: .picker(
                        selectionID: String(store.configuration.middleClickFingerCount),
                        options: [3, 4, 5].map {
                            PluginSettingsOption(id: String($0), title: "\($0)")
                        },
                        style: .segmented
                    )
                )
            )
        }

        return .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "mouse",
                    title: localization.string("settings.mouse.sectionTitle", defaultValue: "鼠标"),
                    systemImage: "computermouse",
                    rows: [
                        toggleRow(
                            id: SettingsID.mouseVertical,
                            title: localization.string("settings.mouse.vertical.title", defaultValue: "垂直反转"),
                            description: localization.string("settings.mouse.vertical.description", defaultValue: "反转鼠标上下滚动方向。"),
                            icon: "arrow.up.and.down",
                            isOn: store.configuration.reverseMouseVertical
                        ),
                        toggleRow(
                            id: SettingsID.mouseHorizontal,
                            title: localization.string("settings.mouse.horizontal.title", defaultValue: "水平反转"),
                            description: localization.string("settings.mouse.horizontal.description", defaultValue: "反转鼠标左右滚动方向。"),
                            icon: "arrow.left.and.right",
                            isOn: store.configuration.reverseMouseHorizontal
                        ),
                        scrollStepRow(
                            id: SettingsID.mouseScrollStep,
                            title: localization.string("settings.mouse.scrollStep.title", defaultValue: "滚动步长"),
                            description: localization.string(
                                "settings.mouse.scrollStep.description",
                                defaultValue: "鼠标每格滚动的最短距离，过小的滚动会被补足到该步长，0 为不调整。"
                            ),
                            value: store.configuration.mouseScrollStep
                        ),
                        scrollGainRow(
                            id: SettingsID.mouseScrollGain,
                            title: localization.string("settings.mouse.scrollGain.title", defaultValue: "滚动速度"),
                            description: localization.string(
                                "settings.mouse.scrollGain.description",
                                defaultValue: "鼠标滚动距离的增益倍数，1.0× 为不调整。"
                            ),
                            value: store.configuration.mouseScrollGain
                        ),
                        toggleRow(
                            id: SettingsID.mouseSmoothScrolling,
                            title: localization.string("settings.mouse.smooth.title", defaultValue: "平滑滚动"),
                            description: localization.string(
                                "settings.mouse.smooth.description",
                                defaultValue: "鼠标滚轮滚动改为平滑过渡，而非逐格跳动。"
                            ),
                            icon: "scroll",
                            isOn: store.configuration.smoothScrollingEnabled
                        ),
                        scrollDurationRow(
                            id: SettingsID.mouseScrollDuration,
                            title: localization.string("settings.mouse.smoothDuration.title", defaultValue: "滚动时长"),
                            description: localization.string(
                                "settings.mouse.smoothDuration.description",
                                defaultValue: "平滑滚动时每次滚动完成过渡所需的时间。"
                            ),
                            value: store.configuration.mouseScrollDuration
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "trackpad",
                    title: localization.string("settings.trackpad.sectionTitle", defaultValue: "触控板"),
                    systemImage: "hand.draw",
                    rows: trackpadRows
                )
            ]
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case .invokeAction(controlID: _):
            requestSettingsPresentation?()
        default:
            return
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        switch permissionID {
        case PermissionID.accessibility:
            return PluginPermissionState(
                isGranted: isAccessibilityGranted,
                footnote: isAccessibilityGranted
                    ? nil
                    : localization.string(
                        "permission.accessibility.footnote",
                        defaultValue: "系统设置 → 隐私与安全性 → 辅助功能，允许 MacTools。"
                    )
            )
        case PermissionID.inputMonitoring:
            return inputMonitoringPermissionState
        default:
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
    }

    func handlePermissionAction(id: String) {
        switch id {
        case PermissionID.accessibility:
            handleAccessibilityPermissionAction()
        case PermissionID.inputMonitoring:
            openInputMonitoringSettings()
        default:
            return
        }
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setBoolean(controlID, value):
            switch controlID {
            case SettingsID.mouseVertical:
                store.setReverseMouseVertical(value)
            case SettingsID.mouseHorizontal:
                store.setReverseMouseHorizontal(value)
            case SettingsID.trackpadVertical:
                store.setReverseTrackpadVertical(value)
            case SettingsID.trackpadHorizontal:
                store.setReverseTrackpadHorizontal(value)
            case SettingsID.middleClick:
                store.setMiddleClickEnabled(value)
            case SettingsID.mouseSmoothScrolling:
                store.setSmoothScrollingEnabled(value)
            default:
                return
            }
            configurationDidChange()
        case let .setSelection(controlID, optionID):
            guard controlID == SettingsID.middleClickFingerCount,
                  let count = Int(optionID),
                  (3...5).contains(count)
            else { return }
            store.setMiddleClickFingerCount(count)
            configurationDidChange()
        case let .setNumber(controlID, value, phase):
            guard phase == .committed else { return }
            switch controlID {
            case SettingsID.mouseScrollStep:
                store.setMouseScrollStep(value)
            case SettingsID.mouseScrollGain:
                store.setMouseScrollGain(value)
            case SettingsID.trackpadScrollStep:
                store.setTrackpadScrollStep(value)
            case SettingsID.trackpadScrollGain:
                store.setTrackpadScrollGain(value)
            case SettingsID.mouseScrollDuration:
                store.setMouseScrollDuration(value)
            default:
                return
            }
            configurationDidChange()
        default:
            return
        }
    }
    func handleShortcutAction(id: String) {}

    private func toggleRow(
        id: String,
        title: String,
        description: String,
        icon: String,
        isOn: Bool
    ) -> PluginSettingsRow {
        PluginSettingsRow(
            id: id,
            title: title,
            description: description,
            systemImage: icon,
            control: .toggle(isOn: isOn)
        )
    }

    private func scrollStepRow(
        id: String,
        title: String,
        description: String,
        value: Double
    ) -> PluginSettingsRow {
        PluginSettingsRow(
            id: id,
            title: title,
            description: description,
            systemImage: "ruler",
            control: .slider(
                value: value,
                range: MouseEnhancerConfiguration.scrollStepRange,
                step: 1,
                valueFormat: PluginSettingsSliderValueFormat(suffix: " px")
            )
        )
    }

    private func scrollGainRow(
        id: String,
        title: String,
        description: String,
        value: Double
    ) -> PluginSettingsRow {
        PluginSettingsRow(
            id: id,
            title: title,
            description: description,
            systemImage: "speedometer",
            control: .slider(
                value: value,
                range: MouseEnhancerConfiguration.scrollGainRange,
                step: 0.1,
                valueFormat: PluginSettingsSliderValueFormat(suffix: "×", fractionDigits: 1)
            )
        )
    }

    private func scrollDurationRow(
        id: String,
        title: String,
        description: String,
        value: Double
    ) -> PluginSettingsRow {
        PluginSettingsRow(
            id: id,
            title: title,
            description: description,
            systemImage: "timer",
            isEnabled: store.configuration.smoothScrollingEnabled,
            isVisible: store.configuration.smoothScrollingEnabled,
            control: .slider(
                value: value,
                range: MouseEnhancerConfiguration.scrollDurationRange,
                step: 0.1,
                valueFormat: PluginSettingsSliderValueFormat(suffix: " s", fractionDigits: 1)
            )
        )
    }

    func refreshAccessibilityPermission() {
        let previous = isAccessibilityGranted
        isAccessibilityGranted = accessibilityTrusted()

        if previous && !isAccessibilityGranted {
            session.deactivate()
            stopMiddleClickSession()
            runtimeError = .accessibilityRevoked
        } else if !previous && isAccessibilityGranted {
            runtimeError = nil
            applyCurrentConfiguration()
            applyMiddleClickConfiguration()
        }

        if previous != isAccessibilityGranted {
            onStateChange?()
        }
    }

    private func ensureAccessibilityPermissionForActiveConfiguration() -> Bool {
        runtimeError = nil

        let configuration = store.configuration
        guard configuration.shouldInstallEventTap
            || (ownsLegacyMiddleClick && configuration.middleClickEnabled)
        else {
            return true
        }

        isAccessibilityGranted = accessibilityTrusted()
        if !isAccessibilityGranted {
            isAccessibilityGranted = requestAccessibilityTrust(true)
        }

        guard isAccessibilityGranted else {
            runtimeError = .accessibilityRequired
            requestPermissionGuidance?(PermissionID.accessibility)
            return false
        }

        return true
    }

    func configurationDidChange() {
        runtimeError = nil
        guard ensureAccessibilityPermissionForActiveConfiguration() else {
            session.deactivate()
            stopMiddleClickSession()
            onStateChange?()
            return
        }

        applyCurrentConfiguration()
        applyMiddleClickConfiguration()
        onStateChange?()
    }

    private func applyCurrentConfiguration() {
        let configuration = store.configuration

        guard configuration.shouldInstallEventTap else {
            session.deactivate()
            return
        }

        guard isAccessibilityGranted else {
            session.deactivate()
            runtimeError = .accessibilityRequired
            return
        }

        if session.state.scrollTapInstalled {
            session.update(configuration: configuration)
            return
        }

        guard session.activate(configuration: configuration) else {
            runtimeError = .tapUnavailable
            logger.error("failed to install scroll event tap")
            return
        }
    }

    private func applyMiddleClickConfiguration() {
        let configuration = store.configuration

        guard ownsLegacyMiddleClick, configuration.middleClickEnabled else {
            stopMiddleClickSession()
            return
        }

        guard isAccessibilityGranted else {
            stopMiddleClickSession()
            runtimeError = .accessibilityRequired
            return
        }

        if let middleClickSession {
            middleClickSession.requiredFingerCount = configuration.middleClickFingerCount
            return
        }

        let newSession = makeMiddleClickSession()
        newSession.requiredFingerCount = configuration.middleClickFingerCount
        newSession.activate()
        middleClickSession = newSession
        logger.info(
            "legacy middle click enabled requiredFingerCount=\(configuration.middleClickFingerCount, privacy: .public)"
        )
    }

    private func stopMiddleClickSession() {
        middleClickSession?.deactivate()
        middleClickSession = nil
    }

    private func handleAccessibilityPermissionAction() {
        if isAccessibilityGranted {
            refreshAccessibilityPermission()
            return
        }

        isAccessibilityGranted = requestAccessibilityTrust(true)
        if isAccessibilityGranted {
            runtimeError = nil
            applyCurrentConfiguration()
            applyMiddleClickConfiguration()
        } else {
            runtimeError = .accessibilityRequired
        }
        onStateChange?()
    }

    private var panelSubtitle: String {
        let configuration = store.configuration

        if session.state.scrollTapInstalled {
            return localization.format(
                "panel.subtitle.enabledFormat",
                defaultValue: "已开启 · %@ · %@",
                deviceSummary(configuration),
                axisSummary(configuration)
            )
        }

        if activeConfigurationNeedsAccessibility(configuration), !isAccessibilityGranted {
            return localization.string("panel.subtitle.needsAccessibility", defaultValue: "启用前需要辅助功能授权")
        }

        if !configuration.shouldInstallEventTap,
           !(ownsLegacyMiddleClick && configuration.middleClickEnabled) {
            return localization.string("panel.subtitle.off", defaultValue: "未启用增强功能")
        }

        if ownsLegacyMiddleClick,
           configuration.middleClickEnabled,
           !configuration.shouldInstallEventTap {
            return localization.format(
                "panel.subtitle.middleClickEnabledFormat",
                defaultValue: "模拟中键 · %d指",
                configuration.middleClickFingerCount
            )
        }

        return metadata.defaultDescription
    }

    private func deviceSummary(_ configuration: MouseEnhancerConfiguration) -> String {
        switch (configuration.hasMouseEnhancement, configuration.hasTrackpadEnhancement) {
        case (true, true):
            return localization.string("summary.device.all", defaultValue: "鼠标和触控板")
        case (true, false):
            return localization.string("summary.device.mouse", defaultValue: "鼠标")
        case (false, true):
            return localization.string("summary.device.trackpad", defaultValue: "触控板")
        case (false, false):
            return localization.string("summary.device.none", defaultValue: "未选设备")
        }
    }

    private func axisSummary(_ configuration: MouseEnhancerConfiguration) -> String {
        let hasVertical = configuration.reverseMouseVertical || configuration.reverseTrackpadVertical
        let hasHorizontal = configuration.reverseMouseHorizontal || configuration.reverseTrackpadHorizontal

        switch (hasVertical, hasHorizontal) {
        case (true, true):
            return localization.string("summary.axis.all", defaultValue: "水平和垂直")
        case (true, false):
            return localization.string("summary.axis.vertical", defaultValue: "垂直")
        case (false, true):
            return localization.string("summary.axis.horizontal", defaultValue: "水平")
        case (false, false):
            return configuration.hasAnyScrollTuning
                ? localization.string("summary.axis.tuning", defaultValue: "滚动调节")
                : localization.string("summary.axis.none", defaultValue: "未选方向")
        }
    }

    private func activeConfigurationNeedsAccessibility(_ configuration: MouseEnhancerConfiguration) -> Bool {
        configuration.shouldInstallEventTap
            || (ownsLegacyMiddleClick && configuration.middleClickEnabled)
    }

    private var inputMonitoringPermissionState: PluginPermissionState {
        switch inputMonitoringAuthorizationStatus() {
        case .granted:
            return PluginPermissionState(
                isGranted: true,
                footnote: localization.string(
                    "permission.inputMonitoring.granted",
                    defaultValue: "已允许，可提升设备识别准确性。"
                )
            )
        case .denied, .unknown:
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.inputMonitoring.footnote",
                    defaultValue: "系统设置 → 隐私与安全性 → 输入监控，允许 MacTools。"
                )
            )
        }
    }

    private static func currentInputMonitoringAuthorizationStatus() -> MouseEnhancerInputMonitoringAuthorizationStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        case kIOHIDAccessTypeUnknown:
            return .unknown
        default:
            return .unknown
        }
    }

    private func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }

        openURL(url)
    }
}
