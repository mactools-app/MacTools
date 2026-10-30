import AppKit
import SwiftUI
import MacToolsPluginKit

/// Interactive native tabs browse static panel content without loading plugins.
struct StarterPackPanelPreview: View {
    static let preferredWidth = MenuBarPanelLayout.baseWidth + 2 * PluginSettingsTheme.Spacing.rowContentControl

    @ObservedObject var controller: StarterPackController
    var panels: [MenuBarPanelDefinition] = MenuBarPanelDefinition.defaults
    @ObservedObject private var themes = MenuBarPanelThemeStore.shared
    @ObservedObject private var localization = PluginRuntimeLocalization.source
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.displayScale) private var displayScale
    @StateObject private var menuPresenter = MenuBarPanelMenuPresenter()
    @State private var selectedPanelID: String?
    @State private var contentImage: NSImage?

    private var itemsByPanelID: [String: [PluginPanelItemKey]] {
        controller.panelItemsByPanelID()
    }

    private var previewPanelID: String {
        if let selectedPanelID, panels.contains(where: { $0.id == selectedPanelID }) {
            return selectedPanelID
        }
        if let targetPanelID = controller.draft.panelID, panels.contains(where: { $0.id == targetPanelID }) {
            return targetPanelID
        }
        return panels.first(where: { !itemsByPanelID[$0.id, default: []].isEmpty })?.id
            ?? panels.first?.id ?? MenuBarPanelDefinition.componentsID
    }

    private var panelIDs: [String] {
        itemsByPanelID[previewPanelID, default: []].map(\.pluginID)
    }

    private var definition: MenuBarPanelThemeDefinition? {
        themes.selectedDefinition(for: MenuBarPanelThemeResolver.appearance(for: colorScheme))
    }

    private var theme: MenuBarPanelThemeStyle {
        MenuBarPanelThemeResolver.resolve(definition: definition, colorScheme: colorScheme, contrast: contrast)
    }

    static var heading: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Label(FeatureL10n.string("设置预览"), systemImage: "eye")
                .font(PluginSettingsTheme.Typography.sectionTitle)
            Text(FeatureL10n.string("示例面板，数值仅供参考。"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowContentControl)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            panel
                // The arrow sits in the header gap so the body aligns with adjacent cards.
                .padding(.top, -StarterPackPreviewPopoverShape.arrowHeight)
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowContentControl)
                .padding(.bottom, PluginSettingsTheme.Spacing.rowContentControl)
            let placedIDs = Set(itemsByPanelID.values.flatMap { $0 }.map(\.pluginID))
            let otherIDs = controller.selectedIDs.filter { !placedIDs.contains($0) }
            if !otherIDs.isEmpty {
                let titles = otherIDs.map(StarterPack.title(for:)).joined(separator: " · ")
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(FeatureL10n.string("也包含"))
                        .font(PluginSettingsTheme.Typography.secondaryLabel)
                    Text(titles)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .lineLimit(3).help(titles)
                }
                .foregroundStyle(.secondary)
            }
            if controller.draft.seedGrid && controller.canSeedGrid {
                Label(FeatureL10n.string("左半屏") + " · " + FeatureL10n.string("右半屏") + " · " + FeatureL10n.string("最大化"), systemImage: "square.grid.3x3")
                    .font(PluginSettingsTheme.Typography.rowDescription)
            }
        }
        .onAppear {
            selectedPanelID = previewPanelID
            renderSnapshot()
        }
        .onChange(of: panelIDs) { _, _ in renderSnapshot() }
        .onChange(of: controller.draft.panelID) { _, value in
            selectedPanelID = value
            renderSnapshot()
        }
        .onChange(of: panels) { _, _ in renderSnapshot() }
        .onChange(of: definition) { _, _ in renderSnapshot() }
        .onChange(of: colorScheme) { _, _ in renderSnapshot() }
        .onChange(of: contrast) { _, _ in renderSnapshot() }
        .onChange(of: layoutDirection) { _, _ in renderSnapshot() }
        .onChange(of: localization.revision) { _, _ in renderSnapshot() }
        .onChange(of: displayScale) { _, _ in renderSnapshot() }
    }

    private var panel: some View {
        let shape = StarterPackPreviewPopoverShape(arrowCenterX: MenuBarPanelLayout.baseWidth / 2)
        return VStack(spacing: 0) {
            MenuBarPanelTabs(panels: panels, selectedPanelID: previewPanelID,
                             onSelect: { selectedPanelID = $0 })
                .frame(maxWidth: .infinity)
                .frame(height: MenuBarPanelLayout.headerHeight)
                .padding(.horizontal, MenuBarPanelLayout.outerPadding)
                .padding(.top, MenuBarPanelLayout.panelTopPadding)
                .environmentObject(menuPresenter)
                .environment(\.menuBarPanelTheme, theme)
            if panelIDs.isEmpty {
                Text(FeatureL10n.string(controller.draft.addToPanel ? "此面板暂无内容" : "面板保持不变。"))
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
                .id(previewPanelID)
                .frame(minHeight: 100, idealHeight: contentHeight, maxHeight: contentHeight)
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

    private var contentHeight: CGFloat {
        max(100, contentImage?.size.height ?? 200)
    }

    @MainActor
    private func renderSnapshot() {
        contentImage = snapshot(AnyView(StarterPackSamplePanelRows(pluginIDs: panelIDs)
            .padding(.horizontal, MenuBarPanelLayout.outerPadding)
            .padding(.top, MenuBarPanelLayout.contentTopPadding)
            .padding(.bottom, MenuBarPanelLayout.panelBottomPadding)))
    }

    /// Sample controls remain inert while the native tabs above stay interactive.
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
        // Render at the presenting display's scale so text and symbols remain sharp
        // even when the offscreen window has no backing screen yet.
        let scale = max(1, displayScale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
            pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = size
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
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        VStack(spacing: MenuBarPanelLayout.featureRowSpacing) {
            ForEach(Array(pluginIDs.enumerated()), id: \.offset) { _, id in
                if id == "system-status" {
                    systemStatusWidget
                } else if id == "calendar" { calendarWidget }
                else { previewRow(id) }
            }
        }
    }

    // Match System Status's default six-metric grid and process section. Values
    // are intentionally illustrative; onboarding never starts hardware sampling.
    private var systemStatusWidget: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                metric("CPU", symbol: "cpu", value: 12, unit: "%", footnote: "45 °C", color: theme.dataSeries.tertiary)
                metric("GPU", symbol: "square.3.layers.3d", value: 8, unit: "%", footnote: "42 °C", color: theme.dataSeries.secondary)
            }
            HStack(spacing: 4) {
                metric(FeatureL10n.string("网络"), symbol: "network", value: 24, unit: "KB/s", footnote: "↓ 18 KB/s  ↑ 6 KB/s", color: theme.dataSeries.primary)
                metric(FeatureL10n.string("磁盘"), symbol: "internaldrive", value: 256, unit: "GB", footnote: "↓ 2 MB/s  ↑ 1 MB/s", color: theme.dataSeries.quaternary)
            }
            HStack(spacing: 4) {
                metric(FeatureL10n.string("内存"), symbol: "memorychip", value: 50, unit: "%", footnote: "8 GB / 16 GB", color: theme.dataSeries.senary)
                metric(FeatureL10n.string("电池"), symbol: "battery.100percent", value: 85, unit: "%", footnote: "6 h 30 min", color: theme.dataSeries.quinary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(FeatureL10n.string("starterPack.preview.processes"))
                    Spacer()
                    Text("CPU").foregroundStyle(theme.text.secondary)
                }
                .font(PluginTypography.caption.font)
                ForEach(Array([("Finder", 3), ("Safari", 2), ("MacTools", 1)].enumerated()), id: \.offset) { _, process in
                    HStack {
                        Text(process.0)
                        Spacer()
                        Text(Double(process.1) / 100, format: .percent.locale(PluginRuntimeLocalization.locale))
                            .monospacedDigit().foregroundStyle(theme.text.secondary)
                    }
                    .font(PluginTypography.detail.font)
                }
            }
            .padding(6)
            .frame(height: 96, alignment: .top)
            .background(PluginComponentCardBackground(cornerRadius: 10))
        }
    }

    private func metric(_ title: String, symbol: String, value: Int, unit: String, footnote: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(PluginTypography.caption.font).foregroundStyle(color)
                .frame(height: 18)
            PluginMetricValue(value.formatted(.number.locale(PluginRuntimeLocalization.locale)), unit: unit)
                .frame(height: 22)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array([4, 6, 5, 9, 7, 6, 8, 12, 9, 7, 11, 8, 6, 9, 7, 5].enumerated()), id: \.offset) { _, height in
                    RoundedRectangle(cornerRadius: 1).fill(color.opacity(0.65))
                        .frame(height: CGFloat(height))
                }
            }
            .frame(height: 18, alignment: .bottom)
            Text(footnote).font(PluginTypography.caption.font.monospacedDigit())
                .foregroundStyle(theme.text.secondary).lineLimit(1)
                .frame(height: 14)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92, alignment: .topLeading)
        .background(PluginComponentCardBackground(cornerRadius: 10))
    }

    private func previewRow(_ id: String) -> some View {
        let switches: Set<String> = ["keep-awake", "microphone-mute", "system-mute", "translator", "stage-manager", "auto-hide-dock", "night-shift", "display-true-color", "auto-input", "app-hotkey"]
        let disclosures: Set<String> = ["display-brightness", "display-resolution", "display-volume", "app-volume", "sidecar", "saved-scripts", "xcode-clean", "disk-clean"]
        let buttonTitle: String = switch id {
        case "lock-screen": FeatureL10n.string("starterPack.preview.lock")
        case "empty-trash": FeatureL10n.string("starterPack.preview.empty")
        case "eject-disk": FeatureL10n.string("starterPack.preview.eject")
        case "homebrew": FeatureL10n.string("starterPack.preview.manage")
        case "zsh-config": FeatureL10n.string("starterPack.preview.edit")
        case "ip-overview": FeatureL10n.string("starterPack.preview.check")
        case "screenshot": FeatureL10n.string("starterPack.preview.capture")
        default: FeatureL10n.string("打开")
        }
        let subtitle: String = switch id {
        case "keep-awake": FeatureL10n.string("starterPack.preview.keepAwake.subtitle")
        case "microphone-mute", "system-mute": FeatureL10n.string("starterPack.preview.unmuted")
        case "lock-screen": FeatureL10n.string("starterPack.preview.lock.subtitle")
        case "app-hotkey": FeatureL10n.string("starterPack.preview.hotkey.subtitle")
        case "auto-input": FeatureL10n.string("starterPack.preview.autoInput.subtitle")
        case "auto-hide-dock", "stage-manager", "night-shift", "display-true-color": FeatureL10n.string("已关闭")
        default: ""
        }
        let snapshot = PluginPanelRowSnapshot(
            id: id, title: StarterPack.title(for: id), iconName: StarterPack.symbol(for: id), iconTint: .secondary,
            controlStyle: switches.contains(id) ? .switch : disclosures.contains(id) ? .disclosure : .button, menuActionBehavior: .keepPresented,
            description: subtitle, helpText: "", descriptionTone: .secondary,
            isOn: ["auto-input", "app-hotkey"].contains(id), isExpanded: false, isEnabled: true, detail: nil,
            buttonActionID: nil, buttonTitle: buttonTitle
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
        calendar.firstWeekday = Calendar.current.firstWeekday
        let padding = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: date)?.count ?? 30
        let days = Array(repeating: 0, count: padding) + Array(1...dayCount)
        let today = calendar.component(.day, from: date)
        let weekdays = calendar.veryShortStandaloneWeekdaySymbols
        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.controlCluster) {
            HStack {
                Text(date, format: .dateTime.year().month(.wide))
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                Spacer()
                Image(systemName: "chevron.left")
                Image(systemName: "chevron.right")
            }
            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    ForEach(0..<7) { column in
                        Text(weekdays[(column + calendar.firstWeekday - 1) % 7])
                            .font(PluginSettingsTheme.Typography.statusBadge).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<(days.count + 6) / 7, id: \.self) { week in
                    calendarWeek(week, days: days, today: today)
                }
            }
        }
        .padding(PluginSettingsTheme.Spacing.rowVertical)
        .background(PluginComponentCardBackground())
    }

    private func calendarWeek(_ week: Int, days: [Int], today: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<7) { weekday in
                let index = week * 7 + weekday
                calendarDay(index < days.count ? days[index] : 0, today: today)
            }
        }
    }

    private func calendarDay(_ day: Int, today: Int) -> some View {
        Text(day == 0 ? "" : day.formatted(.number.locale(PluginRuntimeLocalization.locale)))
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(day == today ? theme.status.informational : theme.text.primary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(day == today ? theme.status.informational.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
