import AppKit
import MacToolsPluginKit
import SwiftUI
import UniformTypeIdentifiers

private enum SystemStatusSettingsAppearance {
    static let separatorOpacity = 0.5
}

struct SystemStatusSettingsView: View {
    enum SectionKind {
        case panel
        case menuBar
    }

    @ObservedObject var controller: SystemStatusSettingsController
    let viewModel: SystemStatusViewModel
    let localization: PluginLocalization
    let section: SectionKind

    @State private var isConfirmingMenuBarReset = false

    @ViewBuilder
    var body: some View {
        switch section {
        case .panel:
            panelSection
        case .menuBar:
            menuBarSection
        }
    }

    private var panelSection: some View {
        SystemStatusMetricEditorView(
            items: panelItems,
            onVisibilityChange: controller.setPanelMetric(_:visible:),
            onMove: controller.movePanelMetric(_:toOffset:),
            panelOptions: SystemStatusPanelOptions(
                limit: controller.configuration.processLimit,
                title: localization.string("settings.process.limit", defaultValue: "最多显示数量"),
                summary: localization.format(
                    "settings.process.limitSummary", defaultValue: "最多 %d 项",
                    controller.configuration.processLimit.rawValue
                ),
                chartMetricTitle: localization.string("settings.chartMetric", defaultValue: "图表指标"),
                selectedCharts: controller.configuration.chartMetrics,
                chartChoices: Dictionary(uniqueKeysWithValues: SystemStatusMetricKind.allCases.map { kind in
                    (kind, SystemStatusChartMetric.available(for: kind).map {
                        SystemStatusChartMetricChoice(metric: $0, title: $0.title(localization: localization))
                    })
                })
            ),
            onProcessLimitChange: controller.setProcessLimit,
            onChartMetricChange: controller.setChartMetric
        )
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                Text(localization.string("settings.menuBar.preview", defaultValue: "实时预览"))
                    .font(PluginSettingsTheme.Typography.rowTitle)

                Text(localization.string(
                    "settings.menuBar.builderDescription",
                    defaultValue: "拖拽调整顺序，展开设置样式和数值。"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                PluginObservedContent(viewModel) { _ in
                    menuBarPreview
                }

                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Text(localization.string("settings.menuBar.setAllMetricsTo", defaultValue: "所有指标设为"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                    menuBarStyleControls
                    menuBarResetMenu
                }
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)

            PluginSettingsListDivider()
                .opacity(SystemStatusSettingsAppearance.separatorOpacity)

            SystemStatusMetricEditorView(
                items: menuBarItems,
                onVisibilityChange: controller.setMenuBarMetric(_:visible:),
                onMove: controller.moveMenuBarMetric(_:toOffset:),
                onPrimaryValueChange: controller.setMenuBarPrimaryValue(_:value:),
                onSecondaryValueChange: controller.setMenuBarSecondaryValue(_:value:),
                onStyleChange: controller.setMenuBarStyle(_:style:),
                onValueArrangementChange: controller.setMenuBarValueArrangement(_:arrangement:)
            )
        }
        .alert(
            localization.string("settings.menuBar.resetAll.confirmationTitle", defaultValue: "重置所有菜单栏设置？"),
            isPresented: $isConfirmingMenuBarReset
        ) {
            Button(localization.string("settings.menuBar.resetAll.cancel", defaultValue: "取消"), role: .cancel) {}
            Button(
                localization.string("settings.menuBar.resetAll.confirm", defaultValue: "重置"),
                role: .destructive
            ) {
                controller.resetMenuBarConfiguration()
            }
        } message: {
            Text(localization.string(
                "settings.menuBar.resetAll.confirmationMessage",
                defaultValue: "这会还原菜单栏指标的样式、数值、显示状态和顺序。"
            ))
        }
    }

    private var menuBarResetMenu: some View {
        Menu {
            Button(localization.string("settings.menuBar.resetStylesAndLayout", defaultValue: "重置样式与布局")) {
                controller.resetMenuBarAppearances()
            }
            Button(role: .destructive) {
                isConfirmingMenuBarReset = true
            } label: {
                Text(localization.string("settings.menuBar.resetAll", defaultValue: "重置所有菜单栏设置…"))
            }
        } label: {
            Label(localization.string("settings.menuBar.reset", defaultValue: "重置"), systemImage: "arrow.counterclockwise")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    private var menuBarStyleControls: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            if commonMenuBarStyle == nil {
                Text(localization.string("settings.menuBarStyle.mixed", defaultValue: "混合"))
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
            }
            applyStyleButton(.horizontal, title: localization.string("settings.menuBarLayout.detailed", defaultValue: "详细"))
            applyStyleButton(.vertical, title: localization.string("settings.menuBarLayout.compact", defaultValue: "紧凑"))
            applyStyleButton(.minimal, title: localization.string("settings.menuBarLayout.minimal", defaultValue: "极简"))
        }
        .fixedSize()
    }

    private var commonMenuBarStyle: SystemStatusMenuBarLayout? {
        guard let firstStyle = controller.configuration.menuBarItems.first?.style else {
            return nil
        }
        return controller.configuration.menuBarItems.dropFirst().allSatisfy { $0.style == firstStyle }
            ? firstStyle
            : nil
    }

    @ViewBuilder
    private func applyStyleButton(
        _ style: SystemStatusMenuBarLayout,
        title: String
    ) -> some View {
        if commonMenuBarStyle == style {
            Button(title) {
                controller.applyMenuBarStyleToAll(style)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityAddTraits(.isSelected)
        } else {
            Button(title) {
                controller.applyMenuBarStyleToAll(style)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var menuBarPreview: some View {
        let items = controller.configuration.menuBarItems.filter(\.isVisible)
        Group {
            if items.isEmpty {
                Text(localization.string("settings.menuBar.previewEmpty", defaultValue: "选择指标后将在这里预览。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, PluginSettingsTheme.Spacing.rowContentControl)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    SystemStatusMenuBarPreviewView(
                        blocks: SystemStatusMenuBarMetricsFormatter.blocks(
                            snapshot: viewModel.snapshot,
                            items: items,
                            localization: localization
                        ),
                        layout: controller.configuration.menuBarLayout
                    )
                    .fixedSize()
                    .padding(.horizontal, PluginSettingsTheme.Spacing.rowContentControl)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 52)
        .background(
            PluginSettingsTheme.Surface.raisedControl,
            in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control)
                .strokeBorder(PluginSettingsTheme.Palette.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var panelItems: [SystemStatusMetricEditorItem] {
        controller.configuration.panelItems.map {
            tableItem(
                preference: $0,
                description: panelDescription(for: $0.kind)
            )
        }
    }

    private var menuBarItems: [SystemStatusMetricEditorItem] {
        controller.configuration.menuBarItems.map {
            let kind = $0.kind
            let valueOptions = SystemStatusMenuBarValueKind.availableValues(for: kind).map {
                SystemStatusMenuBarValueOption(
                    kind: $0,
                    title: $0.title(localization: localization)
                )
            }
            return tableItem(
                kind: kind,
                isVisible: $0.isVisible,
                description: panelDescription(for: kind),
                valueOptions: valueOptions,
                selectedValues: $0.values,
                style: $0.style,
                valueArrangement: $0.valueArrangement
            )
        }
    }

    private func tableItem(
        preference: SystemStatusMetricPreference,
        description: String
    ) -> SystemStatusMetricEditorItem {
        tableItem(
            kind: preference.kind,
            isVisible: preference.isVisible,
            description: description,
            valueOptions: [],
            selectedValues: []
        )
    }

    private func tableItem(
        kind: SystemStatusMetricKind,
        isVisible: Bool,
        description: String,
        valueOptions: [SystemStatusMenuBarValueOption],
        selectedValues: [SystemStatusMenuBarValueKind],
        style: SystemStatusMenuBarLayout = .horizontal,
        valueArrangement: SystemStatusMenuBarValueArrangement = .automatic
    ) -> SystemStatusMetricEditorItem {
        let title = kind.title(localization: localization)
        return SystemStatusMetricEditorItem(
            kind: kind,
            title: title,
            description: description,
            iconName: kind.symbolName,
            isVisible: isVisible,
            visibilityActionTitle: isVisible
                ? localization.format("settings.metric.visibility.hide", defaultValue: "隐藏%@", title)
                : localization.format("settings.metric.visibility.show", defaultValue: "显示%@", title),
            reorderAccessibilityTitle: localization.string("settings.metric.reorderAccessibility", defaultValue: "拖拽调整顺序"),
            visibilityStateTitle: isVisible
                ? localization.string("settings.metric.visibility.visible", defaultValue: "已显示")
                : localization.string("settings.metric.visibility.hidden", defaultValue: "已隐藏"),
            valueOptions: valueOptions,
            selectedValues: selectedValues,
            style: style,
            styleTitle: localization.string("settings.menuBarStyle.title", defaultValue: "样式"),
            detailedStyleTitle: localization.string(
                "settings.menuBarLayout.detailed",
                defaultValue: "详细"
            ),
            compactStyleTitle: localization.string(
                "settings.menuBarLayout.compact",
                defaultValue: "紧凑"
            ),
            minimalStyleTitle: localization.string(
                "settings.menuBarLayout.minimal",
                defaultValue: "极简"
            ),
            valueArrangement: valueArrangement,
            valueArrangementTitle: localization.string(
                "settings.menuBarValueArrangement.title",
                defaultValue: "数值布局"
            ),
            automaticArrangementTitle: localization.string(
                "settings.menuBarValueArrangement.automatic",
                defaultValue: "自动"
            ),
            stackedArrangementTitle: localization.string(
                "settings.menuBarValueArrangement.stacked",
                defaultValue: "上下排列"
            ),
            inlineArrangementTitle: localization.string(
                "settings.menuBarValueArrangement.inline",
                defaultValue: "并排显示"
            ),
            secondaryValueNoneTitle: localization.string(
                "settings.menuBarValue.none",
                defaultValue: "不展示"
            ),
            primaryValueTitle: localization.string(
                "settings.menuBarValue.first",
                defaultValue: "第一个数值"
            ),
            secondaryValueTitle: localization.string(
                "settings.menuBarValue.secondOptional",
                defaultValue: "第二个数值（可选）"
            ),
            expandedStateTitle: localization.string("settings.metric.expanded", defaultValue: "已展开"),
            collapsedStateTitle: localization.string("settings.metric.collapsed", defaultValue: "已折叠")
        )
    }

    private func panelDescription(for kind: SystemStatusMetricKind) -> String {
        switch kind {
        case .cpu:
            return localization.string("settings.metric.cpu.panelDescription", defaultValue: "使用率、温度和功率")
        case .gpu:
            return localization.string("settings.metric.gpu.panelDescription", defaultValue: "使用率、温度和型号")
        case .network:
            return localization.string("settings.metric.network.panelDescription", defaultValue: "上传、下载和地址")
        case .disk:
            return localization.string("settings.metric.disk.panelDescription", defaultValue: "容量和读写速率")
        case .memory:
            return localization.string("settings.metric.memory.panelDescription", defaultValue: "内存和交换空间")
        case .battery:
            return localization.string("settings.metric.battery.panelDescription", defaultValue: "电量、健康度和温度")
        case .topProcesses:
            return localization.string("settings.metric.topProcesses.panelDescription", defaultValue: "按应用汇总 CPU 和内存")
        }
    }


}

private struct SystemStatusMenuBarPreviewView: NSViewRepresentable {
    let blocks: [SystemStatusMenuBarMetricBlock]
    let layout: SystemStatusMenuBarLayout

    func makeNSView(context: Context) -> SystemStatusMenuBarMetricsView {
        let view = SystemStatusMenuBarMetricsView()
        view.menuBarLayout = layout
        view.blocks = blocks
        return view
    }

    func updateNSView(_ view: SystemStatusMenuBarMetricsView, context: Context) {
        view.menuBarLayout = layout
        view.blocks = blocks
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SystemStatusMenuBarMetricsView,
        context: Context
    ) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

struct SystemStatusMenuBarValueOption: Equatable, Identifiable {
    let kind: SystemStatusMenuBarValueKind
    let title: String

    var id: String { kind.rawValue }
}

struct SystemStatusMetricEditorItem: Equatable, Identifiable {
    let kind: SystemStatusMetricKind
    let title: String
    let description: String
    let iconName: String
    let isVisible: Bool
    let visibilityActionTitle: String
    let reorderAccessibilityTitle: String
    let visibilityStateTitle: String
    let valueOptions: [SystemStatusMenuBarValueOption]
    let selectedValues: [SystemStatusMenuBarValueKind]
    let style: SystemStatusMenuBarLayout
    let styleTitle: String
    let detailedStyleTitle: String
    let compactStyleTitle: String
    let minimalStyleTitle: String
    let valueArrangement: SystemStatusMenuBarValueArrangement
    let valueArrangementTitle: String
    let automaticArrangementTitle: String
    let stackedArrangementTitle: String
    let inlineArrangementTitle: String
    let secondaryValueNoneTitle: String
    let primaryValueTitle: String
    let secondaryValueTitle: String
    var expandedStateTitle = "Expanded"
    var collapsedStateTitle = "Collapsed"

    var id: String { kind.rawValue }

    var tint: Color {
        switch kind {
        case .cpu: Color(nsColor: .systemGreen)
        case .gpu: Color(nsColor: .systemPurple)
        case .network: Color(nsColor: .systemCyan)
        case .disk: Color(nsColor: .systemBlue)
        case .memory: Color(nsColor: .systemOrange)
        case .battery: Color(nsColor: .systemMint)
        case .topProcesses: Color(nsColor: .systemGray)
        }
    }

    var appearanceSummary: String {
        "\(selectedStyleTitle) · \(selectedArrangementTitle)"
    }

    private var selectedStyleTitle: String {
        switch style {
        case .horizontal:
            return detailedStyleTitle
        case .vertical:
            return compactStyleTitle
        case .minimal:
            return minimalStyleTitle
        }
    }

    private var selectedArrangementTitle: String {
        switch valueArrangement {
        case .automatic:
            return automaticArrangementTitle
        case .stacked:
            return stackedArrangementTitle
        case .inline:
            return inlineArrangementTitle
        }
    }

    var valuesSummary: String {
        selectedValues.compactMap { value in
            valueOptions.first(where: { $0.kind == value })?.title
        }.joined(separator: " · ")
    }
}

struct SystemStatusChartMetricChoice: Equatable {
    let metric: SystemStatusChartMetric
    let title: String
}

struct SystemStatusPanelOptions: Equatable {
    let limit: SystemStatusProcessLimit
    let title: String
    let summary: String
    let chartMetricTitle: String
    let selectedCharts: [String: SystemStatusChartMetric]
    let chartChoices: [SystemStatusMetricKind: [SystemStatusChartMetricChoice]]

    func selectedMetric(for kind: SystemStatusMetricKind) -> SystemStatusChartMetric {
        guard let metric = selectedCharts[kind.rawValue], SystemStatusChartMetric.available(for: kind).contains(metric) else {
            return .defaultMetric(for: kind)
        }
        return metric
    }

    func summary(for kind: SystemStatusMetricKind) -> String {
        chartChoices[kind]?.first { $0.metric == selectedMetric(for: kind) }?.title ?? "—"
    }
}

enum SystemStatusMetricDrop {
    static func payload(for kind: SystemStatusMetricKind, listID: String) -> String {
        "system-status-metric:\(listID):\(kind.rawValue)"
    }

    static func destination(
        for payload: String,
        over target: SystemStatusMetricKind,
        afterTarget: Bool,
        in items: [SystemStatusMetricKind],
        listID: String
    ) -> (kind: SystemStatusMetricKind, offset: Int)? {
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "system-status-metric", parts[1] == Substring(listID),
              let source = SystemStatusMetricKind(rawValue: String(parts[2])),
              let sourceIndex = items.firstIndex(of: source),
              let targetIndex = items.firstIndex(of: target) else { return nil }
        let offset = targetIndex + (afterTarget ? 1 : 0)
        guard offset != sourceIndex, offset != sourceIndex + 1 else { return nil }
        return (source, offset)
    }
}

private struct SystemStatusMetricEditorView: View {
    let items: [SystemStatusMetricEditorItem]
    let onVisibilityChange: (SystemStatusMetricKind, Bool) -> Void
    let onMove: (SystemStatusMetricKind, Int) -> Void
    var onPrimaryValueChange: (SystemStatusMetricKind, SystemStatusMenuBarValueKind) -> Void = { _, _ in }
    var onSecondaryValueChange: (SystemStatusMetricKind, SystemStatusMenuBarValueKind?) -> Void = { _, _ in }
    var onStyleChange: (SystemStatusMetricKind, SystemStatusMenuBarLayout) -> Void = { _, _ in }
    var onValueArrangementChange: (SystemStatusMetricKind, SystemStatusMenuBarValueArrangement) -> Void = { _, _ in }
    var panelOptions: SystemStatusPanelOptions? = nil
    var onProcessLimitChange: (SystemStatusProcessLimit) -> Void = { _ in }
    var onChartMetricChange: (SystemStatusMetricKind, SystemStatusChartMetric) -> Void = { _, _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedKind: SystemStatusMetricKind?

    private var listID: String { panelOptions == nil ? "menu-bar" : "panel" }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                SystemStatusMetricEditorRow(
                    item: item,
                    isExpanded: item.kind == expandedKind,
                    dragPayload: SystemStatusMetricDrop.payload(for: item.kind, listID: listID),
                    onToggleExpansion: {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            expandedKind = expandedKind == item.kind ? nil : item.kind
                        }
                    },
                    onVisibilityChange: { onVisibilityChange(item.kind, $0) },
                    onPrimaryValueChange: { onPrimaryValueChange(item.kind, $0) },
                    onSecondaryValueChange: { onSecondaryValueChange(item.kind, $0) },
                    onStyleChange: { onStyleChange(item.kind, $0) },
                    onValueArrangementChange: { onValueArrangementChange(item.kind, $0) },
                    showsSeparator: item.id != items.last?.id,
                    panelOptions: panelOptions,
                    onProcessLimitChange: onProcessLimitChange,
                    onChartMetricChange: { onChartMetricChange(item.kind, $0) }
                )
                .modifier(SystemStatusMetricInsertionTarget(
                    destination: { payload, after in
                        SystemStatusMetricDrop.destination(
                            for: payload, over: item.kind, afterTarget: after,
                            in: items.map(\.kind), listID: listID
                        )
                    },
                    onMove: { kind, offset in
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            onMove(kind, offset)
                        }
                    }
                ))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SystemStatusMetricInsertionTarget: ViewModifier {
    let destination: (String, Bool) -> (kind: SystemStatusMetricKind, offset: Int)?
    let onMove: (SystemStatusMetricKind, Int) -> Void

    @State private var rowHeight: CGFloat = 0
    @State private var hoverToken: UUID?
    @State private var payload: String?
    @State private var afterTarget = false

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { rowHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in rowHeight = height }
                }
            }
            .overlay(alignment: afterTarget ? .bottom : .top) {
                if let payload, destination(payload, afterTarget) != nil {
                    HStack(spacing: 0) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        Capsule().fill(Color.accentColor).frame(height: 2)
                    }
                    .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                    .offset(y: afterTarget ? 3 : -3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onDrop(of: [.text], delegate: SystemStatusMetricInsertionDelegate(
                rowHeight: rowHeight, hoverToken: $hoverToken, payload: $payload,
                afterTarget: $afterTarget, destination: destination, onMove: onMove
            ))
    }
}

private struct SystemStatusMetricInsertionDelegate: DropDelegate {
    let rowHeight: CGFloat
    @Binding var hoverToken: UUID?
    @Binding var payload: String?
    @Binding var afterTarget: Bool
    let destination: (String, Bool) -> (kind: SystemStatusMetricKind, offset: Int)?
    let onMove: (SystemStatusMetricKind, Int) -> Void

    func dropEntered(info: DropInfo) {
        let token = UUID()
        hoverToken = token
        payload = nil
        afterTarget = info.location.y >= rowHeight / 2
        loadPayload(info) { value in
            // Ignore provider callbacks from a row or drag session already left.
            guard hoverToken == token else { return }
            payload = value
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let after = info.location.y >= rowHeight / 2
        if afterTarget != after { afterTarget = after }
        // Keep quick drops available while the native provider resolves its string.
        guard let payload else { return DropProposal(operation: .move) }
        return DropProposal(operation: destination(payload, after) == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        hoverToken = nil
        payload = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let after = info.location.y >= rowHeight / 2
        let resolvedPayload = payload
        hoverToken = nil
        payload = nil
        if let resolvedPayload {
            guard let move = destination(resolvedPayload, after) else { return false }
            onMove(move.kind, move.offset)
            return true
        }
        // Load independently so a quick drop need not wait for the hover preview.
        return loadPayload(info) { value in
            guard let value, let move = destination(value, after) else { return }
            onMove(move.kind, move.offset)
        }
    }

    @discardableResult
    private func loadPayload(_ info: DropInfo, completion: @escaping @MainActor (String?) -> Void) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first,
              provider.canLoadObject(ofClass: NSString.self) else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            let value = object as? String
            Task { @MainActor in completion(value) }
        }
        return true
    }
}

struct SystemStatusMetricEditorRow: View {
    let item: SystemStatusMetricEditorItem
    let isExpanded: Bool
    let dragPayload: String
    let onToggleExpansion: () -> Void
    let onVisibilityChange: (Bool) -> Void
    let onPrimaryValueChange: (SystemStatusMenuBarValueKind) -> Void
    let onSecondaryValueChange: (SystemStatusMenuBarValueKind?) -> Void
    let onStyleChange: (SystemStatusMenuBarLayout) -> Void
    let onValueArrangementChange: (SystemStatusMenuBarValueArrangement) -> Void
    var showsSeparator = false
    var panelOptions: SystemStatusPanelOptions? = nil
    var onProcessLimitChange: (SystemStatusProcessLimit) -> Void = { _ in }
    var onChartMetricChange: (SystemStatusChartMetric) -> Void = { _ in }

    private var canExpand: Bool {
        panelOptions == nil || item.kind == .topProcesses || SystemStatusChartMetric.available(for: item.kind).count > 1
    }

    private var summary: String {
        if let panelOptions {
            return item.kind == .topProcesses ? panelOptions.summary : panelOptions.summary(for: item.kind)
        }
        return [item.valuesSummary, item.appearanceSummary].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if canExpand && isExpanded {
                options
                    .padding(.horizontal, PluginSettingsTheme.Spacing.controlCluster)
                    .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
                    .background(
                        PluginSettingsTheme.Palette.recessedControlBackground,
                        in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control, style: .continuous)
                    )
                    .padding(.horizontal, PluginSettingsTheme.Spacing.controlCluster)
                    .padding(.top, PluginSettingsTheme.Spacing.controlCluster / 2)
                    .padding(.bottom, PluginSettingsTheme.Spacing.controlCluster)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if showsSeparator {
                PluginSettingsListDivider()
                    .opacity(SystemStatusSettingsAppearance.separatorOpacity)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        Group {
            if canExpand {
                Button(action: onToggleExpansion) { headerLabel }
                    .buttonStyle(.plain)
                    .accessibilityValue(isExpanded ? item.expandedStateTitle : item.collapsedStateTitle)
            } else {
                headerLabel
            }
        }
        .overlay(alignment: .trailing) {
            Button { onVisibilityChange(!item.isVisible) } label: {
                Image(systemName: item.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(item.isVisible ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(item.visibilityActionTitle)
            .accessibilityLabel(item.visibilityActionTitle)
            .accessibilityValue(item.visibilityStateTitle)
            .padding(.trailing, PluginSettingsTheme.Spacing.rowHorizontal + 26)
        }
        .contentShape(Rectangle())
        .draggable(dragPayload) {
            Label(item.title, systemImage: item.iconName)
                .font(PluginSettingsTheme.Typography.rowTitle)
                .foregroundStyle(item.tint)
                .padding(PluginSettingsTheme.Spacing.rowContentControl)
                .pluginSettingsCardBackground(.standard)
        }
    }

    private var headerLabel: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: item.iconName)
                .font(PluginSettingsTheme.Typography.rowTitle)
                .foregroundStyle(item.tint)
                .frame(width: 32, height: 32)
                .background(item.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(item.title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .foregroundStyle(.primary)
                Text(summary)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if canExpand {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                    .font(PluginSettingsTheme.Typography.rowIcon)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            // Reserve the independent visibility button's hit area.
            Color.clear.frame(width: 24, height: 28)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 28)
                .help(item.reorderAccessibilityTitle)
                .accessibilityHidden(true)
        }
        .pluginSettingsListRowPadding(interactive: true)
        .contentShape(Rectangle())
    }

    private var options: some View {
        VStack(spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            if let panelOptions {
                if item.kind == .memory {
                    optionRow(panelOptions.chartMetricTitle) {
                        Picker(panelOptions.chartMetricTitle, selection: Binding(
                            get: { panelOptions.selectedMetric(for: item.kind) }, set: { onChartMetricChange($0) }
                        )) {
                            ForEach(panelOptions.chartChoices[item.kind] ?? [], id: \.metric) { choice in
                                Text(choice.title).tag(choice.metric)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                } else if item.kind == .topProcesses {
                    optionRow(panelOptions.title) {
                        Picker(panelOptions.title, selection: Binding(
                            get: { panelOptions.limit }, set: { onProcessLimitChange($0) }
                        )) {
                            ForEach(SystemStatusProcessLimit.allCases, id: \.self) { limit in
                                Text(String(limit.rawValue)).tag(limit)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }
            } else {
                menuBarOptions
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var menuBarOptions: some View {
        optionRow(item.styleTitle) {
            Picker(item.styleTitle, selection: Binding(get: { item.style }, set: { onStyleChange($0) })) {
                Text(item.detailedStyleTitle).tag(SystemStatusMenuBarLayout.horizontal)
                Text(item.compactStyleTitle).tag(SystemStatusMenuBarLayout.vertical)
                Text(item.minimalStyleTitle).tag(SystemStatusMenuBarLayout.minimal)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        optionRow(item.valueArrangementTitle) {
            Picker(item.valueArrangementTitle, selection: Binding(
                get: { item.valueArrangement }, set: { onValueArrangementChange($0) }
            )) {
                Text(item.automaticArrangementTitle).tag(SystemStatusMenuBarValueArrangement.automatic)
                Text(item.stackedArrangementTitle).tag(SystemStatusMenuBarValueArrangement.stacked)
                Text(item.inlineArrangementTitle).tag(SystemStatusMenuBarValueArrangement.inline)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        optionRow(item.primaryValueTitle) {
            Picker(item.primaryValueTitle, selection: Binding(
                get: { item.selectedValues.first },
                set: { if let value = $0 { onPrimaryValueChange(value) } }
            )) {
                ForEach(item.valueOptions) { option in
                    Text(option.title).tag(Optional(option.kind))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 160, alignment: .trailing)
        }
        optionRow(item.secondaryValueTitle) {
            Picker(item.secondaryValueTitle, selection: Binding(
                get: { item.selectedValues.dropFirst().first },
                set: { onSecondaryValueChange($0) }
            )) {
                Text(item.secondaryValueNoneTitle).tag(nil as SystemStatusMenuBarValueKind?)
                ForEach(item.valueOptions) { option in
                    Text(option.title).tag(Optional(option.kind))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 160, alignment: .trailing)
        }
    }

    private func optionRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 0)
                control()
                    .frame(minWidth: 250, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    control().fixedSize()
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(minHeight: PluginSettingsTheme.Size.controlHeight)
    }
}
