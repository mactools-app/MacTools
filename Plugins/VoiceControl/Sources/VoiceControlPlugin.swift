import AppKit
import AVFoundation
import ApplicationServices
import MacToolsPluginKit
import SwiftUI

public final class VoiceControlPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        VoiceControlProvider(context: context)
    }
}

@MainActor private struct VoiceControlProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] { [VoiceControlPlugin(context: context)] }
}

@MainActor
final class VoiceControlPlugin: ObservableObject, MacToolsPlugin, PluginSettingsPresenting,
    PluginVoiceControlHostContextConsuming, PluginApplicationActivityStateHandling, PluginGroupedShortcutSettingsProviding,
    PluginActionProviding, PluginActionExposureProviding, PluginVoiceSelfActionProviding,
    PluginVoiceConfirmationPresenting, PluginVoiceFunctionProviding,
    PluginVoiceSelfParameterizedActionProviding, PluginActionPermissionProviding, PluginActionConfirmationProviding,
    PluginPortablePreferencesProviding, PluginPortablePreferencesRestorationReporting,
    PluginPersistentPreferencesChangeSignaling {
    let conversation: VoiceConversation
    let assistant: VoiceAssistantPanel
    let computerUse: ComputerUseController
    let computerTasks: ComputerTaskController
    @Published private(set) var allowsAppReading: Bool
    private let storage: any PluginStorage
    private var allowsRecording = true
    var onStateChange: (() -> Void)?
    var onPersistentPreferencesChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?
    var voiceControlHostContext: PluginVoiceControlHostContext? {
        get { conversation.context }
        set { conversation.context = newValue }
    }
    var metadata: PluginMetadata {
        .init(id: "voice-control", title: conversation.text("语音助手"), iconName: "waveform", iconTint: .purple,
              order: 102, defaultDescription: conversation.text("通过语音对话控制已启用的 MacTools 功能"))
    }
    init(context: PluginRuntimeContext, conversation providedConversation: VoiceConversation? = nil) {
        storage = context.storage
        // Device-local consent must never be inferred from the older feature switch.
        allowsAppReading = context.storage.integer(forKey: "computerReadConsentVersion") == 1
        conversation = providedConversation ?? VoiceConversation(context: context)
        let library = context.resourceBundle.bundleURL.appendingPathComponent("Contents/Frameworks/libcua_driver_sdk.dylib")
        computerUse = ComputerUseController(runtime: CuaRuntime(libraryURL: library), environment: SystemComputerUseEnvironment())
        computerTasks = ComputerTaskController(computer: computerUse)
        computerUse.enabled = storage.object(forKey: "computerInteractionEnabled") == nil
            ? true : storage.bool(forKey: "computerInteractionEnabled")
        conversation.featureAccess = .init(
            automaticallyAllowNewPlugins: storage.object(forKey: "automaticallyAllowNewPlugins") == nil
                ? true : storage.bool(forKey: "automaticallyAllowNewPlugins"),
            excludedPluginIDs: Set(storage.stringArray(forKey: "excludedProviders") ?? []),
            approvedPluginIDs: Set(storage.stringArray(forKey: "approvedProviders") ?? []))
        assistant = VoiceAssistantPanel(conversation: conversation)
        assistant.openSettings = { [weak self] in self?.requestSettingsPresentation?() }
        conversation.onChange = { [weak self] in self?.onStateChange?() }
        conversation.onStop = { [weak self] in self?.computerTasks.stop() }
        conversation.computerTaskSetupBlocker = { [weak self] in self?.computerTaskSetupBlocker }
        computerUse.onInspectionActivity = { [weak model = self.conversation] app in model?.setReadingApp(app) }
        computerTasks.onProgress = { [weak model = self.conversation] task in model?.setComputerTask(task) }
        assistant.cancelComputerTask = { [weak self] in
            self?.conversation.approvals.cancel(); self?.computerTasks.stop()
        }
    }
    var panelItems: [PluginPanelItem] {
        [.row(id: "conversation", initialPlacement: .featurePanel,
              descriptor: .init(controlStyle: .button, menuActionBehavior: .dismissBeforeHandling,
                                buttonTitleProvider: { [weak self] in self?.conversation.text("打开对话") ?? "" }),
              state: .init(subtitle: conversation.text(conversation.status), isOn: conversation.active,
                           isEnabled: true, isAvailable: true, detail: nil, errorMessage: nil),
              action: { [weak self] action in if case .invokeAction = action { self?.toggleAssistant() } })]
    }
    var shortcutDefinitions: [PluginShortcutDefinition] {
        [shortcut(id: "toggle-assistant", title: "显示或关闭助手"),
         shortcut(id: "dismiss-assistant", title: "停止并关闭助手")]
    }
    var shortcutSettingsGroups: [PluginShortcutSettingsGroupConfiguration] {
        [.init(id: "conversation", title: conversation.text("快捷键"),
               shortcutDefinitionIDs: ["toggle-assistant", "dismiss-assistant"])]
    }
    private func shortcut(id: String, title: String) -> PluginShortcutDefinition {
        .init(id: id, title: conversation.text(title), description: conversation.text(id == "dismiss-assistant" ? "可选的独立快捷键，用于停止录音并关闭助手。" : "隐藏时开始聆听，再按一次停止并关闭。"),
              actionID: id, scope: .global, defaultBinding: nil, isRequired: false)
    }
    func handleShortcutAction(id: String) {
        if id == "toggle-assistant" { toggleAssistant() }
        if id == "dismiss-assistant" { assistant.dismiss() }
    }
    func toggleAssistant() { guard allowsRecording else { return }; assistant.toggle() }
    func confirmVoiceAction(_ request: PluginVoiceConfirmationRequest) async -> Bool {
        guard allowsRecording, conversation.active, conversation.connected, !Task.isCancelled else { return false }
        assistant.present()
        return await conversation.approvals.confirm(request)
    }
    var voiceFunctions: [PluginVoiceFunction] {
        computerTaskDefinitions.map {
            .init(actionID: $0.key.actionID, name: $0.key.actionID.replacingOccurrences(of: "-", with: "_"))
        }
    }
    var permissionRequirements: [PluginPermissionRequirement] {
        [.init(id: "microphone", kind: .microphone, title: conversation.text("麦克风"),
               description: conversation.text("仅在开始对话后录音，并发送到 OpenAI 处理。")),
         .init(id: "accessibility", kind: .accessibility, title: conversation.text("辅助功能"),
               description: conversation.text("用于按请求读取和操作应用控件。剪贴板与打开网页无需此权限。"))]
    }
    func permissionState(for permissionID: String) -> PluginPermissionState {
        if permissionID == "accessibility" { return .init(isGranted: AXIsProcessTrusted(), footnote: nil) }
        return .init(isGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, footnote: nil)
    }
    func handlePermissionAction(id: String) {
        if id == "accessibility" {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
            return
        }
        guard id == "microphone" else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { @MainActor [weak self] in _ = await AVCaptureDevice.requestAccess(for: .audio); self?.onStateChange?() }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    func refresh() { onStateChange?() }
    func deactivate(reason: PluginDeactivationReason) { assistant.tearDown(); computerTasks.stop() }
    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        allowsRecording = state.allowsBackgroundWork
        if !allowsRecording { conversation.stop() }
    }
    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            .init(id: "credentials", title: conversation.text("OpenAI 连接"), systemImage: "key",
                  footer: conversation.text("密钥仅保存在本机钥匙串，费用由你的 OpenAI 账户承担。")) { [weak self] _ in
                if let self { VoiceKeySettings(model: conversation) }
            },
            .init(id: "conversation", title: conversation.text("对话"), systemImage: "waveform",
                  embeddedShortcutGroupIDs: ["conversation"]) { [weak self] context in
                if let self { VoiceConversationSettings(plugin: self, model: conversation, context: context) }
            },
            .init(id: "scope", title: conversation.text("允许的功能"), systemImage: "checkmark.shield",
                  footer: conversation.text("对话音频和请求的功能数据会发送到 OpenAI，使用你的 API 额度。回复由 AI 生成；停止、锁屏或睡眠时结束录音。")) { [weak self] _ in
                if let self { VoiceScopeSettings(plugin: self, model: conversation) }
            },
            .init(id: "computer-interaction", title: conversation.text("电脑交互"), systemImage: "cursorarrow") { [weak self] _ in
                if let self { VoiceComputerSettings(plugin: self, model: conversation) }
            }
        ])
    }
    private enum AccessAction {
        static let enable = "automatic-plugin-access-on"
        static let disable = "automatic-plugin-access-off"
    }
    var voiceSelfActionIDs: Set<String> { [AccessAction.enable, AccessAction.disable] }
    var voiceParameterizedActionIDs: Set<String> { voiceSelfParameterizedActionIDs }
    var voiceSelfParameterizedActionIDs: Set<String> {
        computerUse.enabled ? Set(computerActionDefinitions.map(\.key.actionID)) : []
    }
    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        Self.computerUIActionIDs.contains(actionKey.actionID) ? ["accessibility"] : []
    }
    var actionDefinitions: [ActionDefinition] {
        [true, false].map { enabled -> ActionDefinition in
            .init(key: .init(providerID: metadata.id, actionID: enabled ? AccessAction.enable : AccessAction.disable),
                  title: conversation.text(enabled ? "自动允许新安装的插件" : "停止自动允许新安装的插件"),
                  description: conversation.text(enabled
                      ? "新插件将在后续对话中自动可用，已禁止的插件和当前对话不受影响。"
                      : "新插件需手动允许，当前选择和正在进行的对话不受影响。"),
                  keywords: ["new plugins", "automatic access", "automatically allow", "future plugin permissions"],
                  systemImage: "checkmark.shield",
                  risk: enabled ? .confirmationRequired : .safe,
                  confirmation: enabled ? .init(title: conversation.text("自动允许新安装的插件"),
                      message: conversation.text("新插件将在后续对话中自动可用，已禁止的插件和当前对话不受影响。"),
                      confirmButtonTitle: conversation.text("开启")) : nil,
                  capabilities: [.foregroundInteractive, .cancellable])
        } + computerActionDefinitions
    }
    var actionCatalogEntries: [ActionCatalogEntry] {
        actionDefinitions.filter { $0.parameters.isEmpty }.map { .init(reference: .init(key: $0.key), title: $0.title, subtitle: metadata.title) }
    }
    func exposurePolicy(for reference: ActionReference, on surface: ActionExposureSurface) -> ActionExposurePolicy {
        guard reference.key.providerID == metadata.id else { return .excluded }
        guard surface.rawValue == "voice-control" else { return .automatic }
        return voiceSelfActionIDs.union(voiceSelfParameterizedActionIDs).contains(reference.key.actionID) ? .automatic : .excluded
    }
    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        if reference.key.providerID == metadata.id, reference.key.actionID.hasPrefix("computer-") {
            guard allowsRecording, !conversation.credentialBusy else { return .unavailable("Assistant is stopped.") }
            return computerActionAvailability(reference)
        }
        guard reference.key.providerID == metadata.id, voiceSelfActionIDs.contains(reference.key.actionID),
              reference.parameters.entries.isEmpty, allowsRecording, !conversation.credentialBusy else {
            return .init(isAvailable: false)
        }
        return .available
    }
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let reference = invocation.reference
        let revision = conversation.sessionRevision
        if reference.key.actionID.hasPrefix("computer-") {
            let computerAction = String(reference.key.actionID.dropFirst("computer-".count))
            if ComputerTaskController.actions.contains(computerAction) {
                guard actionAvailability(for: reference).isAvailable else { throw ComputerUseError.unavailable("This operation requires an active conversation and its declared permissions.") }
                let admission = try computerTasks.admission(computerAction, reference.parameters)
                return .init { [weak self] in
                    guard let self, !Task.isCancelled, conversation.sessionRevision == revision,
                          actionAvailability(for: reference).isAvailable else { return .cancelled }
                    do {
                        let result = try await computerTasks.perform(computerAction, reference.parameters, admission: admission)
                        guard !Task.isCancelled, conversation.sessionRevision == revision else { return .cancelled }
                        return .succeeded(message: result)
                    } catch is CancellationError { return .cancelled }
                    catch { return .failed(message: error.localizedDescription) }
                }
            }
            // Setup consent replaces read dialogs, not target binding or host admission.
            let inspectionTarget: ComputerUseTarget?
            if reference.key.actionID == "computer-inspect-app" {
                guard actionAvailability(for: reference).isAvailable else { throw ComputerUseError.unavailable("App reading is not authorized for this conversation.") }
                _ = try computerUse.prepareApproval("inspect-app", parameters: reference.parameters)
                inspectionTarget = computerUse.preparedInspectionTarget(reference.parameters)
            } else { inspectionTarget = nil }
            return .init { [weak self] in
                guard let self, !Task.isCancelled, conversation.sessionRevision == revision,
                      actionAvailability(for: reference).isAvailable else { return .cancelled }
                do {
                    let result = try await computerUse.perform(String(reference.key.actionID.dropFirst("computer-".count)),
                        parameters: reference.parameters, inspectionTarget: inspectionTarget)
                    guard !Task.isCancelled, conversation.sessionRevision == revision else { return .cancelled }
                    return result.verified ? .succeeded(message: result.message) : .failed(message: result.message)
                } catch is CancellationError { return .cancelled }
                catch { return .failed(message: error.localizedDescription) }
            }
        }
        return .init { [weak self] in
            guard !Task.isCancelled, let self, conversation.sessionRevision == revision,
                  actionAvailability(for: reference).isAvailable else { return .cancelled }
            var updated = conversation.featureAccess
            updated.setAutomaticallyAllowNewPlugins(reference.key.actionID == AccessAction.enable,
                currentPluginIDs: Set(conversation.context?.providers().map(\.id) ?? []))
            commitFeatureAccess(updated)
            return .succeeded(message: conversation.text("已保存，新插件的访问策略将在后续对话生效。"))
        }
    }
    func setComputerInteraction(_ enabled: Bool) {
        guard !conversation.active, !conversation.credentialBusy else { return }
        computerTasks.stop()
        computerUse.enabled = enabled
        storage.set(enabled, forKey: "computerInteractionEnabled")
        onStateChange?()
    }
    var canReadAppContent: Bool { allowsAppReading && computerUse.enabled && allowsRecording && conversation.active }
    func setAppReadingConsent(_ allowed: Bool) {
        guard !conversation.credentialBusy, allowed != allowsAppReading,
              !allowed || (!conversation.active && computerUse.enabled) else { return }
        if conversation.active { conversation.stop() } else { computerTasks.stop() }
        allowsAppReading = allowed
        storage.set(allowed ? 1 : 0, forKey: "computerReadConsentVersion")
        onStateChange?()
    }
    func setProviderAccess(_ access: [String: Bool], automaticallyAllowNewPlugins: Bool? = nil) {
        guard !conversation.active, !conversation.credentialBusy else { return }
        let available = Set(conversation.context?.providers().map(\.id) ?? [])
        var updated = conversation.featureAccess
        if let automaticallyAllowNewPlugins {
            updated.setAutomaticallyAllowNewPlugins(automaticallyAllowNewPlugins, currentPluginIDs: available)
        }
        for (id, allowed) in access where available.contains(id) {
            guard updated.isAllowed(id) != allowed else { continue }
            updated.setAllowed(allowed, for: [id])
        }
        commitFeatureAccess(updated)
    }
    func setIdleTimeout(_ timeout: VoiceIdleTimeout) {
        guard !conversation.active, !conversation.credentialBusy, conversation.idleTimeout != timeout else { return }
        conversation.idleTimeout = timeout
        storage.set(timeout.rawValue, forKey: "idleTimeoutSeconds")
        onPersistentPreferencesChange?()
    }
    func setConnectOnSpeech(_ enabled: Bool) {
        guard !conversation.active, !conversation.credentialBusy, conversation.connectOnSpeech != enabled else { return }
        conversation.connectOnSpeech = enabled
        storage.set(enabled, forKey: "connectOnSpeech")
        onPersistentPreferencesChange?()
    }
    private func commitFeatureAccess(_ updated: VoiceFeatureAccess) {
        guard updated != conversation.featureAccess else { return }
        conversation.featureAccess = updated
        persistFeatureAccess()
        // Access affects the next session, not host commands or panel declarations.
        // Notify backup once per edit session without rebuilding the host UI.
        onPersistentPreferencesChange?()
    }
    private func persistFeatureAccess() {
        let access = conversation.featureAccess
        storage.set(access.excludedPluginIDs.sorted(), forKey: "excludedProviders")
        storage.set(access.automaticallyAllowNewPlugins, forKey: "automaticallyAllowNewPlugins")
        storage.set(access.approvedPluginIDs.sorted(), forKey: "approvedProviders")
    }
    private struct Preferences: Codable {
        let version: Int
        let excludedProviders: [String]
        let automaticallyAllowNewPlugins: Bool?
        let approvedProviders: [String]?
        let idleTimeoutSeconds: Int?
        let connectOnSpeech: Bool?
    }
    func makePortablePreferencesBackup() -> Data? {
        let access = conversation.featureAccess
        return try? JSONEncoder().encode(Preferences(version: 4,
            excludedProviders: access.excludedPluginIDs.sorted(),
            automaticallyAllowNewPlugins: access.automaticallyAllowNewPlugins,
            approvedProviders: access.approvedPluginIDs.sorted(), idleTimeoutSeconds: conversation.idleTimeout.rawValue, connectOnSpeech: conversation.connectOnSpeech))
    }
    func restorePortablePreferences(from data: Data) { _ = restorePortablePreferencesReportingResult(from: data) }
    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard !conversation.active, data.count <= 32_768,
              let value = try? JSONDecoder().decode(Preferences.self, from: data),
              (1...4).contains(value.version),
              value.version < 4 || value.connectOnSpeech != nil,
              value.version == 1 || (value.automaticallyAllowNewPlugins != nil && value.approvedProviders != nil),
              [value.excludedProviders, value.approvedProviders ?? []].allSatisfy({ ids in
                  ids.count <= 256 && ids.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 }
              }) else { return false }
        let timeout: VoiceIdleTimeout
        if value.version >= 3 {
            guard let seconds = value.idleTimeoutSeconds, let restored = VoiceIdleTimeout(rawValue: seconds) else { return false }
            timeout = restored
        } else { timeout = conversation.idleTimeout }
        conversation.featureAccess = .init(
            automaticallyAllowNewPlugins: value.version == 1 ? true : value.automaticallyAllowNewPlugins ?? false,
            excludedPluginIDs: Set(value.excludedProviders),
            approvedPluginIDs: value.version == 1 ? [] : Set(value.approvedProviders ?? []))
        persistFeatureAccess()
        conversation.connectOnSpeech = value.version == 4 ? value.connectOnSpeech ?? true : conversation.connectOnSpeech
        storage.set(conversation.connectOnSpeech, forKey: "connectOnSpeech")
        conversation.idleTimeout = timeout
        storage.set(timeout.rawValue, forKey: "idleTimeoutSeconds")
        onPersistentPreferencesChange?(); onStateChange?()
        return true
    }
}
