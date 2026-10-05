import SwiftUI
import MacToolsPluginKit

@MainActor
struct WindowModifierDragSettingsView: View {
    @ObservedObject var plugin: WindowLayoutsPlugin

    private let modifierChoices: [(ShortcutModifiers, String, String, String)] = [
        (.control, "⌃", "settings.modifierDrag.control", "Control"),
        (.option, "⌥", "settings.modifierDrag.option", "Option"),
        (.shift, "⇧", "settings.modifierDrag.shift", "Shift"),
        (.command, "⌘", "settings.modifierDrag.command", "Command"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(plugin.localizedKey(
                        "settings.modifierDrag.enabled.title",
                        "按修饰键拖移窗口"
                    ))
                    .font(PluginSettingsTheme.Typography.rowTitle)

                    Text(plugin.localizedKey(
                        "settings.modifierDrag.enabled.description",
                        "移动指针即可拖移其下方窗口，不必按住鼠标按钮。"
                    ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                Toggle("", isOn: Binding(
                    get: { plugin.isModifierDragEnabled },
                    set: { plugin.setModifierDragEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)

            Divider()
                .padding(.leading, PluginSettingsTheme.Spacing.rowHorizontal)

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(plugin.localizedKey(
                        "settings.modifierDrag.modifiers.title",
                        "修饰键组合"
                    ))
                    .font(PluginSettingsTheme.Typography.rowTitle)

                    Text(plugin.localizedKey(
                        "settings.modifierDrag.modifiers.description",
                        "只能按住所选修饰键；按下其他修饰键将取消拖移。"
                    ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                HStack(spacing: 6) {
                    ForEach(modifierChoices, id: \.0.rawValue) { modifier, symbol, nameKey, fallbackName in
                        let name = plugin.localizedKey(nameKey, fallbackName)
                        let isSelected = plugin.modifierDragModifiers.contains(modifier)
                        Button {
                            toggle(modifier)
                        } label: {
                            Text(symbol)
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .frame(minWidth: 20)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityLabel(name)
                        .accessibilityValue(
                            isSelected
                                ? plugin.localizedKey("settings.modifierDrag.selected", "已选择")
                                : plugin.localizedKey("settings.modifierDrag.notSelected", "未选择")
                        )
                        .help(name)
                        .disabled(
                            plugin.modifierDragModifiers == modifier
                                && plugin.modifierDragModifiers.rawValue.nonzeroBitCount == 1
                        )
                    }
                }
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
            .disabled(!plugin.isModifierDragEnabled)

            Divider()
                .padding(.leading, PluginSettingsTheme.Spacing.rowHorizontal)

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(plugin.localizedKey(
                        "settings.modifierDrag.showsIndicator.title",
                        "显示修饰键拖移指示器"
                    ))
                    .font(PluginSettingsTheme.Typography.rowTitle)

                    Text(plugin.localizedKey(
                        "settings.modifierDrag.showsIndicator.description",
                        "按住修饰键或拖移窗口时，在指针旁显示状态提示。"
                    ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                Toggle("", isOn: Binding(
                    get: { plugin.showsModifierDragIndicator },
                    set: { plugin.setShowsModifierDragIndicator($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
            .disabled(!plugin.isModifierDragEnabled)
        }
    }

    private func toggle(_ modifier: ShortcutModifiers) {
        var modifiers = plugin.modifierDragModifiers
        if modifiers.contains(modifier) {
            modifiers.remove(modifier)
        } else {
            modifiers.insert(modifier)
        }
        guard !modifiers.isEmpty else { return }
        plugin.setModifierDragModifiers(modifiers)
    }
}
