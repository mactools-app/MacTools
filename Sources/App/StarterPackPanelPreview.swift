import AppKit
import SwiftUI
import MacToolsPluginKit

/// Static snapshots use the real panel chrome and row renderer without loading plugins.
struct StarterPackPanelPreview: View {
    static let preferredWidth = MenuBarPanelLayout.baseWidth + 2 * PluginSettingsTheme.Spacing.rowContentControl

    @ObservedObject var controller: StarterPackController
    var panels: [MenuBarPanelDefinition] = MenuBarPanelDefinition.defaults
    var showsAppliedSelection = false
    @ObservedObject private var themes = MenuBarPanelThemeStore.shared
    @ObservedObject private var localization = PluginRuntimeLocalization.source
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var headerImage: NSImage?
    @State private var contentImage: NSImage?

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

    private var definition: MenuBarPanelThemeDefinition? {
        themes.selectedDefinition(for: MenuBarPanelThemeResolver.appearance(for: colorScheme))
    }

    private var theme: MenuBarPanelThemeStyle {
        MenuBarPanelThemeResolver.resolve(definition: definition, colorScheme: colorScheme, contrast: contrast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(FeatureL10n.string("设置预览"), systemImage: "eye")
                .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                menuBar
                panel
            }
            .padding(PluginSettingsTheme.Spacing.rowContentControl)
            .pluginSettingsCardBackground(.recessed)
            .overlay {
                RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card, style: .continuous)
                    .strokeBorder(SettingsStyle.cardBorder, lineWidth: PluginSettingsTheme.Stroke.hairline)
            }
            Text(FeatureL10n.string("示例面板，数值仅供参考。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            let otherIDs = selectedIDs.filter { !panelIDs.contains($0) }
            if !otherIDs.isEmpty {
                let titles = otherIDs.map(StarterPack.title(for:)).joined(separator: " · ")
                Text(FeatureL10n.string("也包含") + "\n" + titles)
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    .lineLimit(3).help(titles)
            }
            if draft.seedGrid && (showsAppliedSelection
                ? selectedIDs.contains("action-grid") && selectedIDs.contains("window-layouts")
                : controller.canSeedGrid) {
                Label(FeatureL10n.string("左半屏") + " · " + FeatureL10n.string("右半屏") + " · " + FeatureL10n.string("最大化"), systemImage: "square.grid.3x3")
                    .font(PluginSettingsTheme.Typography.rowDescription)
            }
        }
        .onAppear(perform: renderSnapshots)
        .onChange(of: panelIDs) { _, _ in renderSnapshots() }
        .onChange(of: draft.panelID) { _, _ in renderSnapshots() }
        .onChange(of: panels) { _, _ in renderSnapshots() }
        .onChange(of: definition) { _, _ in renderSnapshots() }
        .onChange(of: colorScheme) { _, _ in renderSnapshots() }
        .onChange(of: contrast) { _, _ in renderSnapshots() }
        .onChange(of: layoutDirection) { _, _ in renderSnapshots() }
        .onChange(of: localization.revision) { _, _ in renderSnapshots() }
    }

    private var panel: some View {
        let shape = StarterPackPreviewPopoverShape(arrowCenterX: iconCenterX)
        return VStack(spacing: 0) {
            if let headerImage {
                Image(nsImage: headerImage).accessibilityHidden(true)
            }
            if panelIDs.isEmpty {
                Text(FeatureL10n.string("面板保持不变。"))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView {
                    if let contentImage {
                        Image(nsImage: contentImage)
                            .accessibilityLabel(Text(panelIDs.map(StarterPack.title(for:)).joined(separator: ", ")))
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 100)
                    }
                }
                .frame(minHeight: 100, idealHeight: min(contentImage?.size.height ?? 200, 320), maxHeight: 320)
            }
        }
        .padding(.top, StarterPackPreviewPopoverShape.arrowHeight)
        .frame(width: MenuBarPanelLayout.baseWidth)
        .background(theme.surfaces.panel, in: shape)
        .clipShape(shape)
        .overlay {
            shape.stroke(SettingsStyle.cardBorder, lineWidth: contrast == .increased
                ? PluginSettingsTheme.Stroke.standard : PluginSettingsTheme.Stroke.hairline)
        }
        .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
        .accessibilityIdentifier("mactools.starter-packs.panel-preview")
    }

    private var iconCenterX: CGFloat {
        // The icon's highlight and the menu bar's edge each use controlCluster padding.
        // SwiftUI mirrors both the shape and the menu bar automatically in right-to-left layouts.
        let inset = 2 * PluginSettingsTheme.Spacing.controlCluster + MenuBarIconProcessing.standardIconPointSize / 2
        return MenuBarPanelLayout.baseWidth - inset
    }

    private var menuBar: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text("MacTools").font(PluginSettingsTheme.Typography.secondaryLabel)
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.100percent")
            Image("MenuBarIcon")
                .renderingMode(.template).resizable().scaledToFit()
                .frame(width: MenuBarIconProcessing.standardIconPointSize, height: MenuBarIconProcessing.standardIconPointSize)
                .padding(.horizontal, PluginSettingsTheme.Spacing.controlCluster)
                .padding(.vertical, 2)
                .background(SettingsStyle.activeControlBackground, in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field))
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.controlCluster)
        .padding(.vertical, 4)
        .background(.bar, in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(FeatureL10n.string("从菜单栏打开 MacTools")))
    }

    @MainActor
    private func renderSnapshots() {
        let header = MenuBarPanelHeader(
            selectedTab: MenuBarPanelTab(id: draft.panelID), availableUpdateVersion: nil,
            canEditLayout: true, isEditingLayout: false, onTabSelection: { _ in },
            onEditLayout: {}, onOpenUpdate: {}, onOpenSettings: {}, onQuit: {}, panels: panels,
            canUndoLayout: false, editingFeedback: MenuBarPanelEditingFeedback(), onUndoLayout: {}
        )
        .frame(height: MenuBarPanelLayout.headerHeight)
        .padding(.horizontal, MenuBarPanelLayout.outerPadding)
        .padding(.top, MenuBarPanelLayout.panelTopPadding)
        headerImage = snapshot(AnyView(header))
        contentImage = snapshot(AnyView(StarterPackSamplePanelRows(pluginIDs: panelIDs)
            .padding(.horizontal, MenuBarPanelLayout.outerPadding)
            .padding(.top, MenuBarPanelLayout.contentTopPadding)
            .padding(.bottom, MenuBarPanelLayout.panelBottomPadding)))
    }

    /// The bitmap keeps native controls out of keyboard navigation as well as pointer hit testing.
    @MainActor
    private func snapshot(_ content: AnyView) -> NSImage? {
        let root = content
            .environmentObject(MenuBarPanelMenuPresenter())
            .environment(\.menuBarPanelTheme, theme)
            .environment(\.pluginComponentTheme, theme.componentTheme)
            .environment(\.menuBarPanelSurfaceWidth, MenuBarPanelLayout.surfaceWidth)
            .environment(\.colorScheme, colorScheme)
            .environment(\.locale, PluginRuntimeLocalization.locale)
            .environment(\.layoutDirection, layoutDirection)
            .foregroundStyle(theme.text.primary)
            .tint(theme.accent)
            .frame(width: MenuBarPanelLayout.baseWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(theme.surfaces.panel)
        let hosting = NSHostingView(rootView: root)
        let size = hosting.fittingSize
        guard size.height.isFinite, size.height > 0 else { return nil }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let appearance: NSAppearance.Name = contrast == .increased
            ? (colorScheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (colorScheme == .dark ? .darkAqua : .aqua)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}

/// One continuous outline keeps the arrow joined to the sample panel without a seam.
private struct StarterPackPreviewPopoverShape: Shape {
    static let arrowHeight: CGFloat = 10
    let arrowCenterX: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + Self.arrowHeight
        let radius = MenuBarPanelLayout.cornerRadius
        let center = rect.minX + arrowCenterX
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: top))
        path.addLine(to: CGPoint(x: center - 12, y: top))
        path.addQuadCurve(to: CGPoint(x: center - 8, y: top - 2), control: CGPoint(x: center - 10, y: top))
        path.addLine(to: CGPoint(x: center - 2, y: rect.minY + 2))
        path.addQuadCurve(to: CGPoint(x: center + 2, y: rect.minY + 2), control: CGPoint(x: center, y: rect.minY))
        path.addLine(to: CGPoint(x: center + 8, y: top - 2))
        path.addQuadCurve(to: CGPoint(x: center + 12, y: top), control: CGPoint(x: center + 10, y: top))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + radius), control: CGPoint(x: rect.maxX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: top), control: CGPoint(x: rect.minX, y: top))
        path.closeSubpath()
        return path
    }
}

private struct StarterPackSamplePanelRows: View {
    let pluginIDs: [String]

    var body: some View {
        VStack(spacing: MenuBarPanelLayout.featureRowSpacing) {
            ForEach(pluginIDs, id: \.self) { id in
                if id == "system-status" {
                    HStack(spacing: ComponentPanelLayout.horizontalSpacing) {
                        metric("CPU", value: "12")
                        metric(FeatureL10n.string("内存"), value: "50")
                    }
                } else if id == "calendar" { calendarWidget }
                else { previewRow(id) }
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Text(title).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            PluginMetricValue(value, unit: "%", isProminent: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PluginSettingsTheme.Spacing.rowVertical)
        .background(PluginComponentCardBackground())
    }

    private func previewRow(_ id: String) -> some View {
        let switches: Set<String> = ["keep-awake", "microphone-mute", "system-mute", "translator", "stage-manager", "auto-hide-dock", "night-shift", "display-true-color"]
        let disclosures: Set<String> = ["display-brightness", "display-resolution", "display-volume", "app-volume"]
        let snapshot = PluginPanelRowSnapshot(
            id: id, title: StarterPack.title(for: id), iconName: StarterPack.symbol(for: id), iconTint: .secondary,
            controlStyle: switches.contains(id) ? .switch : disclosures.contains(id) ? .disclosure : .button, menuActionBehavior: .keepPresented,
            description: "", helpText: "", descriptionTone: .secondary,
            isOn: false, isExpanded: false, isEnabled: true, detail: nil,
            buttonActionID: nil, buttonTitle: FeatureL10n.string(id == "lock-screen" ? "锁定" : "打开")
        )
        return FeatureRowView(
            item: snapshot, indicator: nil, compactIndicator: nil,
            onDisclosureToggle: { _ in }, onSelectionChange: { _, _ in },
            onNavigationSelectionChange: { _, _ in }, onNavigationHoverChange: { _, _, _ in },
            onNavigationRowFrameChange: { _, _, _ in }, onDateChange: { _, _ in },
            onSwitchChange: { _ in false }, onSliderChange: { _, _, _ in }, onActionInvoke: { _, _ in }
        )
    }

    private var calendarWidget: some View {
        let date = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = PluginRuntimeLocalization.locale
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let padding = calendar.component(.weekday, from: start) - 1
        let dayCount = calendar.range(of: .day, in: .month, for: date)?.count ?? 30
        let days = Array(repeating: 0, count: padding) + Array(1...dayCount)
        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Text(date, format: .dateTime.year().month(.wide))
                .font(PluginSettingsTheme.Typography.sectionTitle)
            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    ForEach(Array(calendar.veryShortStandaloneWeekdaySymbols.enumerated()), id: \.offset) { _, title in
                        Text(title).font(PluginSettingsTheme.Typography.statusBadge).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<(days.count + 6) / 7, id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(0..<7) { weekday in
                            let index = week * 7 + weekday
                            let day = index < days.count ? days[index] : 0
                            Text(day == 0 ? "" : day.formatted())
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .frame(maxWidth: .infinity, minHeight: 22)
                        }
                    }
                }
            }
        }
        .padding(PluginSettingsTheme.Spacing.rowVertical)
        .background(PluginComponentCardBackground())
    }
}
