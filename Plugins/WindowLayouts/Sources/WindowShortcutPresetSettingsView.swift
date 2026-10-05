import SwiftUI
import MacToolsPluginKit

private struct WindowShortcutPresetEditorRequest: Identifiable {
    let id = "window-shortcut-preset-editor"
    let initialPreset: WindowShortcutPreset
}

struct WindowShortcutPresetPreviewState {
    let preview: PluginActionShortcutPresetPreview?

    var changedCount: Int {
        preview?.items.filter(\.changesBinding).count ?? 0
    }

    var conflictCount: Int {
        preview?.items.filter { $0.conflictOwnerDescription != nil }.count ?? 0
    }

    var canApply: Bool {
        preview?.canApply == true && preview?.hasChanges == true
    }
}

@MainActor
struct WindowShortcutPresetSettingsView: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    @ObservedObject var plugin: WindowLayoutsPlugin

    @State private var editorRequest: WindowShortcutPresetEditorRequest?

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(
                alignment: .leading,
                spacing: PluginSettingsTheme.Spacing.rowTitleDescription
            ) {
                Text(plugin.localizedKey(
                    "settings.preset.current",
                    "当前快捷键方案"
                ))
                .font(PluginSettingsTheme.Typography.rowTitle)

                Text(plugin.localizedKey(
                    "settings.preset.currentDescription",
                    "打开预设助手，先查看更改和冲突，再决定是否应用。"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Label(
                plugin.currentShortcutPresetTitle,
                systemImage: plugin.currentShortcutPreset == nil
                    ? "slider.horizontal.3"
                    : "checkmark.circle.fill"
            )
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(
                plugin.currentShortcutPreset == nil ? Color.secondary : Color.green
            )
            .lineLimit(1)

            Button(plugin.localizedKey(
                "settings.preset.changeButton",
                "更改…"
            )) {
                editorRequest = WindowShortcutPresetEditorRequest(
                    initialPreset: plugin.initialShortcutPreset
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("mactools.window-layouts.shortcut-presets.change")
        }
        .sheet(item: $editorRequest) { request in
            WindowShortcutPresetEditorSheet(
                plugin: plugin,
                initialPreset: request.initialPreset
            )
            .environment(\.layoutDirection, layoutDirection)
            .environment(\.locale, locale)
        }
    }
}

@MainActor
private struct WindowShortcutPresetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var plugin: WindowLayoutsPlugin
    @State private var selectedPreset: WindowShortcutPreset
    @State private var proposedBindings: [String: ShortcutBinding]
    @State private var applyError: String?

    init(
        plugin: WindowLayoutsPlugin,
        initialPreset: WindowShortcutPreset
    ) {
        self.plugin = plugin
        _selectedPreset = State(initialValue: initialPreset)
        _proposedBindings = State(
            initialValue: plugin.shortcutPresetBindings(for: initialPreset)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: PluginSettingsTheme.Spacing.section
                ) {
                    presetSelection
                    previewSection

                    if let applyError {
                        Label(applyError, systemImage: "exclamationmark.triangle.fill")
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(PluginSettingsTheme.Spacing.cardContent)
            }

            Divider()

            footer
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 500, idealHeight: 560)
        .onChange(of: selectedPreset) { _, _ in
            applyError = nil
            proposedBindings = plugin.shortcutPresetBindings(for: selectedPreset)
        }
    }

    private var header: some View {
        VStack(
            alignment: .leading,
            spacing: PluginSettingsTheme.Spacing.rowTitleDescription
        ) {
            Text(plugin.localizedKey(
                "settings.preset.sheetTitle",
                "更改快捷键预设"
            ))
            .font(PluginSettingsTheme.Typography.pageTitle)

            Text(plugin.localizedKey(
                "settings.preset.sheetDescription",
                "选择预设并逐项查看更改；在点击应用前，不会修改任何快捷键。"
            ))
            .font(PluginSettingsTheme.Typography.pageDescription)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PluginSettingsTheme.Spacing.cardContent)
    }

    private var presetSelection: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(
                alignment: .leading,
                spacing: PluginSettingsTheme.Spacing.rowTitleDescription
            ) {
                Text(plugin.localizedKey(
                    "settings.preset.sheetPicker",
                    "要预览的预设"
                ))
                .font(PluginSettingsTheme.Typography.rowTitle)

                Text(plugin.localizedKey(
                    "settings.preset.selectionDescription",
                    "选择预设只会更新预览，不会立即应用。"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            statusBadge

            Picker("", selection: $selectedPreset) {
                ForEach(WindowShortcutPreset.allCases, id: \.self) { preset in
                    Text(plugin.shortcutPresetTitle(preset)).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 240)
            .accessibilityLabel(plugin.localizedKey(
                "settings.preset.sheetPicker",
                "要预览的预设"
            ))
        }
        .pluginSettingsListRowPadding(interactive: true)
        .pluginSettingsCardBackground(.standard)
    }

    private var previewSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Label(
                    plugin.localizedKey("settings.preset.preview", "更改预览"),
                    systemImage: previewSystemImage
                )
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Spacer()

                Text(previewSummary)
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(previewSummaryColor)
            }
            .pluginSettingsListRowPadding()

            if let preview {
                ForEach(
                    Array(plugin.orderedShortcutPresetPreviewItems(preview).enumerated()),
                    id: \.element.actionID
                ) { _, item in
                    PluginSettingsListDivider()
                    previewRow(item)
                }
            }

            if let errorMessage = preview?.errorMessage {
                PluginSettingsListDivider()
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pluginSettingsListRowPadding()
            }
        }
        .pluginSettingsCardBackground(.standard)
    }

    private func previewRow(
        _ item: PluginActionShortcutPresetPreviewItem
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: PluginSettingsTheme.Spacing.rowVertical
        ) {
            HStack(
                alignment: .firstTextBaseline,
                spacing: PluginSettingsTheme.Spacing.rowContentControl
            ) {
                Text(plugin.shortcutPresetActionTitle(item.actionID))
                    .font(PluginSettingsTheme.Typography.rowTitle)

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                previewStatus(item)
            }

            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                currentBindingBlock(
                    label: plugin.localizedKey(
                        "settings.preset.currentBinding",
                        "当前"
                    ),
                    bindings: plugin.shortcutPresetCurrentBindings(for: item.actionID)
                )

                Image(systemName: "arrow.forward")
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                proposedBindingRecorder(
                    label: plugin.localizedKey(
                        "settings.preset.proposedBinding",
                        "建议"
                    ),
                    item: item
                )
            }
        }
        .pluginSettingsListRowPadding()
        .background(
            item.conflictOwnerDescription == nil
                ? Color.clear
                : Color.red.opacity(0.08)
        )
    }

    @ViewBuilder
    private func previewStatus(
        _ item: PluginActionShortcutPresetPreviewItem
    ) -> some View {
        if let conflictOwnerDescription = item.conflictOwnerDescription {
            Label(
                String(
                    format: plugin.localizedKey(
                        "settings.preset.conflictOwner",
                        "与“%@”冲突"
                    ),
                    conflictOwnerDescription
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(.red)
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
        } else if item.changesBinding {
            Label(
                plugin.localizedKey("settings.preset.willChange", "将更改"),
                systemImage: "arrow.forward.circle"
            )
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(.secondary)
        } else {
            Label(
                plugin.localizedKey("settings.preset.unchanged", "无更改"),
                systemImage: "checkmark.circle"
            )
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(.tertiary)
        }
    }

    private func currentBindingBlock(
        label: String,
        bindings: [ShortcutBinding]
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: PluginSettingsTheme.Spacing.rowTitleDescription
        ) {
            Text(label)
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(.secondary)

            if bindings.isEmpty {
                PluginShortcutRecorderField(
                    displayText: plugin.shortcutBindingTitle(nil),
                    isRecording: false,
                    minWidth: 0
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(bindings.enumerated()), id: \.offset) { _, binding in
                    PluginShortcutRecorderField(
                        displayText: plugin.shortcutBindingTitle(binding),
                        isRecording: false,
                        minWidth: 0
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func proposedBindingRecorder(
        label: String,
        item: PluginActionShortcutPresetPreviewItem
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: PluginSettingsTheme.Spacing.rowTitleDescription
        ) {
            Text(label)
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(item.conflictOwnerDescription == nil ? Color.accentColor : Color.red)

            PluginShortcutRecorder(
                title: plugin.shortcutPresetActionTitle(item.actionID),
                displayText: plugin.shortcutBindingTitle(item.proposedBinding),
                minWidth: 0,
                onRecord: { binding in
                    record(binding, for: item.actionID)
                }
            )
            .frame(maxWidth: .infinity)
            .overlay {
                if item.conflictOwnerDescription != nil {
                    RoundedRectangle(
                        cornerRadius: PluginSettingsTheme.Radius.field,
                        style: .continuous
                    )
                    .stroke(Color.red.opacity(0.65), lineWidth: 1.5)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Text(footerMessage)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(conflictCount > 0 ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Button(plugin.localizedKey(
                "settings.preset.cancelButton",
                "取消"
            )) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(plugin.localizedKey(
                "settings.preset.applyButton",
                "应用预设"
            )) {
                applyPreset()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply)
            .accessibilityIdentifier("mactools.window-layouts.shortcut-presets.apply")
        }
        .controlSize(.small)
        .padding(PluginSettingsTheme.Spacing.cardContent)
    }

    private var preview: PluginActionShortcutPresetPreview? {
        plugin.shortcutPresetPreview(bindingsByActionID: proposedBindings)
    }

    private var changedCount: Int {
        previewState.changedCount
    }

    private var conflictCount: Int {
        previewState.conflictCount
    }

    private var canApply: Bool {
        previewState.canApply
    }

    private var previewState: WindowShortcutPresetPreviewState {
        WindowShortcutPresetPreviewState(preview: preview)
    }

    private var statusBadge: some View {
        Label(statusText, systemImage: statusSystemImage)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var statusText: String {
        if preview?.hasChanges == false {
            return plugin.localizedKey("settings.preset.appliedStatus", "已应用")
        }
        return plugin.localizedKey("settings.preset.notAppliedStatus", "尚未应用")
    }

    private var statusSystemImage: String {
        preview?.hasChanges == false ? "checkmark.circle.fill" : "clock.fill"
    }

    private var statusColor: Color {
        preview?.hasChanges == false ? .green : .orange
    }

    private var previewSystemImage: String {
        conflictCount > 0 ? "exclamationmark.triangle.fill" : "list.bullet.rectangle"
    }

    private var previewSummary: String {
        guard preview != nil else {
            return plugin.localizedKey(
                "settings.preset.previewUnavailable",
                "当前无法预览。"
            )
        }
        if conflictCount > 0 {
            if conflictCount == 1 {
                return plugin.localizedKey(
                    "settings.preset.conflictCountOne",
                    "1 个快捷键冲突"
                )
            }
            return String(
                format: plugin.localizedKey(
                    "settings.preset.conflictCount",
                    "%d 个快捷键冲突"
                ),
                conflictCount
            )
        }
        if changedCount == 0 {
            return plugin.localizedKey(
                "settings.preset.alreadyApplied",
                "当前快捷键已与此预设一致。"
            )
        }
        if changedCount == 1 {
            return plugin.localizedKey(
                "settings.preset.changeCountOne",
                "1 项更改"
            )
        }
        return String(
            format: plugin.localizedKey(
                "settings.preset.changeCount",
                "%d 项更改"
            ),
            changedCount
        )
    }

    private var previewSummaryColor: Color {
        if preview == nil {
            return .orange
        }
        if conflictCount > 0 {
            return .red
        }
        return changedCount == 0 ? .green : .secondary
    }

    private var footerMessage: String {
        if conflictCount > 0 {
            return plugin.localizedKey(
                "settings.preset.resolveConflicts",
                "请先解决标记的快捷键冲突，再应用预设。"
            )
        }
        if changedCount == 0 {
            return plugin.localizedKey(
                "settings.preset.alreadyApplied",
                "当前快捷键已与此预设一致。"
            )
        }
        return plugin.localizedKey(
            "settings.preset.notAppliedDescription",
            "在点击“应用预设”前，不会修改任何快捷键。"
        )
    }

    private func applyPreset() {
        guard canApply else { return }
        if let error = plugin.applyShortcutPreset(
            selectedPreset,
            bindingsByActionID: proposedBindings
        ) {
            applyError = error
            return
        }
        dismiss()
    }

    private func record(
        _ binding: ShortcutBinding,
        for actionID: String
    ) -> PluginShortcutRecordingResult {
        var candidateBindings = proposedBindings
        candidateBindings[actionID] = binding

        guard let candidatePreview = plugin.shortcutPresetPreview(
            bindingsByActionID: candidateBindings
        ) else {
            return .rejected(plugin.localizedKey(
                "settings.preset.previewUnavailable",
                "当前无法预览。"
            ))
        }
        if let errorMessage = candidatePreview.errorMessage {
            return .rejected(errorMessage)
        }
        if let conflict = candidatePreview.items.first(where: {
            $0.proposedBinding == binding && $0.conflictOwnerDescription != nil
        }), let conflictOwnerDescription = conflict.conflictOwnerDescription {
            return .rejected(String(
                format: plugin.localizedKey(
                    "settings.preset.conflictOwner",
                    "与“%@”冲突"
                ),
                conflictOwnerDescription
            ))
        }

        proposedBindings = candidateBindings
        applyError = nil
        return .accepted
    }
}
