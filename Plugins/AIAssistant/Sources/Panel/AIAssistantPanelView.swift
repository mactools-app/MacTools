import SwiftUI
import MacToolsPluginKit

@MainActor
final class AIAssistantPanelModel: ObservableObject {
    @Published var snapshot: AIAssistantPanelSnapshot = .idle
}

struct AIAssistantPanelHostView: View {
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    @ObservedObject var model: AIAssistantPanelModel
    let localization: PluginLocalization
    let onAction: (AIAssistantPanelAction) -> Void

    init(model: AIAssistantPanelModel, localization: PluginLocalization, onAction: @escaping (AIAssistantPanelAction) -> Void) {
        self.model = model
        self.localization = localization
        self.onAction = onAction
    }

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        AIAssistantPanelView(snapshot: model.snapshot, localization: localization, onAction: onAction)
            .environment(\.locale, locale)
            .environment(\.layoutDirection, locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }
}

struct AIAssistantPanelView: View {
    @Environment(\.locale) private var locale
    let snapshot: AIAssistantPanelSnapshot
    let localization: PluginLocalization
    let onAction: (AIAssistantPanelAction) -> Void

    @State private var editedSourceText = ""
    @State private var isEditingSource = false
    @FocusState private var isSourceFocused: Bool
    @State private var showReasoning = false
    @State private var copiedRecently = false

    init(
        snapshot: AIAssistantPanelSnapshot,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        onAction: @escaping (AIAssistantPanelAction) -> Void
    ) {
        self.snapshot = snapshot
        self.localization = localization
        self.onAction = onAction
    }

    var body: some View {
        let _ = locale
        VStack(alignment: .leading, spacing: 10) {
            headerSection
            sourceSection
            if let errorMessage, snapshot.phase != .success {
                tipCard(errorMessage)
            }
            resultSection
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 606)
        .frame(minHeight: 280, maxHeight: 460, alignment: .top)
        .onAppear {
            syncSourceText()
        }
        .onChange(of: snapshot.sourceText) {
            syncSourceText()
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.purple)

            Text(localization.string("panel.header.title", defaultValue: "AI 助手"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            if let result = snapshot.result {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(result.promptName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isRunActive {
                Button {
                    onAction(.stop)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(localization.string("panel.action.stop", defaultValue: "停止当前处理"))
            }

            if hasSessionContent {
                Button {
                    onAction(.discard)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(localization.string("panel.action.discard", defaultValue: "丢弃会话并关闭"))
            }

            Button {
                onAction(.hide)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(localization.string("panel.action.hide", defaultValue: "隐藏 (Esc)"))
        }
        .padding(.horizontal, 2)
    }

    private var isRunActive: Bool {
        snapshot.phase == .capturing || snapshot.phase == .processing
    }

    private var hasSessionContent: Bool {
        snapshot.sourceText?.isEmpty == false
            || snapshot.result != nil
            || snapshot.retainedResult != nil
    }

    // MARK: - Source Text Section (Double Click to Edit, Max 10 Lines)

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(localization.string("panel.source.title", defaultValue: "原始文本"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                if isEditingSource {
                    Text(localization.string("panel.source.editing", defaultValue: "（正在编辑）"))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(localization.string("panel.source.hint", defaultValue: "（双击文本或点按“编辑”）"))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary.opacity(0.8))
                }

                Spacer()

                if isEditingSource {
                    HStack(spacing: 6) {
                        Button(localization.string("panel.source.applyAndRerun", defaultValue: "应用并重新处理")) {
                            isEditingSource = false
                            isSourceFocused = false
                            let trimmed = editedSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && trimmed != (snapshot.sourceText ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
                                onAction(.reprocess(sourceText: trimmed))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)

                        Button(localization.string("common.cancel", defaultValue: "取消")) {
                            cancelSourceEdit()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                } else {
                    Button {
                        isEditingSource = true
                        isSourceFocused = true
                    } label: {
                        Label(localization.string("panel.source.editButton", defaultValue: "编辑"), systemImage: "pencil")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            Group {
                if isEditingSource {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $editedSourceText)
                            .font(.system(size: 13))
                            .focused($isSourceFocused)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                    }
                    .frame(minHeight: 52, maxHeight: 190)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                    )
                } else {
                    ScrollView {
                        Text(displaySourceText.isEmpty ? localization.string("panel.source.empty", defaultValue: "未检测到选中文本") : displaySourceText)
                            .font(.system(size: 13))
                            .foregroundStyle(displaySourceText.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    .frame(minHeight: 44, maxHeight: 190)
                    .background(panelCardColor, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        isEditingSource = true
                        isSourceFocused = true
                    }
                }
            }
        }
    }

    // MARK: - Result Section (Max 10 Lines, Copy Feedback & Confirm Button)

    private var resultSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                switch snapshot.phase {
                case .idle, .capturing:
                    statusText(localization.string("panel.status.capturing", defaultValue: "正在读取选中文本..."))
                case .processing:
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            statusText(
                                snapshot.retainedResult == nil
                                    ? localization.string("panel.status.processing", defaultValue: "正在处理...")
                                    : localization.string("panel.status.reprocessing", defaultValue: "正在重新处理，先前的结果暂时保留...")
                            )
                        }
                        if let retained = snapshot.retainedResult {
                            resultCard(retained)
                        }
                    }
                case .success:
                    if let result = snapshot.result {
                        resultCard(result)
                    }
                case .awaitingConfirmation:
                    confirmationCard
                case .error:
                    if let retained = snapshot.retainedResult {
                        resultCard(retained)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .frame(minHeight: 60, maxHeight: 220, alignment: .top)
    }

    private func resultCard(_ result: AIProcessResult) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.purple)
                    Text(result.promptName)
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    // Copy button with success feedback.
                    Button {
                        onAction(.copyResult)
                        copiedRecently = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copiedRecently = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copiedRecently ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(copiedRecently ? Color.green : Color.primary)
                            Text(copiedRecently ? localization.string("panel.result.copied", defaultValue: "已复制") : localization.string("panel.result.copy", defaultValue: "复制"))
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(result.text.isEmpty)
                }

                if let reasoning = result.reasoningText, !reasoning.isEmpty {
                    DisclosureGroup(isExpanded: $showReasoning) {
                        Text(reasoning)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.top, 4)
                    } label: {
                        Label(
                            localization.string("panel.reasoning.title", defaultValue: "思考过程"),
                            systemImage: "brain"
                        )
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }

                Text(result.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(panelCardColor, in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
    }

    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text(localization.string("panel.confirm.title", defaultValue: "疑似剪贴板内容"))
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(localization.string(
                "panel.confirm.description",
                defaultValue: "未能直接读取选中文本，以上内容来自剪贴板。请确认是否将其发送给 AI 处理。"
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    onAction(.confirmSource)
                } label: {
                    Label(
                        localization.string("panel.confirm.useText", defaultValue: "使用此文本"),
                        systemImage: "checkmark.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    onAction(.discard)
                } label: {
                    Label(
                        localization.string("panel.confirm.discard", defaultValue: "放弃"),
                        systemImage: "xmark.circle"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelCardColor, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.yellow.opacity(0.4), lineWidth: 1)
        )
    }

    private func tipCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.multicolor)
                Text(localization.string("panel.tip.title", defaultValue: "提示"))
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(message)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Button {
                    onAction(.retry)
                } label: {
                    Label(localization.string("panel.retryHelp", defaultValue: "重试"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if (snapshot.sourceText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        isEditingSource = true
                        editedSourceText = ""
                        isSourceFocused = true
                    } label: {
                        Label(
                            localization.string("panel.tip.enterTextManually", defaultValue: "手动输入文本"),
                            systemImage: "square.and.pencil"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    onAction(.openSettings)
                } label: {
                    Label(
                        localization.string("panel.tip.actionTitle", defaultValue: "如何解决"),
                        systemImage: "questionmark.bubble"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelCardColor, in: RoundedRectangle(cornerRadius: 8))
    }

    private var errorMessage: String? {
        switch snapshot.phase {
        case let .error(error):
            // Prefer the specific provider/configuration message recorded on
            // the snapshot over the generic error-case copy.
            return snapshot.errorMessage ?? error.message(localization: localization)
        default:
            return snapshot.errorMessage
        }
    }

    private var displaySourceText: String {
        let text = editedSourceText.isEmpty ? (snapshot.sourceText ?? "") : editedSourceText
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSourceModified: Bool {
        let trimmedOriginal = (snapshot.sourceText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEdited = editedSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedEdited.isEmpty && trimmedEdited != trimmedOriginal
    }

    private func syncSourceText() {
        if let source = snapshot.sourceText, !source.isEmpty {
            editedSourceText = source
        }
    }

    private func cancelSourceEdit() {
        isEditingSource = false
        isSourceFocused = false
        editedSourceText = snapshot.sourceText ?? ""
    }

    private var panelCardColor: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }
}
