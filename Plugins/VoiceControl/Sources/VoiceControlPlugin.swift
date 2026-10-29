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
    PluginVoiceControlHostContextConsuming, PluginApplicationActivityStateHandling,
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
    init(context: PluginRuntimeContext) {
        storage = context.storage
        conversation = VoiceConversation(context: context)
        conversation.excludedPluginIDs = Set(storage.stringArray(forKey: "excludedProviders") ?? [])
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
    private func shortcut(id: String, title: String) -> PluginShortcutDefinition {
        .init(id: id, title: conversation.text(title), description: conversation.text(id == "dismiss-assistant" ? "停止并关闭助手" : "隐藏时开始聆听，再按一次停止并关闭。"),
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
            .init(id: "credentials", title: conversation.text("你的 OpenAI API 密钥"), systemImage: "key") { [conversation] _ in
                VoiceKeySettings(model: conversation)
            },
            .init(id: "scope", title: conversation.text("允许的功能"), systemImage: "checkmark.shield",
                  footer: conversation.text("本次对话只使用下面勾选的功能。修改后在下一次对话生效。")) { [weak self] _ in
                if let self { VoiceScopeSettings(plugin: self, model: conversation) }
            }
        ])
    }
    func setProvider(_ id: String, allowed: Bool) {
        guard !conversation.active else { return }
        if allowed { conversation.excludedPluginIDs.remove(id) } else { conversation.excludedPluginIDs.insert(id) }
        storage.set(conversation.excludedPluginIDs.sorted(), forKey: "excludedProviders")
        onPersistentPreferencesChange?(); onStateChange?()
    }
    private struct Preferences: Codable { let version: Int; let excludedProviders: [String] }
    func makePortablePreferencesBackup() -> Data? {
        try? JSONEncoder().encode(Preferences(version: 1, excludedProviders: conversation.excludedPluginIDs.sorted()))
    }
    func restorePortablePreferences(from data: Data) { _ = restorePortablePreferencesReportingResult(from: data) }
    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard !conversation.active, data.count <= 16_384,
              let value = try? JSONDecoder().decode(Preferences.self, from: data), value.version == 1,
              value.excludedProviders.count <= 256,
              value.excludedProviders.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { return false }
        conversation.excludedPluginIDs = Set(value.excludedProviders)
        storage.set(conversation.excludedPluginIDs.sorted(), forKey: "excludedProviders")
        onPersistentPreferencesChange?(); onStateChange?()
        return true
    }
}
