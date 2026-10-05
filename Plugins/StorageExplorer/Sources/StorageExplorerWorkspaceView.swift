import AppKit
import MacToolsPluginKit
import Quartz
import SwiftUI

public struct StorageExplorerWorkspaceView: View {
    @ObservedObject public var controller: StorageExplorerController
    public let localization: PluginLocalization
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var hoveredBreadcrumbIndex: Int?
    @State private var hoveredTreemapListRowID: String?
    @State private var hoveredTreemapSummary: StorageExplorerTreemapHoverSummary?
    @State private var isReviewDropTargeted = false
    @StateObject private var quickLookPresenter = StorageExplorerQuickLookPresenter()

    public init(controller: StorageExplorerController,
                localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.controller = controller
        self.localization = localization
    }

    private func text(_ key: String, _ fallback: String) -> String {
        localization.string("storageExplorer." + key, defaultValue: fallback)
    }

    public var body: some View {
        GeometryReader { geometry in
            workspace(width: geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func workspace(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            if controller.rootItem == nil {
                controls
            }
            if controller.rootItem != nil {
                explorer(width: width)
                    .layoutPriority(1)
                reviewBar.layoutPriority(2)
            } else if controller.isScanning {
                StorageExplorerScanningView(
                    status: controller.status,
                    metric: controller.metric,
                    startedAt: controller.scanStartedAt,
                    scanningTitle: text("scanning", "正在扫描…"),
                    finalizingTitle: text("finalizing", "正在整理结果…"),
                    filesScannedFormat: text("filesScannedFormat", "已扫描 %d 个项目"),
                    elapsedSecondsFormat: text("elapsedSecondsFormat", "%.1f 秒"),
                    skippedCountFormat: text("skippedCount", "跳过 %d 项")
                )
            } else {
                ContentUnavailableView(text("emptyStateTitle", "选择要分析的文件夹"), systemImage: "internaldrive",
                    description: Text(text("exploreDescription", "查看空间分布、查找大文件，审阅后移至废纸篓。")))
            }
            if let error = controller.lastErrorMessage {
                Text(error).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red).textSelection(.enabled)
            }
            if let success = controller.lastSuccessMessage {
                Text(success).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
        }
        .padding(PluginSettingsTheme.Spacing.section)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $controller.isConfirmingTrash) {
            confirmation
                .environment(\.layoutDirection, layoutDirection)
                .environment(\.locale, locale)
        }
    }

    private func explorer(width: CGFloat) -> some View {
        Group {
            if width >= 680 {
                GeometryReader { geometry in
                    HSplitView {
                        treemapPanel(nodes: controller.hierarchyNodes)
                            .frame(
                                minWidth: max(420, geometry.size.width * 0.52),
                                idealWidth: geometry.size.width * 0.72,
                                maxWidth: .infinity
                            )
                        compactList
                            .frame(
                                minWidth: 220,
                                idealWidth: geometry.size.width * 0.28,
                                maxWidth: .infinity
                            )
                            .opacity(controller.isUpdatingPresentation ? 0.5 : 1)
                            .allowsHitTesting(!controller.isUpdatingPresentation)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    treemapPanel(nodes: controller.hierarchyNodes)
                    compactList
                        .frame(maxHeight: 120)
                        .opacity(controller.isUpdatingPresentation ? 0.5 : 1)
                        .allowsHitTesting(!controller.isUpdatingPresentation)
                }
            }
        }
        .frame(minHeight: 280, maxHeight: .infinity)
        .clipped()
        .animation(.easeOut(duration: 0.16), value: controller.isUpdatingPresentation)
    }

    private func treemapPanel(nodes: [StorageExplorerHierarchyNode]) -> some View {
        VStack(spacing: 0) {
            treemapPathRail
            Divider()
            if controller.isScanning {
                StorageExplorerRefreshStatusView(
                    status: controller.status,
                    metric: controller.metric,
                    startedAt: controller.scanStartedAt,
                    refreshingTitle: text("refreshing", "正在刷新扫描结果…"),
                    finalizingTitle: text("finalizing", "正在整理结果…"),
                    filesScannedFormat: text("filesScannedFormat", "已扫描 %d 个项目"),
                    elapsedSecondsFormat: text("elapsedSecondsFormat", "%.1f 秒"),
                    cancelTitle: text("cancel", "取消"),
                    cancel: controller.cancelScan
                )
                Divider()
            }
            ZStack {
                StorageExplorerHierarchyTreemapView(
                    nodes: nodes,
                    layoutRevision: controller.hierarchyRevision,
                    selection: $controller.selectedPath,
                    hoveredListRowID: $hoveredTreemapListRowID,
                    hoveredSummary: $hoveredTreemapSummary,
                    emptyLabel: text("noSizedItems", "尚无可显示的大小"),
                    reviewCopy: reviewEligibilityCopy,
                    revealInFinderLabel: text("revealInFinder", "在访达中显示"),
                    open: controller.drillDown,
                    preview: showQuickLook,
                    toggleReview: { controller.toggleSelection(path: $0.path) },
                    reviewEligibility: controller.reviewEligibility,
                    revealInFinder: { controller.revealInFinder(path: $0.path) },
                    layoutReady: controller.presentationDidRender
                )
                .saturation(controller.isUpdatingPresentation ? 0.58 : 1)
                .brightness(controller.isUpdatingPresentation ? -0.035 : 0)

                if controller.isUpdatingPresentation {
                    StorageExplorerTreemapUpdateEffect()
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(!controller.isUpdatingPresentation)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(.easeOut(duration: 0.16), value: controller.isUpdatingPresentation)
        }
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
    }

    private var controls: some View {
        HStack {
            Button { controller.scanHomeFolder() } label: { Label(text("homeFolder", "个人目录"), systemImage: "house") }
                .fixedSize(horizontal: true, vertical: false)
            Button { controller.selectFolderAndScan() } label: { Label(text("selectFolder", "选择文件夹…"), systemImage: "folder.badge.plus") }
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
            if controller.isScanning {
                Button(text("cancel", "取消"), role: .cancel) { controller.cancelScan() }
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(controller.isExecutingTrash)
    }

    private var reviewEligibilityCopy: StorageExplorerReviewEligibilityCopy {
        StorageExplorerReviewEligibilityCopy(
            addToReview: text("addToReview", "加入审阅"),
            removeFromReview: text("removeFromReview", "移出审阅"),
            selected: text("reviewSelected", "已加入审阅。"),
            includedByParentFormat: text("reviewIncludedByParentFormat", "已随“%@”加入审阅。"),
            busy: text("updatingTreemap", "正在更新空间图…"),
            incompleteFormat: text(
                "reviewIncompleteFormat",
                "有 %d 个内容未能扫描。显示大小为最低估计，实际释放空间可能不同。"
            ),
            symlink: text(
                "symlinkReviewUnsupported",
                "符号链接不能加入审阅；请在访达中管理链接本身。"
            ),
            aggregate: text(
                "aggregateReviewUnsupported",
                "这是多个较小项目的合并视图，不能作为单个项目加入审阅。"
            ),
            cachedPreview: text(
                "cachedPreviewReviewUnavailable",
                "这是上次扫描的预览。请等待刷新完成后再加入审阅。"
            ),
            scanRoot: text("reviewScanRoot", "当前扫描文件夹本身不能加入审阅。"),
            protectedLocation: text("reviewProtected", "此位置受保护，不能移至废纸篓。"),
            unavailable: text("reviewUnavailable", "此项目不能加入审阅。")
        )
    }

    private var treemapPathRail: some View {
        HStack(spacing: 6) {
            if controller.navigationStack.count > 1 {
                Button { controller.navigateUp() } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help(text("goUp", "返回上一级"))
                .frame(width: 24, height: 24)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(controller.navigationStack.enumerated()), id: \.element.path) { index, item in
                        if index > 0 {
                            Image(systemName: "chevron.forward")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        breadcrumbSegment(item, index: index)
                    }
                }
                .font(PluginSettingsTheme.Typography.rowDescription)
            }
            .layoutPriority(1)

            Spacer(minLength: 4)
            if controller.isUpdatingPresentation {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(text("updatingTreemap", "正在更新空间图…"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                .transition(.opacity)
            } else {
                if let hoveredTreemapSummary {
                    treemapHoverSummary(hoveredTreemapSummary)
                } else {
                    scanSummary
                }
                scanActions
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.035))
        .animation(.easeOut(duration: 0.16), value: controller.isUpdatingPresentation)
    }

    private func treemapHoverSummary(_ summary: StorageExplorerTreemapHoverSummary) -> some View {
        let color: Color = switch summary.tone {
        case .normal: .secondary
        case .warning: .orange
        case .blocked: .red
        case .selected: .accentColor
        }
        return Label {
            HStack(spacing: 5) {
                Text(summary.title).fontWeight(.semibold)
                Text(summary.detail).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
        } icon: {
            Image(systemName: summary.systemImage)
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .foregroundStyle(color)
        .frame(maxWidth: 460, alignment: .trailing)
        .help("\(summary.path)\n\(summary.detail)")
    }

    private func breadcrumbSegment(_ item: StorageItem, index: Int) -> some View {
        let isCurrent = index == controller.navigationStack.count - 1
        let size = StorageExplorerFormatting.bytes(controller.metric.bytes(item))
        return Button {
            controller.navigateToBreadcrumb(at: index)
        } label: {
            Text(item.name.isEmpty ? "/" : item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .fontWeight(isCurrent ? .semibold : .regular)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Color.accentColor.opacity(isCurrent ? 0.12 : hoveredBreadcrumbIndex == index ? 0.09 : 0),
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                hoveredBreadcrumbIndex = index
            } else if hoveredBreadcrumbIndex == index {
                hoveredBreadcrumbIndex = nil
            }
        }
        .help("\(item.path)\n\(size)")
        .accessibilityHint(String(format: text("openPath", "打开 %@"), locale: PluginRuntimeLocalization.locale, item.path))
    }

    private var scanSummary: some View {
        let summaryBytes = controller.isShowingCachedPreview
            ? controller.rootItem.map(controller.metric.bytes) ?? 0
            : controller.status.progress.allocatedBytesScanned
        let size = StorageExplorerFormatting.bytes(summaryBytes)
        let skipped = controller.status.progress.skippedCount
        return HStack(spacing: 7) {
            Text(size).fontWeight(.semibold)
            if controller.isShowingCachedPreview, let previewDate = controller.cachedPreviewDate {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Label(
                        String(format: text("previousScanAgeFormat", "上次扫描：%@"), locale: PluginRuntimeLocalization.locale, relativeScanAge(
                            from: previewDate,
                            relativeTo: context.date
                        )),
                        systemImage: "clock.arrow.circlepath"
                    )
                }
            } else if controller.isScanning {
                Label(text("scanning", "正在扫描…"), systemImage: "arrow.triangle.2.circlepath")
            } else if let completedAt = controller.scanCompletedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(String(format: text("scanAgeFormat", "扫描时间：%@"), locale: PluginRuntimeLocalization.locale, relativeScanAge(
                        from: completedAt,
                        relativeTo: context.date
                    )))
                }
            }
            if skipped > 0 { skippedSummary(count: skipped) }
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize()
    }

    private func skippedSummary(count: Int) -> some View {
        Label(
            String(format: text("skippedCount", "跳过 %d 项"), locale: PluginRuntimeLocalization.locale, count),
            systemImage: "exclamationmark.circle"
        )
        .foregroundStyle(.orange)
        .help(String(format: text(
            "skippedDetailsMessage",
            "%d 个项目因权限、云端占位文件或文件系统边界而被跳过。显示的总大小可能偏低。"
        ), locale: PluginRuntimeLocalization.locale, count))
    }

    private var scanActions: some View {
        Menu {
            Button { controller.scanHomeFolder() } label: {
                Label(text("homeFolder", "个人目录"), systemImage: "house")
            }
            Button { controller.selectFolderAndScan() } label: {
                Label(text("selectFolder", "选择文件夹…"), systemImage: "folder.badge.plus")
            }
            if let root = controller.scanRootURL {
                Divider()
                if controller.isScanning {
                    Button(text("cancel", "取消"), role: .cancel) { controller.cancelScan() }
                } else {
                    Button { controller.startScan(at: root) } label: {
                        Label(text("refresh", "刷新"), systemImage: "arrow.clockwise")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(text("selectFolder", "选择文件夹…"))
        .disabled(controller.isExecutingTrash)
    }

    private var compactList: some View {
        let eligibilityCopy = reviewEligibilityCopy
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(controller.rows.prefix(16)) { row in
                        compactListRow(row, eligibilityCopy: eligibilityCopy)
                    }
                }
            }
            if let item = controller.inspectedItem {
                Divider()
                inlineDetails(for: item)
            }
        }
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(text("results", "扫描结果"))
    }

    private func compactListRow(
        _ row: StorageExplorerRow,
        eligibilityCopy: StorageExplorerReviewEligibilityCopy
    ) -> some View {
        let isTreemapHovered = listRowMatchesTreemapHover(row)
        let eligibility = controller.reviewEligibility(for: row.item)
        let backgroundColor = controller.selectedPath == row.id
            ? Color.accentColor.opacity(0.12)
            : isTreemapHovered ? Color.accentColor.opacity(0.14) : Color.clear
        let borderColor = isTreemapHovered ? Color.accentColor.opacity(0.7) : Color.clear
        let help = "\(row.item.path)\n\(eligibilityCopy.message(for: eligibility))"

        return HStack(spacing: 8) {
            Button {
                controller.toggleSelection(path: row.item.path)
            } label: {
                Image(systemName: eligibilityCopy.icon(for: eligibility))
                    .foregroundStyle(reviewEligibilityColor(for: eligibility))
            }
            .buttonStyle(.plain)
            .disabled(!eligibility.canToggle)
            .help(eligibilityCopy.message(for: eligibility))
            Text(localizedName(row)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(row.sizeLabel)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if row.item.isDirectory && !row.item.isPackage {
                Button { controller.drillDown(to: row.item) } label: {
                    Image(systemName: "chevron.forward")
                }
                .buttonStyle(.plain)
                .help(text("openFolder", "打开文件夹"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if row.item.isDirectory && !row.item.isPackage {
                controller.drillDown(to: row.item)
            } else {
                controller.selectedPath = row.id
            }
        }
        .modifier(StorageExplorerListDragModifier(
            enabled: eligibility.canAdd,
            path: row.item.path
        ))
        .contextMenu {
            compactListContextMenu(row: row, eligibility: eligibility, eligibilityCopy: eligibilityCopy)
        }
        .focusable(true, interactions: .activate)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            showQuickLook(for: row.item) ? .handled : .ignored
        }
        .help(help)
    }

    @ViewBuilder
    private func compactListContextMenu(
        row: StorageExplorerRow,
        eligibility: StorageExplorerReviewEligibility,
        eligibilityCopy: StorageExplorerReviewEligibilityCopy
    ) -> some View {
        if eligibility.canToggle {
            let isSelected = eligibility == .selected
            Button {
                controller.toggleSelection(path: row.item.path)
            } label: {
                Label(
                    isSelected
                        ? text("removeFromReview", "移出审阅")
                        : text("addToReview", "加入审阅"),
                    systemImage: isSelected ? "minus.circle" : "plus.circle"
                )
            }
        } else {
            Button {} label: {
                Label(
                    eligibilityCopy.message(for: eligibility),
                    systemImage: eligibilityCopy.icon(for: eligibility)
                )
            }
            .disabled(true)
        }
        Divider()
        Button {
            controller.revealInFinder(path: row.item.path)
        } label: {
            Label(text("revealInFinder", "在访达中显示"), systemImage: "folder")
        }
    }

    private func localizedName(_ row: StorageExplorerRow) -> String {
        row.id == "type:package" ? text("applicationsAndPackages", "应用与软件包") : row.name
    }

    private func listRowMatchesTreemapHover(_ row: StorageExplorerRow) -> Bool {
        hoveredTreemapListRowID == row.item.path
    }

    private func reviewEligibilityColor(for eligibility: StorageExplorerReviewEligibility) -> Color {
        switch eligibility {
        case .eligible, .selected, .includedBySelectedParent:
            .accentColor
        case .incomplete, .unavailable, .cachedPreview:
            .orange
        case .scanRoot, .protectedLocation:
            .red
        case .busy, .symlink, .aggregate:
            .secondary
        }
    }

    private func showQuickLook(for item: StorageItem) -> Bool {
        guard !item.isDirectory,
              !item.isSymlink,
              !item.isCloudPlaceholder,
              !item.path.hasPrefix("type:") else {
            return false
        }
        controller.selectedPath = item.path
        quickLookPresenter.show(item.url)
        return true
    }

    private func inlineDetails(for item: StorageItem) -> some View {
        let eligibility = controller.reviewEligibility(for: item)
        let eligibilityCopy = reviewEligibilityCopy
        return HStack(spacing: 8) {
            Image(systemName: item.iconSystemName)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.path)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(StorageExplorerFormatting.bytes(item.allocatedSize))
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                if item.size != item.allocatedSize {
                    Text(StorageExplorerFormatting.bytes(item.size))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(text("logicalSize", "文件大小"))
                }
            }
            if item.isAccessDenied {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                    .help(text("accessDenied", "无访问权限"))
            }
            if item.isCloudPlaceholder {
                Image(systemName: "icloud")
                    .foregroundStyle(.secondary)
                    .help(text("cloudPlaceholder", "仅在云端"))
            }
            if item.isSymlink {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .help(text("symlinkReviewUnsupported", "符号链接不能加入审阅；请在访达中管理链接本身。"))
            }
            if item.isIncomplete {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .help(text("incomplete", "大小尚不完整"))
            }
            if !item.isDirectory && !item.isSymlink && !item.isCloudPlaceholder {
                Button { _ = showQuickLook(for: item) } label: {
                    Image(systemName: "eye")
                }
                .help(text("preview", "预览"))
            }
            Button { controller.revealInFinder(path: item.path) } label: {
                Image(systemName: "folder")
            }
            .help(text("revealInFinder", "在访达中显示"))
            Button { controller.toggleSelection(path: item.path) } label: {
                Image(systemName: eligibilityCopy.icon(for: eligibility))
                    .foregroundStyle(reviewEligibilityColor(for: eligibility))
            }
            .disabled(!eligibility.canToggle)
            .help(eligibilityCopy.message(for: eligibility))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .help(inlineDetailsHelp(for: item))
    }

    private func inlineDetailsHelp(for item: StorageItem) -> String {
        var lines = [item.path]
        lines.append("\(text("allocatedSize", "占用空间")): \(StorageExplorerFormatting.bytes(item.allocatedSize))")
        lines.append("\(text("logicalSize", "文件大小")): \(StorageExplorerFormatting.bytes(item.size))")
        if item.isHardLinked {
            lines.append(String(format: text(
                "hardLinkNotice",
                "此文件有 %d 个硬链接；移除最后一个链接后才会释放空间。"
            ), locale: PluginRuntimeLocalization.locale, item.hardLinkCount))
        }
        if item.isAccessDenied { lines.append(text("accessDenied", "无访问权限")) }
        if item.isCloudPlaceholder { lines.append(text("cloudPlaceholder", "仅在云端")) }
        if item.isSymlink {
            lines.append(text("symlinkReviewUnsupported", "符号链接不能加入审阅；请在访达中管理链接本身。"))
        }
        if item.isIncomplete { lines.append(text("incomplete", "大小尚不完整")) }
        lines.append(reviewEligibilityCopy.message(for: controller.reviewEligibility(for: item)))
        lines.append(text("spaceNote", "占用空间不等于可释放空间；共享数据和废纸篓会影响实际可用容量。"))
        return lines.joined(separator: "\n")
    }

    private var reviewBar: some View {
        HStack(spacing: 10) {
            Image(systemName: isReviewDropTargeted
                ? "arrow.down.circle.fill"
                : controller.basket.isEmpty ? "tray.and.arrow.down" : "checkmark.circle.fill")
                .foregroundStyle(isReviewDropTargeted
                    ? Color.accentColor
                    : controller.basket.isEmpty ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if controller.basket.isEmpty {
                    Text(text("dropToReview", "拖到这里以加入审阅"))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    Text(text("dropToReviewDescription", "也可以点按项目旁的加号。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                } else {
                    Text(String(format: text("selectedItemsFormat", "已选 %d 个项目（共 %@）"), locale: PluginRuntimeLocalization.locale, controller.basket.count,
                        StorageExplorerFormatting.bytes(controller.totalSelectedBytes)))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle).monospacedDigit()
                    Text(controller.selectedItemsForReview.prefix(3).map(\.name).joined(separator: " · "))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button(text("clearSelection", "取消选择")) { controller.clearSelection() }
                .disabled(controller.basket.isEmpty || controller.isUpdatingPresentation)
            Button(text("review", "审阅…")) { controller.confirmTrash() }
                .buttonStyle(.borderedProminent)
                .disabled(controller.reviewAvailability != .ready)
                .help(reviewAvailabilityHelp)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(
            Color.accentColor.opacity(isReviewDropTargeted ? 0.18 : controller.basket.isEmpty ? 0.04 : 0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(isReviewDropTargeted ? 1 : 0.65),
                        lineWidth: isReviewDropTargeted ? 2.5 : 1.5)
        )
        .dropDestination(for: String.self) { paths, _ in
            isReviewDropTargeted = false
            guard !controller.isUpdatingPresentation else { return false }
            let eligibleItems = paths.compactMap { path -> StorageItem? in
                guard let item = controller.snapshot.items[path],
                      controller.reviewEligibility(for: item).canAdd else { return nil }
                return item
            }
            var accepted = false
            for item in eligibleItems {
                if !controller.basket.contains(item.path) {
                    controller.toggleSelection(path: item.path)
                    accepted = accepted || controller.basket.contains(item.path)
                }
            }
            return accepted
        } isTargeted: { isTargeted in
            isReviewDropTargeted = isTargeted && !controller.isUpdatingPresentation
        }
        .animation(.easeOut(duration: 0.12), value: isReviewDropTargeted)
    }

    private func relativeScanAge(from date: Date, relativeTo referenceDate: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }

    private var reviewAvailabilityHelp: String {
        switch controller.reviewAvailability {
        case .empty:
            return text("reviewEmptyHelp", "先将项目加入审阅。")
        case .scanning:
            return text("reviewScanningHelp", "扫描完成后可以审阅。")
        case .cachedPreview:
            return text("cachedPreviewReviewUnavailable", "这是上次扫描的预览。请等待刷新完成后再加入审阅。")
        case .updating:
            return text("updatingTreemap", "正在更新空间图…")
        case .executing:
            return text("reviewExecutingHelp", "正在将所选项目移至废纸篓。")
        case .ready:
            return text("reviewReadyHelp", "检查所选项目，然后移至废纸篓。")
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            Label(text("confirmTrashTitle", "移至废纸篓确认"), systemImage: "trash")
                .font(PluginSettingsTheme.Typography.sectionTitle)
            Text(text("confirmTrashMessage", "所选项目将移至 macOS 废纸篓，可从废纸篓恢复。"))
            List(controller.reviewItems) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                    Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if item.isIncomplete {
                        Label(
                            String(format: text(
                                "reviewIncompleteFormat",
                                "有 %d 个内容未能扫描。显示大小为最低估计，实际释放空间可能不同。"
                            ), locale: PluginRuntimeLocalization.locale, max(1, item.skippedCount)),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.orange)
                    }
                }
            }.frame(height: 220)
            Text(String(format: text("selectedItemsFormat", "已选 %d 个项目（共 %@）"), locale: PluginRuntimeLocalization.locale, controller.reviewItems.count,
                StorageExplorerFormatting.bytes(controller.reviewItems.reduce(0) { $0 + controller.metric.bytes($1) })))
            HStack {
                Spacer()
                Button(text("cancel", "取消"), role: .cancel) { controller.isConfirmingTrash = false }
                Button(text("moveToTrash", "移至废纸篓…"), role: .destructive) { Task { await controller.executeTrash() } }
                    .disabled(controller.isExecutingTrash)
            }
        }.padding(24).frame(width: 540)
            .interactiveDismissDisabled(controller.isExecutingTrash)
    }
}

@MainActor
private final class StorageExplorerQuickLookPresenter: NSObject, ObservableObject,
    @preconcurrency QLPreviewPanelDataSource {
    private var previewURL: URL?

    func show(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}

private struct StorageExplorerListDragModifier: ViewModifier {
    let enabled: Bool
    let path: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.draggable(path)
        } else {
            content
        }
    }
}

private struct StorageExplorerScanningView: View {
    @ObservedObject var status: StorageExplorerScanStatus
    let metric: StorageExplorerMetric
    let startedAt: Date?
    let scanningTitle: String
    let finalizingTitle: String
    let filesScannedFormat: String
    let elapsedSecondsFormat: String
    let skippedCountFormat: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(status.progress.phase == .finalizing ? finalizingTitle : scanningTitle)
                .font(PluginSettingsTheme.Typography.sectionTitle)
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                HStack(spacing: 18) {
                    Text(StorageExplorerFormatting.bytes(
                        metric == .logical ? status.progress.bytesScanned : status.progress.allocatedBytesScanned
                    ))
                        .frame(width: 110, alignment: .trailing)
                    Text(String(format: filesScannedFormat, locale: PluginRuntimeLocalization.locale, status.progress.filesScanned))
                        .frame(width: 170, alignment: .leading)
                    Text(String(
                        format: elapsedSecondsFormat,
                        locale: PluginRuntimeLocalization.locale,
                        displayedElapsed(at: context.date)
                    ))
                        .frame(width: 64, alignment: .trailing)
                }
                .font(PluginSettingsTheme.Typography.rowDescription)
                .monospacedDigit()
            }
            if status.progress.skippedCount > 0 {
                Label(String(format: skippedCountFormat, locale: PluginRuntimeLocalization.locale, status.progress.skippedCount),
                      systemImage: "exclamationmark.circle")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayedElapsed(at date: Date) -> TimeInterval {
        StorageExplorerElapsedClock.elapsed(
            startedAt: startedAt,
            reported: status.progress.elapsed,
            now: date
        )
    }
}

private struct StorageExplorerRefreshStatusView: View {
    @ObservedObject var status: StorageExplorerScanStatus
    let metric: StorageExplorerMetric
    let startedAt: Date?
    let refreshingTitle: String
    let finalizingTitle: String
    let filesScannedFormat: String
    let elapsedSecondsFormat: String
    let cancelTitle: String
    let cancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.progress.phase == .finalizing ? finalizingTitle : refreshingTitle)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    HStack(spacing: 8) {
                        Text(StorageExplorerFormatting.bytes(
                            metric == .logical ? status.progress.bytesScanned : status.progress.allocatedBytesScanned
                        ))
                        Text(String(format: filesScannedFormat, locale: PluginRuntimeLocalization.locale, status.progress.filesScanned))
                        Text(String(
                            format: elapsedSecondsFormat,
                            locale: PluginRuntimeLocalization.locale,
                            StorageExplorerElapsedClock.elapsed(
                                startedAt: startedAt,
                                reported: status.progress.elapsed,
                                now: context.date
                            )
                        ))
                    }
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                Spacer(minLength: 8)
                Button(cancelTitle, role: .cancel, action: cancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.10))
        }
    }
}

private struct StorageExplorerTreemapUpdateEffect: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweepToTrailingEdge = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.075)

                if !reduceMotion {
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(0.04),
                            Color.white.opacity(0.24),
                            Color.white.opacity(0.04),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(
                        width: max(140, geometry.size.width * 0.34),
                        height: geometry.size.height * 1.35
                    )
                    .rotationEffect(.degrees(9))
                    .offset(x: sweepOffset(for: geometry.size.width))
                    .blendMode(.screen)
                }

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.42), lineWidth: 2)
            }
            .compositingGroup()
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.45).repeatForever(autoreverses: false)) {
                    sweepToTrailingEdge = true
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func sweepOffset(for width: CGFloat) -> CGFloat {
        sweepToTrailingEdge ? width * 0.68 : -width * 0.68
    }
}

enum StorageExplorerElapsedClock {
    static func elapsed(startedAt: Date?, reported: TimeInterval, now: Date) -> TimeInterval {
        max(reported, startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
}
