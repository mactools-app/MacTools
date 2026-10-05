import AppKit
import MacToolsPluginKit
import SwiftUI
import UniformTypeIdentifiers

/// At most one main-actor delivery is queued regardless of archive record count.
private final class ClipboardBackupProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: ClipboardBackupPhase?
    private var pending = false
    private let deliver: @MainActor @Sendable (ClipboardBackupPhase) -> Void

    init(deliver: @escaping @MainActor @Sendable (ClipboardBackupPhase) -> Void) { self.deliver = deliver }

    func submit(_ phase: ClipboardBackupPhase) {
        let schedule = lock.withLock {
            latest = phase
            if pending { return false }
            pending = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor [self] in
            let phase = lock.withLock {
                defer { latest = nil; pending = false }
                return latest
            }
            if let phase { deliver(phase) }
        }
    }
}

@MainActor
final class ClipboardBackupPresentation: ObservableObject {
    @Published var phase: ClipboardBackupPhase?
    @Published var preview: ClipboardBackupPreview?
    @Published var result: ClipboardBackupSummary?
    @Published var error: String?
    @Published var completed = false
    var localization: PluginLocalization?
    private var operationGeneration = 0
    private var work: Task<Void, Never>?
    private(set) var didRestore = false
    var isBusy: Bool { work != nil }
    var showsCancel: Bool { !completed }
    var isFinishing: Bool { if case .finishing = phase { true } else { false } }

    func close(resume: @escaping (Bool) -> Void) {
        cancel()
        let pending = work
        Task { await pending?.value; resume(didRestore) }
    }

    func cancel() { if !isFinishing { work?.cancel() } }

    func run<Result: Sendable>(
        operation: @escaping @Sendable (@escaping @Sendable (ClipboardBackupPhase) -> Void) throws -> Result,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        guard work == nil else { return }
        error = nil
        operationGeneration += 1
        let generation = operationGeneration
        phase = .reading
        work = Task { [weak self] in
            guard let self else { return }
            let relay = ClipboardBackupProgressRelay { [weak self] phase in
                guard let self, self.operationGeneration == generation, self.work != nil else { return }
                self.phase = phase
            }
            let worker = Task.detached(priority: .userInitiated) {
                try operation { phase in relay.submit(phase) }
            }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                completion(value)
            } catch is CancellationError {
                // The pre-commit worker owns and removes temporary files.
            } catch {
                self.error = message(error)
            }
            phase = nil
            work = nil
        }
    }

    private func message(_ error: Error) -> String {
        guard let localization else { return ClipboardBackupError.storage.errorDescription ?? "" }
        switch error as? ClipboardBackupError {
        case .invalidArchive: return localization.string("backup.error.invalid", defaultValue: "备份无效、已损坏或密码错误。当前数据未更改。")
        case .unsupportedVersion: return localization.string("backup.error.version", defaultValue: "此备份版本暂不受支持。")
        case .invalidPassword: return localization.string("backup.error.password", defaultValue: "请使用至少 12 个字符的备份密码。")
        case .passwordTooLong: return localization.string("backup.error.passwordTooLong", defaultValue: "密码过长，请缩短后重试。")
        case .limitExceeded: return localization.string("backup.error.limit", defaultValue: "备份超过安全上限或当前单项大小限制。")
        case .changedSincePreview: return localization.string("backup.error.changed", defaultValue: "本机剪贴板数据已更改。请重新预览备份。")
        case .keywordCapacityConfirmationRequired: return localization.string("backup.error.keywordCapacityConfirmation", defaultValue: "请先确认是否移除超出容量的导入关键词绑定。")
        default: return localization.string("backup.error.storage", defaultValue: "无法读写备份。请检查可用磁盘空间和文件权限。")
        }
    }

    func restored(_ summary: ClipboardBackupSummary) {
        didRestore = true
        completed = true
        result = summary
    }
}

@MainActor
struct ClipboardBackupRegion: View {
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    let localization: PluginLocalization
    let controller: ClipboardHistoryController
    let makeService: () -> ClipboardBackupService?
    let suspend: () -> Void
    let resume: (Bool) -> Void
    let provisionalSavedMetadata: () -> [UUID: ClipboardHistorySavedMetadata]
    @State private var action: Action?
    enum Action: String, Identifiable { case backup, restore, rollback; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 0) {
            actionRow(.backup, title: localization.string("backup.createTitle", defaultValue: "备份剪贴板数据"),
                      description: localization.string("backup.createDescription", defaultValue: "将所选数据保存为加密文件，可迁移到另一台 Mac。"),
                      systemImage: "externaldrive.badge.plus")
            PluginSettingsListDivider()
            actionRow(.restore, title: localization.string("backup.restoreTitle", defaultValue: "恢复剪贴板备份"),
                      description: localization.string("backup.restoreDescription", defaultValue: "选择备份文件并输入密码，预览后再恢复。"),
                      systemImage: "arrow.down.doc")
            if let service = makeService(), FileManager.default.fileExists(atPath: service.rollbackURL.path) {
                PluginSettingsListDivider()
                actionRow(.rollback, title: localization.string("backup.rollbackTitle", defaultValue: "本机回滚快照"),
                          description: localization.string("backup.rollbackDescription", defaultValue: "恢复到上次替换前的本机数据，无需备份密码。"),
                          systemImage: "clock.arrow.circlepath")
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .sheet(item: $action) { action in
            if let service = makeService() {
                let history = controller.items.filter(\.isInHistory)
                ClipboardBackupSheet(action: action, service: service, localization: localization,
                                     historyCount: history.count,
                                     historyBytes: history.reduce(0) { $0 + $1.payloadByteCount },
                                     suspend: suspend, resume: resume,
                                     provisionalSavedMetadata: provisionalSavedMetadata)
                    .environment(\.locale, locale)
                    .environment(\.layoutDirection, layoutDirection)
            }
        }
    }

    private func actionRow(_ action: Action, title: String, description: String, systemImage: String) -> some View {
        let buttonTitle = action == .backup
            ? localization.string("backup.button.create", defaultValue: "备份…")
            : localization.string("backup.button.restore", defaultValue: "恢复…")
        return PluginSettingsItem(title: title, description: description, systemImage: systemImage) {
            Button {
                self.action = action
            } label: {
                Text(buttonTitle)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 64)
            }
            .fixedSize()
            .accessibilityLabel(title + " · " + buttonTitle)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }
}

@MainActor
struct ClipboardBackupSheet: View {
    let action: ClipboardBackupRegion.Action
    let service: ClipboardBackupService
    let localization: PluginLocalization
    let historyCount: Int
    let historyBytes: Int
    let suspend: () -> Void
    let resume: (Bool) -> Void
    let provisionalSavedMetadata: () -> [UUID: ClipboardHistorySavedMetadata]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ClipboardBackupPresentation
    @State private var scope = ClipboardBackupScope()
    @State private var password = ""
    @State private var confirmation = ""
    @State private var sourceURL: URL?
    @State private var replacing = false
    @State private var confirmsRestore = false
    @State private var missingOffset = 0
    @State private var missingPaths: [String] = []
    @State private var noticeOffset = 0
    @State private var notices: [ClipboardBackupNotice] = []
    @FocusState private var focusedPassword: PasswordField?
    private enum PasswordField: Hashable { case password, confirmation }

    init(action: ClipboardBackupRegion.Action, service: ClipboardBackupService,
         localization: PluginLocalization, historyCount: Int, historyBytes: Int,
         suspend: @escaping () -> Void, resume: @escaping (Bool) -> Void,
         provisionalSavedMetadata: @escaping () -> [UUID: ClipboardHistorySavedMetadata] = { [:] },
         initialFileURL: URL? = nil, presentation: ClipboardBackupPresentation = ClipboardBackupPresentation()) {
        self.action = action
        self.service = service
        self.localization = localization
        self.historyCount = historyCount
        self.historyBytes = historyBytes
        self.suspend = suspend
        self.resume = resume
        self.provisionalSavedMetadata = provisionalSavedMetadata
        _sourceURL = State(initialValue: initialFileURL)
        _model = StateObject(wrappedValue: presentation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            Text(sheetTitle)
                .font(PluginSettingsTheme.Typography.pageTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    sheetContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            Divider()
            HStack {
                Spacer()
                if model.showsCancel {
                    Button(localization.string("common.cancel", defaultValue: "取消"), role: .cancel) {
                        if model.isBusy { model.cancel() } else { password = ""; confirmation = ""; dismiss() }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isFinishing)
                }
                if model.completed {
                    Button(localization.string("backup.done", defaultValue: "完成")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(primaryTitle) { primaryAction() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isBusy || !canProceed)
                }
            }
        }
        .font(PluginSettingsTheme.Typography.rowTitle)
        .buttonStyle(.bordered).controlSize(.small)
        .padding(24)
        .frame(width: 600, height: sheetHeight)
        .interactiveDismissDisabled(model.isBusy)
        .onAppear { model.localization = localization; suspend(); if action == .rollback { replacing = true } }
        .onDisappear { password = ""; confirmation = ""; model.close(resume: resume) }
        .confirmationDialog(confirmationTitle, isPresented: $confirmsRestore, titleVisibility: .visible) {
            Button(confirmationActionTitle, role: model.preview?.replacement == true ? .destructive : nil) {
                commit(acceptingKeywordCapacityLoss: true)
            }
            Button(localization.string("common.cancel", defaultValue: "取消"), role: .cancel) {}
        } message: {
            Text(restoreConfirmationMessage)
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        if model.completed {
            Label(action == .backup
                  ? localization.string("backup.created", defaultValue: "备份已保存")
                  : localization.string("backup.restored", defaultValue: "剪贴板数据已恢复"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if action == .backup, let sourceURL {
                Text(sourceURL.path).font(PluginSettingsTheme.Typography.rowDescription).textSelection(.enabled)
            }
            if let result = model.result { summary(result) }
        } else {
            if action != .rollback { fileControls }
            if action == .backup { scopeControls }
            if action != .rollback && sourceURL != nil && model.preview == nil { passwordControls }
            if action == .rollback || (action == .restore && sourceURL != nil) {
                Picker(localization.string("backup.restoreMode", defaultValue: "恢复方式"), selection: $replacing) {
                    Text(localization.string("backup.merge", defaultValue: "与本机合并（推荐）")).tag(false)
                    Text(localization.string("backup.replaceChoice", defaultValue: "替换备份中包含的类别（破坏性操作）")).tag(true)
                }
                .pickerStyle(.radioGroup)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(action == .rollback || model.isBusy)
                .onChange(of: replacing) { _, _ in
                    model.preview = nil
                    model.error = nil
                }
                if let preview = model.preview {
                    Text(preview.manifest.createdAt, style: .date)
                    Text(localization.format("backup.manifest", defaultValue: "版本 %d · 历史 %d · 已存 %d · 片段 %d", preview.manifest.version, preview.manifest.history, preview.manifest.saved, preview.manifest.snippets))
                    Text(preview.manifest.payloadBytes.formatted(.byteCount(style: .file).locale(PluginRuntimeLocalization.locale)))
                    Text(categoryTitle(preview.manifest.scope))
                    summary(preview.summary)
                    if preview.replacement {
                        Text(localization.format("backup.removed", defaultValue: "将移除 %d 个本机项目的所选类别数据。提交前会创建本机加密回滚快照。", preview.summary.removed))
                    }
                }
            }
        }
        if let preview = model.preview, preview.summary.missingFileReferences > 0 {
            DisclosureGroup(localization.string("backup.missingPaths", defaultValue: "失效的外部文件路径")) {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(Array(missingPaths.enumerated()), id: \.offset) { _, path in Text(path).textSelection(.enabled) }
                    }
                }.frame(maxHeight: 120)
                HStack {
                    Button(localization.string("backup.previous", defaultValue: "上一页")) { missingOffset = max(0, missingOffset - 50); loadMissingPaths() }
                        .disabled(missingOffset == 0 || model.isBusy)
                    Text("\(missingOffset + 1)–\(min(missingOffset + 50, preview.summary.missingFileReferences)) / \(preview.summary.missingFileReferences)")
                    Button(localization.string("backup.next", defaultValue: "下一页")) { missingOffset += 50; loadMissingPaths() }
                        .disabled(missingOffset + 50 >= preview.summary.missingFileReferences || model.isBusy)
                }
            }.font(PluginSettingsTheme.Typography.rowDescription)
        }
        if let preview = model.preview, preview.summary.conflicts + preview.summary.disabledKeywords > 0 {
            DisclosureGroup(localization.string("backup.conflictDetails", defaultValue: "需处理的冲突")) {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                            if notice.kind != .identifierConflict {
                                Text("\(notice.title ?? notice.id.uuidString) · \(notice.keyword ?? "")")
                                if notice.kind == .keywordCapacity {
                                    Text(localization.string("backup.capacity.notice", defaultValue: "关键词绑定因容量不足而移除；片段内容已保留。"))
                                        .foregroundStyle(.secondary)
                                }
                            } else { Text("\(notice.originalID.uuidString) → \(notice.id.uuidString)") }
                        }
                    }.textSelection(.enabled)
                }.frame(maxHeight: 100)
                HStack {
                    Button(localization.string("backup.previous", defaultValue: "上一页")) { noticeOffset = max(0, noticeOffset - 50); loadNotices() }
                        .disabled(noticeOffset == 0 || model.isBusy)
                    Spacer()
                    Button(localization.string("backup.next", defaultValue: "下一页")) { noticeOffset += 50; loadNotices() }
                        .disabled(noticeOffset + 50 >= preview.summary.conflicts + preview.summary.disabledKeywords || model.isBusy)
                }
            }.font(PluginSettingsTheme.Typography.rowDescription)
        }
        if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        if let phase = model.phase {
            HStack {
                if case let .staging(done, total) = phase, total > 0 {
                    ProgressView(value: Double(done), total: Double(total)).frame(width: 140)
                } else { ProgressView().controlSize(.small) }
                Text(phaseText(phase))
            }
                .accessibilityElement(children: .combine)
        }
    }

    private var sheetHeight: CGFloat {
        if model.completed {
            let hasReports = model.result.map { $0.conflicts + $0.disabledKeywords + $0.missingFileReferences > 0 } ?? false
            return hasReports ? 460 : 260
        }
        if action == .backup { return sourceURL == nil ? 380 : 540 }
        if model.preview != nil { return 580 }
        return action == .restore && sourceURL == nil ? 240 : 440
    }

    private var sheetTitle: String {
        switch action {
        case .backup: localization.string("backup.createTitle", defaultValue: "备份剪贴板数据")
        case .restore: localization.string("backup.restoreTitle", defaultValue: "恢复剪贴板备份")
        case .rollback: localization.string("backup.rollback", defaultValue: "恢复本机回滚快照…")
        }
    }

    private var fileControls: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Label(localization.string("backup.file", defaultValue: "备份文件"), systemImage: "doc.zipper")
                    .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
                Spacer()
                Button(action == .backup
                       ? localization.string("backup.destination", defaultValue: "选择保存位置…")
                       : localization.string("backup.choose", defaultValue: "选择备份文件…")) {
                    if action == .backup { chooseDestination() } else { chooseSource() }
                }.disabled(model.isBusy)
            }
            if let sourceURL {
                Text(sourceURL.lastPathComponent).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text(sourceURL.deletingLastPathComponent().path)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
        }
    }

    private var passwordControls: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(localization.string("backup.password", defaultValue: "备份密码"), systemImage: "lock")
                .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: PluginSettingsTheme.Spacing.rowContentControl,
                 verticalSpacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                GridRow {
                    Text(localization.string("backup.password", defaultValue: "备份密码"))
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField(localization.string("backup.password", defaultValue: "备份密码"), text: $password)
                        .frame(minWidth: 120, idealWidth: 240, maxWidth: .infinity)
                        .focused($focusedPassword, equals: .password)
                        .onSubmit {
                            if action == .backup { focusedPassword = .confirmation }
                            else if canProceed { primaryAction() }
                        }
                }
                if action == .backup {
                    GridRow {
                        Text(localization.string("backup.confirmPassword", defaultValue: "再次输入密码"))
                            .fixedSize(horizontal: false, vertical: true)
                        SecureField(localization.string("backup.confirmPassword", defaultValue: "再次输入密码"), text: $confirmation)
                            .frame(minWidth: 120, idealWidth: 240, maxWidth: .infinity)
                            .focused($focusedPassword, equals: .confirmation)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 360, idealWidth: 480, maxWidth: .infinity)
            if password.utf8.count > 1_024 {
                Text(localization.string("backup.error.passwordTooLong", defaultValue: "密码过长，请缩短后重试。"))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red)
            }
            if action == .backup && !confirmation.isEmpty && password != confirmation {
                Text(localization.string("backup.passwordMismatch", defaultValue: "两次输入的密码不一致。"))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red)
            }
            Text(action == .backup
                 ? localization.string("backup.passwordWarning", defaultValue: "至少 12 个字符，可使用便于记忆的短语。请妥善保存，MacTools 无法找回密码。")
                 : localization.string("backup.unlockDescription", defaultValue: "输入创建此备份时设置的密码。验证和预览不会更改本机数据。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
        }.disabled(model.isBusy)
    }

    private var scopeControls: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(localization.string("backup.scope", defaultValue: "备份内容"), systemImage: "checklist")
                .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
            Toggle(localization.string("backup.saved", defaultValue: "已存项目"), isOn: $scope.saved)
            Toggle(localization.string("backup.snippets", defaultValue: "片段"), isOn: $scope.snippets)
            HStack {
                Toggle(localization.string("backup.history", defaultValue: "历史记录"), isOn: $scope.history)
                Spacer()
                Text("\(historyCount.formatted(.number.locale(PluginRuntimeLocalization.locale))) · \(Int64(historyBytes).formatted(.byteCount(style: .file).locale(PluginRuntimeLocalization.locale)))")
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
            Text(localization.string("backup.historyWarning", defaultValue: "历史记录可能包含敏感信息。仅在明确需要时加入备份。外部文件仅保存路径。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
        }.toggleStyle(.checkbox).disabled(model.isBusy)
    }

    private var canProceed: Bool {
        if model.preview != nil { return true }
        if action == .rollback { return true }
        if action == .backup { return sourceURL != nil && !scope.isEmpty && password.count >= 12 && password.utf8.count <= 1_024 && password == confirmation }
        return sourceURL != nil && !password.isEmpty && password.utf8.count <= 1_024
    }

    private var primaryTitle: String {
        if let preview = model.preview {
            return preview.replacement ? replacementTitle(preview.manifest.scope) : localization.string("backup.merge", defaultValue: "与本机合并（推荐）")
        }
        return action == .backup ? localization.string("backup.start", defaultValue: "创建备份")
            : localization.string("backup.preview", defaultValue: "验证并预览")
    }

    private var confirmationTitle: String {
        model.preview?.replacement == true ? primaryTitle
            : localization.string("backup.capacity.title", defaultValue: "关键词片段容量不足")
    }

    private var confirmationActionTitle: String {
        model.preview?.replacement == true ? primaryTitle
            : localization.string("backup.continueMerge", defaultValue: "继续合并")
    }

    private var restoreConfirmationMessage: String {
        guard let preview = model.preview else { return "" }
        var messages: [String] = []
        if preview.replacement {
            messages.append(localization.format("backup.removed", defaultValue: "将移除 %d 个本机项目的所选类别数据。提交前会创建本机加密回滚快照。", preview.summary.removed))
        }
        if preview.requiresKeywordCapacityConfirmation {
            messages.append(localization.format("backup.capacity.message", defaultValue: "所有导入片段内容都会保留。优先保留本机已有关键词，再按备份顺序保留导入关键词；超出容量的 %d 个导入关键词绑定将被移除，对应片段仍可手动粘贴。", preview.summary.capacityDisabledKeywords))
        }
        return messages.joined(separator: "\n\n")
    }

    private func categoryTitle(_ scope: ClipboardBackupScope) -> String {
        [scope.history ? localization.string("backup.history", defaultValue: "历史记录") : nil,
         scope.saved ? localization.string("backup.saved", defaultValue: "已存项目") : nil,
         scope.snippets ? localization.string("backup.snippets", defaultValue: "片段") : nil].compactMap { $0 }.joined(separator: " + ")
    }

    private func replacementTitle(_ scope: ClipboardBackupScope) -> String {
        if scope.isComplete { return localization.string("backup.replaceAll", defaultValue: "替换全部剪贴板数据") }
        return localization.format("backup.replaceScope", defaultValue: "替换 %@", categoryTitle(scope))
    }

    private func summary(_ value: ClipboardBackupSummary) -> some View {
        Text(localization.format("backup.summary", defaultValue: "新增 %d · 合并 %d · 冲突保留 %d · 跳过 %d · 停用关键词 %d · 文件路径失效 %d", value.added, value.merged, value.conflicts, value.skipped, value.disabledKeywords, value.missingFileReferences))
            .font(PluginSettingsTheme.Typography.rowDescription).textSelection(.enabled)
    }

    private func phaseText(_ phase: ClipboardBackupPhase) -> String {
        switch phase {
        case .reading: localization.string("backup.reading", defaultValue: "正在读取并派生密钥…")
        case .encrypting(let count): localization.format("backup.encrypting", defaultValue: "正在加密：%d 项", count)
        case .validating(let count): localization.format("backup.validating", defaultValue: "正在验证：%d 项", count)
        case .staging(let count, _): localization.format("backup.staging", defaultValue: "正在暂存：%d 项", count)
        case .finishing: localization.string("backup.finishing", defaultValue: "正在完成…")
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mactoolsclipboard") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        PluginPresentationSafety.prepareForWindowOrdering()
        if panel.runModal() == .OK, let url = panel.url {
            sourceURL = url
            password = ""
            model.preview = nil
            model.error = nil
            focusedPassword = .password
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mactoolsclipboard") ?? .data]
        panel.nameFieldStringValue = "Clipboard.mactoolsclipboard"
        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        sourceURL = selected.pathExtension.lowercased() == "mactoolsclipboard"
            ? selected : selected.appendingPathExtension("mactoolsclipboard")
        model.error = nil
        focusedPassword = .password
    }

    private func primaryAction() {
        guard !model.isBusy, !model.completed, canProceed else { return }
        if let preview = model.preview {
            if preview.replacement || preview.requiresKeywordCapacityConfirmation { confirmsRestore = true }
            else { commit() }
            return
        }
        let service = service
        if action == .backup {
            guard let url = sourceURL else { return }
            let password = password, scope = scope
            let excludedSavedMetadata = provisionalSavedMetadata()
            model.run(operation: { progress in
                try service.backUp(to: url, password: password, scope: scope,
                                   excludingSavedMetadata: excludedSavedMetadata, progress: progress)
            }) { _ in
                self.password = ""; confirmation = ""; model.completed = true
            }
        } else if action == .rollback {
            let excludedSavedMetadata = provisionalSavedMetadata()
            model.run(operation: { progress in
                try service.previewRollback(excludingSavedMetadata: excludedSavedMetadata, progress: progress)
            }) { model.preview = $0; missingOffset = 0; noticeOffset = 0; loadMissingPaths(); loadNotices() }
        } else if let sourceURL {
            let password = password, replacing = replacing
            let excludedSavedMetadata = provisionalSavedMetadata()
            model.run(operation: { progress in
                try service.preview(url: sourceURL, password: password, replacing: replacing,
                                    excludingSavedMetadata: excludedSavedMetadata, progress: progress)
            }) {
                model.preview = $0; missingOffset = 0; noticeOffset = 0; loadMissingPaths(); loadNotices()
            }
        }
    }

    private func loadMissingPaths() {
        guard let preview = model.preview else { return }
        let service = service, offset = missingOffset
        Task {
            let worker = Task.detached { try service.missingReferences(preview, offset: offset) }
            missingPaths = (try? await worker.value) ?? []
        }
    }

    private func loadNotices() {
        guard let preview = model.preview else { return }
        let service = service, offset = noticeOffset
        Task {
            let worker = Task.detached { try service.notices(preview, offset: offset) }
            notices = (try? await worker.value) ?? []
        }
    }

    private func commit(acceptingKeywordCapacityLoss: Bool = false) {
        guard let preview = model.preview else { return }
        let service = service
        let excludedSavedMetadata = provisionalSavedMetadata()
        model.run(operation: { progress in
            try service.commit(preview, acceptingKeywordCapacityLoss: acceptingKeywordCapacityLoss,
                               excludingSavedMetadata: excludedSavedMetadata, progress: progress)
            return preview.summary
        }) {
            password = ""; confirmation = ""; model.restored($0)
        }
    }
}
