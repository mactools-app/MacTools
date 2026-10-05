import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

struct MenuBarPanelThemeSettingsRow: View {
    @ObservedObject var themeStore: MenuBarPanelThemeStore
    let appearancePreference: AppAppearancePreference

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var pickerPresentation: MenuBarPanelThemePickerPresentation?

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            Button {
                presentPicker(for: preferredPickerAppearance)
            } label: {
                HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: GeneralSettingsCardLayout.iconCornerRadius,
                            style: .continuous
                        )
                        .fill(Color.accentColor.opacity(0.12))

                        Image(systemName: "paintpalette.fill")
                            .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(
                        width: GeneralSettingsCardLayout.iconSize,
                        height: GeneralSettingsCardLayout.iconSize
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppL10n.settings("panelTheme.title", defaultValue: "主题"))
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                        Text(summary)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            themeSwatches

            Button {
                presentPicker(for: preferredPickerAppearance)
            } label: {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: GeneralSettingsCardLayout.minRowHeight,
            alignment: .leading
        )
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .help(AppL10n.settings("panelTheme.help", defaultValue: "选择菜单栏面板的颜色主题"))
        .sheet(item: $pickerPresentation) { presentation in
            MenuBarPanelThemePickerSheet(
                themeStore: themeStore,
                appearancePreference: appearancePreference,
                initialAppearance: presentation.appearance
            )
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
        }
    }

    private var summary: String {
        switch appearancePreference {
        case .system:
            return AppL10n.settingsFormat(
                "panelTheme.summary.auto",
                defaultValue: "浅色：%@ · 深色：%@",
                themeStore.selectedThemeName(for: .light),
                themeStore.selectedThemeName(for: .dark)
            )
        case .light:
            return themeStore.selectedThemeName(for: .light)
        case .dark:
            return themeStore.selectedThemeName(for: .dark)
        }
    }

    @ViewBuilder
    private var themeSwatches: some View {
        switch appearancePreference {
        case .system:
            HStack(spacing: 4) {
                themeSwatchButton(appearance: .light)
                themeSwatchButton(appearance: .dark)
            }
        case .light:
            themeSwatchButton(appearance: .light)
        case .dark:
            themeSwatchButton(appearance: .dark)
        }
    }

    private func themeSwatchButton(appearance: MenuBarPanelThemeAppearance) -> some View {
        Button {
            presentPicker(for: appearance)
        } label: {
            MenuBarPanelThemeSwatch(themeStore: themeStore, appearance: appearance)
        }
        .buttonStyle(.plain)
        .help(
            appearance == .light
                ? AppL10n.settings("appearance.light", defaultValue: "浅色")
                : AppL10n.settings("appearance.dark", defaultValue: "深色")
        )
        .accessibilityLabel(
            appearance == .light
                ? AppL10n.settings("appearance.light", defaultValue: "浅色")
                : AppL10n.settings("appearance.dark", defaultValue: "深色")
        )
    }

    private var preferredPickerAppearance: MenuBarPanelThemeAppearance {
        MenuBarPanelThemePickerRouting.preferredAppearance(
            for: appearancePreference,
            colorScheme: colorScheme
        )
    }

    private func presentPicker(for appearance: MenuBarPanelThemeAppearance) {
        pickerPresentation = MenuBarPanelThemePickerPresentation(appearance: appearance)
    }
}

struct MenuBarPanelThemePickerPresentation: Identifiable, Equatable {
    let id = UUID()
    let appearance: MenuBarPanelThemeAppearance
}

private struct MenuBarPanelThemeSwatch: View {
    @ObservedObject var themeStore: MenuBarPanelThemeStore
    let appearance: MenuBarPanelThemeAppearance

    var body: some View {
        let colorScheme = MenuBarPanelThemeResolver.colorScheme(for: appearance)
        let style = MenuBarPanelThemeResolver.resolve(
            definition: themeStore.selectedDefinition(for: appearance),
            colorScheme: colorScheme,
            contrast: .standard
        )

        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(style.surfaces.panel)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(style.surfaces.card)
                .frame(width: 23, height: 14)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(style.accent)
                        .frame(width: 10, height: 2.5)
                        .padding(.leading, 3)
                }
        }
        .frame(width: 34, height: 25)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .environment(\.colorScheme, colorScheme)
        .accessibilityHidden(true)
    }
}

private struct MenuBarPanelThemePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var themeStore: MenuBarPanelThemeStore
    let appearancePreference: AppAppearancePreference

    @State private var selectedAppearance: MenuBarPanelThemeAppearance
    @State private var alertMessage: String?
    @State private var pendingDeletion: MenuBarPanelThemeDefinition?

    private let headerControlHeight: CGFloat = 28

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    init(
        themeStore: MenuBarPanelThemeStore,
        appearancePreference: AppAppearancePreference,
        initialAppearance: MenuBarPanelThemeAppearance
    ) {
        self.themeStore = themeStore
        self.appearancePreference = appearancePreference
        _selectedAppearance = State(initialValue: initialAppearance)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    themeCard(definition: nil)

                    ForEach(builtInThemes) { theme in
                        themeCard(definition: theme)
                    }

                    ForEach(importedThemes) { theme in
                        themeCard(definition: theme)
                    }
                }
                .padding(20)
            }

            Divider()

            footer
        }
        .frame(width: 700, height: 620)
        .alert(
            AppL10n.settings("panelTheme.alert.title", defaultValue: "主题"),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button(AppL10n.settings("common.ok", defaultValue: "好"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .confirmationDialog(
            AppL10n.settings("panelTheme.delete.title", defaultValue: "删除导入的主题？"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(AppL10n.settings("panelTheme.delete.action", defaultValue: "删除主题"), role: .destructive) {
                if let pendingDeletion {
                    themeStore.deleteImportedTheme(id: pendingDeletion.id)
                }
                pendingDeletion = nil
            }
            Button(AppL10n.settings("common.cancel", defaultValue: "取消"), role: .cancel) {
                pendingDeletion = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.settings("panelTheme.picker.title", defaultValue: "主题"))
                    .font(.title3.weight(.semibold))

                Text(AppL10n.settings(
                    "panelTheme.picker.description",
                    defaultValue: "主题会实时调整菜单栏面板的界面色彩；布局、字体、日历事件色和品牌色保持不变。"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if appearancePreference == .system {
                Picker("", selection: $selectedAppearance) {
                    Text(AppL10n.settings("appearance.light", defaultValue: "浅色"))
                        .tag(MenuBarPanelThemeAppearance.light)
                    Text(AppL10n.settings("appearance.dark", defaultValue: "深色"))
                        .tag(MenuBarPanelThemeAppearance.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140, height: headerControlHeight)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: headerControlHeight, height: headerControlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(AppL10n.settings("panelTheme.close", defaultValue: "关闭"))
        }
        .padding(20)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button {
                    importTheme()
                } label: {
                    Label(
                        AppL10n.settings("panelTheme.import", defaultValue: "导入主题…"),
                        systemImage: "square.and.arrow.down"
                    )
                }
                .controlSize(.small)

                Spacer()

                Link(destination: Self.moreThemesURL) {
                    Label(
                        AppL10n.settings("panelTheme.findMore", defaultValue: "寻找更多主题"),
                        systemImage: "arrow.up.right"
                    )
                }
                .font(.subheadline.weight(.medium))
            }

            Text(AppL10n.settings(
                "panelTheme.findMore.description",
                defaultValue: "可从 iTerm2 Color Schemes 预览并下载主题。支持 .itermcolors（含 .txt）和 Base16/Base24 YAML/JSON。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private static let moreThemesURL = URL(
        string: "https://iterm2colorschemes.com/"
    )!

    private var builtInThemes: [MenuBarPanelThemeDefinition] {
        MenuBarPanelBuiltInThemes.all.filter { $0.appearance == selectedAppearance }
    }

    private var importedThemes: [MenuBarPanelThemeDefinition] {
        themeStore.importedThemes.filter { $0.appearance == selectedAppearance }
    }

    @ViewBuilder
    private func themeCard(definition: MenuBarPanelThemeDefinition?) -> some View {
        let id = definition?.id ?? MenuBarPanelThemeDefinition.systemThemeID
        let isSelected = themeStore.selectedThemeID(for: selectedAppearance) == id

        HStack(alignment: .bottom, spacing: 8) {
            Button {
                selectTheme(id: id)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    MenuBarPanelThemePreview(
                        definition: definition,
                        appearance: selectedAppearance
                    )

                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(definition?.name ?? AppL10n.settings(
                                "panelTheme.systemDefault",
                                defaultValue: "系统默认"
                            ))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                            Text(themeSubtitle(definition))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        selectTheme(id: id)
                        dismiss()
                    }
            )

            if let definition, themeStore.isImportedTheme(id: definition.id) {
                Button(role: .destructive) {
                    pendingDeletion = definition
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(AppL10n.settings("panelTheme.delete.action", defaultValue: "删除主题"))
            }
        }
        .padding(10)
        .background(Color.primary.opacity(isSelected ? 0.08 : 0.035))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.06),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        }
    }

    private func selectTheme(id: String) {
        _ = themeStore.selectTheme(id: id, for: selectedAppearance)
    }

    private func themeSubtitle(_ definition: MenuBarPanelThemeDefinition?) -> String {
        guard let definition else {
            return AppL10n.settings("panelTheme.system.description", defaultValue: "跟随 macOS 语义颜色")
        }
        if definition.origin == .imported {
            if let author = definition.author, !author.isEmpty {
                return author
            }
            return AppL10n.settings("panelTheme.imported", defaultValue: "已导入")
        }
        return definition.author ?? "Base16"
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var allowedContentTypes: [UTType] = [
            .json,
            .plainText,
            UTType(filenameExtension: "yaml") ?? .plainText,
            UTType(filenameExtension: "yml") ?? .plainText
        ]
        if let itermColorsType = UTType(filenameExtension: "itermcolors") {
            allowedContentTypes.append(itermColorsType)
        }
        panel.allowedContentTypes = allowedContentTypes
        panel.message = AppL10n.settings(
            "panelTheme.import.prompt",
            defaultValue: "选择 .itermcolors（或包含该内容的 .txt）、Base16/Base24 YAML/JSON 主题文件。"
        )

        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let theme = try themeStore.importTheme(from: url)
            if appearancePreference == .system || theme.appearance == selectedAppearance {
                selectedAppearance = theme.appearance
                _ = themeStore.selectTheme(id: theme.id, for: theme.appearance)
            } else {
                alertMessage = theme.appearance == .dark
                    ? AppL10n.settings(
                        "panelTheme.import.darkMismatch",
                        defaultValue: "主题已导入，但它属于深色主题。请切换应用外观后选择。"
                    )
                    : AppL10n.settings(
                        "panelTheme.import.lightMismatch",
                        defaultValue: "主题已导入，但它属于浅色主题。请切换应用外观后选择。"
                    )
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

private struct MenuBarPanelThemePreview: View {
    let definition: MenuBarPanelThemeDefinition?
    let appearance: MenuBarPanelThemeAppearance

    var body: some View {
        let colorScheme = MenuBarPanelThemeResolver.colorScheme(for: appearance)
        let style = MenuBarPanelThemeResolver.resolve(
            definition: definition,
            colorScheme: colorScheme,
            contrast: .standard
        )

        VStack(spacing: 5) {
            previewHeader(style)

            HStack(spacing: 6) {
                previewFeatureCard(style)
                previewComponentCard(style)
            }
        }
        .padding(8)
        .frame(height: 92)
        .background(style.surfaces.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, colorScheme)
        .accessibilityHidden(true)
    }

    private func previewHeader(_ style: MenuBarPanelThemeStyle) -> some View {
        ZStack {
            Capsule()
                .fill(style.surfaces.panel)
                .frame(width: 54, height: 15)
                .overlay {
                    Capsule()
                        .strokeBorder(style.surfaces.separator, lineWidth: 0.5)
                }
                .overlay {
                    HStack(spacing: 2) {
                        Capsule()
                            .fill(style.surfaces.tabSelection)
                            .frame(width: 25, height: 13)
                            .overlay {
                                Circle()
                                    .fill(style.text.primary)
                                    .frame(width: 5, height: 5)
                            }

                        Color.clear
                            .frame(width: 25, height: 13)
                            .overlay {
                                RoundedRectangle(cornerRadius: 1, style: .continuous)
                                    .fill(style.text.secondary)
                                    .frame(width: 8, height: 4)
                            }
                    }
                }

            HStack {
                Spacer(minLength: 0)

                Image(systemName: "gearshape")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(style.text.secondary)

                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(style.text.secondary)
            }
            .padding(.trailing, 1)
        }
        .frame(height: 15)
    }

    private func previewFeatureCard(_ style: MenuBarPanelThemeStyle) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(style.surfaces.control)
                .frame(width: 18, height: 18)
                .overlay {
                    Circle()
                        .fill(style.accent)
                        .frame(width: 6, height: 6)
                }

            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(style.text.primary).frame(width: 42, height: 4)
                Capsule().fill(style.text.secondary).frame(width: 58, height: 3)
            }

            Spacer(minLength: 3)

            Capsule()
                .fill(style.surfaces.track)
                .frame(width: 24, height: 13)
                .overlay(alignment: .trailing) {
                    Circle()
                        .fill(style.accent)
                        .frame(width: 9, height: 9)
                        .padding(.trailing, 2)
                }
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(style.surfaces.card)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func previewComponentCard(_ style: MenuBarPanelThemeStyle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(style.componentTheme.dataSeries.primary).frame(width: 5, height: 5)
                Capsule().fill(style.text.secondary).frame(width: 25, height: 3)
                Spacer(minLength: 2)
                HStack(spacing: 2) {
                    Circle().fill(style.status.success).frame(width: 3, height: 3)
                    Circle().fill(style.status.warning).frame(width: 3, height: 3)
                    Circle().fill(style.status.critical).frame(width: 3, height: 3)
                }
                .padding(.horizontal, 3)
                .frame(height: 7)
                .background(style.surfaces.control, in: Capsule())
            }

            HStack(alignment: .bottom, spacing: 3) {
                chartBar(color: style.componentTheme.dataSeries.primary, height: 9)
                chartBar(color: style.componentTheme.dataSeries.secondary, height: 15)
                chartBar(color: style.componentTheme.dataSeries.tertiary, height: 11)
                chartBar(color: style.componentTheme.dataSeries.quaternary, height: 18)
                chartBar(color: style.componentTheme.dataSeries.quinary, height: 13)
            }
            .padding(.horizontal, 5)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .background(style.surfaces.nested)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(6)
        .frame(width: 91)
        .frame(maxHeight: .infinity, alignment: .leading)
        .background(style.surfaces.card)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func chartBar(color: Color, height: CGFloat) -> some View {
        Capsule()
            .fill(color)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

enum MenuBarPanelThemePickerRouting {
    static func preferredAppearance(
        for preference: AppAppearancePreference,
        colorScheme: ColorScheme
    ) -> MenuBarPanelThemeAppearance {
        preference.themeAppearance
            ?? (colorScheme == .dark ? .dark : .light)
    }
}

private extension AppAppearancePreference {
    var themeAppearance: MenuBarPanelThemeAppearance? {
        switch self {
        case .system:
            nil
        case .dark:
            .dark
        case .light:
            .light
        }
    }
}
