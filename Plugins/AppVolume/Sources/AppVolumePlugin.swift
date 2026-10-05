import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class AppVolumePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AppVolumePluginProvider(context: context)
    }
}

@MainActor
private struct AppVolumePluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            AppVolumePlugin(
                storage: context.storage,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class AppVolumePlugin: MacToolsPlugin, PluginActionProviding, PluginActionPermissionProviding {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    private enum ActionID {
        static let setVolume = "set-volume"
    }

    private enum ActionParameterID {
        static let application = "application"
        static let volume = "volume"
    }

    private enum ControlID {
        static let volumePrefix = "application-volume."
        static let openPermission = "open-system-audio-permission"
    }

    private enum PermissionID {
        static let systemAudio = "system-audio-recording"
    }

    private enum StorageKey {
        static let volumes = "applicationVolumes"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "app-volume",
            title: localization.string("metadata.title", defaultValue: "应用音量"),
            iconName: "speaker.wave.2.bubble",
            iconTint: Color(nsColor: .systemBlue),
            order: 46,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "分别调节正在播放音频的应用音量"
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

    private let monitor: any AudioApplicationMonitoring
    private let router: any ApplicationVolumeRouting
    private let storage: PluginStorage
    private let localization: PluginLocalization
    private let openSystemAudioPrivacySettings: () -> Void

    private var snapshot = AudioApplicationSnapshot.empty
    private var volumes: [String: Double]
    private var controlApplicationIDs: [String: String] = [:]
    private var isExpanded = false
    private var accessState = AppVolumeAccessState.unknown
    private var accessTask: Task<Void, Never>?
    private var shouldRecheckSystemAudioAccessOnRefresh = false
    private var pendingPanelVolumes: [String: Double] = [:]
    private var lastRouteErrorMessage: String?
    private var canonicalRoutingVolumes: [String: Double]?
    private var canonicalRouteToken: UUID?
    private var lifecycleGeneration: UInt64 = 0
    private var isActive = false

    private var isCanonicalRouteInProgress: Bool {
        canonicalRouteToken != nil
    }

    init(
        storage: PluginStorage? = nil,
        monitor: (any AudioApplicationMonitoring)? = nil,
        router: (any ApplicationVolumeRouting)? = nil,
        localization: PluginLocalization? = nil,
        openSystemAudioPrivacySettings: @escaping () -> Void = {
            AppVolumePlugin.openSystemAudioPrivacySettings()
        }
    ) {
        let storage = storage ?? UserDefaultsPluginStorage(pluginID: "app-volume")
        let monitor = monitor ?? CoreAudioApplicationMonitor()
        let router = router ?? CoreAudioApplicationVolumeRouter()
        let localization = localization ?? PluginLocalization(bundle: .main)

        self.storage = storage
        self.monitor = monitor
        self.router = router
        self.localization = localization
        self.openSystemAudioPrivacySettings = openSystemAudioPrivacySettings
        self.volumes = Self.loadVolumes(storage: storage)

        monitor.onUpdate = { [weak self] snapshot in
            self?.receive(snapshot)
        }
    }

    var rowState: PluginPanelRowState {
        rebuildControlApplicationIDs()
        let applications = snapshot.applications

        return PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: applications.contains { !Self.isUnity(volume(for: $0.id)) },
            isEnabled: router.isSupported,
            isAvailable: true,
            detail: panelDetail(applications: applications),
            errorMessage: panelErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        guard router.isSupported else {
            return []
        }

        return [
            PluginPermissionRequirement(
                id: PermissionID.systemAudio,
                kind: .screenRecording,
                title: localization.string(
                    "permission.systemAudio.title",
                    defaultValue: "系统音频录制"
                ),
                description: localization.string(
                    "permission.systemAudio.description",
                    defaultValue: "仅在本机实时处理应用音频，不会录制、保存或上传声音。"
                )
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setVolume),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "volume", "audio", "mute"],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: ActionParameterID.application,
                        title: metadata.title,
                        kind: .string,
                        portability: .localOnly
                    ),
                    ActionParameterDefinition(
                        id: ActionParameterID.volume,
                        title: metadata.title,
                        kind: .double
                    ),
                ],
                externalInvocationPolicy: .unavailable,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        snapshot.applications.flatMap { application in
            [0.0, 0.5, 1.0].map { gain in
                ActionCatalogEntry(
                    reference: volumeActionReference(applicationID: application.id, gain: gain),
                    title: "\(application.displayName) · \(Int(gain * 100))%",
                    subtitle: metadata.title
                )
            }
        }
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        actionKey == ActionKey(providerID: metadata.id, actionID: ActionID.setVolume)
            ? [PermissionID.systemAudio]
            : []
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard router.isSupported else {
            return .unavailable(localization.string(
                "panel.subtitle.unsupported",
                defaultValue: "需要 macOS 15 或更高版本"
            ))
        }
        guard actionTarget(for: reference) != nil else {
            return .unavailable(localization.string(
                "panel.subtitle.empty",
                defaultValue: "暂无正在播放音频的应用"
            ))
        }
        guard accessState != .requesting else {
            return .unavailable(localization.string(
                "permission.status.requesting",
                defaultValue: "正在请求"
            ))
        }
        guard !isCanonicalRouteInProgress else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        return .available
    }

    func activate(context: PluginRuntimeContext) {
        lifecycleGeneration &+= 1
        isActive = true
        monitor.start()
    }

    func deactivate(reason: PluginDeactivationReason) {
        lifecycleGeneration &+= 1
        isActive = false
        canonicalRouteToken = nil
        canonicalRoutingVolumes = nil
        pendingPanelVolumes.removeAll()
        lastRouteErrorMessage = nil
        accessTask?.cancel()
        accessTask = nil
        shouldRecheckSystemAudioAccessOnRefresh = false
        if accessState == .requesting {
            accessState = .unknown
        }
        monitor.stop()
        router.stop()
        snapshot = .empty
        onStateChange?()
    }

    func refresh() {
        monitor.refresh()
        guard shouldRecheckSystemAudioAccessOnRefresh else { return }
        shouldRecheckSystemAudioAccessOnRefresh = false
        requestAccess(force: true, openSettingsOnFailure: false)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.systemAudio else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }

        switch accessState {
        case .unknown:
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.systemAudio.footnote.unknown",
                    defaultValue: "首次调节应用音量时，macOS 会请求系统音频录制权限。"
                ),
                statusText: localization.string("permission.status.onDemand", defaultValue: "按需授权"),
                statusSystemImage: "waveform",
                statusTone: .neutral
            )
        case .requesting:
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.systemAudio.footnote.requesting",
                    defaultValue: "请在 macOS 权限提示中允许 MacTools。"
                ),
                statusText: localization.string("permission.status.requesting", defaultValue: "正在请求"),
                statusSystemImage: "ellipsis.circle",
                statusTone: .neutral
            )
        case .granted:
            return PluginPermissionState(isGranted: true, footnote: nil)
        case .denied:
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.systemAudio.footnote.denied",
                    defaultValue: "前往系统设置 → 隐私与安全性 → 屏幕与系统音频录制，授权 MacTools。"
                )
            )
        }
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.systemAudio else {
            return
        }

        requestAccess(
            force: true,
            openSettingsOnFailure: accessState != .granted,
            recheckGrantedAccess: accessState == .granted
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            isExpanded = expanded
            if expanded {
                monitor.refresh()
            }
            onStateChange?()
        case let .setSlider(controlID, value, phase):
            guard !isCanonicalRouteInProgress,
                  let applicationID = controlApplicationIDs[controlID] else {
                return
            }

            let gain = max(0, min(1, value))
            pendingPanelVolumes[applicationID] = gain
            onStateChange?()
            switch phase {
            case .changed:
                if !Self.isUnity(gain), accessState == .unknown {
                    requestAccess(force: false, openSettingsOnFailure: false)
                }
                applyCurrentTargets()
            case .ended:
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let result = await setVolume(gain, for: applicationID)
                    if pendingPanelVolumes[applicationID] == gain {
                        pendingPanelVolumes.removeValue(forKey: applicationID)
                    }
                    if case let .failed(message) = result {
                        lastRouteErrorMessage = message
                    }
                    onStateChange?()
                }
            }
        case let .invokeAction(controlID) where controlID == ControlID.openPermission:
            requestAccess(force: true, openSettingsOnFailure: true)
        default:
            break
        }
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard let target = actionTarget(for: invocation.reference) else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }

        return ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            return await self.setVolume(target.gain, for: target.applicationID)
        }
    }

    // MARK: - Snapshot and routing

    private func receive(_ snapshot: AudioApplicationSnapshot) {
        guard isActive else { return }
        self.snapshot = snapshot
        rebuildControlApplicationIDs()
        applyCurrentTargets()
        onStateChange?()
    }

    private func applyCurrentTargets() {
        var effectiveVolumes = canonicalRoutingVolumes ?? volumes
        for (applicationID, gain) in pendingPanelVolumes {
            effectiveVolumes[applicationID] = gain
        }
        let targets = routingTargets(volumes: effectiveVolumes)
        let needsProcessing = targets.contains { !Self.isUnity($0.gain) }

        guard needsProcessing else {
            router.update(targets: [], outputDeviceUID: snapshot.outputDeviceUID)
            return
        }

        switch accessState {
        case .granted:
            router.update(targets: targets, outputDeviceUID: snapshot.outputDeviceUID)
        case .unknown, .requesting, .denied:
            break
        }
    }

    private func volumeActionReference(applicationID: String, gain: Double) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setVolume),
            parameters: try! ActionParameterSet([
                ActionParameterID.application: .string(applicationID),
                ActionParameterID.volume: .double(gain),
            ])
        )
    }

    private func actionTarget(
        for reference: ActionReference
    ) -> (applicationID: String, gain: Double)? {
        guard reference.key.actionID == ActionID.setVolume,
              case let .string(applicationID)? = reference.parameters[ActionParameterID.application],
              case let .double(gain)? = reference.parameters[ActionParameterID.volume],
              gain >= 0,
              gain <= 1,
              snapshot.applications.contains(where: { $0.id == applicationID }) else {
            return nil
        }
        return (applicationID, gain)
    }

    private func setVolume(_ gain: Double, for applicationID: String) async -> ActionExecutionResult {
        guard isActive,
              snapshot.applications.contains(where: { $0.id == applicationID }) else {
            return .failed(message: localization.string(
                "panel.subtitle.empty",
                defaultValue: "暂无正在播放音频的应用"
            ))
        }

        guard canonicalRouteToken == nil else {
            return .failed(message: PluginKitLocalization.actionUnavailable)
        }
        let operationToken = UUID()
        let operationGeneration = lifecycleGeneration
        canonicalRouteToken = operationToken
        lastRouteErrorMessage = nil
        onStateChange?()
        defer {
            if canonicalRouteToken == operationToken {
                canonicalRoutingVolumes = nil
                canonicalRouteToken = nil
                onStateChange?()
            }
        }

        if !Self.isUnity(gain), accessState != .granted {
            if let accessTask {
                await accessTask.value
                guard isCurrentCanonicalOperation(
                    token: operationToken,
                    generation: operationGeneration
                ) else {
                    return .cancelled
                }
                guard !Task.isCancelled else {
                    return .cancelled
                }
                guard accessState == .granted else {
                    return .failed(message: localization.string(
                        "permission.systemAudio.footnote.denied",
                        defaultValue: "前往系统设置 → 隐私与安全性 → 屏幕与系统音频录制，授权 MacTools。"
                    ))
                }
            } else {
                accessState = .requesting
                onStateChange?()
                let granted = await router.requestSystemAudioAccess()
                guard isCurrentCanonicalOperation(
                    token: operationToken,
                    generation: operationGeneration
                ) else {
                    return .cancelled
                }
                guard !Task.isCancelled else {
                    accessState = .unknown
                    onStateChange?()
                    return .cancelled
                }
                accessState = granted ? .granted : .denied
                guard granted else {
                    onStateChange?()
                    return .failed(message: localization.string(
                        "permission.systemAudio.footnote.denied",
                        defaultValue: "前往系统设置 → 隐私与安全性 → 屏幕与系统音频录制，授权 MacTools。"
                    ))
                }
            }
        }

        let previousVolumes = volumes
        var candidateVolumes = volumes
        candidateVolumes[applicationID] = gain
        canonicalRoutingVolumes = candidateVolumes
        let targets = routingTargets(volumes: candidateVolumes)
        let applyResult = await router.applyAndWait(
            targets: targets,
            outputDeviceUID: snapshot.outputDeviceUID
        )
        guard isCurrentCanonicalOperation(
            token: operationToken,
            generation: operationGeneration
        ) else {
            return .cancelled
        }
        switch applyResult {
        case .succeeded:
            switch persistVolumes(candidateVolumes) {
            case .committed:
                volumes = candidateVolumes
                lastRouteErrorMessage = nil
                onStateChange?()
                return .succeeded()
            case let .rejected(rollbackSucceeded):
                canonicalRoutingVolumes = previousVolumes
                let rollbackResult = await router.applyAndWait(
                    targets: routingTargets(volumes: previousVolumes),
                    outputDeviceUID: snapshot.outputDeviceUID
                )
                guard isCurrentCanonicalOperation(
                    token: operationToken,
                    generation: operationGeneration
                ) else {
                    return .cancelled
                }
                let message: String
                if !rollbackSucceeded {
                    message = localization.string(
                        "action.persistenceStorageRollbackFailed",
                        defaultValue: "无法保存应用音量设置，且恢复先前存储值失败。"
                    )
                } else if rollbackResult == .failed {
                    message = localization.string(
                        "action.persistenceRouteRollbackFailed",
                        defaultValue: "无法保存应用音量设置，且恢复先前路由失败。"
                    )
                } else {
                    message = localization.string(
                        "action.persistenceFailed",
                        defaultValue: "无法保存应用音量设置。"
                    )
                }
                lastRouteErrorMessage = message
                return .failed(message: message)
            }
        case .failed:
            canonicalRoutingVolumes = previousVolumes
            let rollbackResult = await router.applyAndWait(
                targets: routingTargets(volumes: previousVolumes),
                outputDeviceUID: snapshot.outputDeviceUID
            )
            guard isCurrentCanonicalOperation(
                token: operationToken,
                generation: operationGeneration
            ) else {
                return .cancelled
            }
            let message = switch rollbackResult {
            case .succeeded:
                localization.string(
                    "action.routeFailed",
                    defaultValue: "无法应用应用音量设置。"
                )
            case .failed:
                localization.string(
                    "action.routeRollbackFailed",
                    defaultValue: "无法应用应用音量设置，且恢复先前路由失败。"
                )
            }
            lastRouteErrorMessage = message
            return .failed(message: message)
        }
    }

    private func isCurrentCanonicalOperation(
        token: UUID,
        generation: UInt64
    ) -> Bool {
        isActive
            && lifecycleGeneration == generation
            && canonicalRouteToken == token
    }

    private func routingTargets(
        volumes: [String: Double]
    ) -> [ApplicationVolumeTarget] {
        snapshot.applications.map { application in
            ApplicationVolumeTarget(
                id: application.id,
                processObjectIDs: application.processObjectIDs,
                gain: volumes[application.id] ?? 1
            )
        }
    }

    private func requestAccess(
        force: Bool,
        openSettingsOnFailure: Bool,
        recheckGrantedAccess: Bool = false
    ) {
        if accessState == .granted, !recheckGrantedAccess {
            shouldRecheckSystemAudioAccessOnRefresh = false
            applyCurrentTargets()
            return
        }
        guard accessTask == nil, force || accessState == .unknown else {
            if openSettingsOnFailure, accessState == .denied {
                shouldRecheckSystemAudioAccessOnRefresh = true
                openSystemAudioPrivacySettings()
            }
            return
        }

        accessState = .requesting
        onStateChange?()
        accessTask = Task { [weak self] in
            guard let self else {
                return
            }

            let granted = await router.requestSystemAudioAccess()
            guard !Task.isCancelled else {
                return
            }

            accessState = granted ? .granted : .denied
            accessTask = nil
            if granted {
                applyCurrentTargets()
            } else {
                router.update(targets: [], outputDeviceUID: snapshot.outputDeviceUID)
                if openSettingsOnFailure {
                    shouldRecheckSystemAudioAccessOnRefresh = true
                    openSystemAudioPrivacySettings()
                }
            }
            onStateChange?()
        }
    }

    // MARK: - Panel presentation

    private var panelSubtitle: String {
        guard router.isSupported else {
            return localization.string("panel.subtitle.unsupported", defaultValue: "需要 macOS 15 或更高版本")
        }

        let count = snapshot.applications.count
        guard count > 0 else {
            return localization.string("panel.subtitle.empty", defaultValue: "暂无正在播放音频的应用")
        }

        return localization.format(
            "panel.subtitle.countFormat",
            defaultValue: "%d 个应用正在播放",
            count
        )
    }

    private var panelErrorMessage: String? {
        guard router.isSupported else {
            return localization.string(
                "error.unsupported",
                defaultValue: "应用独立音量需要 macOS 15 或更高版本"
            )
        }

        if let lastRouteErrorMessage {
            return lastRouteErrorMessage
        }
        return accessState == .denied
            ? localization.string("error.permissionDenied", defaultValue: "需要系统音频录制权限")
            : nil
    }

    private func panelDetail(applications: [AudioApplication]) -> PluginPanelDetail? {
        guard router.isSupported, isExpanded else {
            return nil
        }

        var controls = applications.map { application in
            let value = volume(for: application.id)
            return PluginPanelControl(
                id: controlID(applicationID: application.id),
                kind: .slider,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: application.displayName,
                sliderValue: value,
                sliderBounds: 0...1,
                sliderStep: 0.01,
                valueLabel: Self.percentLabel(value),
                isEnabled: accessState != .requesting && !isCanonicalRouteInProgress
            )
        }

        if accessState == .denied {
            controls.append(
                PluginPanelControl(
                    id: ControlID.openPermission,
                    kind: .actionRow,
                    options: [],
                    selectedOptionID: nil,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: localization.string(
                        "panel.permission.description",
                        defaultValue: "允许后才能实时处理其他应用的音频。"
                    ),
                    actionTitle: localization.string(
                        "panel.permission.openSettings",
                        defaultValue: "打开隐私设置"
                    ),
                    actionIconSystemName: "lock.open",
                    showsLeadingDivider: !controls.isEmpty,
                    isEnabled: true
                )
            )
        }

        return PluginPanelDetail(controls: controls)
    }

    private func rebuildControlApplicationIDs() {
        controlApplicationIDs = Dictionary(
            uniqueKeysWithValues: snapshot.applications.map {
                (controlID(applicationID: $0.id), $0.id)
            }
        )
    }

    private func controlID(applicationID: String) -> String {
        ControlID.volumePrefix + Data(applicationID.utf8).base64EncodedString()
    }

    private func volume(for applicationID: String) -> Double {
        max(0, min(1, pendingPanelVolumes[applicationID] ?? volumes[applicationID] ?? 1))
    }

    // MARK: - Persistence

    private static func loadVolumes(storage: PluginStorage) -> [String: Double] {
        guard let data = storage.data(forKey: StorageKey.volumes),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }

        return decoded.mapValues { max(0, min(1, $0)) }
    }

    private enum VolumePersistenceResult {
        case committed
        case rejected(rollbackSucceeded: Bool)
    }

    private func persistVolumes(_ candidate: [String: Double]) -> VolumePersistenceResult {
        guard let data = try? JSONEncoder().encode(candidate) else {
            return .rejected(rollbackSucceeded: true)
        }
        let previousRawValue = storage.object(forKey: StorageKey.volumes)
        storage.set(data, forKey: StorageKey.volumes)
        guard storage.data(forKey: StorageKey.volumes) == data else {
            restore(previousRawValue, forKey: StorageKey.volumes)
            return .rejected(
                rollbackSucceeded: rawValuesMatch(
                    storage.object(forKey: StorageKey.volumes),
                    previousRawValue
                )
            )
        }
        return .committed
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            storage.set(value, forKey: key)
        } else {
            storage.removeObject(forKey: key)
        }
    }

    private func rawValuesMatch(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs as NSObject, rhs as NSObject):
            lhs.isEqual(rhs)
        default:
            false
        }
    }

    private static func percentLabel(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static func isUnity(_ gain: Double) -> Bool {
        abs(gain - 1) < 0.005
    }

    private static func openSystemAudioPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate), NSWorkspace.shared.open(url) else {
                continue
            }
            return
        }
    }
}
