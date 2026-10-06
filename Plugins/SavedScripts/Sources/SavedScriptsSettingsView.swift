import AppKit
import MacToolsPluginKit
import SwiftUI

@MainActor
final class SavedScriptsSettingsSearchFocusController: ObservableObject {
    @Published private(set) var requestID: UInt = 0

    func requestFocus() {
        requestID &+= 1
    }
}

@MainActor
struct SavedScriptsSettingsView: View {
    let plugin: SavedScriptsPlugin
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    @ObservedObject private var store: SavedScriptsStore
    @ObservedObject private var executionStore: SavedScriptsExecutionStore
    @ObservedObject private var searchFocusController: SavedScriptsSettingsSearchFocusController

    @State private var query = ""
    @State private var editorRequest: SavedScriptEditorRequest?
    @State private var deletionRequest: SavedScriptDeletionRequest?
    @FocusState private var isSearchFocused: Bool

    init(
        plugin: SavedScriptsPlugin,
        searchFocusController: SavedScriptsSettingsSearchFocusController = .init()
    ) {
        self.plugin = plugin
        _store = ObservedObject(wrappedValue: plugin.store)
        _executionStore = ObservedObject(wrappedValue: plugin.executionStore)
        _searchFocusController = ObservedObject(wrappedValue: searchFocusController)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            librarySection
            if let record = selectedRecord {
                outputSection(record)
            }
            safetySection
        }
        .sheet(item: $editorRequest) { request in
            SavedScriptEditorSheet(
                plugin: plugin,
                request: request,
                onDismiss: { editorRequest = nil }
            )
            .environment(\.layoutDirection, layoutDirection)
            .environment(\.locale, locale)
        }
        .alert(item: $deletionRequest) { request in
            Alert(
                title: Text(plugin.localized(
                    "settings.delete.title",
                    defaultValue: "删除脚本？"
                )),
                message: Text(plugin.localized(
                    "settings.delete.message",
                    defaultValue: "使用此脚本的快捷键、手势、操作网格和工作流将变为不可用。"
                )),
                primaryButton: .destructive(Text(plugin.localized(
                    "common.delete",
                    defaultValue: "删除"
                ))) {
                    _ = plugin.deleteScript(id: request.script.id)
                },
                secondaryButton: .cancel(Text(plugin.localized(
                    "common.cancel",
                    defaultValue: "取消"
                )))
            )
        }
        .onChange(of: searchFocusController.requestID) {
            isSearchFocused = true
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Label(
                    plugin.localized("settings.library.title", defaultValue: "脚本库"),
                    systemImage: "books.vertical"
                )
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

                Text("\(store.scripts.count)/\(SavedScriptsStore.maximumScriptCount)")
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.tertiary)

                Spacer()

                TextField(
                    plugin.localized("settings.search.placeholder", defaultValue: "搜索脚本"),
                    text: $query
                )
                .focused($isSearchFocused)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, idealWidth: 220, maxWidth: 280)

                Button {
                    editorRequest = SavedScriptEditorRequest(script: .draft(), isNew: true)
                } label: {
                    Label(plugin.localized("common.add", defaultValue: "添加"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    store.loadError != nil
                        || store.scripts.count >= SavedScriptsStore.maximumScriptCount
                )
                .accessibilityIdentifier("mactools.saved-scripts.add")
            }

            if store.scripts.isEmpty {
                emptyLibrary
            } else if filteredScripts.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .pluginSettingsCardBackground(.standard)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredScripts.enumerated()), id: \.element.id) { index, script in
                        scriptRow(script)
                        if index < filteredScripts.count - 1 {
                            PluginSettingsListDivider()
                        }
                    }
                }
                .pluginSettingsCardBackground(.standard)
            }

            if let loadError = store.loadError {
                Label(
                    loadError == "invalid-saved-scripts-library"
                        ? plugin.localized(
                            "settings.library.invalid",
                            defaultValue: "无法读取脚本库；原始数据已保留。"
                        )
                        : loadError,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.red)
            }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label(
                plugin.localized("settings.empty.title", defaultValue: "没有已存脚本"),
                systemImage: "terminal"
            )
        } description: {
            Text(plugin.localized(
                "settings.empty.description",
                defaultValue: "添加 AppleScript 或 Shell 脚本，然后直接运行或在 MacTools 的其他操作入口中使用。"
            ))
        } actions: {
            Button(plugin.localized("settings.empty.action", defaultValue: "添加第一个脚本")) {
                editorRequest = SavedScriptEditorRequest(script: .draft(), isNew: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(store.loadError != nil)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .pluginSettingsCardBackground(.standard)
    }

    private func scriptRow(_ script: SavedScript) -> some View {
        let record = executionStore.record(for: script.id)
        let isRunning = record?.status == .running

        return HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: PluginSystemImage.resolvedName(script.kind.systemImage))
                .pluginSettingsRowIconStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                HStack(spacing: 7) {
                    Text(script.name)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        .lineLimit(1)
                    if let record {
                        runStatusBadge(record.status)
                    }
                }
                Text(scriptSubtitle(script))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isRunning {
                ProgressView()
                    .controlSize(.small)
                if plugin.isManualRun(script.id) {
                    Button(plugin.localized("common.stop", defaultValue: "停止")) {
                        plugin.cancelExecution(scriptID: script.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Button(plugin.localized("common.run", defaultValue: "运行")) {
                    plugin.runManual(scriptID: script.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("mactools.saved-scripts.run.\(script.id.uuidString)")
            }

            if record != nil {
                Button {
                    executionStore.selectedScriptID = script.id
                } label: {
                    Label(
                        plugin.localized("settings.output.show", defaultValue: "查看输出"),
                        systemImage: "text.alignleft"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(plugin.localized("settings.output.show", defaultValue: "查看输出"))
            }

            Menu {
                Button(plugin.localized("common.edit", defaultValue: "编辑")) {
                    editorRequest = SavedScriptEditorRequest(script: script, isNew: false)
                }
                Button(plugin.localized("common.duplicate", defaultValue: "制作副本")) {
                    _ = store.duplicate(
                        id: script.id,
                        copySuffix: plugin.localized("settings.copy.suffix", defaultValue: "副本")
                    )
                }
                Divider()
                Button(plugin.localized("common.delete", defaultValue: "删除"), role: .destructive) {
                    deletionRequest = SavedScriptDeletionRequest(script: script)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(plugin.localized("common.more", defaultValue: "更多"))
        }
        .pluginSettingsListRowPadding(interactive: true)
        .contextMenu {
            Button(plugin.localized("common.run", defaultValue: "运行")) {
                plugin.runManual(scriptID: script.id)
            }
            .disabled(isRunning)
            Button(plugin.localized("common.edit", defaultValue: "编辑")) {
                editorRequest = SavedScriptEditorRequest(script: script, isNew: false)
            }
            Button(plugin.localized("common.duplicate", defaultValue: "制作副本")) {
                _ = store.duplicate(
                    id: script.id,
                    copySuffix: plugin.localized("settings.copy.suffix", defaultValue: "副本")
                )
            }
            Divider()
            Button(plugin.localized("common.delete", defaultValue: "删除"), role: .destructive) {
                deletionRequest = SavedScriptDeletionRequest(script: script)
            }
        }
    }

    private func outputSection(_ record: SavedScriptRunRecord) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Label(
                    plugin.localized("settings.output.title", defaultValue: "最近输出"),
                    systemImage: "text.alignleft"
                )
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)
                Spacer()
                Text(record.scriptName)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                runStatusBadge(record.status)
            }

            VStack(alignment: .leading, spacing: 10) {
                if record.status == .running {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(plugin.localized("settings.output.running", defaultValue: "脚本正在运行…"))
                    }
                } else if record.standardOutput.isEmpty && record.standardError.isEmpty {
                    Text(record.message ?? plugin.localized(
                        "settings.output.empty",
                        defaultValue: "脚本没有产生输出。"
                    ))
                    .foregroundStyle(.secondary)
                } else {
                    if !record.standardOutput.isEmpty {
                        outputBlock(
                            title: plugin.localized("settings.output.stdout", defaultValue: "标准输出"),
                            text: record.standardOutput,
                            color: .primary
                        )
                    }
                    if !record.standardError.isEmpty {
                        outputBlock(
                            title: plugin.localized("settings.output.stderr", defaultValue: "错误输出"),
                            text: record.standardError,
                            color: .red
                        )
                    }
                }
                if record.outputWasTruncated {
                    Label(
                        plugin.localized(
                            "settings.output.truncated",
                            defaultValue: "输出过长，只显示前 64 KB。"
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.orange)
                }
            }
            .padding(PluginSettingsTheme.Spacing.cardContent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(
                plugin.localized("settings.safety.title", defaultValue: "安全与共享"),
                systemImage: "lock.shield"
            )
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)

            Text(plugin.localized(
                "settings.safety.description",
                defaultValue: "脚本以当前用户权限运行。MacTools 不使用 sudo，也不会把脚本文本拼接到 Shell 命令中。输出仅保留到本次退出。备份和 Run Link 需要逐个脚本启用。"
            ))
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(PluginSettingsTheme.Spacing.cardContent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var filteredScripts: [SavedScript] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.scripts }
        return store.scripts.filter { script in
            [script.name, plugin.kindTitle(script.kind), script.workingDirectory]
                .contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    private var selectedRecord: SavedScriptRunRecord? {
        guard let id = executionStore.selectedScriptID else { return nil }
        return executionStore.record(for: id)
    }

    private func scriptSubtitle(_ script: SavedScript) -> String {
        let kind = plugin.kindTitle(script.kind)
        guard !script.workingDirectory.isEmpty else { return kind }
        return "\(kind) · \((script.workingDirectory as NSString).abbreviatingWithTildeInPath)"
    }

    private func runStatusBadge(_ status: SavedScriptRunStatus) -> some View {
        Text(plugin.statusTitle(status))
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusColor(status).opacity(0.12), in: Capsule())
    }

    private func statusColor(_ status: SavedScriptRunStatus) -> Color {
        switch status {
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    private func outputBlock(title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(PluginSettingsTheme.Typography.secondaryLabel)
                .foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 54, maxHeight: 180)
            .padding(8)
            .background(
                PluginSettingsTheme.Palette.recessedControlBackground,
                in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field)
            )
        }
    }
}

private struct SavedScriptEditorRequest: Identifiable {
    let id = UUID()
    let script: SavedScript
    let isNew: Bool
}

private struct SavedScriptDeletionRequest: Identifiable {
    let id = UUID()
    let script: SavedScript
}

@MainActor
private struct SavedScriptEditorSheet: View {
    private enum Field: Hashable {
        case name
        case source
    }

    let plugin: SavedScriptsPlugin
    let request: SavedScriptEditorRequest
    let onDismiss: () -> Void

    @State private var draft: SavedScript
    @State private var validationMessage: String?
    @FocusState private var focusedField: Field?

    init(
        plugin: SavedScriptsPlugin,
        request: SavedScriptEditorRequest,
        onDismiss: @escaping () -> Void
    ) {
        self.plugin = plugin
        self.request = request
        self.onDismiss = onDismiss
        _draft = State(initialValue: request.script)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.isNew
                ? plugin.localized("editor.add.title", defaultValue: "添加脚本")
                : plugin.localized("editor.edit.title", defaultValue: "编辑脚本"))
                .font(PluginSettingsTheme.Typography.pageTitle)

            Form {
                Section(plugin.localized("editor.identity.title", defaultValue: "基本信息")) {
                    TextField(
                        plugin.localized("editor.name.placeholder", defaultValue: "脚本名称"),
                        text: $draft.name
                    )
                    .focused($focusedField, equals: .name)

                    Picker(plugin.localized("editor.kind.title", defaultValue: "类型"), selection: $draft.kind) {
                        ForEach(SavedScriptKind.allCases) { kind in
                            Label(
                                plugin.kindTitle(kind),
                                systemImage: PluginSystemImage.resolvedName(kind.systemImage)
                            ).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(plugin.localized("editor.source.title", defaultValue: "脚本文本")) {
                    TextEditor(text: $draft.source)
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                        .focused($focusedField, equals: .source)
                        .frame(minHeight: 210)
                        .padding(6)
                        .background(
                            PluginSettingsTheme.Palette.fieldBackground,
                            in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field)
                        )
                }

                Section(plugin.localized("editor.execution.title", defaultValue: "运行选项")) {
                    TextField(
                        plugin.localized(
                            "editor.directory.placeholder",
                            defaultValue: "工作目录（可选，例如 ~/Projects）"
                        ),
                        text: $draft.workingDirectory
                    )

                    LabeledContent(plugin.localized("editor.timeout.title", defaultValue: "超时")) {
                        HStack(spacing: 10) {
                            TextField("", value: $draft.timeoutSeconds, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: 72)
                                .accessibilityLabel(
                                    plugin.localized("editor.timeout.title", defaultValue: "超时")
                                )
                                .accessibilityValue(plugin.localizedFormat(
                                    "editor.timeout.value.format",
                                    defaultValue: "%d 秒",
                                    draft.timeoutSeconds
                                ))
                                .onSubmit(clampTimeout)

                            Text(plugin.localized(
                                "editor.timeout.unit.short",
                                defaultValue: "秒"
                            ))
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .accessibilityHidden(true)
                        }
                    }
                }

                Section(plugin.localized("editor.sharing.title", defaultValue: "其他入口")) {
                    Toggle(isOn: $draft.confirmOutsideManager) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.localized(
                                "editor.confirm.title",
                                defaultValue: "从其他入口运行前要求确认"
                            ))
                            Text(plugin.localized(
                                "editor.confirm.description",
                                defaultValue: "关闭后，从操作网格、触控板手势、快捷键和工作流运行时会立即执行。"
                            ))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(Text(plugin.localized(
                        "editor.confirm.title",
                        defaultValue: "从其他入口运行前要求确认"
                    )))
                    .accessibilityHint(Text(plugin.localized(
                        "editor.confirm.description",
                        defaultValue: "关闭后，从操作网格、触控板手势、快捷键和工作流运行时会立即执行。"
                    )))
                    Toggle(
                        plugin.localized("editor.runLink.title", defaultValue: "允许 Run Link"),
                        isOn: $draft.allowExternalInvocation
                    )
                    Text(plugin.localized(
                        "editor.runLink.description",
                        defaultValue: "Run Link 始终显示确认；关闭时，快捷键、手势、操作网格和工作流仍可使用此脚本。"
                    ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)

                    Toggle(
                        plugin.localized(
                            "editor.backup.title",
                            defaultValue: "在 MacTools 备份中包含脚本文本"
                        ),
                        isOn: $draft.includeSourceInBackup
                    )
                    Text(plugin.localized(
                        "editor.backup.description",
                        defaultValue: "脚本可能包含敏感信息，因此默认不备份。工作目录不会写入备份。"
                    ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(plugin.localized("common.cancel", defaultValue: "取消"), action: onDismiss)
                    .buttonStyle(.bordered)
                Button(plugin.localized("editor.saveAndRun", defaultValue: "保存并运行")) {
                    save(runAfterSave: true)
                }
                .buttonStyle(.bordered)
                .disabled(!canSave)
                Button(plugin.localized("common.save", defaultValue: "保存")) {
                    save(runAfterSave: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(PluginSettingsTheme.Spacing.pagePadding)
        .frame(minWidth: 640, minHeight: 690)
        .onAppear {
            DispatchQueue.main.async { focusedField = .name }
        }
        .onChange(of: draft.kind) { oldKind, newKind in
            if draft.source == oldKind.defaultSource {
                draft.source = newKind.defaultSource
            }
        }
        .onChange(of: draft.timeoutSeconds) { _, value in
            if value < 1 || value > 300 {
                validationMessage = plugin.localized(
                    "validation.timeout",
                    defaultValue: "超时必须在 1 到 300 秒之间。"
                )
            } else if validationMessage == plugin.localized(
                "validation.timeout",
                defaultValue: "超时必须在 1 到 300 秒之间。"
            ) {
                validationMessage = nil
            }
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save(runAfterSave: Bool) {
        switch plugin.saveScript(draft) {
        case let .success(script):
            onDismiss()
            if runAfterSave {
                Task { @MainActor in plugin.runManual(scriptID: script.id) }
            }
        case let .failure(error):
            validationMessage = localizedValidationMessage(error)
        }
    }

    private func clampTimeout() {
        draft.timeoutSeconds = min(max(draft.timeoutSeconds, 1), 300)
    }

    private func localizedValidationMessage(_ error: Error) -> String {
        guard let error = error as? SavedScriptValidationError else {
            return error.localizedDescription
        }
        return switch error {
        case .emptyName:
            plugin.localized("validation.emptyName", defaultValue: "请输入脚本名称。")
        case .nameTooLong:
            plugin.localized("validation.nameTooLong", defaultValue: "脚本名称过长。")
        case .emptySource:
            plugin.localized("validation.emptySource", defaultValue: "请输入脚本文本。")
        case .sourceTooLong:
            plugin.localized("validation.sourceTooLong", defaultValue: "脚本文本超过 64 KB。")
        case .workingDirectoryTooLong:
            plugin.localized("validation.directoryTooLong", defaultValue: "工作目录路径过长。")
        case .invalidTimeout:
            plugin.localized("validation.timeout", defaultValue: "超时必须在 1 到 300 秒之间。")
        case .tooManyScripts:
            plugin.localized("validation.tooMany", defaultValue: "最多可以保存 32 个脚本。")
        case .payloadTooLarge:
            plugin.localized("validation.payloadTooLarge", defaultValue: "脚本库数据过大。")
        case .duplicateID:
            plugin.localized("validation.duplicateID", defaultValue: "脚本标识符已被使用。")
        case .persistenceFailed:
            plugin.localized("validation.persistenceFailed", defaultValue: "无法保存脚本库。")
        case .recoveryRequired:
            plugin.localized(
                "validation.recoveryRequired",
                defaultValue: "无法读取脚本库；请先导入备份恢复。"
            )
        }
    }
}
