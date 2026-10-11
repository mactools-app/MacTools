import SwiftUI
import MacToolsPluginKit

@MainActor
final class HomebrewSettingsSearchFocusController: ObservableObject {
    @Published private(set) var requestID: UInt = 0

    func requestFocus() {
        requestID &+= 1
    }
}

struct HomebrewDetailView: View {
    private enum SearchField {
        case installed
        case online
    }

    @ObservedObject var controller: HomebrewController
    @ObservedObject var searchFocusController: HomebrewSettingsSearchFocusController
    private let localization: PluginLocalization
    private let showsHeader: Bool
    private let contentPadding: CGFloat
    private let minimumContentHeight: CGFloat
    
    @State private var activeTab: BrewTabSection = .installed
    @State private var installedFilter: BrewPackageFilter = .all
    @State private var localSearchText = ""
    @State private var onlineSearchText = ""
    @State private var newTapName = ""
    
    @State private var selectedInstalledPkg: BrewPackage?
    @State private var selectedSearchPkg: BrewPackage?
    @State private var onlinePackageDetail: BrewPackage?
    @State private var isFetchingOnlineDetail = false
    @State private var customBrewPath = ""
    @State private var pendingAction: HomebrewPendingAction?
    @State private var didRequestInitialScan = false
    @FocusState private var focusedSearchField: SearchField?
    
    enum BrewTabSection: String, CaseIterable, Identifiable {
        case installed
        case search
        case taps
        case diagnostics
        
        var id: String { rawValue }
        
        func title(localization: PluginLocalization) -> String {
            switch self {
            case .installed: return localization.string("detail.tabs.installed", defaultValue: "已安装")
            case .search: return localization.string("detail.tabs.search", defaultValue: "搜索")
            case .taps: return localization.string("detail.tabs.taps", defaultValue: "软件源")
            case .diagnostics: return localization.string("detail.tabs.diagnostics", defaultValue: "诊断")
            }
        }
        
        var icon: String {
            switch self {
            case .installed: return "shippingbox.fill"
            case .search: return "magnifyingglass"
            case .taps: return "square.stack.3d.up.fill"
            case .diagnostics: return "wrench.and.screwdriver.fill"
            }
        }
    }
    
    enum BrewPackageFilter: String, CaseIterable, Identifiable {
        case all
        case formula
        case cask
        
        var id: String { rawValue }
        
        func title(localization: PluginLocalization) -> String {
            switch self {
            case .all: return localization.string("detail.filter.all", defaultValue: "全部")
            case .formula: return localization.string("detail.filter.formula", defaultValue: "Formula")
            case .cask: return localization.string("detail.filter.cask", defaultValue: "Cask")
            }
        }
    }
    
    init(
        controller: HomebrewController,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        showsHeader: Bool = true,
        contentPadding: CGFloat = 16,
        minimumContentHeight: CGFloat = 450,
        searchFocusController: HomebrewSettingsSearchFocusController = .init()
    ) {
        self.controller = controller
        self.localization = localization
        self.showsHeader = showsHeader
        self.contentPadding = contentPadding
        self.minimumContentHeight = minimumContentHeight
        self.searchFocusController = searchFocusController
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                    .padding(.horizontal, contentPadding)
                    .padding(.top, contentPadding)
            }
            
            if !controller.isBrewAvailable {
                pathNotFoundView
            } else {
                VStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                    tabBar
                    statusSummaryBar
                }
                .padding(.horizontal, contentPadding)
                .padding(.vertical, PluginSettingsTheme.Spacing.sectionHeaderContent)
                
                Divider()
                
                // Main Content Area
                GeometryReader { _ in
                    VStack(spacing: 0) {
                        Group {
                            switch activeTab {
                            case .installed:
                                installedTabContent
                            case .search:
                                searchTabContent
                            case .taps:
                                tapsTabContent
                            case .diagnostics:
                                diagnosticsTabContent
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        
                        // Console Output Drawer
                        if !controller.logs.isEmpty {
                            consoleDrawer
                                .frame(height: 140)
                                .transition(.move(edge: .bottom))
                        }
                    }
                }
            }
        }
        .onChange(of: searchFocusController.requestID) {
            if activeTab != .installed && activeTab != .search {
                activeTab = .installed
            }
            DispatchQueue.main.async {
                focusedSearchField = activeTab == .search ? .online : .installed
            }
        }
        .frame(minHeight: minimumContentHeight)
        .onAppear {
            customBrewPath = controller.brewPath
            requestInitialScanIfNeeded()
        }
        .onChange(of: controller.brewPath) { _, newPath in
            customBrewPath = newPath
        }
        .onChange(of: controller.isBrewAvailable) { _, _ in
            requestInitialScanIfNeeded()
        }
        .onChange(of: controller.isBusy) { _, isBusy in
            if !isBusy {
                requestInitialScanIfNeeded()
            }
        }
        .confirmationDialog(
            pendingAction?.title(localization: localization)
                ?? localization.string("detail.confirm.defaultTitle", defaultValue: "确认操作"),
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingAction {
                Button(pendingAction.buttonTitle(localization: localization), role: pendingAction.role) {
                    perform(pendingAction)
                    self.pendingAction = nil
                }
            }
            Button(localization.string("detail.confirm.cancel", defaultValue: "取消"), role: .cancel) {
                pendingAction = nil
            }
        } message: {
            if let pendingAction {
                Text(pendingAction.message(localization: localization))
            }
        }
    }
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(localization.string("detail.title", defaultValue: "Homebrew Manager"))
                    .font(PluginSettingsTheme.Typography.pageTitle)
                Text(localization.string("detail.subtitle", defaultValue: "Manage Homebrew packages, applications, and repositories visually"))
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            
            if controller.isBusy {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(controller.currentOperationName)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .pluginSettingsCardBackground(.recessed)
            }
        }
    }
    
    private var tabBar: some View {
        HStack {
            Spacer(minLength: 0)
            Picker(localization.string("detail.tabs.picker", defaultValue: "视图"), selection: $activeTab) {
                ForEach(BrewTabSection.allCases) { section in
                    Label(section.title(localization: localization), systemImage: section.icon)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .labelsHidden()
            .frame(minWidth: 500, idealWidth: 560, maxWidth: 620)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusSummaryBar: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            statusMetric(
                title: localization.string("detail.status.installed", defaultValue: "已安装"),
                value: "\(controller.installedPackages.count)",
                systemImage: "shippingbox.fill",
                color: Color(nsColor: .secondaryLabelColor)
            )
            statusMetric(
                title: localization.string("detail.status.outdated", defaultValue: "可更新"),
                value: "\(controller.outdatedPackages.count)",
                systemImage: "arrow.up.circle.fill",
                color: controller.outdatedPackages.isEmpty
                    ? Color(nsColor: .secondaryLabelColor)
                    : .orange
            )

            Spacer(minLength: 12)

            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Image(systemName: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(controller.brewPath.isEmpty
                     ? localization.string("detail.status.brewPathMissing", defaultValue: "未配置 brew")
                     : controller.brewPath)
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 160, maxWidth: 360, alignment: .trailing)
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .pluginSettingsCardBackground(.recessed)
    }

    private func statusMetric(
        title: String,
        value: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Image(systemName: PluginSystemImage.resolvedName(systemImage))
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(title)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            Text(value)
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .foregroundStyle(.primary)
        }
    }

    private func refreshButton(title: String) -> some View {
        Button {
            controller.scanAll()
        } label: {
            Label(title, systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!controller.isBrewAvailable || controller.isBusy)
        .help(localization.string("detail.refresh.help", defaultValue: "刷新 Homebrew 状态"))
    }

    private func sectionHeader(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }
    
    // MARK: - Tab Contents
    
    private var installedTabContent: some View {
        let filtered = filteredInstalledPackages

        return HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            VStack(spacing: 0) {
                installedToolbar
                PluginSettingsListDivider(leadingInset: 0, trailingInset: 0)

                if filtered.isEmpty {
                    installedEmptyState
                } else {
                    installedPackageList(filtered)
                }
            }
            .pluginSettingsCardBackground(.standard)
            .frame(width: 340)
            .frame(maxHeight: .infinity)

            installedDetailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, PluginSettingsTheme.Spacing.sectionHeaderContent)
        .padding(.horizontal, contentPadding)
        .padding(.bottom, contentPadding)
    }

    private var filteredInstalledPackages: [BrewPackage] {
        controller.installedPackages.filter { pkg in
            let matchesText = localSearchText.isEmpty
                || pkg.name.localizedCaseInsensitiveContains(localSearchText)
                || pkg.desc.localizedCaseInsensitiveContains(localSearchText)
            let matchesFilter = installedFilter == .all
                || (installedFilter == .formula && !pkg.isCask)
                || (installedFilter == .cask && pkg.isCask)
            return matchesText && matchesFilter
        }
    }

    private var installedToolbar: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            TextField(localization.string("detail.search.placeholder", defaultValue: "搜索已安装包"), text: $localSearchText)
                .focused($focusedSearchField, equals: .installed)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            Picker("", selection: $installedFilter) {
                ForEach(BrewPackageFilter.allCases) { filter in
                    Text(filter.title(localization: localization)).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 96)

            refreshButton(title: localization.string("detail.refresh.button", defaultValue: "刷新"))
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func installedPackageList(_ packages: [BrewPackage]) -> some View {
        List(packages, selection: $selectedInstalledPkg) { pkg in
            installedPackageRow(pkg)
                .tag(pkg)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func installedPackageRow(_ pkg: BrewPackage) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: pkg.isCask ? "macwindow" : "terminal")
                .pluginSettingsRowIconStyle(pkg.isCask ? Color.blue : Color.green)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(pkg.name)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    .lineLimit(1)
                if !pkg.desc.isEmpty {
                    Text(pkg.desc)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            if pkg.isOutdated {
                Text(localization.string("detail.search.hasUpdate", defaultValue: "可更新"))
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }

            Text(pkg.version)
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }

    private var installedDetailPane: some View {
        Group {
            if let pkg = selectedInstalledPkg {
                packageDetailView(for: pkg)
            } else {
                emptyState(
                    icon: "info.circle",
                    title: localization.string("detail.detail.selectionHint", defaultValue: "选择一个包查看详情")
                )
                .pluginSettingsCardBackground(.standard)
            }
        }
    }

    private var installedEmptyState: some View {
        let isUnfiltered = localSearchText.isEmpty && installedFilter == .all

        return emptyState(
            icon: controller.isBusy ? "arrow.clockwise" : "shippingbox",
            title: controller.isBusy
                ? localization.string("detail.search.loadingInstalled", defaultValue: "正在加载 Homebrew 状态")
                : (isUnfiltered
                   ? localization.string("detail.search.notLoaded", defaultValue: "尚未加载已安装包")
                   : localization.string("detail.search.noMatch", defaultValue: "没有匹配的已安装包"))
        )
    }

    private var searchTabContent: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            VStack(spacing: 0) {
                searchToolbar
                PluginSettingsListDivider(leadingInset: 0, trailingInset: 0)
                searchResultsContent
            }
            .pluginSettingsCardBackground(.standard)
            .frame(width: 340)
            .frame(maxHeight: .infinity)

            searchDetailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, PluginSettingsTheme.Spacing.sectionHeaderContent)
        .padding(.horizontal, contentPadding)
        .padding(.bottom, contentPadding)
    }

    private var searchToolbar: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            TextField(localization.string("detail.search.onlinePlaceholder", defaultValue: "搜索软件包"), text: $onlineSearchText)
                .focused($focusedSearchField, equals: .online)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit {
                    runOnlineSearch()
                }

            Button {
                runOnlineSearch()
            } label: {
                Label(localization.string("detail.search.button", defaultValue: "搜索"), systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(onlineSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isSearching)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    @ViewBuilder
    private var searchResultsContent: some View {
        if controller.isSearching {
            emptyState(icon: "arrow.clockwise", title: localization.string("detail.search.searching", defaultValue: "正在搜索 Homebrew"))
        } else if controller.searchResults.isEmpty {
            emptyState(icon: "magnifyingglass", title: localization.string("detail.search.empty", defaultValue: "输入关键词搜索软件包"))
        } else {
            List(controller.searchResults, selection: $selectedSearchPkg) { pkg in
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Image(systemName: pkg.isCask ? "macwindow" : "terminal")
                        .pluginSettingsRowIconStyle(pkg.isCask ? Color.blue : Color.green)
                    Text(pkg.name)
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .lineLimit(1)
                    Spacer()
                    Text(pkg.isCask
                         ? localization.string("detail.filter.cask", defaultValue: "Cask")
                         : localization.string("detail.filter.formula", defaultValue: "Formula"))
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(.secondary)
                }
                .tag(pkg)
                .padding(.vertical, 3)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: selectedSearchPkg) { _, newPkg in
                if let pkg = newPkg {
                    fetchOnlinePackageDetail(pkg)
                }
            }
        }
    }

    @ViewBuilder
    private var searchDetailPane: some View {
        if isFetchingOnlineDetail {
            emptyState(icon: "arrow.clockwise", title: localization.string("detail.search.fetchingDetail", defaultValue: "正在加载包详情"))
                .pluginSettingsCardBackground(.standard)
        } else if let pkg = onlinePackageDetail {
            onlinePackageDetailView(for: pkg)
        } else {
            emptyState(icon: "plus.circle", title: localization.string("detail.detail.onlineHint", defaultValue: "选择搜索结果后安装"))
                .pluginSettingsCardBackground(.standard)
        }
    }
    
    private var tapsTabContent: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                sectionHeader(title: localization.string("detail.taps.titleAdd", defaultValue: "添加软件源"), icon: "plus.circle")

                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    TextField(localization.string("detail.taps.placeholderAdd", defaultValue: "user/repo 或仓库 URL"), text: $newTapName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)

                    Button {
                        let trimmed = newTapName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        pendingAction = .tap(trimmed)
                    } label: {
                        Label(localization.string("detail.taps.buttonAdd", defaultValue: "添加"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newTapName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isBusy)
                }
                .pluginSettingsListRowPadding(interactive: true)
                .pluginSettingsCardBackground(.standard)
            }

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                sectionHeader(
                    title: localization.format("detail.taps.titleList", defaultValue: "已启用软件源（%d）", controller.taps.count),
                    icon: "square.stack.3d.up"
                )
                tapListCard
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, PluginSettingsTheme.Spacing.sectionHeaderContent)
        .padding(.horizontal, contentPadding)
        .padding(.bottom, contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var tapListCard: some View {
        VStack(spacing: 0) {
            if controller.taps.isEmpty {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Image(systemName: "square.stack.3d.up")
                        .pluginSettingsRowIconStyle()
                    Text(localization.string("detail.taps.empty", defaultValue: "暂无软件源"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .pluginSettingsListRowPadding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(controller.taps) { tap in
                            tapRow(tap)
                            if tap.id != controller.taps.last?.id {
                                PluginSettingsListDivider()
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pluginSettingsCardBackground(.standard)
    }

    private func tapRow(_ tap: BrewTap) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: "square.stack.3d.up")
                .pluginSettingsRowIconStyle()
            Text(tap.name)
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Button(role: .destructive) {
                pendingAction = .untap(tap)
            } label: {
                Label(localization.string("detail.taps.buttonUntap", defaultValue: "移除"), systemImage: "minus.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(controller.isBusy)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var diagnosticsTabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                    sectionHeader(title: localization.string("detail.diagnostics.pathTitle", defaultValue: "brew 路径"), icon: "terminal")

                    HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                        TextField(localization.string("detail.diagnostics.pathPlaceholder", defaultValue: "例如 /opt/homebrew/bin/brew"), text: $customBrewPath)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)

                        Button {
                            controller.updateCustomPath(customBrewPath)
                        } label: {
                            Label(localization.string("detail.diagnostics.pathApply", defaultValue: "应用"), systemImage: "checkmark")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(customBrewPath == controller.brewPath || customBrewPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .pluginSettingsListRowPadding(interactive: true)
                    .pluginSettingsCardBackground(.standard)
                }

                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                    sectionHeader(title: localization.string("detail.diagnostics.maintenance.title", defaultValue: "维护操作"), icon: "wrench.and.screwdriver")

                    VStack(spacing: 0) {
                        diagnosticRow(
                            title: localization.string("detail.diagnostics.update.title", defaultValue: "更新软件源"),
                            description: localization.string("detail.diagnostics.update.desc", defaultValue: "同步 Homebrew formula 和 cask 列表。"),
                            icon: "arrow.clockwise.circle.fill",
                            color: .blue,
                            action: { controller.updateBrew() }
                        )
                        PluginSettingsListDivider()
                        diagnosticRow(
                            title: localization.string("detail.diagnostics.upgrade.title", defaultValue: "更新所有包"),
                            description: localization.string("detail.diagnostics.upgrade.desc", defaultValue: "更新当前检测到的过期包。"),
                            icon: "arrow.up.circle.fill",
                            color: .orange,
                            action: { pendingAction = .upgradeAll }
                        )
                        PluginSettingsListDivider()
                        diagnosticRow(
                            title: localization.string("detail.diagnostics.doctor.title", defaultValue: "运行诊断"),
                            description: localization.string("detail.diagnostics.doctor.desc", defaultValue: "检查环境变量、权限和构建路径。"),
                            icon: "heart.text.square.fill",
                            color: .green,
                            action: { controller.runDoctor() }
                        )
                        PluginSettingsListDivider()
                        diagnosticRow(
                            title: localization.string("detail.diagnostics.cleanup.title", defaultValue: "清理缓存"),
                            description: localization.string("detail.diagnostics.cleanup.desc", defaultValue: "移除旧版本下载和缓存。"),
                            icon: "trash.circle.fill",
                            color: .red,
                            action: { pendingAction = .cleanup }
                        )
                    }
                    .pluginSettingsCardBackground(.standard)
                }
            }
            .padding(.top, PluginSettingsTheme.Spacing.sectionHeaderContent)
            .padding(.bottom, contentPadding)
        }
        .padding(.horizontal, contentPadding)
    }

    private var pathNotFoundView: some View {
        VStack(spacing: PluginSettingsTheme.Spacing.section) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: PluginSettingsTheme.Size.pageIcon))
                .foregroundStyle(.orange)
            
            Text(localization.string("detail.diagnostics.pathNotFoundTitle", defaultValue: "未检测到 Homebrew"))
                .font(PluginSettingsTheme.Typography.pageTitle)
            
            Text(localization.string("detail.diagnostics.pathNotFoundDesc", defaultValue: "请确认已安装 Homebrew，或手动指定 brew 可执行文件路径。"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    TextField(localization.string("detail.diagnostics.pathPlaceholder", defaultValue: "例如 /opt/homebrew/bin/brew"), text: $customBrewPath)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    
                    Button {
                        controller.updateCustomPath(customBrewPath)
                    } label: {
                        Label(localization.string("detail.diagnostics.pathApply", defaultValue: "应用"), systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(customBrewPath.isEmpty)
                }
            }
            .frame(maxWidth: 480)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(localization.string("detail.diagnostics.pathHelpTitle", defaultValue: "常见安装位置"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(localization.format(
                    "detail.diagnostics.pathAppleSiliconFormat",
                    defaultValue: "Apple Silicon Mac：%@", "/opt/homebrew/bin/brew"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(localization.format(
                    "detail.diagnostics.pathIntelFormat",
                    defaultValue: "Intel Mac：%@", "/usr/local/bin/brew"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)
            Spacer()
        }
        .padding(PluginSettingsTheme.Spacing.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pluginSettingsCardBackground(.standard)
    }
    
    private func diagnosticRow(
        title: String,
        description: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: icon)
                .pluginSettingsRowIconStyle(color, visualScale: 1.1)
            
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
            
            Button {
                action()
            } label: {
                Label(localization.string("detail.diagnostics.buttonExecute", defaultValue: "执行"), systemImage: "play")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(controller.isBusy)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }
    
    // MARK: - Component Views
    
    private func packageDetailView(for pkg: BrewPackage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: pkg.isCask ? "macwindow" : "terminal")
                    .font(.system(size: 20))
                    .foregroundStyle(pkg.isCask ? .blue : .green)
                
                Text(pkg.name)
                    .font(PluginSettingsTheme.Typography.pageTitle)
                Spacer()
                
                if pkg.isPinned {
                    Label(localization.string("detail.detail.pinned", defaultValue: "Pinned"), systemImage: "pin.fill")
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.15))
                        .foregroundStyle(.yellow)
                        .cornerRadius(4)
                }
            }
            
            if !pkg.desc.isEmpty {
                Text(pkg.desc)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 8) {
                infoRow(label: localization.string("detail.detail.type", defaultValue: "Type"), value: pkg.isCask ? localization.string("detail.detail.typeCask", defaultValue: "GUI App (Cask)") : localization.string("detail.detail.typeFormula", defaultValue: "CLI Package (Formula)"))
                infoRow(label: localization.string("detail.detail.installedVer", defaultValue: "Installed"), value: pkg.version)
                infoRow(label: localization.string("detail.detail.latestVer", defaultValue: "Latest"), value: pkg.latestVersion)
                if !pkg.homepage.isEmpty {
                    HStack {
                        Text(localization.string("detail.detail.website", defaultValue: "Homepage")).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                        Spacer()
                        if let homepageURL = validatedHomepageURL(pkg.homepage) {
                            Link(pkg.homepage, destination: homepageURL)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .lineLimit(1)
                        } else {
                            Text(pkg.homepage)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(10)
            .pluginSettingsCardBackground(.recessed)
            
            if !pkg.dependencies.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localization.format("detail.detail.dependencies", defaultValue: "Dependencies (%d)", pkg.dependencies.count))
                        .font(PluginSettingsTheme.Typography.sectionTitle)
                        .foregroundStyle(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(pkg.dependencies, id: \.self) { dep in
                                Button {
                                    navigateToPackage(name: dep)
                                } label: {
                                    Text(dep)
                                        .font(PluginSettingsTheme.Typography.monospacedValue)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.05))
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            let usedBy = pkg.requiredBy(in: controller.installedPackages)
            if !usedBy.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localization.format("detail.detail.usedBy", defaultValue: "Required By (%d)", usedBy.count))
                        .font(PluginSettingsTheme.Typography.sectionTitle)
                        .foregroundStyle(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(usedBy, id: \.self) { parent in
                                Button {
                                    navigateToPackage(name: parent)
                                } label: {
                                    Text(parent)
                                        .font(PluginSettingsTheme.Typography.monospacedValue)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.05))
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 10) {
                if pkg.isOutdated {
                    Button {
                        controller.upgrade(package: pkg)
                    } label: {
                        Label(localization.string("detail.detail.actionUpgrade", defaultValue: "Upgrade"), systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(controller.isBusy)
                }
                
                if !pkg.isPinned {
                    Button {
                        if pkg.isPinned {
                            controller.unpin(package: pkg)
                        } else {
                            controller.pin(package: pkg)
                        }
                    } label: {
                        Label(pkg.isPinned ? localization.string("detail.detail.actionUnpin", defaultValue: "Unpin") : localization.string("detail.detail.actionPin", defaultValue: "Pin Version"), systemImage: pkg.isPinned ? "pin.slash" : "pin")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(controller.isBusy)
                } else {
                    Button {
                        if pkg.isPinned {
                            controller.unpin(package: pkg)
                        } else {
                            controller.pin(package: pkg)
                        }
                    } label: {
                        Label(pkg.isPinned ? localization.string("detail.detail.actionUnpin", defaultValue: "Unpin") : localization.string("detail.detail.actionPin", defaultValue: "Pin Version"), systemImage: pkg.isPinned ? "pin.slash" : "pin")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(controller.isBusy)
                }
                
                Button(role: .destructive) {
                    pendingAction = .uninstall(pkg)
                } label: {
                    Label(localization.string("detail.detail.actionUninstall", defaultValue: "Uninstall"), systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(controller.isBusy)
            }
        }
        .padding(14)
        .pluginSettingsCardBackground(.standard)
    }
    
    private func onlinePackageDetailView(for pkg: BrewPackage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: pkg.isCask ? "macwindow" : "terminal")
                    .font(.system(size: 20))
                    .foregroundStyle(pkg.isCask ? .blue : .green)
                
                Text(pkg.name)
                    .font(PluginSettingsTheme.Typography.pageTitle)
                Spacer()
            }
            
            if !pkg.desc.isEmpty {
                Text(pkg.desc)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 8) {
                infoRow(
                    label: localization.string("detail.detail.type", defaultValue: "Type"),
                    value: pkg.isCask
                        ? localization.string("detail.filter.cask", defaultValue: "Cask")
                        : localization.string("detail.filter.formula", defaultValue: "Formula")
                )
                infoRow(label: localization.string("detail.detail.latestAvailableVer", defaultValue: "Latest Available"), value: pkg.latestVersion)
                if !pkg.homepage.isEmpty {
                    HStack {
                        Text(localization.string("detail.detail.website", defaultValue: "Homepage")).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                        Spacer()
                        if let homepageURL = validatedHomepageURL(pkg.homepage) {
                            Link(pkg.homepage, destination: homepageURL)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .lineLimit(1)
                        } else {
                            Text(pkg.homepage)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(10)
            .pluginSettingsCardBackground(.recessed)
            
            Spacer()
            
            // Actions
            let alreadyInstalled = controller.installedPackages.contains { $0.name == pkg.name }
            
            Button {
                controller.install(package: pkg)
            } label: {
                Label(alreadyInstalled ? localization.string("detail.search.installAgainAction", defaultValue: "Install Again") : localization.string("detail.search.installAction", defaultValue: "Install"), systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(controller.isBusy)
            
            if alreadyInstalled {
                Text(localization.string("detail.search.installedHint", defaultValue: "This package is already installed on your system."))
                    .font(.caption)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(14)
        .pluginSettingsCardBackground(.standard)
    }
    
    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(PluginSettingsTheme.Typography.rowDescription)
        }
    }
    
    // MARK: - Console Output Drawer
    
    private var consoleDrawer: some View {
        VStack(spacing: 0) {
            Divider()
            
            // Terminal Header
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(controller.isBusy ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                        .opacity(controller.isBusy ? 0.8 : 0.4)
                    
                    Text(localization.string("detail.console.title", defaultValue: "Terminal Console Logs"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                Button(localization.string("detail.console.buttonClear", defaultValue: "Clear")) {
                    controller.clearLogs()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(4)
                
                if controller.isBusy {
                    Button(localization.string("detail.console.buttonCancel", defaultValue: "Cancel Operation")) {
                        controller.cancelCurrentOperation()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.02))
            
            // Scrollable Console
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(controller.logs.suffix(150)) { log in
                            Text(log.text)
                                .font(PluginSettingsTheme.Typography.monospacedValue)
                                .foregroundStyle(log.isError ? Color.red : Color.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(log.id)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.95))
                .onChange(of: controller.logs.count) { _, _ in
                    if let last = controller.logs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    // MARK: - Helper Methods

    private func requestInitialScanIfNeeded() {
        guard !didRequestInitialScan else { return }
        guard controller.isBrewAvailable, !controller.isBusy else { return }
        guard controller.installedPackages.isEmpty,
              controller.outdatedPackages.isEmpty,
              controller.taps.isEmpty else {
            return
        }

        didRequestInitialScan = true
        controller.scanAll()
    }

    private func emptyState(icon: String, title: String) -> some View {
        VStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            if icon == "arrow.clockwise" {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: icon)
                    .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon))
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(PluginSettingsTheme.Typography.pageDescription)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func fetchOnlinePackageDetail(_ pkg: BrewPackage) {
        let requestedName = pkg.name
        let requestedIsCask = pkg.isCask
        isFetchingOnlineDetail = true
        onlinePackageDetail = nil
        
        Task {
            defer {
                if selectedSearchPkg?.name == requestedName && selectedSearchPkg?.isCask == requestedIsCask {
                    isFetchingOnlineDetail = false
                }
            }
            do {
                let tempRunner = controller.runner
                var jsonOutput = ""
                
                _ = try await tempRunner.run(
                    executable: controller.brewPath,
                    arguments: ["info", "--json=v2", pkg.name],
                    onOutput: { jsonOutput += $0 },
                    onError: { _ in }
                )
                
                guard selectedSearchPkg?.name == requestedName && selectedSearchPkg?.isCask == requestedIsCask else { return }
                
                guard let data = jsonOutput.data(using: .utf8) else {
                    return
                }
                
                struct BrewInfoResponse: Codable {
                    let formulae: [FormulaInfo]
                    let casks: [CaskInfo]
                }
                struct FormulaInfo: Codable {
                    let name: String
                    let desc: String?
                    let homepage: String?
                    let versions: StableVersion?
                }
                struct StableVersion: Codable {
                    let stable: String?
                }
                struct CaskInfo: Codable {
                    let token: String
                    let name: [String]?
                    let desc: String?
                    let homepage: String?
                    let version: String?
                }
                
                let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
                
                guard selectedSearchPkg?.name == requestedName && selectedSearchPkg?.isCask == requestedIsCask else { return }
                
                if pkg.isCask, let cask = response.casks.first {
                    onlinePackageDetail = BrewPackage(
                        name: cask.token,
                        version: "",
                        latestVersion: cask.version ?? "",
                        isCask: true,
                        desc: cask.desc ?? (cask.name?.first ?? ""),
                        homepage: cask.homepage ?? "",
                        isOutdated: false,
                        isPinned: false
                    )
                } else if let formula = response.formulae.first {
                    onlinePackageDetail = BrewPackage(
                        name: formula.name,
                        version: "",
                        latestVersion: formula.versions?.stable ?? "",
                        isCask: false,
                        desc: formula.desc ?? "",
                        homepage: formula.homepage ?? "",
                        isOutdated: false,
                        isPinned: false
                    )
                }
            } catch {}
        }
    }
    
    private func navigateToPackage(name: String) {
        if let found = controller.installedPackages.first(where: { $0.name == name }) {
            activeTab = .installed
            selectedInstalledPkg = found
        } else {
            activeTab = .search
            onlineSearchText = name
            runOnlineSearch()
        }
    }

    private func runOnlineSearch() {
        let trimmed = onlineSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedSearchPkg = nil
        onlinePackageDetail = nil
        controller.search(query: trimmed)
    }

    private func perform(_ action: HomebrewPendingAction) {
        switch action {
        case .upgradeAll:
            controller.upgradeAll()
        case .cleanup:
            controller.runCleanup()
        case let .uninstall(package):
            controller.uninstall(package: package)
        case let .tap(name):
            controller.tapRepository(name: name)
            newTapName = ""
        case let .untap(tap):
            controller.untapRepository(tap: tap)
        }
    }

    private func validatedHomepageURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let url = components.url else {
            return nil
        }
        return url
    }
}

private enum HomebrewPendingAction: Identifiable {
    case upgradeAll
    case cleanup
    case uninstall(BrewPackage)
    case tap(String)
    case untap(BrewTap)

    var id: String {
        switch self {
        case .upgradeAll:
            return "upgrade-all"
        case .cleanup:
            return "cleanup"
        case let .uninstall(package):
            return "uninstall-\(package.name)"
        case let .tap(name):
            return "tap-\(name)"
        case let .untap(tap):
            return "untap-\(tap.name)"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .cleanup,
             .uninstall,
             .untap:
            return .destructive
        case .upgradeAll,
             .tap:
            return nil
        }
    }

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .upgradeAll:
            return localization.string("detail.confirm.upgradeAll.title", defaultValue: "确认更新所有包？")
        case .cleanup:
            return localization.string("detail.confirm.cleanup.title", defaultValue: "确认清理 Homebrew 缓存？")
        case let .uninstall(package):
            return localization.format(
                "detail.confirm.uninstall.title",
                defaultValue: "确认卸载 %@？",
                package.name
            )
        case .tap:
            return localization.string("detail.confirm.tap.title", defaultValue: "确认添加软件源？")
        case let .untap(tap):
            return localization.format(
                "detail.confirm.untap.title",
                defaultValue: "确认移除 %@？",
                tap.name
            )
        }
    }

    func message(localization: PluginLocalization) -> String {
        switch self {
        case .upgradeAll:
            return localization.string(
                "detail.confirm.upgradeAll.message",
                defaultValue: "将执行 brew upgrade，更新所有可升级的 Homebrew 包。此操作可能修改已安装软件。"
            )
        case .cleanup:
            return localization.string(
                "detail.confirm.cleanup.message",
                defaultValue: "将执行 brew cleanup，删除 Homebrew 旧版本和下载缓存。"
            )
        case let .uninstall(package):
            return localization.format(
                "detail.confirm.uninstall.message",
                defaultValue: "将执行 brew uninstall %@。如果其他包依赖它，相关功能可能受到影响。",
                package.name
            )
        case let .tap(name):
            return localization.format(
                "detail.confirm.tap.message",
                defaultValue: "将执行 brew tap %@，Homebrew 会从该软件源获取配方和 cask 信息。",
                name
            )
        case let .untap(tap):
            return localization.format(
                "detail.confirm.untap.message",
                defaultValue: "将执行 brew untap %@。依赖该软件源的包可能无法继续更新。",
                tap.name
            )
        }
    }

    func buttonTitle(localization: PluginLocalization) -> String {
        switch self {
        case .upgradeAll:
            return localization.string("detail.confirm.upgradeAll.button", defaultValue: "更新全部")
        case .cleanup:
            return localization.string("detail.confirm.cleanup.button", defaultValue: "清理")
        case .uninstall:
            return localization.string("detail.confirm.uninstall.button", defaultValue: "卸载")
        case .tap:
            return localization.string("detail.confirm.tap.button", defaultValue: "添加")
        case .untap:
            return localization.string("detail.confirm.untap.button", defaultValue: "移除")
        }
    }
}
