import SwiftUI
import MacToolsPluginKit

struct StarterPackSettingsView: View {
    @ObservedObject var controller: StarterPackController
    @ObservedObject var host: PluginHost
    @ObservedObject var navigation: SettingsNavigationCoordinator
    let step: StarterPackStep
    var isOnboarding = false
    var onExit: (() -> Void)?
    var onRestore: (() -> Void)?
    var onOpenSettings: ((SettingsNavigationDestination) -> Void)?
    var onOpenPanel: ((String) -> Void)?

    var body: some View {
        SettingsPageScaffold {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                if isComplete {
                    completionPage
                } else {
                    switch step {
                    case .choose: setupChooser
                    case .review: setupReview
                    case .results:
                        stepIndicator
                        ScrollView { results }
                    }
                    if step != .results || controller.isRunning {
                        setupActions
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .task {
            if host.pluginCatalogStatus.lastUpdatedAt == nil, !host.pluginCatalogStatus.isRefreshing {
                await host.refreshPluginCatalog()
            }
        }
    }

    private var isComplete: Bool {
        step == .results && controller.hasResults && !controller.isRunning
            && controller.failedCount == 0 && !controller.wasStopped
            && controller.setupMessages.isEmpty
            && !controller.results.contains(where: { needsPermission($0.id) })
    }

    private var stepIndicator: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            stepLabel("选择工具", number: 1, target: .choose)
            stepConnector
            stepLabel("检查设置", number: 2, target: .review)
            stepConnector
            stepLabel("完成", number: 3, target: .results)
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .foregroundStyle(.secondary)
    }

    private func leaveSetup() {
        controller.deferOnboarding()
        exitToMarketplace()
    }

    private func exitToMarketplace() {
        if let onExit { onExit() } else { navigation.navigate(to: .plugins(.marketplace)) }
    }

    private func openSettings(_ destination: SettingsNavigationDestination) {
        if let onOpenSettings { onOpenSettings(destination) } else { navigation.navigate(to: destination) }
    }

    private var stepConnector: some View {
        Rectangle().fill(SettingsStyle.separator).frame(width: 24, height: 1)
            .accessibilityHidden(true)
    }

    private func stepLabel(_ key: String, number: Int, target: StarterPackStep) -> some View {
        let active = step == target
        let completed = target == .choose && step != .choose || target == .review && step == .results
        return HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            ZStack {
                Circle().fill(active ? Color.accentColor : SettingsStyle.recessedControlBackground)
                if completed {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                } else {
                    Text(number.formatted(.number.locale(PluginRuntimeLocalization.locale)))
                        .foregroundStyle(active ? Color.white : .secondary)
                }
            }
            .font(PluginSettingsTheme.Typography.statusBadge)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
            Text(FeatureL10n.string(key))
                .fontWeight(active ? .semibold : .regular)
                .foregroundStyle(active ? Color.primary : Color.secondary)
        }
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    @ViewBuilder
    private var catalogStatus: some View {
        if step != .results, controller.needsCatalogLoad {
            let status = host.pluginCatalogStatus
            let message = status.errorMessage ?? (status.source == .unavailable ? status.title : nil)
            HStack(alignment: .firstTextBaseline, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                if let message, !status.isRefreshing {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button(FeatureL10n.string("重试")) {
                        Task { await host.refreshPluginCatalog() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(host.automaticPluginUpdateStatus.isActive)
                    .accessibilityIdentifier("mactools.starter-packs.retry-catalog")
                    .settingsPointingHandCursor()
                } else {
                    ProgressView().controlSize(.small)
                    Text(AppL10n.plugins("plugin.catalog.detail.refreshing", defaultValue: "正在刷新插件列表..."))
                        .foregroundStyle(.secondary)
                }
            }
            .font(PluginSettingsTheme.Typography.rowDescription)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mactools.starter-packs.catalog-status")
        }
    }

    private func introduction(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Text(title).font(PluginSettingsTheme.Typography.pageTitle)
            Text(description).font(PluginSettingsTheme.Typography.pageDescription).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var packChoices: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: PluginSettingsTheme.Spacing.rowContentControl)], alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            ForEach(StarterPack.allCases) { pack in packCard(pack) }
        }
    }

    private func packCard(_ pack: StarterPack) -> some View {
        Toggle(isOn: Binding(get: { controller.selectedPacks.contains(pack) }, set: { controller.selectPack(pack, isSelected: $0) })) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                HStack(spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                    Image(systemName: PluginSystemImage.resolvedName(pack.symbol))
                        .font(PluginSettingsTheme.Typography.pageTitle)
                        .foregroundStyle(.tint)
                        .frame(width: PluginSettingsTheme.Size.metricIcon, height: PluginSettingsTheme.Size.metricIcon)
                        .background(SettingsStyle.activeControlBackground, in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(pack.title).font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(FeatureL10n.format("%d 个插件", pack.pluginIDs.count))
                            .font(PluginSettingsTheme.Typography.statusBadge).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.trailing, PluginSettingsTheme.Size.rowIcon + PluginSettingsTheme.Spacing.controlCluster)
                Text(pack.summary).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    ForEach(pack.pluginIDs, id: \.self) { id in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            pluginIcon(id)
                            Text(pluginTitle(id)).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(PluginSettingsTheme.Typography.rowDescription)
                    }
                }
                Spacer(minLength: 0)
                if controller.installedCount(in: pack) > 0 {
                    Text(FeatureL10n.format("已安装：%d / %d", controller.installedCount(in: pack), pack.pluginIDs.count))
                        .font(PluginSettingsTheme.Typography.statusBadge).foregroundStyle(.secondary)
                }
                Label(pack.permissionSummary, systemImage: "checkmark.shield")
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(SettingsSelectionToggleStyle(card: true))
        .accessibilityLabel(Text(pack.title))
        .accessibilityHint(Text(([pack.summary] + pack.pluginIDs.map(pluginTitle) + [pack.permissionSummary]).joined(separator: ". ")))
        .accessibilityIdentifier("mactools.starter-packs.\(pack.rawValue)")
        .disabled(controller.isRunning)
    }

    private var reviewSummary: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            if host.isImportingPreferences {
                Label(FeatureL10n.string("正在恢复备份，请稍后重试。"), systemImage: "info.circle")
            }
            if controller.selectedIDs.isEmpty {
                Label(FeatureL10n.string("请选择至少一个插件。"), systemImage: "info.circle")
            } else if !controller.hasChanges {
                Label(FeatureL10n.string("已完成设置，无需更改。"), systemImage: "checkmark.circle")
            } else {
                Text([
                    FeatureL10n.format("下载：%d", controller.missingIDs.count),
                    controller.pendingPanelItems.isEmpty ? nil : FeatureL10n.format("添加到面板：%d", controller.pendingPanelItems.count),
                    controller.canSeedGrid && controller.draft.seedGrid ? FeatureL10n.string("设置操作网格") : nil,
                    controller.draft.assignShortcut && !controller.hasGridShortcut ? FeatureL10n.string("设置网格快捷键") : nil
                ].compactMap { $0 }.joined(separator: " · "))
            }
        }
        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
        .accessibilityIdentifier("mactools.starter-packs.change-summary")
    }

    private var reviewConfiguration: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            VStack(spacing: 0) {
                ForEach(controller.candidateIDs, id: \.self) { id in
                    if id != controller.candidateIDs.first {
                        Divider().padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                    }
                    pluginSelectionRow(id)
                }
            }
            .pluginSettingsCardBackground(.standard)
            if controller.candidateIDs.contains("action-grid") {
                gridOptions
                    .padding(PluginSettingsTheme.Spacing.rowHorizontal)
                    .pluginSettingsCardBackground(.standard)
            }
            if !controller.selectedIDs.isEmpty {
                Label(FeatureL10n.string("权限要求"), systemImage: "checkmark.shield")
                    .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
                Text(controller.permissionIDs.isEmpty ? StarterPack.everyday.permissionSummary : controller.permissionIDs.map(permissionTitle).joined(separator: " · "))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
        }
    }

    private func permissionTitle(_ id: String) -> String {
        let titles = ["accessibility": "辅助功能", "automation": "自动化", "screen-recording": "屏幕录制",
                      "system-audio-recording": "系统音频录制", "calendarFullAccess": "日历", "full-disk-access": "完全磁盘访问权限"]
        return FeatureL10n.string(titles[id] ?? id)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            introduction(resultTitle, controller.isRunning
                ? FeatureL10n.string("可继续浏览设置，安装会在后台进行。")
                : FeatureL10n.format("已安装：%d · 未完成：%d", controller.installedCount, controller.results.count - controller.installedCount))
            if controller.isRunning {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    ProgressView().controlSize(.small)
                    Text(controller.currentPluginID.map(pluginTitle) ?? "")
                        .font(PluginSettingsTheme.Typography.rowTitle)
                }
                if controller.stopRequested {
                    Text(FeatureL10n.string("当前插件完成后将停止，其余插件不会安装。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
                Button(FeatureL10n.string("在当前插件完成后停止")) { controller.stopAfterCurrentPlugin() }
                    .disabled(controller.stopRequested)
                    .settingsPointingHandCursor()
            }
            VStack(spacing: 0) {
                ForEach(controller.results) { result in
                    if result.id != controller.results.first?.id {
                        Divider().padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                    }
                    HStack(alignment: .top) {
                        Image(systemName: resultSymbol(result.outcome))
                            .foregroundStyle(resultColor(result))
                        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                            Label { Text(pluginTitle(result.id)) } icon: { pluginIcon(result.id) }
                                .font(PluginSettingsTheme.Typography.rowTitle)
                            Text(resultDescription(result))
                                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(FeatureL10n.string("详情")) {
                            openSettings(.marketplaceDetail(.init(pluginID: result.id)))
                        }.disabled(item(result.id) == nil)
                            .settingsPointingHandCursor()
                    }
                    .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                    .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
                }
            }
            .pluginSettingsCardBackground(.standard)
            ForEach(Array(controller.setupMessages.enumerated()), id: \.offset) { _, message in
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if controller.results.contains(where: { needsPermission($0.id) }) {
                Button(FeatureL10n.string("打开权限设置")) { openSettings(.permissions) }
                    .settingsPointingHandCursor()
            }
            if !controller.isRunning {
                HStack {
                    Button(FeatureL10n.string(controller.failedCount > 0 || controller.wasStopped ? "返回检查并重试" : "检查设置…")) {
                        navigation.navigate(to: .starterPacks(.review))
                    }
                    .settingsPointingHandCursor()
                    Spacer()
                    if controller.didApplyPanelLayout, !host.panelEntries(in: controller.resultPanelID).isEmpty {
                        Button(FeatureL10n.string("打开面板")) {
                            host.menuBarPanelPresentationHandler?(controller.resultPanelID, false)
                        }
                        .settingsPointingHandCursor()
                    } else if controller.appliedPacks.contains(.windows), host.hasPluginSettings(pluginID: "action-grid") {
                        Button(FeatureL10n.string("打开操作网格设置")) { openSettings(.plugins(.configuration("action-grid"))) }
                            .settingsPointingHandCursor()
                    }
                    Button(FeatureL10n.string("完成")) {
                        controller.showsProgress = false
                        exitToMarketplace()
                    }.buttonStyle(.borderedProminent)
                        .settingsPointingHandCursor()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var resultTitle: String {
        FeatureL10n.string(controller.isRunning ? (controller.stopRequested ? "正在停止设置…" : "正在设置工具组合…")
            : controller.wasStopped ? "设置已停止"
            : controller.failedCount > 0 || !controller.setupMessages.isEmpty ? "设置需要处理"
            : controller.results.contains(where: { needsPermission($0.id) }) ? "等待授权" : "设置完成")
    }

    private func resultDescription(_ result: StarterPackResult) -> String {
        if result.outcome == .ready || result.outcome == .installed, needsPermission(result.id) {
            return FeatureL10n.string("需要授权，请打开权限设置。")
        }
        if controller.isRunning, result.id == controller.currentPluginID { return FeatureL10n.string("正在安装…") }
        return resultText(result.outcome)
    }

    private func resultColor(_ result: StarterPackResult) -> Color {
        if case .failed = result.outcome { return .orange }
        if result.outcome == .ready || result.outcome == .installed { return needsPermission(result.id) ? .orange : .green }
        return .secondary
    }

    private func item(_ id: String) -> PluginManagementItem? { host.pluginManagementItems.first { $0.id == id } }
    private func needsPermission(_ id: String) -> Bool {
        host.permissionCoordinator.items.contains { $0.affectedFeatures.contains { $0.pluginID == id && $0.status == .attention } }
    }
    private func pluginTitle(_ id: String) -> String { item(id)?.title ?? StarterPack.title(for: id) }
    private func pluginIcon(_ id: String) -> some View {
        Image(systemName: PluginSystemImage.resolvedName(StarterPack.symbol(for: id)))
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)
            .frame(width: PluginSettingsTheme.Size.rowIcon)
            .accessibilityHidden(true)
    }
    private func pluginStatus(_ id: String) -> String {
        guard let item = item(id) else { return FeatureL10n.string("等待插件列表，刷新后重试。") }
        return item.canInstall ? FeatureL10n.string("将安装") : item.statusText
    }
    private func selectionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { controller.draft.selectedPluginIDs.contains(id) }, set: { selected in
            controller.updateDraft { if selected { $0.selectedPluginIDs.insert(id) } else { $0.selectedPluginIDs.remove(id) } }
        })
    }
    private func draftBinding<Value>(_ key: WritableKeyPath<StarterPackDraft, Value>) -> Binding<Value> {
        Binding(get: { controller.draft[keyPath: key] }, set: { value in controller.updateDraft { $0[keyPath: key] = value } })
    }
    private func resultSymbol(_ outcome: StarterPackResult.Outcome) -> String {
        switch outcome { case .ready, .installed: "checkmark.circle.fill"; case .failed: "exclamationmark.triangle"; case .skipped: "minus.circle" }
    }
    private func resultText(_ outcome: StarterPackResult.Outcome) -> String {
        switch outcome {
        case .ready: FeatureL10n.string("使用现有插件，保留设置。")
        case .installed: FeatureL10n.string("已安装，可以使用。")
        case let .failed(message): message
        case .skipped: FeatureL10n.string(controller.isRunning ? "等待安装" : "已跳过")
        }
    }
}

private extension StarterPackSettingsView {
    var canOpenResultPanel: Bool {
        controller.didApplyPanelLayout && !host.panelEntries(in: controller.resultPanelID).isEmpty
    }

    func setupColumns<Header: View, Content: View>(
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let columnSpacing = PluginSettingsTheme.Spacing.section + PluginSettingsTheme.Spacing.sectionHeaderContent
        let previewWidth = StarterPackPanelPreview.preferredWidth
        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            stepIndicator
            catalogStatus
            GeometryReader { geometry in
                if geometry.size.width >= 280 + columnSpacing + previewWidth {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                        HStack(alignment: .firstTextBaseline, spacing: columnSpacing) {
                            header().frame(maxWidth: .infinity, alignment: .leading)
                            StarterPackPanelPreview.heading
                                .frame(width: previewWidth, alignment: .leading)
                        }
                        HStack(alignment: .top, spacing: columnSpacing) {
                            ScrollView {
                                content()
                                    .padding(PluginSettingsTheme.Spacing.controlCluster)
                            }
                            .padding(-PluginSettingsTheme.Spacing.controlCluster)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            StarterPackPanelPreview(controller: controller, panels: host.visibleMenuBarPanels)
                                .frame(width: previewWidth)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                            header()
                            content()
                            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                                StarterPackPanelPreview.heading
                                StarterPackPanelPreview(controller: controller, panels: host.visibleMenuBarPanels)
                            }
                            .frame(width: previewWidth)
                            .frame(maxWidth: .infinity)
                        }
                        .padding(PluginSettingsTheme.Spacing.controlCluster)
                    }
                    .padding(-PluginSettingsTheme.Spacing.controlCluster)
                }
            }
        }
    }

    var setupChooser: some View {
        setupColumns {
            introduction(FeatureL10n.string("选择适合你的工具"), FeatureL10n.string("可选择多个组合，在检查页面取消不需要的插件。"))
        } content: {
            packChoices
        }
    }

    var setupReview: some View {
        setupColumns {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                introduction(FeatureL10n.string("检查组合设置"), FeatureL10n.string("保留需要的工具，共享插件只显示一次。"))
                reviewSummary
            }
        } content: {
            reviewConfiguration
        }
        .disabled(controller.isRunning)
    }

    func pluginSelectionRow(_ id: String) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Toggle(isOn: selectionBinding(id)) {
                HStack(alignment: .firstTextBaseline, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    pluginIcon(id)
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(pluginTitle(id)).lineLimit(1)
                            .font(PluginSettingsTheme.Typography.rowTitle)
                            .help(pluginTitle(id))
                        Text(pluginStatus(id))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(SettingsSelectionToggleStyle())
            .accessibilityLabel(Text(pluginTitle(id)))
            .accessibilityIdentifier("mactools.starter-packs.plugin.\(id)")
            Button(FeatureL10n.string("详情")) { openSettings(.marketplaceDetail(.init(pluginID: id))) }
                .buttonStyle(.bordered)
                .disabled(item(id) == nil)
                .settingsPointingHandCursor()
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }

    private var gridOptions: some View {
        DisclosureGroup(FeatureL10n.string("操作网格选项")) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                if controller.canSeedGrid {
                    Toggle(FeatureL10n.string("为操作网格添加左半屏、右半屏和最大化"), isOn: draftBinding(\.seedGrid))
                        .toggleStyle(SettingsSelectionToggleStyle())
                } else {
                    Text(FeatureL10n.string("保留现有操作网格。选择窗口布局和操作网格后，可为全新网格添加常用操作。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
                if controller.draft.selectedPluginIDs.contains("action-grid"), !controller.hasGridShortcut {
                    Toggle(FeatureL10n.string("使用 ⌃⌥Space 打开操作网格"), isOn: draftBinding(\.assignShortcut))
                        .toggleStyle(SettingsSelectionToggleStyle())
                    Text(FeatureL10n.string("如快捷键已被占用，将保留原绑定并提示你重新选择。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
            }
            .padding(.top, PluginSettingsTheme.Spacing.sectionHeaderContent)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var setupActions: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            if !isOnboarding {
                Button(action: leaveSetup) {
                    Label(FeatureL10n.string("返回插件市场"), systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .settingsPointingHandCursor()
                .accessibilityIdentifier("mactools.starter-packs.marketplace")
            } else if step == .choose && controller.canResumeOnboarding {
                Menu {
                    Button(FeatureL10n.string("稍后设置"), action: leaveSetup)
                    Button(FeatureL10n.string("从空白开始")) {
                        if controller.startEmpty() { exitToMarketplace() }
                    }
                    .accessibilityIdentifier("mactools.starter-packs.start-empty")
                    Divider()
                    Button(FeatureL10n.string("恢复备份…")) { onRestore?() }
                        .disabled(host.isImportingPreferences)
                        .accessibilityIdentifier("mactools.starter-packs.restore")
                } label: {
                    Label(FeatureL10n.string("其他选项"), systemImage: "ellipsis.circle")
                }
                .disabled(controller.isRunning)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: PluginSettingsTheme.Spacing.controlCluster)
            if step == .choose {
                Text(FeatureL10n.format("已选 %d 个组合 · %d 个插件", controller.selectedPacks.count, controller.selectedIDs.count))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                Button(FeatureL10n.string("下一步")) {
                    controller.reviewSelection()
                    navigation.navigate(to: .starterPacks(.review))
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.selectedIDs.isEmpty || controller.isRunning)
                .accessibilityIdentifier("mactools.starter-packs.review")
                .keyboardShortcut(.defaultAction)
                .settingsPointingHandCursor()
            } else if step == .review {
                Button(FeatureL10n.string("上一步")) { navigation.navigate(to: .starterPacks(.choose)) }
                    .settingsPointingHandCursor()
                Button(controller.missingIDs.isEmpty ? FeatureL10n.string("应用设置") : FeatureL10n.format("安装 %d 个插件", controller.missingIDs.count)) {
                    if controller.apply() { navigation.navigate(to: .starterPacks(.results)) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canApply || host.isCatalogMutationActive || host.automaticPluginUpdateStatus.isActive)
                .accessibilityIdentifier("mactools.starter-packs.apply")
                .keyboardShortcut(.defaultAction)
                .settingsPointingHandCursor()
            } else if isOnboarding {
                Button(FeatureL10n.string("返回插件市场"), action: leaveSetup)
                    .settingsPointingHandCursor()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.top, PluginSettingsTheme.Spacing.controlCluster)
    }

    var completionPage: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            stepIndicator
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: PluginSettingsTheme.Spacing.section) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: PluginSettingsTheme.Size.pageIcon))
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        VStack(spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                            Text(FeatureL10n.string("工具已就绪"))
                                .font(PluginSettingsTheme.Typography.pageTitle)
                            Text(FeatureL10n.format("已就绪：%d 个插件", controller.installedCount))
                                .font(PluginSettingsTheme.Typography.pageDescription)
                                .foregroundStyle(.secondary)
                            Text(StarterPack.allCases.filter { controller.appliedPacks.contains($0) }.map(\.title).joined(separator: " · "))
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                        }
                        completionGuidance
                        Button(FeatureL10n.string("开始使用"), action: startUsing)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .keyboardShortcut(.defaultAction)
                            .settingsPointingHandCursor()
                            .accessibilityIdentifier("mactools.starter-packs.open-panel")
                            .padding(.top, PluginSettingsTheme.Spacing.sectionHeaderContent)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
                    .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
        }
        .accessibilityIdentifier("mactools.starter-packs.complete")
    }

    private var completionGuidance: some View {
        VStack(spacing: 0) {
            if canOpenResultPanel {
                completionGuideRow(
                    title: FeatureL10n.string("从菜单栏打开 MacTools"),
                    description: FeatureL10n.string("点击菜单栏中的 MacTools 图标，即可使用所选工具。"),
                    symbol: "menubar.rectangle"
                )
                Divider().padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            }
            completionGuideRow(
                title: FeatureL10n.string("调整插件设置"),
                description: FeatureL10n.string("在“设置”侧边栏的“插件设置”中选择插件，调整选项和快捷键。需要授权时，可在“权限”中查看指引。"),
                symbol: "slider.horizontal.3"
            )
            Divider().padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            completionGuideRow(
                title: FeatureL10n.string("更多工具，随时添加"),
                description: FeatureL10n.string("可随时在“插件市场”安装更多插件，或通过“插件组合”再次选择。"),
                symbol: "shippingbox"
            )
        }
        .multilineTextAlignment(.leading)
        .pluginSettingsCardBackground(.standard)
    }

    private func completionGuideRow(title: String, description: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: symbol)
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)
                .frame(width: PluginSettingsTheme.Size.rowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
        .accessibilityElement(children: .combine)
    }

    func startUsing() {
        controller.showsProgress = false
        if canOpenResultPanel {
            if let onOpenPanel {
                onOpenPanel(controller.resultPanelID)
            } else {
                exitToMarketplace()
                host.menuBarPanelPresentationHandler?(controller.resultPanelID, false)
            }
        } else {
            exitToMarketplace()
        }
    }
}

struct StarterPackProgressBanner: View {
    @ObservedObject var controller: StarterPackController
    @ObservedObject var navigation: SettingsNavigationCoordinator

    var body: some View {
        if controller.showsProgress, navigation.destination != .starterPacks(.results) {
            HStack {
                if controller.isRunning { ProgressView().controlSize(.small) }
                Text(FeatureL10n.string(controller.isRunning
                    ? (controller.stopRequested ? "正在停止设置…" : "正在设置工具组合…")
                    : controller.wasStopped ? "设置已停止" : "工具组合设置已结束"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                Spacer()
                Button(FeatureL10n.string("查看结果")) {
                    navigation.presentStarterPacks(.results)
                }
                    .settingsPointingHandCursor()
                if !controller.isRunning {
                    Button(FeatureL10n.string("关闭")) { controller.showsProgress = false }
                        .settingsPointingHandCursor()
                }
            }
            .controlSize(.small)
            .padding(PluginSettingsTheme.Spacing.rowHorizontal)
            .background(SettingsStyle.contentBackground)
        }
    }
}
