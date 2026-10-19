import SwiftUI
import MacToolsPluginKit

/// Sample snapshots use the host row renderer, without loading plugins or invoking actions.
struct StarterPackPanelPreview: View {
    @ObservedObject var controller: StarterPackController
    var showsAppliedSelection = false

    private var draft: StarterPackDraft {
        showsAppliedSelection ? controller.appliedDraft ?? controller.draft : controller.draft
    }

    private var selectedIDs: [String] {
        showsAppliedSelection ? controller.results.map(\.id) : controller.selectedIDs
    }

    private var panelIDs: [String] {
        let items = showsAppliedSelection ? controller.appliedPanelItems : controller.recommendedPanelItems
        return draft.addToPanel ? items.map(\.pluginID) : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(FeatureL10n.string("设置预览"), systemImage: "eye")
                .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
            VStack(spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                if panelIDs.isEmpty {
                    Text(FeatureL10n.string("面板保持不变。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
                    ForEach(panelIDs, id: \.self) { id in
                        if id == "system-status" { systemStatus }
                        else { previewRow(id) }
                    }
                }
            }
            .padding(PluginSettingsTheme.Spacing.rowHorizontal)
            .pluginSettingsCardBackground(.standard)
            .disabled(true)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mactools.starter-packs.panel-preview")
            Text(FeatureL10n.string("预览随选择更新，数值仅为示例。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            let otherIDs = selectedIDs.filter { !panelIDs.contains($0) }
            if !otherIDs.isEmpty {
                Text(FeatureL10n.string("也包含"))
                    .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
                Text(otherIDs.map(StarterPack.title(for:)).joined(separator: " · "))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
            if draft.seedGrid && (showsAppliedSelection
                ? selectedIDs.contains("action-grid") && selectedIDs.contains("window-layouts")
                : controller.canSeedGrid) {
                Label(FeatureL10n.string("左半屏") + " · " + FeatureL10n.string("右半屏") + " · " + FeatureL10n.string("最大化"), systemImage: "square.grid.3x3")
                    .font(PluginSettingsTheme.Typography.rowDescription)
            }
        }
    }

    private var systemStatus: some View {
        HStack {
            metric("CPU", value: "12")
            metric(FeatureL10n.string("内存"), value: "50")
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            PluginMetricValue(value, unit: "%", isProminent: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PluginSettingsTheme.Spacing.rowVertical)
        .pluginSettingsCardBackground(.recessed)
    }

    private func previewRow(_ id: String) -> some View {
        let switches: Set<String> = ["keep-awake", "microphone-mute", "stage-manager", "auto-hide-dock", "night-shift", "display-true-color"]
        let snapshot = PluginPanelRowSnapshot(
            id: id, title: StarterPack.title(for: id), iconName: StarterPack.symbol(for: id), iconTint: .secondary,
            controlStyle: switches.contains(id) ? .switch : .button, menuActionBehavior: .keepPresented,
            description: "", helpText: "", descriptionTone: .secondary,
            isOn: false, isExpanded: false, isEnabled: true, detail: nil,
            buttonActionID: nil, buttonTitle: FeatureL10n.string("打开")
        )
        return FeatureRowView(
            item: snapshot, indicator: nil, compactIndicator: nil,
            onDisclosureToggle: { _ in }, onSelectionChange: { _, _ in },
            onNavigationSelectionChange: { _, _ in }, onNavigationHoverChange: { _, _, _ in },
            onNavigationRowFrameChange: { _, _, _ in }, onDateChange: { _, _ in },
            onSwitchChange: { _ in false }, onSliderChange: { _, _, _ in }, onActionInvoke: { _, _ in }
        )
    }
}
