import Combine
import Foundation
import MacToolsPluginKit

/// A complete Settings destination, including the currently selected Plugins
/// subpage. Instances are scoped to a single Settings window.
enum SettingsNavigationDestination: Hashable {
    case general
    case permissions
    case about
    case plugins(FeatureSettingsPane)
    case marketplaceDetail(MarketplacePluginDetailTarget)
    case starterPacks(StarterPackStep)

    var settingsDestination: SettingsDestination {
        switch self {
        case .general:
            .general
        case .permissions:
            // Keep the PluginKit destination enum ABI-stable. Permissions is
            // a host-owned Settings page within the broader plugin domain.
            .pluginConfiguration
        case .about:
            .about
        case .plugins, .marketplaceDetail, .starterPacks:
            .pluginConfiguration
        }
    }

    var featureSettingsPane: FeatureSettingsPane? {
        guard case let .plugins(pane) = self else {
            return nil
        }

        return pane
    }

}

/// A catalog-backed Marketplace destination. A provider/action pair is only
/// a presentation hint; it never represents an executable action request.
struct MarketplacePluginDetailTarget: Hashable {
    let pluginID: String
    let providerID: String?
    let actionID: String?

    init(pluginID: String, providerID: String? = nil, actionID: String? = nil) {
        self.pluginID = pluginID
        self.providerID = providerID
        self.actionID = actionID
    }

    var actionHighlight: MarketplacePluginActionHighlight? {
        guard let providerID, let actionID else { return nil }
        return MarketplacePluginActionHighlight(providerID: providerID, actionID: actionID)
    }
}

struct MarketplacePluginActionHighlight: Hashable {
    let providerID: String
    let actionID: String
}

extension SettingsNavigationDestination {
    static func settingsSidebarOrder(
        configurationIDs: some Sequence<String>
    ) -> [SettingsNavigationDestination] {
        return [
            .general,
            .permissions,
            .about
        ] + FeatureSettingsPane.settingsSidebarOrder(
            configurationIDs: configurationIDs
        ).map(SettingsNavigationDestination.plugins)
    }

}

enum SettingsSearchField: Equatable {
    case actionsAndShortcuts
    case pluginMarketplace
    case pluginSettings(String)
}

enum UnifiedSearchPresentationOrigin: Equatable {
    case settingsSidebar
    case keyboard
    case globalShortcut(String)
}

enum SettingsSidebarMoveDirection: Equatable {
    case previous
    case next
}

extension FeatureSettingsPane {
    static func settingsSidebarOrder(
        configurationIDs: some Sequence<String>
    ) -> [FeatureSettingsPane] {
        [
            .marketplace,
            .actionsAndShortcuts,
            .automation
        ] + configurationIDs.map(FeatureSettingsPane.configuration)
    }
}

struct SettingsSearchFocusRequest: Equatable {
    let id: UInt
    let field: SettingsSearchField
}

struct AboutUpdateActionRequest: Equatable {
    let id: UInt
    let version: String?
}

enum GeneralSettingsSearchTarget: String, Hashable {
    case launchAtLogin
    case appearance
    case floatingPanels
    case language
    case menuBarIcon
    case appShortcuts
    case preferencesBackup

    var scrollID: String {
        "general-search-anchor.\(rawValue)"
    }
}

enum SettingsSearchRevealTarget: Hashable {
    case general(GeneralSettingsSearchTarget)
    case marketplace(MarketplacePluginSearchTarget)
    case plugin(PluginSettingsSearchTarget)
    case automation(AutomationWorkflowSearchTarget)
}

struct AutomationWorkflowSearchTarget: Hashable {
    let workflowID: UUID
}

struct SettingsSearchRevealRequest: Equatable {
    let id: UInt
    let target: SettingsSearchRevealTarget
}

struct MarketplacePluginSearchTarget: Hashable {
    let pluginID: String

    var scrollID: String {
        "marketplace-search-anchor.\(pluginID)"
    }
}

enum MarketplacePluginSearchAvailability {
    static func contains(pluginID: String, in items: [PluginManagementItem]) -> Bool {
        items.contains { $0.id == pluginID }
    }
}

struct UnifiedSearchQuickSelectionRequest: Equatable {
    let id: UInt
    let number: Int
}

enum SettingsSidebarSection: String, Hashable {
    case app
    case customize
    case pluginSettings
}

enum SettingsSidebarNumberTarget: Hashable {
    case destination(SettingsNavigationDestination)
    case collapsedSection(SettingsSidebarSection)
}

enum SettingsSidebarNumberingPolicy {
    static let maximumShortcutCount = 9

    static func targets(
        appDestinations: [SettingsNavigationDestination],
        customizeDestinations: [SettingsNavigationDestination],
        pluginDestinations: [SettingsNavigationDestination],
        appExpanded: Bool,
        customizeExpanded: Bool,
        pluginSettingsExpanded: Bool,
        limit: Int? = maximumShortcutCount
    ) -> [SettingsSidebarNumberTarget] {
        var targets: [SettingsSidebarNumberTarget] = []
        targets += appExpanded
            ? appDestinations.map(SettingsSidebarNumberTarget.destination)
            : [.collapsedSection(.app)]
        targets += customizeExpanded
            ? customizeDestinations.map(SettingsSidebarNumberTarget.destination)
            : [.collapsedSection(.customize)]
        targets += pluginSettingsExpanded
            ? pluginDestinations.map(SettingsSidebarNumberTarget.destination)
            : [.collapsedSection(.pluginSettings)]
        return limit.map { Array(targets.prefix($0)) } ?? targets
    }

    static func movedTarget(
        from currentTarget: SettingsSidebarNumberTarget?,
        direction: SettingsSidebarMoveDirection,
        in targets: [SettingsSidebarNumberTarget]
    ) -> SettingsSidebarNumberTarget? {
        guard !targets.isEmpty else { return nil }
        guard let currentTarget, let currentIndex = targets.firstIndex(of: currentTarget) else {
            return direction == .next ? targets.first : targets.last
        }
        let nextIndex = currentIndex + (direction == .next ? 1 : -1)
        guard targets.indices.contains(nextIndex) else { return nil }
        return targets[nextIndex]
    }
}

enum SettingsSidebarHeaderAccessibility {
    static func isSelected(containsSelection: Bool) -> Bool {
        containsSelection
    }
}

struct SidebarNumberShortcutRequest: Equatable {
    let id: UInt
    let number: Int
}

struct SidebarMoveShortcutRequest: Equatable {
    let id: UInt
    let direction: SettingsSidebarMoveDirection
}

@MainActor
final class SettingsNavigationCoordinator: ObservableObject {
    private static let maximumHistoryCount = 128

    @Published private(set) var destination: SettingsNavigationDestination
    @Published var preferencesImportRequestID: UUID?
    var presentOnboarding: ((StarterPackStep) -> Bool)?
    @Published private(set) var searchFocusRequest: SettingsSearchFocusRequest?
    @Published private(set) var aboutUpdateActionRequest: AboutUpdateActionRequest?
    @Published private(set) var isUnifiedSearchPresented = false
    @Published private(set) var unifiedSearchPresentationOrigin: UnifiedSearchPresentationOrigin?
    @Published private(set) var unifiedSearchFocusRequestID: UInt = 0
    @Published private(set) var sidebarSelectionRevealRequestID: UInt = 0
    @Published private(set) var sidebarFocusRequestID: UInt = 0
    @Published private(set) var sidebarNumberShortcutRequest: SidebarNumberShortcutRequest?
    @Published private(set) var sidebarMoveShortcutRequest: SidebarMoveShortcutRequest?
    @Published private(set) var unifiedSearchQuickSelectionRequest: UnifiedSearchQuickSelectionRequest?
    @Published private(set) var searchRevealRequest: SettingsSearchRevealRequest?

    private(set) var history: [SettingsNavigationDestination]
    private(set) var historyIndex: Int
    private(set) var focusedSearchField: SettingsSearchField?

    private let sidebarOrder: () -> [SettingsNavigationDestination]
    private let isPluginConfigurationAvailable: (String) -> Bool
    private let hasPluginSettingsSearchField: (String) -> Bool
    private let focusPluginSettingsSearch: (String) -> Bool
    private let pluginSettingsSearchFocusTarget: (String) -> PluginSettingsSearchTarget?
    private let isPluginSettingsSearchTargetAvailable: (PluginSettingsSearchTarget) -> Bool
    private let isPluginManagementAvailable: (String) -> Bool
    private let isMarketplaceDetailAvailable: (MarketplacePluginDetailTarget) -> Bool
    private let isAutomationWorkflowAvailable: (UUID) -> Bool
    private let selectPluginSettingsPane: (FeatureSettingsPane) -> Bool
    private var nextSearchFocusRequestID: UInt = 0
    private var nextAboutUpdateActionRequestID: UInt = 0
    private var nextSearchRevealRequestID: UInt = 0
    private var nextUnifiedSearchQuickSelectionRequestID: UInt = 0
    private var nextSidebarNumberShortcutRequestID: UInt = 0
    private var nextSidebarMoveShortcutRequestID: UInt = 0

    convenience init(
        pluginHost: PluginHost,
        sidebarPreferences: SettingsSidebarPreferencesStore? = nil
    ) {
        self.init(
            initialDestination: .general,
            sidebarOrder: {
                let settingsItems = pluginHost.pluginSettingsItems
                let orderItems = settingsItems.map {
                    SettingsSidebarPluginOrderItem(
                        id: $0.id,
                        title: $0.title,
                        installedAt: $0.installedAt
                    )
                }
                let configurationIDs = sidebarPreferences?.orderedPluginIDs(for: orderItems)
                    ?? settingsItems.map(\.id)
                return SettingsNavigationDestination.settingsSidebarOrder(
                    configurationIDs: configurationIDs
                )
            },
            isPluginConfigurationAvailable: { pluginHost.hasPluginSettings(pluginID: $0) },
            hasPluginSettingsSearchField: { pluginHost.hasPluginSettingsSearchField(pluginID: $0) },
            focusPluginSettingsSearch: { pluginHost.focusPluginSettingsSearch(pluginID: $0) },
            pluginSettingsSearchFocusTarget: {
                pluginHost.pluginSettingsSearchFocusTarget(pluginID: $0)
            },
            isPluginSettingsSearchTargetAvailable: {
                pluginHost.hasPluginSettingsSearchTarget($0)
            },
            isPluginManagementAvailable: { pluginID in
                MarketplacePluginSearchAvailability.contains(
                    pluginID: pluginID,
                    in: pluginHost.pluginManagementItems
                )
            },
            isMarketplaceDetailAvailable: { target in
                pluginHost.canPresentMarketplaceDetail(target: target)
            },
            isAutomationWorkflowAvailable: { workflowID in
                pluginHost.automationController.workflows.contains { $0.id == workflowID }
            },
            selectPluginSettingsPane: { pluginHost.selectFeatureSettingsPane($0) }
        )
    }

    init(
        initialDestination: SettingsNavigationDestination = .general,
        sidebarOrder: @escaping () -> [SettingsNavigationDestination] = { [] },
        isPluginConfigurationAvailable: @escaping (String) -> Bool = { _ in true },
        hasPluginSettingsSearchField: @escaping (String) -> Bool = { _ in false },
        focusPluginSettingsSearch: @escaping (String) -> Bool = { _ in false },
        pluginSettingsSearchFocusTarget: @escaping (String) -> PluginSettingsSearchTarget? = { _ in nil },
        isPluginSettingsSearchTargetAvailable: @escaping (PluginSettingsSearchTarget) -> Bool = { _ in true },
        isPluginManagementAvailable: @escaping (String) -> Bool = { _ in true },
        isMarketplaceDetailAvailable: @escaping (MarketplacePluginDetailTarget) -> Bool = { _ in true },
        isAutomationWorkflowAvailable: @escaping (UUID) -> Bool = { _ in true },
        selectPluginSettingsPane: @escaping (FeatureSettingsPane) -> Bool = { _ in true }
    ) {
        self.destination = initialDestination
        self.history = [initialDestination]
        self.historyIndex = 0
        self.sidebarOrder = sidebarOrder
        self.isPluginConfigurationAvailable = isPluginConfigurationAvailable
        self.hasPluginSettingsSearchField = hasPluginSettingsSearchField
        self.focusPluginSettingsSearch = focusPluginSettingsSearch
        self.pluginSettingsSearchFocusTarget = pluginSettingsSearchFocusTarget
        self.isPluginSettingsSearchTargetAvailable = isPluginSettingsSearchTargetAvailable
        self.isPluginManagementAvailable = isPluginManagementAvailable
        self.isMarketplaceDetailAvailable = isMarketplaceDetailAvailable
        self.isAutomationWorkflowAvailable = isAutomationWorkflowAvailable
        self.selectPluginSettingsPane = selectPluginSettingsPane
    }

    var canGoBack: Bool {
        traversableHistoryIndex(startingAt: historyIndex - 1, step: -1) != nil
    }

    var canGoForward: Bool {
        traversableHistoryIndex(startingAt: historyIndex + 1, step: 1) != nil
    }

    func selectSettingsDestination(_ destination: SettingsDestination) {
        guard self.destination.settingsDestination != destination else {
            return
        }

        switch destination {
        case .general:
            navigate(to: .general)
        case .about:
            navigate(to: .about)
        case .pluginConfiguration:
            navigate(to: .plugins(.marketplace))
        }
    }

    func navigate(to destination: SettingsNavigationDestination) {
        guard isAvailable(destination), destination != self.destination else {
            return
        }

        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }

        history.append(destination)
        if history.count > Self.maximumHistoryCount {
            history.removeFirst(history.count - Self.maximumHistoryCount)
        }
        historyIndex = history.count - 1
        activate(destination)
    }

    func requestPreferencesImport() {
        preferencesImportRequestID = UUID()
        _ = navigateFromSearch(to: .general, target: .general(.preferencesBackup))
    }

    func presentStarterPacks(_ step: StarterPackStep) {
        if presentOnboarding?(step) != true { navigate(to: .starterPacks(step)) }
    }

    @discardableResult
    func moveSidebarSelection(
        _ direction: SettingsSidebarMoveDirection,
        in orderedDestinations: [SettingsNavigationDestination]
    ) -> Bool {
        let sidebarDestination = destination.sidebarDestination
        guard
            let currentIndex = orderedDestinations.firstIndex(of: sidebarDestination)
        else {
            return false
        }

        let step = switch direction {
        case .previous:
            -1
        case .next:
            1
        }
        var adjacentIndex = currentIndex + step

        while orderedDestinations.indices.contains(adjacentIndex) {
            let candidate = orderedDestinations[adjacentIndex]
            if isAvailable(candidate) {
                navigate(to: candidate)
                return true
            }
            adjacentIndex += step
        }
        return false
    }

    @discardableResult
    func moveSidebarSelection(_ direction: SettingsSidebarMoveDirection) -> Bool {
        nextSidebarMoveShortcutRequestID &+= 1
        sidebarMoveShortcutRequest = SidebarMoveShortcutRequest(
            id: nextSidebarMoveShortcutRequestID,
            direction: direction
        )
        return true
    }

    @discardableResult
    func performSidebarNumberShortcut(number: Int) -> Bool {
        guard (1...SettingsSidebarNumberingPolicy.maximumShortcutCount).contains(number) else {
            return false
        }
        nextSidebarNumberShortcutRequestID &+= 1
        sidebarNumberShortcutRequest = SidebarNumberShortcutRequest(
            id: nextSidebarNumberShortcutRequestID,
            number: number
        )
        return true
    }

    func requestAboutUpdateAction(version: String?) {
        navigate(to: .about)
        nextAboutUpdateActionRequestID &+= 1
        aboutUpdateActionRequest = AboutUpdateActionRequest(
            id: nextAboutUpdateActionRequestID,
            version: version
        )
    }

    func presentUnifiedSearch(origin: UnifiedSearchPresentationOrigin) {
        unifiedSearchPresentationOrigin = origin
        isUnifiedSearchPresented = true
        unifiedSearchFocusRequestID &+= 1
    }

    func dismissUnifiedSearch() {
        isUnifiedSearchPresented = false
        unifiedSearchPresentationOrigin = nil
        unifiedSearchQuickSelectionRequest = nil
    }

    @discardableResult
    func requestUnifiedSearchQuickSelection(number: Int) -> Bool {
        guard isUnifiedSearchPresented, (1...9).contains(number) else {
            return false
        }

        nextUnifiedSearchQuickSelectionRequestID &+= 1
        unifiedSearchQuickSelectionRequest = UnifiedSearchQuickSelectionRequest(
            id: nextUnifiedSearchQuickSelectionRequestID,
            number: number
        )
        return true
    }

    @discardableResult
    func consumeUnifiedSearchQuickSelectionRequest(
        _ request: UnifiedSearchQuickSelectionRequest
    ) -> Bool {
        guard unifiedSearchQuickSelectionRequest == request else {
            return false
        }

        unifiedSearchQuickSelectionRequest = nil
        return true
    }

    @discardableResult
    func navigateFromSearch(
        to destination: SettingsNavigationDestination,
        target: SettingsSearchRevealTarget?
    ) -> Bool {
        guard canNavigateFromSearch(to: destination, target: target) else {
            return false
        }

        dismissUnifiedSearch()
        if case let .starterPacks(step) = destination {
            presentStarterPacks(step)
        } else {
            navigate(to: destination)
        }

        guard let target else {
            searchRevealRequest = nil
            sidebarFocusRequestID &+= 1
            return true
        }

        nextSearchRevealRequestID &+= 1
        searchRevealRequest = SettingsSearchRevealRequest(
            id: nextSearchRevealRequestID,
            target: target
        )
        return true
    }

    func canNavigateFromSearch(
        to destination: SettingsNavigationDestination,
        target: SettingsSearchRevealTarget?
    ) -> Bool {
        isAvailable(destination)
            && (target.map(isAvailable) ?? true)
            && (target.map { isCompatible($0, with: destination) } ?? true)
    }

    func clearSearchRevealRequest(_ request: SettingsSearchRevealRequest) {
        guard searchRevealRequest == request else {
            return
        }

        searchRevealRequest = nil
    }

    func clearSearchRevealRequest(matching target: SettingsSearchRevealTarget) {
        guard searchRevealRequest?.target == target else {
            return
        }

        searchRevealRequest = nil
    }

    @discardableResult
    func consumeAboutUpdateActionRequest(_ request: AboutUpdateActionRequest) -> Bool {
        guard aboutUpdateActionRequest == request else {
            return false
        }

        aboutUpdateActionRequest = nil
        return true
    }

    func goBack() {
        traverseHistory(startingAt: historyIndex - 1, step: -1)
    }

    func goForward() {
        traverseHistory(startingAt: historyIndex + 1, step: 1)
    }

    func reconcileCurrentDestinationAvailability() {
        // Informational details own their loading and unavailable states. Keep
        // the current page visible when catalog resolution changes availability.
        if case .marketplaceDetail = destination { return }
        guard !isAvailable(destination) else {
            return
        }

        navigate(to: .plugins(.marketplace))
    }

    @discardableResult
    func requestSearchFocus() -> Bool {
        guard
            !isUnifiedSearchPresented,
            let field = searchField(for: destination),
            focusedSearchField != field
        else {
            return false
        }

        if case let .pluginSettings(pluginID) = field {
            guard focusPluginSettingsSearch(pluginID) else {
                return false
            }
            if let target = pluginSettingsSearchFocusTarget(pluginID) {
                nextSearchRevealRequestID &+= 1
                searchRevealRequest = SettingsSearchRevealRequest(
                    id: nextSearchRevealRequestID,
                    target: .plugin(target)
                )
            }
            return true
        }

        nextSearchFocusRequestID &+= 1
        searchFocusRequest = SettingsSearchFocusRequest(
            id: nextSearchFocusRequestID,
            field: field
        )
        return true
    }

    @discardableResult
    func requestSearch() -> Bool {
        guard !isUnifiedSearchPresented else {
            return false
        }

        guard let searchField = searchField(for: destination) else { return false }
        if focusedSearchField == searchField {
            return true
        }
        return requestSearchFocus()
    }

    func setSearchField(_ field: SettingsSearchField, focused: Bool) {
        if focused {
            focusedSearchField = field
        } else if focusedSearchField == field {
            focusedSearchField = nil
        }
    }

    private func searchField(for destination: SettingsNavigationDestination) -> SettingsSearchField? {
        switch destination {
        case .plugins(.actionsAndShortcuts):
            .actionsAndShortcuts
        case .plugins(.marketplace):
            .pluginMarketplace
        case let .plugins(.configuration(pluginID)) where hasPluginSettingsSearchField(pluginID):
            .pluginSettings(pluginID)
        default:
            nil
        }
    }

    private func traverseHistory(startingAt index: Int, step: Int) {
        guard let index = traversableHistoryIndex(startingAt: index, step: step) else {
            return
        }

        let destination = history[index]
        historyIndex = index
        activate(destination)
    }

    private func traversableHistoryIndex(startingAt index: Int, step: Int) -> Int? {
        var index = index

        while history.indices.contains(index) {
            let candidate = history[index]
            if isAvailable(candidate), candidate != destination {
                return index
            }

            index += step
        }

        return nil
    }

    private func isAvailable(_ destination: SettingsNavigationDestination) -> Bool {
        switch destination {
        case let .plugins(.configuration(pluginID)):
            isPluginConfigurationAvailable(pluginID)
        case let .marketplaceDetail(target):
            isMarketplaceDetailAvailable(target)
        default:
            true
        }
    }

    private func isAvailable(_ target: SettingsSearchRevealTarget) -> Bool {
        switch target {
        case .general:
            true
        case let .marketplace(target):
            isPluginManagementAvailable(target.pluginID)
        case let .plugin(target):
            isPluginSettingsSearchTargetAvailable(target)
        case let .automation(target):
            isAutomationWorkflowAvailable(target.workflowID)
        }
    }

    private func isCompatible(
        _ target: SettingsSearchRevealTarget,
        with destination: SettingsNavigationDestination
    ) -> Bool {
        switch (target, destination) {
        case (.general, .general):
            true
        case (.marketplace, .plugins(.marketplace)):
            true
        case let (.plugin(target), .plugins(.configuration(pluginID))):
            target.pluginID == pluginID
        case (.automation, .plugins(.automation)):
            true
        default:
            false
        }
    }

    private func activate(_ destination: SettingsNavigationDestination) {
        if destination.sidebarDestination == .plugins(.marketplace) {
            _ = selectPluginSettingsPane(.marketplace)
        } else if let pane = destination.featureSettingsPane {
            _ = selectPluginSettingsPane(pane)
        }

        self.destination = destination
    }
}

extension SettingsNavigationDestination {
    var sidebarDestination: SettingsNavigationDestination {
        switch self {
        case .marketplaceDetail, .starterPacks:
            return .plugins(.marketplace)
        default:
            return self
        }
    }
}
