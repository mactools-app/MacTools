import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

// MARK: - Bundle Factory

public final class FanControlPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        FanControlPluginProvider(context: context)
    }
}

@MainActor
private struct FanControlPluginProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] {
        [FanControlPlugin(context: context, localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

// MARK: - Control IDs

private enum ControlID {
    static let presetList   = "fan-preset-list"
    static let customSlider = "fan-custom-rpm"
    static let addPreset    = "fan-add-preset"
    static let deletePreset = "fan-delete-preset"
    static let missingHelper = "fan-missing-helper"
}

// MARK: - Plugin

@MainActor
final class FanControlPlugin: MacToolsPlugin, PluginActionProviding, PluginPortablePreferencesProviding, PluginPersistentPreferencesChangeSignaling, PluginPortablePreferencesRestorationReporting, PluginPortablePreferencesActionReferencesProviding, PluginActionReferenceBackupProviding {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("control") }
                    else { self?.panelItemDidBecomeHidden("control") }
                },
        ]
    }

    private enum ActionID {
        static let applyPreset = "apply-preset"
    }

    private enum ActionParameterID {
        static let preset = "preset"
    }

    // MARK: Metadata

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "fan-control",
            title: localization.string("metadata.title", defaultValue: "风扇控制"),
            iconName: "fan",
            iconTint: Color(nsColor: .systemCyan),
            order: 45,
            defaultDescription: localization.string("metadata.description", defaultValue: "管理风扇转速预设")
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
    var onPersistentPreferencesChange: (() -> Void)? {
        get { persistentPreferencesChanges.onChange }
        set { persistentPreferencesChanges.onChange = newValue }
    }

    // MARK: Private State

    let presetStore: FanControlPresetStore
    private let smcReader: any FanControlSMCReading
    private let smcWriter: any FanControlSMCWriting
    private let localization: PluginLocalization
    private let monitoringActiveInterval: Duration
    private let monitoringIdleInterval: Duration
    private let persistentPreferencesChanges = PluginPersistentPreferencesChangeEmitter()

    private var isExpanded = false
    private var isPrimaryPanelVisible = false
    private var fanSnapshot = FanSnapshot.empty
    private enum RetainedError {
        case applyFailed(FanWriteError?, rollbackFailed: Bool)
        case persistenceFailed(rollbackFailed: Bool)
    }

    private var lastError: RetainedError?
    private var lastErrorMessage: String? {
        switch lastError {
        case .applyFailed(let error, let rollbackFailed):
            let message = error?.localizedDescription(localization: localization)
                ?? PluginKitLocalization.actionUnavailable
            return rollbackFailed
                ? localization.format(
                    "error.action.rollbackFailed",
                    defaultValue: "%@；恢复先前风扇策略失败。",
                    message
                )
                : message
        case .persistenceFailed(let rollbackFailed):
            return rollbackFailed
                ? localization.string(
                    "error.action.persistenceRollbackFailed",
                    defaultValue: "无法保存风扇预设，且恢复先前风扇策略失败。"
                )
                : localization.string(
                    "error.action.persistenceFailed",
                    defaultValue: "无法保存风扇预设。"
                )
        case nil:
            return nil
        }
    }
    private var lastApplyError: FanWriteError?
    private var requiresAutoRestore = false
    private var isActivated = false
    private var monitoringTask: Task<Void, Never>?
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?

    // MARK: Init

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "fan-control"),
        smcReader: any FanControlSMCReading = FanControlSMCReader(),
        smcWriter: (any FanControlSMCWriting)? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        monitoringActiveInterval: Duration = .seconds(2),
        monitoringIdleInterval: Duration = .seconds(10)
    ) {
        self.localization = localization
        self.presetStore = FanControlPresetStore(storage: context.storage, localization: localization)
        self.smcReader = smcReader
        self.smcWriter = smcWriter ?? FanControlSMCWriter(
            resourceBundle: context.resourceBundle,
            localization: localization
        )
        self.monitoringActiveInterval = monitoringActiveInterval
        self.monitoringIdleInterval = monitoringIdleInterval
        presetStore.onCatalogChange = { [weak self] in
            self?.onStateChange?()
            self?.persistentPreferencesChanges.didPersist()
        }
        presetStore.onPersistentPreferencesChange = { [weak self] in
            self?.persistentPreferencesChanges.didPersist()
        }
        if presetStore.didPersistPortablePreferencesDuringInitialization {
            persistentPreferencesChanges.didPersist()
        }
    }

    // MARK: - MacToolsPlugin

    func activate(context: PluginRuntimeContext) {
        isActivated = true
        startMonitoring()
        registerSleepWakeObservers()
        // Re-apply the persisted active preset so fan state is consistent
        // even after the app restarts. Skip if already "auto" to avoid
        // spurious admin prompts on launch.
        let preset = presetStore.activePreset
        if case .auto = preset.strategy { return }
        applyActivePreset()
    }

    func deactivate(reason: PluginDeactivationReason) {
        unregisterSleepWakeObservers()
        stopMonitoring()
        isPrimaryPanelVisible = false
        if reason.requiresStateCleanup {
            restoreAutomaticControlIfNeeded(reason: String(describing: reason))
        }
        isActivated = false
    }

    func refresh() {
        fanSnapshot = smcReader.readSnapshot()
        onStateChange?()
    }

    // MARK: - Panel row

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: isExpanded ? buildDetail() : nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.applyPreset),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "fan", "preset", "RPM"],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: ActionParameterID.preset,
                        title: metadata.title,
                        kind: .string
                    ),
                ],
                confirmation: ActionConfirmation(
                    title: metadata.title,
                    message: metadata.defaultDescription,
                    confirmButtonTitle: metadata.title
                ),
                externalInvocationPolicy: .confirmAlways,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        presetStore.allPresets.map { preset in
            ActionCatalogEntry(
                reference: presetActionReference(presetID: preset.id),
                title: "\(metadata.title) · \(preset.displayName(localization: localization))"
            )
        }
    }

    func makePortablePreferencesBackup() -> Data? {
        presetStore.makePortablePreferencesBackup()
    }

    func restorePortablePreferences(from data: Data) {
        _ = restorePortablePreferencesAndReconcileHardware(from: data)
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        restorePortablePreferencesAndReconcileHardware(from: data)
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        presetStore.customPresetIDs(inPortablePreferences: data)?.map {
            presetActionReference(presetID: $0)
        }
    }

    func backupDisposition(
        for reference: ActionReference
    ) -> PluginActionReferenceBackupDisposition {
        guard let preset = preset(for: reference) else { return .excluded }
        return preset.isBuiltIn ? .selfContained : .requiresPluginPreferences
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard preset(for: reference) != nil else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        return .available
    }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(
                id: "built-in-presets",
                title: localization.string("settings.builtIn.title", defaultValue: "内置预设"),
                systemImage: "lock",
                presentation: .edgeToEdge
            ) { [self] _ in
                FanControlPresetManagerView(
                    presetStore: self.presetStore,
                    fanSnapshot: self.fanSnapshot,
                    localization: self.localization,
                    section: .builtIn
                )
            },
            PluginSettingsSection(
                id: "custom-presets",
                title: localization.string("settings.custom.title", defaultValue: "自定义预设"),
                systemImage: "slider.horizontal.3",
                presentation: .edgeToEdge
            ) { [self] _ in
                FanControlPresetManagerView(
                    presetStore: self.presetStore,
                    fanSnapshot: self.fanSnapshot,
                    localization: self.localization,
                    section: .custom
                )
            }
            .headerAccessory { [presetStore, localization] _ in
                Button {
                    FanControlPresetManagerView.addPreset(to: presetStore)
                } label: {
                    Label(
                        localization.string("settings.custom.add", defaultValue: "添加"),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        ])
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            guard isExpanded != expanded else { return }
            isExpanded = expanded
            if !expanded { lastError = nil }
            restartMonitoringIfRunning()
            onStateChange?()

        case let .setSelection(controlID, optionID):
            guard controlID == ControlID.presetList else { return }
            guard let preset = presetStore.allPresets.first(where: { $0.id == optionID }) else { return }
            _ = applyPresetFromAction(preset)

        case let .setSlider(controlID, value, phase):
            guard controlID == ControlID.customSlider, phase == .ended else { return }
            let rpm = Int(value)
            let activeID = presetStore.activePresetID
            applyCustomRPMFromPanel(id: activeID, rpm: rpm)

        case let .invokeAction(controlID):
            handleInvokeAction(controlID)

        case .setSwitch, .setNavigationSelection, .clearNavigationSelection, .setDate:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard let preset = preset(for: invocation.reference) else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        return ActionExecutionHandle { [weak self] in
            self?.applyPresetFromAction(preset)
                ?? .failed(message: PluginKitLocalization.actionUnavailable)
        }
    }

    private func applyPresetFromAction(_ preset: FanPreset) -> ActionExecutionResult {
        let previousPreset = presetStore.activePreset
        guard apply(preset: preset) else {
            let targetError = lastApplyError
            let rollbackSucceeded = lastApplyError?.mayHaveChangedFanState != true
                || apply(preset: previousPreset)
            lastError = .applyFailed(targetError, rollbackFailed: !rollbackSucceeded)
            onStateChange?()
            let failureMessage = lastErrorMessage ?? PluginKitLocalization.actionUnavailable
            return .failed(message: failureMessage)
        }
        guard presetStore.setActivePreset(id: preset.id) else {
            let rollbackSucceeded = apply(preset: previousPreset)
            lastError = .persistenceFailed(rollbackFailed: !rollbackSucceeded)
            onStateChange?()
            let failureMessage = lastErrorMessage ?? PluginKitLocalization.actionUnavailable
            return .failed(message: failureMessage)
        }
        lastError = nil
        onStateChange?()
        return .succeeded()
    }

    private func applyCustomRPMFromPanel(id: String, rpm: Int) {
        guard var targetPreset = presetStore.allPresets.first(where: { $0.id == id }),
              !targetPreset.isBuiltIn else {
            return
        }
        let previousPreset = presetStore.activePreset
        targetPreset.strategy = .fixed(rpm: max(
            FanRPMLimits.absoluteMin,
            min(FanRPMLimits.absoluteMax, rpm)
        ))
        guard apply(preset: targetPreset) else {
            let targetError = lastApplyError
            let rollbackSucceeded = lastApplyError?.mayHaveChangedFanState != true
                || apply(preset: previousPreset)
            lastError = .applyFailed(targetError, rollbackFailed: !rollbackSucceeded)
            onStateChange?()
            return
        }
        guard presetStore.updateCustomPresetRPM(id: id, rpm: rpm) else {
            let rollbackSucceeded = apply(preset: previousPreset)
            lastError = .persistenceFailed(rollbackFailed: !rollbackSucceeded)
            onStateChange?()
            return
        }
        lastError = nil
        onStateChange?()
    }

    // MARK: - Panel visibility

    func panelItemDidBecomeVisible(_ surface: String) {
        guard surface == "control", !isPrimaryPanelVisible else {
            return
        }

        isPrimaryPanelVisible = true
        restartMonitoringIfRunning()
    }

    func panelItemDidBecomeHidden(_ surface: String) {
        guard surface == "control", isPrimaryPanelVisible else {
            return
        }

        isPrimaryPanelVisible = false
        restartMonitoringIfRunning()
    }

    // MARK: - Actions

    private func handleInvokeAction(_ controlID: String) {
        switch controlID {
        case ControlID.addPreset:
            // Navigation to settings page is handled by MenuBarContent;
            // the host intercepts this action ID and calls
            // pluginHost.presentPluginSettings(pluginID: "fan-control").
            break

        case ControlID.deletePreset:
            let idToDelete = presetStore.activePresetID
            guard !presetStore.activePreset.isBuiltIn else { return }
            guard let previousPreferences = presetStore.makePortablePreferencesBackup() else {
                lastError = .persistenceFailed(rollbackFailed: false)
                onStateChange?()
                return
            }
            let previousPreset = presetStore.activePreset
            guard presetStore.deleteCustomPreset(id: idToDelete) else {
                lastError = .persistenceFailed(rollbackFailed: false)
                onStateChange?()
                return
            }
            guard applyActivePreset() else {
                let targetError = lastApplyError
                let preferencesRestored = presetStore.restorePortablePreferences(
                    from: previousPreferences
                )
                let hardwareRestored = preferencesRestored && apply(preset: previousPreset)
                lastError = .applyFailed(targetError, rollbackFailed: !hardwareRestored)
                onStateChange?()
                return
            }
            lastError = nil
            onStateChange?()

        default:
            break
        }
    }

    @discardableResult
    private func applyActivePreset() -> Bool {
        apply(preset: presetStore.activePreset)
    }

    @discardableResult
    private func apply(preset: FanPreset) -> Bool {
        let snapshot = fanSnapshot.fanCount > 0 ? fanSnapshot : smcReader.readSnapshot()
        let result = smcWriter.apply(strategy: preset.strategy, snapshot: snapshot)
        lastApplyError = result
        updateAutoRestoreRequirement(afterApplying: preset.strategy, result: result)
        if let err = result {
            lastError = .applyFailed(err, rollbackFailed: false)
            FanControlLog.plugin.error("Apply preset failed: \(err.localizedDescription, privacy: .public)")
        } else {
            lastError = nil
        }
        onStateChange?()
        return result == nil
    }

    private func restorePortablePreferencesAndReconcileHardware(from data: Data) -> Bool {
        guard let previousPreferences = presetStore.makePortablePreferencesBackup(),
              presetStore.restorePortablePreferences(from: data) else {
            return false
        }
        guard isActivated else { return true }
        guard !applyActivePreset() else { return true }

        let importedPresetError = lastError
        guard presetStore.restorePortablePreferences(from: previousPreferences) else {
            FanControlLog.plugin.error("Failed to roll back fan preferences after restore failure")
            return false
        }
        let didRestoreHardware = applyActivePreset()
        if didRestoreHardware {
            lastError = importedPresetError
            onStateChange?()
        } else {
            FanControlLog.plugin.error("Failed to restore prior fan strategy after restore failure")
        }
        return false
    }

    private func presetActionReference(presetID: String) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.applyPreset),
            parameters: try! ActionParameterSet([
                ActionParameterID.preset: .string(presetID),
            ])
        )
    }

    private func preset(for reference: ActionReference) -> FanPreset? {
        guard reference.key.actionID == ActionID.applyPreset,
              case let .string(presetID)? = reference.parameters[ActionParameterID.preset] else {
            return nil
        }
        return presetStore.allPresets.first(where: { $0.id == presetID })
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                let snapshot = self.smcReader.readSnapshot()
                if self.updateFanSnapshotIfNeeded(snapshot) {
                    self.onStateChange?()
                }
                try? await Task.sleep(for: self.currentMonitoringInterval)
            }
        }
    }

    private func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    private var currentMonitoringInterval: Duration {
        if isPrimaryPanelVisible && isExpanded {
            return monitoringActiveInterval
        }
        return monitoringIdleInterval
    }

    private func updateFanSnapshotIfNeeded(_ snapshot: FanSnapshot) -> Bool {
        guard !fanSnapshot.isMeaningfullyEquivalent(to: snapshot) else {
            return false
        }

        fanSnapshot = snapshot
        return true
    }

    private func restartMonitoringIfRunning() {
        guard monitoringTask != nil else {
            return
        }

        stopMonitoring()
        startMonitoring()
    }

    private func registerSleepWakeObservers() {
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
        let preset = presetStore.activePreset
        guard case .auto = preset.strategy else {
            restoreAutomaticControlIfNeeded(reason: "system sleep")
            return
        }
    }

    private func handleSystemDidWake() {
        fanSnapshot = smcReader.readSnapshot()
        let preset = presetStore.activePreset
        if case .auto = preset.strategy { return }
        applyActivePreset()
        FanControlLog.plugin.info("System did wake — re-applied active preset: \(preset.name, privacy: .public)")
    }

    // MARK: - Panel Builder

    private var panelSubtitle: String {
        let preset = presetStore.activePreset
        if let rpm = fanSnapshot.averageSpeed, rpm > 0 {
            return localization.format(
                "panel.subtitle.withRPM",
                defaultValue: "%@ · %@",
                preset.displayName(localization: localization),
                "\(rpm) RPM"
            )
        }
        return preset.displayName(localization: localization)
    }

    private func buildDetail() -> PluginPanelDetail {
        var controls: [PluginPanelControl] = []

        // 1. Preset select list
        let presetOptions = presetStore.allPresets.map {
            PluginPanelControlOption(
                id: $0.id,
                title: $0.displayName(localization: localization),
                subtitle: presetSubtitle(for: $0)
            )
        }
        controls.append(PluginPanelControl(
            id: ControlID.presetList,
            kind: .selectList,
            options: presetOptions,
            selectedOptionID: presetStore.activePresetID,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            isEnabled: true
        ))

        // 2. Slider for the active custom preset
        let activePreset = presetStore.activePreset
        if case let .fixed(rpm) = activePreset.strategy, !activePreset.isBuiltIn {
            let maxSlider = Double(fanSnapshot.globalMaxSpeed > 0
                ? fanSnapshot.globalMaxSpeed
                : FanRPMLimits.fallbackMax)
            controls.append(PluginPanelControl(
                id: ControlID.customSlider,
                kind: .slider,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: localization.string("panel.slider.targetRPM", defaultValue: "目标转速"),
                sliderValue: Double(rpm),
                sliderBounds: Double(FanRPMLimits.absoluteMin)...maxSlider,
                sliderStep: 100,
                valueLabel: "\(rpm) RPM",
                isEnabled: true
            ))

            // 3. Delete button for custom preset
            controls.append(PluginPanelControl(
                id: ControlID.deletePreset,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: localization.string("panel.action.deletePreset", defaultValue: "删除此预设"),
                actionIconSystemName: "trash",
                isEnabled: true
            ))
        }

        // 4. Add custom preset → opens plugin settings page
        controls.append(PluginPanelControl(
            id: ControlID.addPreset,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.managePresets", defaultValue: "管理预设…"),
            actionIconSystemName: "slider.horizontal.3",
            actionBehavior: .dismissBeforeHandling,
            showsLeadingDivider: true,
            isEnabled: true
        ))

        // 5. Helper-not-found warning
        if !smcWriter.isHelperAvailable {
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
                actionTitle: localization.string("panel.action.missingHelper", defaultValue: "风扇控制组件缺失"),
                actionIconSystemName: "exclamationmark.triangle",
                actionBehavior: .dismissBeforeHandling,
                showsLeadingDivider: true,
                isEnabled: false
            ))
        }

        return PluginPanelDetail(primaryControls: controls, secondaryPanel: nil)
    }

    private func presetSubtitle(for preset: FanPreset) -> String? {
        switch preset.strategy {
        case .auto:
            return localization.string("preset.auto.subtitle", defaultValue: "由 macOS 管理")
        case .fullSpeed:
            let maxRPM = fanSnapshot.globalMaxSpeed
            return maxRPM > 0
                ? localization.format("preset.fullSpeed.subtitleWithRPM", defaultValue: "最高 %d RPM", maxRPM)
                : localization.string("preset.fullSpeed.subtitle", defaultValue: "最高转速")
        case .fixed(let rpm):
            return "\(rpm) RPM"
        }
    }

    private func updateAutoRestoreRequirement(afterApplying strategy: FanControlStrategy, result: FanWriteError?) {
        switch strategy {
        case .auto:
            if result == nil {
                requiresAutoRestore = false
            }
        case .fullSpeed, .fixed:
            if result == nil || result?.mayHaveChangedFanState == true {
                requiresAutoRestore = true
            }
        }
    }

    private func restoreAutomaticControlIfNeeded(reason: String) {
        guard requiresAutoRestore else {
            FanControlLog.plugin.info("Skipped fan auto restore for \(reason, privacy: .public); no successful manual fan write in this session")
            return
        }

        guard smcWriter.isInstalledHelperAvailable else {
            FanControlLog.plugin.info("Skipped fan auto restore for \(reason, privacy: .public); SMC helper is not installed")
            return
        }

        let snapshot = fanSnapshot.fanCount > 0 ? fanSnapshot : smcReader.readSnapshot()
        let result = smcWriter.apply(strategy: .auto, snapshot: snapshot)
        updateAutoRestoreRequirement(afterApplying: .auto, result: result)

        if let result {
            FanControlLog.plugin.error("Failed to restore fan control to auto for \(reason, privacy: .public): \(result.localizedDescription, privacy: .public)")
        } else {
            FanControlLog.plugin.info("Restored fan control to auto for \(reason, privacy: .public)")
        }
    }
}

private extension FanWriteError {
    var mayHaveChangedFanState: Bool {
        if case .writeFailed = self {
            return true
        }

        return false
    }
}
