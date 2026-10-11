import AppKit
import MacToolsPluginKit
import SwiftUI

@MainActor
struct ClipboardSnippetKeywordNotice: View {
    @ObservedObject var settings: ClipboardHistorySettingsStore
    let localization: PluginLocalization

    var isExpansionDisabled: Bool { !settings.isKeywordExpansionEnabled }

    var body: some View {
        if isExpansionDisabled {
            HStack(spacing: 10) {
                Label(
                    localization.string(
                        "saved.keyword.disabled",
                        defaultValue: "Keyword expansion is off. You can still paste this snippet manually."
                    ),
                    systemImage: "keyboard"
                )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(localization.string("saved.keyword.enable", defaultValue: "Enable")) {
                    settings.isKeywordExpansionEnabled = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(localization.string(
                    "settings.saved.expansion.title", defaultValue: "Expand Snippet Keywords"
                ))
            }
            .padding(10)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("mactools.clipboard.snippet.keyword-disabled")
        }
    }
}

struct ClipboardSnippetEditorSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    let initialDraft: ClipboardSnippetDraft
    @ObservedObject var settings: ClipboardHistorySettingsStore
    let errorMessage: String?
    let localization: PluginLocalization
    let previewPasteboard: any ClipboardPasteboardAccess
    let onSave: (ClipboardSnippetDraft) async -> Bool
    let onCancel: () -> Void

    @State private var draft: ClipboardSnippetDraft
    @State private var tagsText: String
    @State private var preview: Result<ClipboardSnippetExpansion, Error>?
    @State private var isSaving = false
    @State private var contentSelection = NSRange(location: 0, length: 0)
    @State private var variablePickerRequest: VariablePickerRequest?
    @State private var previewTask: Task<Void, Never>?

    private struct VariablePickerRequest: Identifiable {
        let id = UUID()
        let text: String
        let selection: NSRange
    }

    init(
        initialDraft: ClipboardSnippetDraft,
        settings: ClipboardHistorySettingsStore,
        errorMessage: String?,
        localization: PluginLocalization,
        previewPasteboard: any ClipboardPasteboardAccess,
        onSave: @escaping (ClipboardSnippetDraft) async -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.initialDraft = initialDraft
        self.settings = settings
        self.errorMessage = errorMessage
        self.localization = localization
        self.previewPasteboard = previewPasteboard
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initialDraft)
        _tagsText = State(initialValue: initialDraft.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(draft.isNew
                    ? localization.string("saved.editor.new", defaultValue: "New Snippet")
                    : localization.string("saved.editor.edit", defaultValue: "Edit Snippet"))
                    .font(PluginSettingsTheme.Typography.pageTitle)
                Spacer()
                Button {
                    variablePickerRequest = VariablePickerRequest(text: draft.content, selection: contentSelection)
                } label: {
                    Label(
                        localization.string("saved.editor.variable", defaultValue: "Insert Variable"),
                        systemImage: "curlybraces"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .sheet(item: $variablePickerRequest) { request in
                    ClipboardSnippetVariablePicker(
                        text: request.text,
                        selection: request.selection,
                        localization: localization,
                        previewPasteboard: previewPasteboard,
                        onInsert: insertVariable,
                        maximumExpandedTextByteCount: settings.maximumExpandedTextByteCount
                    )
                    .environment(\.locale, locale)
                    .environment(\.layoutDirection, layoutDirection)
                }
            }

            TextField(localization.string("saved.editor.title", defaultValue: "Name"), text: $draft.title)
            ClipboardSnippetTextEditor(
                text: $draft.content,
                selectedRange: $contentSelection
            )
                .font(.body)
                .frame(minHeight: 220)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
                }
            HStack(spacing: 12) {
                TextField(localization.string("saved.editor.tags", defaultValue: "Tags, separated by commas"), text: $tagsText)
                TextField(
                    localization.string("saved.editor.keyword", defaultValue: "Expansion keyword (optional)"),
                    text: Binding(
                        get: { draft.keyword ?? "" },
                        set: { draft.keyword = $0.isEmpty ? nil : $0 }
                    )
                )
                .frame(maxWidth: 240)
            }
            Text(localization.string(
                "saved.editor.keywordHint",
                defaultValue: "Unique keywords expand as you type in supported editors. Keywords that prefix another keyword wait for Space. Requires Accessibility permission."
            ))
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)
            ClipboardSnippetKeywordNotice(settings: settings, localization: localization)
            if let preview {
                switch preview {
                case let .success(expansion):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localization.string("saved.editor.preview", defaultValue: "Preview"))
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        Text(expansion.text)
                            .textSelection(.enabled)
                            .lineLimit(5)
                    }
                case let .failure(error):
                    Label(
                        (error as? ClipboardSnippetTemplateError)?.localizedMessage(localization)
                            ?? error.localizedDescription,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                        .foregroundStyle(.red)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(localization.string("saved.editor.preview", defaultValue: "Preview")) {
                    previewTask?.cancel()
                    let template = draft.content
                    let maximumByteCount = settings.maximumExpandedTextByteCount
                    previewTask = Task {
                        let needsClipboard = await Task.detached {
                            ClipboardSnippetTemplateEngine.requiresClipboardText(template)
                        }.value
                        guard !Task.isCancelled else { return }
                        let clipboardText = needsClipboard
                            ? await ClipboardSnippetPreviewClipboard.readText(
                                from: previewPasteboard,
                                maximumByteCount: maximumByteCount
                            )
                            : nil
                        guard !Task.isCancelled else { return }
                        var context = ClipboardSnippetExpansionContext.current(
                            clipboardText: clipboardText
                        )
                        context.maximumUTF8ByteCount = maximumByteCount
                        do {
                            let expansion = try await ClipboardSnippetTemplateEngine.expandAsync(template, context: context)
                            guard !Task.isCancelled else { return }
                            preview = .success(expansion)
                        } catch is CancellationError { return }
                        catch { preview = .failure(error) }
                    }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(localization.string("common.cancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(localization.string("common.save", defaultValue: "Save")) {
                    guard !isSaving else { return }
                    draft.tags = tagsText.split(separator: ",").map(String.init)
                    isSaving = true
                    let submittedDraft = draft
                    Task { @MainActor in
                        let didSave = await onSave(submittedDraft)
                        if !didSave { isSaving = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isSaving
                        || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.content.isEmpty
                )
            }
        }
        .padding(22)
        .frame(minWidth: 680, idealWidth: 720, minHeight: 480)
        .onChange(of: draft.content) { _, _ in previewTask?.cancel(); preview = nil }
        .onDisappear { previewTask?.cancel() }
    }

    private func insertVariable(_ insertion: String) {
        let result = ClipboardSnippetEditorInsertion.insert(
            insertion,
            into: draft.content,
            selectedRange: contentSelection
        )
        draft.content = result.text
        contentSelection = result.selectedRange
    }
}

enum ClipboardSnippetEditorInsertion {
    static func insert(
        _ insertion: String,
        into text: String,
        selectedRange: NSRange
    ) -> (text: String, selectedRange: NSRange) {
        let content = text as NSString
        let location = min(selectedRange.location, content.length)
        let length = min(selectedRange.length, content.length - location)
        let updatedText = content.replacingCharacters(
            in: NSRange(location: location, length: length),
            with: insertion
        )
        return (
            updatedText,
            NSRange(location: location + (insertion as NSString).length, length: 0)
        )
    }
}

@MainActor
private struct ClipboardSnippetTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ClipboardSnippetTextEditor

        init(parent: ClipboardSnippetTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.selectedRange = textView.selectedRange()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.string = text
        textView.setSelectedRange(selectedRange)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        let length = (text as NSString).length
        let location = min(selectedRange.location, length)
        let selectionLength = min(selectedRange.length, length - location)
        let clampedRange = NSRange(location: location, length: selectionLength)
        if textView.selectedRange() != clampedRange {
            textView.setSelectedRange(clampedRange)
        }
    }
}

extension ClipboardSnippetDraft: Identifiable {}

@MainActor
struct ClipboardSavedMetadataEditorSheet: View {
    let localization: PluginLocalization
    let onSave: (ClipboardSavedMetadataDraft) -> Void
    let onCancel: () -> Void

    @State private var draft: ClipboardSavedMetadataDraft
    @State private var tagsText: String

    init(
        initialDraft: ClipboardSavedMetadataDraft,
        localization: PluginLocalization,
        onSave: @escaping (ClipboardSavedMetadataDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.localization = localization
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initialDraft)
        _tagsText = State(initialValue: initialDraft.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localization.string("saved.editDetails", defaultValue: "Edit Details"))
                .font(PluginSettingsTheme.Typography.pageTitle)
            TextField(
                localization.string("saved.editor.title", defaultValue: "Name"),
                text: $draft.title
            )
            TextField(
                localization.string("saved.editor.tags", defaultValue: "Tags, separated by commas"),
                text: $tagsText
            )
            HStack {
                Spacer()
                Button(localization.string("common.cancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(localization.string("common.save", defaultValue: "Save")) {
                    draft.tags = tagsText.split(separator: ",").map(String.init)
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(minWidth: 520, idealWidth: 560)
    }
}
