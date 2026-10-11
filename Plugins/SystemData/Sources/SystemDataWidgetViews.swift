import MacToolsPluginKit
import SwiftUI

// MARK: - Shared badge

enum SystemDataBadgeColor {
    static func systemColor(for badge: SystemDataBadge) -> Color {
        switch badge {
        case .safe: .green
        case .review: .orange
        case .manual: .secondary
        }
    }
}

struct SystemDataBadgeLabel: View {
    let badge: SystemDataBadge
    let localization: PluginLocalization

    var body: some View {
        Text(text)
            .font(PluginTypography.caption.font.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .accessibilityLabel(text)
    }

    private var text: String {
        switch badge {
        case .safe:
            localization.string("badge.safe", defaultValue: "可再生")
        case .review:
            localization.string("badge.review", defaultValue: "需审阅")
        case .manual:
            localization.string("badge.manual", defaultValue: "仅供参考")
        }
    }

    private var color: Color {
        SystemDataBadgeColor.systemColor(for: badge)
    }
}

// MARK: - Widget card layout

/// Card metrics shared by the widget body and its span calculation, so the
/// descriptor's allocated height matches the intrinsic three-line layout.
/// The host grid is `PluginPanelWidgetLayoutMetrics.default` (8pt per span
/// unit); line heights mirror `PluginTypography`'s AppKit metrics.
enum SystemDataWidgetLayout {
    static let cardPadding: CGFloat = 10
    static let cardSpacing: CGFloat = 5
    /// Chevron button frame sets the header line height.
    static let headerHeight: CGFloat = 16
    /// `PluginTypography.prominentMetric` (largeTitle) line height.
    static let metricLineHeight: CGFloat = 32
    /// `PluginTypography.caption` line height.
    static let captionLineHeight: CGFloat = 13

    static var cardContentHeight: CGFloat {
        cardPadding * 2
            + headerHeight
            + metricLineHeight
            + captionLineHeight
            + cardSpacing * 2
    }
}

// MARK: - Widget card content

/// Self-contained card body: title line, headline metric, one caption line.
struct SystemDataWidgetView: View {
    @ObservedObject var controller: SystemDataController
    let localization: PluginLocalization
    let pluginTitle: String
    let presentDetail: () -> Void

    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: SystemDataWidgetLayout.cardSpacing) {
            header
            PluginMetricValue(
                metric.value,
                unit: metric.unit,
                isProminent: true,
                unitColor: theme.text.secondary
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(caption)
                .font(PluginTypography.caption.font)
                .foregroundStyle(theme.text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(SystemDataWidgetLayout.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PluginComponentCardBackground())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "externaldrive")
                .font(PluginTypography.caption.font.weight(.semibold))
                .foregroundStyle(theme.text.secondary)
            Text(pluginTitle)
                .font(PluginTypography.caption.font.weight(.medium))
                .foregroundStyle(theme.text.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: presentDetail) {
                Image(systemName: "chevron.right")
                    .font(PluginTypography.caption.font.weight(.bold))
                    .foregroundStyle(theme.text.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(localization.string("widget.detail.title", defaultValue: "分类占用"))
            .accessibilityLabel(localization.string("widget.detail.title", defaultValue: "分类占用"))
        }
    }

    private var metric: (value: String, unit: String) {
        switch controller.state {
        case .idle:
            return ("—", "")
        case let .scanning(progress):
            return SystemDataFormatting.metric(progress.bytesFound)
        case .cancelled, .failed, .completed:
            if let summary = controller.summary {
                return SystemDataFormatting.metric(summary.totalBytes)
            }
            return ("—", "")
        }
    }

    private var caption: String {
        switch controller.state {
        case .idle:
            return localization.string("widget.caption.idle", defaultValue: "等待扫描…")
        case let .scanning(progress):
            return localization.format(
                "panel.subtitle.progress",
                defaultValue: "%d/%d 项",
                progress.completedItems,
                progress.totalItems
            )
        case .cancelled:
            return localization.string("panel.subtitle.cancelled", defaultValue: "扫描已取消")
        case .failed:
            return localization.string("panel.subtitle.failed", defaultValue: "扫描失败")
        case .completed:
            guard let summary = controller.summary else { return "" }
            var segments: [String] = []
            if let available = summary.availableBytes {
                segments.append(localization.format(
                    "widget.caption.available",
                    defaultValue: "可用 %@",
                    SystemDataFormatting.bytes(available)
                ))
            }
            if let capacity = summary.capacityBytes {
                segments.append(localization.format(
                    "widget.caption.capacity",
                    defaultValue: "容量 %@",
                    SystemDataFormatting.bytes(capacity)
                ))
            }
            segments.append(localization.format(
                "widget.caption.updated",
                defaultValue: "更新于 %@",
                summary.scannedAt.formatted(.relative(presentation: .named))
            ))
            return segments.joined(separator: " · ")
        }
    }

    private var accessibilitySummary: String {
        [pluginTitle, metric.value + " " + metric.unit, caption]
            .filter { !$0.isEmpty && $0 != "—" }
            .joined(separator: "，")
    }
}

// MARK: - Widget detail panel

/// Bounded scrollable breakdown: one compact row per group plus a settings entry.
struct SystemDataWidgetDetailView: View {
    @ObservedObject var controller: SystemDataController
    @ObservedObject var preferences: SystemDataDisplayPreferences
    let localization: PluginLocalization
    let openSettings: () -> Void

    @Environment(\.pluginComponentTheme) private var theme

    private var visibleGroups: [SystemDataGroup] {
        SystemDataPresentation.visible(
            groups: controller.groups,
            showAllItems: preferences.showAllItems
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                if visibleGroups.isEmpty {
                    Text(emptyStateText)
                        .font(PluginTypography.detail.font)
                        .foregroundStyle(theme.text.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    ForEach(visibleGroups) { group in
                        groupRow(group)
                    }
                    Divider().foregroundStyle(theme.surfaces.track)
                    footer
                }
            }
        }
        .frame(maxHeight: 340)
    }

    private func groupRow(_ group: SystemDataGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: group.systemImage)
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(theme.text.secondary)
                    .frame(width: 14)
                Text(group.label.resolve(localization))
                    .font(PluginTypography.detail.font)
                    .foregroundStyle(theme.text.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(SystemDataFormatting.bytes(group.bytes))
                    .font(PluginTypography.value.font)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)
            }
            bar(fraction: fraction(of: group), badge: group.badge)
        }
    }

    private func bar(fraction: Double, badge: SystemDataBadge) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surfaces.track)
                Capsule()
                    .fill(SystemDataBadgeColor.systemColor(for: badge).opacity(0.75))
                    .frame(width: max(3, proxy.size.width * fraction))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = controller.summary {
                Text(summaryLine(summary))
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(2)
            }
            Button(action: openSettings) {
                Label(
                    localization.string("widget.detail.openSettings", defaultValue: "打开完整清单"),
                    systemImage: "arrow.up.right.square"
                )
                .font(PluginTypography.control.font)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryLine(_ summary: SystemDataScanSummary) -> String {
        var segments = [
            localization.format(
                "widget.detail.total",
                defaultValue: "合计 %@",
                SystemDataFormatting.bytes(summary.totalBytes)
            ),
        ]
        if let available = summary.availableBytes {
            segments.append(localization.format(
                "widget.detail.free",
                defaultValue: "可用 %@",
                SystemDataFormatting.bytes(available)
            ))
        }
        if let capacity = summary.capacityBytes {
            segments.append(localization.format(
                "widget.detail.capacity",
                defaultValue: "容量 %@",
                SystemDataFormatting.bytes(capacity)
            ))
        }
        return segments.joined(separator: " · ")
    }

    private var emptyStateText: String {
        switch controller.state {
        case .idle:
            return localization.string("widget.caption.idle", defaultValue: "等待扫描…")
        case let .scanning(progress):
            return localization.format(
                "status.scanning",
                defaultValue: "正在扫描 %d/%d 项…",
                progress.completedItems,
                progress.totalItems
            )
        case .cancelled:
            return localization.string("panel.subtitle.cancelled", defaultValue: "扫描已取消")
        case .failed:
            return localization.string("panel.subtitle.failed", defaultValue: "扫描失败")
        case .completed:
            return localization.string("settings.group.empty", defaultValue: "未发现相关文件")
        }
    }

    private func fraction(of group: SystemDataGroup) -> Double {
        guard let total = controller.summary?.totalBytes, total > 0 else { return 0 }
        return min(1, max(0, Double(group.bytes) / Double(total)))
    }
}
