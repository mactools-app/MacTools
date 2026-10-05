import AppKit
import Combine
import Foundation
import SwiftUI
import MacToolsPluginKit

enum FeatureSettingsPane: Hashable {
    case actionsAndShortcuts
    case automation
    case marketplace
    case configuration(String)
}

enum SettingsPresentationRequest: Equatable {
    case settings
    case general
    case permissions
    case about
    case appUpdate
    case pluginMarketplace
    case pluginMarketplaceDetail(MarketplacePluginDetailTarget)
    case pluginConfiguration(String)
    case automationWorkflow(UUID)
    case feature(FeatureSettingsPane)
}

enum AppPresentationRequest: Equatable {
    case composeActionInput(ActionInputItem)
    case settings(SettingsPresentationRequest)
    case toggleCommandPalette
    case toggleDashboard
    case toggleFeaturePanel
    case showDashboard
    case showFeaturePanel
    case showUnifiedSearch
}

enum AppShortcutAction: String, CaseIterable, Hashable {
    case openSettings = "app.open-settings"
    case toggleDashboard = "app.toggle-dashboard"
    case toggleFeaturePanel = "app.toggle-feature-panel"
    case openCommandPalette = "app.open-command-palette"

    var isPanelAction: Bool { self == .toggleDashboard || self == .toggleFeaturePanel }

    var title: String {
        switch self {
        case .openSettings:
            return AppL10n.settings("shortcuts.openSettings.title", defaultValue: "打开设置")
        case .openCommandPalette:
            return AppL10n.settings(
                "shortcuts.openCommandPalette.title",
                defaultValue: "打开命令面板"
            )
        case .toggleDashboard:
            return AppL10n.settings("shortcuts.toggleDashboard.title", defaultValue: "切换仪表盘")
        case .toggleFeaturePanel:
            return AppL10n.settings("shortcuts.toggleFeaturePanel.title", defaultValue: "切换功能面板")
        }
    }

    var compactTitle: String {
        switch self {
        case .openSettings:
            return AppL10n.settings("settings.window.title", defaultValue: "设置")
        case .openCommandPalette:
            return title
        case .toggleDashboard:
            return AppL10n.settings("plugins.dashboard.title", defaultValue: "仪表盘")
        case .toggleFeaturePanel:
            return AppL10n.settings("plugins.featurePanel.title", defaultValue: "功能面板")
        }
    }

    var description: String {
        switch self {
        case .openSettings:
            return AppL10n.settings("shortcuts.openSettings.description", defaultValue: "打开 MacTools 设置。")
        case .openCommandPalette:
            return AppL10n.settings(
                "shortcuts.openCommandPalette.description",
                defaultValue: "在任意位置显示或隐藏 MacTools 命令面板。"
            )
        case .toggleDashboard:
            return AppL10n.settings(
                "shortcuts.toggleDashboard.description",
                defaultValue: "显示、隐藏或切换到仪表盘。"
            )
        case .toggleFeaturePanel:
            return AppL10n.settings(
                "shortcuts.toggleFeaturePanel.description",
                defaultValue: "显示、隐藏或切换到功能面板。"
            )
        }
    }

    var systemImage: String {
        switch self {
        case .openSettings:
            return "gearshape"
        case .openCommandPalette:
            return "command.square"
        case .toggleDashboard:
            return "square.grid.2x2"
        case .toggleFeaturePanel:
            return "switch.2"
        }
    }

    var presentationRequest: AppPresentationRequest {
        switch self {
        case .openSettings:
            return .settings(.settings)
        case .openCommandPalette:
            return .toggleCommandPalette
        case .toggleDashboard:
            return .toggleDashboard
        case .toggleFeaturePanel:
            return .toggleFeaturePanel
        }
    }

    var settingsPresentationRequest: SettingsPresentationRequest {
        switch self {
        case .openSettings, .openCommandPalette:
            .general
        case .toggleDashboard, .toggleFeaturePanel:
            .feature(.actionsAndShortcuts)
        }
    }

    var isCommandPaletteSearchEligible: Bool {
        switch self {
        case .openSettings, .openCommandPalette:
            false
        case .toggleDashboard, .toggleFeaturePanel:
            true
        }
    }

}

struct PluginHostCapabilities: Equatable, Sendable {
    let panelKinds: Set<PluginPanelItemKind>
    let settingsLayout: PluginSettingsLayout?
    var hasSettings: Bool { settingsLayout != nil }
}

struct MenuBarPanelLayoutEntry: Identifiable {
    let item: PanelCatalogItem
    let entry: MenuBarPanelEntry
    var id: String { entry.id }
}

struct ActionOwnerAppearance {
    let systemImage: String
    let iconTint: Color
}

struct AppShortcutSettingsItem: Identifiable, Equatable {
    let id: String
    let action: AppShortcutAction
    let assignmentID: UUID?
    let title: String
    let description: String
    let systemImage: String
    let bindingText: String
    let canClear: Bool
    let errorMessage: String?

}

private struct ShortcutMutationMetadata {
    let shortcutID: String
    let assignmentID: UUID?
}

struct PluginProvidedSettingsSearchItem: Identifiable, Hashable {
    let pluginID: String
    let entry: PluginSettingsSearchEntry

    var id: String {
        "\(pluginID).settings-search.\(entry.id)"
    }
}

struct PluginCommandItem: Identifiable, Hashable {
    let pluginID: String
    let pluginTitle: String
    let definition: PluginCommandDefinition

    var id: String {
        "\(pluginID).command.\(definition.id)"
    }
}

struct PluginAutomaticUpdateStatus: Equatable {
    enum Phase: Equatable {
        case idle
        case checking
        case updating
        case completed
        case failed
    }

    let phase: Phase
    let pluginIDs: [String]
    let message: String?

    static let idle = PluginAutomaticUpdateStatus(
        phase: .idle,
        pluginIDs: [],
        message: nil
    )

    var isActive: Bool {
        phase == .checking || phase == .updating
    }

    var isVisible: Bool {
        phase != .idle
    }

    func isUpdatingPlugin(id: String) -> Bool {
        phase == .updating && pluginIDs.contains(id)
    }

    var title: String {
        switch phase {
        case .idle:
            return ""
        case .checking:
            return AppL10n.plugins("plugin.autoUpdate.title.checking", defaultValue: "正在检查插件更新")
        case .updating:
            return AppL10n.plugins("plugin.autoUpdate.title.updating", defaultValue: "正在更新插件")
        case .completed:
            return AppL10n.plugins("plugin.autoUpdate.title.completed", defaultValue: "插件已更新")
        case .failed:
            return AppL10n.plugins("plugin.autoUpdate.title.failed", defaultValue: "插件自动更新失败")
        }
    }

    var detailText: String {
        if let message {
            return message
        }

        switch phase {
        case .idle:
            return ""
        case .checking:
            return AppL10n.plugins("plugin.autoUpdate.detail.checking", defaultValue: "新版首次启动时会先检查已安装插件。")
        case .updating:
            return AppL10n.pluginsFormat(
                "plugin.autoUpdate.detail.updatingFormat",
                defaultValue: "正在更新 %d 个已安装插件，完成后会继续加载。",
                pluginIDs.count
            )
        case .completed:
            return pluginIDs.isEmpty
                ? AppL10n.plugins("plugin.autoUpdate.detail.noUpdates", defaultValue: "已是最新版本。")
                : AppL10n.pluginsFormat("plugin.autoUpdate.detail.completedFormat", defaultValue: "已更新 %d 个插件。", pluginIDs.count)
        case .failed:
            return AppL10n.plugins("plugin.autoUpdate.detail.failed", defaultValue: "稍后可在此页面重试。")
        }
    }
}

struct PluginAutomaticUpdateVersionStore {
    private enum DefaultsKey {
        static let lastCheckedAppVersion = "plugins.dynamic.lastAutomaticUpdateAppVersion"
    }

    var userDefaults: UserDefaults = .standard

    func needsAutomaticUpdateCheck(currentAppVersion: String) -> Bool {
        guard !currentAppVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return userDefaults.string(forKey: DefaultsKey.lastCheckedAppVersion) != currentAppVersion
    }

    func markAutomaticUpdateChecked(currentAppVersion: String) {
        userDefaults.set(currentAppVersion, forKey: DefaultsKey.lastCheckedAppVersion)
    }
}

@MainActor
final class PluginHost: ObservableObject {
    private struct ActionShortcutBurstState {
        var admittedCount = 0
        var activeTaskCount = 0
        var lastCompletionUptime: TimeInterval?
    }

    private static let maximumActionShortcutBurstCount = 9
    private static let actionShortcutBurstResetInterval: TimeInterval = 0.75

    private struct SettingsViewCacheKey: Hashable {
        enum Content: Hashable {
            case workspace
            case section(String)
            case sectionAccessory(String)
        }

        let pluginID: String
        let content: Content

        var itemID: String {
            switch content {
            case .workspace:
                return "\(pluginID).workspace"
            case let .section(sectionID):
                return "\(pluginID).section.\(sectionID)"
            case let .sectionAccessory(sectionID):
                return "\(pluginID).section.\(sectionID).accessory"
            }
        }
    }

    private struct PluginDescriptor {
        let metadata: PluginMetadata
        let plugin: any MacToolsPlugin
        let capabilities: PluginHostCapabilities


        var hasSettings: Bool {
            capabilities.hasSettings
        }
    }

    private struct ShortcutDescriptor {
        let itemID: String
        let pluginID: String
        let pluginTitle: String
        let definition: PluginShortcutDefinition
        let plugin: any MacToolsPlugin
    }

    private struct ShortcutResolutionSnapshot {
        let revision: UInt64
        let descriptors: [ShortcutDescriptor]
    }

    private var shortcutDefinitionRevision: UInt64 = 0
    private var shortcutResolutionSnapshot: ShortcutResolutionSnapshot?

    /// Immutable inputs shared by one synchronous update. Plugin declarations
    /// are read again on the next update, including dynamic defaults and titles.
    private struct PluginDescriptorSnapshot {
        let defaults: [PluginDescriptor]
        let byID: [String: PluginDescriptor]
        let ordered: [PluginDescriptor]

        init(defaults: [PluginDescriptor], orderedIDs: [String]) {
            self.defaults = defaults
            let byID = Dictionary(
                defaults.map { ($0.metadata.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            self.byID = byID
            ordered = orderedIDs.compactMap { byID[$0] }
        }
    }

    private struct PreferencesActionRestoreContext {
        let selection: PreferencesBackupSelection
        let payloadDefinedActionReferencesByPluginID: [String: Set<ActionReference>]
        let importedWorkflowIDs: Set<UUID>
        let restorableWorkflowIDs: Set<UUID>
        let resolvableWorkflowIDs: Set<UUID>
    }

    private let builtInPlugins: [any MacToolsPlugin]
    private let shortcutStore: ShortcutStore
    private let pluginOrderingStore: PluginOrderingStore
    let menuBarPanelStore: MenuBarPanelStore
    let menuBarIconCoordinator: PluginMenuBarIconCoordinator
    @Published private(set) var menuBarPanels: [MenuBarPanelDefinition] = []
    private var visibleMenuBarPanelID: String?
    private var menuBarPanelContentCache: [String: MenuBarPanelContentSnapshot] = [:]
    /// Emitted after a complete panel update, including layout-only mutations.
    let menuBarPanelContentDidChange = PassthroughSubject<Void, Never>()
    var menuBarPanelPresentationHandler: ((String, Bool) -> Void)?
    private let preferencesBackupStore: any PreferencesBackupApplicationStoring
    private let automaticPreferencesBackupCoordinator: AutomaticPreferencesBackupCoordinator?
    private let cloudPreferencesSyncCoordinator: CloudPreferencesSyncCoordinator?
    let preferencesBackupChangeReporter: PreferencesBackupChangeReporter
    private let globalShortcutManager: GlobalShortcutManager
    private let displayConfigurationObserver: (any DisplayConfigurationObserving)?
    private let accessibilityPermissionObserver: (any AccessibilityPermissionObserving)?
    private let applicationActivityObserver: (any ApplicationActivityObserving)?
    private let focusedApplicationTargetProvider: any FocusedApplicationTargetProviding
    private let displayTopologyRefreshDelay: Duration
    private let pluginStateChangeRebuildDelay: Duration
    let dynamicPluginManager: DynamicPluginManager?
    private let pluginCatalogManager: PluginCatalogManager?
    let actionInputRegistry = ActionInputRegistry()
    let actionInputAliases: CommandPaletteAliasStore

    var commandPaletteAliasResolver: CommandPaletteAliasResolver {
        CommandPaletteAliasResolver(items: actionInputRegistry.items, overrides: actionInputAliases.overrides)
    }

    func setActionInputAlias(_ alias: String?, for item: ActionInputItem) throws {
        try actionInputAliases.set(alias, for: item, items: actionInputRegistry.items)
        objectWillChange.send()
    }
    let actionRegistry: ActionRegistry
    let actionExecutor: ActionExecutor
    let actionConfirmationService: ActionConfirmationRouter
    private let actionShortcutStore: ActionShortcutAssignmentStore
    let shortcutAssignmentService: ShortcutAssignmentService
    private let actionPresetStore: ActionInvocationPresetStore
    let actionRunLinkService: ActionRunLinkService
    let automationController: AutomationController
    private var actionGridPresentationHandler: ((
        [ActionGridPresentationEntry],
        ActionExecutionSource
    ) -> Bool)?
    @TaskLocal private static var actionShortcutAncestry: Set<ActionReference> = []
    private var actionShortcutBursts: [ActionReference: ActionShortcutBurstState] = [:]
#if DEBUG
    var actionShortcutBurstUptimeProviderForTests: (() -> TimeInterval)?
#endif
    private var preferencesBackupExportSelection: PreferencesBackupSelection?
    private var preferencesBackupRestoreContext: PreferencesActionRestoreContext?

    private var dynamicPlugins: [any MacToolsPlugin] = []
    private var dynamicPluginCapabilitiesByID: [String: PluginPackageManifest.Capabilities] = [:]
    private var dynamicPluginCategoriesByID: [String: String?] = [:]
    private var dynamicPluginReleaseChannelsByID: [String: String?] = [:]
    private var dynamicPluginManifestsByID: [String: PluginPackageManifest] = [:]
    private var dynamicPluginInstalledAtByID: [String: Date] = [:]
    private var shortcutErrors: [String: String] = [:]
    private let shortcutBindingDeliveries = PluginShortcutBindingTracker()
    private var appShortcutErrors: [AppShortcutAction: String] = [:]
    let panelCoordinator = PluginPanelCoordinator()
    private var settingsViewCache: [SettingsViewCacheKey: PluginSettingsContentViewItem] = [:]
    private var isolatedPluginFailures: [String: String] = [:]
    private var isHandlingPluginAction = false
    @Published private var didLoadDynamicPlugins = false
    private var areCloudPreferencesReady = false
    private var displayTopologyRefreshTask: Task<Void, Never>?
    private var pluginStateChangeRebuildTask: Task<Void, Never>?
    private var runtimeLocaleCancellable: AnyCancellable?
    private var applicationActivityState: PluginApplicationActivityState
    private var dirtyPluginIDs: Set<String> = []
    private var builtInCapabilitiesByID: [String: PluginHostCapabilities] = [:]
    private var dynamicResolvedCapabilitiesByID: [String: PluginHostCapabilities] = [:]

    var availablePanelItems: [PanelCatalogItem] { panelCoordinator.catalog.filter(\.isAvailable) }
    var panelItems: [PluginPanelRowSnapshot] { panelItems(in: MenuBarPanelDefinition.featuresID) }
    var componentItems: [PluginPanelWidgetSnapshot] { componentItems(in: MenuBarPanelDefinition.componentsID) }
    @Published private(set) var pluginSettingsItems: [PluginSettingsPageItem] = []
    @Published private(set) var permissionCards: [PluginPermissionCard] = []
    private(set) lazy var permissionCoordinator = PermissionCoordinator(
        specializedActionHandler: { [weak self] pluginID, permissionID in
            self?.performSpecializedPermissionAction(
                pluginID: pluginID,
                permissionID: permissionID
            )
        },
        refreshHandler: { [weak self] targets in
            self?.refreshPermissionState(targets: targets)
        },
        guidanceHandler: { [weak self] kind, sourceFrame in
            self?.permissionGuidanceHandler(kind, sourceFrame)
        }
    )
    @Published private(set) var shortcutItems: [ShortcutSettingsItem] = []
    private var shortcutMutationMetadataByRowID: [String: ShortcutMutationMetadata] = [:]
    @Published private(set) var appShortcutItems: [AppShortcutSettingsItem] = []
    @Published private(set) var actionShortcutItems: [ActionShortcutSettingsItem] = []
    @Published private(set) var actionShortcutCatalogItems: [ActionShortcutCatalogItem] = []

    var actionShortcutLoadError: String? {
        actionShortcutStore.loadError
    }
    @Published private(set) var pluginSettingsSearchItems: [PluginProvidedSettingsSearchItem] = []
    @Published private(set) var pluginCommandItems: [PluginCommandItem] = []
    @Published private(set) var actionCatalogEntries: [ActionCatalogEntry] = []
    @Published private(set) var actionRegistryIssues: [ActionRegistryIssue] = []
    @Published private(set) var shortcutBindingRevision: UInt64 = 0
    @Published private(set) var pluginManagementItems: [PluginManagementItem] = []
    @Published private(set) var pluginCatalogStatus: PluginCatalogStatus = .unavailable
    @Published private(set) var automaticPluginUpdateStatus: PluginAutomaticUpdateStatus = .idle
    @Published private(set) var hasActivePlugin = false
    @Published private(set) var localizationRevision = 0
    @Published private(set) var automaticPreferencesBackupEnabled = false
    @Published private(set) var automaticPreferencesBackupSummary =
        AutomaticPreferencesBackupSummary.empty
    @Published private(set) var cloudPreferencesSyncEnabled = false
    @Published private(set) var cloudPreferencesSyncStatus: CloudPreferencesSyncStatus = .offline(reason: .disabled)
    @Published private(set) var cloudPreferencesSyncDirectoryURL: URL?

    /// The app shell installs this while the application is running. The host
    /// emits typed requests but never manipulates windows or popovers directly.
    var appPresentationHandler: ((AppPresentationRequest) -> Void)?
    var componentDetailHandlersByPanelID: [String: (String, String) -> Void] = [:]

    private let openPermissionSettings: (URL) -> Void
    private let permissionGuidanceHandler: PermissionCoordinator.GuidanceHandler

    /// The app shell installs this to present source-appropriate feedback for actions invoked from
    /// headless surfaces such as global shortcuts and trackpad gestures.
    var actionExecutionFeedbackHandler: ((
        ActionExecutionSource,
        ActionReference,
        String?,
        ActionExecutionOutcome
    ) -> Void)?

    /// Injected by `MenuBarStatusItemController`; returns the status-item button frame in screen coordinates.
    var statusItemButtonFrameProvider: (() -> NSRect?)? = nil {
        didSet {
            configureHostStatusItemCallbacks(for: activePlugins)
        }
    }
    var resetStatusItemPosition: (() -> Void)? = nil {
        didSet {
            configureHostStatusItemCallbacks(for: activePlugins)
        }
    }

    convenience init(
        loadDynamicPluginsOnInit: Bool = true,
        preferencesBackupStore: any PreferencesBackupApplicationStoring,
        enablesAutomaticPreferencesBackups: Bool = false
    ) {
        let dynamicPluginManager = DynamicPluginManager()
        let pluginCatalogManager = PluginCatalogManager.live(dynamicPluginManager: dynamicPluginManager)
        let preferencesBackupChangeReporter = PreferencesBackupChangeReporter()
        let shortcutStore = ShortcutStore(
            preferencesBackupChangeReporter: preferencesBackupChangeReporter
        )
        self.init(
            plugins: BuiltInPluginRegistry().makePlugins(),
            dynamicPluginManager: dynamicPluginManager,
            pluginCatalogManager: pluginCatalogManager,
            shortcutStore: shortcutStore,
            pluginOrderingStore: PluginOrderingStore(
                preferencesBackupChangeReporter: preferencesBackupChangeReporter
            ),
            preferencesBackupStore: preferencesBackupStore,
            preferencesBackupChangeReporter: preferencesBackupChangeReporter,
            automaticPreferencesBackupCoordinator: enablesAutomaticPreferencesBackups
                ? AutomaticPreferencesBackupCoordinator(userDefaults: shortcutStore.userDefaults)
                : nil,
            cloudPreferencesSyncCoordinator: enablesAutomaticPreferencesBackups
                ? CloudPreferencesSyncCoordinator(userDefaults: shortcutStore.userDefaults)
                : nil,
            globalShortcutManager: GlobalShortcutManager(),
            displayConfigurationObserver: SystemDisplayConfigurationObserver(),
            accessibilityPermissionObserver: AccessibilityPermissionObserver(),
            applicationActivityObserver: SystemApplicationActivityObserver(),
            loadDynamicPluginsOnInit: loadDynamicPluginsOnInit
        )
    }

    init(
        plugins: [any MacToolsPlugin],
        dynamicPluginManager: DynamicPluginManager? = nil,
        pluginCatalogManager: PluginCatalogManager? = nil,
        shortcutStore: ShortcutStore,
        pluginOrderingStore: PluginOrderingStore,
        preferencesBackupStore: any PreferencesBackupApplicationStoring,
        preferencesBackupChangeReporter providedPreferencesBackupChangeReporter:
            PreferencesBackupChangeReporter? = nil,
        automaticPreferencesBackupCoordinator: AutomaticPreferencesBackupCoordinator? = nil,
        cloudPreferencesSyncCoordinator: CloudPreferencesSyncCoordinator? = nil,
        globalShortcutManager: GlobalShortcutManager,
        displayConfigurationObserver: (any DisplayConfigurationObserving)? = nil,
        accessibilityPermissionObserver: (any AccessibilityPermissionObserving)? = nil,
        applicationActivityObserver: (any ApplicationActivityObserving)? = nil,
        focusedApplicationTargetProvider: (any FocusedApplicationTargetProviding)? = nil,
        displayTopologyRefreshDelay: Duration = .milliseconds(180),
        pluginStateChangeRebuildDelay: Duration = .milliseconds(80),
        loadDynamicPluginsOnInit: Bool = true,
        actionURLScheme: String = RightClickURLRouter.bundleURLSchemes().sorted().first ?? "mactools",
        openPermissionSettings: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        permissionGuidanceHandler: @escaping PermissionCoordinator.GuidanceHandler = {
            kind,
            sourceFrame in
            PermissionFlowGuidancePresenter.shared.present(
                kind: kind,
                sourceFrame: sourceFrame
            )
        }
    ) {
        let preferencesBackupChangeReporter = providedPreferencesBackupChangeReporter
            ?? PreferencesBackupChangeReporter()
        shortcutStore.preferencesBackupChangeReporter = preferencesBackupChangeReporter
        pluginOrderingStore.preferencesBackupChangeReporter =
            preferencesBackupChangeReporter
        preferencesBackupStore.preferencesBackupChangeReporter = preferencesBackupChangeReporter

        self.builtInPlugins = plugins.sorted {
            if $0.metadata.order == $1.metadata.order {
                return $0.metadata.title.localizedCompare($1.metadata.title) == .orderedAscending
            }

            return $0.metadata.order < $1.metadata.order
        }
        self.actionInputAliases = CommandPaletteAliasStore(defaults: shortcutStore.userDefaults)
        self.shortcutStore = shortcutStore
        self.pluginOrderingStore = pluginOrderingStore
        self.menuBarPanelStore = MenuBarPanelStore(
            userDefaults: shortcutStore.userDefaults, reporter: preferencesBackupChangeReporter
        )
        self.menuBarPanels = menuBarPanelStore.configuration.displayPanels
        self.menuBarIconCoordinator = PluginMenuBarIconCoordinator(userDefaults: shortcutStore.userDefaults)
        self.preferencesBackupStore = preferencesBackupStore
        self.automaticPreferencesBackupCoordinator = automaticPreferencesBackupCoordinator
        self.cloudPreferencesSyncCoordinator = cloudPreferencesSyncCoordinator
        self.preferencesBackupChangeReporter = preferencesBackupChangeReporter
        self.globalShortcutManager = globalShortcutManager
        self.openPermissionSettings = openPermissionSettings
        self.permissionGuidanceHandler = permissionGuidanceHandler
        self.displayConfigurationObserver = displayConfigurationObserver
        self.accessibilityPermissionObserver = accessibilityPermissionObserver
        self.applicationActivityObserver = applicationActivityObserver
        self.focusedApplicationTargetProvider = focusedApplicationTargetProvider
            ?? SystemFocusedApplicationTargetProvider()
        self.applicationActivityState = applicationActivityObserver?.state ?? .interactive
        self.displayTopologyRefreshDelay = displayTopologyRefreshDelay
        self.pluginStateChangeRebuildDelay = pluginStateChangeRebuildDelay
        self.dynamicPluginManager = dynamicPluginManager
        self.pluginCatalogManager = pluginCatalogManager
        let actionRegistry = ActionRegistry()
        let actionShortcutStore = ActionShortcutAssignmentStore(
            userDefaults: shortcutStore.userDefaults,
            preferencesBackupChangeReporter: preferencesBackupChangeReporter
        )
        let actionPresetStore = ActionInvocationPresetStore(
            userDefaults: shortcutStore.userDefaults,
            preferencesBackupChangeReporter: preferencesBackupChangeReporter
        )
        let actionConfirmationService = ActionConfirmationRouter()
        let actionExecutor = ActionExecutor(
            registry: actionRegistry,
            confirmationService: actionConfirmationService
        )
        self.actionRegistry = actionRegistry
        self.actionConfirmationService = actionConfirmationService
        self.actionExecutor = actionExecutor
        self.actionShortcutStore = actionShortcutStore
        self.actionPresetStore = actionPresetStore
        self.shortcutAssignmentService = ShortcutAssignmentService(
            registry: actionRegistry,
            store: actionShortcutStore,
            shortcutManager: globalShortcutManager
        )
        self.actionRunLinkService = ActionRunLinkService(
            registry: actionRegistry,
            presetStore: actionPresetStore,
            scheme: actionURLScheme
        )
        let workflowStore = WorkflowStore(
            userDefaults: shortcutStore.userDefaults,
            preferencesBackupChangeReporter: preferencesBackupChangeReporter
        )
        self.automationController = AutomationController(
            store: workflowStore,
            ruleStore: AutomationRuleStore(
                userDefaults: shortcutStore.userDefaults,
                preferencesBackupChangeReporter: preferencesBackupChangeReporter
            ),
            registry: actionRegistry,
            executor: actionExecutor,
            systemServices: SystemAutomationServices.make()
        )

        preferencesBackupChangeReporter.onCommittedChange = {
            [weak automaticPreferencesBackupCoordinator, weak cloudPreferencesSyncCoordinator] _ in
            automaticPreferencesBackupCoordinator?.committedPreferencesDidChange()
            cloudPreferencesSyncCoordinator?.committedPreferencesDidChange()
        }

        self.automationController.onCatalogChange = { [weak self] in
            self?.rebuildDerivedState()
        }
        self.automationController.actionReferencePortability = { [weak self] reference in
            self?.leafActionReferenceBackupPortability(
                reference,
                // A standalone workflow file cannot carry plugin settings. Actions whose
                // stable identity depends on those settings must use a full preferences backup.
                selection: .all(pluginPreferenceIDs: [])
            ) ?? .unknown
        }

        configureCallbacks(for: self.builtInPlugins)

        if let dynamicPluginManager {
            dynamicPluginManager.onPluginWillDeactivate = { [weak self] pluginID, reason in
                self?.menuBarIconCoordinator.unregister(pluginID: pluginID, reason: reason)
            }
            let legacyHiddenPluginIDs = dynamicPluginManager.legacyHiddenPluginIDs()
            if menuBarPanelStore.migrateLegacyHiddenPlugins(legacyHiddenPluginIDs) {
                dynamicPluginManager.clearLegacyHiddenPluginIDs()
            }
            if loadDynamicPluginsOnInit {
                self.dynamicPlugins = dynamicPluginManager.loadInstalledPlugins()
                self.didLoadDynamicPlugins = true
            } else {
                dynamicPluginManager.prepareInstalledPluginsWithoutLoading()
            }
            let installedMetadata = dynamicPluginManager.installedMetadata()
            self.dynamicPluginCapabilitiesByID = installedMetadata.capabilitiesByID
            self.dynamicPluginCategoriesByID = installedMetadata.categoriesByID
            self.dynamicPluginReleaseChannelsByID = installedMetadata.releaseChannelsByID
            self.dynamicPluginManifestsByID = installedMetadata.manifestsByID
            self.dynamicPluginInstalledAtByID = installedMetadata.installedAtByID
            self.pluginManagementItems = dynamicPluginManager.pluginManagementItems
            self.pluginCatalogStatus = pluginCatalogManager?.status ?? .unavailable
            configureCallbacks(for: self.dynamicPlugins)
            dynamicPluginManager.onPluginsChanged = { [weak self] plugins in
                self?.replaceDynamicPlugins(plugins)
            }
        }

        self.globalShortcutManager.onShortcutTriggered = { [weak self] shortcutID in
            self?.handleShortcutTrigger(shortcutID: shortcutID)
        }
        self.globalShortcutManager.onShortcutReleased = { [weak self] shortcutID in
            self?.handleShortcutRelease(shortcutID: shortcutID)
        }

        self.displayConfigurationObserver?.onConfigurationChange = { [weak self] in
            PluginPresentationSafety.prepareForWindowOrdering()
            self?.scheduleDisplayTopologyRefresh()
        }

        self.accessibilityPermissionObserver?.onPermissionChange = { [weak self] in
            self?.refreshAccessibilityPermissionNow()
        }

        self.applicationActivityObserver?.onStateChange = { [weak self] state in
            self?.handleApplicationActivityStateChange(state)
        }

        runtimeLocaleCancellable = PluginRuntimeLocalization.source.$revision
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshLocalization()
                }
            }

        if let automaticPreferencesBackupCoordinator {
            automaticPreferencesBackupEnabled = automaticPreferencesBackupCoordinator.isEnabled
            automaticPreferencesBackupCoordinator.snapshotProvider = { [weak self] in
                self?.makePreferencesBackup()
            }
            automaticPreferencesBackupCoordinator.failureHandler = { error in
                AppLog.preferencesBackup.error(
                    "Automatic preferences backup failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            automaticPreferencesBackupCoordinator.summaryHandler = { [weak self] summary in
                self?.automaticPreferencesBackupSummary = summary
            }
            Task { [weak automaticPreferencesBackupCoordinator] in
                await automaticPreferencesBackupCoordinator?.refreshSummary()
            }
        }

        if let cloudPreferencesSyncCoordinator {
            cloudPreferencesSyncCoordinator.isReadyToSync = { [weak self] in
                self?.areCloudPreferencesReady ?? false
            }
            cloudPreferencesSyncEnabled = cloudPreferencesSyncCoordinator.isEnabled
            cloudPreferencesSyncStatus = cloudPreferencesSyncCoordinator.status
            cloudPreferencesSyncDirectoryURL = cloudPreferencesSyncCoordinator.syncDirectoryURL
            cloudPreferencesSyncCoordinator.snapshotProvider = { [weak self] in
                self?.makePreferencesBackup()
            }
            cloudPreferencesSyncCoordinator.importHandler = { [weak self] backup in
                guard let self else { return }
                let result = try self.importCloudPreferences(backup)
                guard result.shortcutErrors.isEmpty else {
                    throw NSError(
                        domain: "MacTools.CloudPreferencesSync",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: result.shortcutErrors
                            .sorted { $0.key < $1.key }
                            .map(\.value)
                            .joined(separator: "\n")]
                    )
                }
            }
            cloudPreferencesSyncCoordinator.statusHandler = { [weak self] status in
                self?.cloudPreferencesSyncStatus = status
            }
            cloudPreferencesSyncCoordinator.directoryURLHandler = { [weak self] url in
                self?.cloudPreferencesSyncDirectoryURL = url
            }
        }

        refreshAll()
        startCloudPreferencesSyncIfReady()
    }

    isolated deinit {
        displayTopologyRefreshTask?.cancel()
        pluginStateChangeRebuildTask?.cancel()
        runtimeLocaleCancellable?.cancel()
    }

    func setAutomaticPreferencesBackupEnabled(_ enabled: Bool) {
        automaticPreferencesBackupCoordinator?.setEnabled(enabled)
        automaticPreferencesBackupEnabled = automaticPreferencesBackupCoordinator?.isEnabled ?? false
    }

    @discardableResult
    func setApplicationAppearancePreference(rawValue: String) -> Bool {
        preferencesBackupStore.setAppearancePreference(rawValue: rawValue)
    }

    @discardableResult
    func setApplicationFloatingPanelAppearance(rawValue: String) -> Bool {
        preferencesBackupStore.setFloatingPanelAppearance(rawValue: rawValue)
    }

    @discardableResult
    func setApplicationLanguagePreference(rawValue: String) -> Bool {
        preferencesBackupStore.setLanguagePreference(rawValue: rawValue)
    }

    func createAutomaticPreferencesBackupNow() async throws -> AutomaticPreferencesBackupWriteResult {
        guard let automaticPreferencesBackupCoordinator else {
            throw CocoaError(.featureUnsupported)
        }
        return try await automaticPreferencesBackupCoordinator.createBackupNow()
    }

    func prepareAutomaticPreferencesBackupDirectory() throws -> URL {
        guard let automaticPreferencesBackupCoordinator else {
            throw CocoaError(.featureUnsupported)
        }
        return try automaticPreferencesBackupCoordinator.prepareBackupDirectory()
    }

    func flushAutomaticPreferencesBackupBeforeTermination() {
        automaticPreferencesBackupCoordinator?.flushPendingBackupBeforeTermination()
        cloudPreferencesSyncCoordinator?.flushPendingExportBeforeTermination()
    }

    func setCloudPreferencesSyncEnabled(_ enabled: Bool) {
        cloudPreferencesSyncCoordinator?.setEnabled(enabled)
        cloudPreferencesSyncEnabled = cloudPreferencesSyncCoordinator?.isEnabled ?? false
        if let coordinator = cloudPreferencesSyncCoordinator {
            cloudPreferencesSyncStatus = coordinator.status
        }
    }

    func setCloudPreferencesSyncDirectoryURL(_ url: URL?) {
        cloudPreferencesSyncCoordinator?.setSyncDirectoryURL(url)
        cloudPreferencesSyncDirectoryURL = url
        if let coordinator = cloudPreferencesSyncCoordinator {
            cloudPreferencesSyncStatus = coordinator.status
        }
    }

    func triggerCloudPreferencesSync() async throws {
        guard let cloudPreferencesSyncCoordinator else {
            throw CocoaError(.featureUnsupported)
        }
        try await cloudPreferencesSyncCoordinator.syncNow()
    }

    func resolveCloudPreferencesConflict(_ choice: CloudPreferencesConflictChoice) async throws {
        try await cloudPreferencesSyncCoordinator?.resolveConflict(choice)
    }

    func openCloudPreferencesSyncFolder() {
        guard let url = cloudPreferencesSyncDirectoryURL ?? cloudPreferencesSyncCoordinator?.syncDirectoryURL else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func deactivateAllPlugins(reason: PluginDeactivationReason = .hostShutdown) {
        menuBarIconCoordinator.deactivateAll(reason: reason)
        pluginStateChangeRebuildTask?.cancel()
        pluginStateChangeRebuildTask = nil
        hideAllPanelItems()

        for plugin in activePlugins {
            guardPluginCall(plugin, operation: "deactivate plugin") {
                plugin.deactivate(reason: reason)
            }
        }
    }

    func refreshAll() {
        handlePluginAction(rebuildAfterAction: false) {
            for plugin in activePlugins {
                guardPluginCall(plugin, operation: "refresh") {
                    plugin.refresh()
                }
            }
        }

        actionRegistry.invalidateAvailability()
        rebuildDerivedState(synchronizingShortcuts: true)
    }

    /// Refreshes only providers whose live presentation is about to be shown.
    /// Stateful action surfaces use this to avoid stale external system state
    /// without turning Action Grid presentation into a full plugin refresh.
    func refreshActionPresentations(providerIDs: Set<String>) {
        guard !providerIDs.isEmpty else { return }

        handlePluginAction(rebuildAfterAction: false) {
            for plugin in activePlugins where providerIDs.contains(plugin.metadata.id) {
                guardPluginCall(plugin, operation: "refresh action presentation") {
                    plugin.refresh()
                }
            }
        }

        actionRegistry.invalidateAvailability()
        rebuildDerivedState(dirtyPluginIDs: providerIDs)
    }

    func makePreferencesBackup(
        selection requestedSelection: PreferencesBackupSelection? = nil
    ) -> PreferencesBackup {
        let shortcutDescriptors = shortcutDescriptors()
        var shortcutCustomizations = shortcutStore.customizations(
            for: shortcutDescriptors.map(\.itemID)
        )
        for action in AppShortcutAction.allCases {
            if let binding = resolvedAppShortcutBinding(for: action) {
                shortcutCustomizations[action.rawValue] = .custom(binding)
            }
        }

        let proposedSelection = requestedSelection ?? allPortablePreferencesSelection
        preferencesBackupExportSelection = proposedSelection
        defer { preferencesBackupExportSelection = nil }
        let proposedPortablePreferences = portablePluginPreferences()
        let selection = requestedSelection
            ?? .all(pluginPreferenceIDs: Set(proposedPortablePreferences.keys))
        var dependencySelection = selection
        dependencySelection.pluginPreferenceIDs.formIntersection(proposedPortablePreferences.keys)
        preferencesBackupExportSelection = dependencySelection

        let automationSnapshot = automationController.preferencesBackupSnapshot()
        let portableWorkflowIDs = WorkflowPortabilityAnalysis.portableWorkflowIDs(
            in: automationSnapshot.workflows,
            referencePortability: { reference in
                self.leafActionReferenceBackupPortability(
                    reference,
                    selection: dependencySelection
                )
            }
        )
        let portableWorkflows = automationSnapshot.workflows.filter {
            portableWorkflowIDs.contains($0.id)
        }
        let selectedPortablePreferences = proposedPortablePreferences.filter {
            selection.pluginPreferenceIDs.contains($0.key)
        }
        // These predicates never escape this synchronous export. Keep a strong
        // capture to avoid the premature weak-storage destruction in optimized builds.
        let referenceIsPortable: (ActionReference) -> Bool = { reference in
            self.actionReferenceBackupPortability(
                reference,
                workflows: automationSnapshot.workflows,
                portableWorkflowIDs: portableWorkflowIDs,
                selection: dependencySelection
            ) == .portable
        }
        return PreferencesBackup(
            application: preferencesBackupStore.applicationPreferences(),
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: orderedPluginIDs(), hiddenPluginIDs: [],
                panelConfiguration: menuBarPanelStore.configuration),
            shortcutCustomizations: selection.includesShortcuts ? shortcutCustomizations : [:],
            actionShortcutAssignments: selection.includesShortcuts
                ? shortcutAssignmentService.assignments.filter {
                    referenceIsPortable($0.reference)
                }
                : [],
            pluginPreferences: selectedPortablePreferences,
            pluginPreferenceActionReferences: portablePreferenceActionReferences(
                in: selectedPortablePreferences
            ),
            actionInvocationPresets: selection.includesRunLinks
                ? actionPresetStore.presets().compactMap { preset in
                    let migratedReference = migratedActionReferenceForRestore(preset.reference)
                    guard referenceIsPortable(migratedReference) else {
                        return nil
                    }
                    return ActionInvocationPreset(
                        id: preset.id,
                        reference: migratedReference,
                        createdAt: preset.createdAt,
                        formatVersion: preset.formatVersion
                    )
                }
                : [],
            workflows: selection.includesAutomation ? portableWorkflows : [],
            automationRules: selection.includesAutomation
                ? automationSnapshot.rules.filter {
                    portableWorkflowIDs.contains($0.workflowID)
                        && AutomationRulePortabilityAnalysis.isPortable($0)
                }
                : [],
            selection: selection
        )
    }

    var deviceLocalAutomationRuleCount: Int {
        automationController.rules.filter {
            AutomationRulePortabilityAnalysis.containsDeviceLocalReference($0)
        }.count
    }

    func preferencesImportPreview(
        for backup: PreferencesBackup,
        selection: PreferencesBackupSelection? = nil
    ) throws -> PreferencesImportPreview {
        let availableSelection = backup.effectiveSelection
        let effectiveSelection = (selection ?? availableSelection).intersecting(availableSelection)
        let restoreContext = makePreferencesActionRestoreContext(
            backup: backup,
            selection: effectiveSelection
        )
        let embeddedActionReferences = portablePreferenceActionReferences(
            in: backup,
            selection: effectiveSelection
        )
        return try PreferencesImportPreview.make(
            backup: backup,
            availablePluginIDs: Set(defaultPluginIDs),
            availableShortcutIDs: Set(
                AppShortcutAction.allCases.map(\.rawValue) + shortcutDescriptors().map(\.itemID)
            ),
            availableActionReferences: Set(actionCatalogEntries.map(\.reference)),
            additionalActionReferences: embeddedActionReferences,
            actionReferenceCanResolve: { [weak self] reference in
                self?.actionReferenceCanResolve(
                    reference,
                    context: restoreContext
                ) ?? false
            },
            actionReferenceIsRestorable: { [weak self] reference in
                guard let self else { return false }
                return self.actionReferenceRestorePortability(
                    reference,
                    context: restoreContext
                ) != .knownNonPortable
            },
            pluginManagementItems: pluginManagementItems,
            selection: effectiveSelection,
            applicationPreferencesAreValid: preferencesBackupStore.validates
        )
    }

    func importPreferences(
        _ backup: PreferencesBackup,
        installingMissingPluginIDs requestedPluginIDs: Set<String>,
        selection: PreferencesBackupSelection? = nil,
        progress: (PreferencesImportProgress) -> Void = { _ in }
    ) async throws -> PreferencesImportResult {
        let preview = try preferencesImportPreview(for: backup, selection: selection)
        let installablePluginIDs = Set(preview.installablePlugins.map(\.id))
        let pluginIDs = requestedPluginIDs.intersection(installablePluginIDs).sorted()
        var installedPluginIDs: [String] = []
        var pluginInstallationFailures: [String: String] = [:]

        progress(.preparing(pluginCount: pluginIDs.count))
        for (offset, pluginID) in pluginIDs.enumerated() {
            progress(.installingPlugin(
                id: pluginID,
                number: offset + 1,
                total: pluginIDs.count
            ))
            do {
                try await installPluginFromCatalog(pluginID: pluginID)
                installedPluginIDs.append(pluginID)
            } catch {
                pluginInstallationFailures[pluginID] = error.localizedDescription
            }
        }

        if !installedPluginIDs.isEmpty {
            loadDynamicPluginsIfNeeded()
        }

        progress(.restoringPreferences(
            completedPluginCount: pluginIDs.count,
            totalPluginCount: pluginIDs.count
        ))
        let pluginIDsAwaitingRestart = Set(pluginManagementItems
            .filter { $0.state == .restartRequired }
            .map(\.id))
            .subtracting(activePlugins.map { $0.metadata.id })
        let importedResult = try importPreferences(backup, selection: selection)
        var shortcutErrors = importedResult.shortcutErrors
        let deferredPluginPreferenceIDs = installedPluginIDs.filter { pluginID in
            guard pluginIDsAwaitingRestart.contains(pluginID) else { return false }
            return shortcutErrors.removeValue(forKey: "plugin-preferences.\(pluginID)") != nil
        }
        let result = PreferencesImportResult(
            installedPluginIDs: installedPluginIDs,
            deferredPluginPreferenceIDs: deferredPluginPreferenceIDs,
            pluginInstallationFailures: pluginInstallationFailures,
            shortcutErrors: shortcutErrors
        )
        return result
    }

    private struct CloudLocalPreferences {
        let workflows: [WorkflowDefinition]
        let rules: [AutomationRule]
        let shortcuts: [ActionShortcutAssignmentRecord]
        let presets: [ActionInvocationPreset]
        let shortcutCustomizations: [String: ShortcutCustomization]
        let protectedPluginIDs: Set<String>
        let pluginPreferences: [String: Data]

        var workflowIDs: Set<UUID> { Set(workflows.map(\.id)) }
    }

    /// Cloud updates replace portable records only. Local records are captured
    /// from their stores, since a portable backup deliberately omits them.
    func importCloudPreferences(_ backup: PreferencesBackup) throws -> PreferencesImportResult {
        let exported = makePreferencesBackup()
        let portable = CloudPreferencesSyncCoordinator.filterMachineSpecificPreferences(exported)
        let automation = automationController.preferencesBackupSnapshot()
        let portableWorkflowIDs = Set((portable.workflows ?? []).map(\.id))
        let portableRuleIDs = Set((portable.automationRules ?? []).map(\.id))
        let portableShortcutIDs = Set(portable.actionShortcutAssignments.map(\.id))
        let portablePresetIDs = Set((portable.actionInvocationPresets ?? []).map(\.id))
        let rules = automation.rules.filter { !portableRuleIDs.contains($0.id) }
        let shortcuts = shortcutAssignmentService.assignments.filter { !portableShortcutIDs.contains($0.id) }
        let presets = actionPresetStore.presets().filter { !portablePresetIDs.contains($0.id) }
        var protectedIDs = Set(automation.workflows.filter { !portableWorkflowIDs.contains($0.id) }.map(\.id))
        protectedIDs.formUnion(rules.map(\.workflowID))
        let references = shortcuts.map(\.reference) + presets.map(\.reference)
        protectedIDs.formUnion(references.compactMap { WorkflowExecutionAnalysis.nestedWorkflowID(for: $0.key) })
        var previousCount = -1
        while previousCount != protectedIDs.count {
            previousCount = protectedIDs.count
            for workflow in automation.workflows where protectedIDs.contains(workflow.id) {
                protectedIDs.formUnion(workflow.steps.compactMap {
                    WorkflowExecutionAnalysis.nestedWorkflowID(for: $0.reference.key)
                })
            }
        }
        let workflows = automation.workflows.filter { protectedIDs.contains($0.id) }
        let dependencyReferences = references + workflows.flatMap { $0.steps.map(\.reference) }
        // Plugin payloads are opaque, replacement-based archives. A provider used
        // by preserved local automation must retain its presets as well.
        let protectedPluginIDs = Set(dependencyReferences.compactMap { reference -> String? in
            guard WorkflowExecutionAnalysis.nestedWorkflowID(for: reference.key) == nil,
                  let plugin = corePlugin(for: reference.key.providerID),
                  let provider = plugin as? any PluginActionReferenceBackupProviding else { return nil }
            let disposition = guardedValue(for: plugin, operation: "preserve local action dependencies",
                                           provider.backupDisposition(for: reference))
            guard disposition == .requiresPluginPreferences else { return nil }
            return reference.key.providerID
        })
        let customizations = shortcutStore.customizations(for: shortcutDescriptors().map(\.itemID))
            .filter { portable.shortcutCustomizations[$0.key] == nil }
        let local = CloudLocalPreferences(
            workflows: workflows, rules: rules, shortcuts: shortcuts, presets: presets,
            shortcutCustomizations: customizations, protectedPluginIDs: protectedPluginIDs,
            pluginPreferences: exported.pluginPreferences
        )
        return try restorePreferences(backup, preserving: local)
    }

    private func preservingLocalWorkflows(
        _ context: PreferencesActionRestoreContext, local: CloudLocalPreferences?
    ) -> PreferencesActionRestoreContext {
        guard let local else { return context }
        return PreferencesActionRestoreContext(
            selection: context.selection,
            payloadDefinedActionReferencesByPluginID: context.payloadDefinedActionReferencesByPluginID,
            importedWorkflowIDs: context.importedWorkflowIDs.union(local.workflowIDs),
            restorableWorkflowIDs: context.restorableWorkflowIDs.union(local.workflowIDs),
            resolvableWorkflowIDs: context.resolvableWorkflowIDs.union(local.workflowIDs)
        )
    }

    func importPreferences(
        _ backup: PreferencesBackup,
        selection requestedSelection: PreferencesBackupSelection? = nil
    ) throws -> PreferencesImportResult {
        try restorePreferences(backup, selection: requestedSelection)
    }

    private func restorePreferences(
        _ backup: PreferencesBackup,
        selection requestedSelection: PreferencesBackupSelection? = nil,
        preserving local: CloudLocalPreferences? = nil
    ) throws -> PreferencesImportResult {
        let availableSelection = backup.effectiveSelection
        let selection = (requestedSelection ?? availableSelection).intersecting(availableSelection)
        _ = try preferencesImportPreview(for: backup, selection: selection)
        try automaticPreferencesBackupCoordinator?.createSafetySnapshotBeforeImport()
        var restoreContext = preservingLocalWorkflows(makePreferencesActionRestoreContext(
            backup: backup,
            selection: selection
        ), local: local)
        let selectedPluginPreferences = backup.pluginPreferences.filter {
            selection.pluginPreferenceIDs.contains($0.key)
                && !(local?.protectedPluginIDs.contains($0.key) ?? false)
        }
        let restoredPluginPreferences = selectedPluginPreferences.reduce(into: [String: Data]()) { result, entry in
            result[entry.key] = if let existing = local?.pluginPreferences[entry.key] {
                CloudPreferencesSyncCoordinator.preservingMachineSpecificPluginPreferences(
                    incoming: entry.value, local: existing, pluginID: entry.key
                )
            } else { entry.value }
        }
        let shortcutCustomizations = backup.shortcutCustomizations.merging(
            local?.shortcutCustomizations ?? [:], uniquingKeysWith: { _, local in local }
        )
        preferencesBackupRestoreContext = restoreContext
        defer {
            preferencesBackupRestoreContext = nil
        }
        if selection.includesApplicationPreferences {
            preferencesBackupStore.apply(backup.application)
        }

        if selection.includesPluginLayout {
            let panelConfiguration = backup.pluginDisplay.panelConfiguration
                ?? PanelLayoutMigrator.migrate(LegacyPanelLayout(),
                    preferences: LegacyPanelDisplayPreferences(backup: backup.pluginDisplay))
                    .applyingLegacyClickBehavior(backup.application.menuBarClickBehavior)
            menuBarPanelStore.replace(panelConfiguration, replacingUnreadable: true)
            menuBarPanels = menuBarPanelStore.configuration.displayPanels
            pluginOrderingStore.setOrderedPluginIDs(
                backup.pluginDisplay.orderedPluginIDs, defaultPluginIDs: defaultPluginIDs)
        }

        let actionSurfacePluginIDs = Set(activePlugins.compactMap { plugin in
            plugin is any ActionGridHostContextConsuming
                || plugin is any TrackpadActionHostContextConsuming
                ? plugin.metadata.id
                : nil
        })
        var shortcutErrors: [String: String] = [:]
        let providerPreferences = restoredPluginPreferences.filter {
            !actionSurfacePluginIDs.contains($0.key)
        }
        let restoredProviderIDs = restorePortablePluginPreferences(providerPreferences)
        for pluginID in providerPreferences.keys where !restoredProviderIDs.contains(pluginID) {
            shortcutErrors["plugin-preferences.\(pluginID)"] = AppL10n.preferencesBackupFormat(
                "preferencesBackup.import.pluginRestoreFailed",
                defaultValue: "无法恢复“%@”的插件设置。",
                corePlugin(for: pluginID)?.metadata.title ?? pluginID
            )
        }
        // Only a successfully validated and persisted payload can authorize actions that depend
        // on that payload. This closes the gap between preflight decoding and stateful restore.
        restoreContext = preservingLocalWorkflows(makePreferencesActionRestoreContext(
            backup: backup,
            selection: selection,
            restoredPluginPreferenceIDs: restoredProviderIDs
        ), local: local)
        preferencesBackupRestoreContext = restoreContext
        // Portable plugin settings can create action catalog identities (for example,
        // restored Fan Control preset UUIDs). Rebuild before dependent references.
        rebuildDerivedState()
        // Workflows are providers for nested workflow actions, so restore them before surfaces,
        // shortcuts, and Run Links that may depend on those identities.
        if selection.includesAutomation,
           let workflows = backup.workflows,
           let rules = backup.automationRules {
            let restorableIDs = restoreContext.restorableWorkflowIDs
            let restored = automationController.restorePreferences(
                workflows: workflows.compactMap { workflow in
                    restorableIDs.contains(workflow.id) && !(local?.workflowIDs.contains(workflow.id) ?? false)
                        ? migratedWorkflowForRestore(workflow)
                        : nil
                } + (local?.workflows ?? []),
                rules: rules.filter { rule in
                    restorableIDs.contains(rule.workflowID)
                        && AutomationRulePortabilityAnalysis.isPortable(rule)
                        && !(local?.rules.contains(where: { $0.id == rule.id }) ?? false)
                } + (local?.rules ?? [])
            )
            if !restored {
                shortcutErrors["automation"] = FeatureL10n.string("无法保存工作流。")
                restoreContext = PreferencesActionRestoreContext(
                    selection: restoreContext.selection,
                    payloadDefinedActionReferencesByPluginID:
                        restoreContext.payloadDefinedActionReferencesByPluginID,
                    importedWorkflowIDs: restoreContext.importedWorkflowIDs,
                    restorableWorkflowIDs: [],
                    resolvableWorkflowIDs: []
                )
                preferencesBackupRestoreContext = restoreContext
            }
        }
        // Action-surface layouts are restored only after their referenced providers and
        // workflow dependency graph are known, so a selective import cannot retain a
        // dangling Grid or Trackpad action.
        let surfacePreferences = restoredPluginPreferences.filter {
            actionSurfacePluginIDs.contains($0.key)
        }
        let restoredSurfaceIDs = restorePortablePluginPreferences(surfacePreferences)
        for pluginID in surfacePreferences.keys where !restoredSurfaceIDs.contains(pluginID) {
            shortcutErrors["plugin-preferences.\(pluginID)"] = AppL10n.preferencesBackupFormat(
                "preferencesBackup.import.pluginRestoreFailed",
                defaultValue: "无法恢复“%@”的插件设置。",
                corePlugin(for: pluginID)?.metadata.title ?? pluginID
            )
        }
        if selection.includesShortcuts {
            if backup.actionShortcutAssignmentsWereEncoded {
                let descriptors = shortcutDescriptors()
                let appCustomizations = Dictionary(
                    uniqueKeysWithValues: AppShortcutAction.allCases.map { action in
                        (
                            action,
                            shortcutCustomizations[action.rawValue]
                                ?? .inheritDefault
                        )
                    }
                )
                let targetCustomizations = Dictionary(
                    descriptors.map { descriptor in
                        (
                            descriptor.itemID,
                            shortcutCustomizations[descriptor.itemID]
                                ?? .inheritDefault
                        )
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                let customizationErrors = validateImportedShortcutCustomizations(
                    targetCustomizations,
                    descriptors: descriptors,
                    appCustomizations: appCustomizations
                )
                if !customizationErrors.isEmpty {
                    shortcutErrors.merge(
                        importShortcutErrorMessages(
                            customizationErrors,
                            descriptors: descriptors
                        ),
                        uniquingKeysWith: { existing, _ in existing }
                    )
                } else {
                    let reservedState = importedReservedShortcutState(
                        customizations: targetCustomizations,
                        descriptors: descriptors
                    )
                    let importedAssignments = backup.actionShortcutAssignments.filter { assignment in
                        actionReferenceRestorePortability(assignment.reference) != .knownNonPortable
                            && !(local?.shortcuts.contains(where: { $0.id == assignment.id }) ?? false)
                    } + (local?.shortcuts ?? [])
                    switch shortcutAssignmentService.validateImport(
                        importedAssignments,
                        reservedRegistrations: reservedState.registrations,
                        reservedOwnerDescriptions: reservedState.ownerDescriptions
                    ) {
                    case let .failure(error):
                        shortcutErrors["action-shortcuts"] = error.localizedDescription
                    case .success:
                        switch shortcutAssignmentService.replaceAllForImport(
                            importedAssignments,
                            reservedRegistrations: reservedState.registrations,
                            reservedOwnerDescriptions: reservedState.ownerDescriptions
                        ) {
                        case let .failure(error):
                            shortcutErrors["action-shortcuts"] = error.localizedDescription
                        case .success:
                            shortcutErrors.merge(
                                applyImportedShortcutCustomizations(
                                    shortcutCustomizations,
                                    bridgesLegacyActionAssignments: false,
                                    notifiesActionBackedDescriptors: false
                                ),
                                uniquingKeysWith: { existing, _ in existing }
                            )
                            notifyAllActionBackedShortcutBindings()
                        }
                    }
                }
            } else {
                shortcutErrors.merge(
                    applyImportedShortcutCustomizations(
                        shortcutCustomizations,
                        bridgesLegacyActionAssignments: true
                    ),
                    uniquingKeysWith: { existing, _ in existing }
                )
            }
        }
        if selection.includesRunLinks,
           let presets = backup.actionInvocationPresets,
           !actionPresetStore.replaceAllForRecovery(presets.compactMap { preset in
               guard actionReferenceRestorePortability(preset.reference) != .knownNonPortable,
                     !(local?.presets.contains(where: { $0.id == preset.id }) ?? false) else {
                   return nil
               }
               return ActionInvocationPreset(
                   id: preset.id,
                   reference: migratedActionReferenceForRestore(preset.reference),
                   createdAt: preset.createdAt,
                   formatVersion: preset.formatVersion
               )
           } + (local?.presets ?? [])) {
            shortcutErrors["run-links"] = FeatureL10n.string("无法保存运行链接预设。")
        }
        rebuildDerivedState(synchronizingShortcuts: true)
        return PreferencesImportResult(
            installedPluginIDs: [],
            pluginInstallationFailures: [:],
            shortcutErrors: shortcutErrors
        )
    }

    /// Rebuild language-dependent host data without refreshing or reactivating
    /// plugins, which keeps active plugin sessions and external side effects intact.
    func refreshLocalization() {
        for plugin in activePlugins {
            guard let localizationRefreshing = plugin as? any PluginRuntimeLocalizationRefreshing else {
                continue
            }

            guardPluginCall(plugin, operation: "refresh localization") {
                localizationRefreshing.refreshLocalization()
            }
        }
        panelCoordinator.clearWidgetViews()
        settingsViewCache.removeAll()
        dynamicPluginManager?.refreshLocalization()
        syncPluginManagementState()
        menuBarIconCoordinator.refreshPrimaryIconOwner(
            pluginTitle: menuBarIconCoordinator.primaryIconOwner.flatMap {
                dynamicPluginManifestsByID[$0.pluginID]?.localizedDisplayName
            }
        )
        localizationRevision &+= 1
        rebuildDerivedState(synchronizingShortcuts: true)
    }

    func refreshDisplayTopology() {
        displayTopologyRefreshTask?.cancel()
        refreshDisplayTopologyNow()
    }

    func isSwitchOn(for itemID: String) -> Bool {
        guard let item = panelCoordinator.item(for: itemID),
              case let .row(row) = item.definition.content else { return false }
        return row.state.isOn
    }

    func setSwitchValue(_ isOn: Bool, for itemID: String) {
        performPanelAction(.setSwitch(isOn), itemID: itemID)
    }

    func setDisclosureExpanded(_ isExpanded: Bool, for itemID: String) {
        panelCoordinator.setExpanded(isExpanded, id: itemID)
        performPanelAction(.setDisclosureExpanded(panelCoordinator.hasExpandedPlacement(for: itemID)), itemID: itemID)
    }

    func setPanelSelectionValue(_ optionID: String, controlID: String, for itemID: String) {
        performPanelAction(.setSelection(controlID: controlID, optionID: optionID), itemID: itemID)
    }

    func setPanelNavigationSelectionValue(_ optionID: String, controlID: String, for itemID: String) {
        panelCoordinator.setNavigationSelection(optionID, controlID: controlID, id: itemID)
        performPanelAction(.setNavigationSelection(controlID: controlID, optionID: optionID), itemID: itemID)
    }

    func clearPanelNavigationSelection(controlID: String, for itemID: String) {
        panelCoordinator.setNavigationSelection(nil, controlID: controlID, id: itemID)
        performPanelAction(.clearNavigationSelection(controlID: controlID), itemID: itemID)
    }

    func setPanelDateValue(_ date: Date, controlID: String, for itemID: String) {
        performPanelAction(.setDate(controlID: controlID, value: date), itemID: itemID)
    }

    func setPanelSliderValue(_ value: Double, controlID: String, for itemID: String,
                             phase: PluginPanelAction.SliderPhase) {
        performPanelAction(.setSlider(controlID: controlID, value: value, phase: phase),
                           itemID: itemID, rebuild: phase == .ended)
    }

    func invokePanelAction(controlID: String, for itemID: String) {
        performPanelAction(.invokeAction(controlID: controlID), itemID: itemID)
    }

    private func performPanelAction(_ action: PluginPanelAction, itemID: String, rebuild: Bool = true) {
        guard let item = panelCoordinator.item(for: itemID),
              let plugin = corePlugin(for: item.key.pluginID),
              !isPluginIsolated(plugin), case let .row(row) = item.definition.content else { return }
        handlePluginAction(rebuildAfterAction: false) {
            guardPluginCall(plugin, operation: "perform panel item action") { row.action(action) }
        }
        if rebuild || isPluginIsolated(plugin) {
            rebuildDerivedState(dirtyPluginIDs: [item.key.pluginID])
        }
    }

    func performSettingsAction(pluginID: String, action: PluginSettingsAction) {
        guard let plugin = corePlugin(for: pluginID) else {
            return
        }

        let rebuildAfterAction: Bool
        switch action {
        case let .setNumber(_, _, phase), let .setText(_, _, phase):
            rebuildAfterAction = phase == .committed
        default:
            rebuildAfterAction = true
        }

        handlePluginAction(rebuildAfterAction: rebuildAfterAction) {
            guardPluginCall(plugin, operation: "settings action") {
                plugin.handleSettingsAction(action)
            }
        }
    }

    @discardableResult
    func performCommand(
        pluginID: String,
        expectedDefinition: PluginCommandDefinition
    ) -> Bool {
        guard
            let plugin = corePlugin(for: pluginID),
            let commandProvider = plugin as? any PluginCommandProviding,
            (guardedValue(
                for: plugin,
                operation: "read command definitions",
                commandProvider.commandDefinitions
            ) ?? []).contains(expectedDefinition)
        else {
            rebuildDerivedState()
            return false
        }

        var didPerform = false
        handlePluginAction {
            didPerform = guardPluginCall(plugin, operation: "perform command") {
                commandProvider.handleCommand(id: expectedDefinition.id)
            }
        }
        return didPerform
    }

    @discardableResult
    func performAppCommand(_ action: AppShortcutAction) -> Bool {
        guard let appPresentationHandler else {
            return false
        }

        appPresentationHandler(action.presentationRequest)
        return true
    }

    func performPermissionAction(
        pluginID: String,
        permissionID: String,
        sourceFrame: CGRect? = nil
    ) {
        if permissionCoordinator.performAction(
            pluginID: pluginID,
            permissionID: permissionID,
            sourceFrame: sourceFrame
        ) {
            return
        }
        performSpecializedPermissionAction(
            pluginID: pluginID,
            permissionID: permissionID
        )
    }

    private func performSpecializedPermissionAction(
        pluginID: String,
        permissionID: String
    ) {
        guard let plugin = corePlugin(for: pluginID) else {
            return
        }

        let requirement = guardedValue(
            for: plugin,
            operation: "read permission requirements",
            plugin.permissionRequirements
        )?.first { $0.id == permissionID }
        if let requirement,
           case .system(.automation) = permissionPresentationRole(for: requirement),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            // Explicit button clicks should navigate; passive guidance requests retain context.
            openPermissionSettings(url)
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "permission action") {
                plugin.handlePermissionAction(id: permissionID)
            }
        }
    }

    func setShortcutBinding(_ binding: ShortcutBinding, for shortcutID: String) {
        guard let target = shortcutMutationTarget(for: shortcutID) else {
            return
        }

        guard shortcutValidationMessage(binding, for: target.descriptor) == nil else {
            return
        }

        applyShortcutCustomization(
            .custom(binding),
            for: target.descriptor,
            assignmentID: target.assignmentID
        )
    }

    func setShortcutBindingAndReturnError(_ binding: ShortcutBinding, for shortcutID: String) -> String? {
        guard let target = shortcutMutationTarget(for: shortcutID) else {
            return AppL10n.plugins("plugin.shortcut.unavailable", defaultValue: "快捷键不可用。")
        }

        if let message = shortcutValidationMessage(binding, for: target.descriptor) {
            return message
        }

        return applyShortcutCustomization(
            .custom(binding),
            for: target.descriptor,
            assignmentID: target.assignmentID
        )
    }

    struct ShortcutBindingConflict: Identifiable, Equatable {
        let targetShortcutID: String
        let conflictingShortcutIDs: [String]
        let binding: ShortcutBinding
        let ownerDescription: String
        let canSwap: Bool

        var id: String {
            "\(targetShortcutID)|\(conflictingShortcutIDs.joined(separator: ","))|\(binding.keyCode)|\(binding.modifiers.rawValue)"
        }
    }

    enum ShortcutConflictResolution {
        case swap
        case replace
    }

    func shortcutBindingConflict(
        for binding: ShortcutBinding,
        targetShortcutID: String
    ) -> ShortcutBindingConflict? {
        guard let target = shortcutMutationTarget(for: targetShortcutID),
              actionReference(for: target.descriptor) == nil
        else { return nil }
        let conflicts = shortcutDescriptors().filter {
            $0.itemID != target.descriptor.itemID
                && resolvedBinding(for: $0) == binding
                && !canShareShortcutBinding(target.descriptor, with: $0)
        }
        guard !conflicts.isEmpty,
              conflicts.allSatisfy({ actionReference(for: $0) == nil })
        else { return nil }

        return ShortcutBindingConflict(
            targetShortcutID: target.descriptor.itemID,
            conflictingShortcutIDs: conflicts.map(\.itemID),
            binding: binding,
            ownerDescription: conflicts.map {
                "\($0.pluginTitle) · \($0.definition.title)"
            }.joined(separator: ", "),
            canSwap: conflicts.count == 1 && resolvedBinding(for: target.descriptor) != nil
        )
    }

    @discardableResult
    func resolveShortcutBindingConflict(
        _ conflict: ShortcutBindingConflict,
        resolution: ShortcutConflictResolution
    ) -> String? {
        guard let target = shortcutDescriptor(for: conflict.targetShortcutID),
              actionReference(for: target) == nil,
              !conflict.conflictingShortcutIDs.isEmpty
        else {
            let message = AppL10n.plugins(
                "plugin.shortcut.conflictChanged",
                defaultValue: "快捷键冲突已发生变化，请重试。"
            )
            shortcutErrors[conflict.targetShortcutID] = message
            rebuildDerivedState()
            return message
        }
        let previousOwners = conflict.conflictingShortcutIDs.compactMap(shortcutDescriptor(for:))
        let currentConflictingOwnerIDs = Set(shortcutDescriptors().filter {
            $0.itemID != target.itemID
                && resolvedBinding(for: $0) == conflict.binding
                && !canShareShortcutBinding(target, with: $0)
        }.map(\.itemID))
        guard previousOwners.count == conflict.conflictingShortcutIDs.count,
              previousOwners.allSatisfy({ actionReference(for: $0) == nil }),
              Set(conflict.conflictingShortcutIDs) == currentConflictingOwnerIDs
        else {
            let message = AppL10n.plugins(
                "plugin.shortcut.conflictChanged",
                defaultValue: "快捷键冲突已发生变化，请重试。"
            )
            shortcutErrors[conflict.targetShortcutID] = message
            rebuildDerivedState()
            return message
        }

        if let message = shortcutValidationMessage(conflict.binding, for: target) {
            shortcutErrors[target.itemID] = message
            rebuildDerivedState()
            return message
        }
        let previousTargetBinding = resolvedBinding(for: target)
        if resolution == .swap {
            guard conflict.canSwap,
                  previousOwners.count == 1,
                  let previousOwner = previousOwners.first,
                  let previousTargetBinding
            else {
                let message = AppL10n.plugins(
                    "plugin.shortcut.conflictChanged",
                    defaultValue: "快捷键冲突已发生变化，请重试。"
                )
                shortcutErrors[target.itemID] = message
                rebuildDerivedState()
                return message
            }
            if let message = shortcutValidationMessage(previousTargetBinding, for: previousOwner) {
                shortcutErrors[target.itemID] = message
                rebuildDerivedState()
                return message
            }
            if let remainingConflict = shortcutDescriptors().first(where: {
                $0.itemID != target.itemID
                    && $0.itemID != previousOwner.itemID
                    && resolvedBinding(for: $0) == previousTargetBinding
                    && !canShareShortcutBinding(previousOwner, with: $0)
            }) {
                let message = ShortcutValidationError.duplicate(
                    ownerDescription: "\(remainingConflict.pluginTitle) · \(remainingConflict.definition.title)"
                ).localizedDescription
                shortcutErrors[target.itemID] = message
                rebuildDerivedState()
                return message
            }
        }

        let originalTargetCustomization = shortcutStore.customization(for: target.itemID)
        let originalOwnerCustomizations = Dictionary(uniqueKeysWithValues: previousOwners.map {
            ($0.itemID, shortcutStore.customization(for: $0.itemID))
        })
        for previousOwner in previousOwners {
            let customization: ShortcutCustomization = if resolution == .swap {
                previousTargetBinding.map(ShortcutCustomization.custom) ?? .cleared
            } else {
                .cleared
            }
            shortcutStore.setCustomization(customization, for: previousOwner.itemID)
        }
        shortcutStore.setCustomization(.custom(conflict.binding), for: target.itemID)

        let ownersMatchExpectedBindings = previousOwners.allSatisfy { previousOwner in
            let expectedBinding = resolution == .swap ? previousTargetBinding : nil
            return legacyResolvedBinding(for: previousOwner) == expectedBinding
        }
        let destinationStillConflicts = shortcutDescriptors().contains {
            $0.itemID != target.itemID
                && resolvedBinding(for: $0) == conflict.binding
                && !canShareShortcutBinding(target, with: $0)
        }
        let swappedBindingStillConflicts: Bool = if resolution == .swap,
                                                   let previousOwner = previousOwners.first,
                                                   let previousTargetBinding {
            shortcutDescriptors().contains {
                $0.itemID != target.itemID
                    && $0.itemID != previousOwner.itemID
                    && resolvedBinding(for: $0) == previousTargetBinding
                    && !canShareShortcutBinding(previousOwner, with: $0)
            }
        } else {
            false
        }
        guard legacyResolvedBinding(for: target) == conflict.binding,
              ownersMatchExpectedBindings,
              !destinationStillConflicts,
              !swappedBindingStillConflicts
        else {
            shortcutStore.setCustomization(originalTargetCustomization, for: target.itemID)
            for previousOwner in previousOwners {
                shortcutStore.setCustomization(
                    originalOwnerCustomizations[previousOwner.itemID] ?? .inheritDefault,
                    for: previousOwner.itemID
                )
            }
            let message = AppL10n.plugins(
                "plugin.shortcut.saveFailed",
                defaultValue: "无法保存快捷键。"
            )
            shortcutErrors[target.itemID] = message
            rebuildDerivedState()
            return message
        }

        shortcutErrors.removeValue(forKey: target.itemID)
        notifyShortcutBindingChange(for: target, binding: conflict.binding)
        for previousOwner in previousOwners {
            shortcutErrors.removeValue(forKey: previousOwner.itemID)
            notifyShortcutBindingChange(
                for: previousOwner,
                binding: resolution == .swap ? previousTargetBinding : nil
            )
        }
        rebuildDerivedState(synchronizingShortcuts: true)
        return nil
    }

    private func shortcutValidationMessage(
        _ binding: ShortcutBinding,
        for descriptor: ShortcutDescriptor
    ) -> String? {
        guard let validator = descriptor.plugin as? any PluginShortcutBindingValidating else {
            return nil
        }
        return guardedValue(
            for: descriptor.plugin,
            operation: "validate shortcut binding",
            validator.shortcutValidationMessage(
                definitionID: descriptor.definition.id,
                binding: binding
            )
        ) ?? nil
    }

    func setAppShortcutBindingAndReturnError(
        _ binding: ShortcutBinding,
        for action: AppShortcutAction,
        assignmentID: UUID? = nil
    ) -> String? {
        let result = shortcutAssignmentService.assign(
            binding,
            to: actionReference(for: action),
            assignmentID: assignmentID
        )
        switch result {
        case .success:
            appShortcutErrors.removeValue(forKey: action)
            rebuildDerivedState(synchronizingShortcuts: true)
            return nil
        case let .failure(error):
            appShortcutErrors[action] = error.localizedDescription
            rebuildDerivedState()
            return error.localizedDescription
        }
    }

    func clearAppShortcut(_ action: AppShortcutAction, assignmentID: UUID? = nil) {
        let reference = actionReference(for: action)
        let targetID = assignmentID
            ?? shortcutAssignmentService.assignment(for: reference)?.id
        let result = shortcutAssignmentService.clear(reference, assignmentID: targetID)
        switch result {
        case .success:
            appShortcutErrors.removeValue(forKey: action)
        case let .failure(error):
            appShortcutErrors[action] = error.localizedDescription
        }
        rebuildDerivedState(synchronizingShortcuts: true)
    }

    func clearAppShortcutError(_ action: AppShortcutAction) {
        guard appShortcutErrors[action] != nil else {
            return
        }

        appShortcutErrors.removeValue(forKey: action)
        rebuildDerivedState()
    }

    func setActionShortcutBindingAndReturnError(
        _ binding: ShortcutBinding,
        for reference: ActionReference,
        assignmentID: UUID? = nil,
        replacingConflictingActionAssignments: Bool = false
    ) -> String? {
        let result = setActionShortcutBinding(
            binding,
            to: reference,
            assignmentID: assignmentID,
            replacingConflictingActionAssignments: replacingConflictingActionAssignments
        )
        if case .success = result {
            return nil
        }
        if case let .failure(error) = result {
            return error.localizedDescription
        }
        return nil
    }

    func setActionShortcutBinding(
        _ binding: ShortcutBinding,
        to reference: ActionReference,
        assignmentID: UUID? = nil,
        replacingConflictingActionAssignments: Bool = false
    ) -> ActionShortcutMutationResult {
        let previousBindings = actionBackedShortcutBindings()
        let result = shortcutAssignmentService.assign(
            binding,
            to: reference,
            assignmentID: assignmentID,
            replacingConflictingActionAssignments: replacingConflictingActionAssignments
        )
        switch result {
        case .success:
            rebuildDerivedState(synchronizingShortcuts: true)
            notifyChangedActionBackedShortcutBindings(previous: previousBindings)
        case .failure:
            break
        }
        return result
    }

    func clearActionShortcut(for reference: ActionReference, assignmentID: UUID? = nil) {
        let previousBindings = actionBackedShortcutBindings()
        guard case .success = shortcutAssignmentService.clear(
            reference,
            assignmentID: assignmentID
        ) else {
            return
        }
        rebuildDerivedState(synchronizingShortcuts: true)
        notifyChangedActionBackedShortcutBindings(previous: previousBindings)
    }

    func actionShortcutSettingsItem(
        for reference: ActionReference
    ) -> ActionShortcutSettingsItem? {
        shortcutAssignmentService.settingsItem(for: reference)
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        actionRegistry.availability(for: reference)
    }

    var appIntentEligibleActionCount: Int {
        MacToolsAppIntentActionCatalog(registry: actionRegistry)
            .actions(includeUnavailable: false)
            .count
    }

    func actionExposurePolicy(
        for reference: ActionReference,
        on surface: ActionExposureSurface
    ) -> ActionExposurePolicy {
        actionRegistry.exposurePolicy(for: reference, on: surface)
    }

    func actionPermissionTitles(for reference: ActionReference) -> [String] {
        guard let plugin = corePlugin(for: reference.key.providerID),
              let provider = plugin as? any PluginActionPermissionProviding,
              let permissionIDs = guardedValue(
                  for: plugin,
                  operation: "read action permission requirements",
                  provider.permissionRequirementIDs(for: reference.key)
              ),
              let requirements = guardedValue(
                  for: plugin,
                  operation: "read permission requirements",
                  plugin.permissionRequirements
              ) else {
            return []
        }
        let requirementsByID = Dictionary(
            requirements.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return permissionIDs.compactMap { requirementsByID[$0]?.title }
    }

    func actionRunLinkPresentation(
        for reference: ActionReference
    ) -> ActionRunLinkPresentation {
        actionRunLinkService.presentation(for: reference)
    }

    func createActionRunLink(
        for reference: ActionReference
    ) -> Result<ActionRunLinkRepresentation, ActionInvocationPresetError> {
        let result = actionRunLinkService.createPreset(for: reference)
        if case .success = result {
            objectWillChange.send()
        }
        return result
    }

    func deleteActionRunLinkPreset(for reference: ActionReference) {
        guard actionRunLinkService.deletePreset(for: reference) else {
            return
        }
        objectWillChange.send()
    }

    func clearShortcut(for shortcutID: String) {
        guard let target = shortcutMutationTarget(for: shortcutID) else {
            return
        }

        applyShortcutCustomization(
            .cleared,
            for: target.descriptor,
            assignmentID: target.assignmentID
        )
    }

    func resetShortcut(for shortcutID: String) {
        guard let target = shortcutMutationTarget(for: shortcutID) else {
            return
        }

        applyShortcutCustomization(
            .inheritDefault,
            for: target.descriptor,
            assignmentID: target.assignmentID
        )
    }

    private func resetShortcuts(pluginID: String, definitionIDs: [String]) {
        let ids = Set(definitionIDs)
        guard !ids.isEmpty else { return }
        let descriptors = shortcutDescriptors()
        let targets = descriptors.filter { $0.pluginID == pluginID && ids.contains($0.definition.id) }
        guard !targets.isEmpty else { return }
        for descriptor in targets {
            applyShortcutCustomization(.inheritDefault, for: descriptor,
                                       descriptors: descriptors, updatesPresentation: false)
        }
        rebuildDerivedState(synchronizingShortcuts: true)
    }

    func presentPluginSettings(pluginID: String) {
        rebuildDerivedState()

        guard pluginSettingsItems.contains(where: { $0.id == pluginID }) else {
            return
        }

        appPresentationHandler?(.settings(.pluginConfiguration(pluginID)))
    }

    func installActionGridPresenter(
        _ presenter: @escaping ([ActionGridPresentationEntry], ActionExecutionSource) -> Bool
    ) {
        actionGridPresentationHandler = presenter
        actionRegistry.invalidateAvailability()
    }

    func installFocusedHostWindowProvider(_ provider: @escaping () -> NSWindow?) {
        focusedApplicationTargetProvider.currentHostWindowProvider = provider
    }

    func focusedPluginWindowLayoutTarget() -> NSWindow? {
        activePlugins.lazy
            .compactMap { plugin in
                (plugin as? any PluginWindowLayoutTargetProviding)?.focusedWindowLayoutTarget
            }
            .first { window in
                window.isVisible && (window.isKeyWindow || (window.childWindows ?? []).contains {
                    $0.parent === window && $0.isVisible && $0.isKeyWindow
                })
            }
    }

    func captureCurrentFocusedWindowTarget() {
        focusedApplicationTargetProvider.captureCurrentTarget()
    }

    func presentPluginMarketplace() {
        appPresentationHandler?(.settings(.pluginMarketplace))
    }

    func presentPermissionCenter() {
        rebuildDerivedState()
        appPresentationHandler?(.settings(.permissions))
    }

    @discardableResult
    func selectFeatureSettingsPane(_ pane: FeatureSettingsPane) -> Bool {
        switch pane {
        case .actionsAndShortcuts, .automation, .marketplace:
            return true
        case let .configuration(pluginID):
            guard pluginSettingsItems.contains(where: { $0.id == pluginID }) else {
                return false
            }

            return true
        }
    }

    func hasPluginSettings(pluginID: String) -> Bool {
        pluginSettingsItems.contains(where: { $0.id == pluginID })
    }

    func hasMarketplaceDetail(target: MarketplacePluginDetailTarget) -> Bool {
        guard let item = pluginManagementItems.first(where: { $0.id == target.pluginID }) else {
            return false
        }

        guard let highlight = target.actionHighlight else {
            return true
        }

        return item.productMetadata?.actions?.providers.contains { provider in
            provider.id == highlight.providerID
                && provider.staticActions.contains { $0.id == highlight.actionID }
        } == true
    }

    func hasPluginSettingsSearchField(pluginID: String) -> Bool {
        guard hasPluginSettings(pluginID: pluginID) else { return false }
        guard let plugin = corePlugin(for: pluginID),
              plugin is any PluginSettingsSearchFocusing else {
            return false
        }
        return (plugin as? any PluginSettingsSearchFocusMetadataProviding)?
            .isSettingsSearchAvailable ?? true
    }

    func pluginSettingsSearchFocusTarget(pluginID: String) -> PluginSettingsSearchTarget? {
        guard hasPluginSettingsSearchField(pluginID: pluginID),
              let metadata = corePlugin(for: pluginID)
                as? any PluginSettingsSearchFocusMetadataProviding else {
            return nil
        }
        return metadata.settingsSearchFocusTarget
    }

    @discardableResult
    func focusPluginSettingsSearch(pluginID: String) -> Bool {
        guard hasPluginSettingsSearchField(pluginID: pluginID),
              let plugin = corePlugin(for: pluginID),
              let searchFocusing = plugin as? any PluginSettingsSearchFocusing else {
            return false
        }
        return guardPluginCall(plugin, operation: "focus settings search") {
            searchFocusing.focusSettingsSearch()
        }
    }

    func hasPluginSettingsSearchTarget(
        _ target: PluginSettingsSearchTarget
    ) -> Bool {
        cancelScheduledPluginStateRebuild()
        rebuildDerivedState()

        guard let item = pluginSettingsItems.first(where: {
            $0.pluginID == target.pluginID
        }) else {
            return false
        }

        if item.missingPermissionCards.contains(where: { $0.id == target.entryID }) {
            return true
        }

        for section in item.sections where section.isVisible {
            if section.id == target.entryID {
                return true
            }
            if case let .rows(rows) = section.content,
               rows.contains(where: { $0.isVisible && $0.id == target.entryID }) {
                return true
            }
        }

        if item.shortcutItems.allSatisfy({ $0.settingsGroupID != nil }) {
            if item.shortcutItems.contains(where: {
                $0.settingsGroupID == target.entryID
            }) {
                return true
            }
        } else if item.shortcutItems.contains(where: {
            $0.id == target.entryID
        }) {
            return true
        }

        return item.hasPluginContent
            && pluginSettingsSearchItems.contains {
                $0.pluginID == target.pluginID
                    && $0.entry.id == target.entryID
            }
    }

    func clearShortcutError(for shortcutID: String) {
        let errorID = shortcutMutationMetadataByRowID[shortcutID]?.shortcutID
            ?? shortcutID
        guard shortcutErrors.removeValue(forKey: errorID) != nil else {
            return
        }

        rebuildDerivedState()
    }


    func componentViewItem(for itemID: String, dismiss: @escaping () -> Void) -> PluginPanelWidgetViewItem {
        let content = panelCoordinator.widgetView(for: itemID, dismiss: dismiss) { [weak self] detailID in
            guard let self, let entry = self.panelCoordinator.entry(for: itemID),
                  let panelID = self.menuBarPanelStore.configuration.panelID(for: entry.placement.id),
                  self.visibleMenuBarPanelID == panelID else { return }
            self.componentDetailHandlersByPanelID[panelID]?(itemID, detailID)
        } ?? AnyView(EmptyView())
        return PluginPanelWidgetViewItem(id: itemID, content: content)
    }

    func componentPreviewView(for itemID: String,
                              reportContentHeight: @escaping (CGFloat) -> Void = { _ in }) -> AnyView? {
        guard let item = panelCoordinator.item(for: itemID),
              case let .widget(widget) = item.definition.content,
              let plugin = corePlugin(for: item.key.pluginID) else { return nil }
        return guardedValue(for: plugin, operation: "make widget preview",
            widget.makeView(PluginPanelWidgetContext(pluginID: item.key.pluginID,
                itemID: item.key.itemID, placementID: nil, dismiss: {},
                reportContentHeight: reportContentHeight)))
    }

    func componentDetailContent(placementID itemID: String, detailID: String,
                                dismiss: @escaping () -> Void) -> PluginPanelDetailContent? {
        guard let item = panelCoordinator.item(for: itemID),
              let plugin = corePlugin(for: item.key.pluginID),
              case let .widget(widget) = item.definition.content else { return nil }
        return guardedOptionalValue(for: plugin, operation: "make panel item detail",
                                    widget.makeDetail?(detailID, dismiss))
    }

    func isComponentViewCached(for itemID: String) -> Bool {
        panelCoordinator.isWidgetViewCached(itemID)
    }

    func pluginSettingsContentViewItem(
        for pluginID: String,
        sectionID: String? = nil
    ) -> PluginSettingsContentViewItem {
        let cacheKey = SettingsViewCacheKey(
            pluginID: pluginID,
            content: sectionID.map(SettingsViewCacheKey.Content.section) ?? .workspace
        )
        if let cachedItem = settingsViewCache[cacheKey] {
            return cachedItem
        }

        guard
            let plugin = corePlugin(for: pluginID),
            let page = pluginSettingsItems.first(where: { $0.pluginID == pluginID })?.page
        else {
            rebuildDerivedState()
            return PluginSettingsContentViewItem(id: cacheKey.itemID, content: AnyView(EmptyView()))
        }

        let context = makePluginSettingsContext(pluginID: pluginID)
        let content: AnyView

        switch (page.body, sectionID) {
        case let (.workspace(workspace), nil):
            content = guardedSettingsView(
                for: plugin,
                operation: "make settings workspace",
                workspace.makeView(context)
            )
        case let (.form(sections), .some(sectionID)):
            guard
                let section = sections.first(where: { $0.id == sectionID }),
                case let .custom(customContent) = section.content
            else {
                return PluginSettingsContentViewItem(id: cacheKey.itemID, content: AnyView(EmptyView()))
            }
            content = guardedSettingsView(
                for: plugin,
                operation: "make custom settings section",
                customContent.makeView(context)
            )
        default:
            content = AnyView(EmptyView())
        }

        guard corePlugin(for: pluginID) != nil else {
            rebuildDerivedState()
            return PluginSettingsContentViewItem(id: cacheKey.itemID, content: AnyView(EmptyView()))
        }

        let item = PluginSettingsContentViewItem(
            id: cacheKey.itemID,
            content: AnyView(content.id(localizationRevision))
        )
        settingsViewCache[cacheKey] = item
        return item
    }

    func pluginSettingsHeaderAccessoryViewItem(
        for pluginID: String,
        sectionID: String
    ) -> PluginSettingsContentViewItem {
        let cacheKey = SettingsViewCacheKey(
            pluginID: pluginID,
            content: .sectionAccessory(sectionID)
        )
        if let cachedItem = settingsViewCache[cacheKey] {
            return cachedItem
        }

        guard
            let plugin = corePlugin(for: pluginID),
            let page = pluginSettingsItems.first(where: { $0.pluginID == pluginID })?.page,
            case let .form(sections) = page.body,
            let section = sections.first(where: { $0.id == sectionID }),
            let accessory = section.headerAccessory
        else {
            return PluginSettingsContentViewItem(
                id: cacheKey.itemID,
                content: AnyView(EmptyView())
            )
        }

        let context = makePluginSettingsContext(pluginID: pluginID)
        let content = guardedSettingsView(
            for: plugin,
            operation: "make settings section header accessory",
            accessory.makeView(context)
        )
        let item = PluginSettingsContentViewItem(
            id: cacheKey.itemID,
            content: AnyView(content.id(localizationRevision))
        )
        settingsViewCache[cacheKey] = item
        return item
    }

    func setPluginSettingsPage(_ pluginID: String, visible: Bool) {
        guard
            let plugin = corePlugin(for: pluginID),
            let page = pluginSettingsItems.first(where: { $0.pluginID == pluginID })?.page,
            let visibilityHandler = page.visibilityHandler
        else {
            return
        }

        guardPluginCall(
            plugin,
            operation: visible ? "show settings page" : "hide settings page"
        ) {
            visibilityHandler(visible)
        }
    }

    func discardComponentViews() {
        panelCoordinator.clearWidgetViews()
    }

    func recheckPluginRequirements() {
        dynamicPluginManager?.reloadInstalledPlugins()
        syncPluginManagementState()
    }

    func refreshPluginCatalog() async {
        let installedMetadata = await pluginCatalogManager?.refreshCatalog()
        syncPluginManagementState(installedMetadata: installedMetadata)
    }

    private func startCloudPreferencesSyncIfReady() {
        guard dynamicPluginManager == nil || didLoadDynamicPlugins else { return }
        areCloudPreferencesReady = true
        cloudPreferencesSyncCoordinator?.start()
    }

    func loadDynamicPluginsIfNeeded() {
        guard !didLoadDynamicPlugins, let dynamicPluginManager else {
            return
        }

        dynamicPlugins = dynamicPluginManager.loadInstalledPlugins()
        didLoadDynamicPlugins = true
        configureCallbacks(for: dynamicPlugins)
        syncPluginManagementState()
        refreshAll()
        startCloudPreferencesSyncIfReady()
    }

    /// True while installed dynamic plugins are still being updated or loaded,
    /// so empty panels can show progress instead of an install prompt.
    var isPreparingPlugins: Bool {
        automaticPluginUpdateStatus.isActive || (dynamicPluginManager != nil && !didLoadDynamicPlugins)
    }

    var hasInstalledDynamicPlugins: Bool {
        guard let dynamicPluginManager else {
            return false
        }

        return !dynamicPluginManager.installedPackageVersionsByID().isEmpty
    }

    var hasPendingDynamicPluginExtractionMigration: Bool {
        pluginCatalogManager?.hasPendingExtractionMigrationResume ?? false
    }

    @discardableResult
    func automaticUpdateInstalledPluginsBeforeLoading() async -> Bool {
        guard let pluginCatalogManager else {
            loadDynamicPluginsIfNeeded()
            return true
        }

        automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
            phase: .checking,
            pluginIDs: [],
            message: nil
        )

        await pluginCatalogManager.refreshCatalog()
        syncPluginManagementState()

        if let errorMessage = pluginCatalogManager.status.errorMessage {
            automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
                phase: .failed,
                pluginIDs: [],
                message: errorMessage
            )
            loadDynamicPluginsIfNeeded()
            return false
        }

        let updatePlan = pluginCatalogManager.automaticUpdatePlanForInstalledPlugins()
        guard !updatePlan.isEmpty else {
            automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
                phase: .completed,
                pluginIDs: [],
                message: AppL10n.plugins("plugin.autoUpdate.message.noInstalledUpdates", defaultValue: "已安装插件都是最新版本。")
            )
            loadDynamicPluginsIfNeeded()
            return true
        }

        presentPluginMarketplace()
        automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
            phase: .updating,
            pluginIDs: updatePlan.affectedPluginIDs,
            message: AppL10n.pluginsFormat(
                "plugin.autoUpdate.message.progressFormat",
                defaultValue: "已完成 %d/%d",
                0,
                updatePlan.affectedPluginIDs.count
            )
        )
        syncPluginManagementState()

        do {
            try await pluginCatalogManager.updateInstalledPluginsToLatestBeforeLoading { [weak self] progress in
                self?.automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
                    phase: .updating,
                    pluginIDs: updatePlan.affectedPluginIDs,
                    message: AppL10n.pluginsFormat(
                        "plugin.autoUpdate.message.progressFormat",
                        defaultValue: "已完成 %d/%d",
                        progress.completedCount,
                        progress.totalCount
                    )
                )
            }
            syncPluginManagementState()
            automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
                phase: .completed,
                pluginIDs: updatePlan.affectedPluginIDs,
                message: AppL10n.pluginsFormat(
                    "plugin.autoUpdate.message.updatedInstalledFormat",
                    defaultValue: "已更新 %d 个插件。",
                    updatePlan.affectedPluginIDs.count
                )
            )
        } catch {
            syncPluginManagementState()
            automaticPluginUpdateStatus = PluginAutomaticUpdateStatus(
                phase: .failed,
                pluginIDs: updatePlan.affectedPluginIDs,
                message: error.localizedDescription
            )
        }

        loadDynamicPluginsIfNeeded()
        return automaticPluginUpdateStatus.phase == .completed
    }

    func installPluginFromCatalog(pluginID: String) async throws {
        guard let pluginCatalogManager else {
            return
        }

        try await pluginCatalogManager.installPlugin(id: pluginID)
        syncPluginManagementState()
    }

    func updatePluginFromCatalog(pluginID: String) async throws {
        guard let pluginCatalogManager else {
            return
        }

        try await pluginCatalogManager.updatePlugin(id: pluginID)
        syncPluginManagementState()
    }

    func updateAvailablePluginsFromCatalog(
        progress: ((PluginCatalogUpdateProgress) -> Void)? = nil
    ) async throws {
        guard let pluginCatalogManager else {
            return
        }

        defer {
            syncPluginManagementState()
        }

        try await pluginCatalogManager.updateAvailablePlugins(progress: progress)
    }

    func installPluginPackage(from sourceURL: URL) throws {
        try dynamicPluginManager?.installPluginPackage(from: sourceURL)
        pluginCatalogManager?.rebuildManagementItems()
        syncPluginManagementState()
    }

    func updatePluginPackage(from sourceURL: URL) throws {
        try dynamicPluginManager?.updatePluginPackage(from: sourceURL)
        pluginCatalogManager?.rebuildManagementItems()
        syncPluginManagementState()
    }

    func uninstallDynamicPlugin(pluginID: String, removeData: Bool = false) throws {
        try dynamicPluginManager?.uninstallPlugin(pluginID: pluginID, removeData: removeData)
        pluginOrderingStore.removePlugin(pluginID)
        menuBarPanelStore.removePlugin(id: pluginID)
        shortcutStore.removeCustomizations(forPluginID: pluginID)
        shortcutErrors = shortcutErrors.filter { !$0.key.hasPrefix("\(pluginID).shortcut.") }
        isolatedPluginFailures.removeValue(forKey: pluginID)
        pluginCatalogManager?.rebuildManagementItems()
        syncPluginManagementState()
    }

    private var plugins: [any MacToolsPlugin] {
        builtInPlugins + dynamicPlugins
    }

    private var activePlugins: [any MacToolsPlugin] {
        plugins.filter { isolatedPluginFailures[$0.metadata.id] == nil }
    }

    private var portablePluginPreferenceIDs: Set<String> {
        Set(activePlugins.compactMap { plugin in
            plugin is any PluginPortablePreferencesProviding ? plugin.metadata.id : nil
        })
    }

    private var allPortablePreferencesSelection: PreferencesBackupSelection {
        .all(pluginPreferenceIDs: portablePluginPreferenceIDs)
    }

    private func leafActionReferenceBackupPortability(
        _ reference: ActionReference,
        selection: PreferencesBackupSelection
    ) -> ActionReferencePortability {
        let schemaPortability = actionRegistry.portability(of: reference)
        guard schemaPortability == .portable else { return schemaPortability }
        guard let plugin = activePlugins.first(where: {
            $0.metadata.id == reference.key.providerID
        }), let provider = plugin as? any PluginActionReferenceBackupProviding else {
            return .portable
        }

        switch guardedValue(
            for: plugin,
            operation: "classify action backup",
            provider.backupDisposition(for: reference)
        ) ?? .excluded {
        case .selfContained:
            return .portable
        case .requiresPluginPreferences:
            return selection.pluginPreferenceIDs.contains(plugin.metadata.id)
                ? .portable
                : .knownNonPortable
        case .excluded:
            return .knownNonPortable
        }
    }

    private func actionReferenceBackupPortability(
        _ reference: ActionReference,
        workflows: [WorkflowDefinition],
        portableWorkflowIDs: Set<UUID>,
        selection: PreferencesBackupSelection
    ) -> ActionReferencePortability {
        guard let workflowID = WorkflowExecutionAnalysis.nestedWorkflowID(
            for: reference.key
        ) else {
            return leafActionReferenceBackupPortability(reference, selection: selection)
        }
        guard workflows.contains(where: { $0.id == workflowID }) else { return .unknown }
        guard selection.includesAutomation else { return .knownNonPortable }
        return portableWorkflowIDs.contains(workflowID) ? .portable : .knownNonPortable
    }

    private func currentActionReferenceBackupPortability(
        _ reference: ActionReference
    ) -> ActionReferencePortability {
        let selection = preferencesBackupExportSelection ?? allPortablePreferencesSelection
        let workflows = automationController.workflows
        let portableWorkflowIDs = WorkflowPortabilityAnalysis.portableWorkflowIDs(
            in: workflows,
            referencePortability: { [weak self] reference in
                self?.leafActionReferenceBackupPortability(
                    reference,
                    selection: selection
                ) ?? .unknown
            }
        )
        return actionReferenceBackupPortability(
            reference,
            workflows: workflows,
            portableWorkflowIDs: portableWorkflowIDs,
            selection: selection
        )
    }

    private func actionReferenceRestorePortability(
        _ reference: ActionReference
    ) -> ActionReferencePortability {
        actionReferenceRestorePortability(
            reference,
            context: preferencesBackupRestoreContext
        )
    }

    private func actionReferenceRestorePortability(
        _ reference: ActionReference,
        context: PreferencesActionRestoreContext?
    ) -> ActionReferencePortability {
        if let workflowID = WorkflowExecutionAnalysis.nestedWorkflowID(for: reference.key),
           let context {
            guard context.importedWorkflowIDs.contains(workflowID),
                  context.selection.includesAutomation else {
                return .knownNonPortable
            }
            return context.restorableWorkflowIDs.contains(workflowID)
                ? .portable
                : .knownNonPortable
        }

        return leafActionReferenceRestorePortability(reference, context: context)
    }

    private func leafActionReferenceRestorePortability(
        _ reference: ActionReference,
        context: PreferencesActionRestoreContext?
    ) -> ActionReferencePortability {
        let migratedReference: ActionReference
        switch actionRegistry.migrate(reference) {
        case let .success(migrated):
            migratedReference = migrated
        case .failure(.unknownAction):
            guard let plugin = activePlugins.first(where: {
                $0.metadata.id == reference.key.providerID
            }), let provider = plugin as? any PluginActionReferenceBackupProviding else {
                return .unknown
            }
            let disposition = guardedValue(
                for: plugin,
                operation: "classify unknown restored action",
                provider.backupDisposition(for: reference)
            ) ?? .excluded
            if portablePreferencesDefine(reference, context: context) {
                return .portable
            }
            return switch disposition {
            case .selfContained:
                .unknown
            case .requiresPluginPreferences:
                context == nil ? .unknown : .knownNonPortable
            case .excluded:
                .knownNonPortable
            }
        case .failure:
            return .knownNonPortable
        }
        let schemaPortability = actionRegistry.portability(of: migratedReference)
        guard schemaPortability == .portable else { return schemaPortability }
        guard let plugin = activePlugins.first(where: {
            $0.metadata.id == migratedReference.key.providerID
        }), let provider = plugin as? any PluginActionReferenceBackupProviding else {
            return .portable
        }
        return switch guardedValue(
            for: plugin,
            operation: "classify restored action",
            provider.backupDisposition(for: migratedReference)
        ) ?? .excluded {
        case .selfContained:
            .portable
        case .requiresPluginPreferences:
            context == nil || portablePreferencesDefine(migratedReference, context: context)
                ? .portable
                : .knownNonPortable
        case .excluded:
            portablePreferencesDefine(migratedReference, context: context)
                ? .portable
                : .knownNonPortable
        }
    }

    private func portablePreferencesDefine(
        _ reference: ActionReference,
        context: PreferencesActionRestoreContext?
    ) -> Bool {
        guard let context else { return false }
        let references = context.payloadDefinedActionReferencesByPluginID[
            reference.key.providerID
        ] ?? []
        if references.contains(reference) { return true }
        guard case let .success(migrated) = actionRegistry.migrate(reference) else {
            return false
        }
        return references.contains(migrated)
    }

    private func actionReferenceCanResolve(
        _ reference: ActionReference,
        context: PreferencesActionRestoreContext
    ) -> Bool {
        if let workflowID = WorkflowExecutionAnalysis.nestedWorkflowID(for: reference.key) {
            return context.resolvableWorkflowIDs.contains(workflowID)
        }
        return leafActionReferenceCanResolve(reference, context: context)
    }

    private func leafActionReferenceCanResolve(
        _ reference: ActionReference,
        context: PreferencesActionRestoreContext
    ) -> Bool {
        switch actionRegistry.migrate(reference) {
        case let .success(migrated):
            guard leafActionReferenceRestorePortability(reference, context: context)
                != .knownNonPortable else {
                return false
            }
            if portablePreferencesDefine(reference, context: context)
                || portablePreferencesDefine(migrated, context: context) {
                return true
            }
            guard case let .success(action) = actionRegistry.registeredAction(for: migrated) else {
                return false
            }
            return action.catalogEntry != nil
        case .failure(.unknownAction):
            guard activePlugins.contains(where: {
                $0.metadata.id == reference.key.providerID
                    && $0 is any PluginActionReferenceBackupProviding
            }) else {
                return false
            }
            return portablePreferencesDefine(reference, context: context)
        case .failure:
            return false
        }
    }

    private func makePreferencesActionRestoreContext(
        backup: PreferencesBackup,
        selection: PreferencesBackupSelection,
        restoredPluginPreferenceIDs: Set<String>? = nil
    ) -> PreferencesActionRestoreContext {
        var payloadDefinedActionReferencesByPluginID = decodedPortablePreferenceActionReferences(
            in: backup,
            selection: selection
        )
        if let restoredPluginPreferenceIDs {
            payloadDefinedActionReferencesByPluginID = payloadDefinedActionReferencesByPluginID.filter {
                restoredPluginPreferenceIDs.contains($0.key)
            }
        }
        let importedWorkflows = selection.includesAutomation ? (backup.workflows ?? []) : []
        let importedWorkflowIDs = Set(importedWorkflows.map(\.id))
        let baseContext = PreferencesActionRestoreContext(
            selection: selection,
            payloadDefinedActionReferencesByPluginID: payloadDefinedActionReferencesByPluginID,
            importedWorkflowIDs: importedWorkflowIDs,
            restorableWorkflowIDs: [],
            resolvableWorkflowIDs: []
        )
        let restorableWorkflowIDs = WorkflowPortabilityAnalysis.portableWorkflowIDs(
            in: importedWorkflows,
            referencePortability: { [weak self] reference in
                guard let self else { return .knownNonPortable }
                return self.leafActionReferenceRestorePortability(
                    reference,
                    context: baseContext
                ) == .knownNonPortable ? .knownNonPortable : .portable
            }
        )
        let resolvableWorkflowIDs = WorkflowPortabilityAnalysis.portableWorkflowIDs(
            in: importedWorkflows,
            referencePortability: { [weak self] reference in
                guard let self else { return .knownNonPortable }
                return self.leafActionReferenceCanResolve(reference, context: baseContext)
                    ? .portable
                    : .knownNonPortable
            }
        )
        return PreferencesActionRestoreContext(
            selection: selection,
            payloadDefinedActionReferencesByPluginID: payloadDefinedActionReferencesByPluginID,
            importedWorkflowIDs: importedWorkflowIDs,
            restorableWorkflowIDs: restorableWorkflowIDs,
            resolvableWorkflowIDs: resolvableWorkflowIDs
        )
    }

    private func migratedActionReferenceForRestore(
        _ reference: ActionReference
    ) -> ActionReference {
        guard case let .success(migrated) = actionRegistry.migrate(reference) else {
            return reference
        }
        return migrated
    }

    private func migratedWorkflowForRestore(
        _ workflow: WorkflowDefinition
    ) -> WorkflowDefinition {
        var migrated = workflow
        migrated.steps = workflow.steps.map { step in
            var migratedStep = step
            migratedStep.reference = migratedActionReferenceForRestore(step.reference)
            return migratedStep
        }
        return migrated
    }

    private func portablePluginPreferences() -> [String: Data] {
        activePlugins.reduce(into: [String: Data]()) { result, plugin in
            guard let portablePreferences = plugin as? any PluginPortablePreferencesProviding,
                  let data = guardedOptionalValue(
                    for: plugin,
                    operation: "export portable preferences",
                    portablePreferences.makePortablePreferencesBackup()
                  )
            else {
                return
            }
            result[plugin.metadata.id] = data
        }
    }

    private func portablePreferenceActionReferences(
        in preferences: [String: Data]
    ) -> [String: [ActionReference]] {
        activePlugins.reduce(into: [String: [ActionReference]]()) { result, plugin in
            guard let data = preferences[plugin.metadata.id],
                  let provider = plugin
                    as? any PluginPortablePreferencesActionReferencesProviding,
                  let references = guardedOptionalValue(
                    for: plugin,
                    operation: "index portable preference actions",
                    provider.actionReferences(inPortablePreferences: data)
                  ) else {
                return
            }
            result[plugin.metadata.id] = uniqueActionReferences(references)
        }
    }

    private func portablePreferenceActionReferences(
        in backup: PreferencesBackup,
        selection: PreferencesBackupSelection
    ) -> [ActionReference] {
        var references: [ActionReference] = []
        for pluginID in selection.pluginPreferenceIDs.sorted() {
            guard let data = backup.pluginPreferences[pluginID] else { continue }
            guard let plugin = corePlugin(for: pluginID),
                  let provider = plugin
                    as? any PluginPortablePreferencesActionReferencesProviding,
                  let decoded = guardedOptionalValue(
                    for: plugin,
                    operation: "validate portable preference action index",
                    provider.actionReferences(inPortablePreferences: data)
                  ) else {
                continue
            }
            // The serialized index is only a compatibility/cache field. Derive preview
            // dependencies from the selected payload itself so a crafted backup cannot
            // make the installer trust unrelated provider IDs.
            references.append(contentsOf: decoded)
        }
        return uniqueActionReferences(references)
    }

    private func decodedPortablePreferenceActionReferences(
        in backup: PreferencesBackup,
        selection: PreferencesBackupSelection
    ) -> [String: Set<ActionReference>] {
        selection.pluginPreferenceIDs.reduce(into: [:]) { result, pluginID in
            guard let data = backup.pluginPreferences[pluginID],
                  let plugin = corePlugin(for: pluginID),
                  let provider = plugin
                    as? any PluginPortablePreferencesActionReferencesProviding,
                  let decoded = guardedOptionalValue(
                    for: plugin,
                    operation: "validate portable preference actions",
                    provider.actionReferences(inPortablePreferences: data)
                  ) else {
                return
            }
            result[pluginID] = Set(decoded.filter { $0.key.providerID == pluginID })
        }
    }

    private func uniqueActionReferences(
        _ references: [ActionReference]
    ) -> [ActionReference] {
        var seen = Set<ActionReference>()
        return references.filter { seen.insert($0).inserted }
    }

    @discardableResult
    private func restorePortablePluginPreferences(
        _ pluginPreferences: [String: Data]
    ) -> Set<String> {
        var restoredPluginIDs = Set<String>()
        for (pluginID, data) in pluginPreferences.sorted(by: { $0.key < $1.key }) {
            guard let plugin = corePlugin(for: pluginID),
                  let portablePreferences = plugin as? any PluginPortablePreferencesProviding
            else {
                continue
            }

            let restored: Bool
            if let reporting = plugin as? any PluginPortablePreferencesRestorationReporting {
                restored = guardedValue(
                    for: plugin,
                    operation: "restore portable preferences",
                    reporting.restorePortablePreferencesReportingResult(from: data)
                ) ?? false
            } else {
                let callCompleted = guardPluginCall(
                    plugin,
                    operation: "restore portable preferences"
                ) {
                    portablePreferences.restorePortablePreferences(from: data)
                }
                // Legacy payloads that do not define action identities remain compatible.
                // Action-bearing payloads must opt into verifiable restoration before they can
                // authorize dependent Grid, Trackpad, shortcut, workflow, or Run Link records.
                restored = callCompleted
                    && !(plugin is any PluginPortablePreferencesActionReferencesProviding)
            }
            if restored { restoredPluginIDs.insert(pluginID) }
        }
        return restoredPluginIDs
    }

    private func corePlugin(for pluginID: String) -> (any MacToolsPlugin)? {
        activePlugins.first(where: { $0.metadata.id == pluginID })
    }

    private func configureCallbacks(for plugins: [any MacToolsPlugin]) {
        for plugin in plugins {
            let pluginID = plugin.metadata.id

            if let inputRequester = plugin as? any PluginActionInputPresentationRequesting {
                inputRequester.requestActionInput = { [weak self, weak plugin] key in
                    guard let self, let plugin, key.providerID == pluginID,
                          self.corePlugin(for: pluginID) === plugin,
                          let item = self.actionInputRegistry.items.first(where: { $0.id == key }) else { return }
                    self.appPresentationHandler?(.composeActionInput(item))
                }
            }

            plugin.onStateChange = { [weak self] in
                self?.rebuildDerivedStateAfterPluginChange(pluginID: pluginID)
            }
            plugin.requestPermissionGuidance = { [weak self] permissionID in
                self?.requestPermissionGuidance(forPluginID: pluginID, permissionID: permissionID)
            }
            plugin.shortcutBindingResolver = { [weak self] shortcutDefinitionID in
                self?.legacyResolvedBinding(
                    forPluginID: pluginID,
                    shortcutDefinitionID: shortcutDefinitionID
                )
            }
            if let requester = plugin as? any PluginShortcutResetRequesting {
                requester.resetShortcutCustomizations = { [weak self, weak plugin] definitionIDs in
                    guard let self, let plugin, self.corePlugin(for: pluginID) === plugin else { return }
                    self.resetShortcuts(pluginID: pluginID, definitionIDs: definitionIDs)
                }
            }
            if let inlineShortcutConsumer = plugin as?
                any PluginInlineShortcutSettingsContextConsuming {
                inlineShortcutConsumer.inlineShortcutSettingsContextProvider = { [weak self] in
                    self?.makePluginSettingsContext(pluginID: pluginID)
                        ?? PluginSettingsContext(pluginID: pluginID)
                }
            }
            if let focusTargetConsumer = plugin as? any PluginFocusedWindowTargetConsuming {
                focusTargetConsumer.focusedWindowTargetProvider = { [weak self] in
                    self?.focusedApplicationTargetProvider.target()
                }
            }
            if let presetApplying = plugin as? any PluginActionShortcutPresetApplying {
                presetApplying.previewActionShortcutPreset = { [weak self] actionIDs, bindings in
                    guard let self else {
                        return PluginActionShortcutPresetPreview(
                            items: [],
                            errorMessage: FeatureL10n.string("无法预览快捷键预设。")
                        )
                    }
                    return self.shortcutAssignmentService.replacementPreview(
                        providerID: pluginID,
                        managedActionIDs: actionIDs,
                        bindingsByActionID: bindings
                    )
                }
                presetApplying.applyActionShortcutPreset = { [weak self] actionIDs, bindings in
                    guard let self else {
                        return FeatureL10n.string("无法应用快捷键预设。")
                    }
                    let previousBindings = self.actionBackedShortcutBindings()
                    switch self.shortcutAssignmentService.replaceAssignments(
                        providerID: pluginID,
                        managedActionIDs: actionIDs,
                        bindingsByActionID: bindings
                    ) {
                    case .success:
                        self.rebuildDerivedState(synchronizingShortcuts: true)
                        self.notifyChangedActionBackedShortcutBindings(
                            previous: previousBindings
                        )
                        return nil
                    case let .failure(error):
                        return error.localizedDescription
                    }
                }
            }
            if let transactionApplying = plugin as?
                any PluginActionShortcutReplacementTransactionApplying {
                transactionApplying.currentActionShortcutBindings = {
                    [weak self] actionIDs in
                    self?.shortcutAssignmentService.currentBindings(
                        providerID: pluginID,
                        managedActionIDs: actionIDs
                    ) ?? [:]
                }
                transactionApplying.performActionShortcutReplacementTransaction = {
                    [weak self] actionIDs, bindings, mutation in
                    guard let self else {
                        return FeatureL10n.string("无法应用快捷键预设。")
                    }
                    let previousBindings = self.actionBackedShortcutBindings()
                    let error = self.shortcutAssignmentService.performReplacementTransaction(
                        providerID: pluginID,
                        managedActionIDs: actionIDs,
                        bindingsByActionID: bindings,
                        mutation: mutation
                    )
                    self.rebuildDerivedState(synchronizingShortcuts: true)
                    self.notifyChangedActionBackedShortcutBindings(
                        previous: previousBindings
                    )
                    return error
                }
            }
            if let persistentPreferencesSignaling = plugin as? any PluginPersistentPreferencesChangeSignaling {
                persistentPreferencesSignaling.onPersistentPreferencesChange = { [weak self] in
                    self?.preferencesBackupChangeReporter.didPersist(.plugin(pluginID))
                }
            }
            if let anchorable = plugin as? any DropZoneAnchorProviding {
                anchorable.anchorRectProvider = { [weak self] in
                    self?.statusItemButtonFrameProvider?()
                }
            }
            if let settingsPresenting = plugin as? any PluginSettingsPresenting {
                settingsPresenting.requestSettingsPresentation = { [weak self] in
                    self?.presentPluginSettings(pluginID: pluginID)
                }
            }
            if let dashboardPresenting = plugin as? any PluginDashboardPresenting {
                dashboardPresenting.requestDashboardPresentation = { [weak self] in
                    self?.appPresentationHandler?(.showDashboard)
                }
            }
            if let actionGridConsumer = plugin as? any ActionGridHostContextConsuming {
                actionGridConsumer.actionGridHostContext = makeActionGridHostContext()
            }
            if let trackpadActionConsumer = plugin as? any TrackpadActionHostContextConsuming {
                trackpadActionConsumer.trackpadActionHostContext = makeTrackpadActionHostContext()
            }
            if let actionExecutionConsumer = plugin as? any PluginActionExecutionHostContextConsuming {
                actionExecutionConsumer.actionExecutionHostContext = makePluginActionExecutionHostContext()
            }
            if let activityStateHandling = plugin as? any PluginApplicationActivityStateHandling {
                guardPluginCall(plugin, operation: "set application activity state") {
                    activityStateHandling.applicationActivityStateDidChange(applicationActivityState)
                }
            }
            if let safetyChangeProvider = plugin as? any PluginActionSafetyStateChangeProviding {
                safetyChangeProvider.onActionSafetyStateChange = { [weak self] in
                    self?.rebuildDerivedStateAfterActionSafetyChange(pluginID: pluginID)
                }
            }
            configureHostStatusItemCallbacks(for: [plugin])
        }
        configureTrackpadGestureBridge()
        let pendingIconPluginIDs: Set<String>? = dynamicPluginManager != nil && !didLoadDynamicPlugins
            ? nil
            : Set(pluginManagementItems.filter { $0.state == .restartRequired }.map(\.id))
        menuBarIconCoordinator.synchronize(with: activePlugins, pendingPluginIDs: pendingIconPluginIDs)
    }

    private let trackpadGestureBridge = TrackpadGestureBridge()

    private func configureTrackpadGestureBridge() {
        trackpadGestureBridge.connect(plugins: activePlugins) { [weak self] in
            self?.configureTrackpadGestureBridge()
        }
    }

    private func handleApplicationActivityStateChange(
        _ state: PluginApplicationActivityState
    ) {
        let previousState = applicationActivityState
        guard previousState != state else { return }
        applicationActivityState = state

        if previousState == .waking {
            switch state {
            case .interactive, .sessionInactive, .displayAsleep:
                scheduleDisplayTopologyRefresh()
            case .systemSleeping, .waking:
                break
            }
        }

        for plugin in activePlugins {
            guard let activityStateHandling = plugin as? any PluginApplicationActivityStateHandling else {
                continue
            }
            guardPluginCall(plugin, operation: "update application activity state") {
                activityStateHandling.applicationActivityStateDidChange(state)
            }
        }
    }

    private func configureHostStatusItemCallbacks(for plugins: [any MacToolsPlugin]) {
        for plugin in plugins {
            guard let recoverable = plugin as? any MenuBarHostStatusItemRecovering else { continue }
            recoverable.hostStatusItemFrameProvider = { [weak self] in
                self?.statusItemButtonFrameProvider?()
            }
            recoverable.resetHostStatusItemPosition = { [weak self] in
                self?.resetStatusItemPosition?()
            }
        }
    }

    private func replaceDynamicPlugins(_ plugins: [any MacToolsPlugin]) {
        hideAllPanelItems()
        for plugin in dynamicPlugins { panelCoordinator.removePlugin(plugin.metadata.id) }
        discardComponentViews()
        settingsViewCache.removeAll()
        dynamicResolvedCapabilitiesByID.removeAll()
        syncPluginManagementState()
        dynamicPlugins = plugins.sorted {
            if $0.metadata.order == $1.metadata.order {
                return $0.metadata.title.localizedCompare($1.metadata.title) == .orderedAscending
            }

            return $0.metadata.order < $1.metadata.order
        }
        configureCallbacks(for: dynamicPlugins)
        rebuildDerivedState(synchronizingShortcuts: true)
    }

    private func syncPluginManagementState(installedMetadata: InstalledPluginMetadata? = nil) {
        let metadata = installedMetadata ?? dynamicPluginManager?.installedMetadata()
        dynamicPluginCapabilitiesByID = metadata?.capabilitiesByID ?? [:]
        dynamicPluginCategoriesByID = metadata?.categoriesByID ?? [:]
        dynamicPluginReleaseChannelsByID = metadata?.releaseChannelsByID ?? [:]
        dynamicPluginManifestsByID = metadata?.manifestsByID ?? [:]
        dynamicPluginInstalledAtByID = metadata?.installedAtByID ?? [:]
        pluginManagementItems = dynamicPluginManager?.pluginManagementItems ?? []
        pluginCatalogStatus = pluginCatalogManager?.status ?? .unavailable
    }

    private func refreshPermissionState(targets: [PermissionCenterAffectedFeature]) {
        var refreshedPluginIDs: Set<String> = []
        for target in targets where refreshedPluginIDs.insert(target.pluginID).inserted {
            guard let plugin = corePlugin(for: target.pluginID) else { continue }
            handlePluginAction(rebuildAfterAction: false) {
                if target.status == .granted,
                   target.permissionID == "system-audio-recording" {
                    guardPluginCall(plugin, operation: "recheck granted permission state") {
                        plugin.handlePermissionAction(id: target.permissionID)
                    }
                } else {
                    guardPluginCall(plugin, operation: "refresh permission state") {
                        plugin.refresh()
                    }
                }
            }
        }

        rebuildDerivedState()
    }

    @discardableResult
    private func rebuildPermissionProjections(descriptors: [PluginDescriptor]) -> Set<String> {
        var permissionCenterRequirements: [PermissionCenterRequirement] = []
        var missingPermissionCardIDs = Set<String>()
        permissionCards = descriptors.flatMap { descriptor -> [PluginPermissionCard] in
            let plugin = descriptor.plugin
            let requirements = guardedValue(
                for: plugin,
                operation: "read permission requirements",
                plugin.permissionRequirements
            ) ?? []

            return requirements.compactMap { requirement -> PluginPermissionCard? in
                guard let state = guardedValue(
                    for: plugin,
                    operation: "read permission state",
                    plugin.permissionState(for: requirement.id)
                ) else {
                    return nil
                }

                let hostKind = HostPermissionKind.resolve(
                    permissionID: requirement.id,
                    pluginKind: requirement.kind
                )
                let cardID = "\(plugin.metadata.id).permission.\(requirement.id)"
                if !state.isGranted {
                    missingPermissionCardIDs.insert(cardID)
                }
                permissionCenterRequirements.append(
                    PermissionCenterRequirement(
                        pluginID: plugin.metadata.id,
                        pluginTitle: descriptor.metadata.title,
                        permissionID: requirement.id,
                        kind: hostKind,
                        description: requirement.description,
                        isGranted: state.isGranted,
                        footnote: state.footnote,
                        statusText: state.statusText,
                        statusSystemImage: state.statusSystemImage,
                        statusTone: state.statusTone
                    )
                )

                return PluginPermissionCard(
                    id: cardID,
                    pluginID: plugin.metadata.id,
                    permissionID: requirement.id,
                    title: requirement.title,
                    description: requirement.description,
                    iconSystemImage: permissionIconName(for: hostKind),
                    statusText: state.statusText ?? (state.isGranted
                        ? AppL10n.plugins("plugin.permission.granted", defaultValue: "已授权")
                        : AppL10n.plugins("plugin.permission.notGranted", defaultValue: "未授权")),
                    statusSystemImage: state.statusSystemImage ?? (state.isGranted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"),
                    statusTone: state.statusTone ?? (state.isGranted ? .positive : .caution),
                    footnote: state.footnote,
                    buttonTitle: permissionActionTitle(
                        for: hostKind,
                        isGranted: state.isGranted
                    )
                )
            }
        }
        permissionCoordinator.replaceRequirements(permissionCenterRequirements)
        return missingPermissionCardIDs
    }

    private func rebuildDerivedState(
        dirtyPluginIDs: Set<String>? = nil,
        synchronizingShortcuts: Bool = false
    ) {
        shortcutDefinitionRevision &+= 1
        if dirtyPluginIDs == nil {
            cancelScheduledPluginStateRebuild()
        }

        synchronizeInputGestureClaims()

        let descriptors = pluginDescriptorSnapshot()
        let isolatedPluginCountAtStart = isolatedPluginFailures.count
        let orderedDescriptors = descriptors.ordered
        for descriptor in orderedDescriptors {
            let id = descriptor.metadata.id
            guard dirtyPluginIDs == nil || dirtyPluginIDs!.contains(id) ||
                    !panelCoordinator.hasSnapshot(for: id) else { continue }
            guard let items = guardedValue(for: descriptor.plugin, operation: "read panel items",
                                           descriptor.plugin.panelItems) else { continue }
            do {
                try panelCoordinator.update(pluginID: id, metadata: descriptor.metadata,
                    definitions: items, allowedKinds: descriptor.capabilities.panelKinds,
                    sourceDefaultDescription: descriptor.plugin.metadata.defaultDescription)
            } catch {
                // Keep the last validated snapshot and its identity contract until
                // the plugin publishes valid definitions or is actually unloaded.
                AppLog.pluginHost.error("Invalid panel items for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        synchronizePanelLayout(pluginOrder: orderedDescriptors.map(\.metadata.id))
        let missingPermissionCardIDs = rebuildPermissionProjections(descriptors: orderedDescriptors)

        synchronizeActionRegistry(descriptors: orderedDescriptors)

        let shortcutSnapshot = makeShortcutResolutionSnapshot(from: orderedDescriptors)
        let shortcutDescriptors = shortcutSnapshot.descriptors
        let globalShortcutConflicts = globalShortcutRegistrationSelection(
            for: shortcutDescriptors
        ).conflictOwners
        var shortcutMutationMetadataByRowID: [String: ShortcutMutationMetadata] = [:]
        shortcutItems = shortcutDescriptors.flatMap { descriptor -> [ShortcutSettingsItem] in
            // Ordinary global shortcuts backed by canonical Actions are managed only in
            // Actions & Shortcuts. Active-only, required, and key-phase shortcuts remain
            // plugin-specific settings because their behavior cannot be represented by a
            // one-shot Action invocation.
            if actionReference(for: descriptor) != nil {
                return []
            }
            let customization = shortcutStore.customization(for: descriptor.itemID)
            let binding = legacyResolvedBinding(for: descriptor)
            shortcutMutationMetadataByRowID[descriptor.itemID] = ShortcutMutationMetadata(
                shortcutID: descriptor.itemID,
                assignmentID: nil
            )
            return [
                ShortcutSettingsItem(
                    id: descriptor.itemID,
                    pluginID: descriptor.pluginID,
                    pluginTitle: descriptor.pluginTitle,
                    title: descriptor.definition.title,
                    description: descriptor.definition.description,
                    bindingText: ShortcutFormatter.displayString(for: binding),
                    isRequired: descriptor.definition.isRequired,
                    canClear: !descriptor.definition.isRequired && binding != nil,
                    usesDefaultValue: customization == .inheritDefault,
                    errorMessage: shortcutErrors[descriptor.itemID]
                        ?? eventShortcutConflictError(for: descriptor, descriptors: shortcutDescriptors)
                        ?? globalShortcutConflicts[descriptor.itemID].map {
                            ShortcutValidationError.duplicate(ownerDescription: $0).localizedDescription
                        }
                        ?? binding.flatMap {
                            MacToolsReservedShortcutBindings.validationError(for: $0)?
                                .localizedDescription
                        },
                    settingsGroupID: descriptor.definition.settingsGroupID,
                    settingsGroupTitle: descriptor.definition.settingsGroupTitle,
                    settingsGroupDescription: descriptor.definition.settingsGroupDescription,
                    settingsControlTitle: descriptor.definition.settingsControlTitle,
                    settingsControlSystemImage: descriptor.definition.settingsControlSystemImage
                )
            ]
        }
        self.shortcutMutationMetadataByRowID = shortcutMutationMetadataByRowID

        appShortcutItems = AppShortcutAction.allCases.flatMap { action -> [AppShortcutSettingsItem] in
            let reference = actionReference(for: action)
            let records = shortcutAssignmentService.assignments.filter {
                $0.reference == reference
            }
            let assignments: [ActionShortcutAssignmentRecord?] = records.isEmpty
                ? [nil]
                : records.map(Optional.some)
            return assignments.enumerated().map { index, assignment in
                let binding = assignment?.binding
                let rowID = index == 0
                    ? action.rawValue
                    : "\(action.rawValue).assignment.\(assignment?.id.uuidString.lowercased() ?? String(index))"
                return AppShortcutSettingsItem(
                    id: rowID,
                    action: action,
                    assignmentID: assignment?.id,
                    title: action.title,
                    description: action.description,
                    systemImage: action.systemImage,
                    bindingText: ShortcutFormatter.displayString(for: binding),
                    canClear: binding != nil,
                    errorMessage: appShortcutErrors[action]
                        ?? binding.flatMap {
                            MacToolsReservedShortcutBindings.validationError(for: $0)?
                                .localizedDescription
                        }
                        ?? binding.flatMap {
                            appShortcutConflictError(
                                for: action,
                                binding: $0,
                                descriptors: shortcutDescriptors
                            )
                        }
                )
            }
        }

        pluginSettingsSearchItems = orderedDescriptors.flatMap { descriptor -> [PluginProvidedSettingsSearchItem] in
            let plugin = descriptor.plugin
            guard let provider = plugin as? any PluginSettingsSearchProviding else {
                return []
            }

            let entries = guardedValue(
                for: plugin,
                operation: "read settings search entries",
                provider.settingsSearchEntries
            ) ?? []
            return entries.map {
                PluginProvidedSettingsSearchItem(pluginID: plugin.metadata.id, entry: $0)
            }
        }

        pluginCommandItems = orderedDescriptors.flatMap { descriptor -> [PluginCommandItem] in
            let plugin = descriptor.plugin
            guard let provider = plugin as? any PluginCommandProviding else {
                return []
            }

            let definitions = guardedValue(
                for: plugin,
                operation: "read command definitions",
                provider.commandDefinitions
            ) ?? []
            return definitions.map {
                PluginCommandItem(
                    pluginID: plugin.metadata.id,
                    pluginTitle: descriptor.metadata.title,
                    definition: $0
                )
            }
        }

        pluginSettingsItems = buildPluginSettingsItems(
            descriptors: orderedDescriptors,
            permissionCards: permissionCards,
            missingPermissionCardIDs: missingPermissionCardIDs,
            shortcutItems: shortcutItems
        )
        if let dirtyPluginIDs {
            for pluginID in dirtyPluginIDs {
                settingsViewCache = settingsViewCache.filter { $0.key.pluginID != pluginID }
            }
        } else {
            settingsViewCache.removeAll()
        }
        trimSettingsViewCache(keeping: Set(pluginSettingsItems.map(\.id)))

        let newHasActivePlugin = panelCoordinator.catalog.contains {
            switch $0.definition.content {
            case .row(let row): row.state.isOn
            case .widget(let widget): widget.state.isActive
            }
        }
        if hasActivePlugin != newHasActivePlugin {
            hasActivePlugin = newHasActivePlugin
        }

        // Publish the presentation once, after registry consumers and shortcut
        // registrations have settled. Consumers above read the live registry.
        if synchronizingShortcuts {
            syncGlobalShortcuts()
        } else {
            updateActionShortcutCatalog(descriptors: orderedDescriptors, shortcuts: shortcutSnapshot)
        }

        if isolatedPluginFailures.count > isolatedPluginCountAtStart {
            rebuildDerivedState(synchronizingShortcuts: synchronizingShortcuts)
        } else {
            menuBarPanelContentDidChange.send()
        }
    }

    private func synchronizeInputGestureClaims() {
        let claims = activePlugins.flatMap { plugin -> [PluginInputGestureConflict] in
            guard let provider = plugin as? any PluginInputGestureClaimProviding else {
                return []
            }
            let provided = guardedValue(
                for: plugin,
                operation: "read input gesture claims",
                provider.activeInputGestureClaims
            ) ?? []
            return provided.map {
                PluginInputGestureConflict(
                    claim: $0,
                    ownerPluginID: plugin.metadata.id,
                    ownerPluginTitle: plugin.metadata.title
                )
            }
        }

        for plugin in activePlugins {
            guard let consumer = plugin as? any PluginInputGestureConflictConsuming else {
                continue
            }
            let externalClaims = claims.filter { $0.ownerPluginID != plugin.metadata.id }
            guardPluginCall(plugin, operation: "update input gesture conflicts") {
                consumer.inputGestureConflictsDidChange(externalClaims)
            }
        }
    }

    private func handlePluginAction(rebuildAfterAction: Bool = true, _ action: () -> Void) {
        guard !isHandlingPluginAction else {
            action()
            return
        }

        isHandlingPluginAction = true

        action()

        isHandlingPluginAction = false
        if rebuildAfterAction {
            rebuildDerivedState()
        }
    }

    private func rebuildDerivedStateAfterPluginChange(pluginID: String) {
        shortcutDefinitionRevision &+= 1
        guard !isHandlingPluginAction else {
            return
        }

        dirtyPluginIDs.insert(pluginID)
        schedulePluginStateChangeRebuild()
    }

    private func rebuildDerivedStateAfterActionSafetyChange(pluginID: String) {
        dirtyPluginIDs.remove(pluginID)
        if dirtyPluginIDs.isEmpty {
            pluginStateChangeRebuildTask?.cancel()
            pluginStateChangeRebuildTask = nil
        }

        actionRegistry.invalidateAvailability()
        rebuildDerivedState(dirtyPluginIDs: [pluginID])
    }

    private func schedulePluginStateChangeRebuild() {
        guard pluginStateChangeRebuildTask == nil else {
            return
        }

        pluginStateChangeRebuildTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(for: pluginStateChangeRebuildDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            let pluginIDs = dirtyPluginIDs
            dirtyPluginIDs.removeAll()
            pluginStateChangeRebuildTask = nil
            guard !pluginIDs.isEmpty else {
                return
            }

            actionRegistry.invalidateAvailability()
            rebuildDerivedState(dirtyPluginIDs: pluginIDs, synchronizingShortcuts: true)
        }
    }

    #if DEBUG
    func waitForScheduledPluginStateRebuildForTests() async {
        await pluginStateChangeRebuildTask?.value
    }
    #endif

    private func cancelScheduledPluginStateRebuild() {
        pluginStateChangeRebuildTask?.cancel()
        pluginStateChangeRebuildTask = nil
        dirtyPluginIDs.removeAll()
    }

    private func synchronizeActionRegistry(descriptors: [PluginDescriptor]) {
        var registrations = [hostActionRegistration()]

        for descriptor in descriptors where !isPluginIsolated(descriptor.plugin) {
            let plugin = descriptor.plugin
            if let provider = plugin as? any PluginActionProviding {
                let definitions = guardedValue(
                    for: plugin,
                    operation: "read action definitions",
                    provider.actionDefinitions
                ) ?? []
                let catalogEntries = guardedValue(
                    for: plugin,
                    operation: "read action catalog entries",
                    provider.actionCatalogEntries
                ) ?? []
                registrations.append(
                    actionRegistration(
                        for: plugin,
                        definitions: definitions,
                        catalogEntries: catalogEntries
                    )
                )
            } else if let commandProvider = plugin as? any PluginCommandProviding {
                let definitions = guardedValue(
                    for: plugin,
                    operation: "read legacy command definitions for actions",
                    commandProvider.commandDefinitions
                ) ?? []
                registrations.append(
                    legacyCommandActionRegistration(
                        for: plugin,
                        providerTitle: descriptor.metadata.title,
                        definitions: definitions
                    )
                )
            }
        }

        let definitionByKey = Dictionary(
            registrations.flatMap(\.definitions).map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        registrations.insert(
            automationController.actionRegistration(
                definitionLookup: { definitionByKey[$0] }
            ),
            at: 1
        )

        let issues = actionRegistry.synchronize(registrations)
        actionInputRegistry.synchronize(activePlugins, readDescriptors: { plugin in
            guard let provider = plugin as? any PluginActionInputProviding else { return [] }
            return self.guardedValue(for: plugin, operation: "read action input descriptors",
                                     provider.actionInputDescriptors) ?? []
        }, definitionLookup: { self.actionRegistry.definition(for: $0) })
        if actionRegistryIssues != issues {
            actionRegistryIssues = issues
        }
        if issues.isEmpty {
            AppLog.pluginHost.info(
                "Action registry synchronized providers=\(registrations.count, privacy: .public) catalog=\(self.actionRegistry.catalogEntries.count, privacy: .public) issues=0"
            )
        } else {
            let summary = actionRegistryIssueSummary(issues)
            AppLog.pluginHost.error(
                "Action registry rejected \(issues.count, privacy: .public) item(s): \(summary, privacy: .public)"
            )
        }
        automationController.migrateReferencesIfNeeded()
        migrateLegacyAppActionShortcutsIfNeeded()
        migrateLegacyPluginActionShortcutsIfNeeded(plugins: descriptors.map(\.plugin))
        removeRetiredPluginActionShortcutsIfNeeded(plugins: descriptors.map(\.plugin))
        if actionCatalogEntries != actionRegistry.catalogEntries {
            actionCatalogEntries = actionRegistry.catalogEntries
        }
        for plugin in activePlugins {
            (plugin as? any ActionGridHostContextConsuming)?.actionSurfaceCatalogDidChange()
            (plugin as? any TrackpadActionHostContextConsuming)?.trackpadActionCatalogDidChange()
            (plugin as? any PluginActionExecutionHostContextConsuming)?.actionExecutionCatalogDidChange()
        }
    }

    private func actionRegistryIssueSummary(_ issues: [ActionRegistryIssue]) -> String {
        var counts: [String: Int] = [:]
        for issue in issues {
            let category = switch issue {
            case .invalidProviderID: "invalid-provider-id"
            case .duplicateProviderID: "duplicate-provider-id"
            case .invalidDefinition: "invalid-definition"
            case .duplicateDefinition: "duplicate-definition"
            case .invalidCatalogEntry: "invalid-catalog-entry"
            case .duplicateCatalogEntry: "duplicate-catalog-entry"
            }
            counts[category, default: 0] += 1
        }
        return counts.keys.sorted().map { key in
            "\(key)=\(counts[key, default: 0])"
        }.joined(separator: ",")
    }

    private func makeTrackpadActionHostContext() -> TrackpadActionHostContext {
        TrackpadActionHostContext(
            catalog: { [weak self] in self?.actionSurfaceCatalogItems() ?? [] },
            item: { [weak self] reference in self?.actionSurfaceItem(for: reference) },
            migrate: { [weak self] reference in
                guard let self,
                      case let .success(migrated) = self.actionRegistry.migrate(reference) else {
                    return nil
                }
                return migrated
            },
            canExport: { [weak self] reference in
                self?.currentActionReferenceBackupPortability(reference) == .portable
            },
            canRestore: { [weak self] reference in
                self?.actionReferenceRestorePortability(reference) != .knownNonPortable
            },
            execute: { [weak self] reference in
                self?.executeHeadlessAction(
                    reference: reference,
                    source: .trackpadGesture
                )
            }
        )
    }

    private func makeActionGridHostContext() -> ActionGridHostContext {
        ActionGridHostContext(
            catalog: { [weak self] in self?.actionSurfaceCatalogItems() ?? [] },
            item: { [weak self] reference in self?.actionSurfaceItem(for: reference) },
            migrate: { [weak self] reference in
                guard let self,
                      case let .success(migrated) = self.actionRegistry.migrate(reference) else {
                    return nil
                }
                return migrated
            },
            openOwner: { [weak self] reference in
                self?.presentActionOwner(for: reference) ?? false
            },
            canExport: { [weak self] reference in
                self?.currentActionReferenceBackupPortability(reference) == .portable
            },
            canRestore: { [weak self] reference in
                self?.actionReferenceRestorePortability(reference) != .knownNonPortable
            },
            canPresent: { [weak self] in self?.actionGridPresentationHandler != nil },
            present: { [weak self] entries, source in
                guard let self,
                      (1 ... 9).contains(entries.count),
                      Set(entries.map(\.id)).count == entries.count,
                      Self.validateActionGridPresentationEntries(entries) else {
                    return false
                }
                return self.actionGridPresentationHandler?(entries, source) ?? false
            }
        )
    }

    private func makePluginActionExecutionHostContext() -> PluginActionExecutionHostContext {
        PluginActionExecutionHostContext(
            item: { [weak self] reference in
                self?.actionSurfaceItem(for: reference, livePresentation: true)
            },
            execute: { [weak self] reference, source in
                guard let self else {
                    return .unavailable(reason: FeatureL10n.string("操作不可用。"))
                }
                let outcome = await self.actionExecutor.execute(
                    ActionInvocation(
                        reference: reference,
                        source: source,
                        mode: .foreground
                    )
                )
                switch outcome {
                case let .completed(.succeeded(message)):
                    return .succeeded(message: message)
                case let .completed(.failed(message)):
                    return .failed(message: message)
                case .completed(.cancelled):
                    return .cancelled
                case let .rejected(.unavailable(reason)):
                    return .unavailable(
                        reason: reason ?? FeatureL10n.string("操作不可用。")
                    )
                case let .rejected(.providerFailure(message)):
                    return .failed(message: message)
                case .rejected(.confirmationDenied),
                     .rejected(.confirmationTimedOut):
                    return .cancelled
                case .rejected:
                    return .failed(message: FeatureL10n.string("无法执行操作。"))
                }
            },
            openProviderSettings: { [weak self] providerID in
                guard let self, PluginPackageManifestLoader.isValidPluginID(providerID) else { return }
                let reference = ActionReference(key: ActionKey(providerID: providerID, actionID: "set-enabled"))
                if !self.presentActionOwner(for: reference) {
                    self.presentPluginMarketplace()
                }
            }
        )
    }

    private static func validateActionGridPresentationEntries(
        _ entries: [ActionGridPresentationEntry],
        depth: Int = 0
    ) -> Bool {
        let resolvedSlots = entries.enumerated().map { offset, entry in
            entry.slotIndex ?? offset
        }
        guard depth <= ActionGridPresentationLimits.maximumFolderDepth,
              entries.count <= ActionGridPresentationLimits.maximumEntriesPerGrid,
              Set(entries.map(\.id)).count == entries.count,
              resolvedSlots.allSatisfy({
                  (0 ..< ActionGridPresentationLimits.maximumEntriesPerGrid).contains($0)
              }),
              Set(resolvedSlots).count == resolvedSlots.count else {
            return false
        }
        return entries.allSatisfy { entry in
            if let children = entry.children {
                return entry.customTitle?.isEmpty == false
                    && validateActionGridPresentationEntries(children, depth: depth + 1)
            }
            return entry.reference.key != ActionKey(providerID: "action-grid", actionID: "show")
        }
    }

    private func actionSurfaceCatalogItems() -> [ActionSurfaceCatalogItem] {
        actionRegistry.catalogEntries.compactMap { entry in
            actionSurfaceItem(for: entry.reference)
        }
    }

    private func actionSurfaceItem(
        for reference: ActionReference,
        livePresentation: Bool = false
    ) -> ActionSurfaceCatalogItem? {
        guard case let .success(action) = actionRegistry.registeredAction(for: reference) else {
            return nil
        }
        let ownerTitle = actionSurfaceOwnerTitle(providerID: reference.key.providerID)
        var entry = action.catalogEntry
        if livePresentation {
            guard let plugin = activePlugins.first(where: { $0.metadata.id == reference.key.providerID }),
                  let provider = plugin as? any PluginActionProviding else { return nil }
            // Composed settings verify immediately after execution, before the UI rebuild debounce.
            // Read the provider's current snapshot instead of the registry's presentation cache.
            entry = guardedValue(
                for: plugin, operation: "read live action presentation", provider.actionCatalogEntries
            )?.first { $0.reference == reference }
        }
        return ActionSurfaceCatalogItem(
            reference: reference,
            title: entry?.title ?? action.definition.title,
            subtitle: entry?.subtitle,
            ownerTitle: ownerTitle,
            systemImage: action.definition.systemImage,
            availability: actionRegistry.availability(for: reference),
            isSafe: action.definition.risk == .safe,
            canOpenOwner: canPresentActionOwner(for: reference),
            presentationState: entry?.presentationState
        )
    }

    @discardableResult
    func presentActionOwner(for reference: ActionReference) -> Bool {
        guard let appPresentationHandler else { return false }
        switch reference.key.providerID {
        case "mactools":
            guard let action = AppShortcutAction(rawValue: reference.key.actionID) else {
                return false
            }
            appPresentationHandler(.settings(action.settingsPresentationRequest))
        case AutomationController.providerID:
            if reference.key.actionID.hasPrefix("workflow."),
               let workflowID = UUID(
                uuidString: String(reference.key.actionID.dropFirst("workflow.".count))
               ),
               automationController.workflows.contains(where: { $0.id == workflowID }) {
                appPresentationHandler(.settings(.automationWorkflow(workflowID)))
            } else {
                appPresentationHandler(.settings(.feature(.automation)))
            }
        case let pluginID:
            rebuildDerivedState()
            guard pluginSettingsItems.contains(where: { $0.id == pluginID }) else {
                return false
            }
            appPresentationHandler(.settings(.pluginConfiguration(pluginID)))
        }
        return true
    }

    func canPresentActionOwner(for reference: ActionReference) -> Bool {
        guard appPresentationHandler != nil else { return false }
        switch reference.key.providerID {
        case "mactools":
            return AppShortcutAction(rawValue: reference.key.actionID) != nil
        case AutomationController.providerID:
            return true
        case let pluginID:
            return pluginSettingsItems.contains(where: { $0.id == pluginID })
        }
    }

    func actionSurfaceAssignmentSummaries(
        for reference: ActionReference
    ) -> [ActionSurfaceAssignmentSummary] {
        activePlugins.compactMap { plugin in
            guard let provider = plugin as? any ActionSurfaceAssignmentSummarizing else {
                return nil
            }
            return guardedOptionalValue(
                for: plugin,
                operation: "read action surface assignment",
                provider.actionSurfaceAssignmentSummary(for: reference)
            )
        }
    }

    func actionSurfaceOwnerTitle(providerID: String) -> String {
        switch providerID {
        case "mactools":
            return "MacTools"
        case AutomationController.providerID:
            return FeatureL10n.string("自动化")
        default:
            guard let metadata = activePlugins.first(where: {
                $0.metadata.id == providerID
            })?.metadata else {
                return providerID
            }
            return localizedMetadata(for: metadata).title
        }
    }

    private func migrateLegacyAppActionShortcutsIfNeeded() {
        guard !actionShortcutStore.hasMigratedLegacyAppAssignments else { return }
        let candidates = AppShortcutAction.allCases.compactMap { action
            -> (reference: ActionReference, binding: ShortcutBinding)? in
            guard let binding = shortcutStore.resolvedBinding(
                for: action.rawValue,
                default: nil
            ) else {
                return nil
            }
            return (actionReference(for: action), binding)
        }
        actionShortcutStore.migrateLegacyAppAssignments(candidates) { [shortcutStore] in
            for action in AppShortcutAction.allCases {
                shortcutStore.setCustomization(.inheritDefault, for: action.rawValue)
            }
        }
    }

    private func migrateLegacyPluginActionShortcutsIfNeeded(plugins: [any MacToolsPlugin]) {
        for plugin in plugins {
            guard !actionShortcutStore.hasMigratedLegacyPluginAssignments(pluginID: plugin.metadata.id),
                  let provider = plugin as? any PluginLegacyActionShortcutProviding else {
                continue
            }
            guard let assignments = guardedValue(
                for: plugin,
                operation: "read legacy action shortcuts",
                provider.legacyActionShortcutAssignments
            ) else { continue }
            actionShortcutStore.migrateLegacyPluginAssignments(
                pluginID: plugin.metadata.id,
                assignments: assignments
            ) { [weak self, weak plugin] in
                guard let self, let plugin,
                      let provider = plugin as? any PluginLegacyActionShortcutProviding else {
                    return
                }
                for assignment in assignments {
                    guard let shortcutDefinitionID = assignment.legacyShortcutDefinitionID else {
                        continue
                    }
                    self.shortcutStore.setCustomization(
                        .cleared,
                        for: self.shortcutItemID(
                            pluginID: plugin.metadata.id,
                            shortcutDefinitionID: shortcutDefinitionID
                        )
                    )
                }
                self.guardPluginCall(plugin, operation: "finish legacy action shortcut migration") {
                    provider.legacyActionShortcutsDidMigrate()
                }
            }
        }
    }

    private func removeRetiredPluginActionShortcutsIfNeeded(plugins: [any MacToolsPlugin]) {
        for plugin in plugins {
            guard let provider = plugin as? any PluginRetiredActionShortcutProviding else {
                continue
            }
            let actionIDs = guardedValue(
                for: plugin,
                operation: "read retired action shortcuts",
                provider.retiredActionShortcutIDs
            ) ?? []
            guard !actionIDs.isEmpty else { continue }
            if case let .failure(error) = shortcutAssignmentService.removeRetiredAssignments(
                providerID: plugin.metadata.id,
                actionIDs: actionIDs
            ) {
                AppLog.pluginHost.error(
                    "Failed to remove retired shortcuts for plugin \(plugin.metadata.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func hostActionRegistration() -> ActionProviderRegistration {
        let providerID = "mactools"
        let definitions = AppShortcutAction.allCases.filter { !$0.isPanelAction }.map { action in
            ActionDefinition(
                key: ActionKey(providerID: providerID, actionID: action.rawValue),
                title: action.title,
                description: action.description,
                systemImage: action.systemImage,
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            )
        }
        let panelDefinitions = menuBarPanels.map { panel in
            ActionDefinition(
                key: panelActionReference(id: panel.id).key,
                title: panel.title,
                description: FeatureL10n.string("显示、隐藏或切换到此面板。"),
                systemImage: panel.systemImage,
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            )
        }
        let allDefinitions = definitions + panelDefinitions
        return ActionProviderRegistration(
            providerID: providerID,
            identity: ObjectIdentifier(self),
            definitions: allDefinitions,
            catalogEntries: allDefinitions.map {
                ActionCatalogEntry(
                    reference: ActionReference(key: $0.key),
                    title: $0.title,
                    subtitle: "MacTools"
                )
            },
            availability: { _ in .available },
            begin: { [weak self] invocation in
                if let self,
                   let panel = self.menuBarPanels.first(where: {
                       !$0.isDefault && self.panelActionReference(id: $0.id).key == invocation.reference.key
                   }), let handler = self.menuBarPanelPresentationHandler {
                    handler(panel.id, true)
                    return .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
                guard let self,
                      let action = AppShortcutAction(rawValue: invocation.reference.key.actionID),
                      let appPresentationHandler = self.appPresentationHandler else {
                    return .failure(.providerFailure(FeatureL10n.string("MacTools 尚未准备完成。")))
                }
                appPresentationHandler(action.presentationRequest)
                return .success(ActionExecutionHandle(operation: { .succeeded() }))
            }
        )
    }

    private func actionRegistration(
        for plugin: any MacToolsPlugin,
        definitions: [ActionDefinition],
        catalogEntries: [ActionCatalogEntry]
    ) -> ActionProviderRegistration {
        let providerID = plugin.metadata.id
        return ActionProviderRegistration(
            providerID: providerID,
            identity: ObjectIdentifier(plugin),
            definitions: definitions,
            catalogEntries: catalogEntries,
            executionRevision: { [weak self, weak plugin] in
                guard let self, let plugin else { return .max }
                guard let provider = plugin as? any PluginActionExecutionRevisionProviding else {
                    return 0
                }
                return self.guardedValue(
                    for: plugin,
                    operation: "read action execution revision",
                    provider.actionExecutionRevision
                ) ?? .max
            },
            availability: { [weak self, weak plugin] reference in
                guard let self,
                      let plugin,
                      let provider = plugin as? any PluginActionProviding else {
                    return .unavailable(FeatureL10n.string("插件不可用。"))
                }
                return self.guardedValue(
                    for: plugin,
                    operation: "read action availability",
                    provider.actionAvailability(for: reference)
                ) ?? .unavailable(FeatureL10n.string("插件不可用。"))
            },
            exposurePolicy: { [weak self, weak plugin] reference, surface in
                guard let self, let plugin else {
                    return .excluded
                }
                guard let provider = plugin as? any PluginActionExposureProviding else {
                    return .automatic
                }
                return self.guardedValue(
                    for: plugin,
                    operation: "read action exposure policy",
                    provider.exposurePolicy(for: reference, on: surface)
                ) ?? .excluded
            },
            migrate: { [weak self, weak plugin] reference, schemaVersion in
                guard let self,
                      let plugin,
                      let provider = plugin as? any PluginActionProviding else {
                    return nil
                }
                return self.guardedOptionalValue(
                    for: plugin,
                    operation: "migrate action reference",
                    provider.migrateActionReference(
                        reference,
                        toSchemaVersion: schemaVersion
                    )
                )
            },
            begin: { [weak self, weak plugin] invocation in
                guard let self,
                      let plugin,
                      let provider = plugin as? any PluginActionProviding,
                      !self.isPluginIsolated(plugin) else {
                    return .failure(.providerFailure(FeatureL10n.string("插件不可用。")))
                }

                let result = PluginInvocationGuard.value(operation: "begin action") {
                    try provider.beginAction(invocation)
                }
                switch result {
                case let .success(handle):
                    return .success(handle)
                case let .failure(failure):
                    self.isolatePlugin(plugin, operation: "begin action", failure: failure)
                    return .failure(.providerFailure(failure.localizedDescription))
                }
            }
        )
    }

    private func legacyCommandActionRegistration(
        for plugin: any MacToolsPlugin,
        providerTitle: String,
        definitions commandDefinitions: [PluginCommandDefinition]
    ) -> ActionProviderRegistration {
        let providerID = plugin.metadata.id
        let definitions = commandDefinitions.map { command in
            ActionDefinition(
                key: ActionKey(providerID: providerID, actionID: command.id),
                title: command.title,
                description: command.description,
                keywords: command.keywords,
                systemImage: command.systemImage,
                risk: command.confirmation == nil ? .safe : .confirmationRequired,
                confirmation: command.confirmation.map {
                    ActionConfirmation(
                        title: $0.title,
                        message: $0.message,
                        confirmButtonTitle: $0.confirmButtonTitle
                    )
                },
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            )
        }

        return ActionProviderRegistration(
            providerID: providerID,
            identity: ObjectIdentifier(plugin),
            definitions: definitions,
            catalogEntries: definitions.map {
                ActionCatalogEntry(
                    reference: ActionReference(key: $0.key),
                    title: $0.title,
                    subtitle: providerTitle
                )
            },
            availability: { _ in .available },
            begin: { [weak self, weak plugin] invocation in
                guard let self,
                      let plugin,
                      let provider = plugin as? any PluginCommandProviding,
                      let expectedDefinition = commandDefinitions.first(where: {
                          $0.id == invocation.reference.key.actionID
                      }),
                      (self.guardedValue(
                          for: plugin,
                          operation: "revalidate legacy command action",
                          provider.commandDefinitions
                      ) ?? []).contains(expectedDefinition) else {
                    return .failure(.providerFailure(FeatureL10n.string("操作不可用。")))
                }

                guard self.guardPluginCall(plugin, operation: "perform legacy command action", {
                    provider.handleCommand(id: expectedDefinition.id)
                }) else {
                    return .failure(.providerFailure(FeatureL10n.string("插件执行失败。")))
                }
                return .success(ActionExecutionHandle(operation: { .succeeded() }))
            }
        )
    }

    private func guardedValue<T>(
        for plugin: any MacToolsPlugin,
        operation: String,
        _ value: @autoclosure () -> T
    ) -> T? {
        guard !isPluginIsolated(plugin) else {
            return nil
        }

        switch PluginInvocationGuard.value(operation: operation, value) {
        case let .success(value):
            return value
        case let .failure(failure):
            isolatePlugin(plugin, operation: operation, failure: failure)
            return nil
        }
    }

    private func guardedOptionalValue<T>(
        for plugin: any MacToolsPlugin,
        operation: String,
        _ value: @autoclosure () -> T?
    ) -> T? {
        guard !isPluginIsolated(plugin) else {
            return nil
        }

        switch PluginInvocationGuard.value(operation: operation, value) {
        case let .success(value):
            return value
        case let .failure(failure):
            isolatePlugin(plugin, operation: operation, failure: failure)
            return nil
        }
    }

    @discardableResult
    private func guardPluginCall(
        _ plugin: any MacToolsPlugin,
        operation: String,
        _ action: () -> Void
    ) -> Bool {
        guard !isPluginIsolated(plugin) else {
            return false
        }

        switch PluginInvocationGuard.run(operation: operation, action) {
        case .success:
            return true
        case let .failure(failure):
            isolatePlugin(plugin, operation: operation, failure: failure)
            return false
        }
    }

    private func guardedSettingsView(
        for plugin: any MacToolsPlugin,
        operation: String,
        _ view: @autoclosure () -> AnyView
    ) -> AnyView {
        guardedValue(
            for: plugin,
            operation: operation,
            view()
        ) ?? AnyView(EmptyView())
    }

    private func makePluginSettingsContext(pluginID: String) -> PluginSettingsContext {
        PluginSettingsContext(
            pluginID: pluginID,
            shortcutItems: shortcutItems.filter { $0.pluginID == pluginID },
            actionShortcutItems: actionShortcutCatalogItems
                .filter { $0.reference.key.providerID == pluginID }
                .map {
                    PluginSettingsActionShortcutItem(
                        actionID: $0.reference.key.actionID,
                        title: $0.title,
                        description: $0.description,
                        bindingText: $0.bindingText,
                        canAssign: $0.canAssign,
                        canClear: $0.assignmentID != nil
                    )
                },
            recordShortcut: { [weak self] itemID, binding in
                self?.clearShortcutError(for: itemID)
                return self?.setShortcutBindingAndReturnError(binding, for: itemID)
            },
            beginShortcutRecording: { [weak self] itemID in
                self?.clearShortcutError(for: itemID)
            },
            clearShortcut: { [weak self] itemID in
                self?.clearShortcutError(for: itemID)
                self?.clearShortcut(for: itemID)
            },
            resetShortcut: { [weak self] itemID in
                self?.clearShortcutError(for: itemID)
                self?.resetShortcut(for: itemID)
            },
            recordActionShortcut: { [weak self] actionID, binding in
                guard let self,
                      let item = self.actionShortcutCatalogItems.first(where: {
                          $0.reference.key.providerID == pluginID
                              && $0.reference.key.actionID == actionID
                      })
                else {
                    return FeatureL10n.string("操作不可用。")
                }
                return self.setActionShortcutBindingAndReturnError(
                    binding,
                    for: item.reference,
                    assignmentID: item.assignmentID
                )
            },
            clearActionShortcut: { [weak self] actionID in
                guard let self,
                      let item = self.actionShortcutCatalogItems.first(where: {
                          $0.reference.key.providerID == pluginID
                              && $0.reference.key.actionID == actionID
                              && $0.assignmentID != nil
                      })
                else {
                    return
                }
                self.clearActionShortcut(
                    for: item.reference,
                    assignmentID: item.assignmentID
                )
            }
        )
    }

    private func isPluginIsolated(_ plugin: any MacToolsPlugin) -> Bool {
        isolatedPluginFailures[plugin.metadata.id] != nil
    }

    private func isolatePlugin(
        _ plugin: any MacToolsPlugin,
        operation: String,
        failure: PluginInvocationFailure
    ) {
        let pluginID = plugin.metadata.id
        let message = failure.localizedDescription

        guard isolatedPluginFailures[pluginID] == nil else {
            return
        }

        shortcutDefinitionRevision &+= 1
        isolatedPluginFailures[pluginID] = message
        menuBarIconCoordinator.unregister(pluginID: pluginID, reason: .disabled)
        panelCoordinator.removePlugin(pluginID)
        settingsViewCache = settingsViewCache.filter { $0.key.pluginID != pluginID }
        shortcutErrors = shortcutErrors.filter { !$0.key.hasPrefix("\(pluginID).shortcut.") }

        AppLog.pluginHost.error(
            "Plugin \(pluginID, privacy: .public) isolated after \(operation, privacy: .public): \(message, privacy: .public)"
        )

        switch PluginInvocationGuard.run(operation: "deactivate isolated plugin \(pluginID)", {
            plugin.deactivate(reason: .disabled)
        }) {
        case .success:
            break
        case let .failure(deactivateFailure):
            AppLog.pluginHost.error(
                "Plugin \(pluginID, privacy: .public) failed during isolation deactivate: \(deactivateFailure.localizedDescription, privacy: .public)"
            )
        }

        plugin.onStateChange = nil
        (plugin as? any PluginActionSafetyStateChangeProviding)?.onActionSafetyStateChange = nil
        plugin.requestPermissionGuidance = nil
        (plugin as? any PluginActionInputPresentationRequesting)?.requestActionInput = nil
        plugin.shortcutBindingResolver = nil
        (plugin as? any PluginShortcutResetRequesting)?.resetShortcutCustomizations = nil
        (plugin as? any PluginFocusedWindowTargetConsuming)?
            .focusedWindowTargetProvider = nil
        if let presetApplying = plugin as? any PluginActionShortcutPresetApplying {
            presetApplying.previewActionShortcutPreset = nil
            presetApplying.applyActionShortcutPreset = nil
        }
        if let transactionApplying = plugin as?
            any PluginActionShortcutReplacementTransactionApplying {
            transactionApplying.currentActionShortcutBindings = nil
            transactionApplying.performActionShortcutReplacementTransaction = nil
        }
        (plugin as? any PluginSettingsPresenting)?.requestSettingsPresentation = nil
        (plugin as? any PluginDashboardPresenting)?.requestDashboardPresentation = nil
        (plugin as? any ActionGridHostContextConsuming)?.actionGridHostContext = nil
        (plugin as? any TrackpadActionHostContextConsuming)?.trackpadActionHostContext = nil
        (plugin as? any PluginActionExecutionHostContextConsuming)?.actionExecutionHostContext = nil
        syncGlobalShortcuts()
    }

    private func scheduleDisplayTopologyRefresh() {
        displayTopologyRefreshTask?.cancel()
        let refreshDelay = displayTopologyRefreshDelay
        displayTopologyRefreshTask = Task { @MainActor [weak self, refreshDelay] in
            do {
                try await Task.sleep(for: refreshDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.refreshDisplayTopologyNow()
        }
    }

    private func refreshDisplayTopologyNow() {
        displayTopologyRefreshTask = nil
        handlePluginAction {
            for plugin in activePlugins {
                if let displayTopologyRefreshing = plugin as? DisplayTopologyRefreshing {
                    guardPluginCall(plugin, operation: "refresh display topology") {
                        displayTopologyRefreshing.refreshDisplayTopology()
                    }
                }
            }
        }
    }

    private func refreshAccessibilityPermissionNow() {
        handlePluginAction {
            for plugin in activePlugins {
                if let accessibilityRefreshing = plugin as? AccessibilityPermissionRefreshing {
                    guardPluginCall(plugin, operation: "refresh accessibility permission") {
                        accessibilityRefreshing.refreshAccessibilityPermission()
                    }
                }
            }
        }
    }

    private func buildPluginSettingsItems(
        descriptors: [PluginDescriptor],
        permissionCards: [PluginPermissionCard],
        missingPermissionCardIDs: Set<String>,
        shortcutItems: [ShortcutSettingsItem]
    ) -> [PluginSettingsPageItem] {
        let permissionCardsByPluginID = Dictionary(grouping: permissionCards, by: \.pluginID)
        let shortcutItemsByPluginID = Dictionary(grouping: shortcutItems, by: \.pluginID)
        return descriptors.filter { !isPluginIsolated($0.plugin) }.compactMap { descriptor in
            let pluginID = descriptor.metadata.id
            let matchingPermissionCards = permissionCardsByPluginID[pluginID] ?? []
            let matchingMissingPermissionCardIDs = missingPermissionCardIDs.intersection(
                matchingPermissionCards.map(\.id)
            )
            let matchingShortcutItems = shortcutItemsByPluginID[pluginID] ?? []
            let shortcutSettingsGroups: [PluginShortcutSettingsGroupConfiguration]
            if descriptor.hasSettings,
               let provider = descriptor.plugin as? any PluginGroupedShortcutSettingsProviding,
               let configurations = guardedValue(
                   for: descriptor.plugin,
                   operation: "read grouped shortcut settings configuration",
                   provider.shortcutSettingsGroups
               ) {
                var seenIDs: Set<String> = []
                shortcutSettingsGroups = configurations.filter { configuration in
                    let id = configuration.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = configuration.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let systemImage = configuration.systemImage.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isValid = !id.isEmpty
                        && !title.isEmpty
                        && !systemImage.isEmpty
                        && (!configuration.actionIDs.isEmpty || !configuration.shortcutDefinitionIDs.isEmpty)
                        && seenIDs.insert(id).inserted
                    if !isValid {
                        AppLog.pluginHost.error(
                            "Plugin \(pluginID, privacy: .public) returned an invalid grouped shortcut settings configuration"
                        )
                    }
                    return isValid
                }
            } else {
                shortcutSettingsGroups = []
            }
            let rawPage: PluginSettingsPage?
            if descriptor.hasSettings {
                rawPage = guardedOptionalValue(
                    for: descriptor.plugin,
                    operation: "read plugin settings page",
                    descriptor.plugin.settingsPage
                )
            } else {
                rawPage = nil
            }
            let page: PluginSettingsPage?
            if let rawPage {
                do {
                    if rawPage.body.layout != descriptor.capabilities.settingsLayout {
                        AppLog.pluginHost.error(
                            "Plugin \(pluginID, privacy: .public) settings layout does not match its manifest"
                        )
                        page = nil
                    } else {
                        try PluginSettingsValidator.validate(
                            rawPage,
                            availableShortcutGroupIDs: Set(
                                matchingShortcutItems.compactMap(\.settingsGroupID)
                            ).union(shortcutSettingsGroups.map(\.id))
                        )
                        page = rawPage
                    }
                } catch {
                    AppLog.pluginHost.error(
                        "Plugin \(pluginID, privacy: .public) returned invalid settings: \(String(describing: error), privacy: .public)"
                    )
                    page = nil
                }
            } else {
                page = nil
            }
            let actionShortcutSettingsConfiguration: PluginActionShortcutSettingsConfiguration?
            if descriptor.hasSettings,
               let provider = descriptor.plugin as? any PluginActionShortcutSettingsProviding,
               let configuration = guardedValue(
                   for: descriptor.plugin,
                   operation: "read action shortcut settings configuration",
                   provider.actionShortcutSettingsConfiguration
               ) {
                let title = configuration.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let systemImage = configuration.systemImage.trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty || systemImage.isEmpty || configuration.actionIDs.isEmpty {
                    AppLog.pluginHost.error(
                        "Plugin \(pluginID, privacy: .public) returned invalid action shortcut settings configuration"
                    )
                    actionShortcutSettingsConfiguration = nil
                } else {
                    actionShortcutSettingsConfiguration = configuration
                }
            } else {
                actionShortcutSettingsConfiguration = nil
            }
            let hasSettingsSurface = !matchingMissingPermissionCardIDs.isEmpty
                || !matchingShortcutItems.isEmpty
                || actionShortcutSettingsConfiguration != nil
                || !shortcutSettingsGroups.isEmpty
                || page != nil

            guard hasSettingsSurface else {
                return nil
            }

            let shortcutGroupPresentation = descriptor.plugin as?
                any PluginShortcutSettingsGroupPresentationProviding
            let description: String
            if let pageDescription = page?.description,
               pageDescription != descriptor.plugin.metadata.defaultDescription {
                description = pageDescription
            } else {
                // A page can inherit metadata captured when the plugin initialized.
                // Use the current manifest locale while preserving custom introductions.
                description = descriptor.metadata.defaultDescription
            }

            return PluginSettingsPageItem(
                id: pluginID,
                pluginID: pluginID,
                title: descriptor.metadata.title,
                description: description,
                iconName: descriptor.metadata.iconName,
                iconTint: descriptor.metadata.iconTint,
                installedAt: dynamicPluginInstalledAtByID[pluginID],
                page: page,
                permissionCards: matchingPermissionCards,
                missingPermissionCardIDs: matchingMissingPermissionCardIDs,
                shortcutItems: matchingShortcutItems,
                actionShortcutSettingsConfiguration: shortcutSettingsGroups.isEmpty
                    ? actionShortcutSettingsConfiguration
                    : nil,
                shortcutSettingsGroups: shortcutSettingsGroups,
                shortcutDefinitionFirstSettingsGroupIDs:
                    shortcutGroupPresentation?.shortcutDefinitionFirstSettingsGroupIDs ?? [],
                collapsibleShortcutSettingsGroupIDs:
                    shortcutGroupPresentation?.collapsibleShortcutSettingsGroupIDs ?? [],
                collapsibleActionSettingsGroupIDs:
                    shortcutGroupPresentation?.collapsibleActionSettingsGroupIDs ?? []
            )
        }
    }


    private func shortcutDescriptors(from descriptors: [PluginDescriptor]? = nil) -> [ShortcutDescriptor] {
        (descriptors ?? orderedPluginDescriptors()).filter { !isPluginIsolated($0.plugin) }.flatMap { descriptor in
            let plugin = descriptor.plugin
            let metadata = descriptor.metadata
            let definitions = guardedValue(
                for: plugin,
                operation: "read shortcut definitions",
                plugin.shortcutDefinitions
            ) ?? []

            return definitions.map { definition in
                ShortcutDescriptor(
                    itemID: shortcutItemID(
                        pluginID: plugin.metadata.id,
                        shortcutDefinitionID: definition.id
                    ),
                    pluginID: metadata.id,
                    pluginTitle: metadata.title,
                    definition: definition,
                    plugin: plugin
                )
            }
        }
    }

    private func makeShortcutResolutionSnapshot(from descriptors: [PluginDescriptor]) -> ShortcutResolutionSnapshot {
        // Capture before invoking getters: an exception or reentrant state
        // change invalidates reuse even if it occurs while reading definitions.
        let revision = shortcutDefinitionRevision
        return ShortcutResolutionSnapshot(revision: revision, descriptors: shortcutDescriptors(from: descriptors))
    }

    private var defaultPluginIDs: [String] {
        defaultPluginDescriptors().map(\.metadata.id)
    }


    private func orderedPluginIDs() -> [String] {
        pluginOrderingStore.orderedPluginIDs(defaultPluginIDs: defaultPluginIDs)
    }

    private func orderedPlugins() -> [any MacToolsPlugin] {
        let pluginsByID = pluginsByID()

        return orderedPluginIDs().compactMap { pluginsByID[$0] }
    }

    private func orderedCorePlugins() -> [any MacToolsPlugin] {
        orderedPluginDescriptors().map(\.plugin)
    }

    private func orderedPluginDescriptors() -> [PluginDescriptor] {
        pluginDescriptorSnapshot().ordered
    }

    private func pluginDescriptorSnapshot() -> PluginDescriptorSnapshot {
        let descriptors = defaultPluginDescriptors()
        return PluginDescriptorSnapshot(
            defaults: descriptors,
            orderedIDs: pluginOrderingStore.orderedPluginIDs(
                defaultPluginIDs: descriptors.map(\.metadata.id)
            )
        )
    }


    private func pluginsByID() -> [String: any MacToolsPlugin] {
        activePlugins.reduce(into: [String: any MacToolsPlugin]()) { result, plugin in
            let id = plugin.metadata.id

            if result[id] == nil {
                result[id] = plugin
            }
        }
    }

    private func defaultPluginDescriptors() -> [PluginDescriptor] {
        let descriptors = builtInPlugins
            .map {
                PluginDescriptor(
                    metadata: $0.metadata,
                    plugin: $0,
                    capabilities: builtInCapabilities(for: $0)
                )
            }
            + dynamicPlugins.map {
                PluginDescriptor(
                    metadata: localizedMetadata(for: $0.metadata),
                    plugin: $0,
                    capabilities: dynamicCapabilities(for: $0)
                )
            }

        return descriptors
            .filter { !isPluginIsolated($0.plugin) }
            .sorted { lhs, rhs in
                if lhs.metadata.order == rhs.metadata.order {
                    return lhs.metadata.title.localizedCompare(rhs.metadata.title) == .orderedAscending
                }

                return lhs.metadata.order < rhs.metadata.order
            }
    }

    private func localizedMetadata(for metadata: PluginMetadata) -> PluginMetadata {
        guard let localized = PluginLocalizationMatcher.localizedMetadata(
            from: dynamicPluginManifestsByID[metadata.id]?.localizedMetadata ?? [:]
        )
        else {
            return metadata
        }

        return PluginMetadata(
            id: metadata.id,
            title: localized.displayName ?? metadata.title,
            iconName: metadata.iconName,
            iconTint: metadata.iconTint,
            order: metadata.order,
            defaultDescription: localized.summary ?? metadata.defaultDescription
        )
    }

    private func builtInCapabilities(for plugin: any MacToolsPlugin) -> PluginHostCapabilities {
        if let cached = builtInCapabilitiesByID[plugin.metadata.id] { return cached }
        let capabilities = PluginHostCapabilities(panelKinds: Set(PluginPanelItemKind.allCases),
                                                  settingsLayout: plugin.settingsPage?.body.layout)
        builtInCapabilitiesByID[plugin.metadata.id] = capabilities
        return capabilities
    }

    private func dynamicCapabilities(for plugin: any MacToolsPlugin) -> PluginHostCapabilities {
        if let cached = dynamicResolvedCapabilitiesByID[plugin.metadata.id] { return cached }
        let declared = dynamicPluginCapabilitiesByID[plugin.metadata.id]
        let capabilities = PluginHostCapabilities(
            panelKinds: Set(declared?.panelItems ?? PluginPanelItemKind.allCases),
            settingsLayout: declared.map { $0.settings.layout } ?? plugin.settingsPage?.body.layout)
        dynamicResolvedCapabilitiesByID[plugin.metadata.id] = capabilities
        return capabilities
    }

    private func hideAllPanelItems() { panelCoordinator.setVisiblePanel(nil) }


    private func trimSettingsViewCache(keeping settingsPluginIDs: Set<String>) {
        settingsViewCache = settingsViewCache.filter {
            settingsPluginIDs.contains($0.key.pluginID)
        }
    }

    private func shortcutDescriptor(for shortcutID: String) -> ShortcutDescriptor? {
        shortcutDescriptors().first(where: { $0.itemID == shortcutID })
    }

    private func shortcutMutationTarget(
        for rowID: String
    ) -> (descriptor: ShortcutDescriptor, assignmentID: UUID?)? {
        let metadata = shortcutMutationMetadataByRowID[rowID]
        let shortcutID = metadata?.shortcutID ?? rowID
        guard let descriptor = shortcutDescriptor(for: shortcutID) else {
            return nil
        }
        return (descriptor, metadata?.assignmentID)
    }

    private func shortcutItemID(pluginID: String, shortcutDefinitionID: String) -> String {
        "\(pluginID).shortcut.\(shortcutDefinitionID)"
    }

    private func resolvedBinding(for descriptor: ShortcutDescriptor) -> ShortcutBinding? {
        if let reference = actionReference(for: descriptor) {
            return shortcutAssignmentService.assignment(for: reference)?.binding
        }
        return legacyResolvedBinding(for: descriptor)
    }

    private func legacyResolvedBinding(for descriptor: ShortcutDescriptor) -> ShortcutBinding? {
        shortcutStore.resolvedBinding(
            for: descriptor.itemID,
            default: descriptor.definition.defaultBinding
        )
    }

    /// Global, optional plugin shortcuts that point at a published parameterless action are
    /// aliases of that action assignment. The old `ShortcutStore` remains readable only for
    /// one-shot migration; all subsequent edits and registrations use the action store.
    private func actionReference(for descriptor: ShortcutDescriptor) -> ActionReference? {
        guard descriptor.definition.scope == .global,
              !descriptor.definition.isRequired,
              !(descriptor.plugin is any PluginShortcutEventHandling) else {
            return nil
        }
        let key = ActionKey(
            providerID: descriptor.pluginID,
            actionID: descriptor.definition.actionID
        )
        guard let definition = actionRegistry.definition(for: key),
              definition.parameters.isEmpty,
              definition.capabilities.contains(.foregroundInteractive) else {
            return nil
        }
        let reference = ActionReference(
            key: key,
            schemaVersion: definition.parameterSchemaVersion
        )
        guard actionRegistry.catalogEntries.contains(where: {
            $0.reference == reference
        }) else {
            return nil
        }
        return reference
    }

    private func resolvedAppShortcutBinding(for action: AppShortcutAction) -> ShortcutBinding? {
        shortcutAssignmentService.assignment(for: actionReference(for: action))?.binding
    }

    private func actionReference(for action: AppShortcutAction) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: "mactools", actionID: action.rawValue)
        )
    }

    private func consumedShortcutBindings(_ binding: ShortcutBinding, for descriptor: ShortcutDescriptor) -> Set<ShortcutBinding> {
        // Window Switcher's existing phase-based shortcut contract also consumes
        // Shift for reverse cycling. Account for that chord in host validation
        // without extending the PluginKit shortcut-definition contract.
        guard descriptor.pluginID == "window-switcher",
              descriptor.plugin is any PluginShortcutEventHandling,
              !binding.modifiers.contains(.shift) else { return [binding] }
        return [binding, ShortcutBinding(keyCode: binding.keyCode, modifiers: binding.modifiers.union(.shift))]
    }

    private func shortcutBindingsConflict(_ binding: ShortcutBinding, for descriptor: ShortcutDescriptor,
                                         with otherBinding: ShortcutBinding, for other: ShortcutDescriptor) -> Bool {
        // Explicit scope bindings win inside Window Switcher. Its implicit
        // reverse chord must not shadow a shortcut owned by another plugin.
        if descriptor.pluginID == other.pluginID { return binding == otherBinding }
        return !consumedShortcutBindings(binding, for: descriptor)
            .isDisjoint(with: consumedShortcutBindings(otherBinding, for: other))
    }

    private func pluginShortcutConflict(
        for binding: ShortcutBinding,
        descriptors: [ShortcutDescriptor]
    ) -> ShortcutDescriptor? {
        descriptors.first { descriptor in
            resolvedBinding(for: descriptor).map { consumedShortcutBindings($0, for: descriptor).contains(binding) } ?? false
        }
    }

    private func appShortcutConflictError(
        for action: AppShortcutAction,
        binding: ShortcutBinding,
        descriptors: [ShortcutDescriptor]
    ) -> String? {
        guard let conflict = pluginShortcutConflict(for: binding, descriptors: descriptors) else {
            return nil
        }

        return ShortcutValidationError.duplicate(
            ownerDescription: "\(conflict.pluginTitle) · \(conflict.definition.title)"
        ).localizedDescription
    }

    private func eventShortcutConflictError(
        for descriptor: ShortcutDescriptor,
        descriptors: [ShortcutDescriptor]
    ) -> String? {
        guard descriptor.plugin is any PluginShortcutEventHandling,
              let binding = legacyResolvedBinding(for: descriptor) else { return nil }
        do {
            try validateShortcutCustomization(.custom(binding), for: descriptor, descriptors: descriptors)
        } catch { return error.localizedDescription }
        return nil
    }

    private func legacyResolvedBinding(
        forPluginID pluginID: String,
        shortcutDefinitionID: String
    ) -> ShortcutBinding? {
        let descriptors: [ShortcutDescriptor]
        if let snapshot = shortcutResolutionSnapshot, snapshot.revision == shortcutDefinitionRevision {
            descriptors = snapshot.descriptors
        } else {
            descriptors = shortcutDescriptors()
        }
        guard let descriptor = descriptors.first(where: {
            $0.pluginID == pluginID && $0.definition.id == shortcutDefinitionID
        }), eventShortcutConflictError(for: descriptor, descriptors: descriptors) == nil else { return nil }
        return legacyResolvedBinding(for: descriptor)
    }

    private func applyImportedShortcutCustomizations(
        _ importedCustomizations: [String: ShortcutCustomization],
        bridgesLegacyActionAssignments: Bool,
        notifiesActionBackedDescriptors: Bool = true
    ) -> [String: String] {
        let descriptors = shortcutDescriptors()
        let appCustomizations = Dictionary(
            uniqueKeysWithValues: AppShortcutAction.allCases.map { action in
                (action, importedCustomizations[action.rawValue] ?? .inheritDefault)
            }
        )
        let targetCustomizations = Dictionary(
            descriptors.map { descriptor in
                (descriptor.itemID, importedCustomizations[descriptor.itemID] ?? .inheritDefault)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let errors = validateImportedShortcutCustomizations(
            targetCustomizations,
            descriptors: descriptors,
            appCustomizations: appCustomizations
        )

        guard errors.isEmpty else {
            return importShortcutErrorMessages(errors, descriptors: descriptors)
        }

        var mutationErrors: [String: String] = [:]
        for descriptor in descriptors {
            guard let customization = targetCustomizations[descriptor.itemID] else {
                continue
            }

            shortcutStore.setCustomization(customization, for: descriptor.itemID)
            shortcutErrors.removeValue(forKey: descriptor.itemID)
            let binding = ShortcutStore.resolve(
                customization: customization,
                defaultBinding: descriptor.definition.defaultBinding
            )
            if bridgesLegacyActionAssignments,
               importedCustomizations[descriptor.itemID] != nil,
               let reference = actionReference(for: descriptor) {
                if let binding {
                    if case let .failure(error) = shortcutAssignmentService.assign(
                        binding,
                        to: reference
                    ) {
                        mutationErrors[descriptor.itemID] = error.localizedDescription
                    }
                } else {
                    if case let .failure(error) = shortcutAssignmentService.clear(reference) {
                        mutationErrors[descriptor.itemID] = error.localizedDescription
                    }
                }
            }
            if notifiesActionBackedDescriptors || actionReference(for: descriptor) == nil {
                notifyShortcutBindingChange(
                    for: descriptor,
                    binding: binding
                )
            }
        }
        for action in AppShortcutAction.allCases where bridgesLegacyActionAssignments {
            guard let customization = importedCustomizations[action.rawValue] else {
                continue
            }
            let binding = ShortcutStore.resolve(
                customization: customization,
                defaultBinding: nil
            )
            if let binding {
                if case let .failure(error) = shortcutAssignmentService.assign(
                    binding,
                    to: actionReference(for: action)
                ) {
                    mutationErrors[action.rawValue] = error.localizedDescription
                }
            } else {
                if case let .failure(error) = shortcutAssignmentService.clear(
                    actionReference(for: action)
                ) {
                    mutationErrors[action.rawValue] = error.localizedDescription
                }
            }
            appShortcutErrors.removeValue(forKey: action)
        }

        return importShortcutErrorMessages(mutationErrors, descriptors: descriptors)
    }

    private func importShortcutErrorMessages(
        _ errors: [String: String],
        descriptors: [ShortcutDescriptor]
    ) -> [String: String] {
        let descriptorsByID = Dictionary(
            descriptors.map { ($0.itemID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return Dictionary(
            errors.map { shortcutID, message in
                let title = AppShortcutAction(rawValue: shortcutID)?.title
                    ?? descriptorsByID[shortcutID].map {
                    "\($0.pluginTitle) · \($0.definition.title)"
                } ?? shortcutID
                return (shortcutID, "\(title): \(message)")
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func validateImportedShortcutCustomizations(
        _ customizations: [String: ShortcutCustomization],
        descriptors: [ShortcutDescriptor],
        appCustomizations: [AppShortcutAction: ShortcutCustomization]
    ) -> [String: String] {
        var bindingsByID: [String: ShortcutBinding?] = [:]
        var appBindings: [AppShortcutAction: ShortcutBinding?] = [:]
        var errors: [String: String] = [:]

        for action in AppShortcutAction.allCases {
            let binding = ShortcutStore.resolve(
                customization: appCustomizations[action] ?? .inheritDefault,
                defaultBinding: nil
            )
            appBindings[action] = binding

            if let binding {
                if !binding.hasRequiredModifiers {
                    errors[action.rawValue] = ShortcutValidationError.missingModifier.localizedDescription
                } else if ShortcutKeyCode.isModifier(binding.keyCode) {
                    errors[action.rawValue] = ShortcutValidationError.modifierOnly.localizedDescription
                } else if let error = MacToolsReservedShortcutBindings.validationError(
                    for: binding
                ) {
                    errors[action.rawValue] = error.localizedDescription
                }
            }
        }

        for descriptor in descriptors {
            let customization = customizations[descriptor.itemID] ?? .inheritDefault
            let binding = ShortcutStore.resolve(
                customization: customization,
                defaultBinding: descriptor.definition.defaultBinding
            )
            bindingsByID[descriptor.itemID] = binding

            do {
                if descriptor.definition.isRequired && binding == nil {
                    throw ShortcutValidationError.requiredShortcut
                }

                if let binding {
                    guard binding.hasRequiredModifiers else {
                        throw ShortcutValidationError.missingModifier
                    }

                    guard !ShortcutKeyCode.isModifier(binding.keyCode) else {
                        throw ShortcutValidationError.modifierOnly
                    }

                    if let error = MacToolsReservedShortcutBindings.validationError(
                        for: binding
                    ) {
                        throw error
                    }
                }
            } catch {
                errors[descriptor.itemID] = error.localizedDescription
            }
        }

        for (index, descriptor) in descriptors.enumerated() {
            guard let binding = bindingsByID[descriptor.itemID] ?? nil else {
                continue
            }

            for otherDescriptor in descriptors.dropFirst(index + 1) {
                guard let otherBinding = bindingsByID[otherDescriptor.itemID] ?? nil,
                      shortcutBindingsConflict(binding, for: descriptor, with: otherBinding, for: otherDescriptor),
                      !canShareShortcutBinding(descriptor, with: otherDescriptor)
                else {
                    continue
                }

                errors[descriptor.itemID] = ShortcutValidationError.duplicate(
                    ownerDescription: "\(otherDescriptor.pluginTitle) · \(otherDescriptor.definition.title)"
                ).localizedDescription
                errors[otherDescriptor.itemID] = ShortcutValidationError.duplicate(
                    ownerDescription: "\(descriptor.pluginTitle) · \(descriptor.definition.title)"
                ).localizedDescription
            }
        }

        for (index, action) in AppShortcutAction.allCases.enumerated() {
            guard let appBinding = appBindings[action] ?? nil else {
                continue
            }

            for otherAction in AppShortcutAction.allCases.dropFirst(index + 1) {
                guard let otherBinding = appBindings[otherAction] ?? nil,
                      otherBinding == appBinding
                else {
                    continue
                }

                errors[action.rawValue] = ShortcutValidationError.duplicate(
                    ownerDescription: otherAction.title
                ).localizedDescription
                errors[otherAction.rawValue] = ShortcutValidationError.duplicate(
                    ownerDescription: action.title
                ).localizedDescription
            }

            for descriptor in descriptors {
                guard let binding = bindingsByID[descriptor.itemID] ?? nil,
                      consumedShortcutBindings(binding, for: descriptor).contains(appBinding)
                else {
                    continue
                }

                errors[action.rawValue] = ShortcutValidationError.duplicate(
                    ownerDescription: "\(descriptor.pluginTitle) · \(descriptor.definition.title)"
                ).localizedDescription
                errors[descriptor.itemID] = ShortcutValidationError.duplicate(
                    ownerDescription: action.title
                ).localizedDescription
            }
        }

        return errors
    }

    @discardableResult
    private func applyShortcutCustomization(
        _ customization: ShortcutCustomization,
        for descriptor: ShortcutDescriptor,
        assignmentID: UUID? = nil,
        descriptors: [ShortcutDescriptor]? = nil,
        updatesPresentation: Bool = true
    ) -> String? {
        if let reference = actionReference(for: descriptor) {
            let binding = ShortcutStore.resolve(
                customization: customization,
                defaultBinding: descriptor.definition.defaultBinding
            )
            let result: ActionShortcutMutationResult
            if let binding {
                result = shortcutAssignmentService.assign(
                    binding,
                    to: reference,
                    assignmentID: assignmentID
                )
            } else {
                result = shortcutAssignmentService.clear(
                    reference,
                    assignmentID: assignmentID
                )
            }

            switch result {
            case .success:
                shortcutStore.setCustomization(.cleared, for: descriptor.itemID)
                notifyShortcutBindingChange(
                    for: descriptor,
                    binding: shortcutAssignmentService.assignment(for: reference)?.binding
                )
                shortcutErrors.removeValue(forKey: descriptor.itemID)
                if updatesPresentation {
                    rebuildDerivedState(synchronizingShortcuts: true)
                }
                return nil
            case let .failure(error):
                shortcutErrors[descriptor.itemID] = error.localizedDescription
                if updatesPresentation { rebuildDerivedState() }
                return error.localizedDescription
            }
        }

        do {
            try validateShortcutCustomization(customization, for: descriptor, descriptors: descriptors)
            shortcutStore.setCustomization(customization, for: descriptor.itemID)
            notifyShortcutBindingChange(
                for: descriptor,
                binding: ShortcutStore.resolve(
                    customization: customization,
                    defaultBinding: descriptor.definition.defaultBinding
                )
            )
            shortcutErrors.removeValue(forKey: descriptor.itemID)
            if updatesPresentation {
                rebuildDerivedState(synchronizingShortcuts: true)
            }
            return nil
        } catch let error as ShortcutValidationError {
            shortcutErrors[descriptor.itemID] = error.localizedDescription
            if updatesPresentation { rebuildDerivedState() }
            return error.localizedDescription
        } catch {
            shortcutErrors[descriptor.itemID] = error.localizedDescription
            if updatesPresentation { rebuildDerivedState() }
            return error.localizedDescription
        }
    }

    private func validateShortcutCustomization(
        _ customization: ShortcutCustomization,
        for descriptor: ShortcutDescriptor,
        descriptors: [ShortcutDescriptor]? = nil
    ) throws {
        let candidate = ShortcutStore.resolve(
            customization: customization,
            defaultBinding: descriptor.definition.defaultBinding
        )

        if descriptor.definition.isRequired && candidate == nil {
            throw ShortcutValidationError.requiredShortcut
        }

        if let candidate {
            guard candidate.hasRequiredModifiers else {
                throw ShortcutValidationError.missingModifier
            }

            guard !ShortcutKeyCode.isModifier(candidate.keyCode) else {
                throw ShortcutValidationError.modifierOnly
            }

            if let error = MacToolsReservedShortcutBindings.validationError(
                for: candidate
            ) {
                throw error
            }

            if let conflict = (descriptors ?? shortcutDescriptors()).first(where: { other in
                other.itemID != descriptor.itemID
                    && resolvedBinding(for: other).map { shortcutBindingsConflict(candidate, for: descriptor, with: $0, for: other) } == true
                    && !canShareShortcutBinding(descriptor, with: other)
            }) {
                throw ShortcutValidationError.duplicate(
                    ownerDescription: "\(conflict.pluginTitle) · \(conflict.definition.title)"
                )
            }

            if let conflict = AppShortcutAction.allCases.first(where: {
                resolvedAppShortcutBinding(for: $0).map { consumedShortcutBindings(candidate, for: descriptor).contains($0) } ?? false
            }) {
                throw ShortcutValidationError.duplicate(
                    ownerDescription: conflict.title
                )
            }

            if let conflict = shortcutAssignmentService.assignments.first(where: {
                consumedShortcutBindings(candidate, for: descriptor).contains($0.binding)
            }) {
                let reference = conflict.reference
                let title = actionRegistry.catalogEntries.first(where: { $0.reference == reference })?.title
                    ?? actionRegistry.definition(for: reference.key)?.title
                    ?? reference.key.actionID
                throw ShortcutValidationError.duplicate(
                    ownerDescription: "\(actionOwnerTitle(providerID: reference.key.providerID)) · \(title)"
                )
            }
        }
    }

    private func validateAppShortcut(
        _ binding: ShortcutBinding,
        for action: AppShortcutAction
    ) throws {
        guard binding.hasRequiredModifiers else {
            throw ShortcutValidationError.missingModifier
        }

        guard !ShortcutKeyCode.isModifier(binding.keyCode) else {
            throw ShortcutValidationError.modifierOnly
        }

        if let error = MacToolsReservedShortcutBindings.validationError(
            for: binding
        ) {
            throw error
        }

        if let conflict = pluginShortcutConflict(
            for: binding,
            descriptors: shortcutDescriptors()
        ) {
            throw ShortcutValidationError.duplicate(
                ownerDescription: "\(conflict.pluginTitle) · \(conflict.definition.title)"
            )
        }

        if let conflict = AppShortcutAction.allCases.first(where: {
            $0 != action && resolvedAppShortcutBinding(for: $0) == binding
        }) {
            throw ShortcutValidationError.duplicate(ownerDescription: conflict.title)
        }
    }

    private func canShareShortcutBinding(_ lhs: ShortcutDescriptor, with rhs: ShortcutDescriptor) -> Bool {
        guard let groupID = lhs.definition.sharedBindingGroupID else {
            return false
        }

        return groupID == rhs.definition.sharedBindingGroupID
    }

    private func notifyShortcutBindingChange(
        for descriptor: ShortcutDescriptor,
        binding: ShortcutBinding?,
        onlyIfChanged: Bool = false
    ) {
        guard let handling = descriptor.plugin as? any PluginShortcutBindingChangeHandling else {
            return
        }

        guard shortcutBindingDeliveries.shouldDeliver(
            to: descriptor.plugin,
            shortcutID: descriptor.itemID,
            binding: binding,
            force: !onlyIfChanged
        ) else { return }
        guardPluginCall(descriptor.plugin, operation: "update shortcut binding") {
            handling.shortcutBindingDidChange(id: descriptor.definition.id, binding: binding)
        }
    }

    private func actionBackedShortcutBindings() -> [String: ShortcutBinding] {
        Dictionary(
            uniqueKeysWithValues: shortcutDescriptors().compactMap { descriptor in
                guard let reference = actionReference(for: descriptor),
                      let binding = shortcutAssignmentService.assignment(
                          for: reference
                      )?.binding else {
                    return nil
                }
                return (descriptor.itemID, binding)
            }
        )
    }

    private func notifyChangedActionBackedShortcutBindings(
        previous: [String: ShortcutBinding]
    ) {
        let current = actionBackedShortcutBindings()
        for descriptor in shortcutDescriptors() {
            guard actionReference(for: descriptor) != nil,
                  previous[descriptor.itemID] != current[descriptor.itemID] else {
                continue
            }
            notifyShortcutBindingChange(
                for: descriptor,
                binding: current[descriptor.itemID]
            )
        }
    }

    private func notifyAllActionBackedShortcutBindings() {
        let current = actionBackedShortcutBindings()
        for descriptor in shortcutDescriptors() where actionReference(for: descriptor) != nil {
            notifyShortcutBindingChange(
                for: descriptor,
                binding: current[descriptor.itemID]
            )
        }
    }

    private func importedReservedShortcutState(
        customizations: [String: ShortcutCustomization],
        descriptors: [ShortcutDescriptor]
    ) -> (
        registrations: [GlobalShortcutManager.Registration],
        ownerDescriptions: [String: String]
    ) {
        let eligibleDescriptors = descriptors.filter {
            $0.definition.scope == .global && actionReference(for: $0) == nil
        }
        let registrations = eligibleDescriptors.compactMap {
            descriptor -> GlobalShortcutManager.Registration? in
            let customization = customizations[descriptor.itemID] ?? .inheritDefault
            guard let binding = ShortcutStore.resolve(
                customization: customization,
                defaultBinding: descriptor.definition.defaultBinding
            ) else {
                return nil
            }
            return GlobalShortcutManager.Registration(
                shortcutID: descriptor.itemID,
                binding: binding
            )
        }
        let ownerDescriptions = Dictionary(
            eligibleDescriptors.map {
                ($0.itemID, "\($0.pluginTitle) · \($0.definition.title)")
            },
            uniquingKeysWith: { first, _ in first }
        )
        return (registrations, ownerDescriptions)
    }

    private func globalShortcutRegistrationSelection(
        for descriptors: [ShortcutDescriptor]
    ) -> (registrations: [GlobalShortcutManager.Registration], conflictOwners: [String: String]) {
        let candidates = descriptors.enumerated().compactMap { index, descriptor
            -> (index: Int, descriptor: ShortcutDescriptor, binding: ShortcutBinding, isCustom: Bool)? in
            guard descriptor.definition.scope == .global,
                  actionReference(for: descriptor) == nil,
                  let binding = resolvedBinding(for: descriptor),
                  MacToolsReservedShortcutBindings.validationError(for: binding) == nil else {
                return nil
            }
            let isCustom: Bool = if case .custom = shortcutStore.customization(for: descriptor.itemID) {
                true
            } else {
                false
            }
            return (index, descriptor, binding, isCustom)
        }.sorted { lhs, rhs in
            lhs.isCustom == rhs.isCustom ? lhs.index < rhs.index : lhs.isCustom
        }

        var claimedBindings: [ShortcutBinding: ShortcutDescriptor] = [:]
        var registrations: [GlobalShortcutManager.Registration] = []
        var conflictOwners: [String: String] = [:]
        for candidate in candidates {
            if let owner = claimedBindings[candidate.binding],
               !canShareShortcutBinding(candidate.descriptor, with: owner) {
                conflictOwners[candidate.descriptor.itemID] =
                    "\(owner.pluginTitle) · \(owner.definition.title)"
                continue
            }
            claimedBindings[candidate.binding] = candidate.descriptor
            registrations.append(GlobalShortcutManager.Registration(
                shortcutID: candidate.descriptor.itemID,
                binding: candidate.binding
            ))
        }
        return (registrations, conflictOwners)
    }

    private func syncGlobalShortcuts() {
        let previousShortcutBindingRevision = shortcutBindingRevision
        let plugins = orderedPluginDescriptors()
        let snapshot = makeShortcutResolutionSnapshot(from: plugins)
        let descriptors = snapshot.descriptors
        let liveIDs = Set(descriptors.map(\.itemID))
        shortcutBindingDeliveries.retain(shortcutIDs: liveIDs)
        let registrations = globalShortcutRegistrationSelection(for: descriptors).registrations

        let ownerDescriptions = Dictionary(
            descriptors.filter { actionReference(for: $0) == nil }.map {
                ($0.itemID, "\($0.pluginTitle) · \($0.definition.title)")
            },
            uniquingKeysWith: { first, _ in first }
        )
        shortcutAssignmentService.synchronize(
            reservedRegistrations: registrations,
            reservedOwnerDescriptions: ownerDescriptions
        )
        // Phase-aware listeners own their event taps. Refresh their host-resolved
        // bindings after dynamic defaults or action assignments change; do not
        // Carbon-register their active-only shortcuts.
        for descriptor in descriptors where descriptor.plugin is any PluginShortcutEventHandling {
            let binding = eventShortcutConflictError(for: descriptor, descriptors: descriptors) == nil
                ? legacyResolvedBinding(for: descriptor) : nil
            notifyShortcutBindingChange(for: descriptor, binding: binding, onlyIfChanged: true)
        }
        if actionShortcutItems != shortcutAssignmentService.settingsItems {
            actionShortcutItems = shortcutAssignmentService.settingsItems
        }
        if shortcutBindingRevision != shortcutAssignmentService.revision {
            shortcutBindingRevision = shortcutAssignmentService.revision
        }
        updateActionShortcutCatalog(descriptors: plugins, shortcuts: snapshot)
        if shortcutBindingRevision != previousShortcutBindingRevision {
            notifyActionShortcutAssignmentChanges()
        }
    }

    private func notifyActionShortcutAssignmentChanges() {
        for plugin in activePlugins {
            guard let handling = plugin as? any PluginActionShortcutAssignmentChangeHandling else {
                continue
            }
            guardPluginCall(plugin, operation: "update action shortcut assignments") {
                handling.actionShortcutAssignmentsDidChange()
            }
        }
    }

    private func updateActionShortcutCatalog(
        descriptors: [PluginDescriptor],
        shortcuts: ShortcutResolutionSnapshot
    ) {
        // Availability providers can resolve required exit shortcuts. Reuse
        // definitions only during this synchronous projection, never bindings.
        let previousSnapshot = shortcutResolutionSnapshot
        shortcutResolutionSnapshot = shortcuts
        defer { shortcutResolutionSnapshot = previousSnapshot }
        let items = buildActionShortcutCatalogItems(descriptors: descriptors)
        if actionShortcutCatalogItems != items {
            actionShortcutCatalogItems = items
        }
    }

    private func buildActionShortcutCatalogItems(descriptors: [PluginDescriptor]) -> [ActionShortcutCatalogItem] {
        // These values are shared by many rows, but may change between host updates.
        // Keep the cache local so localization, permissions and plugin replacement stay live.
        var ownerTitles = Dictionary(descriptors.filter { !isPluginIsolated($0.plugin) }.map {
            ($0.metadata.id, $0.metadata.title)
        }, uniquingKeysWith: { first, _ in first })
        var permissionRequirements: [String: [String: String]] = [:]
        let plugins = Dictionary(activePlugins.map { ($0.metadata.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        func ownerTitle(_ providerID: String) -> String {
            if let title = ownerTitles[providerID] { return title }
            let title = actionOwnerTitle(providerID: providerID)
            ownerTitles[providerID] = title
            return title
        }
        func permissionSummary(_ reference: ActionReference) -> String? {
            let providerID = reference.key.providerID
            guard let plugin = plugins[providerID],
                  let provider = plugin as? any PluginActionPermissionProviding,
                  let ids = guardedValue(for: plugin, operation: "read action permission requirements",
                                         provider.permissionRequirementIDs(for: reference.key)) else { return nil }
            if permissionRequirements[providerID] == nil {
                let requirements = guardedValue(for: plugin, operation: "read permission requirements",
                                                plugin.permissionRequirements) ?? []
                permissionRequirements[providerID] = Dictionary(requirements.map { ($0.id, $0.title) },
                                                               uniquingKeysWith: { first, _ in first })
            }
            let titles = ids.compactMap { permissionRequirements[providerID]?[$0] }
            return titles.isEmpty ? nil : FeatureL10n.format("所需权限：%@", FeatureL10n.joined(titles))
        }
        var items: [ActionShortcutCatalogItem] = actionCatalogEntries.flatMap {
            entry -> [ActionShortcutCatalogItem] in
            guard case let .success(action) = actionRegistry.registeredAction(
                for: entry.reference
            ) else {
                return []
            }

            let availability = actionRegistry.availability(for: entry.reference)
            let assignmentItems = shortcutAssignmentService.settingsItems(
                for: entry.reference
            )
            let rows: [ActionShortcutSettingsItem?] = assignmentItems.isEmpty
                ? [nil]
                : assignmentItems.map(Optional.some)
            let title = ownerTitle(entry.reference.key.providerID)
            let permissions = permissionSummary(entry.reference)
            return rows.map { assignmentItem in
                let status: ActionShortcutCatalogStatus
                if let assignmentItem {
                    status = actionShortcutCatalogStatus(for: assignmentItem.state)
                } else if availability.isAvailable {
                    status = .unassigned
                } else {
                    status = .unavailable(availability.reason)
                }
                return ActionShortcutCatalogItem(
                    reference: entry.reference,
                    assignmentID: assignmentItem?.assignment.id,
                    title: entry.title,
                    ownerTitle: title,
                    description: action.definition.description,
                    permissionSummary: permissions,
                    systemImage: action.definition.systemImage,
                    bindingText: assignmentItem?.bindingText ?? "",
                    status: status,
                    // Availability is live execution state, not configurability. Let users
                    // prepare a shortcut while an interactive action is temporarily unavailable.
                    canAssign: action.definition.capabilities.contains(.foregroundInteractive)
                )
            }
        }

        let catalogReferences = Set(items.map(\.reference))
        items.append(contentsOf: shortcutAssignmentService.settingsItems.compactMap { item in
            guard !catalogReferences.contains(item.assignment.reference) else {
                return nil
            }
            return ActionShortcutCatalogItem(
                reference: item.assignment.reference,
                assignmentID: item.assignment.id,
                title: item.title,
                ownerTitle: ownerTitle(item.assignment.reference.key.providerID),
                description: FeatureL10n.string("操作提供方暂时不可用；快捷键分配已保留。"),
                permissionSummary: nil,
                systemImage: "puzzlepiece.extension",
                bindingText: item.bindingText,
                status: actionShortcutCatalogStatus(for: item.state),
                canAssign: false
            )
        })
        return items
    }

    private func actionShortcutCatalogStatus(
        for state: ActionShortcutRegistrationState
    ) -> ActionShortcutCatalogStatus {
        switch state {
        case .registered:
            .assigned
        case let .unavailable(reason):
            .unavailable(reason)
        case let .conflict(ownerDescription):
            .conflicted(ownerDescription)
        case let .registrationFailed(code):
            .conflicted(FeatureL10n.format("系统注册失败（%d）。", code))
        case .invalidBinding:
            .conflicted(FeatureL10n.string("快捷键无效。"))
        }
    }

    private func actionOwnerTitle(providerID: String) -> String {
        switch providerID {
        case "mactools":
            return "MacTools"
        case AutomationController.providerID:
            return FeatureL10n.string("自动化")
        default:
            guard let metadata = corePlugin(for: providerID)?.metadata else {
                return providerID
            }
            return localizedMetadata(for: metadata).title
        }
    }

    func actionOwnerAppearance(providerID: String) -> ActionOwnerAppearance {
        switch providerID {
        case "mactools":
            return ActionOwnerAppearance(systemImage: "hammer", iconTint: .orange)
        case AutomationController.providerID:
            return ActionOwnerAppearance(
                systemImage: "bolt.horizontal.circle",
                iconTint: .indigo
            )
        default:
            guard let metadata = corePlugin(for: providerID)?.metadata else {
                return ActionOwnerAppearance(
                    systemImage: "puzzlepiece.extension",
                    iconTint: .secondary
                )
            }
            return ActionOwnerAppearance(
                systemImage: metadata.iconName,
                iconTint: metadata.iconTint
            )
        }
    }

    private func handleShortcutTrigger(shortcutID: String) {
        if let reference = shortcutAssignmentService.reference(forShortcutID: shortcutID) {
            let ancestry = Self.actionShortcutAncestry
            guard !ancestry.contains(reference) else { return }
            guard admitActionShortcutTrigger(for: reference) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { finishActionShortcutTrigger(for: reference) }
                await Self.$actionShortcutAncestry.withValue(ancestry.union([reference])) {
                    await executeHeadlessActionNow(
                        reference: reference,
                        source: .globalShortcut
                    )
                }
            }
            return
        }

        if let action = AppShortcutAction(rawValue: shortcutID) {
            appPresentationHandler?(action.presentationRequest)
            return
        }

        guard let descriptor = shortcutDescriptor(for: shortcutID) else {
            return
        }

        handlePluginAction {
            guardPluginCall(descriptor.plugin, operation: "shortcut action") {
                if let eventHandler = descriptor.plugin as? any PluginShortcutEventHandling {
                    eventHandler.handleShortcutEvent(id: descriptor.definition.actionID, phase: .pressed)
                } else {
                    descriptor.plugin.handleShortcutAction(id: descriptor.definition.actionID)
                }
            }
        }
    }

    /// Bounds asynchronously delivered synthetic retriggers without dropping ordinary repeats.
    /// Carbon re-enters through the main queue, outside task-local ancestry, so the burst remains
    /// active briefly after the last invocation completes. A later physical shortcut starts fresh.
    private func admitActionShortcutTrigger(for reference: ActionReference) -> Bool {
        let now = actionShortcutBurstUptime
        var burst = actionShortcutBursts[reference] ?? ActionShortcutBurstState()
        if burst.activeTaskCount == 0,
           let lastCompletionUptime = burst.lastCompletionUptime,
           now - lastCompletionUptime >= Self.actionShortcutBurstResetInterval {
            burst = ActionShortcutBurstState()
        }
        guard burst.admittedCount < Self.maximumActionShortcutBurstCount else {
            actionShortcutBursts[reference] = burst
            return false
        }
        burst.admittedCount += 1
        burst.activeTaskCount += 1
        burst.lastCompletionUptime = nil
        actionShortcutBursts[reference] = burst
        return true
    }

    private func finishActionShortcutTrigger(for reference: ActionReference) {
        guard var burst = actionShortcutBursts[reference] else { return }
        burst.activeTaskCount = max(0, burst.activeTaskCount - 1)
        if burst.activeTaskCount == 0 {
            burst.lastCompletionUptime = actionShortcutBurstUptime
        }
        actionShortcutBursts[reference] = burst
    }

    private var actionShortcutBurstUptime: TimeInterval {
#if DEBUG
        if let actionShortcutBurstUptimeProviderForTests {
            return actionShortcutBurstUptimeProviderForTests()
        }
#endif
        return ProcessInfo.processInfo.systemUptime
    }

    private func handleShortcutRelease(shortcutID: String) {
        guard let descriptor = shortcutDescriptor(for: shortcutID),
              let eventHandler = descriptor.plugin as? any PluginShortcutEventHandling
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(descriptor.plugin, operation: "shortcut release") {
                eventHandler.handleShortcutEvent(id: descriptor.definition.actionID, phase: .released)
            }
        }
    }

    private func executeHeadlessAction(
        reference: ActionReference,
        source: ActionExecutionSource
    ) {
        Task { @MainActor [weak self] in
            await self?.executeHeadlessActionNow(reference: reference, source: source)
        }
    }

    private func executeHeadlessActionNow(
        reference: ActionReference,
        source: ActionExecutionSource
    ) async {
        let actionTitle = try? actionRegistry.registeredAction(for: reference).get()
            .definition.title
        let outcome = await actionExecutor.execute(
            ActionInvocation(
                reference: reference,
                source: source,
                mode: .foreground
            )
        )
        actionExecutionFeedbackHandler?(source, reference, actionTitle, outcome)
    }

    private func requestPermissionGuidance(forPluginID pluginID: String, permissionID: String) {
        guard let plugin = corePlugin(for: pluginID),
              (guardedValue(
                  for: plugin,
                  operation: "read permission requirements",
                  plugin.permissionRequirements
              ) ?? []).contains(where: { $0.id == permissionID }) else {
            return
        }

        // A plugin may report missing permission while refreshing in the background.
        // Update its presentation without opening guidance or System Settings; those
        // transitions require an explicit click in Settings.
        rebuildDerivedState(dirtyPluginIDs: [pluginID])
    }

    private func permissionActionTitle(
        for kind: HostPermissionKind,
        isGranted: Bool
    ) -> String {
        switch kind {
        case .accessibility, .inputMonitoring, .screenRecording:
            return isGranted
                ? AppL10n.plugins("plugin.permission.checkStatus", defaultValue: "检查授权状态")
                : AppL10n.plugins("plugin.permission.openAuthorization", defaultValue: "前往授权")
        case .fullDiskAccess:
            return isGranted
                ? AppL10n.plugins("plugin.permission.openSettings", defaultValue: "打开设置")
                : AppL10n.plugins("plugin.permission.openAuthorization", defaultValue: "前往授权")
        case .calendarFullAccess, .systemAudioRecording:
            return isGranted
                ? AppL10n.plugins("plugin.permission.checkStatus", defaultValue: "检查授权状态")
                : AppL10n.plugins("plugin.permission.requestAuthorization", defaultValue: "请求授权")
        case .automation, .finderExtension:
            return AppL10n.plugins("plugin.permission.openSettings", defaultValue: "打开设置")
        }
    }

    private func permissionIconName(for kind: HostPermissionKind) -> String {
        switch kind {
        case .accessibility:
            return "accessibility"
        case .inputMonitoring:
            return "keyboard.badge.eye"
        case .calendarFullAccess:
            return "calendar"
        case .automation:
            return "cursorarrow.click.2"
        case .finderExtension:
            return "puzzlepiece.extension"
        case .screenRecording:
            return "rectangle.dashed.badge.record"
        case .systemAudioRecording:
            return "waveform.badge.mic"
        case .fullDiskAccess:
            return "externaldrive.badge.checkmark"
        }
    }

    /// These capabilities predate first-class PluginKit permission kinds. Stable IDs let
    /// the host render them consistently without making an incompatible PluginKit v5 change.
    private func permissionPresentationRole(
        for requirement: PluginPermissionRequirement
    ) -> PermissionPresentationRole {
        switch requirement.id {
        case "full-disk-access": .fullDiskAccess
        case "finder-extension": .extensionManagement
        default: .system(requirement.kind)
        }
    }

    private enum PermissionPresentationRole {
        case system(PluginPermissionKind)
        case fullDiskAccess
        case extensionManagement
    }
}


struct MenuBarPanelContentSnapshot {
    let entries: [MenuBarPanelEntry]
    let components: [PluginPanelWidgetSnapshot]
    let features: [PluginPanelRowSnapshot]
}

extension PluginHost {
    var visibleMenuBarPanels: [MenuBarPanelDefinition] { menuBarPanels.filter { !$0.isHidden } }

    func panelItems(in panelID: String) -> [PluginPanelRowSnapshot] { panelContentSnapshot(in: panelID).features }
    func componentItems(in panelID: String) -> [PluginPanelWidgetSnapshot] { panelContentSnapshot(in: panelID).components }
    func panelEntries(in panelID: String) -> [MenuBarPanelEntry] { panelContentSnapshot(in: panelID).entries }

    func panelContentSnapshot(in panelID: String) -> MenuBarPanelContentSnapshot {
        if let cached = menuBarPanelContentCache[panelID] { return cached }
        let resolved = panelCoordinator.snapshot(in: panelID)
        let snapshot = MenuBarPanelContentSnapshot(entries: resolved.map(\.entry),
            components: resolved.compactMap { panelCoordinator.widgetSnapshot($0.item, id: $0.id) },
            features: resolved.compactMap { panelCoordinator.rowSnapshot($0.item, id: $0.id) })
        menuBarPanelContentCache[panelID] = snapshot
        return snapshot
    }

    func panelLayoutEntries(in panelID: String) -> [MenuBarPanelLayoutEntry] {
        panelCoordinator.snapshot(in: panelID).map { MenuBarPanelLayoutEntry(item: $0.item, entry: $0.entry) }
    }

    func rowIndicator(for id: String) -> PluginPanelRowIndicator? {
        guard let item = panelCoordinator.item(for: id),
              case let .row(row) = item.definition.content else { return nil }
        return row.state.indicator
    }

    func rowCompactIndicator(for id: String) -> PluginPanelRowCompactIndicator? {
        guard let item = panelCoordinator.item(for: id),
              case let .row(row) = item.definition.content else { return nil }
        return row.state.compactIndicator
    }

    @discardableResult
    func addMenuBarPanel() -> String? {
        guard let id = menuBarPanelStore.addPanel() else { return nil }
        panelConfigurationDidChange()
        return id
    }

    func updateMenuBarPanel(_ panel: MenuBarPanelDefinition) {
        let previous = menuBarPanelStore.configuration
        menuBarPanelStore.updatePanel(panel)
        guard previous != menuBarPanelStore.configuration else { return }
        panelConfigurationDidChange()
    }

    @discardableResult
    func deleteMenuBarPanel(id: String) -> String? {
        guard menuBarPanels.contains(where: { $0.id == id && !$0.isDefault }) else { return nil }
        if case let .failure(error) = shortcutAssignmentService.clear(panelActionReference(id: id)) {
            return error.localizedDescription
        }
        menuBarPanelStore.deletePanel(id: id)
        panelConfigurationDidChange()
        return nil
    }

    func moveMenuBarPanel(id: String, toOffset: Int) {
        menuBarPanelStore.movePanel(id: id, toOffset: toOffset)
        panelConfigurationDidChange()
    }

    var lastSelectedMenuBarPanelID: String { menuBarPanelStore.lastSelectedPanelID }

    func rememberMenuBarPanelSelection(id: String) { menuBarPanelStore.rememberSelection(id: id) }

    @discardableResult
    func restoreDefaultMenuBarPanelLayout() -> String? {
        let retiredActionIDs = Set(menuBarPanels.filter { !$0.isDefault }.map {
            panelActionReference(id: $0.id).key.actionID
        })
        if !retiredActionIDs.isEmpty,
           case let .failure(error) = shortcutAssignmentService.removeRetiredAssignments(
               providerID: "mactools", actionIDs: retiredActionIDs) {
            return error.localizedDescription
        }
        menuBarPanelStore.replace(MenuBarPanelConfiguration(), replacingUnreadable: true)
        panelConfigurationDidChange()
        return nil
    }

    @discardableResult
    func addPanelItem(_ key: PluginPanelItemKey, to panelID: String) -> Bool {
        guard panelCoordinator.item(for: key)?.isAvailable == true,
              visibleMenuBarPanels.contains(where: { $0.id == panelID }),
              menuBarPanelStore.addItem(key, to: panelID) != nil else { return false }
        panelConfigurationDidChange()
        return true
    }

    @discardableResult
    func removePanelEntry(_ entry: MenuBarPanelEntry, from panelID: String) -> Bool {
        guard panelEntries(in: panelID).contains(entry) else { return false }
        menuBarPanelStore.removePlacement(id: entry.placement.id)
        panelConfigurationDidChange()
        return true
    }

    func movePanelEntry(_ entry: MenuBarPanelEntry, panelID: String, toOffset: Int) {
        var entries = panelEntries(in: panelID)
        guard let index = entries.firstIndex(of: entry) else { return }
        entries.move(fromOffsets: IndexSet(integer: index), toOffset: min(max(toOffset, 0), entries.count))
        menuBarPanelStore.setOrder(entries.map(\.placement.id), panelID: panelID)
        panelConfigurationDidChange()
    }

    func transferPanelEntry(_ entry: MenuBarPanelEntry, from source: String, to destination: String,
                            at offset: Int) -> MenuBarPanelLayoutChange? {
        guard source != destination, panelEntries(in: source).contains(entry),
              visibleMenuBarPanels.contains(where: { $0.id == destination }) else { return nil }
        var visible = panelEntries(in: destination)
        visible.insert(entry, at: min(max(offset, 0), visible.count))
        let before = menuBarPanelStore.configuration
        menuBarPanelStore.movePlacement(id: entry.placement.id, to: destination,
                                        visibleOrder: visible.map(\.placement.id))
        let change = MenuBarPanelLayoutChange(before: before, after: menuBarPanelStore.configuration)
        guard change.before != change.after else { return nil }
        panelConfigurationDidChange()
        return change
    }

    func canUndoPanelLayoutChange(_ change: MenuBarPanelLayoutChange) -> Bool {
        menuBarPanelStore.configuration == change.after
    }

    @discardableResult
    func undoPanelLayoutChange(_ change: MenuBarPanelLayoutChange) -> Bool {
        guard canUndoPanelLayoutChange(change), menuBarPanelStore.replace(change.before) else { return false }
        panelConfigurationDidChange()
        return true
    }

    func setVisibleMenuBarPanel(_ panelID: String?) {
        visibleMenuBarPanelID = panelID
        panelCoordinator.setVisiblePanel(panelID)
    }

    func panelActionReference(id: String) -> ActionReference {
        let actionID: String
        switch id {
        case MenuBarPanelDefinition.componentsID: actionID = AppShortcutAction.toggleDashboard.rawValue
        case MenuBarPanelDefinition.featuresID: actionID = AppShortcutAction.toggleFeaturePanel.rawValue
        default: actionID = "app.toggle-panel.\(id)"
        }
        return ActionReference(key: ActionKey(providerID: "mactools", actionID: actionID))
    }

    private func synchronizePanelLayout(pluginOrder: [String]? = nil) {
        panelCoordinator.onLayoutChange = { [weak self] in
            guard let self else { return }
            self.menuBarPanelContentCache.removeAll(keepingCapacity: true)
            self.menuBarPanelContentDidChange.send()
        }
        panelCoordinator.invoke = { [weak self] id, action in
            guard let self, let plugin = self.corePlugin(for: id), !self.isPluginIsolated(plugin) else { return }
            self.guardPluginCall(plugin, operation: "panel item callback", action)
        }
        let order = pluginOrder ?? orderedPluginIDs()
        menuBarPanelStore.reconcile(panelCoordinator.initialPlacements(pluginOrder: order),
                                   discoveredPluginIDs: Set(order.filter { panelCoordinator.hasSnapshot(for: $0) }))
        menuBarPanelContentCache.removeAll(keepingCapacity: true)
        panelCoordinator.synchronize(configuration: menuBarPanelStore.configuration,
                                    pluginOrder: order, visiblePanelID: visibleMenuBarPanelID)
    }

    private func panelConfigurationDidChange() {
        let panels = menuBarPanelStore.configuration.displayPanels
        let containersChanged = panels != menuBarPanels
        if containersChanged { menuBarPanels = panels }
        if let visibleID = visibleMenuBarPanelID,
           !panels.contains(where: { $0.id == visibleID && !$0.isHidden }) {
            visibleMenuBarPanelID = panels.first(where: { !$0.isHidden })?.id
        }
        if containersChanged {
            rebuildDerivedState(dirtyPluginIDs: [], synchronizingShortcuts: true)
        } else {
            objectWillChange.send()
            synchronizePanelLayout()
            menuBarPanelContentDidChange.send()
        }
    }
}
