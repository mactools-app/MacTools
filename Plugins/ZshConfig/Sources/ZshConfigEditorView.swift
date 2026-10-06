import SwiftUI
import MacToolsPluginKit

// MARK: - ZshConfigEditorView

struct ZshConfigEditorView: View {
    @ObservedObject var store: ZshConfigStore
    private let localization: PluginLocalization
    @State private var contentTab: ContentTab = .editor
    @State private var activeSnippet: ZshSnippet? = nil
    @State private var snippetInput: String = ""
    @State private var showFileInfo: Bool = false
    @State private var scrollToBottomID: Int = 0
    @State private var isRunningSource = false
    @State private var sourceResult: Bool? = nil
    @State private var sourceResultToken = 0

    init(
        store: ZshConfigStore,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.store = store
        self.localization = localization
    }

    private enum ContentTab: CaseIterable {
        case editor
        case quickInsert

        var icon: String {
            switch self {
            case .editor:      return "square.and.pencil"
            case .quickInsert: return "bolt.fill"
            }
        }

        func title(localization: PluginLocalization) -> String {
            switch self {
            case .editor:
                return localization.string("editor.tab.editor", defaultValue: "编辑")
            case .quickInsert:
                return localization.string("editor.tab.quickInsert", defaultValue: "快速插入")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            fileSelectorSection
            contentTabBar
            contentBody
        }
    }

    // MARK: - File Selector

    private var fileSelectorSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                title: localization.string("editor.fileSelector.title", defaultValue: "配置文件"),
                icon: "doc.text"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ZshConfigFileType.allCases) { type in
                        fileTabButton(type: type)
                    }
                }
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                .padding(.vertical, 2)
            }
            .padding(.horizontal, -PluginSettingsTheme.Spacing.rowHorizontal)
        }
    }

    private func fileTabButton(type: ZshConfigFileType) -> some View {
        let isSelected = store.selectedType == type
        let status = store.statusMap[type]
        return Button {
            store.select(type)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(fileStatusColor(status))
                    .frame(width: 7, height: 7)
                Text(type.filename)
                    .font(PluginTypography.code.font.weight(isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.15)
                          : PluginSettingsTheme.Palette.recessedControlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content Tab Bar

    private var contentTabBar: some View {
        HStack(spacing: 0) {
            ForEach(ContentTab.allCases, id: \.self) { tab in
                contentTabButton(tab)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card, style: .continuous)
                .fill(PluginSettingsTheme.Palette.recessedControlBackground)
        )
    }

    private func contentTabButton(_ tab: ContentTab) -> some View {
        let isSelected = contentTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                contentTab = tab
            }
        } label: {
            Label(tab.title(localization: localization), systemImage: tab.icon)
                .font(PluginTypography.control.font.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card - 2, style: .continuous)
                                .fill(PluginSettingsTheme.Surface.raisedControl)
                                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                        }
                    }
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        switch contentTab {
        case .editor:
            editorBodySection
        case .quickInsert:
            snippetSection
        }
    }

    // MARK: - Editor Tab

    @ViewBuilder
    private var editorBodySection: some View {
        if let status = store.statusMap[store.selectedType] {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                fileInfoRow(status: status)
                if status.exists {
                    editorField(isWritable: status.isWritable)
                    actionRow(status: status)
                } else {
                    notExistBanner(status: status)
                }
            }
        }
    }

    @ViewBuilder
    private func fileInfoRow(status: ZshFileStatus) -> some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(store.selectedType.role(localization: localization))
                    .font(PluginSettingsTheme.Typography.rowTitle)
                HStack(spacing: 4) {
                    if status.exists {
                        Text(status.formattedSize)
                            .font(PluginSettingsTheme.Typography.monospacedValue)
                            .foregroundStyle(.secondary)
                        if let date = status.modifiedDate {
                            Text("·").foregroundStyle(.secondary)
                            Text(date, style: .relative)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                            Text(localization.string("editor.fileInfo.modifiedAgo", defaultValue: "前修改"))
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(localization.string("editor.fileInfo.missing", defaultValue: "文件不存在"))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showFileInfo.toggle() }
            } label: {
                Image(systemName: showFileInfo ? "info.circle.fill" : "info.circle")
                    .pluginSettingsRowIconStyle(showFileInfo ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(localization.string("editor.fileInfo.help", defaultValue: "查看加载时机与推荐用途"))
        }
        .pluginSettingsListRowPadding()
        .pluginSettingsCardBackground(.standard)

        if showFileInfo {
            fileInfoPanel
        }
    }

    private var fileInfoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            infoRow(
                label: localization.string("editor.fileInfo.whenLoaded", defaultValue: "加载时机"),
                value: store.selectedType.whenLoaded(localization: localization)
            )
            PluginSettingsListDivider(leadingInset: 0, trailingInset: 0)
            infoRow(
                label: localization.string("editor.fileInfo.recommendedUse", defaultValue: "推荐用途"),
                value: store.selectedType.recommendedUse(localization: localization)
            )
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .pluginSettingsCardBackground(.standard)
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.primary)
        }
    }

    private func editorField(isWritable: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if store.editingContent.isEmpty {
                Text(localization.string(
                    "editor.emptyFile.placeholder",
                    defaultValue: "文件为空。可直接在此输入，或切换到「快速插入」标签添加常用配置。"
                ))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.leading, 6)
                    .allowsHitTesting(false)
            }
            ZshSyntaxHighlightingEditor(
                text: isWritable ? $store.editingContent : .constant(store.editingContent),
                isEditable: isWritable,
                onChange: { store.markEdited() },
                scrollToBottomID: scrollToBottomID
            )
            .frame(minHeight: 200, maxHeight: .infinity)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous)
                .fill(PluginSettingsTheme.Palette.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous)
                .stroke(PluginSettingsTheme.Palette.separator, lineWidth: PluginSettingsTheme.Stroke.hairline)
        )
    }

    @ViewBuilder
    private func actionRow(status: ZshFileStatus) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            if status.isWritable {
                Button {
                    store.saveCurrentFile()
                } label: {
                    HStack(spacing: 4) {
                        if store.isBusy {
                            ProgressView().controlSize(.mini)
                        } else if store.lastSaveSucceeded {
                            Image(systemName: "checkmark")
                                .font(PluginSettingsTheme.Typography.statusBadge)
                        }
                        Text(saveButtonTitle)
                    }
                    .font(PluginSettingsTheme.Typography.controlLabel)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!store.hasUnsavedChanges || store.isBusy)
                .help(localization.format(
                    "editor.action.save.help",
                    defaultValue: "保存前会自动备份为 %@.bak",
                    store.selectedType.filename
                ))
            } else {
                readOnlyBadge
            }
            Spacer()
            Button {
                store.openInExternalEditor(store.selectedType)
            } label: {
                Label(
                    localization.string("editor.action.openExternal", defaultValue: "在系统编辑器中打开"),
                    systemImage: "square.and.pencil"
                )
                    .font(PluginSettingsTheme.Typography.controlLabel)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(localization.string("editor.action.openExternal.help", defaultValue: "在系统默认文本编辑器中打开此文件"))
        }

        if let error = store.saveError {
            errorBanner(message: error)
        }
        if store.lastSaveSucceeded {
            savedHintBanner
        }
    }

    private func notExistBanner(status: ZshFileStatus) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon + 4))
                .foregroundStyle(.tertiary)
            VStack(spacing: 5) {
                Text(localization.string("editor.missingFile.title", defaultValue: "文件尚不存在"))
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(status.isWritable
                     ? localization.format(
                        "editor.missingFile.createDescription",
                        defaultValue: "点击「创建文件」将在家目录生成 %@ 并填入说明注释。",
                        store.selectedType.filename
                     )
                     : localization.string(
                        "editor.missingFile.readOnlyDescription",
                        defaultValue: "家目录不可写，无法创建此文件。请检查磁盘权限。"
                     ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if status.isWritable {
                Button(localization.string("editor.action.createFile", defaultValue: "创建文件")) {
                    store.createCurrentFile()
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.isBusy)
                    .padding(.top, 2)
            }
            if let error = store.saveError {
                errorBanner(message: error)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
        .pluginSettingsCardBackground(.standard)
    }

    // MARK: - Quick Insert Tab

    private var snippetSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.forward.circle")
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
                Text(localization.format(
                    "editor.quickInsert.target",
                    defaultValue: "插入到 %@",
                    store.selectedType.filename
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { contentTab = .editor }
                } label: {
                    Text(localization.string("editor.quickInsert.switchToEditor", defaultValue: "切换到编辑器"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
            .pluginSettingsCardBackground(.recessed)

            VStack(spacing: 0) {
                ForEach(Array(snippets.enumerated()), id: \.element.id) { index, snippet in
                    VStack(spacing: 0) {
                        snippetRow(snippet: snippet)
                        if activeSnippet?.id == snippet.id {
                            snippetExpandedContent(snippet: snippet)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    if index < snippets.count - 1 {
                        PluginSettingsListDivider()
                    }
                }
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private func snippetRow(snippet: ZshSnippet) -> some View {
        let isActive = activeSnippet?.id == snippet.id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isActive {
                    activeSnippet = nil
                    snippetInput = ""
                } else {
                    activeSnippet = snippet
                    snippetInput = ""
                }
            }
        } label: {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: snippet.icon)
                    .pluginSettingsRowIconStyle(isActive ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.title)
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .foregroundStyle(.primary)
                    Text(snippet.description)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isActive ? "chevron.down" : "chevron.forward")
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.tertiary)
                    .animation(.easeInOut(duration: 0.2), value: isActive)
            }
            .pluginSettingsListRowPadding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func snippetExpandedContent(snippet: ZshSnippet) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(snippet.placeholder, text: $snippetInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { insertCurrentSnippet(snippet) }

            if !snippetInput.isEmpty {
                Text(snippet.buildContent(snippetInput))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous)
                            .fill(PluginSettingsTheme.Palette.recessedControlBackground)
                    )
            }

            HStack {
                Spacer()
                Button(localization.string("editor.quickInsert.insertAtEnd", defaultValue: "插入到末尾")) {
                    insertCurrentSnippet(snippet)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(snippetInput.isEmpty)
            }
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .background(PluginSettingsTheme.Surface.raisedControl)
        .overlay(alignment: .top) {
            PluginSettingsListDivider(leadingInset: 0, trailingInset: 0)
        }
    }

    // MARK: - Helper Views

    private var readOnlyBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock")
                .font(PluginSettingsTheme.Typography.statusBadge)
            Text(localization.string("editor.readOnly", defaultValue: "只读"))
                .font(PluginSettingsTheme.Typography.statusBadge)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(PluginSettingsTheme.Palette.recessedControlBackground)
        )
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(.red)
            Text(message)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.red)
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.recessed)
    }

    private var savedHintBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(.green)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(localization.format(
                    "editor.savedHint.title",
                    defaultValue: "已保存（已备份为 %@.bak）",
                    store.selectedType.filename
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                if store.selectedType == .zshrc || store.selectedType == .zshenv {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                        Text("source ~/\(store.selectedType.filename)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .allowsHitTesting(false)
                        Group {
                            if isRunningSource {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: 16, height: 16)
                            } else if let result = sourceResult {
                                Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(result ? Color.green : Color.red)
                                    .frame(width: 16, height: 16)
                            } else {
                                Button {
                                    runSourceDirectly(for: store.selectedType)
                                } label: {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                                .fixedSize()
                                .contentShape(Circle())
                            }
                        }
                        .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(PluginSettingsTheme.Surface.raisedControl)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(PluginSettingsTheme.Palette.separator, lineWidth: PluginSettingsTheme.Stroke.hairline)
                    )

                    Text(localization.string("editor.savedHint.reloadDescription", defaultValue: "执行后无需重启终端即可生效。"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.recessed)
        .onAppear {
            sourceResult = nil
        }
    }



    private func sectionHeader(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }

    // MARK: - Helper Functions

    private var snippets: [ZshSnippet] {
        ZshSnippet.localizedSnippets(localization: localization)
    }

    private var saveButtonTitle: String {
        if store.hasUnsavedChanges {
            return localization.string("editor.action.saveUnsaved", defaultValue: "保存*")
        }
        if store.lastSaveSucceeded {
            return localization.string("editor.action.saved", defaultValue: "已保存")
        }
        return localization.string("editor.action.save", defaultValue: "保存")
    }

    private func runSourceDirectly(for type: ZshConfigFileType) {
        guard !isRunningSource else { return }
        isRunningSource = true
        sourceResult = nil
        sourceResultToken += 1
        let token = sourceResultToken
        let filename = type.filename
        Task {
            let succeeded: Bool = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["--login", "-c", "source ~/\(filename)"]
                    do {
                        try process.run()
                        process.waitUntilExit()
                        continuation.resume(returning: process.terminationStatus == 0)
                    } catch {
                        continuation.resume(returning: false)
                    }
                }
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                isRunningSource = false
                sourceResult = succeeded
            }
            try? await Task.sleep(for: .seconds(3))
            guard sourceResultToken == token else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                sourceResult = nil
            }
        }
    }

    private func runSourceInTerminal(for type: ZshConfigFileType) {
        let script = """
        tell application "Terminal"
            activate
            do script "source ~/\(type.filename)"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func fileStatusColor(_ status: ZshFileStatus?) -> Color {
        guard let status else { return .gray.opacity(0.4) }
        if !status.exists { return .orange.opacity(0.6) }
        if !status.isWritable { return .yellow }
        return .green
    }

    private func insertCurrentSnippet(_ snippet: ZshSnippet) {
        guard !snippetInput.isEmpty else { return }
        store.appendSnippet(snippet.buildContent(snippetInput))
        scrollToBottomID += 1
        withAnimation(.easeInOut(duration: 0.15)) {
            activeSnippet = nil
            snippetInput = ""
            contentTab = .editor
        }
    }
}
