import AppKit
import ApplicationServices
import Foundation
@preconcurrency import IOKit.hid
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class TrackpadGesturesPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        TrackpadGesturesPluginProvider(context: context)
    }
}

@MainActor
private struct TrackpadGesturesPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [TrackpadGesturesPlugin(context: context)]
    }
}

enum TrackpadInputMonitoringStatus: Equatable {
    case granted
    case denied
    case unknown
}

private struct TrackpadGestureReadinessError: LocalizedError {
    let localizedMessage: String

    var errorDescription: String? {
        localizedMessage
    }
}

@MainActor
final class TrackpadGesturesPlugin: MacToolsPlugin, AccessibilityPermissionRefreshing, PluginSettingsPresenting, PluginSettingsSearchFocusing, PluginSettingsSearchFocusMetadataProviding, PluginFeatureExtractionReadinessProviding, TrackpadActionHostContextConsuming, PluginPortablePreferencesProviding, PluginPortablePreferencesRestorationReporting, PluginPersistentPreferencesChangeSignaling, PluginPortablePreferencesActionReferencesProviding, PluginInputGestureClaimProviding, TrackpadGestureEventProviding {
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

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "trackpad-gestures",
            title: localization.string("metadata.title", defaultValue: "触控板手势"),
            iconName: "hand.draw",
            iconTint: Color(nsColor: .systemIndigo),
            order: 57,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "将触控板手势映射为 MacTools 操作、快捷键或中键点击"
            )
        )
    }
    let rowDescriptor: PluginPanelRowDescriptor
    private let settingsSearchFocusController = TrackpadSettingsSearchFocusController()

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?
    var trackpadActionHostContext: TrackpadActionHostContext? {
        didSet {
            if let trackpadActionHostContext,
               store.migrateActions(using: trackpadActionHostContext) {
                onStateChange?()
                persistentPreferencesChanges.didPersist()
            }
        }
    }
    var requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)?
    var onTrackpadGestureRequestsChange: (() -> Void)?
    var onPersistentPreferencesChange: (() -> Void)? {
        get { persistentPreferencesChanges.onChange }
        set { persistentPreferencesChanges.onChange = newValue }
    }

    let store: TrackpadGestureStore
    let testingModel: TrackpadGestureTestingModel

    var activeInputGestureClaims: [PluginInputGestureClaim] {
        let gestures = store.isTesting
            ? TrackpadGesture.allCases
            : Array(store.enabledGestures.union(externalGestureClaims))
        let claimedFingerCounts = Set(gestures.compactMap(\.middleClickOverlapFingerCount))
        return claimedFingerCounts.sorted().map { count in
            return PluginInputGestureClaim(
                id: "trackpad.tap.\(count)",
                title: TrackpadGesture.fingerTap(count: count).title(localization: localization)
            )
        }
    }

    private let localization: PluginLocalization
    private let session: any MultitouchDeviceSessionManaging
    private let actionExecutor: any TrackpadGestureActionExecuting
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool
    private let inputMonitoringStatus: @MainActor () -> TrackpadInputMonitoringStatus
    private let openURL: (URL) -> Void
    private var isAccessibilityGranted: Bool
    private var isInputMonitoringGranted: Bool
    private enum RuntimeError {
        case listenerUnavailable
        case accessibilityRequired
        case inputMonitoringRequired
    }

    private var runtimeError: RuntimeError?

    private var lastErrorMessage: String? {
        guard let runtimeError else { return nil }
        switch runtimeError {
        case .listenerUnavailable:
            return localization.string(
                "error.listenerUnavailable",
                defaultValue: "无法启动手势监听，请检查权限后重试。"
            )
        case .accessibilityRequired:
            return localization.string(
                "error.accessibilityRequired",
                defaultValue: "触控板手势需要辅助功能权限。"
            )
        case .inputMonitoringRequired:
            return localization.string(
                "error.inputMonitoringRequired",
                defaultValue: "触控板手势需要输入监控权限。"
            )
        }
    }
    private var listenerActivationFailed = false
    private var applicationActivationObserver: NSObjectProtocol?
    private var externalGestureClaims: Set<TrackpadGesture> = []
    private var ownedLocalGestures: Set<TrackpadGesture> = []
    private var isTrackpadGestureOwnershipManaged = false
    private var externalGestureHandler: ((TrackpadGesture, UInt64) -> Void)?
    private var lastKnownEnabledLocalGestures: Set<TrackpadGesture>

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "TrackpadGesturesPlugin"
    )
    private let persistentPreferencesChanges = PluginPersistentPreferencesChangeEmitter()

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "trackpad-gestures"),
        legacyMiddleClick: LegacyMiddleClickPreferences? = LegacyMiddleClickPreferences.load(),
        session: (any MultitouchDeviceSessionManaging)? = nil,
        actionExecutor: (any TrackpadGestureActionExecuting)? = nil,
        localization: PluginLocalization? = nil,
        accessibilityTrusted: @escaping @MainActor () -> Bool = {
            AXIsProcessTrusted()
        },
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = { prompt in
            let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        },
        inputMonitoringStatus: @escaping @MainActor () -> TrackpadInputMonitoringStatus = {
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: .granted
            case kIOHIDAccessTypeDenied: .denied
            default: .unknown
            }
        },
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        let resolvedLocalization = localization ?? PluginLocalization(bundle: context.resourceBundle)
        self.localization = resolvedLocalization
        let store = TrackpadGestureStore(
            storage: context.storage,
            legacyMiddleClick: legacyMiddleClick
        )
        self.store = store
        self.testingModel = TrackpadGestureTestingModel()
        self.lastKnownEnabledLocalGestures = store.enabledGestures
        self.session = session ?? MultitouchDeviceSession()
        self.actionExecutor = actionExecutor ?? TrackpadGestureActionExecutor()
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.inputMonitoringStatus = inputMonitoringStatus
        self.openURL = openURL
        self.isAccessibilityGranted = accessibilityTrusted()
        self.isInputMonitoringGranted = inputMonitoringStatus() == .granted
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .keepPresented,
            buttonTitleProvider: {
                resolvedLocalization.string("panel.button.settings", defaultValue: "设置")
            }
        )
        if store.didPersistPortablePreferencesDuringInitialization {
            persistentPreferencesChanges.didPersist()
        }

        self.session.onRecognized = {
            [weak self] gesture, deviceID, timestamp, evidence in
            self?.handleRecognizedGesture(
                gesture,
                deviceID: deviceID,
                timestamp: timestamp,
                evidence: evidence
            )
        }
        self.session.onAvailabilityChange = { [weak self] isAvailable in
            guard let self, self.recognitionNeeded else { return }
            if self.store.isTesting {
                self.testingModel.clearSnapshots()
            }
            if isAvailable, self.isAccessibilityGranted, self.isInputMonitoringGranted {
                self.listenerActivationFailed = false
                self.runtimeError = nil
            } else if !isAvailable, self.isAccessibilityGranted, self.isInputMonitoringGranted {
                self.listenerActivationFailed = true
                self.runtimeError = .listenerUnavailable
            }
            self.onStateChange?()
        }
        if let testingSession = self.session as? any MultitouchDeviceTestingSessionManaging {
            testingSession.onTestingSnapshot = { [weak self] snapshot in
                guard let self, self.store.isTesting else { return }
                let mode = self.testingModel.mode ?? .allGestures
                self.testingModel.apply(snapshot.preparingForDisplay(mode: mode))
            }
            testingSession.onTestingReset = { [weak self] in
                guard let self, self.store.isTesting else { return }
                self.testingModel.clearSnapshots()
            }
        }
    }

    func activate(context: PluginRuntimeContext) {
        observeApplicationActivation()
        refreshPermissionsAndApply()
    }

    func deactivate(reason: PluginDeactivationReason) {
        // Test mode is session-only and must never survive a listener restart or hot update.
        store.setTesting(false)
        testingModel.stop()
        (session as? any MultitouchDeviceTestingSessionManaging)?.updateTestingMode(nil)
        removeApplicationActivationObserver()
        session.deactivate()
        onStateChange?()
    }

    func refresh() {
        refreshPermissionsAndApply()
        onStateChange?()
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
                    defaultValue: "用于发送快捷键和中键点击。"
                )
            ),
            PluginPermissionRequirement(
                id: PermissionID.inputMonitoring,
                kind: .inputMonitoring,
                title: localization.string("permission.inputMonitoring.title", defaultValue: "输入监控"),
                description: localization.string(
                    "permission.inputMonitoring.description",
                    defaultValue: "用于在系统范围内识别触控板接触手势。所有处理均在本机完成。"
                )
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(
                id: "mappings",
                title: localization.string("settings.mappings.title", defaultValue: "手势映射"),
                systemImage: "hand.tap",
                presentation: .edgeToEdge
            ) { [weak self] _ in
                if let self {
                    TrackpadGesturesSettingsView(
                        store: self.store,
                        testingModel: self.testingModel,
                        localization: self.localization,
                        actionHostContext: self.trackpadActionHostContext,
                        isGestureOwned: { self.isGestureOwned($0) },
                        onChange: { [weak self] in self?.configurationDidChange() },
                        onSetTesting: { [weak self] enabled in self?.setTesting(enabled) },
                        onSetTestingMode: { [weak self] mode in self?.setTestingMode(mode) },
                        section: .mappings,
                        searchFocusController: self.settingsSearchFocusController
                    )
                    .pluginSettingsSearchAnchor(
                        pluginID: self.metadata.id,
                        entryID: "mappings"
                    )
                }
            }
            .headerAccessory { [weak self] _ in
                if let self {
                    TrackpadGestureTestingHeaderAccessory(
                        store: self.store,
                        localization: self.localization,
                        onSetTesting: { [weak self] enabled in self?.setTesting(enabled) }
                    )
                }
            },
            PluginSettingsSection(
                id: "typing-protection",
                title: localization.string("settings.typing.title", defaultValue: "输入保护"),
                systemImage: "keyboard",
                presentation: .edgeToEdge
            ) { [weak self] _ in
                if let self {
                    TrackpadGesturesSettingsView(
                        store: self.store,
                        testingModel: self.testingModel,
                        localization: self.localization,
                        actionHostContext: self.trackpadActionHostContext,
                        isGestureOwned: { self.isGestureOwned($0) },
                        onChange: { [weak self] in self?.configurationDidChange() },
                        onSetTesting: { [weak self] enabled in self?.setTesting(enabled) },
                        onSetTestingMode: { [weak self] mode in self?.setTestingMode(mode) },
                        section: .typingProtection
                    )
                }
            }
        ])
        .onVisibilityChange { [weak self] isVisible in
            guard !isVisible, self?.store.isTesting == true else {
                return
            }
            self?.setTesting(false)
        }
    }

    func focusSettingsSearch() {
        settingsSearchFocusController.requestFocus()
    }

    var settingsSearchFocusTarget: PluginSettingsSearchTarget? {
        PluginSettingsSearchTarget(pluginID: metadata.id, entryID: "mappings")
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
                    defaultValue: "系统设置 → 隐私与安全性 → 输入监控，允许 MacTools；若状态未更新，请重新打开 MacTools。"
                )
            )
        default:
            PluginPermissionState(isGranted: true, footnote: nil)
        }
    }

    func handlePermissionAction(id: String) {
        switch id {
        case PermissionID.accessibility:
            isAccessibilityGranted = requestAccessibilityTrust(true)
            refreshPermissionsAndApply()
        case PermissionID.inputMonitoring:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                openURL(url)
            }
        default:
            break
        }
        onStateChange?()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func refreshAccessibilityPermission() {
        refreshPermissionsAndApply()
    }

    func validateFeatureExtractionReadiness() throws {
        guard !listenerActivationFailed else {
            throw TrackpadGestureReadinessError(localizedMessage: localization.string(
                "error.listenerUnavailable",
                defaultValue: "无法启动手势监听，请检查权限后重试。"
            ))
        }
    }

    func configurationDidChange(persistent: Bool = true) {
        session.invalidatePendingDeliveriesForConfigurationChange()
        if persistent {
            persistentPreferencesChanges.didPersist()
        }
        let enabledLocalGestures = store.enabledGestures
        let newlyEnabledGestures = enabledLocalGestures.subtracting(lastKnownEnabledLocalGestures)
        lastKnownEnabledLocalGestures = enabledLocalGestures
        newlyEnabledGestures.forEach { requestTrackpadGestureOwnership?($0) }
        onTrackpadGestureRequestsChange?()

        guard ensurePermissionsIfNeeded() else {
            session.deactivate()
            onStateChange?()
            return
        }
        applyConfiguration()
        onStateChange?()
    }

    private func setTesting(_ enabled: Bool) {
        if enabled {
            setTestingMode(.allGestures)
            return
        }
        store.setTesting(enabled)
        testingModel.stop()
        (session as? any MultitouchDeviceTestingSessionManaging)?.updateTestingMode(nil)
        configurationDidChange(persistent: false)
    }

    private func setTestingMode(_ mode: TrackpadGestureTestingMode?) {
        guard let mode else {
            setTesting(false)
            return
        }
        if store.isTesting {
            store.clearTestGesture()
            testingModel.updateMode(mode)
        } else {
            store.setTesting(true)
            testingModel.begin(mode)
        }
        configurationDidChange(persistent: false)
    }

    private func handleRecognizedGesture(
        _ gesture: TrackpadGesture,
        deviceID: UInt64,
        timestamp: TimeInterval?,
        evidence: TrackpadGestureRecognitionEvidence?
    ) {
        guard session.isActive else {
            return
        }

        let accessibilityGrantedNow = accessibilityTrusted()
        let inputMonitoringGrantedNow = inputMonitoringStatus() == .granted
        guard accessibilityGrantedNow, inputMonitoringGrantedNow else {
            isAccessibilityGranted = accessibilityGrantedNow
            isInputMonitoringGranted = inputMonitoringGrantedNow
            session.deactivate()
            testingModel.clearSnapshots()
            runtimeError = permissionError
            onStateChange?()
            return
        }

        if store.isTesting {
            if let practiceGesture = testingModel.mode?.practiceGesture,
               gesture != practiceGesture {
                return
            }
            if gesture.tipTapConfiguration == nil,
               gesture.physicalClickFingerCount == nil,
               gesture.producesNativeClick,
               session.resolveNativeClick(
                   for: gesture,
                   deviceID: deviceID,
                   evidence: evidence
               ) == nil {
                return
            }
            testingModel.recordRecognized(gesture, deviceID: deviceID, at: timestamp)
            store.recordTestGesture(gesture)
            return
        }
        if externalGestureClaims.contains(gesture) {
            if gesture.tipTapConfiguration == nil,
               gesture.physicalClickFingerCount == nil,
               gesture.producesNativeClick,
               session.resolveNativeClick(
                   for: gesture,
                   deviceID: deviceID,
                   evidence: evidence
               ) == nil {
                return
            }
            externalGestureHandler?(gesture, deviceID)
            return
        }
        guard let mapping = store.mapping(for: gesture), mapping.isEnabled else {
            return
        }
        if gesture.physicalClickFingerCount != nil {
            // The native event was already consumed or rewritten synchronously by the event tap.
            if case .middleClick = mapping.action {
                return
            }
        } else if gesture.tipTapConfiguration != nil {
            // TipTap delivery is already deferred by the session until the exact native click
            // pair has been correlated and suppressed or rewritten.
            if mapping.action == .middleClick {
                return
            }
        } else if gesture.producesNativeClick {
            guard let clickResolution = session.resolveNativeClick(
                for: gesture,
                deviceID: deviceID,
                evidence: evidence
            ) else {
                return
            }
            if clickResolution == .middleClick {
                return
            }
        }
        if case let .action(reference) = mapping.action {
            trackpadActionHostContext?.execute(reference)
        } else {
            actionExecutor.execute(mapping.action)
        }
    }

    private func refreshPermissionsAndApply() {
        let previousAccessibility = isAccessibilityGranted
        let previousInputMonitoring = isInputMonitoringGranted
        isAccessibilityGranted = accessibilityTrusted()
        isInputMonitoringGranted = inputMonitoringStatus() == .granted

        if recognitionNeeded && (!isAccessibilityGranted || !isInputMonitoringGranted) {
            session.deactivate()
            testingModel.clearSnapshots()
            runtimeError = permissionError
        } else {
            runtimeError = nil
            applyConfiguration()
        }

        if previousAccessibility != isAccessibilityGranted
            || previousInputMonitoring != isInputMonitoringGranted {
            onStateChange?()
        }
    }

    private func observeApplicationActivation() {
        guard applicationActivationObserver == nil else { return }
        applicationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshPermissionsAndApply()
                self.onStateChange?()
            }
        }
    }

    private func removeApplicationActivationObserver() {
        guard let applicationActivationObserver else { return }
        NotificationCenter.default.removeObserver(applicationActivationObserver)
        self.applicationActivationObserver = nil
    }

    private func ensurePermissionsIfNeeded() -> Bool {
        guard recognitionNeeded else {
            runtimeError = nil
            return true
        }

        isAccessibilityGranted = accessibilityTrusted()
        if !isAccessibilityGranted {
            isAccessibilityGranted = requestAccessibilityTrust(true)
        }
        isInputMonitoringGranted = inputMonitoringStatus() == .granted

        guard isAccessibilityGranted else {
            runtimeError = permissionError
            requestPermissionGuidance?(PermissionID.accessibility)
            return false
        }
        guard isInputMonitoringGranted else {
            runtimeError = permissionError
            requestPermissionGuidance?(PermissionID.inputMonitoring)
            return false
        }
        runtimeError = nil
        return true
    }

    private func applyConfiguration() {
        listenerActivationFailed = false
        if store.isTesting, let mode = testingModel.mode {
            (session as? any MultitouchDeviceTestingSessionManaging)?.updateTestingMode(mode)
        }
        let localGestures = managedLocalGestures
        let gestures = store.isTesting
            ? Set(TrackpadGesture.allCases)
            : localGestures.union(externalGestureClaims)
        let clickResolutions: [TrackpadGesture: TrackpadNativeClickResolution]
        if store.isTesting {
            clickResolutions = Dictionary(uniqueKeysWithValues: TrackpadGesture.allCases.compactMap {
                gesture in
                guard gesture.producesNativeClick else {
                    return nil
                }
                return (gesture, .consume)
            })
        } else {
            let localResolutions: [TrackpadGesture: TrackpadNativeClickResolution] = Dictionary(
                uniqueKeysWithValues: store.mappings.compactMap { mapping -> (TrackpadGesture, TrackpadNativeClickResolution)? in
                guard mapping.isEnabled, localGestures.contains(mapping.gesture) else { return nil }
                switch mapping.action {
                case .middleClick:
                    return (mapping.gesture, .middleClick)
                case .action where mapping.gesture.producesNativeClick:
                    return (mapping.gesture, .consume)
                case .keyboardShortcut, .keyTap:
                    guard mapping.gesture.producesNativeClick else {
                        return nil
                    }
                    return (mapping.gesture, .consume)
                case .action:
                    return nil
                }
                }
            )
            let externalResolutions: [TrackpadGesture: TrackpadNativeClickResolution] = Dictionary(
                uniqueKeysWithValues: externalGestureClaims.compactMap { gesture -> (TrackpadGesture, TrackpadNativeClickResolution)? in
                    guard gesture.producesNativeClick else {
                        return nil
                    }
                    return (gesture, .consume)
                }
            )
            clickResolutions = localResolutions.merging(externalResolutions) { local, _ in local }
        }
        session.updateNativeClickResolutions(clickResolutions)
        session.updateTypingProtection(
            isEnabled: store.ignoresGesturesWhileTyping,
            gracePeriod: store.typingGracePeriod
        )
        guard !gestures.isEmpty else {
            session.deactivate()
            return
        }
        guard isAccessibilityGranted, isInputMonitoringGranted else {
            session.deactivate()
            return
        }

        if session.isActive {
            session.update(gestures: gestures)
            return
        }
        guard session.activate(gestures: gestures) else {
            listenerActivationFailed = true
            runtimeError = .listenerUnavailable
            logger.error("failed to start multitouch session")
            return
        }
    }

    private var recognitionNeeded: Bool {
        store.isTesting || !store.enabledGestures.isEmpty || !externalGestureClaims.isEmpty
    }

    var requestedTrackpadGestures: Set<TrackpadGesture> {
        store.enabledGestures
    }

    func setTrackpadGestureOwnership(
        localGestures: Set<TrackpadGesture>,
        externalGestures: Set<TrackpadGesture>,
        handler: @escaping (TrackpadGesture, UInt64) -> Void
    ) {
        session.invalidatePendingDeliveriesForConfigurationChange()
        isTrackpadGestureOwnershipManaged = true
        ownedLocalGestures = localGestures
        externalGestureClaims = externalGestures
        externalGestureHandler = handler
        applyConfiguration()
        onStateChange?()
    }

    private var managedLocalGestures: Set<TrackpadGesture> {
        isTrackpadGestureOwnershipManaged ? ownedLocalGestures : store.enabledGestures
    }

    private func isGestureOwned(_ gesture: TrackpadGesture) -> Bool {
        !isTrackpadGestureOwnershipManaged || ownedLocalGestures.contains(gesture)
    }

    private var permissionError: RuntimeError {
        isAccessibilityGranted ? .inputMonitoringRequired : .accessibilityRequired
    }

    private var panelSubtitle: String {
        if store.isTesting {
            return localization.string("panel.subtitle.testing", defaultValue: "正在测试手势")
        }
        let count = store.mappings.lazy.filter(\.isEnabled).count
        guard count > 0 else {
            return localization.string("panel.subtitle.empty", defaultValue: "尚未配置手势")
        }
        if !isAccessibilityGranted || !isInputMonitoringGranted {
            return localization.string("panel.subtitle.needsPermission", defaultValue: "需要完成权限设置")
        }
        return localization.format("panel.subtitle.enabledCountFormat", defaultValue: "%d 个手势已启用", count)
    }

    func trackpadActionCatalogDidChange() {
        guard let trackpadActionHostContext else { return }
        if store.migrateActions(using: trackpadActionHostContext) {
            onStateChange?()
            persistentPreferencesChanges.didPersist()
        }
    }

    func makePortablePreferencesBackup() -> Data? {
        store.portableBackup(using: trackpadActionHostContext)
    }

    func restorePortablePreferences(from data: Data) {
        _ = restorePortablePreferencesAndNotify(from: data)
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        restorePortablePreferencesAndNotify(from: data)
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        store.actionReferences(inPortableBackup: data)
    }

    private func restorePortablePreferencesAndNotify(from data: Data) -> Bool {
        let previousMappings = store.mappings
        let previousIgnoresGesturesWhileTyping = store.ignoresGesturesWhileTyping
        let previousTypingGracePeriod = store.typingGracePeriod
        guard store.restorePortableBackup(data, using: trackpadActionHostContext) else {
            return false
        }
        if store.mappings != previousMappings
            || store.ignoresGesturesWhileTyping != previousIgnoresGesturesWhileTyping
            || store.typingGracePeriod != previousTypingGracePeriod {
            configurationDidChange()
        }
        return true
    }
}
