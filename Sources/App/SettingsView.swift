import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit
import PermissionFlow

enum GeneralSettingsCardLayout {
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 4
    static let iconSize: CGFloat = 30
    static let iconCornerRadius: CGFloat = 8
    static let headerSpacing: CGFloat = 16
    static let minRowHeight: CGFloat = 38
}

private enum SettingsSplitViewLayout {
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 232
    static let sidebarMaxWidth: CGFloat = 280
    static let detailMinWidth: CGFloat = 560
    static let navigationChromeWidth: CGFloat = 104
}

private struct SettingsSidebarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat { SettingsSplitViewLayout.sidebarIdealWidth }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private func settingsNavigationTitle(
    for destination: SettingsNavigationDestination,
    configurationItems: [SettingsPluginNavigationItem]
) -> String {
    switch destination {
    case .general:
        AppL10n.settings("tab.general", defaultValue: "通用")
    case .permissions:
        AppL10n.settings("tab.permissions", defaultValue: "权限")
    case .about:
        AppL10n.settings("tab.about", defaultValue: "关于")
    case .plugins(.actionsAndShortcuts):
        FeatureL10n.string("操作与快捷键")
    case .plugins(.automation):
        FeatureL10n.string("自动化")
    case .plugins(.marketplace):
        AppL10n.settings("plugins.sidebar.marketplace", defaultValue: "插件市场")
    case .marketplaceDetail:
        AppL10n.settings("plugins.sidebar.marketplace", defaultValue: "插件市场")
    case let .plugins(.configuration(pluginID)):
        configurationItems.first { $0.id == pluginID }?.title
            ?? AppL10n.settings("tab.plugins", defaultValue: "插件")
    }
}

struct SettingsView: View {
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    let pluginHost: PluginHost
    @ObservedObject var presentation: SettingsNavigationPresentationModel
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let appUpdater: AppUpdater
    let menuBarIconSettings: MenuBarIconSettings
    let menuBarIconGallery: MenuBarIconGalleryLibrary
    let launchAtLoginController: LaunchAtLoginController
    let menuBarPanelThemeStore: MenuBarPanelThemeStore
    @ObservedObject var sidebarPreferences: SettingsSidebarPreferencesStore
    let appearanceUserDefaults: UserDefaults
    let commandPaletteRecentStore: CommandPaletteRecentStore
    @StateObject private var uninstallConfirmationSession = PluginUninstallConfirmationSession()
    @State private var sidebarColumnWidth = SettingsSplitViewLayout.sidebarIdealWidth

    var body: some View {
        // Recreate native AppKit-backed controls when the shared locale changes.
        let _ = runtimeLocale.revision
        let configurationItems = presentation.configurationItems
        let orderItems = configurationItems.map {
            SettingsSidebarPluginOrderItem(
                id: $0.id,
                title: $0.title,
                installedAt: $0.installedAt
            )
        }
        let orderedConfigurationIDs = sidebarPreferences.orderedPluginIDs(for: orderItems)
        let orderedSidebarDestinations = SettingsNavigationDestination.settingsSidebarOrder(
            configurationIDs: orderedConfigurationIDs
        )
        return NavigationSplitView {
            SettingsSidebarColumn {
                SettingsSidebar(
                    configurationItems: configurationItems,
                    orderedDestinations: orderedSidebarDestinations,
                    sidebarPreferences: sidebarPreferences,
                    selection: settingsSelection,
                    selectionRevealRequestID:
                        navigationCoordinator.sidebarSelectionRevealRequestID,
                    focusRequestID:
                        navigationCoordinator.sidebarFocusRequestID,
                    numberShortcutRequest:
                        navigationCoordinator.sidebarNumberShortcutRequest,
                    moveShortcutRequest:
                        navigationCoordinator.sidebarMoveShortcutRequest,
                    onSearch: {
                        navigationCoordinator.presentUnifiedSearch(origin: .settingsSidebar)
                    }
                )
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(
                min: SettingsSplitViewLayout.sidebarMinWidth,
                ideal: SettingsSplitViewLayout.sidebarIdealWidth,
                max: SettingsSplitViewLayout.sidebarMaxWidth
            )
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SettingsSidebarWidthPreferenceKey.self,
                        value: geometry.size.width
                    )
                }
            }
        } detail: {
            SettingsDetailColumn {
                SettingsDetailPane(
                    pluginHost: pluginHost,
                    navigationCoordinator: navigationCoordinator,
                    destination: navigationCoordinator.destination,
                    uninstallConfirmationSession: uninstallConfirmationSession,
                    appUpdater: appUpdater,
                    menuBarIconSettings: menuBarIconSettings,
                    menuBarIconGallery: menuBarIconGallery,
                    launchAtLoginController: launchAtLoginController,
                    menuBarPanelThemeStore: menuBarPanelThemeStore,
                    appearanceUserDefaults: appearanceUserDefaults
                )
            }
            .frame(
                minWidth: SettingsSplitViewLayout.detailMinWidth,
                maxWidth: .infinity,
                maxHeight: .infinity
            )
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) {
                        historyNavigationControls
                    }
                    .sharedBackgroundVisibility(
                        navigationCoordinator.isUnifiedSearchPresented ? .hidden : .automatic
                    )

                    ToolbarItem(placement: .navigation) {
                        SettingsDetailToolbarTitle(
                            coordinator: navigationCoordinator,
                            presentation: presentation,
                            sidebarColumnWidth: $sidebarColumnWidth
                        )
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) {
                        historyNavigationControls
                    }

                    ToolbarItem(placement: .navigation) {
                        SettingsDetailToolbarTitle(
                            coordinator: navigationCoordinator,
                            presentation: presentation,
                            sidebarColumnWidth: $sidebarColumnWidth
                        )
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onPreferenceChange(SettingsSidebarWidthPreferenceKey.self) { width in
            sidebarColumnWidth = width
        }
        .onChange(of: presentation.configurationItems.map(\.id)) {
            navigationCoordinator.reconcileCurrentDestinationAvailability()
        }
        .onChange(of: presentation.marketplaceItems) {
            navigationCoordinator.reconcileCurrentDestinationAvailability()
        }
        .blur(
            radius: navigationCoordinator.isUnifiedSearchPresented
                && !accessibilityReduceTransparency
                ? 2.5
                : 0
        )
        .allowsHitTesting(!navigationCoordinator.isUnifiedSearchPresented)
        .overlay {
            if navigationCoordinator.isUnifiedSearchPresented {
                UnifiedSearchPresentationView(
                    pluginHost: pluginHost,
                    launchAtLoginController: launchAtLoginController,
                    appearanceUserDefaults: appearanceUserDefaults,
                    recentStore: commandPaletteRecentStore,
                    navigationCoordinator: navigationCoordinator
                )
                .accessibilityAddTraits(.isModal)
            }
        }
        .id(runtimeLocale.revision)
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .environment(\.locale, PluginRuntimeLocalization.locale)
        .environment(\.layoutDirection, layoutDirection)
    }

    private var settingsSelection: Binding<SettingsNavigationDestination> {
        Binding {
            navigationCoordinator.destination.sidebarDestination
        } set: { destination in
            navigationCoordinator.navigate(to: destination)
        }
    }

    private var historyNavigationControls: some View {
        SettingsHistoryNavigationControls(
            coordinator: navigationCoordinator
        )
        .opacity(navigationCoordinator.isUnifiedSearchPresented ? 0 : 1)
        .allowsHitTesting(!navigationCoordinator.isUnifiedSearchPresented)
        .accessibilityHidden(navigationCoordinator.isUnifiedSearchPresented)
        .accessibilityIdentifier("mactools.settings.history-navigation")
    }

    private var layoutDirection: LayoutDirection {
        PluginRuntimeLocalization.locale.language.characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }

}

struct SettingsHistoryNavigationControls: View {
    @ObservedObject var coordinator: SettingsNavigationCoordinator

    var body: some View {
        ControlGroup {
            Button {
                coordinator.goBack()
            } label: {
                Label(backTitle, systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
            }
            .disabled(!coordinator.canGoBack)
            .help(backTitle)

            Button {
                coordinator.goForward()
            } label: {
                Label(forwardTitle, systemImage: "chevron.forward")
                    .labelStyle(.iconOnly)
            }
            .disabled(!coordinator.canGoForward)
            .help(forwardTitle)
        }
        .controlGroupStyle(.navigation)
    }

    private var backTitle: String {
        AppL10n.settings("navigation.back", defaultValue: "后退")
    }

    private var forwardTitle: String {
        AppL10n.settings("navigation.forward", defaultValue: "前进")
    }
}

private struct PermissionSettingsRow: View {
    let card: PluginPermissionCard
    let statusColor: Color
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: card.iconSystemImage)
                .pluginSettingsRowIconStyle(visualScale: card.iconVisualScale)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    Text(card.title)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                    Label {
                        Text(card.statusText)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: card.statusSystemImage)
                    }
                        .font(PluginSettingsTheme.Typography.secondaryLabel)
                        .foregroundStyle(statusColor)
                }

                Text(card.description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let footnote = card.footnote {
                    Text(footnote)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(card.buttonTitle, action: onAction)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

private struct PermissionCenterSettingsView: View {
    @ObservedObject var coordinator: PermissionCoordinator

    var body: some View {
        SettingsGroupedFormPageScaffold(
            introduction: SettingsPageIntroductionConfiguration(
                description: AppL10n.settings(
                    "permissions.description",
                    defaultValue: "集中查看已安装功能使用的 macOS 权限。MacTools 只能发起请求或打开系统设置，不能代替你授予权限。"
                )
            ),
            introductionAccessory: {
                Button {
                    coordinator.refresh()
                } label: {
                    Label(
                        AppL10n.settings("permissions.recheck", defaultValue: "重新检查"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .help(AppL10n.settings("permissions.recheck", defaultValue: "重新检查"))
            }
        ) { widths in
            if coordinator.items.isEmpty {
                Section {
                    ContentUnavailableView(
                        AppL10n.settings("permissions.empty.title", defaultValue: "暂无相关权限"),
                        systemImage: "checkmark.shield",
                        description: Text(AppL10n.settings(
                            "permissions.empty.description",
                            defaultValue: "安装需要 macOS 权限的插件后，它们会显示在这里。"
                        ))
                    )
                    .frame(width: widths.sectionLayout)
                    .frame(minHeight: 180)
                }
            } else {
                ForEach(coordinator.items) { item in
                    Section {
                        PermissionCenterRow(
                            item: item,
                            onAction: {
                                performPermissionCenterAction(
                                    coordinator: coordinator,
                                    item: item,
                                    sourceFrame: permissionGuidanceSourceFrame(
                                        eventType: NSApp.currentEvent?.type,
                                        mouseLocation: NSEvent.mouseLocation
                                    )
                                )
                            }
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                    } header: {
                        SettingsGroupedFormSectionHeader(
                            title: permissionTitle(for: item.kind),
                            systemImage: permissionSystemImage(for: item.kind),
                            layoutWidth: widths.readableContent
                        )
                    }
                }
            }
        }
    }
}

@MainActor
func performPermissionCenterAction(
    coordinator: PermissionCoordinator,
    item: PermissionCenterItem,
    sourceFrame: CGRect?
) {
    coordinator.performAction(for: item, sourceFrame: sourceFrame)
}

func permissionGuidanceSourceFrame(
    eventType: NSEvent.EventType?,
    mouseLocation: CGPoint
) -> CGRect? {
    switch eventType {
    case .leftMouseDown, .leftMouseUp:
        return CGRect(
            x: mouseLocation.x - 16,
            y: mouseLocation.y - 16,
            width: 32,
            height: 32
        )
    default:
        return nil
    }
}

private struct PermissionCenterRow: View {
    let item: PermissionCenterItem
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Label {
                        Text(item.statusText)
                    } icon: {
                        Image(systemName: item.statusSystemImage)
                    }
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    .foregroundStyle(statusColor(for: item.statusTone))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(permissionActionTitle(for: item), action: onAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowVertical) {
                Text(AppL10n.settings(
                    "permissions.affectedFeatures",
                    defaultValue: "使用此权限的功能"
                ))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                ForEach(item.affectedFeatures) { feature in
                    HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                        Image(systemName: featureStatusSystemImage(for: feature))
                            .foregroundStyle(featureStatusColor(for: feature))
                            .frame(width: 16)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(feature.pluginTitle)
                                    .font(PluginSettingsTheme.Typography.rowTitle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(permissionFeatureStatusText(for: feature))
                                    .font(PluginSettingsTheme.Typography.statusBadge)
                                    .foregroundStyle(featureStatusColor(for: feature))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            Text(feature.description)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let footnote = feature.footnote {
                                Text(footnote)
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if let footnote = item.footnote {
                Text(footnote)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }

    private func featureStatusSystemImage(
        for feature: PermissionCenterAffectedFeature
    ) -> String {
        if let statusSystemImage = feature.statusSystemImage {
            return statusSystemImage
        }
        return switch feature.status {
        case .attention: "exclamationmark.circle.fill"
        case .onDemand: "circle.dashed"
        case .granted: "checkmark.circle.fill"
        }
    }

    private func featureStatusColor(
        for feature: PermissionCenterAffectedFeature
    ) -> Color {
        if let statusTone = feature.statusTone {
            return statusColor(for: statusTone)
        }
        return switch feature.status {
        case .attention: .orange
        case .onDemand: .secondary
        case .granted: .green
        }
    }
}

func permissionFeatureStatusText(
    for feature: PermissionCenterAffectedFeature
) -> String {
    if let statusText = feature.statusText, !statusText.isEmpty {
        return statusText
    }

    return switch feature.status {
    case .attention:
        AppL10n.plugins("plugin.permission.notGranted", defaultValue: "未授权")
    case .onDemand:
        AppL10n.settings("permissions.status.onDemand", defaultValue: "按需请求")
    case .granted:
        AppL10n.plugins("plugin.permission.granted", defaultValue: "已授权")
    }
}

private func permissionTitle(for kind: HostPermissionKind) -> String {
    switch kind {
    case .accessibility:
        permissionFlowTitle(
            key: PermissionFlowResources.accessibilityName(),
            defaultValue: "辅助功能"
        )
    case .inputMonitoring:
        permissionFlowTitle(
            key: "permission_flow.pane.input_monitoring",
            defaultValue: "输入监控"
        )
    case .screenRecording:
        permissionFlowTitle(
            key: "permission_flow.pane.screen_recording",
            defaultValue: "屏幕录制"
        )
    case .calendarFullAccess:
        permissionFlowTitle(
            key: "permission_flow.pane.calendars",
            defaultValue: "日历完全访问"
        )
    case .automation:
        AppL10n.settings("permissions.kind.automation", defaultValue: "自动化")
    case .systemAudioRecording:
        AppL10n.settings("permissions.kind.systemAudio", defaultValue: "系统音频录制")
    case .fullDiskAccess:
        permissionFlowTitle(
            key: "permission_flow.pane.full_disk_access",
            defaultValue: "完全磁盘访问"
        )
    case .finderExtension:
        AppL10n.settings("permissions.kind.finderExtension", defaultValue: "Finder 扩展")
    }
}

private func permissionFlowTitle(key: String, defaultValue: String) -> String {
    PermissionFlowResources.localizedString(
        for: key,
        defaultValue: defaultValue,
        localeIdentifier: PluginRuntimeLocalization.locale.identifier
    )
}

private func permissionSystemImage(for kind: HostPermissionKind) -> String {
    switch kind {
    case .accessibility: "accessibility"
    case .inputMonitoring: "keyboard.badge.eye"
    case .screenRecording: "rectangle.dashed.badge.record"
    case .calendarFullAccess: "calendar"
    case .automation: "cursorarrow.click.2"
    case .systemAudioRecording: "waveform.badge.mic"
    case .fullDiskAccess: "externaldrive.badge.checkmark"
    case .finderExtension: "puzzlepiece.extension"
    }
}

private func permissionActionTitle(for item: PermissionCenterItem) -> String {
    if item.status == .granted {
        return AppL10n.settings("permissions.recheck", defaultValue: "重新检查")
    }
    switch item.kind {
    case .calendarFullAccess, .systemAudioRecording:
        return AppL10n.plugins("plugin.permission.requestAuthorization", defaultValue: "请求授权")
    case .automation, .finderExtension:
        return AppL10n.plugins("plugin.permission.openSettings", defaultValue: "打开设置")
    default:
        return AppL10n.plugins("plugin.permission.openAuthorization", defaultValue: "前往授权")
    }
}

struct GeneralSettingsView: View {
    let pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    @ObservedObject var menuBarIconSettings: MenuBarIconSettings
    @ObservedObject var menuBarIconGallery: MenuBarIconGalleryLibrary
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @ObservedObject var menuBarPanelThemeStore: MenuBarPanelThemeStore
    @ObservedObject private var cliService = CLIBrokerServiceController.shared
    @AppStorage(AppAppearancePreference.userDefaultsKey) private var appearancePreferenceRawValue = AppAppearancePreference.system.rawValue
    @AppStorage(PluginFloatingPanelAppearance.userDefaultsKey) private var floatingPanelAppearanceRawValue = PluginFloatingPanelAppearance.system.rawValue
    @AppStorage(AppLanguagePreference.userDefaultsKey) private var languagePreferenceRawValue = AppLanguagePreference.system.rawValue
    @State private var activeSearchTarget: GeneralSettingsSearchTarget?
    @State private var clearSearchTargetTask: Task<Void, Never>?

    init(
        pluginHost: PluginHost,
        navigationCoordinator: SettingsNavigationCoordinator,
        menuBarIconSettings: MenuBarIconSettings,
        menuBarIconGallery: MenuBarIconGalleryLibrary,
        launchAtLoginController: LaunchAtLoginController,
        menuBarPanelThemeStore: MenuBarPanelThemeStore = .shared,
        appearanceUserDefaults: UserDefaults
    ) {
        self.pluginHost = pluginHost
        self.navigationCoordinator = navigationCoordinator
        self.menuBarIconSettings = menuBarIconSettings
        self.menuBarIconGallery = menuBarIconGallery
        self.launchAtLoginController = launchAtLoginController
        self.menuBarPanelThemeStore = menuBarPanelThemeStore
        _appearancePreferenceRawValue = AppStorage(
            wrappedValue: AppAppearancePreference.system.rawValue,
            AppAppearancePreference.userDefaultsKey,
            store: appearanceUserDefaults
        )
        _floatingPanelAppearanceRawValue = AppStorage(
            wrappedValue: PluginFloatingPanelAppearance.system.rawValue,
            PluginFloatingPanelAppearance.userDefaultsKey,
            store: appearanceUserDefaults
        )
        _languagePreferenceRawValue = AppStorage(
            wrappedValue: AppLanguagePreference.system.rawValue,
            AppLanguagePreference.userDefaultsKey,
            store: appearanceUserDefaults
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            SettingsGroupedFormLayout(widthPolicy: .general) { widths in
                Section {
                    LaunchAtLoginSettingsRow(controller: launchAtLoginController)
                        .generalSettingsSearchAnchor(
                            target: .launchAtLogin,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("general.section.startup", defaultValue: "启动"),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    AppearanceSettingsRow(
                        selectionRawValue: appearancePreferenceBinding
                    )
                        .generalSettingsSearchAnchor(
                            target: .appearance,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                    FloatingPanelAppearanceSettingsRow(
                        selectionRawValue: floatingPanelAppearanceBinding
                    )
                    .generalSettingsSearchAnchor(
                        target: .floatingPanels,
                        activeTarget: activeSearchTarget
                    )
                    .settingsGroupedFormRowWidth(widths.sectionLayout)
                    MenuBarPanelThemeSettingsRow(
                        themeStore: menuBarPanelThemeStore,
                        appearancePreference: AppAppearancePreference(
                            rawValue: appearancePreferenceRawValue
                        ) ?? .system
                    )
                    .settingsGroupedFormRowWidth(widths.sectionLayout)
                    LanguageSettingsRow(selectionRawValue: languagePreferenceBinding)
                        .generalSettingsSearchAnchor(
                            target: .language,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("general.section.appearance", defaultValue: "外观"),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    MenuBarIconSettingsView(
                        iconSettings: menuBarIconSettings,
                        gallery: menuBarIconGallery,
                        iconCoordinator: pluginHost.menuBarIconCoordinator
                    )
                    .generalSettingsSearchAnchor(
                        target: .menuBarIcon,
                        activeTarget: activeSearchTarget
                    )
                    .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("general.section.menuBarIcon", defaultValue: "状态栏图标"),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    AppShortcutSettingsRows(pluginHost: pluginHost)
                        .generalSettingsSearchAnchor(
                            target: .appShortcuts,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("shortcuts.title", defaultValue: "键盘快捷键"),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    PreferencesBackupSettingsRow(pluginHost: pluginHost)
                        .generalSettingsSearchAnchor(
                            target: .preferencesBackup,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.preferencesBackup(
                            "general.section.preferencesBackup",
                            defaultValue: "偏好设置备份"
                        ),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    CloudPreferencesSyncSettingsRow(pluginHost: pluginHost)
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.preferencesBackup(
                            "general.section.cloudPreferencesSync",
                            defaultValue: "云同步"
                        ),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    if CLIInstallController.isSupportedChannel {
                        CLIInstallSettingsView()
                            .settingsGroupedFormRowWidth(widths.sectionLayout)
                    } else {
                        CLISettingsRow(service: cliService)
                            .settingsGroupedFormRowWidth(widths.sectionLayout)
                    }
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("general.section.commandLine", defaultValue: "命令行"),
                        layoutWidth: widths.readableContent
                    )
                }
            }
            .onAppear {
                applySearchRevealRequest(
                    navigationCoordinator.searchRevealRequest,
                    proxy: proxy
                )
            }
            .onChange(of: navigationCoordinator.searchRevealRequest) { _, request in
                applySearchRevealRequest(request, proxy: proxy)
            }
            .onDisappear {
                clearSearchTargetTask?.cancel()
                clearSearchTargetTask = nil
                if let activeSearchTarget {
                    navigationCoordinator.clearSearchRevealRequest(
                        matching: .general(activeSearchTarget)
                    )
                }
                activeSearchTarget = nil
            }
        }
    }

    private func applySearchRevealRequest(
        _ request: SettingsSearchRevealRequest?,
        proxy: ScrollViewProxy
    ) {
        guard
            let request,
            case let .general(target) = request.target
        else {
            return
        }

        clearSearchTargetTask?.cancel()
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

    private var appearancePreferenceBinding: Binding<String> {
        Binding(
            get: { appearancePreferenceRawValue },
            set: { rawValue in
                guard pluginHost.setApplicationAppearancePreference(rawValue: rawValue) else {
                    return
                }
                appearancePreferenceRawValue = rawValue
            }
        )
    }

    private var languagePreferenceBinding: Binding<String> {
        Binding(
            get: { languagePreferenceRawValue },
            set: { rawValue in
                guard pluginHost.setApplicationLanguagePreference(rawValue: rawValue) else {
                    return
                }
                languagePreferenceRawValue = rawValue
            }
        )
    }

    private var floatingPanelAppearanceBinding: Binding<String> {
        Binding(
            get: { floatingPanelAppearanceRawValue },
            set: { rawValue in
                guard pluginHost.setApplicationFloatingPanelAppearance(rawValue: rawValue) else {
                    return
                }
                floatingPanelAppearanceRawValue = rawValue
            }
        )
    }
}

private struct CLISettingsRow: View {
    @ObservedObject var service: CLIBrokerServiceController

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: GeneralSettingsCardLayout.iconCornerRadius,
                    style: .continuous
                )
                .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "terminal")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(
                width: GeneralSettingsCardLayout.iconSize,
                height: GeneralSettingsCardLayout.iconSize
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.settings("commandLine.title", defaultValue: "MacTools 命令行"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(subtitle)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(service.lastError == nil ? .secondary : Color.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if service.status == .requiresApproval {
                Button(AppL10n.settings("commandLine.approve", defaultValue: "允许后台运行")) {
                    service.openApprovalSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Toggle(
                AppL10n.settings("commandLine.title", defaultValue: "MacTools 命令行"),
                isOn: Binding(
                    get: { service.isRegistered },
                    set: { enabled in
                        if enabled {
                            _ = service.ensureRegistered()
                        } else {
                            _ = service.unregister()
                        }
                    }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .frame(
            maxWidth: .infinity,
            minHeight: GeneralSettingsCardLayout.minRowHeight,
            alignment: .leading
        )
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .onAppear { service.refresh() }
    }

    private var subtitle: String {
        if let error = service.lastError { return error }
        switch service.status {
        case .enabled:
            return AppL10n.settings(
                "commandLine.enabled",
                defaultValue: "已允许单独安装的 mactools-cli 连接到 MacTools。"
            )
        case .requiresApproval:
            return AppL10n.settings(
                "commandLine.requiresApproval",
                defaultValue: "请在系统设置中允许 MacTools 命令行代理后台运行。"
            )
        case .notRegistered, .notFound, .registrationFailed:
            return AppL10n.settings(
                "commandLine.description",
                defaultValue: "单独安装 mactools-cli 后，在此启用本机命令行集成。"
            )
        }
    }
}

private struct GeneralSettingsSearchAnchorModifier: ViewModifier {
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    let target: GeneralSettingsSearchTarget
    let activeTarget: GeneralSettingsSearchTarget?

    func body(content: Content) -> some View {
        content
            .id(target.scrollID)
            .accessibilityFocused($isAccessibilityFocused)
            .overlay {
                if activeTarget == target {
                    RoundedRectangle(
                        cornerRadius: PluginSettingsTheme.Radius.card,
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

    private func focusIfNeeded(_ activeTarget: GeneralSettingsSearchTarget?) {
        guard activeTarget == target else {
            return
        }

        isAccessibilityFocused = true
    }
}

private extension View {
    func generalSettingsSearchAnchor(
        target: GeneralSettingsSearchTarget,
        activeTarget: GeneralSettingsSearchTarget?
    ) -> some View {
        modifier(
            GeneralSettingsSearchAnchorModifier(
                target: target,
                activeTarget: activeTarget
            )
        )
    }
}

private struct AppShortcutSettingsRows: View {
    @ObservedObject var pluginHost: PluginHost

    private var items: [AppShortcutSettingsItem] {
        pluginHost.appShortcutItems.filter { !$0.action.isPanelAction }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                AppShortcutSettingsRow(pluginHost: pluginHost, item: item)

                if index < items.count - 1 {
                    PluginSettingsListDivider()
                }
            }
        }
    }
}

private struct AppShortcutSettingsRow: View {
    private enum Layout {
        static let recorderWidth = PluginSettingsTheme.Size.shortcutRecorderWidth
        static let actionButtonSize: CGFloat = 22
        static let controlSpacing = PluginSettingsTheme.Spacing.controlCluster
        static let controlClusterWidth = recorderWidth + controlSpacing + actionButtonSize
        static let summaryMinWidth: CGFloat = 220
    }

    @ObservedObject var pluginHost: PluginHost
    let item: AppShortcutSettingsItem
    @State private var pendingWarning: CommonShortcutBindingWarning?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                appIcon
                summary
                    .frame(minWidth: Layout.summaryMinWidth)
                shortcutControl
            }

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                    appIcon
                    summary
                }

                shortcutControl
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .alert(item: $pendingWarning) { warning in
            commonShortcutBindingWarningAlert(warning) {
                _ = save(warning.binding)
            }
        }
    }

    private func record(_ binding: ShortcutBinding) -> PluginShortcutRecordingResult {
        if MacToolsReservedShortcutBindings.requiresConflictWarning(for: binding) {
            pendingWarning = CommonShortcutBindingWarning(shortcutID: item.id, binding: binding)
            return .accepted
        }

        return PluginShortcutRecordingResult.from(errorMessage: save(binding))
    }

    private func save(_ binding: ShortcutBinding) -> String? {
        pluginHost.setAppShortcutBindingAndReturnError(
            binding,
            for: item.action,
            assignmentID: item.assignmentID
        )
    }

    private var appIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))

            Image(systemName: item.systemImage)
                .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(item.errorMessage ?? item.description)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(item.errorMessage == nil ? Color.secondary : Color.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var shortcutControl: some View {
        HStack(spacing: Layout.controlSpacing) {
            PluginShortcutRecorder(
                title: item.title,
                displayText: item.bindingText,
                minWidth: Layout.recorderWidth,
                onRecord: { binding in
                    record(binding)
                },
                onBeginRecording: {
                    pluginHost.clearAppShortcutError(item.action)
                }
            )
            .frame(width: Layout.recorderWidth)

            if item.canClear {
                Button {
                    pluginHost.clearAppShortcut(
                        item.action,
                        assignmentID: item.assignmentID
                    )
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(PluginSettingsTheme.Typography.rowIcon)
                        .symbolRenderingMode(.monochrome)
                        .frame(
                            width: Layout.actionButtonSize,
                            height: Layout.actionButtonSize
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondary)
                .help(AppL10n.settings("shortcuts.clearHelp", defaultValue: "清除快捷键"))
            } else {
                Color.clear
                    .frame(width: Layout.actionButtonSize, height: Layout.actionButtonSize)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: Layout.controlClusterWidth, alignment: .trailing)
    }
}

private struct PendingPreferencesImport: Identifiable {
    let id = UUID()
    let backup: PreferencesBackup
    let preview: PreferencesImportPreview
}

private struct PreferencesBackupSettingsRow: View {
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    private enum ManualBackupFeedback {
        case created
        case unchanged
    }

    @ObservedObject var pluginHost: PluginHost
    @State private var pendingImport: PendingPreferencesImport?
    @State private var isChoosingExport = false
    @State private var exportSelection = PreferencesBackupSelection.all(pluginPreferenceIDs: [])
    @State private var exportPluginOptions: [PreferencesPluginOption] = []
    @State private var deviceLocalAutomationRuleCount = 0
    @State private var alertMessage: String?
    @State private var isPreparingImport = false
    @State private var isImporting = false
    @State private var importProgress: PreferencesImportProgress?
    @State private var isBackingUp = false
    @State private var manualBackupFeedback: ManualBackupFeedback?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))

                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

                VStack(alignment: .leading, spacing: 3) {
                    Text(AppL10n.preferencesBackup("preferencesBackup.title", defaultValue: "偏好设置备份"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.description",
                        defaultValue: "自动备份保存在本机，包含可移植的应用与插件设置；不包含权限、缓存、凭证或其他私密数据。"
                    ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)

            backupRowDivider

            Toggle(
                isOn: Binding(
                    get: { pluginHost.automaticPreferencesBackupEnabled },
                    set: { enabled in
                        pluginHost.setAutomaticPreferencesBackupEnabled(enabled)
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        AppL10n.preferencesBackup(
                            "preferencesBackup.automatic.enabled",
                            defaultValue: "自动备份设置"
                        )
                    )
                    .font(PluginSettingsTheme.Typography.rowTitle)

                    automaticBackupSummaryView
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)

            backupRowDivider

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.manual.title",
                        defaultValue: "手动备份"
                    ))
                    .font(PluginSettingsTheme.Typography.rowTitle)

                    if let manualBackupFeedback {
                        Text(manualBackupFeedbackText(manualBackupFeedback))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                Button(
                    AppL10n.preferencesBackup(
                        "preferencesBackup.automatic.backUpNow",
                        defaultValue: "立即备份"
                    ),
                    action: backUpNow
                )
                    .buttonStyle(.bordered)
                    .disabled(isPreparingImport || isImporting || isBackingUp)

                Button(
                    AppL10n.preferencesBackup(
                        "preferencesBackup.automatic.openFolder",
                        defaultValue: "打开备份文件夹"
                    ),
                    action: openBackupFolder
                )
                    .buttonStyle(.bordered)
                    .disabled(isPreparingImport || isImporting)
            }
            .controlSize(.small)
            .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)

            backupRowDivider

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Text(AppL10n.preferencesBackup(
                    "preferencesBackup.transfer.title",
                    defaultValue: "迁移偏好设置"
                ))
                .font(PluginSettingsTheme.Typography.rowTitle)

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                Button(AppL10n.preferencesBackup("preferencesBackup.export", defaultValue: "导出偏好设置…"), action: exportPreferences)
                    .buttonStyle(.bordered)
                    .disabled(isPreparingImport || isImporting || isBackingUp)

                Button(AppL10n.preferencesBackup("preferencesBackup.import", defaultValue: "导入偏好设置…"), action: choosePreferencesImport)
                    .buttonStyle(.bordered)
                    .disabled(isPreparingImport || isImporting || isBackingUp)
            }
            .controlSize(.small)
            .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)

        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .sheet(item: $pendingImport) { pending in
            PreferencesImportPreviewSheet(
                preview: pending.preview,
                previewProvider: { selection in
                    try pluginHost.preferencesImportPreview(
                        for: pending.backup,
                        selection: selection
                    )
                },
                pluginOptions: pluginOptions(for: Set(pending.backup.pluginPreferences.keys)),
                isImporting: isImporting,
                importProgress: importProgress,
                onCancel: { pendingImport = nil },
                onImport: { selectedPluginIDs, selection in
                    importPreferences(
                        pending.backup,
                        installingMissingPluginIDs: selectedPluginIDs,
                        selection: selection
                    )
                }
            )
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
        }
        .sheet(isPresented: $isChoosingExport) {
            PreferencesExportSelectionSheet(
                selection: $exportSelection,
                pluginOptions: exportPluginOptions,
                deviceLocalAutomationRuleCount: deviceLocalAutomationRuleCount,
                onCancel: { isChoosingExport = false },
                onExport: {
                    isChoosingExport = false
                    savePreferences(selection: exportSelection)
                }
            )
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
        }
        .alert(
            AppL10n.preferencesBackup("preferencesBackup.alert.title", defaultValue: "偏好设置备份"),
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
    }

    private var backupRowDivider: some View {
        PluginSettingsListDivider(
            leadingInset: GeneralSettingsCardLayout.horizontalPadding,
            trailingInset: GeneralSettingsCardLayout.horizontalPadding
        )
    }

    @ViewBuilder
    private var automaticBackupSummaryView: some View {
        let summary = pluginHost.automaticPreferencesBackupSummary
        if let latestBackupDate = summary.latestBackupDate {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 1) {
                    Text(automaticBackupRelativeText(
                        latestBackupDate,
                        relativeTo: context.date
                    ))
                    Text(automaticBackupDetailsText(
                        summary,
                        latestBackupDate: latestBackupDate
                    ))
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            Text(AppL10n.preferencesBackup(
                "preferencesBackup.automatic.noBackups",
                defaultValue: "还没有备份"
            ))
        }
    }

    private func automaticBackupRelativeText(
        _ latestBackupDate: Date,
        relativeTo referenceDate: Date
    ) -> String {
        let locale = PluginRuntimeLocalization.locale
        let relativeDate = PreferencesBackupStatusFormatter.relativeDate(
            latestBackupDate,
            relativeTo: referenceDate,
            locale: locale,
            justNow: AppL10n.preferencesBackup(
                "preferencesBackup.automatic.justNow",
                defaultValue: "刚刚"
            )
        )
        return String(
            format: AppL10n.preferencesBackup(
                "preferencesBackup.automatic.lastBackup",
                defaultValue: "上次备份：%@"
            ),
            locale: locale,
            relativeDate
        )
    }

    private func automaticBackupDetailsText(
        _ summary: AutomaticPreferencesBackupSummary,
        latestBackupDate: Date
    ) -> String {
        let locale = PluginRuntimeLocalization.locale
        let date = PreferencesBackupStatusFormatter.absoluteDate(
            latestBackupDate,
            locale: locale
        )
        let size = PreferencesBackupStatusFormatter.byteCount(
            summary.totalSize,
            locale: locale
        )
        let history = AppL10n.preferencesBackupPluralFormat(
            "preferencesBackup.automatic.history",
            defaultValue: "%d 个备份 · %@",
            count: summary.snapshotCount,
            size
        )
        return "\(date) · \(history)"
    }

    private func manualBackupFeedbackText(_ feedback: ManualBackupFeedback) -> String {
        switch feedback {
        case .created:
            AppL10n.preferencesBackup(
                "preferencesBackup.manual.created",
                defaultValue: "刚刚已备份"
            )
        case .unchanged:
            AppL10n.preferencesBackup(
                "preferencesBackup.manual.unchanged",
                defaultValue: "与上次备份相比没有变化"
            )
        }
    }

    private func backUpNow() {
        Task { @MainActor in
            isBackingUp = true
            defer { isBackingUp = false }
            do {
                let result = try await pluginHost.createAutomaticPreferencesBackupNow()
                switch result {
                case .created:
                    manualBackupFeedback = .created
                case .unchanged:
                    manualBackupFeedback = .unchanged
                }
            } catch {
                alertMessage = preferencesBackupErrorMessage(error)
            }
        }
    }

    private func openBackupFolder() {
        do {
            NSWorkspace.shared.open(
                try pluginHost.prepareAutomaticPreferencesBackupDirectory()
            )
        } catch {
            alertMessage = preferencesBackupErrorMessage(error)
        }
    }

    private func exportPreferences() {
        let backup = pluginHost.makePreferencesBackup()
        exportSelection = .all(pluginPreferenceIDs: Set(backup.pluginPreferences.keys))
        exportPluginOptions = pluginOptions(for: Set(backup.pluginPreferences.keys))
        deviceLocalAutomationRuleCount = pluginHost.deviceLocalAutomationRuleCount
        isChoosingExport = true
    }

    private func savePreferences(selection: PreferencesBackupSelection) {
        let data: Data
        do {
            data = try PreferencesArchiveDocument(
                scope: .full,
                backup: pluginHost.makePreferencesBackup(selection: selection)
            ).encodedJSON()
        } catch {
            alertMessage = preferencesBackupErrorMessage(error)
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = PreferencesBackupExportFileName.make()
        panel.message = AppL10n.preferencesBackup("preferencesBackup.export.prompt", defaultValue: "将可移植的 MacTools 偏好设置保存为 JSON 文件。")

        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try data.write(to: url, options: .atomic)
            alertMessage = AppL10n.preferencesBackup("preferencesBackup.exported", defaultValue: "偏好设置已导出。")
        } catch {
            alertMessage = preferencesBackupErrorMessage(error)
        }
    }

    private func choosePreferencesImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = AppL10n.preferencesBackup("preferencesBackup.import.prompt", defaultValue: "选择 MacTools 导出的偏好设置 JSON 文件。")

        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task { @MainActor in
            isPreparingImport = true
            defer { isPreparingImport = false }

            do {
                let backup = try await PreferencesBackup.decodeJSON(contentsOf: url)
                await pluginHost.refreshPluginCatalog()
                pendingImport = PendingPreferencesImport(
                    backup: backup,
                    preview: try pluginHost.preferencesImportPreview(for: backup)
                )
            } catch {
                alertMessage = preferencesBackupErrorMessage(error)
            }
        }
    }

    private func importPreferences(
        _ backup: PreferencesBackup,
        installingMissingPluginIDs pluginIDs: Set<String>,
        selection: PreferencesBackupSelection
    ) {
        Task { @MainActor in
            isImporting = true
            importProgress = .preparing(pluginCount: pluginIDs.count)
            defer {
                isImporting = false
                importProgress = nil
            }

            do {
                let result = try await pluginHost.importPreferences(
                    backup,
                    installingMissingPluginIDs: pluginIDs,
                    selection: selection,
                    progress: { importProgress = $0 }
                )
                pendingImport = nil
                let importedMessage = AppL10n.preferencesBackup(
                    "preferencesBackup.imported",
                    defaultValue: "偏好设置已导入。"
                )
                let warnings = result.pluginInstallationFailures
                    .sorted { $0.key < $1.key }
                    .map { pluginID, message in
                        let title = pluginHost.pluginManagementItems
                            .first(where: { $0.id == pluginID })?
                            .title
                            ?? pluginID
                        return "\(title): \(message)"
                    }
                    + result.deferredPluginPreferenceIDs.map { pluginID in
                        let title = pluginHost.pluginManagementItems
                            .first(where: { $0.id == pluginID })?
                            .title
                            ?? pluginID
                        return AppL10n.preferencesBackupFormat(
                            "preferencesBackup.import.pluginRestoreDeferred",
                            defaultValue: "已安装“%@”。请重新启动 MacTools，然后再次导入此备份以恢复其设置。",
                            title
                        )
                    }
                    + result.shortcutErrors
                        .values
                        .sorted()
                alertMessage = warnings.isEmpty
                    ? importedMessage
                    : ([importedMessage] + warnings).joined(separator: "\n")
            } catch {
                pendingImport = nil
                alertMessage = preferencesBackupErrorMessage(error)
            }
        }
    }

    private func pluginOptions(for pluginIDs: Set<String>) -> [PreferencesPluginOption] {
        let titles = Dictionary(
            pluginHost.pluginManagementItems.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        return pluginIDs.map { id in
            PreferencesPluginOption(id: id, title: titles[id] ?? id)
        }
        .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    private func preferencesBackupErrorMessage(_ error: Error) -> String {
        switch error as? PreferencesBackupError {
        case let .unsupportedFormatVersion(version):
            return AppL10n.preferencesBackupFormat(
                "preferencesBackup.error.unsupportedFormat",
                defaultValue: "不支持的偏好设置备份版本（%d）。",
                version
            )
        case .invalidApplicationPreferences:
            return AppL10n.preferencesBackup(
                "preferencesBackup.error.invalidApplicationPreferences",
                defaultValue: "备份中的应用偏好设置无效。"
            )
        case let .fileTooLarge(maximumBytes):
            return AppL10n.preferencesBackupFormat(
                "preferencesBackup.error.fileTooLarge",
                defaultValue: "偏好设置备份不能超过 %d MB。",
                maximumBytes / (1024 * 1024)
            )
        case nil:
            return error.localizedDescription
        }
    }
}

private struct CloudPreferencesSyncSettingsRow: View {
    @ObservedObject var pluginHost: PluginHost
    @State private var isSyncingManually = false
    @State private var alertMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                        .fill(Color.blue.opacity(0.12))

                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                        .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                        .foregroundStyle(Color.blue)
                }
                .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

                VStack(alignment: .leading, spacing: 3) {
                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.cloudSync.title",
                        defaultValue: "偏好设置云同步"
                    ))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.cloudSync.description",
                        defaultValue: "通过所选的云盘或共享文件夹，同步可在其他 Mac 上使用的应用与插件设置。系统权限、缓存和钥匙串项目不会同步。选择将脚本文本纳入备份后，这些文本也会同步，且可能包含敏感信息。"
                    ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)

            rowDivider

            Toggle(
                isOn: Binding(
                    get: { pluginHost.cloudPreferencesSyncEnabled },
                    set: { pluginHost.setCloudPreferencesSyncEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.cloudSync.enabled",
                        defaultValue: "启用偏好设置云同步"
                    ))
                    .font(PluginSettingsTheme.Typography.rowTitle)

                    cloudSyncStatusSubtitleView
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)

            rowDivider

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.cloudSync.folder",
                        defaultValue: "同步文件夹"
                    ))
                    .font(PluginSettingsTheme.Typography.rowTitle)

                    if let folderURL = pluginHost.cloudPreferencesSyncDirectoryURL {
                        Text(folderURL.path)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(AppL10n.preferencesBackup(
                            "preferencesBackup.cloudSync.notConfigured",
                            defaultValue: "未配置文件夹"
                        ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                Button(
                    pluginHost.cloudPreferencesSyncDirectoryURL == nil
                        ? AppL10n.preferencesBackup("preferencesBackup.cloudSync.chooseFolder", defaultValue: "选择文件夹…")
                        : AppL10n.preferencesBackup("preferencesBackup.cloudSync.changeFolder", defaultValue: "更改…"),
                    action: chooseSyncFolder
                )
                .buttonStyle(.bordered)

                if pluginHost.cloudPreferencesSyncDirectoryURL != nil {
                    Button(
                        AppL10n.preferencesBackup("preferencesBackup.cloudSync.openFolder", defaultValue: "打开文件夹"),
                        action: { pluginHost.openCloudPreferencesSyncFolder() }
                    )
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)

            rowDivider

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        cloudSyncStatusIcon
                        Text(cloudSyncStatusText)
                            .font(PluginSettingsTheme.Typography.rowTitle)
                    }

                    if let subtitle = cloudSyncStatusDetailText {
                        Text(subtitle)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                Button(
                    AppL10n.preferencesBackup(
                        "preferencesBackup.cloudSync.syncNow",
                        defaultValue: "立即同步"
                    ),
                    action: syncNow
                )
                .buttonStyle(.bordered)
                .disabled(
                    !pluginHost.cloudPreferencesSyncEnabled
                        || pluginHost.cloudPreferencesSyncDirectoryURL == nil
                        || isSyncingManually
                        || pluginHost.cloudPreferencesSyncStatus.isSyncing
                )
            }
            .controlSize(.small)
            .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
            if case .conflict = pluginHost.cloudPreferencesSyncStatus {
                rowDivider
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(AppL10n.preferencesBackup("preferencesBackup.cloudSync.conflict.detail", defaultValue: "本机和共享设置均已更改。两个版本已保留，请选择要同步的版本。此 Mac 的专属设置会保留。"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(AppL10n.preferencesBackup("preferencesBackup.cloudSync.conflict.local", defaultValue: "使用本机设置")) {
                            resolveConflict(.local)
                        }
                        Button(AppL10n.preferencesBackup("preferencesBackup.cloudSync.conflict.shared", defaultValue: "使用共享设置")) {
                            resolveConflict(.shared)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSyncingManually || !pluginHost.cloudPreferencesSyncEnabled)
                }
                .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
                .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
            }
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .alert(
            AppL10n.preferencesBackup("preferencesBackup.cloudSync.title", defaultValue: "偏好设置云同步"),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button(AppL10n.settings("common.ok", defaultValue: "好"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var rowDivider: some View {
        PluginSettingsListDivider(
            leadingInset: GeneralSettingsCardLayout.horizontalPadding,
            trailingInset: GeneralSettingsCardLayout.horizontalPadding
        )
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = AppL10n.settings("common.choose", defaultValue: "选择")
        panel.message = AppL10n.preferencesBackup(
            "preferencesBackup.cloudSync.folderPrompt",
            defaultValue: "选择用于同步 MacTools 偏好设置的文件夹（如 iCloud 云盘或 Dropbox）。"
        )

        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pluginHost.setCloudPreferencesSyncDirectoryURL(url)
    }

    private func resolveConflict(_ choice: CloudPreferencesConflictChoice) {
        Task { @MainActor in
            isSyncingManually = true
            defer { isSyncingManually = false }
            do { try await pluginHost.resolveCloudPreferencesConflict(choice) }
            catch { alertMessage = preferencesBackupErrorMessage(error) }
        }
    }

    private func syncNow() {
        Task { @MainActor in
            isSyncingManually = true
            defer { isSyncingManually = false }
            do {
                try await pluginHost.triggerCloudPreferencesSync()
            } catch {
                alertMessage = preferencesBackupErrorMessage(error)
            }
        }
    }

    private func cloudSyncRelativeDate(_ date: Date, relativeTo referenceDate: Date) -> String {
        PreferencesBackupStatusFormatter.relativeDate(
            date,
            relativeTo: referenceDate,
            locale: PluginRuntimeLocalization.locale,
            justNow: AppL10n.preferencesBackup(
                "preferencesBackup.automatic.justNow",
                defaultValue: "刚刚"
            )
        )
    }

    private var cloudSyncStatusSubtitleView: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let date = pluginHost.cloudPreferencesSyncStatus.lastSyncedDate {
                Text(AppL10n.preferencesBackupFormat(
                    "preferencesBackup.cloudSync.status.lastSynced",
                    defaultValue: "上次同步：%@",
                    cloudSyncRelativeDate(date, relativeTo: context.date)
                ))
            } else {
                Text(cloudSyncStatusDetailText ?? cloudSyncStatusText)
            }
        }
    }

    @ViewBuilder
    private var cloudSyncStatusIcon: some View {
        switch pluginHost.cloudPreferencesSyncStatus {
        case .offline:
            Image(systemName: "icloud.slash").foregroundStyle(.secondary)
        case .syncing:
            ProgressView().controlSize(.mini)
        case .pending:
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
        case .conflict:
            Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
        case .synced:
            Image(systemName: "checkmark.icloud").foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.icloud").foregroundStyle(.red)
        }
    }

    private var cloudSyncStatusText: String {
        switch pluginHost.cloudPreferencesSyncStatus {
        case .offline:
            AppL10n.preferencesBackup("preferencesBackup.cloudSync.status.offline", defaultValue: "离线")
        case .syncing:
            AppL10n.preferencesBackup("preferencesBackup.cloudSync.status.syncing", defaultValue: "同步中…")
        case .pending:
            AppL10n.preferencesBackup("preferencesBackup.cloudSync.status.pending", defaultValue: "等待同步")
        case .conflict:
            AppL10n.preferencesBackup("preferencesBackup.cloudSync.status.conflict", defaultValue: "需要选择设置版本")
        case .synced:
            AppL10n.preferencesBackup("preferencesBackup.cloudSync.status.synced", defaultValue: "已同步")
        case .error:
            AppL10n.preferencesBackup("preferencesBackup.cloudSync.status.error", defaultValue: "错误")
        }
    }

    private var cloudSyncStatusDetailText: String? {
        switch pluginHost.cloudPreferencesSyncStatus {
        case .offline(let reason):
            switch reason {
            case .disabled:
                AppL10n.preferencesBackup("preferencesBackup.cloudSync.status.disabled", defaultValue: "云同步未启用")
            case .folderNotConfigured:
                AppL10n.preferencesBackup("preferencesBackup.cloudSync.notConfigured", defaultValue: "未配置文件夹")
            case .folderNotFound:
                AppL10n.preferencesBackup("preferencesBackup.cloudSync.status.folderMissing", defaultValue: "配置的同步文件夹不存在")
            case .snapshotMissing:
                AppL10n.preferencesBackup("preferencesBackup.cloudSync.status.snapshotMissing", defaultValue: "共享文件暂不可用。请检查云盘后重试；本机设置已保留。")
            }
        case .syncing, .pending:
            nil
        case .conflict(let deviceName):
            deviceName.isEmpty ? nil : deviceName
        case .synced(let date):
            date.map {
                AppL10n.preferencesBackupFormat(
                    "preferencesBackup.cloudSync.status.lastSynced",
                    defaultValue: "上次同步：%@",
                    cloudSyncRelativeDate($0, relativeTo: .now)
                )
            }
        case .error(let message):
            message
        }
    }

    private func preferencesBackupErrorMessage(_ error: Error) -> String {
        switch error as? PreferencesBackupError {
        case let .unsupportedFormatVersion(version):
            AppL10n.preferencesBackupFormat(
                "preferencesBackup.error.unsupportedFormat",
                defaultValue: "不支持的偏好设置备份版本（%d）。",
                version
            )
        case .invalidApplicationPreferences:
            AppL10n.preferencesBackup(
                "preferencesBackup.error.invalidApplicationPreferences",
                defaultValue: "备份中的应用偏好设置无效。"
            )
        case let .fileTooLarge(maximumBytes):
            AppL10n.preferencesBackupFormat(
                "preferencesBackup.error.fileTooLarge",
                defaultValue: "偏好设置备份不能超过 %d MB。",
                maximumBytes / (1024 * 1024)
            )
        case nil:
            error.localizedDescription
        }
    }
}

struct PreferencesPluginOption: Identifiable, Equatable {
    let id: String
    let title: String
}

enum PreferencesBackupStatusFormatter {
    static func relativeDate(
        _ date: Date,
        relativeTo referenceDate: Date,
        locale: Locale,
        justNow: String
    ) -> String {
        guard referenceDate.timeIntervalSince(date) >= 60 else {
            return justNow
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }

    static func absoluteDate(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func byteCount(_ count: Int, locale: Locale) -> String {
        Int64(count).formatted(
            ByteCountFormatStyle(style: .file).locale(locale)
        )
    }
}

private struct PreferencesExportSelectionSheet: View {
    @Binding var selection: PreferencesBackupSelection
    let pluginOptions: [PreferencesPluginOption]
    let deviceLocalAutomationRuleCount: Int
    let onCancel: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppL10n.preferencesBackup(
                "preferencesBackup.exportSelection.title",
                defaultValue: "选择要导出的偏好设置"
            ))
            .font(PluginSettingsTheme.Typography.pageTitle)

            Text(AppL10n.preferencesBackup(
                "preferencesBackup.selection.description",
                defaultValue: "仅导出所选类别。导入时还可以再次选择要恢复的内容。"
            ))
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)

            PreferencesSelectionFields(
                selection: $selection,
                pluginOptions: pluginOptions
            )

            if selection.includesAutomation, deviceLocalAutomationRuleCount > 0 {
                Label {
                    Text(AppL10n.preferencesBackupFormat(
                        "preferencesBackup.exportSelection.deviceLocalRulesOmitted",
                        defaultValue: "%d 条绑定到此 Mac 显示器的自动化规则不会导出。",
                        deviceLocalAutomationRuleCount
                    ))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(AppL10n.settings("common.cancel", defaultValue: "取消"), action: onCancel)
                    .buttonStyle(.bordered)
                Button(AppL10n.preferencesBackup(
                    "preferencesBackup.exportSelection.confirm",
                    defaultValue: "继续导出…"
                ), action: onExport)
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct PreferencesSelectionFields: View {
    @Binding var selection: PreferencesBackupSelection
    let pluginOptions: [PreferencesPluginOption]
    var availableSelection: PreferencesBackupSelection? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            selectionRow(
                title: AppL10n.preferencesBackup(
                    "preferencesBackup.preview.application",
                    defaultValue: "应用偏好"
                ),
                description: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.application.description",
                    defaultValue: "外观、语言和菜单栏点击方式；不包含权限、登录项或凭证。"
                ),
                isOn: $selection.includesApplicationPreferences,
                isAvailable: availableSelection?.includesApplicationPreferences ?? true
            )
            selectionRow(
                title: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.pluginLayout",
                    defaultValue: "插件布局与可见性"
                ),
                description: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.pluginLayout.description",
                    defaultValue: "恢复仪表盘和功能面板中的插件顺序与可见性；缺失插件需要另外安装。"
                ),
                isOn: $selection.includesPluginLayout,
                isAvailable: availableSelection?.includesPluginLayout ?? true
            )
            selectionRow(
                title: AppL10n.preferencesBackup(
                    "preferencesBackup.preview.shortcuts",
                    defaultValue: "快捷键"
                ),
                description: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.shortcuts.description",
                    defaultValue: "恢复应用和操作快捷键；插件操作还需要对应插件及其设置。"
                ),
                isOn: $selection.includesShortcuts,
                isAvailable: availableSelection?.includesShortcuts ?? true
            )
            selectionRow(
                title: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.automation",
                    defaultValue: "工作流与自动化规则"
                ),
                description: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.automation.description",
                    defaultValue: "保留工作流标识和直接 Run Link；工作流步骤仍需要对应插件及其设置。"
                ),
                isOn: $selection.includesAutomation,
                isAvailable: availableSelection?.includesAutomation ?? true
            )
            selectionRow(
                title: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.runLinks",
                    defaultValue: "已保存的 Run Link"
                ),
                description: AppL10n.preferencesBackup(
                    "preferencesBackup.selection.runLinks.description",
                    defaultValue: "参数化操作的已保存链接；工作流链接随“工作流与自动化规则”一起恢复。"
                ),
                isOn: $selection.includesRunLinks,
                isAvailable: availableSelection?.includesRunLinks ?? true
            )

            if !pluginOptions.isEmpty {
                Divider()
                Text(AppL10n.preferencesBackup(
                    "preferencesBackup.preview.plugins",
                    defaultValue: "插件设置"
                ))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(AppL10n.preferencesBackup(
                    "preferencesBackup.selection.plugins.description",
                    defaultValue: "仅包含插件声明为可移植的设置。脚本文本等敏感内容仍需在对应插件中单独允许备份。"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(pluginOptions) { plugin in
                    Toggle(plugin.title, isOn: pluginSelectionBinding(plugin.id))
                        .toggleStyle(.checkbox)
                        .padding(.leading, 18)
                        .disabled(
                            availableSelection.map {
                                !$0.pluginPreferenceIDs.contains(plugin.id)
                            } ?? false
                        )
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(PluginSettingsTheme.Typography.rowTitle)
        .padding(16)
        .pluginSettingsCardBackground(.standard)
    }

    private func selectionRow(
        title: String,
        description: String,
        isOn: Binding<Bool>,
        isAvailable: Bool
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!isAvailable)
    }

    private func pluginSelectionBinding(_ pluginID: String) -> Binding<Bool> {
        Binding {
            selection.pluginPreferenceIDs.contains(pluginID)
        } set: { selected in
            if selected {
                selection.pluginPreferenceIDs.insert(pluginID)
            } else {
                selection.pluginPreferenceIDs.remove(pluginID)
            }
        }
    }
}

enum PreferencesBackupExportFileName {
    static func make(date: Date = .now, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "MacTools Preferences \(formatter.string(from: date)).json"
    }
}

struct PreferencesImportSelectionModel: Equatable {
    var selectedInstallablePluginIDs: Set<String>
    var userDeselectedPluginIDs: Set<String>

    init(eligiblePluginIDs: Set<String> = []) {
        self.selectedInstallablePluginIDs = eligiblePluginIDs
        self.userDeselectedPluginIDs = []
    }

    mutating func selectAll(eligiblePluginIDs: Set<String>) {
        userDeselectedPluginIDs.subtract(eligiblePluginIDs)
        selectedInstallablePluginIDs = eligiblePluginIDs
    }

    mutating func deselectAll(eligiblePluginIDs: Set<String>) {
        userDeselectedPluginIDs.formUnion(eligiblePluginIDs)
        selectedInstallablePluginIDs.removeAll()
    }

    mutating func setPluginSelected(_ pluginID: String, isSelected: Bool) {
        if isSelected {
            selectedInstallablePluginIDs.insert(pluginID)
            userDeselectedPluginIDs.remove(pluginID)
        } else {
            selectedInstallablePluginIDs.remove(pluginID)
            userDeselectedPluginIDs.insert(pluginID)
        }
    }

    mutating func updateEligiblePlugins(_ eligiblePluginIDs: Set<String>) {
        selectedInstallablePluginIDs = eligiblePluginIDs.subtracting(userDeselectedPluginIDs)
    }
}

struct PreferencesImportPreviewSheet: View {
    let preview: PreferencesImportPreview
    let previewProvider: (PreferencesBackupSelection) throws -> PreferencesImportPreview
    let pluginOptions: [PreferencesPluginOption]
    let isImporting: Bool
    let importProgress: PreferencesImportProgress?
    let onCancel: () -> Void
    let onImport: (Set<String>, PreferencesBackupSelection) -> Void
    @State var selectionModel: PreferencesImportSelectionModel
    @State private var selection: PreferencesBackupSelection
    @State private var currentPreview: PreferencesImportPreview
    @State private var previewErrorMessage: String?

    var selectedInstallablePluginIDs: Set<String> {
        selectionModel.selectedInstallablePluginIDs
    }

    var userDeselectedPluginIDs: Set<String> {
        selectionModel.userDeselectedPluginIDs
    }

    init(
        preview: PreferencesImportPreview,
        previewProvider: @escaping (PreferencesBackupSelection) throws -> PreferencesImportPreview,
        pluginOptions: [PreferencesPluginOption],
        isImporting: Bool,
        importProgress: PreferencesImportProgress? = nil,
        onCancel: @escaping () -> Void,
        onImport: @escaping (Set<String>, PreferencesBackupSelection) -> Void
    ) {
        self.preview = preview
        self.previewProvider = previewProvider
        self.pluginOptions = pluginOptions
        self.isImporting = isImporting
        self.importProgress = importProgress
        self.onCancel = onCancel
        self.onImport = onImport
        var availableSelection = preview.selection
        availableSelection.pluginPreferenceIDs.formIntersection(pluginOptions.map(\.id))
        _selection = State(initialValue: availableSelection)
        let initialPreview: PreferencesImportPreview
        var errorMessage: String? = nil
        do {
            initialPreview = try previewProvider(availableSelection)
        } catch {
            initialPreview = preview
            errorMessage = error.localizedDescription
        }
        _currentPreview = State(initialValue: initialPreview)
        _selectionModel = State(initialValue: PreferencesImportSelectionModel(
            eligiblePluginIDs: Set(initialPreview.installableMissingPluginIDs)
        ))
        _previewErrorMessage = State(initialValue: errorMessage)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                previewContent
                    .padding(24)
            }

            if isImporting, let importProgress {
                importProgressView(importProgress)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button(AppL10n.settings("common.cancel", defaultValue: "取消"), action: onCancel)
                    .buttonStyle(.bordered)
                    .disabled(isImporting)
                Button(confirmTitle) {
                    onImport(selectedInstallablePluginIDs, selection)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting || selection.isEmpty || previewErrorMessage != nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 500, height: 640)
        .onChange(of: selection) { _, selection in
            refreshPreview(for: selection)
        }
    }

    private func importProgressView(_ progress: PreferencesImportProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text(importProgressTitle(progress))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    .lineLimit(1)
            }

            ProgressView(
                value: Double(progress.completedUnitCount),
                total: Double(progress.totalUnitCount)
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
    }

    private func importProgressTitle(_ progress: PreferencesImportProgress) -> String {
        switch progress {
        case .preparing:
            return AppL10n.preferencesBackup(
                "preferencesBackup.importProgress.preparing",
                defaultValue: "正在准备导入…"
            )
        case let .installingPlugin(id, number, total):
            let title = currentPreview.installablePlugins.first(where: { $0.id == id })?.title ?? id
            return AppL10n.preferencesBackupFormat(
                "preferencesBackup.importProgress.installing",
                defaultValue: "正在安装 %@（%d/%d）…",
                title,
                number,
                total
            )
        case .restoringPreferences:
            return AppL10n.preferencesBackup(
                "preferencesBackup.importProgress.restoring",
                defaultValue: "正在应用偏好设置…"
            )
        }
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppL10n.preferencesBackup("preferencesBackup.preview.title", defaultValue: "导入偏好设置"))
                .font(PluginSettingsTheme.Typography.pageTitle)

            Text(previewDescription)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PreferencesSelectionFields(
                selection: $selection,
                pluginOptions: pluginOptions,
                availableSelection: preview.selection
            )

            if let previewErrorMessage {
                Text(previewErrorMessage)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
            }

            Text(AppL10n.preferencesBackup(
                "preferencesBackup.preview.replaceNotice",
                defaultValue: "将替换以上偏好类别；备份中未包含的设置会恢复为默认值。"
            ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !currentPreview.installablePlugins.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(AppL10n.preferencesBackup(
                            "preferencesBackup.preview.installablePlugins",
                            defaultValue: "可安装的缺失插件"
                        ))
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                        Spacer()

                        Text(pluginsSelectedCountSummary)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }

                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.preview.installablePluginsDescription",
                        defaultValue: "仅会从已验证的插件列表下载你选中的插件。"
                    ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button(AppL10n.preferencesBackup(
                            "preferencesBackup.preview.selectAllMissingPlugins",
                            defaultValue: "全选缺失插件"
                        )) {
                            selectionModel.selectAll(eligiblePluginIDs: Set(currentPreview.installableMissingPluginIDs))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isImporting || selectedInstallablePluginIDs.count == currentPreview.installablePlugins.count)

                        Button(AppL10n.preferencesBackup(
                            "preferencesBackup.preview.deselectAll",
                            defaultValue: "全不选"
                        )) {
                            selectionModel.deselectAll(eligiblePluginIDs: Set(currentPreview.installableMissingPluginIDs))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isImporting || selectedInstallablePluginIDs.isEmpty)
                    }

                    ForEach(currentPreview.installablePlugins) { plugin in
                        Toggle(isOn: installationSelectionBinding(for: plugin.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plugin.title)
                                    .font(PluginSettingsTheme.Typography.rowTitle)

                                Text("\(plugin.version) · \(plugin.summary ?? plugin.id)")
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(isImporting)
                    }
                }
            }

            if !currentPreview.unavailablePluginIDs.isEmpty
                || !currentPreview.unavailableShortcutIDs.isEmpty
                || !currentPreview.unavailableActionReferences.isEmpty {
                Text(AppL10n.preferencesBackupFormat(
                    "preferencesBackup.preview.skipped",
                    defaultValue: "将跳过 %d 个本机不可用的插件设置、%d 项快捷键和 %d 个不可用或不可移植的操作；不会安装缺失插件。",
                    currentPreview.unavailablePluginIDs.count,
                    currentPreview.unavailableShortcutIDs.count,
                    currentPreview.unavailableActionReferences.count
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }

            if !currentPreview.retainedUnavailableActionReferences.isEmpty {
                Text(AppL10n.preferencesBackupFormat(
                    "preferencesBackup.preview.retainedUnavailableActions",
                    defaultValue: "将保留 %d 个当前不可用的操作；对应插件恢复后可继续使用。",
                    currentPreview.retainedUnavailableActionReferences.count
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var confirmTitle: String {
        Self.confirmTitle(selectedCount: selectedInstallablePluginIDs.count)
    }

    var previewDescription: String {
        Self.previewDescription(selectedCount: selectedInstallablePluginIDs.count)
    }

    var pluginsSelectedCountSummary: String {
        Self.pluginsSelectedCountSummary(
            selectedCount: selectedInstallablePluginIDs.count,
            totalCount: currentPreview.installablePlugins.count
        )
    }

    static func confirmTitle(selectedCount: Int) -> String {
        if selectedCount == 0 {
            return AppL10n.preferencesBackup("preferencesBackup.preview.confirm", defaultValue: "导入")
        }

        return AppL10n.preferencesBackupPluralFormat(
            "preferencesBackup.preview.installAndImportCount",
            defaultValue: "安装 %d 个插件并导入",
            count: selectedCount
        )
    }

    static func previewDescription(selectedCount: Int) -> String {
        if selectedCount == 0 {
            return AppL10n.preferencesBackup(
                "preferencesBackup.preview.description",
                defaultValue: "请确认以下更改。导入不会安装插件，也不会修改权限、缓存、Keychain 密钥或插件私有数据。"
            )
        }

        return AppL10n.preferencesBackupPluralFormat(
            "preferencesBackup.preview.descriptionWithInstall",
            defaultValue: "请确认以下更改。导入将自动安装 %d 个选中的缺失插件；不会修改权限、缓存、Keychain 密钥或插件私有数据。",
            count: selectedCount
        )
    }

    static func pluginsSelectedCountSummary(selectedCount: Int, totalCount: Int) -> String {
        AppL10n.preferencesBackupFormat(
            "preferencesBackup.preview.selectedPluginsSummary",
            defaultValue: "已选 %d / %d 个插件",
            selectedCount,
            totalCount
        )
    }

    private func installationSelectionBinding(for pluginID: String) -> Binding<Bool> {
        Binding {
            selectionModel.selectedInstallablePluginIDs.contains(pluginID)
        } set: { isSelected in
            selectionModel.setPluginSelected(pluginID, isSelected: isSelected)
        }
    }

    private func refreshPreview(for selection: PreferencesBackupSelection) {
        do {
            let refreshed = try previewProvider(selection)
            currentPreview = refreshed
            selectionModel.updateEligiblePlugins(Set(refreshed.installableMissingPluginIDs))
            previewErrorMessage = nil
        } catch {
            previewErrorMessage = error.localizedDescription
            selectionModel.deselectAll(eligiblePluginIDs: [])
        }
    }
}
private struct AppearanceSettingsRow: View {
    @Binding var selectionRawValue: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                icon
                summary.frame(minWidth: 220, idealWidth: 280, maxWidth: .infinity)
                appearancePicker
            }

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                    icon
                    summary
                }

                appearancePicker
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .help(AppL10n.settings("appearance.help", defaultValue: "设置应用外观"))
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))

            Image(systemName: "circle.lefthalf.filled")
                .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppL10n.settings("appearance.title", defaultValue: "应用外观"))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

            Text(AppL10n.settings("appearance.description", defaultValue: "自动跟随系统，也可以固定为深色或浅色。"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appearancePicker: some View {
        Picker(AppL10n.settings("appearance.picker", defaultValue: "外观"), selection: $selectionRawValue) {
            ForEach(AppAppearancePreference.allCases) { preference in
                Text(preference.title)
                    .tag(preference.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct FloatingPanelAppearanceSettingsRow: View {
    @Binding var selectionRawValue: String

    private var selection: PluginFloatingPanelAppearance {
        PluginFloatingPanelAppearance(rawValue: selectionRawValue) ?? .system
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                icon
                summary.frame(minWidth: 220, idealWidth: 280, maxWidth: .infinity)
                appearanceControls
            }

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                    icon
                    summary
                }

                appearanceControls
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: GeneralSettingsCardLayout.minRowHeight,
            alignment: .leading
        )
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .help(AppL10n.settings(
            "floatingPanelAppearance.help",
            defaultValue: "设置浮动面板和提示的背景外观"
        ))
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: GeneralSettingsCardLayout.iconCornerRadius,
                style: .continuous
            )
            .fill(Color.accentColor.opacity(0.12))

            Image(systemName: "rectangle.on.rectangle")
                .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(
            width: GeneralSettingsCardLayout.iconSize,
            height: GeneralSettingsCardLayout.iconSize
        )
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppL10n.settings(
                "floatingPanelAppearance.title",
                defaultValue: "浮动面板外观"
            ))
            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

            Text(AppL10n.settings(
                "floatingPanelAppearance.description",
                defaultValue: "跟随 macOS 的透明效果，或使用不透明的实色背景；启用“降低透明度”时始终使用实色。"
            ))
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appearanceControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                FloatingPanelAppearancePreview(appearance: selection)
                appearancePicker
            }

            VStack(alignment: .trailing, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                FloatingPanelAppearancePreview(appearance: selection)
                appearancePicker
            }
        }
    }

    private var appearancePicker: some View {
        Picker(
            AppL10n.settings(
                "floatingPanelAppearance.picker",
                defaultValue: "浮动面板外观"
            ),
            selection: $selectionRawValue
        ) {
            ForEach(PluginFloatingPanelAppearance.allCases) { preference in
                Text(preference.title).tag(preference.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct FloatingPanelAppearancePreview: View {
    let appearance: PluginFloatingPanelAppearance

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.55), Color.orange.opacity(0.42)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 11, weight: .medium))
                Text("ABC")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                PluginFloatingPanelSurface(
                    shape: .roundedRectangle(cornerRadius: 9),
                    appearance: appearance
                )
            }
        }
        .frame(width: 104, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

private struct LanguageSettingsRow: View {
    @Binding var selectionRawValue: String

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: "globe")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.settings("language.title", defaultValue: "语言"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(AppL10n.settings("language.description", defaultValue: "默认跟随系统语言，也可以固定为指定语言。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker(AppL10n.settings("language.picker", defaultValue: "语言"), selection: $selectionRawValue) {
                ForEach(AppLanguagePreference.allCases) { preference in
                    Text(preference.pickerTitle)
                        .tag(preference.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 360, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .help(AppL10n.settings("language.help", defaultValue: "设置应用语言"))
    }
}

private struct LaunchAtLoginSettingsRow: View {
    @ObservedObject var controller: LaunchAtLoginController
    @State private var toggleID = UUID()

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: "power")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.settings("launchAtLogin.title", defaultValue: "开机时启动"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(subtitle)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(controller.lastErrorMessage == nil ? .secondary : Color.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(AppL10n.settings("launchAtLogin.toggle", defaultValue: "开机时启动 MacTools"), isOn: enabledBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .id(toggleID)
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .help(AppL10n.settings("launchAtLogin.help", defaultValue: "登录系统时自动启动 MacTools 并显示在菜单栏。"))
        .onAppear {
            DispatchQueue.main.async {
                toggleID = UUID()
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding {
            controller.isEnabled
        } set: { newValue in
            controller.setEnabled(newValue)
        }
    }

    private var subtitle: String {
        controller.lastErrorMessage ?? AppL10n.settings("launchAtLogin.description", defaultValue: "登录系统时自动启动 MacTools 并显示在菜单栏。")
    }
}

private struct SettingsSidebarSearchLauncher: NSViewRepresentable {
    let prompt: String
    let onActivate: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onActivate: onActivate)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = SearchLauncherField()
        field.target = context.coordinator
        field.action = #selector(Coordinator.activate(_:))
        field.isEditable = false
        field.isSelectable = false
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        configure(field)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.onActivate = onActivate
        configure(field)
    }

    private func configure(_ field: NSSearchField) {
        field.placeholderString = prompt
        field.stringValue = ""
        field.toolTip = prompt
        field.setAccessibilityLabel(prompt)
    }

    final class Coordinator: NSObject {
        var onActivate: () -> Void

        init(onActivate: @escaping () -> Void) {
            self.onActivate = onActivate
        }

        @objc func activate(_ sender: Any?) {
            onActivate()
        }
    }

    private final class SearchLauncherField: NSSearchField {
        override var acceptsFirstResponder: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            sendAction(action, to: target)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}

private enum SettingsSidebarAccessoryLayout {
    static let width: CGFloat = 40
    static let sectionHeaderTrailingInset: CGFloat = 8
}

enum SettingsSidebarCommandHintPolicy {
    static let revealDelay: TimeInterval = 0.15

    static func commandIsHeld(in modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
    }
}

@MainActor
private final class SettingsSidebarCommandHintMonitor: ObservableObject {
    @Published private(set) var showsHints = false

    private var localEventMonitor: Any?
    private var applicationDeactivationObserver: NSObjectProtocol?
    private var pendingReveal: DispatchWorkItem?

    func start() {
        guard localEventMonitor == nil else { return }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleModifierFlags(event.modifierFlags)
            }
            return event
        }
        applicationDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hideHints()
            }
        }
    }

    func stop() {
        pendingReveal?.cancel()
        pendingReveal = nil
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let applicationDeactivationObserver {
            NotificationCenter.default.removeObserver(applicationDeactivationObserver)
            self.applicationDeactivationObserver = nil
        }
        showsHints = false
    }

    private func handleModifierFlags(_ modifierFlags: NSEvent.ModifierFlags) {
        guard SettingsSidebarCommandHintPolicy.commandIsHeld(in: modifierFlags) else {
            hideHints()
            return
        }
        guard !showsHints, pendingReveal == nil else { return }

        let reveal = DispatchWorkItem { [weak self] in
            self?.pendingReveal = nil
            self?.showsHints = true
        }
        pendingReveal = reveal
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SettingsSidebarCommandHintPolicy.revealDelay,
            execute: reveal
        )
    }

    private func hideHints() {
        pendingReveal?.cancel()
        pendingReveal = nil
        showsHints = false
    }
}

private struct SettingsSidebarShowsNumberShortcutHintsKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var settingsSidebarShowsNumberShortcutHints: Bool {
        get { self[SettingsSidebarShowsNumberShortcutHintsKey.self] }
        set { self[SettingsSidebarShowsNumberShortcutHintsKey.self] = newValue }
    }
}

private struct SettingsSidebarShortcutLabel: View {
    enum Style {
        case plain
        case badge
    }

    let shortcut: String
    var style: Style = .plain
    @Environment(\.settingsSidebarShowsNumberShortcutHints) private var showsNumberHints

    var body: some View {
        Group {
            switch style {
            case .plain:
                shortcutText
            case .badge:
                shortcutText
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.12))
                    )
            }
        }
        .frame(
            width: SettingsSidebarAccessoryLayout.width,
            alignment: .trailing
        )
        .opacity(isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isVisible)
        .accessibilityHidden(true)
    }

    private var isVisible: Bool {
        switch style {
        case .plain:
            showsNumberHints
        case .badge:
            true
        }
    }

    private var shortcutText: some View {
        Text(shortcut)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

private struct SettingsSidebar: View {
    private enum Layout {
        static let searchSectionSpacing = PluginSettingsTheme.Spacing.sectionHeaderContent
    }

    let configurationItems: [SettingsPluginNavigationItem]
    let orderedDestinations: [SettingsNavigationDestination]
    @ObservedObject var sidebarPreferences: SettingsSidebarPreferencesStore
    @Binding var selection: SettingsNavigationDestination
    let selectionRevealRequestID: UInt
    let focusRequestID: UInt
    let numberShortcutRequest: SidebarNumberShortcutRequest?
    let moveShortcutRequest: SidebarMoveShortcutRequest?
    let onSearch: () -> Void
    @State private var highlightedCollapsedSection: SettingsSidebarSection?
    @StateObject private var commandHintMonitor = SettingsSidebarCommandHintMonitor()
    @AccessibilityFocusState private var accessibilityFocusedCollapsedSection: SettingsSidebarSection?
    @FocusState private var isListFocused: Bool

    var body: some View {
        let configurationItemsByID = Dictionary(uniqueKeysWithValues: configurationItems.map { ($0.id, $0) })
        let shortcutNumbers = Dictionary(uniqueKeysWithValues: effectiveNumberTargets.enumerated().map {
            ($0.element, $0.offset + 1)
        })
        return VStack(spacing: 0) {
            SettingsSidebarSearchLauncher(
                prompt: AppL10n.search("search.title", defaultValue: "搜索 MacTools"),
                onActivate: onSearch
            )
            .frame(height: 30)
            .overlay(alignment: .trailing) {
                SettingsSidebarShortcutLabel(shortcut: "⌘K", style: .badge)
                    .padding(.trailing, 14)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, Layout.searchSectionSpacing)

            ScrollViewReader { proxy in
                List(selection: optionalSelectionBinding) {
                    Section {
                        if sidebarPreferences.isAppSectionExpanded {
                            ForEach(appDestinations, id: \.self) { destination in
                                sidebarRow(
                                    for: destination,
                                    configurationItemsByID: configurationItemsByID,
                                    shortcutNumbers: shortcutNumbers
                                )
                            }
                        }
                    } header: {
                        disclosureSectionHeader(
                            title: "MacTools",
                            section: .app
                        )
                    }

                    Section {
                        if sidebarPreferences.isCustomizeSectionExpanded {
                            ForEach(primaryPluginDestinations, id: \.self) { destination in
                                sidebarRow(
                                    for: destination,
                                    configurationItemsByID: configurationItemsByID,
                                    shortcutNumbers: shortcutNumbers
                                )
                            }
                        }
                    } header: {
                        disclosureSectionHeader(
                            title: customizeSectionTitle,
                            section: .customize
                        )
                    }

                    Section {
                        if sidebarPreferences.isPluginSettingsSectionExpanded {
                            if configurationDestinations.isEmpty {
                                Text(emptyConfigurationsText)
                                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(configurationDestinations, id: \.self) { destination in
                                    sidebarRow(
                                        for: destination,
                                        configurationItemsByID: configurationItemsByID,
                                        shortcutNumbers: shortcutNumbers
                                    )
                                }
                                .onMove(perform: moveConfigurations)
                            }
                        }
                    } header: {
                        configurationSectionHeader
                    }
                }
                .listStyle(.sidebar)
                .focused($isListFocused)
                .onChange(of: selection) { _, destination in
                    highlightedCollapsedSection = nil
                    reveal(destination, using: proxy)
                }
                .onChange(of: selectionRevealRequestID) {
                    reveal(selection, using: proxy)
                }
                .task(id: focusRequestID) {
                    guard focusRequestID > 0 else { return }
                    await Task.yield()
                    isListFocused = true
                }
                .onChange(of: numberShortcutRequest) { _, request in
                    guard let request else { return }
                    performNumberShortcut(request.number)
                }
                .onChange(of: moveShortcutRequest) { _, request in
                    guard let request else { return }
                    performMoveShortcut(request.direction)
                }
                .onChange(of: highlightedCollapsedSection) { _, section in
                    accessibilityFocusedCollapsedSection = section
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(AppL10n.settings(
                    "settings.sidebar.accessibilityLabel",
                    defaultValue: "设置导航"
                ))
                .accessibilityHint(configurationDestinations.isEmpty ? emptyConfigurationsText : "")
            }
        }
        .environment(
            \.settingsSidebarShowsNumberShortcutHints,
            commandHintMonitor.showsHints
        )
        .onAppear {
            commandHintMonitor.start()
        }
        .onDisappear {
            commandHintMonitor.stop()
        }
    }

    private var emptyConfigurationsText: String {
        AppL10n.settings(
            "plugins.sidebar.emptyConfigurations",
            defaultValue: "暂无可设置插件"
        )
    }

    private var customizeSectionTitle: String {
        AppL10n.settings(
            "settings.sidebar.customizeSection",
            defaultValue: "自定义"
        )
    }

    private var configurationOrderItems: [SettingsSidebarPluginOrderItem] {
        configurationItems.map {
            SettingsSidebarPluginOrderItem(
                id: $0.id,
                title: $0.title,
                installedAt: $0.installedAt
            )
        }
    }

    private var appDestinations: [SettingsNavigationDestination] {
        orderedDestinations.filter {
            switch $0 {
            case .general, .permissions, .about:
                true
            case .plugins, .marketplaceDetail:
                false
            }
        }
    }

    private var primaryPluginDestinations: [SettingsNavigationDestination] {
        orderedDestinations.filter {
            guard case let .plugins(pane) = $0 else {
                return false
            }
            if case .configuration = pane {
                return false
            }
            return true
        }
    }

    private var configurationDestinations: [SettingsNavigationDestination] {
        orderedDestinations.filter {
            guard case let .plugins(pane) = $0 else {
                return false
            }
            if case .configuration = pane {
                return true
            }
            return false
        }
    }

    private func sidebarRow(
        for destination: SettingsNavigationDestination,
        configurationItemsByID: [String: SettingsPluginNavigationItem],
        shortcutNumbers: [SettingsSidebarNumberTarget: Int]
    ) -> some View {
        let item: SettingsPluginNavigationItem? = if case let .plugins(.configuration(pluginID)) = destination {
            configurationItemsByID[pluginID]
        } else {
            nil
        }
        let title = item?.title ?? settingsNavigationTitle(for: destination, configurationItems: [])
        let shortcutNumber = shortcutNumbers[.destination(destination)]

        // Keep one explicit row per destination so List can collect IDs without building every label.
        return HStack(spacing: 0) {
            switch destination {
            case .general:
                SettingsSidebarRow(title: title, systemImage: "gearshape", iconTint: .gray, shortcutNumber: shortcutNumber)
            case .permissions:
                SettingsSidebarRow(title: title, systemImage: "lock.shield", iconTint: .teal, shortcutNumber: shortcutNumber)
            case .about:
                SettingsSidebarRow(title: title, systemImage: "info.circle", iconTint: .blue, shortcutNumber: shortcutNumber)
            case .plugins(.actionsAndShortcuts):
                SettingsSidebarRow(title: title, systemImage: "command", iconTint: .orange, shortcutNumber: shortcutNumber)
            case .plugins(.automation):
                SettingsSidebarRow(title: title, systemImage: "bolt.horizontal.circle", iconTint: .indigo, shortcutNumber: shortcutNumber)
            case .plugins(.marketplace):
                SettingsSidebarRow(title: title, systemImage: "shippingbox", iconTint: .blue, shortcutNumber: shortcutNumber)
            case .plugins(.configuration):
                if let item {
                    SettingsSidebarRow(
                        title: title,
                        systemImage: item.iconName,
                        iconTint: item.iconTint,
                        shortcutNumber: shortcutNumber
                    )
                }
            case .marketplaceDetail:
                EmptyView()
            }
        }
        .tag(destination)
        .id(destination)
    }

    private var configurationSectionHeader: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            disclosureSectionHeader(
                title: configurationSectionTitle,
                section: .pluginSettings
            )

            Spacer(minLength: 0)

            Menu {
                Picker(
                    AppL10n.settings(
                        "plugins.sidebar.configurationSection",
                        defaultValue: "插件设置"
                    ),
                    selection: configurationSortMode
                ) {
                    Section {
                        sortOption(.installedOldestFirst)
                        sortOption(.installedNewestFirst)
                    }

                    Section {
                        sortOption(.nameAscending)
                        sortOption(.nameDescending)
                    }

                    Section {
                        sortOption(.custom)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Divider()

                Button(AppL10n.settings(
                    "settings.sidebar.pluginSort.resetCustom",
                    defaultValue: "重置自定义顺序"
                )) {
                    sidebarPreferences.resetCustomOrder()
                }
                .disabled(sidebarPreferences.customOrderedPluginIDs.isEmpty)

                Divider()

                Button {} label: {
                    Label(
                        AppL10n.settings(
                            "settings.sidebar.pluginSort.scopeNote",
                            defaultValue: "仅影响设置侧边栏"
                        ),
                        systemImage: "info.circle"
                    )
                }
                .disabled(true)
            } label: {
                Color.clear
                    .frame(width: SettingsSidebarAccessoryLayout.width, height: 11)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .overlay(alignment: .trailing) {
                // Keep the visible symbol outside the native menu label's tinting.
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption2.weight(.medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(sectionHeaderForegroundColor(for: .pluginSettings))
                    .frame(width: 11, height: 11, alignment: .center)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .scaleEffect(0.80, anchor: .trailing)
            .padding(
                .trailing,
                SettingsSidebarAccessoryLayout.sectionHeaderTrailingInset
            )
            .accessibilityLabel(sidebarPreferences.sortMode.localizedTitle)
            .help(AppL10n.settings(
                "settings.sidebar.pluginSortHelp",
                defaultValue: "调整设置侧边栏中的插件页面顺序，不影响仪表盘或功能面板"
            ))
        }
    }

    private var configurationSortMode: Binding<SettingsSidebarPluginSortMode> {
        Binding {
            sidebarPreferences.sortMode
        } set: { sortMode in
            sidebarPreferences.setSortMode(
                sortMode,
                availableItems: configurationOrderItems
            )
        }
    }

    private func sortOption(_ sortMode: SettingsSidebarPluginSortMode) -> some View {
        Text(sortMode.localizedTitle)
            .tag(sortMode)
    }

    private var configurationSectionTitle: String {
        AppL10n.settings(
            "plugins.sidebar.configurationSection",
            defaultValue: "插件设置"
        )
    }

    private func sectionHeaderForegroundColor(for section: SettingsSidebarSection) -> Color {
        let containsSelection = !sectionIsExpanded(section) && selectedSection == section
        return containsSelection || highlightedCollapsedSection == section
            ? .primary
            : .secondary
    }

    private func disclosureSectionHeader(
        title: String,
        section: SettingsSidebarSection
    ) -> some View {
        let isExpanded = sectionIsExpanded(section)
        let shortcutNumber = effectiveNumberTargets.firstIndex(of: .collapsedSection(section))
            .map { $0 + 1 }
        let containsSelection = !isExpanded && selectedSection == section
        let isKeyboardHighlighted = highlightedCollapsedSection == section
        let isAccessibilitySelected = SettingsSidebarHeaderAccessibility.isSelected(
            containsSelection: containsSelection
        )
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                sidebarPreferences.setSection(section, expanded: !isExpanded)
            }
            highlightedCollapsedSection = nil
        } label: {
            HStack(spacing: 4) {
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: 3, height: 14)
                    .opacity(containsSelection ? 1 : 0)
                    .accessibilityHidden(true)

                Image(systemName: isExpanded
                    ? "chevron.down"
                    : "chevron.forward")
                    .font(.caption2.weight(.semibold))
                Text(title)
                    .fontWeight(containsSelection ? .semibold : .regular)
                Spacer(minLength: 4)
                if let shortcutNumber {
                    SettingsSidebarShortcutLabel(shortcut: "⌘\(shortcutNumber)")
                }
            }
            .foregroundStyle(sectionHeaderForegroundColor(for: section))
            .contentShape(Rectangle())
            .background {
                if isKeyboardHighlighted {
                    SettingsSidebarKeyboardCandidateBackground()
                        .padding(.horizontal, -4)
                        .padding(.vertical, -2)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(
            .trailing,
            SettingsSidebarAccessoryLayout.sectionHeaderTrailingInset
        )
        .accessibilityFocused($accessibilityFocusedCollapsedSection, equals: section)
        .help(disclosureTitle(title: title, isExpanded: isExpanded))
        .accessibilityLabel(title)
        .accessibilityHint(sectionAccessibilityHint(
            title: title,
            isExpanded: isExpanded,
            shortcutNumber: shortcutNumber
        ))
        .accessibilityAddTraits(isAccessibilitySelected ? .isSelected : [])
    }

    private var effectiveNumberTargets: [SettingsSidebarNumberTarget] {
        SettingsSidebarNumberingPolicy.targets(
            appDestinations: appDestinations,
            customizeDestinations: primaryPluginDestinations,
            pluginDestinations: configurationDestinations,
            appExpanded: sidebarPreferences.isAppSectionExpanded,
            customizeExpanded: sidebarPreferences.isCustomizeSectionExpanded,
            pluginSettingsExpanded: sidebarPreferences.isPluginSettingsSectionExpanded
        )
    }

    private var selectedSection: SettingsSidebarSection {
        switch selection.sidebarDestination {
        case .general, .permissions, .about:
            .app
        case .plugins(.configuration):
            .pluginSettings
        case .plugins, .marketplaceDetail:
            .customize
        }
    }

    private func sectionIsExpanded(_ section: SettingsSidebarSection) -> Bool {
        switch section {
        case .app:
            sidebarPreferences.isAppSectionExpanded
        case .customize:
            sidebarPreferences.isCustomizeSectionExpanded
        case .pluginSettings:
            sidebarPreferences.isPluginSettingsSectionExpanded
        }
    }

    private func performNumberShortcut(_ number: Int) {
        let index = number - 1
        guard effectiveNumberTargets.indices.contains(index) else { return }
        activate(effectiveNumberTargets[index])
    }

    private func performMoveShortcut(_ direction: SettingsSidebarMoveDirection) {
        let targets = SettingsSidebarNumberingPolicy.targets(
            appDestinations: appDestinations,
            customizeDestinations: primaryPluginDestinations,
            pluginDestinations: configurationDestinations,
            appExpanded: sidebarPreferences.isAppSectionExpanded,
            customizeExpanded: sidebarPreferences.isCustomizeSectionExpanded,
            pluginSettingsExpanded: sidebarPreferences.isPluginSettingsSectionExpanded,
            limit: nil
        )
        guard !targets.isEmpty else { return }
        let currentTarget: SettingsSidebarNumberTarget? = if let highlightedCollapsedSection {
            .collapsedSection(highlightedCollapsedSection)
        } else if sectionIsExpanded(selectedSection) {
            .destination(selection.sidebarDestination)
        } else {
            .collapsedSection(selectedSection)
        }
        guard let target = SettingsSidebarNumberingPolicy.movedTarget(
            from: currentTarget,
            direction: direction,
            in: targets
        ) else { return }
        activate(target, expandSection: false)
    }

    private func activate(
        _ target: SettingsSidebarNumberTarget,
        expandSection: Bool = true
    ) {
        switch target {
        case let .destination(destination):
            highlightedCollapsedSection = nil
            selection = destination
        case let .collapsedSection(section):
            if expandSection {
                sidebarPreferences.setSection(section, expanded: true)
                highlightedCollapsedSection = nil
            } else {
                highlightedCollapsedSection = section
            }
        }
    }

    private func sectionAccessibilityHint(
        title: String,
        isExpanded: Bool,
        shortcutNumber: Int?
    ) -> String {
        let action = disclosureTitle(title: title, isExpanded: isExpanded)
        guard let shortcutNumber else { return action }
        let shortcut = AppL10n.settingsFormat(
            "settings.sidebar.shortcutAccessibilityHint",
            defaultValue: "Keyboard shortcut: Command-%d",
            shortcutNumber
        )
        return "\(action). \(shortcut)"
    }

    private func disclosureTitle(title: String, isExpanded: Bool) -> String {
        if isExpanded {
            return AppL10n.settingsFormat(
                "settings.sidebar.section.collapseFormat",
                defaultValue: "收起%@",
                title
            )
        }
        return AppL10n.settingsFormat(
            "settings.sidebar.section.expandFormat",
            defaultValue: "展开%@",
            title
        )
    }

    private func reveal(
        _ destination: SettingsNavigationDestination,
        using proxy: ScrollViewProxy
    ) {
        let sidebarDestination = destination.sidebarDestination
        withAnimation(.easeInOut(duration: 0.15)) {
            switch destination {
            case .general, .permissions, .about:
                sidebarPreferences.setSection(.app, expanded: true)
            case .plugins(.configuration):
                sidebarPreferences.setSection(.pluginSettings, expanded: true)
            case .plugins, .marketplaceDetail:
                sidebarPreferences.setSection(.customize, expanded: true)
            }
        }

        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(sidebarDestination)
            }
        }
    }

    private func moveConfigurations(fromOffsets: IndexSet, toOffset: Int) {
        _ = sidebarPreferences.movePlugins(
            fromOffsets: fromOffsets,
            toOffset: toOffset,
            availableItems: configurationOrderItems
        )
    }

    private var optionalSelectionBinding: Binding<SettingsNavigationDestination?> {
        Binding(
            get: { selection },
            set: { newSelection in
                guard let newSelection else { return }

                guard newSelection != selection else {
                    return
                }

                // AppKit-backed sidebar lists write their selection while
                // SwiftUI is still updating the view hierarchy. Publish the
                // navigation change after the native list update completes.
                Task { @MainActor in
                    await Task.yield()
                    selection = newSelection
                }
            }
        )
    }
}

private struct SettingsSidebarColumn<Content: View>: View {
    private let content: Content
    @State private var headerHeight: CGFloat = 0

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // Keep the sidebar viewport tied to the window chrome instead of the
        // transient safe-area proposal from an in-window overlay.
        content
            .padding(.top, headerHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                SettingsWindowTopSafeAreaReader(topInset: $headerHeight)
                    .frame(width: 0, height: 0)
            }
            .ignoresSafeArea(.container, edges: .top)
    }
}

private struct SettingsDetailColumn<Content: View>: View {
    private let content: Content
    @State private var headerHeight: CGFloat = 0

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.top, headerHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if headerHeight > 0 {
                    SettingsStyle.contentBackground
                        .frame(height: headerHeight)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background {
                SettingsWindowTopSafeAreaReader(topInset: $headerHeight)
                    .frame(width: 0, height: 0)
            }
            .ignoresSafeArea(.container, edges: .top)
    }
}

private struct SettingsWindowTopSafeAreaReader: NSViewRepresentable {
    @Binding var topInset: CGFloat

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        configure(nsView)
        nsView.publishCurrentInset()
    }

    private func configure(_ view: ObserverView) {
        view.onTopInsetChange = { inset in
            guard topInset != inset else { return }
            topInset = inset
        }
    }

    final class ObserverView: NSView {
        var onTopInsetChange: ((CGFloat) -> Void)?
        private var lastPublishedInset: CGFloat = -1

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            publishCurrentInset()
        }

        override func layout() {
            super.layout()
            publishCurrentInset()
        }

        func publishCurrentInset() {
            let inset = window?.contentView?.safeAreaInsets.top ?? 0
            guard inset != lastPublishedInset else { return }
            lastPublishedInset = inset

            DispatchQueue.main.async { [weak self] in
                self?.onTopInsetChange?(inset)
            }
        }
    }
}

private struct SettingsDetailToolbarTitle: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @ObservedObject var coordinator: SettingsNavigationCoordinator
    @ObservedObject var presentation: SettingsNavigationPresentationModel
    @Binding var sidebarColumnWidth: CGFloat
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source

    var body: some View {
        // Native toolbar content can outlive the enclosing split-view update.
        let _ = runtimeLocale.revision
        let title = settingsNavigationTitle(
            for: coordinator.destination,
            configurationItems: presentation.configurationItems
        )
        let isHidden = coordinator.isUnifiedSearchPresented
        // RTL navigation items occupy the sidebar's narrower toolbar region.
        let columnWidth = layoutDirection == .rightToLeft
            ? sidebarColumnWidth
            : SettingsSplitViewLayout.detailMinWidth
        let maximumWidth = max(40, columnWidth - SettingsSplitViewLayout.navigationChromeWidth)

        Text(title)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: maximumWidth, alignment: .leading)
            .opacity(isHidden ? 0 : 1)
            .help(title)
            .accessibilityHidden(isHidden)
            .accessibilityIdentifier("mactools.settings.detail-title")
    }
}

private struct SettingsSidebarRow: View {
    private enum Layout {
        static let iconWidth: CGFloat = 14
    }

    let title: String
    let systemImage: String
    let iconTint: Color
    let shortcutNumber: Int?

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Label {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: PluginSystemImage.resolvedName(systemImage))
                    .font(PluginSettingsTheme.Typography.rowIcon)
                    .foregroundStyle(iconTint)
                    .frame(width: Layout.iconWidth)
            }

            Spacer(minLength: 0)

            if let shortcutNumber {
                SettingsSidebarShortcutLabel(shortcut: "⌘\(shortcutNumber)")
            }
        }
        .font(.body)
        .focusable(false)
        .help(title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint)
    }

    private var accessibilityHint: String {
        var hints: [String] = []
        if let shortcutNumber {
            hints.append(AppL10n.settingsFormat(
                "settings.sidebar.shortcutAccessibilityHint",
                defaultValue: "Keyboard shortcut: Command-%d",
                shortcutNumber
            ))
        }
        return hints.joined(separator: ". ")
    }
}

private struct SettingsSidebarKeyboardCandidateBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        Color(nsColor: .keyboardFocusIndicatorColor),
                        lineWidth: PluginSettingsTheme.Stroke.standard
                    )
            }
    }
}

private extension SettingsSidebarPluginSortMode {
    var localizedTitle: String {
        switch self {
        case .installedOldestFirst:
            AppL10n.settings(
                "settings.sidebar.pluginSort.installedOldestFirst",
                defaultValue: "安装时间：最早优先"
            )
        case .installedNewestFirst:
            AppL10n.settings(
                "settings.sidebar.pluginSort.installedNewestFirst",
                defaultValue: "安装时间：最新优先"
            )
        case .nameAscending:
            AppL10n.settings(
                "settings.sidebar.pluginSort.nameAscending",
                defaultValue: "名称：升序"
            )
        case .nameDescending:
            AppL10n.settings(
                "settings.sidebar.pluginSort.nameDescending",
                defaultValue: "名称：降序"
            )
        case .custom:
            AppL10n.settings(
                "settings.sidebar.pluginSort.custom",
                defaultValue: "自定义顺序"
            )
        }
    }

}

private struct SettingsDetailPane: View {
    let pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    let destination: SettingsNavigationDestination
    @ObservedObject var uninstallConfirmationSession: PluginUninstallConfirmationSession
    @ObservedObject var appUpdater: AppUpdater
    @ObservedObject var menuBarIconSettings: MenuBarIconSettings
    @ObservedObject var menuBarIconGallery: MenuBarIconGalleryLibrary
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @ObservedObject var menuBarPanelThemeStore: MenuBarPanelThemeStore
    let appearanceUserDefaults: UserDefaults

    @ViewBuilder
    var body: some View {
        switch destination {
        case .general:
            GeneralSettingsView(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                menuBarIconSettings: menuBarIconSettings,
                menuBarIconGallery: menuBarIconGallery,
                launchAtLoginController: launchAtLoginController,
                menuBarPanelThemeStore: menuBarPanelThemeStore,
                appearanceUserDefaults: appearanceUserDefaults
            )
        case .permissions:
            PermissionCenterSettingsView(
                coordinator: pluginHost.permissionCoordinator
            )
        case .about:
            AboutSettingsView(
                appUpdater: appUpdater,
                navigationCoordinator: navigationCoordinator
            )
        case let .plugins(pane):
            PluginSettingsDestinationPane(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                selectedPane: pane,
                uninstallConfirmationSession: uninstallConfirmationSession
            )
        case let .marketplaceDetail(target):
            MarketplacePluginDetailView(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                target: target
            )
        }
    }
}

private struct PluginSettingsDestinationPane: View {
    let pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    let selectedPane: FeatureSettingsPane
    @ObservedObject var uninstallConfirmationSession: PluginUninstallConfirmationSession

    var body: some View {
        detail
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedPane {
        case .actionsAndShortcuts:
            ActionShortcutSettingsView(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator
            )
        case .automation:
            AutomationSettingsView(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator
            )
        case .marketplace:
            PluginManagementSettingsView(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                uninstallConfirmationSession: uninstallConfirmationSession
            )
        case let .configuration(pluginID):
            PluginSettingsDetailPane(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                pluginID: pluginID
            )
        }
    }

}

struct PluginSettingsPageVisibilityTransition {
    struct Change: Equatable {
        let pluginID: String
        let isVisible: Bool
    }

    static func changes(from currentPluginID: String?, to pluginID: String?) -> [Change] {
        guard currentPluginID != pluginID else { return [] }
        return [
            currentPluginID.map { Change(pluginID: $0, isVisible: false) },
            pluginID.map { Change(pluginID: $0, isVisible: true) },
        ].compactMap { $0 }
    }
}

private struct PluginSettingsDetailPane: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    let pluginID: String
    private var item: PluginSettingsPageItem? {
        pluginHost.pluginSettingsItems.first { $0.id == pluginID }
    }
    @State private var activeSearchTarget: PluginSettingsSearchTarget?
    @State private var clearSearchTargetTask: Task<Void, Never>?
    @State private var visiblePluginID: String?

    var body: some View {
        Group {
            if let item {
                ScrollViewReader { proxy in
                    pageContent(item)
                        .environment(\.pluginSettingsSearchTarget, activeSearchTarget)
                        .onAppear {
                            applySearchRevealRequest(
                                navigationCoordinator.searchRevealRequest,
                                pluginID: item.pluginID,
                                proxy: proxy
                            )
                        }
                        .onChange(of: navigationCoordinator.searchRevealRequest) { _, request in
                            applySearchRevealRequest(
                                request,
                                pluginID: item.pluginID,
                                proxy: proxy
                            )
                        }
                }
            } else {
                ContentUnavailableView(
                    AppL10n.settings("plugins.configuration.empty.title", defaultValue: "暂无可配置插件"),
                    systemImage: "slider.horizontal.3",
                    description: Text(AppL10n.settings(
                        "plugins.configuration.empty.description",
                        defaultValue: "当插件提供权限、快捷键或自定义设置后，会显示在这里。"
                    ))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            transitionVisiblePlugin(to: item?.pluginID)
        }
        .onChange(of: item?.pluginID) { _, pluginID in
            transitionVisiblePlugin(to: pluginID)
        }
        .onDisappear {
            transitionVisiblePlugin(to: nil)
            clearSearchTargetTask?.cancel()
            clearSearchTargetTask = nil
            if let activeSearchTarget {
                navigationCoordinator.clearSearchRevealRequest(
                    matching: .plugin(activeSearchTarget)
                )
            }
            activeSearchTarget = nil
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
        ) { notification in
            guard notification.object is MacToolsCommandWindow else { return }
            // Refresh permissions when the settings window itself is revisited.
            // Global panels must not turn background settings into a full refresh.
            pluginHost.refreshAll()
        }
    }

    @ViewBuilder
    private func pageContent(_ item: PluginSettingsPageItem) -> some View {
        Group {
            switch item.layout {
            case .form:
                PluginFormPage(pluginHost: pluginHost, item: item)
            case .workspace:
                PluginWorkspacePage(pluginHost: pluginHost, item: item)
            }
        }
    }

    private func transitionVisiblePlugin(to pluginID: String?) {
        let changes = PluginSettingsPageVisibilityTransition.changes(
            from: visiblePluginID,
            to: pluginID
        )
        visiblePluginID = pluginID
        for change in changes {
            pluginHost.setPluginSettingsPage(change.pluginID, visible: change.isVisible)
        }
    }

    private func applySearchRevealRequest(
        _ request: SettingsSearchRevealRequest?,
        pluginID: String,
        proxy: ScrollViewProxy
    ) {
        guard
            let target = applySearchRevealRequest(request, pluginID: pluginID)
        else {
            return
        }

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target.scrollID, anchor: .center)
            }
        }
    }

    @discardableResult
    private func applySearchRevealRequest(
        _ request: SettingsSearchRevealRequest?,
        pluginID: String
    ) -> PluginSettingsSearchTarget? {
        guard
            let request,
            case let .plugin(target) = request.target,
            target.pluginID == pluginID
        else {
            return nil
        }

        clearSearchTargetTask?.cancel()
        activeSearchTarget = target
        clearSearchTargetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            activeSearchTarget = nil
            navigationCoordinator.clearSearchRevealRequest(request)
        }
        return target
    }
}

private struct PluginFormPage: View {
    @ObservedObject var pluginHost: PluginHost
    let item: PluginSettingsPageItem

    var body: some View {
        SettingsGroupedFormPageScaffold(introduction: item.introductionConfiguration) { widths in
            if !item.missingPermissionCards.isEmpty {
                Section {
                    ForEach(item.missingPermissionCards) { card in
                        PermissionSettingsRow(
                            card: card,
                            statusColor: statusColor(for: card.statusTone),
                            onAction: {
                                pluginHost.performPermissionAction(
                                    pluginID: card.pluginID,
                                    permissionID: card.permissionID,
                                    sourceFrame: permissionGuidanceSourceFrame(
                                        eventType: NSApp.currentEvent?.type,
                                        mouseLocation: NSEvent.mouseLocation
                                    )
                                )
                            }
                        )
                        .pluginSettingsSearchAnchor(
                            pluginID: card.pluginID,
                            entryID: card.id
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                        .listRowBackground(Color.orange.opacity(0.08))
                    }
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings(
                            "plugins.configuration.section.permissions",
                            defaultValue: "权限"
                        ),
                        systemImage: "exclamationmark.shield",
                        layoutWidth: widths.readableContent
                    )
                    .foregroundStyle(.orange)
                }
            }

            let inputItems = pluginHost.actionInputRegistry.items.filter {
                $0.id.providerID == item.pluginID && !$0.descriptor.aliases.isEmpty
            }
            if !inputItems.isEmpty {
                Section {
                    ForEach(inputItems) { input in
                        CommandPaletteAliasSettingsRow(pluginHost: pluginHost, item: input)
                            .settingsGroupedFormRowWidth(widths.sectionLayout)
                    }
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("actionInput.alias.section", defaultValue: "命令面板触发短语"),
                        systemImage: "text.cursor", layoutWidth: widths.readableContent
                    )
                }
            }

            ForEach(item.sections.filter(\.isVisible)) { section in
                PluginFormSection(
                    pluginHost: pluginHost,
                    pluginID: item.pluginID,
                    section: section,
                    shortcutItems: item.shortcutItems,
                    layoutWidths: widths
                )

                if let configuration = item.actionShortcutSettingsConfiguration,
                   configuration.placementAfterSectionID == section.id {
                    PluginActionShortcutFormSection(
                        pluginHost: pluginHost,
                        pluginID: item.pluginID,
                        configuration: configuration,
                        layoutWidths: widths
                    )
                }

                ForEach(item.standaloneShortcutSettingsGroups.filter {
                    $0.placementAfterSectionID == section.id
                }) { configuration in
                    PluginMixedShortcutFormSection(
                        pluginHost: pluginHost,
                        pluginID: item.pluginID,
                        configuration: configuration,
                        shortcutItems: item.shortcutItems,
                        definitionsFirst: item.shortcutDefinitionFirstSettingsGroupIDs.contains(configuration.id),
                        collapsesAllContent: item.collapsibleShortcutSettingsGroupIDs.contains(configuration.id),
                        collapsesActionContent: item.collapsibleActionSettingsGroupIDs.contains(configuration.id),
                        layoutWidths: widths
                    )
                }
            }

            if let configuration = item.actionShortcutSettingsConfiguration,
               configuration.placementAfterSectionID == nil
                   || !item.sections.contains(where: {
                       $0.isVisible && $0.id == configuration.placementAfterSectionID
                   }) {
                PluginActionShortcutFormSection(
                    pluginHost: pluginHost,
                    pluginID: item.pluginID,
                    configuration: configuration,
                    layoutWidths: widths
                )
            }

            ForEach(item.standaloneShortcutSettingsGroups.filter { configuration in
                configuration.placementAfterSectionID == nil
                    || !item.sections.contains(where: {
                        $0.isVisible && $0.id == configuration.placementAfterSectionID
                    })
            }) { configuration in
                PluginMixedShortcutFormSection(
                    pluginHost: pluginHost,
                    pluginID: item.pluginID,
                    configuration: configuration,
                    shortcutItems: item.shortcutItems,
                    definitionsFirst: item.shortcutDefinitionFirstSettingsGroupIDs.contains(configuration.id),
                    collapsesAllContent: item.collapsibleShortcutSettingsGroupIDs.contains(configuration.id),
                    collapsesActionContent: item.collapsibleActionSettingsGroupIDs.contains(configuration.id),
                    layoutWidths: widths
                )
            }

            if !item.remainingShortcutItems.isEmpty {
                Section {
                    PluginShortcutRowsContent(
                        pluginHost: pluginHost,
                        items: item.remainingShortcutItems
                    )
                    .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings(
                            "plugins.configuration.section.shortcuts",
                            defaultValue: "快捷键"
                        ),
                        systemImage: "command",
                        layoutWidth: widths.readableContent
                    )
                }
            }
        }
    }
}

private struct SettingsFullWidthDisclosure<Label: View, Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Binding var isExpanded: Bool
    private let label: Label
    private let content: Content

    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        _isExpanded = isExpanded
        self.content = content()
        self.label = label()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Button {
                if accessibilityReduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    label
                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded
                            ? (layoutDirection == .rightToLeft ? -90 : 90)
                            : 0))
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(AppL10n.settings(
                isExpanded
                    ? "plugins.configuration.disclosure.expanded"
                    : "plugins.configuration.disclosure.collapsed",
                defaultValue: isExpanded ? "Expanded" : "Collapsed"
            )))

            if isExpanded {
                content
                    .transition(accessibilityReduceMotion
                        ? .identity
                        : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct PluginMixedShortcutFormSection: View {
    @Environment(\.pluginSettingsSearchTarget) private var searchTarget
    @ObservedObject var pluginHost: PluginHost
    let pluginID: String
    let configuration: PluginShortcutSettingsGroupConfiguration
    let shortcutItems: [ShortcutSettingsItem]
    let definitionsFirst: Bool
    let collapsesAllContent: Bool
    let collapsesActionContent: Bool
    let layoutWidths: SettingsGroupedFormWidths
    @State private var isExpanded = false

    static func searchTarget(pluginID: String, groupID: String) -> PluginSettingsSearchTarget {
        PluginSettingsSearchTarget(pluginID: pluginID, entryID: groupID)
    }

    static func reveal(
        target: PluginSettingsSearchTarget?,
        pluginID: String,
        groupID: String,
        isExpanded: inout Bool
    ) {
        if target == searchTarget(pluginID: pluginID, groupID: groupID) {
            isExpanded = true
        }
    }

    private var matchingShortcutItems: [ShortcutSettingsItem] {
        let itemIDs = Set(configuration.shortcutDefinitionIDs.map {
            "\(pluginID).shortcut.\($0)"
        })
        return shortcutItems.filter { itemIDs.contains($0.id) }
    }

    var body: some View {
        Section {
            sectionContent
                .settingsGroupedFormRowWidth(layoutWidths.sectionLayout)
                .pluginSettingsSearchAnchor(
                    pluginID: pluginID,
                    entryID: Self.searchTarget(pluginID: pluginID, groupID: configuration.id).entryID
                )
                .onChange(of: searchTarget, initial: true) { _, target in
                    Self.reveal(target: target, pluginID: pluginID,
                                groupID: configuration.id, isExpanded: &isExpanded)
                }
        } header: {
            SettingsGroupedFormSectionHeader(
                title: configuration.title,
                systemImage: configuration.systemImage,
                layoutWidth: layoutWidths.readableContent
            )
        } footer: {
            if let description = configuration.description {
                Text(description)
                    .frame(width: layoutWidths.sectionLayout, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        if collapsesAllContent {
            SettingsFullWidthDisclosure(isExpanded: $isExpanded) {
                mixedRows
            } label: {
                Text(AppL10n.settings(
                    "plugins.configuration.shortcuts.show",
                    defaultValue: "Show Shortcuts"
                ))
                .font(PluginSettingsTheme.Typography.rowTitle)
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        } else {
            mixedRows
        }
    }

    @ViewBuilder
    private var mixedRows: some View {
        VStack(spacing: 0) {
            if definitionsFirst, !matchingShortcutItems.isEmpty {
                shortcutRows
            }
            if definitionsFirst,
               !matchingShortcutItems.isEmpty,
               !configuration.actionIDs.isEmpty {
                PluginSettingsListDivider()
            }
            if collapsesActionContent, !configuration.actionIDs.isEmpty {
                SettingsFullWidthDisclosure(isExpanded: $isExpanded) {
                    actionRows
                } label: {
                    Text(AppL10n.settings(
                        "plugins.configuration.shortcuts.advanced",
                        defaultValue: "Advanced Controls"
                    ))
                    .font(PluginSettingsTheme.Typography.rowTitle)
                }
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
            } else if !configuration.actionIDs.isEmpty {
                actionRows
            }
            if !definitionsFirst,
               !configuration.actionIDs.isEmpty,
               !matchingShortcutItems.isEmpty {
                PluginSettingsListDivider()
            }
            if !definitionsFirst, !matchingShortcutItems.isEmpty {
                shortcutRows
            }
        }
    }

    private var actionRows: some View {
        PluginActionShortcutRowsContent(
            pluginHost: pluginHost,
            providerID: pluginID,
            actionIDs: configuration.actionIDs,
            hidesNeutralStatusBadges: true
        )
    }

    private var shortcutRows: some View {
        ShortcutSettingsRowsView(
            pluginHost: pluginHost,
            items: matchingShortcutItems,
            alignsWithActionRows: true
        )
    }
}

private struct PluginActionShortcutFormSection: View {
    @ObservedObject var pluginHost: PluginHost
    let pluginID: String
    let configuration: PluginActionShortcutSettingsConfiguration
    let layoutWidths: SettingsGroupedFormWidths

    var body: some View {
        Section {
            PluginActionShortcutRowsContent(
                pluginHost: pluginHost,
                providerID: pluginID,
                actionIDs: configuration.actionIDs
            )
            .settingsGroupedFormRowWidth(layoutWidths.sectionLayout)
            // Keep search decoration on the row so Form can lay out the
            // section header and footer outside its native card.
            .pluginSettingsSearchAnchor(
                pluginID: pluginID,
                entryID: PluginActionShortcutSettingsConfiguration.settingsSearchEntryID
            )
        } header: {
            SettingsGroupedFormSectionHeader(
                title: configuration.title,
                systemImage: configuration.systemImage,
                layoutWidth: layoutWidths.readableContent
            )
        } footer: {
            if let description = configuration.description {
                Text(description)
                    .frame(width: layoutWidths.sectionLayout, alignment: .leading)
            }
        }
    }
}

private extension PluginSettingsPageItem {
    var introductionConfiguration: SettingsPageIntroductionConfiguration {
        SettingsPageIntroductionConfiguration(
            description: description
        )
    }
}

private struct PluginFormSection: View {
    @ObservedObject var pluginHost: PluginHost
    let pluginID: String
    let section: PluginSettingsSection
    let shortcutItems: [ShortcutSettingsItem]
    let layoutWidths: SettingsGroupedFormWidths

    var body: some View {
        if !isEmptyPlacementAnchor {
            formSection
        }
    }

    private var isEmptyPlacementAnchor: Bool {
        guard section.title == nil, section.footer == nil, section.headerAccessory == nil,
              case let .rows(rows) = section.content else { return false }
        return !rows.contains(where: \.isVisible)
    }

    // Empty sections can still position host-owned shortcut groups. Keep them
    // in the page's ordering, but do not give them native Form chrome or spacing.
    private var formSection: some View {
        Section {
            switch section.content {
            case let .rows(rows):
                ForEach(rows.filter(\.isVisible)) { row in
                    PluginSettingsRowView(
                        pluginID: pluginID,
                        row: row,
                        onAction: { action in
                            pluginHost.performSettingsAction(
                                pluginID: pluginID,
                                action: action
                            )
                        }
                    )
                    .pluginSettingsSearchAnchor(
                        pluginID: pluginID,
                        entryID: row.id
                    )
                    .settingsGroupedFormRowWidth(layoutWidths.sectionLayout)
                }
            case let .shortcutGroup(groupID):
                PluginShortcutRowsContent(
                    pluginHost: pluginHost,
                    items: shortcutItems.filter { $0.settingsGroupID == groupID }
                )
                .settingsGroupedFormRowWidth(layoutWidths.sectionLayout)
            case .custom:
                customContent
            }
        } header: {
            sectionHeader
        } footer: {
            if let footer = section.footer {
                Text(footer)
                    .frame(
                        width: layoutWidths.sectionLayout,
                        alignment: .leading
                    )
            }
        }
    }

    @ViewBuilder
    private var customContent: some View {
        let content = pluginHost.pluginSettingsContentViewItem(
            for: pluginID,
            sectionID: section.id
        ).content
            .settingsGroupedFormRowWidth(layoutWidths.sectionLayout)
        switch section.presentation {
        case .standard:
            content
        case .edgeToEdge:
            content
                .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private var sectionHeader: some View {
        if section.title != nil || section.headerAccessory != nil {
            SettingsGroupedFormSectionHeader(
                title: section.title,
                systemImage: section.systemImage,
                layoutWidth: layoutWidths.readableContent
            ) {
                if section.headerAccessory != nil {
                    pluginHost.pluginSettingsHeaderAccessoryViewItem(
                        for: pluginID,
                        sectionID: section.id
                    ).content
                }
            }
        }
    }
}

private struct PluginWorkspacePage: View {
    @ObservedObject var pluginHost: PluginHost
    let item: PluginSettingsPageItem

    var body: some View {
        SettingsPageScaffold(widthPolicy: workspaceWidthPolicy) {
            switch item.workspaceScrolling {
            case .host:
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: SettingsPageLayout.introductionContentSpacing
                    ) {
                        introduction
                        workspacePermissions
                        aliasSettings
                        workspaceContent
                    }
                }
            case .selfManaged:
                VStack(
                    alignment: .leading,
                    spacing: SettingsPageLayout.introductionContentSpacing
                ) {
                    introduction
                    workspacePermissions
                    aliasSettings
                    workspaceContent
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    @ViewBuilder private var aliasSettings: some View {
        let inputs = pluginHost.actionInputRegistry.items.filter {
            $0.id.providerID == item.pluginID && !$0.descriptor.aliases.isEmpty
        }
        if !inputs.isEmpty {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                Label(AppL10n.settings("actionInput.alias.section", defaultValue: "命令面板触发短语"), systemImage: "text.cursor")
                    .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
                ForEach(inputs) { input in
                    CommandPaletteAliasSettingsRow(pluginHost: pluginHost, item: input)
                        .padding().pluginSettingsCardBackground(.standard)
                }
            }
        }
    }

    private var workspaceWidthPolicy: SettingsPageWidthPolicy {
        switch item.workspaceScrolling {
        case .host:
            .standard
        case .selfManaged:
            .expansive
        }
    }

    @ViewBuilder
    private var introduction: some View {
        if !item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SettingsPageIntroduction(
                configuration: item.introductionConfiguration
            )
        }
    }

    @ViewBuilder
    private var workspacePermissions: some View {
        if !item.missingPermissionCards.isEmpty {
            VStack(
                alignment: .leading,
                spacing: PluginSettingsTheme.Spacing.sectionHeaderContent
            ) {
                Label(
                    AppL10n.settings(
                        "plugins.configuration.section.permissions",
                        defaultValue: "权限"
                    ),
                    systemImage: "exclamationmark.shield"
                )
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.orange)

                VStack(spacing: 0) {
                    ForEach(Array(item.missingPermissionCards.enumerated()), id: \.element.id) { index, card in
                        PermissionSettingsRow(
                            card: card,
                            statusColor: statusColor(for: card.statusTone),
                            onAction: {
                                pluginHost.performPermissionAction(
                                    pluginID: card.pluginID,
                                    permissionID: card.permissionID,
                                    sourceFrame: permissionGuidanceSourceFrame(
                                        eventType: NSApp.currentEvent?.type,
                                        mouseLocation: NSEvent.mouseLocation
                                    )
                                )
                            }
                        )
                        .pluginSettingsSearchAnchor(
                            pluginID: card.pluginID,
                            entryID: card.id
                        )
                        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)

                        if index < item.missingPermissionCards.count - 1 {
                            Divider()
                                .padding(.leading, PluginSettingsTheme.Spacing.rowHorizontal)
                        }
                    }
                }
                .pluginSettingsCardBackground(.standard)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.orange.opacity(0.65))
                        .frame(width: 3)
                }
            }
        }
    }

    private var workspaceContent: some View {
        pluginHost.pluginSettingsContentViewItem(for: item.pluginID).content
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct PluginSettingsRowView: View {
    let pluginID: String
    let row: PluginSettingsRow
    let onAction: (PluginSettingsAction) -> Void
    @State private var showsConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            rowContent

            if let error = row.error {
                Text(error)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !row.helpItems.isEmpty {
                PluginSettingsHelpList(
                    items: row.helpItems,
                    tone: row.helpTone
                )
            } else if let help = row.help {
                Text(help)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(statusColor(for: row.helpTone))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!row.isEnabled)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var rowContent: some View {
        if case let .choiceGroup(selectionID, options) = row.control {
            PluginSettingsChoiceGroupControl(
                selectionID: selectionID,
                options: options,
                onSelect: {
                    onAction(.setSelection(controlID: row.id, optionID: $0))
                }
            )
        } else {
            PluginSettingsItem(
                title: row.title,
                description: row.description,
                systemImage: row.systemImage
            ) {
                control
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch row.control {
        case let .toggle(isOn):
            Toggle(
                "",
                isOn: Binding(
                    get: { isOn },
                    set: { onAction(.setBoolean(controlID: row.id, value: $0)) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        case let .picker(selectionID, options, style):
            PluginSettingsPickerControl(
                selectionID: selectionID,
                options: options,
                style: style,
                onSelect: {
                    onAction(.setSelection(controlID: row.id, optionID: $0))
                }
            )
        case .choiceGroup:
            EmptyView()
        case let .slider(value, range, step, valueFormat):
            PluginSettingsSliderControl(
                controlID: row.id,
                value: value,
                range: range,
                step: step,
                valueFormat: valueFormat,
                onAction: onAction
            )
        case let .textField(value, prompt, isRequired):
            PluginSettingsTextControl(
                controlID: row.id,
                value: value,
                prompt: prompt,
                isRequired: isRequired,
                isSecure: false,
                onAction: onAction
            )
        case let .secureField(value, prompt, isRequired):
            PluginSettingsTextControl(
                controlID: row.id,
                value: value,
                prompt: prompt,
                isRequired: isRequired,
                isSecure: true,
                onAction: onAction
            )
        case let .action(title, role):
            PluginSettingsActionButton(title: title, role: role) {
                onAction(.invoke(controlID: row.id))
            }
        case let .confirmationAction(title, role, confirmation):
            PluginSettingsActionButton(title: title, role: role) {
                showsConfirmation = true
            }
            .alert(confirmation.title, isPresented: $showsConfirmation) {
                Button(confirmation.cancelButtonTitle, role: .cancel) {}
                Button(
                    confirmation.confirmButtonTitle,
                    role: role == .destructive ? .destructive : nil
                ) {
                    onAction(.invoke(controlID: row.id))
                }
            } message: {
                Text(confirmation.message)
            }
        case let .status(text, systemImage, tone, actionTitle):
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Label(text, systemImage: systemImage)
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(statusColor(for: tone))
                    .lineLimit(1)

                if let actionTitle {
                    Button(actionTitle) {
                        onAction(.invoke(controlID: row.id))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct PluginSettingsHelpList: View {
    let items: [String]
    let tone: PluginStatusTone

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .accessibilityHidden(true)

                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .foregroundStyle(statusColor(for: tone))
        .accessibilityElement(children: .contain)
    }
}

private struct PluginSettingsPickerControl: View {
    let selectionID: String
    let options: [PluginSettingsOption]
    let style: PluginSettingsPickerStyle
    let onSelect: (String) -> Void

    var body: some View {
        switch style {
        case .automatic:
            picker
        case .menu:
            picker.pickerStyle(.menu)
        case .segmented:
            picker.pickerStyle(.segmented)
        }
    }

    private var picker: some View {
        Picker(
            "",
            selection: Binding(
                get: { selectionID },
                set: { selection in onSelect(selection) }
            )
        ) {
            ForEach(options) { option in
                Text(option.title).tag(option.id)
            }
        }
        .labelsHidden()
        .frame(minWidth: 120, idealWidth: 180, maxWidth: 240, alignment: .trailing)
    }
}

private struct PluginSettingsChoiceGroupControl: View {
    let selectionID: String
    let options: [PluginSettingsOption]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            ViewThatFits(in: .horizontal) {
                horizontalChoices
                verticalChoices
            }

            if let description = selectedOption?.description {
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(statusColor(for: selectedOption?.descriptionTone ?? .neutral))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var horizontalChoices: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            ForEach(options) { option in
                choiceButton(option: option)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var verticalChoices: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.controlCluster) {
            ForEach(options) { option in
                choiceButton(option: option)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedOption: PluginSettingsOption? {
        options.first { $0.id == selectionID }
    }

    @ViewBuilder
    private func choiceButton(option: PluginSettingsOption) -> some View {
        let isSelected = selectionID == option.id
        Button {
            onSelect(option.id)
        } label: {
            HStack(spacing: 6) {
                Text(option.title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(minWidth: 132, maxWidth: .infinity, minHeight: PluginSettingsTheme.Size.controlHeight + 8)
            .padding(.horizontal, PluginSettingsTheme.Spacing.controlCluster)
            .background {
                RoundedRectangle(
                    cornerRadius: PluginSettingsTheme.Radius.control,
                    style: .continuous
                )
                .fill(
                    isSelected
                        ? Color.accentColor
                        : PluginSettingsTheme.Palette.recessedControlBackground
                )
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: PluginSettingsTheme.Radius.control,
                    style: .continuous
                )
                .stroke(
                    isSelected ? Color.accentColor : PluginSettingsTheme.Palette.separator,
                    lineWidth: PluginSettingsTheme.Stroke.hairline
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}


struct PluginSettingsSliderInteractionState: Sendable {
    private(set) var currentValue: Double
    private(set) var isEditing = false

    init(value: Double) {
        currentValue = value
    }

    mutating func userValueChanged(
        _ rawValue: Double,
        controlID: String,
        range: ClosedRange<Double>,
        step: Double?
    ) -> [PluginSettingsAction] {
        let newValue = PluginSettingsSlider.snappedValue(rawValue, in: range, step: step)
        guard currentValue != newValue else { return [] }

        currentValue = newValue
        var actions: [PluginSettingsAction] = [
            .setNumber(controlID: controlID, value: newValue, phase: .changed)
        ]
        if !isEditing {
            actions.append(.setNumber(
                controlID: controlID,
                value: newValue,
                phase: .committed
            ))
        }
        return actions
    }

    mutating func editingChanged(
        _ editing: Bool,
        controlID: String
    ) -> [PluginSettingsAction] {
        let wasEditing = isEditing
        isEditing = editing
        guard wasEditing, !editing else { return [] }

        return [
            .setNumber(
                controlID: controlID,
                value: currentValue,
                phase: .committed
            )
        ]
    }

    mutating func modelValueChanged(_ newValue: Double) {
        guard currentValue != newValue else { return }
        currentValue = newValue
    }
}

private struct PluginSettingsSliderControl: View {
    let controlID: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let valueFormat: PluginSettingsSliderValueFormat?
    let onAction: (PluginSettingsAction) -> Void
    @State private var interactionState: PluginSettingsSliderInteractionState

    init(
        controlID: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double?,
        valueFormat: PluginSettingsSliderValueFormat?,
        onAction: @escaping (PluginSettingsAction) -> Void
    ) {
        self.controlID = controlID
        self.value = value
        self.range = range
        self.step = step
        self.valueFormat = valueFormat
        self.onAction = onAction
        _interactionState = State(initialValue: PluginSettingsSliderInteractionState(value: value))
    }

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            PluginSettingsSlider(
                value: Binding(
                    get: { interactionState.currentValue },
                    set: { rawValue in
                        let actions = interactionState.userValueChanged(
                            rawValue,
                            controlID: controlID,
                            range: range,
                            step: step
                        )
                        actions.forEach(onAction)
                    }
                ),
                in: range,
                step: step,
                onEditingChanged: { editing in
                    let actions = interactionState.editingChanged(editing, controlID: controlID)
                    actions.forEach(onAction)
                }
            )

            if let valueFormat {
                Text(valueFormat.text(for: interactionState.currentValue))
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
        .onChange(of: value) { _, newValue in
            interactionState.modelValueChanged(newValue)
        }
    }
}

private struct PluginSettingsTextControl: View {
    let controlID: String
    let value: String
    let prompt: String?
    let isRequired: Bool
    let isSecure: Bool
    let onAction: (PluginSettingsAction) -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        controlID: String,
        value: String,
        prompt: String?,
        isRequired: Bool,
        isSecure: Bool,
        onAction: @escaping (PluginSettingsAction) -> Void
    ) {
        self.controlID = controlID
        self.value = value
        self.prompt = prompt
        self.isRequired = isRequired
        self.isSecure = isSecure
        self.onAction = onAction
        _text = State(initialValue: value)
    }

    var body: some View {
        Group {
            if isSecure {
                SecureField(prompt ?? "", text: $text)
            } else {
                TextField(prompt ?? "", text: $text)
            }
        }
        .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
        .focused($isFocused)
        .onChange(of: text) { _, value in
            onAction(.setText(controlID: controlID, value: value, phase: .changed))
        }
        .onChange(of: value) { _, value in
            if text != value {
                text = value
            }
        }
        .onChange(of: isFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                commit()
            }
        }
        .onSubmit(commit)
    }

    private func commit() {
        guard !isRequired || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        onAction(.setText(controlID: controlID, value: text, phase: .committed))
    }
}

private struct PluginSettingsActionButton: View {
    let title: String
    let role: PluginSettingsActionRole
    let action: () -> Void

    var body: some View {
        switch role {
        case .normal:
            Button(title, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .prominent:
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .destructive:
            Button(title, role: .destructive, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

private struct PluginShortcutRowsContent: View {
    @ObservedObject var pluginHost: PluginHost
    let items: [ShortcutSettingsItem]

    var body: some View {
        if groupedItems.isEmpty {
            ShortcutSettingsRowsView(pluginHost: pluginHost, items: items)
        } else {
            GroupedShortcutSettingsRowsView(pluginHost: pluginHost, groups: groupedItems)
        }
    }

    private var groupedItems: [ShortcutSettingsGroup] {
        guard !items.isEmpty, items.allSatisfy({ $0.settingsGroupID != nil }) else {
            return []
        }

        var groupOrder: [String] = []
        var groups: [String: [ShortcutSettingsItem]] = [:]
        for item in items {
            guard let groupID = item.settingsGroupID else { continue }
            if groups[groupID] == nil {
                groupOrder.append(groupID)
            }
            groups[groupID, default: []].append(item)
        }

        return groupOrder.compactMap { groupID in
            guard let groupItems = groups[groupID], let first = groupItems.first else {
                return nil
            }
            return ShortcutSettingsGroup(
                id: groupID,
                title: first.settingsGroupTitle ?? first.title,
                description: first.settingsGroupDescription ?? first.description,
                items: groupItems
            )
        }
    }
}

private func statusColor(for tone: PluginStatusTone) -> Color {
    switch tone {
    case .neutral:
        return .secondary
    case .positive:
        return .green
    case .caution:
        return .orange
    }
}

struct AboutSettingsView: View {
    @StateObject private var updateViewModel: AboutUpdateViewModel
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    private let releaseHistory: ReleaseHistory

    init(
        appUpdater: AppUpdater,
        navigationCoordinator: SettingsNavigationCoordinator,
        releaseHistory: ReleaseHistory = .bundled
    ) {
        _updateViewModel = StateObject(
            wrappedValue: AboutUpdateViewModel(updater: appUpdater)
        )
        self.navigationCoordinator = navigationCoordinator
        self.releaseHistory = releaseHistory
    }

    var body: some View {
        VStack(spacing: 0) {
            AboutProductSummary(viewModel: updateViewModel)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)

            Divider()

            AboutReleaseHistoryView(releaseHistory: releaseHistory)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(
            of: navigationCoordinator.aboutUpdateActionRequest,
            initial: true
        ) { _, request in
            handleUpdateActionRequest(request)
        }
    }

    private func handleUpdateActionRequest(_ request: AboutUpdateActionRequest?) {
        guard
            let request,
            navigationCoordinator.consumeAboutUpdateActionRequest(request)
        else {
            return
        }

        Task { @MainActor in
            await Task.yield()
            await updateViewModel.performRequestedUpdateAction(version: request.version)
        }
    }
}

private struct AboutProductSummary: View {
    @ObservedObject var viewModel: AboutUpdateViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            AppIconPreview()

            VStack(alignment: .leading, spacing: 6) {
                Text(AppMetadata.appName)
                    .font(PluginSettingsTheme.Typography.pageTitle)

                Text(AppL10n.settingsFormat("about.versionFormat", defaultValue: "版本 %@", AppMetadata.versionDescription))
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)

                Text(AppMetadata.aboutDescription)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                Link(destination: AppMetadata.repositoryURL) {
                    HStack(spacing: 5) {
                        Text(AppMetadata.repositoryDisplayName)
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                    }
                }
                .font(PluginSettingsTheme.Typography.rowDescription)
                .padding(.top, 2)
            }

            Spacer(minLength: 12)

            AboutUpdateCard(viewModel: viewModel)
                .frame(minWidth: 160, idealWidth: 190, maxWidth: 220)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }
}

private struct AboutReleaseHistoryView: View {
    private static let maximumReleaseCount = 10

    let releaseHistory: ReleaseHistory

    private var displayedReleases: [ReleaseHistoryItem] {
        releaseHistory.mostRecentReleases(limit: Self.maximumReleaseCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    AppL10n.settings("about.changelog.title", defaultValue: "版本记录"),
                    systemImage: "clock.arrow.circlepath"
                )
                .font(PluginSettingsTheme.Typography.sectionTitle)

                Text(
                    AppL10n.settings(
                        "about.changelog.description",
                        defaultValue: "MacTools 与插件最近 10 个版本的发布记录"
                    )
                )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if displayedReleases.isEmpty {
                ContentUnavailableView(
                    AppL10n.settings(
                        "about.changelog.empty.title",
                        defaultValue: "暂无版本记录"
                    ),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        AppL10n.settings(
                            "about.changelog.empty.description",
                            defaultValue: "发布新版本后，更新内容会显示在这里。"
                        )
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(displayedReleases) { release in
                            AboutReleaseCard(release: release)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AboutReleaseCard: View {
    let release: ReleaseHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(releaseKindTitle, systemImage: releaseKindSystemImage)
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(.secondary)

                Text(release.version)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                if isCurrentVersion {
                    Text(
                        AppL10n.settings(
                            "about.changelog.currentVersion",
                            defaultValue: "当前版本"
                        )
                    )
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }

                Spacer(minLength: 12)

                Text(release.date)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.tertiary)
            }

            ForEach(release.sections) { section in
                VStack(alignment: .leading, spacing: 7) {
                    Text(section.kind.displayName)
                        .font(PluginSettingsTheme.Typography.secondaryLabel)
                        .foregroundStyle(.secondary)

                    ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Circle()
                                .fill(Color.secondary.opacity(0.7))
                                .frame(width: 4, height: 4)
                                .alignmentGuide(.firstTextBaseline) { dimensions in
                                    dimensions[VerticalAlignment.center]
                                }
                                .accessibilityHidden(true)

                            Text(entry)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.standard)
    }

    private var releaseKindTitle: String {
        switch release.kind {
        case .app:
            return AppMetadata.appName
        case .plugin:
            return AppL10n.settings("tab.plugins", defaultValue: "插件")
        }
    }

    private var releaseKindSystemImage: String {
        switch release.kind {
        case .app:
            return "app.fill"
        case .plugin:
            return "shippingbox.fill"
        }
    }

    private var isCurrentVersion: Bool {
        release.kind == .app && release.version == AppMetadata.shortVersion
    }
}

private struct AboutUpdateCard: View {
    private enum Layout {
        static let verticalSpacing: CGFloat = 12
        static let statusMinHeight: CGFloat = 16
    }

    @ObservedObject var viewModel: AboutUpdateViewModel

    var body: some View {
        VStack(spacing: Layout.verticalSpacing) {
            Button(viewModel.primaryButtonTitle) {
                Task {
                    await viewModel.performPrimaryAction()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(viewModel.isPrimaryButtonDisabled)

            Text(statusText ?? " ")
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(viewModel.statusColor)
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: Layout.statusMinHeight, alignment: .top)
                .opacity(statusText == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusText: String? {
        switch viewModel.state {
        case .idle:
            return nil
        default:
            return viewModel.statusDetail ?? viewModel.statusHeadline
        }
    }
}

private struct AppIconPreview: View {
    private static let iconSize: CGFloat = 76

    var body: some View {
        if let appIcon = AppMetadata.appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
        } else {
            Image(systemName: "wrench.and.screwdriver.fill")
                .resizable()
                .scaledToFit()
                .padding(12)
                .foregroundStyle(.secondary)
                .background(PluginSettingsTheme.Palette.recessedControlBackground)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}
