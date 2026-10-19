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
    @State private var showsAllPacks = false

    var body: some View {
        SettingsPageScaffold {
            if isOnboarding {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    breadcrumb
                    catalogStatus
                    switch step {
                    case .choose: onboardingChooser
                    case .review: onboardingReview
                    case .results:
                        if !controller.isRunning && controller.failedCount == 0 && !controller.wasStopped {
                            onboardingReady
                        } else {
                            ScrollView { results }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                        breadcrumb
                        catalogStatus
                        switch step {
                        case .choose: chooser
                        case .review: review
                        case .results: results
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isOnboarding { onboardingFooter } else { footer }
        }
        .controlSize(.small)
        .task {
            if isOnboarding, controller.selectedPacks.contains(where: { !StarterPack.recommendedForOnboarding.contains($0) }) {
                showsAllPacks = true
            }
            if !host.visibleMenuBarPanels.contains(where: { $0.id == controller.draft.panelID }),
               let first = host.visibleMenuBarPanels.first {
                controller.updateDraft { $0.panelID = first.id }
            }
            if host.pluginCatalogStatus.lastUpdatedAt == nil, !host.pluginCatalogStatus.isRefreshing {
                await host.refreshPluginCatalog()
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(FeatureL10n.string(controller.canResumeOnboarding && !controller.isRunning ? "稍后设置" : "返回插件市场"), action: leaveSetup)
                .settingsPointingHandCursor()
                .accessibilityIdentifier("mactools.starter-packs.marketplace")
            if step == .review {
                Button(FeatureL10n.string("返回选择")) { navigation.navigate(to: .starterPacks(.choose)) }
                    .settingsPointingHandCursor()
            }
            Spacer(minLength: 8)
            if step == .choose {
                Text(FeatureL10n.format("已选 %d 个组合 · %d 个插件", controller.selectedPacks.count, controller.selectedIDs.count))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                Button(FeatureL10n.string("检查设置…")) {
                    controller.reviewSelection()
                    navigation.navigate(to: .starterPacks(.review))
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.selectedIDs.isEmpty || controller.isRunning)
                    .accessibilityIdentifier("mactools.starter-packs.review")
                    .settingsPointingHandCursor()
            } else if step == .review {
                Button(FeatureL10n.string("应用设置")) {
                    if controller.apply() {
                        navigation.navigate(to: .starterPacks(.results))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canApply || host.isCatalogMutationActive
                    || host.automaticPluginUpdateStatus.isActive)
                .accessibilityIdentifier("mactools.starter-packs.apply")
                .settingsPointingHandCursor()
            }
        }
        .controlSize(.small)
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
        .background(SettingsStyle.contentBackground)
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            if isOnboarding {
                stepLabel("选择工具", active: step == .choose)
                Image(systemName: "chevron.right")
                stepLabel("检查设置", active: step == .review)
                Image(systemName: "chevron.right")
                stepLabel("完成", active: step == .results)
            } else {
                Button(FeatureL10n.string("插件市场"), action: leaveSetup)
                    .buttonStyle(.link)
                    .settingsPointingHandCursor()
                Image(systemName: "chevron.right")
                if step == .choose {
                    Text(FeatureL10n.string("工具组合"))
                } else {
                    Button(FeatureL10n.string("工具组合")) { navigation.navigate(to: .starterPacks(.choose)) }
                        .buttonStyle(.link)
                        .settingsPointingHandCursor()
                    Image(systemName: "chevron.right")
                    Text(FeatureL10n.string(step == .review ? "检查设置" : controller.isRunning ? "正在设置" : "完成"))
                }
            }
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

    private func stepLabel(_ key: String, active: Bool) -> some View {
        Text(FeatureL10n.string(key))
            .fontWeight(active ? .semibold : .regular)
            .foregroundStyle(active ? Color.primary : Color.secondary)
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
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            introduction(
                FeatureL10n.string(controller.needsOnboarding ? "选择适合你的工具" : "为现有设置添加工具"),
                FeatureL10n.string("可选择多个组合，在检查页面取消不需要的插件。")
            )
            HStack {
                Button(FeatureL10n.string("选择所有组合")) { controller.selectAllPacks() }
                    .settingsPointingHandCursor()
                Button(FeatureL10n.string("清除选择")) { controller.clearSelection() }
                    .settingsPointingHandCursor()
            }
            .buttonStyle(.borderless).foregroundStyle(.tint).disabled(controller.isRunning)
            ViewThatFits(in: .horizontal) {
                packChoices(columns: 3).frame(minWidth: 960)
                packChoices(columns: 2).frame(minWidth: 620)
                packChoices(columns: 1)
            }
            if controller.needsOnboarding && !isOnboarding {
                HStack {
                    Button(FeatureL10n.string("从空白开始")) {
                        if controller.startEmpty() {
                            navigation.navigate(to: .plugins(.marketplace))
                        }
                    }
                    .help(FeatureL10n.string("返回插件市场"))
                    .accessibilityIdentifier("mactools.starter-packs.start-empty")
                    .settingsPointingHandCursor()
                    Button(FeatureL10n.string("恢复备份…")) { navigation.requestPreferencesImport() }
                        .settingsPointingHandCursor()
                }
                .buttonStyle(.borderless).foregroundStyle(.tint)
                .disabled(controller.isRunning)
            }
        }
    }

    private func packChoices(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: PluginSettingsTheme.Spacing.sectionHeaderContent), count: columns), alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            ForEach(isOnboarding && !showsAllPacks ? StarterPack.recommendedForOnboarding : StarterPack.allCases) { pack in packCard(pack) }
        }
    }

    private func packCard(_ pack: StarterPack) -> some View {
        Toggle(isOn: Binding(get: { controller.selectedPacks.contains(pack) }, set: { controller.selectPack(pack, isSelected: $0) })) {
            VStack(alignment: .leading, spacing: isOnboarding ? PluginSettingsTheme.Spacing.controlCluster : PluginSettingsTheme.Spacing.sectionHeaderContent) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: PluginSystemImage.resolvedName(pack.symbol))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(pack.title).font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(FeatureL10n.format("%d 个插件", pack.pluginIDs.count))
                        .font(PluginSettingsTheme.Typography.statusBadge).foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text(pack.summary).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 5) {
                    ForEach(pack.pluginIDs, id: \.self) { id in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            pluginIcon(id)
                            Text(pluginTitle(id)).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(PluginSettingsTheme.Typography.rowDescription)
                    }
                }
                if controller.installedCount(in: pack) > 0 {
                    Text(FeatureL10n.format("已安装：%d / %d", controller.installedCount(in: pack), pack.pluginIDs.count))
                        .font(PluginSettingsTheme.Typography.statusBadge).foregroundStyle(.secondary)
                }
                Label(pack.permissionSummary, systemImage: "checkmark.shield")
                    .font(isOnboarding ? PluginSettingsTheme.Typography.statusBadge : PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(SettingsSelectionToggleStyle(card: true, cardPadding: isOnboarding ? PluginSettingsTheme.Spacing.rowContentControl : PluginSettingsTheme.Spacing.rowHorizontal))
        .accessibilityLabel(Text(pack.title))
        .accessibilityHint(Text(([pack.summary] + pack.pluginIDs.map(pluginTitle) + [pack.permissionSummary]).joined(separator: ". ")))
        .accessibilityIdentifier("mactools.starter-packs.\(pack.rawValue)")
        .disabled(controller.isRunning)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            introduction(FeatureL10n.string("检查组合设置"), FeatureL10n.string("共享插件只显示一次。仅下载缺少的插件，保留现有设置、布局和快捷键。"))
            reviewSummary
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.section) {
                    reviewConfiguration.frame(minWidth: 340, maxWidth: .infinity)
                    if showsLayoutPreview { layoutPreview.frame(width: 260) }
                }
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    reviewConfiguration
                    if showsLayoutPreview { layoutPreview }
                }
            }
        }
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
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            ForEach(controller.candidateIDs, id: \.self) { id in
                HStack {
                    Toggle(isOn: selectionBinding(id)) {
                        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                            Label { Text(pluginTitle(id)) } icon: { pluginIcon(id) }
                                .font(PluginSettingsTheme.Typography.rowTitle)
                            Text(pluginStatus(id)).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                            if !isOnboarding {
                                Text(StarterPack.allCases.filter { controller.selectedPacks.contains($0) && $0.pluginIDs.contains(id) }.map(\.title).joined(separator: " · "))
                                    .font(PluginSettingsTheme.Typography.statusBadge).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(SettingsSelectionToggleStyle())
                    .accessibilityLabel(Text(pluginTitle(id)))
                    .accessibilityIdentifier("mactools.starter-packs.plugin.\(id)")
                    Spacer(minLength: 8)
                    Button(FeatureL10n.string("详情")) { openSettings(.marketplaceDetail(.init(pluginID: id))) }
                        .disabled(item(id) == nil)
                        .settingsPointingHandCursor()
                }
                .padding(isOnboarding ? PluginSettingsTheme.Spacing.rowVertical : PluginSettingsTheme.Spacing.rowHorizontal)
                .pluginSettingsCardBackground(.standard)
            }
            if !controller.recommendedPanelItems.isEmpty {
                Toggle(FeatureL10n.string("将所选工具添加到面板"), isOn: draftBinding(\.addToPanel))
                    .toggleStyle(SettingsSelectionToggleStyle())
                if controller.draft.addToPanel {
                    Picker(FeatureL10n.string("目标面板"), selection: draftBinding(\.panelID)) {
                        ForEach(host.visibleMenuBarPanels) { panel in Text(panel.title).tag(panel.id) }
                    }
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
                    Text(FeatureL10n.string("已在任意面板中的工具将保留原位置，不会重复添加。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
            }
            if controller.candidateIDs.contains("action-grid") {
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
            if !controller.selectedIDs.isEmpty {
                Text(FeatureL10n.string("权限要求"))
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

    private var showsLayoutPreview: Bool {
        (controller.draft.addToPanel && !controller.pendingPanelItems.isEmpty) || controller.candidateIDs.contains("action-grid")
    }

    private var layoutPreview: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(FeatureL10n.string("布局更改"), systemImage: "rectangle.3.group")
                .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
            if controller.draft.addToPanel {
                ForEach(controller.pendingPanelItems, id: \.self) { item in
                    Label { Text(pluginTitle(item.pluginID)) } icon: { pluginIcon(item.pluginID) }
                        .font(PluginSettingsTheme.Typography.rowDescription)
                }
            }
            if controller.canSeedGrid && controller.draft.seedGrid {
                StarterPackGridPreview(items: ["左半屏", "右半屏", "最大化"].enumerated().map {
                    .init(slot: $0.offset, title: FeatureL10n.string($0.element), symbol: ["rectangle.lefthalf.filled", "rectangle.righthalf.filled", "rectangle.inset.filled"][$0.offset])
                })
            } else if controller.candidateIDs.contains("action-grid") {
                Text(FeatureL10n.string("现有网格和快捷键保持不变。"))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
        }
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
        .pluginSettingsCardBackground(.standard)
    }
    private var results: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            introduction(resultTitle, controller.isRunning
                ? FeatureL10n.string("可继续浏览设置，安装会在后台进行。")
                : FeatureL10n.format("已安装：%d · 未完成：%d", controller.installedCount, controller.results.count - controller.installedCount))
            if controller.isRunning {
                ProgressView().controlSize(.small)
                Text(controller.currentPluginID.map(pluginTitle) ?? "")
                if controller.stopRequested {
                    Text(FeatureL10n.string("当前插件完成后将停止，其余插件不会安装。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
                Button(FeatureL10n.string("在当前插件完成后停止")) { controller.stopAfterCurrentPlugin() }
                    .disabled(controller.stopRequested)
                    .settingsPointingHandCursor()
            }
            ForEach(controller.results) { result in
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
            }
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

    func onboardingColumns<Content: View>(showsAppliedSelection: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.section + PluginSettingsTheme.Spacing.sectionHeaderContent) {
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            StarterPackPanelPreview(controller: controller, panels: host.visibleMenuBarPanels, showsAppliedSelection: showsAppliedSelection)
                .frame(width: StarterPackPanelPreview.preferredWidth)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var onboardingChooser: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            introduction(FeatureL10n.string("选择适合你的工具"), FeatureL10n.string("可选择多个组合，在检查页面取消不需要的插件。"))
            onboardingColumns {
                ScrollView {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                        packChoices(columns: 2)
                        Button(FeatureL10n.string(showsAllPacks ? "显示推荐组合" : "浏览全部七个组合")) { showsAllPacks.toggle() }
                            .buttonStyle(.link).settingsPointingHandCursor()
                    }
                    .padding(.trailing, PluginSettingsTheme.Stroke.standard)
                }
            }
        }
    }

    var onboardingReview: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            introduction(FeatureL10n.string("检查组合设置"), FeatureL10n.string("保留需要的工具，共享插件只显示一次。"))
            onboardingColumns {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                    reviewSummary
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(controller.candidateIDs, id: \.self) { id in
                                if id != controller.candidateIDs.first { Divider() }
                                onboardingPluginRow(id)
                            }
                        }
                    }
                    .frame(minHeight: 72, maxHeight: min(CGFloat(controller.candidateIDs.count) * 36, 360))
                    .pluginSettingsCardBackground(.standard)
                    .layoutPriority(-1)
                    onboardingPanelOptions
                    if !controller.selectedIDs.isEmpty {
                        Label(controller.permissionIDs.isEmpty ? StarterPack.everyday.permissionSummary : controller.permissionIDs.map(permissionTitle).joined(separator: " · "), systemImage: "checkmark.shield")
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .disabled(controller.isRunning)
    }

    func onboardingPluginRow(_ id: String) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Toggle(isOn: selectionBinding(id)) {
                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    Label { Text(pluginTitle(id)).lineLimit(1) } icon: { pluginIcon(id) }
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .help(pluginTitle(id))
                    if item(id)?.canInstall != true {
                        Text(pluginStatus(id))
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .toggleStyle(SettingsSelectionToggleStyle())
            .accessibilityLabel(Text(pluginTitle(id)))
            .accessibilityIdentifier("mactools.starter-packs.plugin.\(id)")
            Button(FeatureL10n.string("详情")) { openSettings(.marketplaceDetail(.init(pluginID: id))) }
                .buttonStyle(.link)
                .disabled(item(id) == nil)
                .settingsPointingHandCursor()
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.controlCluster)
    }

    var onboardingPanelOptions: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            if !controller.recommendedPanelItems.isEmpty {
                Label(FeatureL10n.string("面板设置"), systemImage: "rectangle.topthird.inset.filled")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Toggle(FeatureL10n.string("将所选工具添加到面板"), isOn: draftBinding(\.addToPanel))
                    .toggleStyle(SettingsSelectionToggleStyle())
                if controller.draft.addToPanel {
                    Picker(FeatureL10n.string("目标面板"), selection: draftBinding(\.panelID)) {
                        ForEach(host.visibleMenuBarPanels) { panel in Text(panel.title).tag(panel.id) }
                    }
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
                }
            }
            if controller.candidateIDs.contains("action-grid") {
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
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var onboardingFooter: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            if step == .choose {
                Button(FeatureL10n.string("稍后设置"), action: leaveSetup)
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .settingsPointingHandCursor()
                Button(FeatureL10n.string("从空白开始")) {
                    if controller.startEmpty() { exitToMarketplace() }
                }
                .disabled(controller.isRunning)
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .accessibilityIdentifier("mactools.starter-packs.start-empty")
                .settingsPointingHandCursor()
                Button(FeatureL10n.string("恢复备份…")) { onRestore?() }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .disabled(controller.isRunning || host.isImportingPreferences)
                    .accessibilityIdentifier("mactools.starter-packs.restore")
                    .settingsPointingHandCursor()
            } else if step == .review {
                Button(FeatureL10n.string("返回选择")) { navigation.navigate(to: .starterPacks(.choose)) }
                    .settingsPointingHandCursor()
                Button(FeatureL10n.string("稍后设置"), action: leaveSetup)
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .settingsPointingHandCursor()
            } else if !controller.isRunning && controller.failedCount == 0 && !controller.wasStopped {
                Button(FeatureL10n.string("编辑选择")) { navigation.navigate(to: .starterPacks(.review)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .settingsPointingHandCursor()
            }
            Spacer(minLength: 8)
            if step == .choose {
                Text(FeatureL10n.format("已选 %d 个组合 · %d 个插件", controller.selectedPacks.count, controller.selectedIDs.count))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                Button(FeatureL10n.string("检查设置…")) {
                    controller.reviewSelection()
                    navigation.navigate(to: .starterPacks(.review))
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.selectedIDs.isEmpty || controller.isRunning)
                .accessibilityIdentifier("mactools.starter-packs.review")
                .settingsPointingHandCursor()
            } else if step == .review {
                Button(controller.missingIDs.isEmpty ? FeatureL10n.string("应用设置") : FeatureL10n.format("安装 %d 个插件", controller.missingIDs.count)) {
                    if controller.apply() { navigation.navigate(to: .starterPacks(.results)) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canApply || host.isCatalogMutationActive || host.automaticPluginUpdateStatus.isActive)
                .accessibilityIdentifier("mactools.starter-packs.apply")
                .settingsPointingHandCursor()
            } else if !controller.isRunning && controller.failedCount == 0 && !controller.wasStopped {
                if canOpenResultPanel {
                    Button(FeatureL10n.string("浏览插件市场")) {
                        controller.showsProgress = false
                        exitToMarketplace()
                    }
                    .settingsPointingHandCursor()
                }
                Button(FeatureL10n.string(canOpenResultPanel ? "打开面板" : "打开插件市场")) {
                    controller.showsProgress = false
                    if canOpenResultPanel {
                        if let onOpenPanel { onOpenPanel(controller.resultPanelID) }
                        else { host.menuBarPanelPresentationHandler?(controller.resultPanelID, false) }
                    } else { exitToMarketplace() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("mactools.starter-packs.open-panel")
                .settingsPointingHandCursor()
            } else {
                Button(FeatureL10n.string("返回插件市场"), action: leaveSetup)
                    .settingsPointingHandCursor()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
        .background(SettingsStyle.contentBackground)
        .overlay(alignment: .top) { Divider() }
    }

    var onboardingReady: some View {
        onboardingColumns(showsAppliedSelection: true) {
            ScrollView {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    Label {
                        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                            Text(FeatureL10n.string("工具已就绪"))
                                .font(PluginSettingsTheme.Typography.pageTitle)
                            Text(FeatureL10n.format("已就绪：%d 个插件", controller.installedCount))
                                .font(PluginSettingsTheme.Typography.pageDescription).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .font(PluginSettingsTheme.Typography.pageTitle).foregroundStyle(.green)
                    }
                    ForEach(StarterPack.allCases.filter { controller.appliedPacks.contains($0) }) { pack in
                        HStack {
                            Image(systemName: PluginSystemImage.resolvedName(pack.symbol)).foregroundStyle(.tint)
                            Text(pack.title).font(PluginSettingsTheme.Typography.rowTitle)
                            Image(systemName: "checkmark").foregroundStyle(.green)
                            Spacer(minLength: 0)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                        Text(FeatureL10n.string(canOpenResultPanel ? "从菜单栏打开 MacTools" : "插件市场"))
                            .font(PluginSettingsTheme.Typography.sectionTitle)
                        Text(FeatureL10n.string(canOpenResultPanel
                            ? "点击菜单栏中的 MacTools 图标，即可使用所选工具。"
                            : "可在插件市场查看已安装的插件并打开设置。"))
                            .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                        Text(FeatureL10n.string("更多工具，随时添加"))
                            .font(PluginSettingsTheme.Typography.sectionTitle)
                        Text(FeatureL10n.string("可随时在插件市场安装更多插件，或选择全部七个工具组合。"))
                            .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                        Text(FeatureL10n.string("设置 → 插件市场 → 工具组合"))
                            .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    }
                    ForEach(Array(controller.setupMessages.enumerated()), id: \.offset) { _, message in
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if controller.results.contains(where: { needsPermission($0.id) }) {
                        Button(FeatureL10n.string("打开权限设置")) { openSettings(.permissions) }
                            .settingsPointingHandCursor()
                    }
                }
                .padding(.vertical, PluginSettingsTheme.Spacing.section)
            }
        }
    }
}

private struct StarterPackGridPreview: View {
    let items: [StarterPackGridPreviewItem]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(0..<9) { slot in
                let item = items.first { $0.slot == slot }
                VStack(spacing: 6) {
                    Image(systemName: PluginSystemImage.resolvedName(item?.symbol ?? "plus"))
                    Text(item?.title ?? " ")
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .lineLimit(2)
                }
                .foregroundStyle(item == nil ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 66)
                .padding(4)
                .pluginSettingsCardBackground(.recessed)
                .help(item?.title ?? "")
            }
        }
        .accessibilityElement(children: .combine)
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
