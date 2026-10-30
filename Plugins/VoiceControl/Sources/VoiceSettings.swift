import MacToolsPluginKit
import SwiftUI

@MainActor
struct VoiceKeySettings: View {
    @ObservedObject var model: VoiceConversation
    @State private var draftKey = ""
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Label(model.text(model.credentialStatus), systemImage: "key")
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .accessibilityIdentifier("voice-control.credential-status")
                Spacer(minLength: 12)
                if model.credentialBusy { ProgressView().controlSize(.small) }
                if model.hasCredentials && !editing {
                    Button(model.text("更换密钥…")) { editing = true }
                        .accessibilityIdentifier("voice-control.replace-key")
                }
                Menu {
                    if model.hasCredentials {
                        Button(model.text("忘记密钥"), role: .destructive) {
                            Task { await model.forgetKey(); draftKey = "" }
                        }
                        Divider()
                    }
                    Section(model.text("故障排查")) {
                        Button(model.text("测试扬声器")) { model.testSpeaker() }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(model.text("连接选项"))
                .accessibilityIdentifier("voice-control.connection-options")
            }.disabled(model.active || model.credentialBusy)
            if editing || !model.hasCredentials {
                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    SecureField("", text: $draftKey, prompt: Text(model.text("粘贴你的 API 密钥")))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180, idealWidth: 320, maxWidth: 440)
                        .accessibilityLabel(model.text("粘贴你的 API 密钥"))
                        .accessibilityIdentifier("voice-control.key-input")
                        .onSubmit { save() }
                    Button(model.text("保存密钥")) { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("voice-control.save-key")
                    if model.hasCredentials {
                        Button(model.text("取消")) { draftKey = ""; editing = false }
                            .accessibilityIdentifier("voice-control.cancel-key-edit")
                    }
                }.disabled(model.active || model.credentialBusy)
            }
            if let message = model.credentialMessage {
                Text(model.text(message)).font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(model.credentialError ? Color.red : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.bordered).controlSize(.small)
        .onDisappear { draftKey = ""; editing = false }
    }
    private func save() {
        let key = draftKey
        Task { if await model.saveKey(key) { draftKey = ""; editing = false } }
    }
}

@MainActor
struct VoiceScopeSettings: View {
    let plugin: VoiceControlPlugin
    @ObservedObject var model: VoiceConversation
    @State private var showsFeatures = false
    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Toggle(model.text("自动允许新安装的插件"), isOn: Binding(
                get: { model.featureAccess.automaticallyAllowNewPlugins },
                set: { plugin.setProviderAccess([:], automaticallyAllowNewPlugins: $0) }))
                .toggleStyle(.switch)
                .font(PluginSettingsTheme.Typography.rowTitle)
                .disabled(model.active || model.credentialBusy)
                .accessibilityIdentifier("voice-control.automatically-allow-new-plugins")
            Text(model.text("关闭后保留当前选择，新插件需手动允许。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            HStack {
                Text(voiceAccessSummary(model)).font(PluginSettingsTheme.Typography.rowTitle)
                Spacer(minLength: 12)
                Button(model.text("管理功能…")) { showsFeatures = true }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("voice-control.manage-features")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showsFeatures) { VoiceFeatureAccessSheet(plugin: plugin, model: model) }
    }
}

@MainActor
private func voiceAccessSummary(_ model: VoiceConversation) -> String {
    let providers = model.context?.providers() ?? []
    let allowed = providers.filter { model.featureAccess.isAllowed($0.id) }.count
    return String.localizedStringWithFormat(model.text("已允许 %lld 项，共 %lld 项"), allowed, providers.count)
}

/// Keep switch edits local: provider discovery and preference backups must not run per click.
@MainActor
final class VoiceFeatureAccessDraft: ObservableObject {
    let providers: [PluginVoiceProvider]
    private let originalAccess: VoiceFeatureAccess
    @Published private(set) var featureAccess: VoiceFeatureAccess

    init(providers: [PluginVoiceProvider], featureAccess: VoiceFeatureAccess) {
        self.providers = providers.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        originalAccess = featureAccess
        self.featureAccess = featureAccess
    }
    var allowedCount: Int { providers.filter { isAllowed($0.id) }.count }
    var access: [String: Bool] { Dictionary(uniqueKeysWithValues: providers.map { ($0.id, isAllowed($0.id)) }) }
    var changes: [String: Bool] {
        access.filter { originalAccess.isAllowed($0.key) != $0.value }
    }
    func isAllowed(_ id: String) -> Bool { featureAccess.isAllowed(id) }
    func matches(_ query: String) -> [PluginVoiceProvider] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return providers.filter { search.isEmpty || $0.title.localizedStandardContains(search) }
    }
    func setAllowed(_ allowed: Bool, for providers: [PluginVoiceProvider]) {
        guard providers.contains(where: { isAllowed($0.id) != allowed }) else { return }
        featureAccess.setAllowed(allowed, for: Set(providers.map(\.id)))
    }
}

@MainActor
private struct VoiceFeatureAccessSheet: View {
    let plugin: VoiceControlPlugin
    @ObservedObject var model: VoiceConversation
    @StateObject private var draft: VoiceFeatureAccessDraft
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    init(plugin: VoiceControlPlugin, model: VoiceConversation) {
        self.plugin = plugin
        self.model = model
        _draft = StateObject(wrappedValue: VoiceFeatureAccessDraft(
            providers: model.context?.providers() ?? [], featureAccess: model.featureAccess))
    }
    private var editingDisabled: Bool { model.active || model.credentialBusy }
    var body: some View {
        let matches = draft.matches(query)
        let filtered = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Text(model.text("允许的功能")).font(PluginSettingsTheme.Typography.pageTitle)
                Spacer()
                Button(model.text("取消")) { dismiss() }
                    .accessibilityIdentifier("voice-control.features-cancel")
                Button(model.text("完成")) {
                    plugin.setProviderAccess(draft.changes)
                    dismiss()
                }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(editingDisabled)
                    .accessibilityIdentifier("voice-control.features-done")
            }
            Text(String.localizedStringWithFormat(model.text("已允许 %lld 项，共 %lld 项"), draft.allowedCount, draft.providers.count))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            TextField("", text: $query, prompt: Text(model.text("搜索功能")))
                .labelsHidden().textFieldStyle(.roundedBorder)
                .accessibilityLabel(model.text("搜索功能"))
                .accessibilityIdentifier("voice-control.feature-search")
                .focused($searchFocused)
            HStack {
                if filtered {
                    Text(String.localizedStringWithFormat(model.text("找到 %lld 项功能"), matches.count))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.text(filtered ? "允许搜索结果" : "全部允许")) { draft.setAllowed(true, for: matches) }
                    .disabled(editingDisabled || matches.allSatisfy { draft.isAllowed($0.id) })
                    .accessibilityIdentifier("voice-control.features-allow-all")
                Button(model.text(filtered ? "禁止搜索结果" : "全部禁止")) { draft.setAllowed(false, for: matches) }
                    .disabled(editingDisabled || matches.allSatisfy { !draft.isAllowed($0.id) })
                    .accessibilityIdentifier("voice-control.features-allow-none")
            }
            List(matches) { provider in
                Toggle(provider.title, isOn: Binding(get: { draft.isAllowed(provider.id) },
                                                    set: { draft.setAllowed($0, for: [provider]) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .disabled(editingDisabled)
                    .accessibilityIdentifier("voice-control.feature." + provider.id)
            }
            .listStyle(.inset)
            .overlay {
                if matches.isEmpty {
                    if draft.providers.isEmpty {
                        ContentUnavailableView(model.text("没有可用功能"), systemImage: "square.stack")
                    } else { ContentUnavailableView.search(text: query) }
                }
            }
            Text(model.text(model.active ? "请先停止对话，再修改允许的功能。" : "选择“完成”保存更改。将在下一次对话生效。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
        }
        .padding(PluginSettingsTheme.Spacing.pagePadding)
        .frame(width: 480, height: 500)
        .buttonStyle(.bordered).controlSize(.small)
        .onAppear { searchFocused = true }
        .onExitCommand { dismiss() }
    }
}
