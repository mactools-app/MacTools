import SwiftUI
import MacToolsPluginKit

/// Detail view (design §8.3).
///
/// Top-to-bottom layout: limited-scan banner → scan scope & actions → category cards → execution result →
/// purge segment → leftover installers segment → settings (removal mode, cleanup history) → scan log.
/// Everything uses `PluginSettingsTheme`; visual baseline is `FanControlPresetManagerView`.
///
/// The view holds no business state: checks, removal mode, and confirm all command the Controller; only the snapshot is read back.
/// The only local state is "which cards are expanded" and the history section's load cache—purely presentational.
///
/// Each of the three segments has its own `DiskCleanController` with distinct scope and non-interfering state, but they **share the same type
/// and the same pipeline** (design §10): P2 candidates still go through sizing, completeness, Planner cast, and execution primitives—
/// there is no second deletion path.
struct DiskCleanDetailView: View {
    @ObservedObject var controller: DiskCleanController
    /// Purge segment. nil means the host did not wire it (e.g. tests that only care about the rules segment).
    @ObservedObject private var developerArtifactsController: DiskCleanController
    @ObservedObject private var installersController: DiskCleanController
    @ObservedObject private var purgeRoots: DiskCleanPurgeRootsModel
    private let localization: PluginLocalization
    private let historyProvider: (any DiskCleanCleanupHistoryProviding)?
    private let showsHeader: Bool
    private let contentPadding: CGFloat
    private let minimumContentHeight: CGFloat

    @State private var expandedCategories: Set<DiskCleanCategoryID> = []
    @State private var isScanLogExpanded = false

    init(
        controller: DiskCleanController,
        developerArtifactsController: DiskCleanController,
        installersController: DiskCleanController,
        purgeRoots: DiskCleanPurgeRootsModel,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        historyProvider: (any DiskCleanCleanupHistoryProviding)? = nil,
        showsHeader: Bool = true,
        contentPadding: CGFloat = 20,
        minimumContentHeight: CGFloat = 420
    ) {
        self.controller = controller
        self.developerArtifactsController = developerArtifactsController
        self.installersController = installersController
        self.purgeRoots = purgeRoots
        self.localization = localization
        self.historyProvider = historyProvider
        self.showsHeader = showsHeader
        self.contentPadding = contentPadding
        self.minimumContentHeight = minimumContentHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            if showsHeader {
                header
            }
            limitationsBanner
            errorBanner
            scopeSection
            categorySection
            executionResultSection
            developerArtifactsSection
            installersSection
            settingsSection
            scanLogSection
        }
        .padding(contentPadding)
        .frame(maxWidth: .infinity, minHeight: minimumContentHeight, alignment: .topLeading)
        .confirmationDialog(
            confirmationTitle,
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                controller.confirmPendingClean()
            } label: {
                Text(localization.string("detail.confirm.confirm", defaultValue: "永久删除"))
            }
            Button(role: .cancel) {
                controller.cancelPendingClean()
            } label: {
                Text(localization.string("detail.action.cancelClean", defaultValue: "取消"))
            }
        } message: {
            Text(
                localization.string(
                    "detail.confirm.message",
                    defaultValue: "永久删除不进废纸篓，无法恢复。"
                )
            )
        }
    }

    private var snapshot: DiskCleanControllerSnapshot {
        controller.snapshot
    }

    // MARK: - Page header

    private var header: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Text(localization.string("detail.title", defaultValue: "磁盘清理"))
                .font(PluginSettingsTheme.Typography.pageTitle)
            Text(snapshot.subtitle(localization: localization))
                .font(PluginSettingsTheme.Typography.pageDescription)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var limitationsBanner: some View {
        let limitations = snapshot.scanResult?.limitations ?? []
        if !limitations.isEmpty {
            DiskCleanBanner(
                symbolName: "exclamationmark.triangle.fill",
                tint: .orange,
                title: localization.string("detail.limited.title", defaultValue: "本次扫描不完整"),
                lines: limitations.map { DiskCleanFormat.limitation($0, localization: localization) }
            )
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage = snapshot.errorMessage {
            DiskCleanBanner(
                symbolName: "xmark.octagon.fill",
                tint: .red,
                title: localization.string("detail.error.title", defaultValue: "操作未完成"),
                lines: [errorMessage]
            )
        }
    }

    // MARK: - Scan scope and actions

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            DiskCleanSectionHeader(
                title: localization.string("detail.scope.title", defaultValue: "扫描范围"),
                symbolName: "line.3.horizontal.decrease.circle"
            )

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowHorizontal) {
                    ForEach(DiskCleanChoice.allCases) { choice in
                        Toggle(
                            choice.title(localization: localization),
                            isOn: Binding(
                                get: { snapshot.selectedChoices.contains(choice) },
                                set: { controller.setChoice(choice, isSelected: $0) }
                            )
                        )
                        .toggleStyle(.checkbox)
                        .disabled(snapshot.isBusy)
                    }
                    Spacer(minLength: 0)
                }

                DiskCleanActionBar(
                    snapshot: snapshot,
                    localization: localization,
                    onScan: { controller.scan() },
                    onClean: { controller.clean() },
                    onCancel: { controller.cancelCurrentOperation() }
                )
            }
            .pluginSettingsListRowPadding(interactive: true)
            .pluginSettingsCardBackground(.standard)
        }
    }

    // MARK: - Category cards

    @ViewBuilder
    private var categorySection: some View {
        let groups = DiskCleanCategoryGroup.groups(
            candidates: snapshot.scanResult?.candidates ?? [],
            selection: snapshot.selection
        )

        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            DiskCleanSectionHeader(
                title: localization.string("detail.categories.title", defaultValue: "清理项目"),
                symbolName: "square.stack.3d.up"
            )

            if groups.isEmpty {
                DiskCleanEmptyState(
                    symbolName: "internaldrive",
                    text: snapshot.scanResult == nil
                        ? localization.string("detail.categories.idle", defaultValue: "点击「扫描」查看可清理内容")
                        : localization.string("detail.candidates.empty", defaultValue: "没有发现可清理项目")
                )
            } else {
                DiskCleanCategoryListView(
                    groups: groups,
                    selection: snapshot.selection,
                    outcomesByCandidateID: outcomesByCandidateID,
                    localization: localization,
                    isInteractionEnabled: !snapshot.isBusy,
                    onToggleCandidate: { controller.setCandidateSelected($0, isSelected: $1) },
                    onToggleCategory: { controller.setCategorySelection($0, isSelected: $1) },
                    expandedCategories: $expandedCategories
                )
            }
        }
    }

    private var outcomesByCandidateID: [DiskCleanCandidate.ID: DiskCleanExecutionItemResult.Outcome] {
        guard let executionResult = snapshot.executionResult else { return [:] }
        return Dictionary(
            executionResult.itemResults.map { ($0.candidateID, $0.outcome) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Execution result

    @ViewBuilder
    private var executionResultSection: some View {
        if let executionResult = snapshot.executionResult {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                DiskCleanSectionHeader(
                    title: executionResult.wasCancelled
                        ? localization.string("detail.result.cancelledTitle", defaultValue: "已停止的清理结果")
                        : localization.string("detail.result.title", defaultValue: "清理结果"),
                    symbolName: executionResult.wasCancelled ? "stop.circle" : "checkmark.seal"
                )

                VStack(spacing: 0) {
                    // Pin attention-needed terminal statuses (design §7.5, §13-M4-6): they leave staged objects on disk;
                    // burying them under dozens of successes is the same as not saying it.
                    ForEach(executionResult.attentionResults, id: \.candidateID) { item in
                        attentionRow(item)
                        PluginSettingsListDivider()
                    }
                    summaryRow(executionResult)
                }
                .pluginSettingsCardBackground(.standard)
            }
        }
    }

    private func attentionRow(_ item: DiskCleanExecutionItemResult) -> some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(DiskCleanFormat.attentionTitle(item.outcome, localization: localization))
                    .font(PluginSettingsTheme.Typography.rowTitle)

                Text(item.path)
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if let stagedName = DiskCleanFormat.stagedName(of: item.outcome) {
                    Text(
                        localization.format(
                            "detail.result.stagedName",
                            defaultValue: "暂存名：%@",
                            stagedName
                        )
                    )
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                }

                Text(DiskCleanFormat.attentionGuidance(item.outcome, localization: localization))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .pluginSettingsListRowPadding()
    }

    private func summaryRow(_ result: DiskCleanExecutionResult) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowHorizontal) {
            metric(
                title: result.mode == .trash
                    ? localization.string("detail.result.trashed", defaultValue: "已移到废纸篓")
                    : localization.string("detail.result.removed", defaultValue: "已删除"),
                value: DiskCleanFormat.itemCount(result.removedCount, localization: localization)
            )
            metric(
                title: localization.string("detail.result.skipped", defaultValue: "已跳过"),
                value: DiskCleanFormat.itemCount(result.skippedCount, localization: localization)
            )
            metric(
                title: localization.string("detail.result.failed", defaultValue: "未完成"),
                value: DiskCleanFormat.itemCount(result.failedCount, localization: localization)
            )
            metric(
                // Trash mode must not say "reclaimed": objects are still in Trash, so space is not truly free yet (design §7.7).
                title: result.mode == .trash
                    ? localization.string("detail.result.trashedBytes", defaultValue: "已移到废纸篓")
                    : localization.string("detail.result.reclaimedBytes", defaultValue: "已释放"),
                value: DiskCleanFormat.approximateBytes(result.reclaimedBytes, localization: localization)
            )
            Spacer(minLength: 0)
        }
        .pluginSettingsListRowPadding()
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Text(title)
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(.secondary)
            Text(value)
                .font(PluginSettingsTheme.Typography.monospacedValue)
        }
        .frame(minWidth: 96, alignment: .leading)
    }

    // MARK: - P2 segments

    /// Purge sweep (design §10.1). Root management sits inside the segment—"what to scan" is a prerequisite of this segment;
    /// burying it under generic settings would make users hunt between two places.
    private var developerArtifactsSection: some View {
        DiskCleanCleanupSectionView(
            controller: developerArtifactsController,
            title: DiskCleanCategoryID.developerArtifacts.title(localization: localization),
            symbolName: DiskCleanCategoryID.developerArtifacts.symbolName,
            localization: localization
        ) {
            DiskCleanPurgeRootsView(model: purgeRoots, localization: localization)
        }
    }

    private var installersSection: some View {
        DiskCleanCleanupSectionView(
            controller: installersController,
            title: DiskCleanCategoryID.installers.title(localization: localization),
            symbolName: DiskCleanCategoryID.installers.symbolName,
            localization: localization
        )
    }

    // MARK: - Settings section

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            DiskCleanSectionHeader(
                title: localization.string("detail.settings.title", defaultValue: "清理设置"),
                symbolName: "gearshape"
            )

            VStack(spacing: 0) {
                removalModeRow
                if let historyProvider {
                    PluginSettingsListDivider()
                    DiskCleanCleanupHistorySection(
                        provider: historyProvider,
                        localization: localization
                    )
                    .pluginSettingsListRowPadding(interactive: true)
                }
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var removalModeRow: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(localization.string("detail.removalMode.title", defaultValue: "删除方式"))
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(removalModeDescription)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Picker(
                "",
                selection: Binding(
                    get: { snapshot.removalMode },
                    set: { controller.setRemovalMode($0) }
                )
            ) {
                Text(localization.string("detail.removalMode.trash", defaultValue: "废纸篓"))
                    .tag(DiskCleanRemovalMode.trash)
                Text(localization.string("detail.removalMode.permanent", defaultValue: "永久删除"))
                    .tag(DiskCleanRemovalMode.permanent)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .disabled(snapshot.isBusy)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var removalModeDescription: String {
        switch snapshot.removalMode {
        case .trash:
            return localization.string(
                "detail.removalMode.trash.description",
                defaultValue: "移到废纸篓，清空废纸篓后才真正释放空间。放回时会落在暂存名下。"
            )
        case .permanent:
            return localization.string(
                "detail.removalMode.permanent.description",
                defaultValue: "直接删除，不进废纸篓，无法恢复。执行前需要再确认一次。"
            )
        }
    }

    // MARK: - Scan log

    private var scanLogSection: some View {
        DisclosureGroup(isExpanded: $isScanLogExpanded) {
            scanLogList
                .padding(.top, PluginSettingsTheme.Spacing.sectionHeaderContent)
        } label: {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Text(localization.string("detail.scanLog.title", defaultValue: "扫描日志"))
                    .font(PluginSettingsTheme.Typography.rowTitle)
                if snapshot.phase == .scanning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
    }

    private var scanLogList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    if snapshot.scanLogEntries.isEmpty {
                        Text(localization.string("detail.scanLog.empty", defaultValue: "点击扫描后显示实时进度"))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(snapshot.scanLogEntries) { entry in
                            logRow(entry)
                                .id(entry.id)
                        }
                    }
                }
                .padding(PluginSettingsTheme.Spacing.rowVertical)
            }
            .frame(minHeight: 118, maxHeight: 160)
            .pluginSettingsCardBackground(.recessed)
            .onChange(of: snapshot.scanLogEntries.last?.id) {
                guard let id = snapshot.scanLogEntries.last?.id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func logRow(_ entry: DiskCleanScanLogEntry) -> some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Image(systemName: DiskCleanFormat.logSymbolName(entry.tone))
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(DiskCleanFormat.logTint(entry.tone))
                .frame(width: 14, height: 14)

            Text(entry.text)
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .textSelection(.enabled)
                .lineLimit(3)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Confirmation dialog

    private var confirmationTitle: String {
        DiskCleanFormat.confirmationTitle(snapshot, localization: localization)
    }

    /// Closing the dialog cancels. The confirm button first advances state to `cleaning`, so the later setter callback hits
    /// the `phase == .confirming` guard in `cancelPendingClean` and will not undo the just-submitted execution.
    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { snapshot.phase == .confirming },
            set: { isPresented in
                guard !isPresented else { return }
                controller.cancelPendingClean()
            }
        )
    }
}

// MARK: - Copy and formatting

/// Formatting shared by the detail page and the history section.
///
/// Bytes always carry "about" (estimated logical size ≠ actual free space, design §7.7); fixed-width numeric columns avoid layout jitter on refresh.
enum DiskCleanFormat {
    /// Byte-column width. Fixed width keeps "about 1.2 GB" and "about 812 KB" aligned so refreshes do not jump sideways.
    static let byteColumnWidth: CGFloat = 92

    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(PluginRuntimeLocalization.locale))
    }

    static func approximateBytes(_ value: Int64, localization: PluginLocalization) -> String {
        localization.format("detail.candidate.size", defaultValue: "约 %@", bytes(value))
    }

    static func itemCount(_ count: Int, localization: PluginLocalization) -> String {
        localization.format("item.count", defaultValue: "%d 项", count)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = PluginRuntimeLocalization.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: Action copy (shared by all three segments)

    /// Cleanup button copy. The button states what will happen: Trash is one-step, so the button itself is the last explanation (design §8.4).
    static func cleanActionTitle(
        _ snapshot: DiskCleanControllerSnapshot,
        localization: PluginLocalization
    ) -> String {
        let count = snapshot.selection.selectedCount
        guard count > 0 else {
            return snapshot.removalMode == .trash
                ? localization.string("detail.action.trash", defaultValue: "移到废纸篓")
                : localization.string("detail.action.clean", defaultValue: "清理")
        }

        let byteText = bytes(snapshot.selection.selectedEstimatedBytes)
        switch snapshot.removalMode {
        case .trash:
            return localization.format(
                "detail.action.trashSelected",
                defaultValue: "移到废纸篓 · %d 项 · 约 %@",
                count,
                byteText
            )
        case .permanent:
            return localization.format(
                "detail.action.cleanSelected",
                defaultValue: "清理 · %d 项 · 约 %@",
                count,
                byteText
            )
        }
    }

    static func selectionSummary(
        _ snapshot: DiskCleanControllerSnapshot,
        localization: PluginLocalization
    ) -> String {
        guard let result = snapshot.scanResult else {
            return localization.string("detail.selection.idle", defaultValue: "尚未扫描")
        }
        if snapshot.isResultExpired {
            return localization.string(
                "detail.selection.expired",
                defaultValue: "结果已过期，请重新扫描"
            )
        }
        if snapshot.isResultStale {
            return localization.string("detail.selection.stale", defaultValue: "清理范围已变化，请重新扫描")
        }
        return localization.format(
            "detail.selection.summary",
            defaultValue: "可清理 %d 项 · 已选 %d 项 · 约 %@",
            result.cleanableCandidates.count,
            snapshot.selection.selectedCount,
            bytes(snapshot.selection.selectedEstimatedBytes)
        )
    }

    static func confirmationTitle(
        _ snapshot: DiskCleanControllerSnapshot,
        localization: PluginLocalization
    ) -> String {
        guard let pending = snapshot.pendingPlan else {
            return localization.string("detail.confirm.fallbackTitle", defaultValue: "确认永久清理")
        }
        return localization.format(
            "detail.confirm.title",
            defaultValue: "确认永久清理 %d 项 · 约 %@",
            pending.itemCount,
            bytes(pending.totalEstimatedBytes)
        )
    }

    static func partialReasons(
        _ reasons: Set<DiskCleanScanCompleteness.PartialReason>,
        localization: PluginLocalization
    ) -> String {
        let ordered: [DiskCleanScanCompleteness.PartialReason] = [
            .timedOut, .permissionDenied, .unsupportedVolume, .crossedMountPoint, .walkError
        ]
        return ordered
            .filter(reasons.contains)
            .map { reason in
                switch reason {
                case .timedOut:
                    return localization.string("partial.timedOut", defaultValue: "超时")
                case .permissionDenied:
                    return localization.string("partial.permissionDenied", defaultValue: "权限不足")
                case .unsupportedVolume:
                    return localization.string("partial.unsupportedVolume", defaultValue: "不支持的卷")
                case .crossedMountPoint:
                    return localization.string("partial.crossedMountPoint", defaultValue: "含挂载点")
                case .walkError:
                    return localization.string("partial.walkError", defaultValue: "读取异常")
                }
            }
            .joined(separator: localization.string("list.separator", defaultValue: "、"))
    }

    /// Per-line copy for the limited-scan banner (design §4.5).
    static func limitation(
        _ limitation: DiskCleanScanLimitation,
        localization: PluginLocalization
    ) -> String {
        switch limitation {
        case let .fdaRestricted(skippedTargetIDs):
            return localization.format(
                "limitation.fdaRestricted",
                defaultValue: "未开启完全磁盘访问，已跳过 %d 项系统缓存",
                skippedTargetIDs.count
            )
        case let .dynamicRuleFailed(targetID, reason):
            return localization.format(
                "limitation.dynamicRuleFailed",
                defaultValue: "动态规则 %@ 未能运行：%@",
                targetID,
                reason
            )
        case let .targetExpansionFailed(targetID, reason):
            return localization.format(
                "limitation.targetExpansionFailed",
                defaultValue: "规则 %@ 展开失败：%@",
                targetID,
                reason
            )
        case let .volumeSkipped(path):
            return localization.format(
                "limitation.volumeSkipped",
                defaultValue: "已跳过非本地卷：%@",
                path
            )
        case let .scanRootUnreadable(path, reason):
            guard reason == .permissionDenied else {
                return localization.format(
                    "limitation.scanRootUnreadable",
                    defaultValue: "无法读取 %@（%@）",
                    path,
                    partialReasons([reason], localization: localization)
                )
            }
            return localization.format(
                "limitation.scanRootDenied",
                defaultValue: "没有访问 %@ 的权限，其中的内容未被扫描",
                path
            )
        case .walkerCircuitBroken:
            return localization.string(
                "limitation.walkerCircuitBroken",
                defaultValue: "扫描引擎已降级，本次不再计算大小，重启应用后恢复"
            )
        case let .threadsAbandoned(count):
            return localization.format(
                "limitation.threadsAbandoned",
                defaultValue: "有 %d 个扫描线程未能按时返回",
                count
            )
        }
    }

    static func stagedName(of outcome: DiskCleanExecutionItemResult.Outcome) -> String? {
        switch outcome {
        case let .trashed(_, stagedName),
             let .partiallyDeleted(stagedName, _),
             let .rollbackBlocked(stagedName, _):
            return stagedName
        case .removed, .skipped, .changedSinceScan, .failed:
            return nil
        }
    }

    static func attentionTitle(
        _ outcome: DiskCleanExecutionItemResult.Outcome,
        localization: PluginLocalization
    ) -> String {
        switch outcome {
        case .partiallyDeleted:
            return localization.string("detail.result.partiallyDeleted", defaultValue: "只删除了一部分")
        case .rollbackBlocked:
            return localization.string("detail.result.rollbackBlocked", defaultValue: "无法放回原处")
        case .removed, .trashed, .skipped, .changedSinceScan, .failed:
            return localization.string("detail.result.attention", defaultValue: "需要处理")
        }
    }

    /// Guidance must say "what the disk looks like now" and "what the user can do", not only a status name.
    static func attentionGuidance(
        _ outcome: DiskCleanExecutionItemResult.Outcome,
        localization: PluginLocalization
    ) -> String {
        switch outcome {
        case .partiallyDeleted:
            return localization.string(
                "detail.result.partiallyDeleted.guidance",
                defaultValue: "删除中途失败，暂存对象里只剩一部分内容，不会被放回原路径。可在访达中按暂存名找到并自行删除。"
            )
        case .rollbackBlocked:
            return localization.string(
                "detail.result.rollbackBlocked.guidance",
                defaultValue: "原路径已被重新创建，暂存对象未覆盖它。可在访达中按暂存名找到并自行处理。"
            )
        case let .failed(message):
            return message
        case .removed, .trashed, .skipped, .changedSinceScan:
            return ""
        }
    }

    static func logSymbolName(_ tone: DiskCleanScanLogTone) -> String {
        switch tone {
        case .info:
            return "circle"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    static func logTint(_ tone: DiskCleanScanLogTone) -> Color {
        switch tone {
        case .info:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}
