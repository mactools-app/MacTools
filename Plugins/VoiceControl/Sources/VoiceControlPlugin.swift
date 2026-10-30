import AppKit
import AVFoundation
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
final class VoiceControlPlugin: MacToolsPlugin, PluginSettingsPresenting,
    PluginVoiceControlHostContextConsuming, PluginApplicationActivityStateHandling, PluginGroupedShortcutSettingsProviding,
    PluginActionProviding, PluginActionExposureProviding, PluginVoiceSelfActionProviding,
    PluginPortablePreferencesProviding, PluginPortablePreferencesRestorationReporting,
    PluginPersistentPreferencesChangeSignaling {
    let conversation: VoiceConversation
    let assistant: VoiceAssistantPanel
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
        .init(id: "voice-control", title: conversation.text("语音控制"), iconName: "waveform", iconTint: .purple,
              order: 102, defaultDescription: conversation.text("通过语音对话控制已启用的 MacTools 功能"))
    }
    init(context: PluginRuntimeContext, conversation providedConversation: VoiceConversation? = nil) {
        storage = context.storage
        conversation = providedConversation ?? VoiceConversation(context: context)
        conversation.featureAccess = .init(
            automaticallyAllowNewPlugins: storage.object(forKey: "automaticallyAllowNewPlugins") == nil
                ? true : storage.bool(forKey: "automaticallyAllowNewPlugins"),
            excludedPluginIDs: Set(storage.stringArray(forKey: "excludedProviders") ?? []),
            approvedPluginIDs: Set(storage.stringArray(forKey: "approvedProviders") ?? []))
        assistant = VoiceAssistantPanel(conversation: conversation)
        assistant.openSettings = { [weak self] in self?.requestSettingsPresentation?() }
        conversation.onChange = { [weak self] in self?.onStateChange?() }
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
               shortcutDefinitionIDs: ["toggle-assistant", "dismiss-assistant"], placementAfterSectionID: "credentials")]
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
    var permissionRequirements: [PluginPermissionRequirement] {
        [.init(id: "microphone", kind: .microphone, title: conversation.text("麦克风"),
               description: conversation.text("仅在开始对话后录音，并发送到 OpenAI 处理。"))]
    }
    func permissionState(for permissionID: String) -> PluginPermissionState {
        .init(isGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, footnote: nil)
    }
    func handlePermissionAction(id: String) {
        guard id == "microphone" else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { @MainActor [weak self] in _ = await AVCaptureDevice.requestAccess(for: .audio); self?.onStateChange?() }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    func refresh() { onStateChange?() }
    func deactivate(reason: PluginDeactivationReason) { assistant.tearDown() }
    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        allowsRecording = state.allowsBackgroundWork
        if !allowsRecording { conversation.stop() }
    }
    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            .init(id: "credentials", title: conversation.text("你的 OpenAI API 密钥"), systemImage: "key",
                  footer: conversation.text("使用你自己的 OpenAI 账户计费。在这里保存的密钥仅存于本机钥匙串，不会包含在 App 或开源代码中。")) { [conversation] _ in
                VoiceKeySettings(model: conversation)
            },
            .init(id: "audio", title: conversation.text("音频"), systemImage: "speaker.wave.2",
                  footer: conversation.text("对话音频和请求的功能数据会发送到 OpenAI，使用你的 API 额度。回复由 AI 生成；停止、锁屏或睡眠时结束录音。"), rows: [
                .init(id: "test-speaker", title: conversation.text("扬声器"),
                      description: conversation.text("播放提示音以检查当前输出设备。"),
                      control: .action(title: conversation.text("测试扬声器"), role: .normal))
            ]),
            .init(id: "scope", title: conversation.text("允许的功能"), systemImage: "checkmark.shield",
                  footer: conversation.text("选择助手可使用的功能。更改将在下一次对话生效。")) { [weak self] _ in
                if let self { VoiceScopeSettings(plugin: self, model: conversation) }
            }
        ])
    }
    func handleSettingsAction(_ action: PluginSettingsAction) {
        if case .invoke(controlID: "test-speaker") = action { conversation.testSpeaker() }
    }

    private enum AccessAction {
        static let enable = "automatic-plugin-access-on"
        static let disable = "automatic-plugin-access-off"
    }
    var voiceSelfActionIDs: Set<String> { [AccessAction.enable, AccessAction.disable] }
    var actionDefinitions: [ActionDefinition] {
        [true, false].map { enabled in
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
                  capabilities: [.foregroundInteractive])
        }
    }
    var actionCatalogEntries: [ActionCatalogEntry] {
        actionDefinitions.map { .init(reference: .init(key: $0.key), title: $0.title, subtitle: metadata.title) }
    }
    func exposurePolicy(for reference: ActionReference, on surface: ActionExposureSurface) -> ActionExposurePolicy {
        guard reference.key.providerID == metadata.id else { return .excluded }
        guard surface.rawValue == "voice-control" else { return .automatic }
        return voiceSelfActionIDs.contains(reference.key.actionID) ? .automatic : .excluded
    }
    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.providerID == metadata.id, voiceSelfActionIDs.contains(reference.key.actionID),
              reference.parameters.entries.isEmpty, allowsRecording, !conversation.credentialBusy else {
            return .init(isAvailable: false)
        }
        return .available
    }
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let reference = invocation.reference
        return .init { [weak self] in
            guard let self, actionAvailability(for: reference).isAvailable else { return .cancelled }
            var updated = conversation.featureAccess
            updated.setAutomaticallyAllowNewPlugins(reference.key.actionID == AccessAction.enable,
                currentPluginIDs: Set(conversation.context?.providers().map(\.id) ?? []))
            commitFeatureAccess(updated)
            return .succeeded(message: conversation.text("已保存，新插件的访问策略将在后续对话生效。"))
        }
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
    }
    func makePortablePreferencesBackup() -> Data? {
        let access = conversation.featureAccess
        return try? JSONEncoder().encode(Preferences(version: 2,
            excludedProviders: access.excludedPluginIDs.sorted(),
            automaticallyAllowNewPlugins: access.automaticallyAllowNewPlugins,
            approvedProviders: access.approvedPluginIDs.sorted()))
    }
    func restorePortablePreferences(from data: Data) { _ = restorePortablePreferencesReportingResult(from: data) }
    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard !conversation.active, data.count <= 32_768,
              let value = try? JSONDecoder().decode(Preferences.self, from: data),
              value.version == 1 || value.version == 2,
              value.version == 1 || (value.automaticallyAllowNewPlugins != nil && value.approvedProviders != nil),
              [value.excludedProviders, value.approvedProviders ?? []].allSatisfy({ ids in
                  ids.count <= 256 && ids.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 }
              }) else { return false }
        conversation.featureAccess = .init(
            automaticallyAllowNewPlugins: value.version == 1 ? true : value.automaticallyAllowNewPlugins ?? false,
            excludedPluginIDs: Set(value.excludedProviders),
            approvedPluginIDs: value.version == 1 ? [] : Set(value.approvedProviders ?? []))
        persistFeatureAccess()
        onPersistentPreferencesChange?(); onStateChange?()
        return true
    }
}
