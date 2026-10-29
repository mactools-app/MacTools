import MacToolsPluginKit
import SwiftUI

@MainActor
struct VoiceKeySettings: View {
    @ObservedObject var model: VoiceConversation
    @State private var draftKey = ""
    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text(model.text(model.credentialStatus)).font(PluginSettingsTheme.Typography.rowTitle)
            HStack {
                SecureField(model.text("粘贴你的 API 密钥"), text: $draftKey)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 160, idealWidth: 300, maxWidth: .infinity)
                    .onSubmit { save() }
                Button(model.text("保存密钥")) { save() }.disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(model.text("忘记密钥")) { model.forgetKey(); draftKey = "" }.disabled(!model.hasCredentials)
            }.disabled(model.active).buttonStyle(.bordered).controlSize(.small)
            Text(model.text("使用你自己的 OpenAI 账户计费。在这里保存的密钥仅存于本机钥匙串，不会包含在 App 或开源代码中。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            Text(model.text("对话音频和请求的功能数据会发送到 OpenAI，使用你的 API 额度。回复由 AI 生成；停止、锁屏或睡眠时结束录音。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            if let message = model.credentialMessage {
                Text(model.text(message)).font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(model.credentialError ? Color.red : Color.secondary)
            }
            #if DEBUG
            DisclosureGroup(model.text("开发选项：使用已有密钥文件")) {
                HStack {
                    Text(model.credentialPath ?? model.text("只保存文件位置，不复制文件中的密钥。"))
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(model.text("选择文件…")) { model.chooseCredentials(); draftKey = "" }.disabled(model.active)
                }.font(PluginSettingsTheme.Typography.rowDescription)
            }
            #endif
            Button(model.text("测试扬声器")) { model.testSpeaker() }.controlSize(.small)
        }.onDisappear { draftKey = "" }
    }
    private func save() { if model.saveKey(draftKey) { draftKey = "" } }
}

@MainActor
struct VoiceScopeSettings: View {
    let plugin: VoiceControlPlugin
    @ObservedObject var model: VoiceConversation
    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            ForEach(model.context?.providers() ?? []) { provider in
                Toggle(provider.title, isOn: Binding(get: { !model.excludedPluginIDs.contains(provider.id) },
                                                    set: { plugin.setProvider(provider.id, allowed: $0) }))
                    .toggleStyle(.checkbox).disabled(model.active)
            }
        }
    }
}
