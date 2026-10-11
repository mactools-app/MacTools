import AppKit
import MacToolsPluginKit
import SwiftUI

/// Full inventory workspace: status row, summary card, collapsible group cards
/// with per-item sizes, safety badges, and Finder reveal / copy-path buttons.
///
/// Read-only by design: the workspace never deletes anything, so every button
/// here only starts a scan, cancels it, reveals an existing location, or
/// copies its path.
struct SystemDataWorkspaceView: View {
    @ObservedObject var controller: SystemDataController
    @ObservedObject var preferences: SystemDataDisplayPreferences
    let localization: PluginLocalization

    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path

    /// Collapsed group ids; empty means every group starts expanded.
    @State private var collapsedGroupIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            statusRow
            showAllToggle
            summaryCard
            if !visibleGroups.isEmpty {
                groupControls
            }
            ForEach(visibleGroups) { group in
                groupCard(group)
            }
            scopeNote
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Show-all toggle

    private var visibleGroups: [SystemDataGroup] {
        SystemDataPresentation.visible(
            groups: controller.groups,
            showAllItems: preferences.showAllItems
        )
    }

    private var showAllToggle: some View {
        Toggle(isOn: $preferences.showAllItems) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(localization.string(
                    "settings.showAllItems",
                    defaultValue: "显示所有条目"
                ))
                .font(PluginSettingsTheme.Typography.rowTitle)
                Text(localization.string(
                    "settings.showAllItems.description",
                    defaultValue: "关闭时隐藏未发现的条目"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.standard)
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    Image(systemName: statusSymbol)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(statusColor)
                    Text(statusTitle)
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .foregroundStyle(statusColor)
                }
                if let failure = controller.state.failureMessage {
                    Text(failure)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
            statusButton
        }
    }

    private var statusButton: some View {
        Button {
            if controller.state.isScanning {
                controller.cancel()
            } else {
                controller.scan()
            }
        } label: {
            if controller.state.isScanning {
                Label(
                    localization.string("settings.cancel", defaultValue: "取消"),
                    systemImage: "xmark.circle"
                )
            } else {
                Label(
                    localization.string("settings.refresh", defaultValue: "刷新"),
                    systemImage: "arrow.clockwise"
                )
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var statusTitle: String {
        switch controller.state {
        case .idle:
            return localization.string("status.idle", defaultValue: "尚未扫描")
        case let .scanning(progress):
            return localization.format(
                "status.scanning",
                defaultValue: "正在扫描 %d/%d 项…",
                progress.completedItems,
                progress.totalItems
            )
        case .cancelled:
            return localization.string("status.cancelled", defaultValue: "扫描已取消")
        case .failed:
            return localization.string("status.failed", defaultValue: "扫描失败")
        case .completed:
            guard let summary = controller.summary else {
                return localization.string("status.completed", defaultValue: "扫描完成")
            }
            let scannedAt = summary.scannedAt.formatted(date: .abbreviated, time: .shortened)
            return localization.format(
                "status.completedAt",
                defaultValue: "扫描完成 · %@",
                scannedAt
            )
        }
    }

    private var statusSymbol: String {
        switch controller.state {
        case .idle: "circle"
        case .scanning: "arrow.triangle.2.circlepath"
        case .cancelled: "minus.circle"
        case .failed: "exclamationmark.triangle"
        case .completed: "checkmark.circle"
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .failed: .red
        case .completed: .primary
        default: .secondary
        }
    }

    // MARK: - Summary card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.section) {
                metricBlock(
                    label: localization.string("summary.total", defaultValue: "系统数据合计"),
                    metric: controller.summary.map { SystemDataFormatting.metric($0.totalBytes) }
                )
                metricBlock(
                    label: localization.string("summary.free", defaultValue: "可用空间"),
                    metric: controller.summary?.availableBytes.map { SystemDataFormatting.metric($0) }
                )
                metricBlock(
                    label: localization.string("summary.capacity", defaultValue: "磁盘容量"),
                    metric: controller.summary?.capacityBytes.map { SystemDataFormatting.metric($0) }
                )
            }

            if case let .scanning(progress) = controller.state, progress.totalItems > 0 {
                ProgressView(
                    value: Double(progress.completedItems),
                    total: Double(progress.totalItems)
                )
                .progressViewStyle(.linear)
            }

            if let summary = controller.summary {
                Text(
                    localization.format(
                        "summary.scannedAt",
                        defaultValue: "上次扫描 %@",
                        summary.scannedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            }
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.standard)
    }

    private func metricBlock(
        label: String,
        metric: (value: String, unit: String)?
    ) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Text(label)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let metric {
                PluginMetricValue(metric.value, unit: metric.unit)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(localization.string("summary.unavailable", defaultValue: "—"))
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Group card

    private func groupCard(_ group: SystemDataGroup) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            groupHeader(group)

            if !collapsedGroupIDs.contains(group.id) {
                groupBar(group)

                VStack(spacing: 0) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider()
                        }
                        itemRow(item)
                    }
                }
            }
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.standard)
    }

    private func groupHeader(_ group: SystemDataGroup) -> some View {
        let isCollapsed = collapsedGroupIDs.contains(group.id)
        return Button {
            withAnimation(.default) {
                if isCollapsed {
                    collapsedGroupIDs.remove(group.id)
                } else {
                    collapsedGroupIDs.insert(group.id)
                }
            }
        } label: {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: "chevron.right")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Label {
                    Text(group.label.resolve(localization))
                        .font(PluginSettingsTheme.Typography.sectionTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: group.systemImage)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                SystemDataBadgeLabel(badge: group.badge, localization: localization)
                Text(SystemDataFormatting.bytes(group.bytes))
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func groupBar(_ group: SystemDataGroup) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(SystemDataBadgeColor.systemColor(for: group.badge).opacity(0.7))
                    .frame(width: max(3, proxy.size.width * fraction(of: group)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private func fraction(of group: SystemDataGroup) -> Double {
        guard let total = controller.summary?.totalBytes, total > 0 else { return 0 }
        return min(1, max(0, Double(group.bytes) / Double(total)))
    }

    // MARK: - Group controls

    private var groupControls: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Spacer(minLength: 0)
            Button {
                withAnimation(.default) {
                    collapsedGroupIDs.formUnion(visibleGroups.map(\.id))
                }
            } label: {
                Label(
                    localization.string("settings.collapseAll", defaultValue: "折叠所有"),
                    systemImage: "rectangle.compress.vertical"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(visibleGroups.allSatisfy { collapsedGroupIDs.contains($0.id) })

            Button {
                withAnimation(.default) {
                    collapsedGroupIDs.removeAll()
                }
            } label: {
                Label(
                    localization.string("settings.expandAll", defaultValue: "展开所有"),
                    systemImage: "rectangle.expand.vertical"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(collapsedGroupIDs.isEmpty)
        }
    }

    // MARK: - Item row

    private func itemRow(_ item: SystemDataItem) -> some View {
        HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    Text(item.label.resolve(localization))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .lineLimit(1)
                    SystemDataBadgeLabel(badge: item.badge, localization: localization)
                }
                Text(item.path)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            statusText(for: item)
                .frame(minWidth: 76, alignment: .trailing)

            revealButton(for: item)
            copyButton(for: item)
        }
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }

    @ViewBuilder
    private func statusText(for item: SystemDataItem) -> some View {
        switch item.status {
        case let .measured(bytes):
            PluginMetricValue(
                SystemDataFormatting.metric(bytes).value,
                unit: SystemDataFormatting.metric(bytes).unit
            )
        case .absent:
            Text(localization.string("item.absent", defaultValue: "未发现"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
        case .unreadable:
            Text(localization.string("item.unreadable", defaultValue: "无法读取"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func revealButton(for item: SystemDataItem) -> some View {
        let expanded = SystemDataCatalog.expand(path: item.path, home: homeDirectory)
        let canReveal = item.status.isMeasured && Self.pathExists(expanded)
        Button {
            Self.reveal(path: expanded)
        } label: {
            Image(systemName: "folder")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!canReveal)
        .help(localization.string("item.reveal", defaultValue: "在 Finder 中显示"))
        .accessibilityLabel(localization.string("item.reveal", defaultValue: "在 Finder 中显示"))
    }

    @ViewBuilder
    private func copyButton(for item: SystemDataItem) -> some View {
        let expanded = SystemDataCatalog.expand(path: item.path, home: homeDirectory)
        Button {
            Self.copyPath(expanded)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(localization.string("item.copyPath", defaultValue: "复制路径"))
        .accessibilityLabel(localization.string("item.copyPath", defaultValue: "复制路径"))
    }

    // MARK: - Note

    private var scopeNote: some View {
        Text(localization.string("settings.scopeNote", defaultValue: "受系统保护的位置（应用容器、邮件等）不在统计范围内。"))
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Row action helpers

    static func pathExists(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    }

    static func reveal(path: String) {
        guard pathExists(path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Copies the expanded location to the general pasteboard; non-absolute
    /// paths are never written so the clipboard cannot hold template junk.
    static func copyPath(_ path: String) {
        guard path.hasPrefix("/") else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}
