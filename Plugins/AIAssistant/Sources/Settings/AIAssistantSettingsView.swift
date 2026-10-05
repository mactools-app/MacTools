import SwiftUI
import MacToolsPluginKit

// MARK: - AIAssistantSettingsView (Compatibility Wrapper)

struct AIAssistantSettingsView: View {
    private let profiles: [AIAssistantProviderProfile]
    private let prompts: [AIAssistantPrompt]
    private let apiKey: String
    private let localization: PluginLocalization
    private let settingsContext: PluginSettingsContext
    private let shortcutItemProvider: (AIAssistantPrompt) -> ShortcutSettingsItem?
    private let onSave: (([AIAssistantProviderProfile], [AIAssistantPrompt], String) -> String?)?
    private let onSaveProvider: (([AIAssistantProviderProfile], String) -> String?)?
    private let onPromptsChanged: (([AIAssistantPrompt]) -> String?)?
    private let onMakeNewPrompt: ([AIAssistantPrompt]) -> AIAssistantPrompt
    private let onFetchModels: (AIAssistantProviderProfile, String) async -> AIAssistantOutcome<[String]>
    private let onTestConnection: (AIAssistantProviderProfile, String) async -> AIAssistantOutcome<String>

    init(
        profiles: [AIAssistantProviderProfile],
        prompts: [AIAssistantPrompt],
        apiKey: String,
        localization: PluginLocalization,
        settingsContext: PluginSettingsContext,
        shortcutItemProvider: @escaping (AIAssistantPrompt) -> ShortcutSettingsItem?,
        onSave: (([AIAssistantProviderProfile], [AIAssistantPrompt], String) -> String?)? = nil,
        onSaveProvider: (([AIAssistantProviderProfile], String) -> String?)? = nil,
        onPromptsChanged: (([AIAssistantPrompt]) -> String?)? = nil,
        onMakeNewPrompt: @escaping ([AIAssistantPrompt]) -> AIAssistantPrompt,
        onFetchModels: @escaping (AIAssistantProviderProfile, String) async -> AIAssistantOutcome<[String]>,
        onTestConnection: @escaping (AIAssistantProviderProfile, String) async -> AIAssistantOutcome<String>
    ) {
        self.profiles = profiles
        self.prompts = prompts
        self.apiKey = apiKey
        self.localization = localization
        self.settingsContext = settingsContext
        self.shortcutItemProvider = shortcutItemProvider
        self.onSave = onSave
        self.onSaveProvider = onSaveProvider
        self.onPromptsChanged = onPromptsChanged
        self.onMakeNewPrompt = onMakeNewPrompt
        self.onFetchModels = onFetchModels
        self.onTestConnection = onTestConnection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            AIAssistantServiceSettingsView(
                profiles: profiles,
                apiKey: apiKey,
                localization: localization,
                onSave: { profiles, key in
                    if let onSaveProvider {
                        return onSaveProvider(profiles, key)
                    }
                    if let onSave {
                        return onSave(profiles, prompts, key)
                    }
                    return nil
                },
                onFetchModels: onFetchModels,
                onTestConnection: onTestConnection
            )

            AIAssistantPromptSettingsView(
                prompts: prompts,
                localization: localization,
                settingsContext: settingsContext,
                shortcutItemProvider: shortcutItemProvider,
                onPromptsChanged: { updatedPrompts in
                    if let onPromptsChanged {
                        return onPromptsChanged(updatedPrompts)
                    }
                    if let onSave {
                        return onSave(profiles, updatedPrompts, apiKey)
                    }
                    return nil
                },
                onMakeNewPrompt: onMakeNewPrompt
            )
        }
    }
}

// MARK: - AI Service Settings View

struct AIAssistantServiceSettingsView: View {
    @State private var profiles: [AIAssistantProviderProfile]
    @State private var apiKey: String

    @State private var availableModels: [String] = []
    @State private var isFetchingModels = false
    @State private var modelListError: String?

    @State private var isTestingConnection = false
    @State private var testMessage: String?
    @State private var testMessageIsError = false

    @State private var serviceMessage: String?
    @State private var serviceMessageIsError = false
    @State private var serviceCardWidth: CGFloat = 520

    let localization: PluginLocalization
    let onSave: ([AIAssistantProviderProfile], String) -> String?
    let onFetchModels: (AIAssistantProviderProfile, String) async -> AIAssistantOutcome<[String]>
    let onTestConnection: (AIAssistantProviderProfile, String) async -> AIAssistantOutcome<String>

    init(
        profiles: [AIAssistantProviderProfile],
        apiKey: String,
        localization: PluginLocalization,
        onSave: @escaping ([AIAssistantProviderProfile], String) -> String?,
        onFetchModels: @escaping (AIAssistantProviderProfile, String) async -> AIAssistantOutcome<[String]>,
        onTestConnection: @escaping (AIAssistantProviderProfile, String) async -> AIAssistantOutcome<String>
    ) {
        self._profiles = State(initialValue: profiles)
        self._apiKey = State(initialValue: apiKey)
        self.localization = localization
        self.onSave = onSave
        self.onFetchModels = onFetchModels
        self.onTestConnection = onTestConnection
    }

    var body: some View {
        VStack(spacing: 0) {
            fieldRow(
                title: localization.string("settings.provider.name.title", defaultValue: "名称"),
                description: localization.string("settings.provider.name.description", defaultValue: "显示在处理结果卡片上。")
            ) {
                TextField(
                    "",
                    text: providerBinding(\.name),
                    prompt: Text(localization.string("settings.provider.name.placeholder", defaultValue: "AI 服务"))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }

            PluginSettingsListDivider()

            fieldRow(
                title: localization.string("settings.provider.baseURL.title", defaultValue: "服务地址"),
                description: localization.string("settings.provider.baseURL.description", defaultValue: "OpenAI 或兼容网关地址。")
            ) {
                TextField(
                    "",
                    text: providerBinding(\.baseURL),
                    prompt: Text(localization.string("settings.provider.baseURL.placeholder", defaultValue: "https://api.deepseek.com/v1"))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }

            PluginSettingsListDivider()

            fieldRow(
                title: localization.string("settings.provider.apiKey.title", defaultValue: "接口密钥"),
                description: localization.string("settings.provider.apiKey.description", defaultValue: "留空则保留当前钥匙串内容。")
            ) {
                SecureField(
                    "",
                    text: $apiKey,
                    prompt: Text(localization.string("settings.provider.apiKey.placeholder", defaultValue: "sk-..."))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onChange(of: apiKey) {
                    serviceMessage = nil
                    serviceMessageIsError = false
                }
            }

            PluginSettingsListDivider()

            modelRow

            if let modelListError {
                Text(modelListError)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                    .padding(.bottom, PluginSettingsTheme.Spacing.rowVertical)
            }

            PluginSettingsListDivider()

            fieldRow(
                title: localization.string("settings.provider.reasoning.title", defaultValue: "请求思考过程"),
                description: localization.string(
                    "settings.provider.reasoning.description",
                    defaultValue: "为 DeepSeek / Qwen 等推理模型在请求中启用思考字段。"
                )
            ) {
                Toggle("", isOn: providerBinding(\.enableReasoning))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            PluginSettingsListDivider()

            serviceActions
        }
        .pluginSettingsCardBackground(.standard)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { serviceCardWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { serviceCardWidth = proxy.size.width }
            }
        )
    }

    private var modelRow: some View {
        fieldRow(
            title: localization.string("settings.provider.model.title", defaultValue: "模型"),
            description: localization.string("settings.provider.model.description", defaultValue: "用于处理的模型名称。")
        ) {
            HStack(spacing: 6) {
                TextField(
                    "",
                    text: providerBinding(\.model),
                    prompt: Text(localization.string("settings.provider.model.placeholder", defaultValue: "deepseek-flash"))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)

                Menu {
                    if availableModels.isEmpty {
                        Text(localization.string("settings.modelList.empty", defaultValue: "暂无可用模型，点击刷新获取"))
                    } else {
                        ForEach(availableModels, id: \.self) { model in
                            Button(model) {
                                providerBinding(\.model).wrappedValue = model
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(localization.string("settings.modelList.help", defaultValue: "从可用模型中选择"))

                Button {
                    Task { @MainActor in await fetchModels() }
                } label: {
                    if isFetchingModels {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 20, height: 20)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(isFetchingModels)
                .help(localization.string("settings.modelList.fetchHelp", defaultValue: "获取可用模型列表"))
            }
        }
    }

    private var serviceActions: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            if let testMessage {
                Text(testMessage)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(testMessageIsError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }

            if let serviceMessage {
                Text(serviceMessage)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(serviceMessageIsError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Button {
                    Task { @MainActor in await testConnection() }
                } label: {
                    if isTestingConnection {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(localization.string("settings.test.title", defaultValue: "测试连接"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTestingConnection)

                Button(localization.string("settings.action.restoreDefaults", defaultValue: "恢复默认")) {
                    profiles = [AIAssistantProviderProfile.defaultProfile(localization: localization)]
                    apiKey = ""
                    serviceMessage = nil
                    serviceMessageIsError = false
                    testMessage = nil
                    testMessageIsError = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(localization.string("settings.action.saveService", defaultValue: "保存服务设置")) {
                    saveService()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var labelColumnWidth: CGFloat {
        max(140, serviceCardWidth * 0.35)
    }

    private func fieldRow<Control: View>(
        title: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .lineLimit(1)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(width: labelColumnWidth, alignment: .leading)

            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func providerBinding<Value>(_ keyPath: WritableKeyPath<AIAssistantProviderProfile, Value>) -> Binding<Value> {
        Binding(
            get: {
                let index = profiles.indices.first ?? 0
                return profiles[index][keyPath: keyPath]
            },
            set: {
                let index = profiles.indices.first ?? 0
                profiles[index][keyPath: keyPath] = $0
                serviceMessage = nil
                serviceMessageIsError = false
            }
        )
    }

    private func saveService() {
        if let error = onSave(profiles, apiKey) {
            serviceMessage = error
            serviceMessageIsError = true
        } else {
            serviceMessage = localization.string("settings.message.serviceSaved", defaultValue: "AI 服务已保存")
            serviceMessageIsError = false
        }
    }

    private func fetchModels() async {
        let profile = profiles.indices.first.map { profiles[$0] } ?? AIAssistantProviderProfile.defaultProfile(localization: localization)

        isFetchingModels = true
        modelListError = nil
        defer { isFetchingModels = false }

        let result = await onFetchModels(profile, apiKey)
        switch result {
        case let .success(models):
            availableModels = models
            if models.isEmpty {
                modelListError = localization.string("settings.modelList.emptyResult", defaultValue: "未返回可用模型")
            }
        case let .failure(error):
            modelListError = error
        }
    }

    private func testConnection() async {
        let profile = profiles.indices.first.map { profiles[$0] } ?? AIAssistantProviderProfile.defaultProfile(localization: localization)

        isTestingConnection = true
        testMessage = nil
        testMessageIsError = false
        defer { isTestingConnection = false }

        let result = await onTestConnection(profile, apiKey)
        switch result {
        case let .success(reply):
            testMessage = reply
            testMessageIsError = false
        case let .failure(error):
            testMessage = error
            testMessageIsError = true
        }
    }
}

// MARK: - Prompt Modules Settings View

struct AIAssistantPromptSettingsView: View {
    @StateObject private var editor: AIAssistantPromptEditor
    @State private var promptPendingDeletion: AIAssistantPrompt?

    let localization: PluginLocalization
    let settingsContext: PluginSettingsContext
    let shortcutItemProvider: (AIAssistantPrompt) -> ShortcutSettingsItem?

    init(
        prompts: [AIAssistantPrompt],
        localization: PluginLocalization,
        settingsContext: PluginSettingsContext,
        shortcutItemProvider: @escaping (AIAssistantPrompt) -> ShortcutSettingsItem?,
        onPromptsChanged: @escaping ([AIAssistantPrompt]) -> String?,
        onMakeNewPrompt: @escaping ([AIAssistantPrompt]) -> AIAssistantPrompt
    ) {
        self._editor = StateObject(wrappedValue: AIAssistantPromptEditor(
            prompts: prompts, localization: localization,
            persist: onPromptsChanged, makePrompt: onMakeNewPrompt
        ))
        self.localization = localization
        self.settingsContext = settingsContext
        self.shortcutItemProvider = shortcutItemProvider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            VStack(spacing: 0) {
                ForEach(Array(editor.prompts.enumerated()), id: \.element.id) { index, prompt in
                    promptRow(index: index)
                    if prompt.id != editor.prompts.last?.id {
                        PluginSettingsListDivider()
                    }
                }
            }
            .pluginSettingsCardBackground(.standard)

            // Align the add button to the trailing edge.
            HStack {
                Spacer()
                Button {
                    editor.addPrompt()
                } label: {
                    Label(localization.string("settings.promptList.add", defaultValue: "添加处理模板"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.top, 4)

            if let message = editor.message {
                Text(message)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(editor.messageIsError ? Color.red : Color.secondary)
                    .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            }
        }
        .alert(
            localization.string("settings.prompt.deleteConfirm.title", defaultValue: "删除处理模板？"),
            isPresented: Binding(
                get: { promptPendingDeletion != nil },
                set: { if !$0 { promptPendingDeletion = nil } }
            ),
            presenting: promptPendingDeletion
        ) { prompt in
            Button(localization.string("common.delete", defaultValue: "删除"), role: .destructive) {
                editor.deletePrompt(prompt.id)
                promptPendingDeletion = nil
            }
            Button(localization.string("common.cancel", defaultValue: "取消"), role: .cancel) {
                promptPendingDeletion = nil
            }
        } message: { prompt in
            Text(localization.format(
                "settings.prompt.deleteConfirm.message",
                defaultValue: "确定要删除「%@」吗？删除后快捷键与相关配置将一并失效，且无法恢复。",
                prompt.normalizedName
            ))
        }
    }

    private func promptRow(index: Int) -> some View {
        let prompt = editor.promptEditDrafts[editor.prompts[index].id] ?? editor.prompts[index]
        let isEditing = editor.isEditing(prompt.id)
        let isDisabled = !prompt.isEnabled

        return Group {
            if isEditing {
                editingPromptCard(index: index, prompt: prompt, isDisabled: isDisabled)
            } else {
                collapsedPromptCard(index: index, prompt: prompt, isDisabled: isDisabled)
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    // MARK: - Collapsed Card

    private func collapsedPromptCard(index: Int, prompt: AIAssistantPrompt, isDisabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Toggle("", isOn: promptEnabledBinding(for: prompt))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Text(prompt.normalizedName)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                    .lineLimit(1)

                // Temperature badge.
                Text(String(format: "%.1f", prompt.temperature))
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())

                // Shortcut summary.
                if let item = shortcutItemProvider(prompt),
                   !item.bindingText.isEmpty {
                    Text(item.bindingText)
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                Button {
                    editor.beginEditing(prompt.id)
                } label: {
                    Text(localization.string("settings.promptRow.edit", defaultValue: "编辑"))
                }
                .buttonStyle(.link)
                .controlSize(.small)

                iconButton("chevron.up", help: localization.string("settings.promptRow.moveUpHelp", defaultValue: "上移")) {
                    editor.movePrompt(prompt.id, offset: -1)
                }
                .disabled(index == 0)

                iconButton("chevron.down", help: localization.string("settings.promptRow.moveDownHelp", defaultValue: "下移")) {
                    editor.movePrompt(prompt.id, offset: 1)
                }
                .disabled(index == editor.prompts.count - 1)

                iconButton("trash", help: localization.string("settings.promptRow.deleteHelp", defaultValue: "删除")) {
                    promptPendingDeletion = prompt
                }
            }

            // Prompt preview.
            VStack(alignment: .leading, spacing: 3) {
                if let sys = prompt.systemPrompt, !sys.isEmpty {
                    Text(localization.format("settings.promptRow.systemPreview", defaultValue: "系统：%@", sys))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(localization.format("settings.promptRow.templatePreview", defaultValue: "模板：%@", prompt.template))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 32)

            shortcutControls(for: prompt)
        }
    }

    @ViewBuilder
    private func shortcutControls(for prompt: AIAssistantPrompt) -> some View {
        if let item = shortcutItemProvider(prompt) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localization.string("settings.prompt.shortcutLabel", defaultValue: "全局快捷键"))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    Text(localization.string("settings.prompt.shortcutImmediateDescription", defaultValue: "快捷键更改立即生效。"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    PluginShortcutRecorder(
                        title: item.title,
                        displayText: item.bindingText,
                        minWidth: 120,
                        onRecord: { binding in
                            settingsContext.recordShortcut(binding, for: item.id)
                        },
                        onBeginRecording: {
                            settingsContext.beginShortcutRecording(for: item.id)
                        }
                    )
                    .controlSize(.small)

                    if item.canClear {
                        Button {
                            settingsContext.clearShortcut(for: item.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                        .help(localization.string("settings.prompt.shortcutClear", defaultValue: "清除快捷键"))
                    }
                }
            }
        }
    }

    // MARK: - Editing Card

    private func editingPromptCard(index: Int, prompt: AIAssistantPrompt, isDisabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Toggle("", isOn: promptEnabledBinding(for: prompt, isEditing: true))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)

                TextField(
                    "",
                    text: promptBinding(for: prompt, keyPath: \.name),
                    prompt: Text(localization.string("settings.prompt.namePlaceholder", defaultValue: "模板名称"))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, idealWidth: 180, maxWidth: 240)

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                Button {
                    editor.save(prompt.id)
                } label: {
                    Text(localization.string("settings.prompt.save", defaultValue: "保存"))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                // Cancel always stays enabled so editing is never a trap.
                Button {
                    editor.cancel(prompt.id)
                } label: {
                    Text(localization.string("settings.prompt.cancel", defaultValue: "取消"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                iconButton("chevron.up", help: localization.string("settings.promptRow.moveUpHelp", defaultValue: "上移")) {
                    editor.movePrompt(prompt.id, offset: -1)
                }
                .disabled(isDisabled || index == 0)

                iconButton("chevron.down", help: localization.string("settings.promptRow.moveDownHelp", defaultValue: "下移")) {
                    editor.movePrompt(prompt.id, offset: 1)
                }
                .disabled(isDisabled || index == editor.prompts.count - 1)

                iconButton("trash", help: localization.string("settings.promptRow.deleteHelp", defaultValue: "删除")) {
                    promptPendingDeletion = prompt
                }
                .disabled(isDisabled)
            }

            VStack(alignment: .leading, spacing: 12) {
                // Temperature control.
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(localization.string("settings.prompt.temperature.title", defaultValue: "温度"))
                                .font(PluginSettingsTheme.Typography.rowTitle)

                            Text(String(format: "%.1f", promptBinding(for: prompt, keyPath: \.temperature).wrappedValue))
                                .font(PluginSettingsTheme.Typography.monospacedValue)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }

                        Text(localization.string("settings.prompt.temperature.description", defaultValue: "0-2，控制输出创造力与稳定性，默认 0.7。"))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Slider(
                        value: promptBinding(for: prompt, keyPath: \.temperature),
                        in: 0.0 ... 2.0,
                        step: 0.1
                    )
                    .frame(width: 160)

                    Button {
                        promptBinding(for: prompt, keyPath: \.temperature).wrappedValue = 0.7
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(localization.string("settings.prompt.temperature.resetHelp", defaultValue: "重置温度为 0.7"))
                    .disabled(promptBinding(for: prompt, keyPath: \.temperature).wrappedValue == 0.7)
                    .opacity(promptBinding(for: prompt, keyPath: \.temperature).wrappedValue == 0.7 ? 0.3 : 1.0)
                }

                // System prompt.
                VStack(alignment: .leading, spacing: 6) {
                    Text(localization.string("settings.prompt.systemPrompt.title", defaultValue: "系统提示词 (System Prompt)"))
                        .font(PluginSettingsTheme.Typography.rowTitle)

                    ZStack(alignment: .topLeading) {
                        if (editor.promptEditDrafts[prompt.id]?.systemPrompt ?? "").isEmpty {
                            Text(localization.string("settings.prompt.systemPrompt.placeholder", defaultValue: "设定 AI 角色的背景人设、语气或格式规则（可选）..."))
                                .font(.system(size: 12))
                                .foregroundStyle(Color.secondary.opacity(0.6))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 8)
                        }

                        TextEditor(text: promptSystemPromptBinding(for: prompt))
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .padding(4)
                    }
                    .frame(height: 85)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }

                // Prompt template.
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(localization.string("settings.prompt.template.title", defaultValue: "提示词模板 (Prompt Template)"))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Spacer()
                        Text(localization.string("settings.prompt.template.required", defaultValue: "必须包含 {{text}}"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    ZStack(alignment: .topLeading) {
                        if editor.promptEditDrafts[prompt.id]?.template.isEmpty == true {
                            Text(localization.string("settings.prompt.template.placeholder", defaultValue: "请将以下内容翻译为英文：\n\n{{text}}"))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.secondary.opacity(0.6))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 8)
                        }

                        TextEditor(text: promptBinding(for: prompt, keyPath: \.template))
                            .font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(4)
                    }
                    .frame(height: 85)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }
            }
            .padding(.leading, 32)
        }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func promptBinding<Value>(
        for prompt: AIAssistantPrompt,
        keyPath: WritableKeyPath<AIAssistantPrompt, Value>
    ) -> Binding<Value> {
        Binding(
            get: { editor.promptEditDrafts[prompt.id]?[keyPath: keyPath] ?? prompt[keyPath: keyPath] },
            set: { editor.updateDraft(prompt.id, keyPath: keyPath, value: $0) }
        )
    }

    private func promptSystemPromptBinding(for prompt: AIAssistantPrompt) -> Binding<String> {
        Binding(
            get: { editor.promptEditDrafts[prompt.id]?.systemPrompt ?? "" },
            set: { editor.updateDraft(prompt.id, keyPath: \.systemPrompt, value: $0.isEmpty ? nil : $0) }
        )
    }

    private func promptEnabledBinding(for prompt: AIAssistantPrompt, isEditing: Bool = false) -> Binding<Bool> {
        Binding(
            get: {
                if isEditing { return editor.promptEditDrafts[prompt.id]?.isEnabled ?? prompt.isEnabled }
                return editor.prompts.first { $0.id == prompt.id }?.isEnabled ?? prompt.isEnabled
            },
            set: {
                if isEditing {
                    editor.updateDraft(prompt.id, keyPath: \.isEnabled, value: $0)
                } else {
                    editor.setEnabled(prompt.id, $0)
                }
            }
        )
    }
}
