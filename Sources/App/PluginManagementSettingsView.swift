import SwiftUI
import MacToolsPluginKit

struct PluginManagementSettingsView: View {
    let pluginHost: PluginHost
    @StateObject private var presentation: PluginMarketplacePresentationModel
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    @ObservedObject var uninstallConfirmationSession: PluginUninstallConfirmationSession
    var appRelauncher: any AppRelaunching = AppRelauncher()

    @State private var alertMessage: String?
    @State private var pendingUninstallItem: PluginUninstallConfirmation?
    @State private var activeOperationID: String?
    @State private var searchText: String = ""
    @State private var selectedFilter: PluginCategoryFilter = .all
    @FocusState private var isSearchFocused: Bool
    @AppStorage(PluginMarketplaceSortMode.userDefaultsKey) private var sortMode = PluginMarketplaceSortMode.notInstalledFirst
    @State private var bulkUpdateProgressText: String?
    @State private var bulkUpdateProgressOpacity: Double = 0
    @State private var bulkUpdateProgressHideTask: Task<Void, Never>?
    @State private var activeSearchTarget: MarketplacePluginSearchTarget?
    @State private var clearSearchTargetTask: Task<Void, Never>?

    init(
        pluginHost: PluginHost,
        navigationCoordinator: SettingsNavigationCoordinator,
        uninstallConfirmationSession: PluginUninstallConfirmationSession,
        appRelauncher: any AppRelaunching = AppRelauncher()
    ) {
        self.pluginHost = pluginHost
        self.navigationCoordinator = navigationCoordinator
        self.uninstallConfirmationSession = uninstallConfirmationSession
        self.appRelauncher = appRelauncher
        _presentation = StateObject(wrappedValue: PluginMarketplacePresentationModel(host: pluginHost))
    }

    var body: some View {
        let filteredItems = filteredItems
        let configurationPluginIDs = presentation.configurationPluginIDs
        return SettingsPageScaffold {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: SettingsPageLayout.introductionContentSpacing
                    ) {
                        SettingsPageIntroduction(
                            configuration: marketplaceIntroductionConfiguration
                        ) {
                            marketplaceIntroductionActions
                        }

                        if uninstallConfirmationSession.isConfirmationPaused {
                            PluginUninstallConfirmationPausedBanner(session: uninstallConfirmationSession)
                        }

                        if presentation.items.isEmpty {
                            ContentUnavailableView(
                                AppL10n.plugins("plugin.marketplace.empty.title", defaultValue: "暂无插件"),
                                systemImage: "shippingbox",
                                description: Text(AppL10n.plugins(
                                    "plugin.marketplace.empty.description",
                                    defaultValue: "刷新插件列表后，可以在这里安装、更新和卸载。"
                                ))
                            )
                            .frame(maxWidth: .infinity, minHeight: 260)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                PluginFilterBarView(
                                    searchText: $searchText,
                                    selectedFilter: $selectedFilter,
                                    isSearchFocused: $isSearchFocused,
                                    countsByFilter: countsByFilter
                                )

                                marketplaceSortPicker
                            }

                            LazyVStack(alignment: .leading, spacing: 10) {
                                if filteredItems.isEmpty {
                                    ContentUnavailableView(
                                        AppL10n.plugins("plugin.filter.empty.title", defaultValue: "未找到匹配的插件"),
                                        systemImage: "magnifyingglass",
                                        description: Text(AppL10n.plugins("plugin.filter.empty.description", defaultValue: "尝试调整关键字或切换分类。"))
                                    )
                                    .frame(maxWidth: .infinity, minHeight: 180)
                                } else {
                                    ForEach(filteredItems) { item in
                                        PluginManagementRow(
                                            item: item,
                                            hasSettings: configurationPluginIDs.contains(item.id),
                                            isBusy: activeOperationID == item.id
                                                || presentation.automaticUpdateStatus.isUpdatingPlugin(id: item.id),
                                            isInteractionDisabled: activeOperationID != nil
                                                || presentation.automaticUpdateStatus.isActive,
                                            onInstall: { runOperation(id: item.id) { try await pluginHost.installPluginFromCatalog(pluginID: item.id) } },
                                            onUpdate: { runOperation(id: item.id) { try await pluginHost.updatePluginFromCatalog(pluginID: item.id) } },
                                            onUninstall: { requestUninstall(item) },
                                            onOpenSettings: { pluginHost.presentPluginSettings(pluginID: item.id) },
                                            onRelaunch: { appRelauncher.relaunch() },
                                            onShowDetails: {
                                                navigationCoordinator.navigate(
                                                    to: .marketplaceDetail(.init(pluginID: item.id))
                                                )
                                            }
                                        )
                                        .marketplaceSearchAnchor(
                                            target: MarketplacePluginSearchTarget(
                                                pluginID: item.id
                                            ),
                                            activeTarget: activeSearchTarget
                                        )
                                    }
                                }
                            }
                        }
                    }
                    // Reserve room inside the clipped viewport for native row
                    // focus rings, keeping the header and cards aligned.
                    .padding(.horizontal, PluginSettingsTheme.Spacing.controlCluster)
                }
                .onAppear {
                    applySearchRevealRequest(
                        navigationCoordinator.searchRevealRequest,
                        proxy: proxy
                    )
                }
                .onChange(of: navigationCoordinator.searchRevealRequest) {
                    _, request in
                    applySearchRevealRequest(request, proxy: proxy)
                }
            }
        }
        .task {
            guard !presentation.automaticUpdateStatus.isActive else {
                return
            }

            await pluginHost.refreshPluginCatalog()
        }
        .alert(
            AppL10n.plugins("plugin.marketplace.operationFailed.title", defaultValue: "插件操作失败"),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        alertMessage = nil
                    }
                }
            )
        ) {
            Button(AppL10n.settings("common.ok", defaultValue: "好"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .sheet(item: $pendingUninstallItem) { item in
            PluginUninstallConfirmationSheet(
                confirmation: item,
                session: uninstallConfirmationSession,
                onConfirm: uninstall
            )
        }
        .onAppear {
            syncAutomaticBulkUpdateProgress(presentation.automaticUpdateStatus)
            applySearchFocusRequest(navigationCoordinator.searchFocusRequest)
        }
        .onDisappear {
            navigationCoordinator.setSearchField(.pluginMarketplace, focused: false)
            clearSearchTargetTask?.cancel()
            if let activeSearchTarget {
                navigationCoordinator.clearSearchRevealRequest(
                    matching: .marketplace(activeSearchTarget)
                )
            }
            activeSearchTarget = nil
        }
        .onChange(of: navigationCoordinator.searchFocusRequest) { _, request in
            applySearchFocusRequest(request)
        }
        .onChange(of: isSearchFocused) { _, isFocused in
            navigationCoordinator.setSearchField(.pluginMarketplace, focused: isFocused)
        }
        .onChange(of: presentation.items.isEmpty) { _, isEmpty in
            if isEmpty {
                isSearchFocused = false
            }
        }
        .onChange(of: presentation.items) { _, items in
            guard
                let activeSearchTarget,
                !MarketplacePluginSearchAvailability.contains(
                    pluginID: activeSearchTarget.pluginID,
                    in: items
                )
            else {
                return
            }

            clearSearchTargetTask?.cancel()
            self.activeSearchTarget = nil
            navigationCoordinator.clearSearchRevealRequest(
                matching: .marketplace(activeSearchTarget)
            )
        }
        .onChange(of: presentation.automaticUpdateStatus) { _, status in
            syncAutomaticBulkUpdateProgress(status)
        }
    }

    private func applySearchFocusRequest(_ request: SettingsSearchFocusRequest?) {
        guard
            request?.field == .pluginMarketplace,
            !presentation.items.isEmpty,
            !isSearchFocused
        else {
            return
        }

        isSearchFocused = true
    }

    private func applySearchRevealRequest(
        _ request: SettingsSearchRevealRequest?,
        proxy: ScrollViewProxy
    ) {
        guard
            let request,
            case let .marketplace(target) = request.target
        else {
            return
        }

        guard MarketplacePluginSearchAvailability.contains(
            pluginID: target.pluginID,
            in: presentation.items
        ) else {
            navigationCoordinator.clearSearchRevealRequest(request)
            return
        }

        clearSearchTargetTask?.cancel()
        searchText = ""
        selectedFilter = .all
        activeSearchTarget = target

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target.scrollID, anchor: .center)
            }
        }

        clearSearchTargetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            activeSearchTarget = nil
            navigationCoordinator.clearSearchRevealRequest(request)
        }
    }

    private var filteredItems: [PluginManagementItem] {
        let filtered = presentation.items.filter {
            PluginListFilter.matches(managementItem: $0, query: searchText, filter: selectedFilter)
        }
        return PluginMarketplaceSortMode.sorted(filtered, by: sortMode)
    }

    private var countsByFilter: [PluginCategoryFilter: Int] {
        PluginListFilter.countsByFilter(
            managementItems: presentation.items,
            query: searchText
        )
    }

    private var marketplaceSortPicker: some View {
        let sortLabel = AppL10n.plugins("plugin.marketplace.sort.label", defaultValue: "排序")
        let sortHelp = AppL10n.plugins(
            "plugin.marketplace.sort.help",
            defaultValue: "调整市场列表排序，不影响菜单栏功能顺序。"
        )

        return HStack(spacing: 8) {
            Spacer(minLength: 0)

            Text(sortLabel)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Picker(sortLabel, selection: $sortMode) {
                ForEach(PluginMarketplaceSortMode.allCases) { mode in
                    Text(mode.displayName)
                        .tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help(sortHelp)
            .accessibilityLabel(sortLabel)
            .accessibilityValue(sortMode.displayName)
            .accessibilityHint(sortHelp)
        }
    }

    private var marketplaceIntroductionConfiguration: SettingsPageIntroductionConfiguration {
        let status = presentation.catalogStatus
        let updatedText = status.lastUpdatedAt.map {
            $0.formatted(date: .omitted, time: .shortened)
        }
        let description = [status.title, updatedText, status.detailText]
            .compactMap { $0 }
            .joined(separator: " · ")

        return SettingsPageIntroductionConfiguration(
            description: description,
            descriptionColor: status.errorMessage == nil ? .secondary : .orange
        )
    }

    @ViewBuilder
    private var marketplaceIntroductionActions: some View {
        if shouldShowBulkUpdateControls {
            bulkUpdateProgressLabel

            Button {
                runBulkUpdate()
            } label: {
                PluginManagementActionLabel(
                    title: AppL10n.plugins("plugin.marketplace.updateAll", defaultValue: "全部更新"),
                    busyTitle: AppL10n.plugins("plugin.marketplace.updating", defaultValue: "更新中"),
                    isBusy: isBulkPluginUpdateBusy,
                    width: 74
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                activeOperationID != nil
                    || !hasAvailablePluginUpdates
                    || presentation.catalogStatus.isRefreshing
                    || presentation.automaticUpdateStatus.isActive
            )
        }

        Button {
            runOperation(id: "catalog.refresh") {
                await pluginHost.refreshPluginCatalog()
            }
        } label: {
            Label(AppL10n.plugins("plugin.marketplace.refresh", defaultValue: "刷新列表"), systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(
            activeOperationID != nil
                || presentation.catalogStatus.isRefreshing
                || presentation.automaticUpdateStatus.isActive
        )
    }

    private var hasAvailablePluginUpdates: Bool {
        presentation.items.contains { $0.canUpdate }
    }

    private var shouldShowBulkUpdateControls: Bool {
        hasAvailablePluginUpdates || isBulkPluginUpdateBusy || bulkUpdateProgressText != nil
    }

    private var isBulkPluginUpdateBusy: Bool {
        activeOperationID == "catalog.updateAll"
            || presentation.automaticUpdateStatus.phase == .updating
    }

    @ViewBuilder
    private var bulkUpdateProgressLabel: some View {
        if let bulkUpdateProgressText {
            Text(bulkUpdateProgressText)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .opacity(bulkUpdateProgressOpacity)
        }
    }

    private func runOperation(id: String, _ operation: @escaping () async throws -> Void) {
        guard activeOperationID == nil,
              !presentation.automaticUpdateStatus.isActive
        else {
            return
        }

        activeOperationID = id
        hideBulkUpdateProgressText()

        Task {
            do {
                try await operation()
            } catch {
                alertMessage = error.localizedDescription
            }

            activeOperationID = nil
        }
    }

    private func runBulkUpdate() {
        guard activeOperationID == nil,
              !presentation.automaticUpdateStatus.isActive
        else {
            return
        }

        activeOperationID = "catalog.updateAll"
        bulkUpdateProgressHideTask?.cancel()
        showBulkUpdateProgressText(
            AppL10n.pluginsFormat(
                "plugin.marketplace.bulkUpdate.progressFormat",
                defaultValue: "已完成 %d/%d",
                0,
                availablePluginUpdateCount
            )
        )

        Task {
            do {
                try await pluginHost.updateAvailablePluginsFromCatalog { progress in
                    showBulkUpdateProgressText(
                        AppL10n.pluginsFormat(
                            "plugin.marketplace.bulkUpdate.progressFormat",
                            defaultValue: "已完成 %d/%d",
                            progress.completedCount,
                            progress.totalCount
                        )
                    )
                }

                activeOperationID = nil
                showBulkUpdateProgressText(
                    AppL10n.plugins("plugin.marketplace.bulkUpdate.completed", defaultValue: "更新完成")
                )
                scheduleBulkUpdateProgressFadeOut()
            } catch {
                activeOperationID = nil
                alertMessage = error.localizedDescription
                hideBulkUpdateProgressText()
            }
        }
    }

    private func showBulkUpdateProgressText(_ text: String) {
        bulkUpdateProgressHideTask?.cancel()
        bulkUpdateProgressText = text

        withAnimation(.easeOut(duration: 0.15)) {
            bulkUpdateProgressOpacity = 1
        }
    }

    private func scheduleBulkUpdateProgressFadeOut() {
        bulkUpdateProgressHideTask?.cancel()
        bulkUpdateProgressHideTask = Task {
            withAnimation(.easeOut(duration: 2)) {
                bulkUpdateProgressOpacity = 0
            }

            try? await Task.sleep(for: .seconds(2))

            guard !Task.isCancelled else {
                return
            }

            bulkUpdateProgressText = nil
        }
    }

    private func syncAutomaticBulkUpdateProgress(_ status: PluginAutomaticUpdateStatus) {
        switch status.phase {
        case .updating:
            guard !status.pluginIDs.isEmpty else {
                return
            }

            showBulkUpdateProgressText(
                status.message
                    ?? AppL10n.pluginsFormat(
                        "plugin.marketplace.bulkUpdate.progressFormat",
                        defaultValue: "已完成 %d/%d",
                        0,
                        status.pluginIDs.count
                    )
            )
        case .completed:
            guard bulkUpdateProgressText != nil, !status.pluginIDs.isEmpty else {
                return
            }

            showBulkUpdateProgressText(
                AppL10n.plugins("plugin.marketplace.bulkUpdate.completed", defaultValue: "更新完成")
            )
            scheduleBulkUpdateProgressFadeOut()
        case .failed:
            hideBulkUpdateProgressText()
        case .idle, .checking:
            break
        }
    }

    private func hideBulkUpdateProgressText() {
        bulkUpdateProgressHideTask?.cancel()

        withAnimation(.easeOut(duration: 0.2)) {
            bulkUpdateProgressOpacity = 0
        }

        bulkUpdateProgressText = nil
    }

    private func uninstall(_ confirmation: PluginUninstallConfirmation) {
        guard activeOperationID == nil else {
            return
        }

        do {
            try pluginHost.uninstallDynamicPlugin(pluginID: confirmation.pluginID)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func requestUninstall(_ item: PluginManagementItem) {
        guard item.canUninstall, activeOperationID == nil else {
            return
        }

        let confirmation = PluginUninstallConfirmation(
            pluginID: item.id,
            pluginTitle: item.title,
            surfaceCapabilitySummary: item.uninstallScopeSummary,
            removesDataOnUninstall: item.uninstallDataPolicy == .removePrivateData
        )
        if uninstallConfirmationSession.shouldConfirmUninstall(
            removesData: confirmation.removesDataOnUninstall
        ) {
            pendingUninstallItem = confirmation
        } else {
            uninstall(confirmation)
        }
    }

    private var availablePluginUpdateCount: Int {
        presentation.items.filter(\.canUpdate).count
    }
}

private struct PluginManagementRow: View {
    let item: PluginManagementItem
    let hasSettings: Bool
    let isBusy: Bool
    let isInteractionDisabled: Bool
    let onInstall: () -> Void
    let onUpdate: () -> Void
    let onUninstall: () -> Void
    let onOpenSettings: () -> Void
    let onRelaunch: () -> Void
    let onShowDetails: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            pluginIcon

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                    PluginReleaseChannelBadge(releaseChannel: item.releaseChannel)

                    Text(item.version)
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(.secondary)
                }

                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let visibleStatusText {
                Text(visibleStatusText)
                    .font(PluginSettingsTheme.Typography.secondaryLabel.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 58, alignment: .trailing)
            }

            actionButtons
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.standard)
        .contentShape(RoundedRectangle(
            cornerRadius: PluginSettingsTheme.Radius.hostCard,
            style: .continuous
        ))
        .onTapGesture(perform: onShowDetails)
        .focusable()
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(AppL10n.plugins(
            "plugin.marketplace.details.open",
            defaultValue: "查看详情"
        ))) {
            onShowDetails()
        }
        .accessibilityIdentifier("mactools.marketplace.plugin.\(item.id)")
    }

    @ViewBuilder
    private var pluginIcon: some View {
        let icon = ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(statusColor.opacity(0.14))

            Image(systemName: statusImageName)
                .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                .foregroundStyle(statusColor)
        }
        .frame(width: PluginSettingsTheme.Size.metricIcon, height: PluginSettingsTheme.Size.metricIcon)

        if hasSettings {
            Button(action: onOpenSettings) {
                icon
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help(AppL10n.pluginsFormat(
                "plugin.management.openSettingsForPlugin",
                defaultValue: "打开%@设置",
                item.title
            ))
        } else {
            icon
        }
    }

    private var detail: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.managementDetailText)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            if item.requiresRelaunchAction {
                Button(AppL10n.plugins("plugin.marketplace.relaunchNow", defaultValue: "立即重启"), action: onRelaunch)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .buttonStyle(.link)
                    .disabled(isInteractionDisabled)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if item.canInstall {
            Button(action: onInstall) {
                PluginManagementActionLabel(
                    title: AppL10n.plugins("plugin.marketplace.install", defaultValue: "安装"),
                    busyTitle: AppL10n.plugins("plugin.marketplace.installing", defaultValue: "安装中"),
                    isBusy: isBusy,
                    width: actionButtonLabelWidth
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(isInteractionDisabled)
        }

        if item.canUpdate {
            Button(action: onUpdate) {
                PluginManagementActionLabel(
                    title: AppL10n.plugins("plugin.marketplace.update", defaultValue: "更新"),
                    busyTitle: AppL10n.plugins("plugin.marketplace.updating", defaultValue: "更新中"),
                    isBusy: isBusy,
                    width: actionButtonLabelWidth
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(isInteractionDisabled)
        }

        if item.canUninstall {
            Button(role: .destructive, action: onUninstall) {
                Text(AppL10n.plugins("plugin.marketplace.uninstall", defaultValue: "卸载"))
                    .frame(width: actionButtonLabelWidth)
            }
            .buttonStyle(.bordered)
            .disabled(isInteractionDisabled)
        }
    }

    private var visibleStatusText: String? {
        switch item.state {
        case .available, .installed:
            return nil
        case .localDevelopment, .updateAvailable, .restartRequired, .failed, .incompatible, .revoked:
            return item.statusText
        }
    }

    private var actionButtonLabelWidth: CGFloat {
        64
    }

    private var statusColor: Color {
        switch item.state {
        case .available, .localDevelopment:
            return .blue
        case .installed:
            return .green
        case .updateAvailable, .restartRequired:
            return .accentColor
        case .failed, .incompatible, .revoked:
            return .orange
        }
    }

    private var statusImageName: String {
        switch item.state {
        case .available:
            return "arrow.down.circle.fill"
        case .localDevelopment:
            return "hammer.circle.fill"
        case .installed:
            return "checkmark.seal.fill"
        case .updateAvailable:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .restartRequired:
            return "restart.circle.fill"
        case .failed, .incompatible, .revoked:
            return "exclamationmark.triangle.fill"
        }
    }
}

private struct MarketplaceSearchAnchorModifier: ViewModifier {
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    let target: MarketplacePluginSearchTarget
    let activeTarget: MarketplacePluginSearchTarget?

    func body(content: Content) -> some View {
        content
            .id(target.scrollID)
            .accessibilityFocused($isAccessibilityFocused)
            .overlay {
                if activeTarget == target {
                    RoundedRectangle(
                        cornerRadius: PluginSettingsTheme.Radius.hostCard,
                        style: .continuous
                    )
                    .stroke(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onAppear {
                focusIfNeeded(activeTarget)
            }
            .onChange(of: activeTarget) { _, newValue in
                focusIfNeeded(newValue)
            }
    }

    private func focusIfNeeded(
        _ activeTarget: MarketplacePluginSearchTarget?
    ) {
        guard activeTarget == target else {
            return
        }

        isAccessibilityFocused = true
    }
}

private extension View {
    func marketplaceSearchAnchor(
        target: MarketplacePluginSearchTarget,
        activeTarget: MarketplacePluginSearchTarget?
    ) -> some View {
        modifier(
            MarketplaceSearchAnchorModifier(
                target: target,
                activeTarget: activeTarget
            )
        )
    }
}

private extension PluginManagementItem {
    var requiresRelaunchAction: Bool {
        if case .restartRequired = state {
            return true
        }

        return false
    }
}

extension PluginManagementItem {
    var uninstallScopeSummary: String {
        capabilities == nil ? "MacTools" : surfaceCapabilitySummary
    }
}

private extension PluginManagementItem {
    var surfaceCapabilitySummary: String {
        guard let capabilities else {
            return AppL10n.plugins("plugin.capability.unknown", defaultValue: "插件功能")
        }

        switch (capabilities.panelItems.contains(.widget), capabilities.panelItems.contains(.row)) {
        case (true, true):
            return AppL10n.plugins("plugin.capability.both", defaultValue: "卡片与功能行")
        case (true, false):
            return AppL10n.plugins("plugin.capability.widget", defaultValue: "卡片")
        case (false, true):
            return AppL10n.plugins("plugin.capability.row", defaultValue: "功能行")
        case (false, false):
            return AppL10n.plugins("plugin.capability.settingsOnly", defaultValue: "仅设置")
        }
    }

    var managementDetailText: String {
        [detailText, surfaceCapabilitySummary]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

private struct PluginManagementActionLabel: View {
    let title: String
    let busyTitle: String
    let isBusy: Bool
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
            }

            Text(isBusy ? busyTitle : title)
        }
        .frame(width: width)
    }
}
