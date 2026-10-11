import Combine
import Carbon
import SwiftUI
import XCTest
@testable import MacToolsPluginKit
@testable import MacTools

@MainActor
final class MacToolsSearchTests: XCTestCase {

    func testIndexPreservesInstalledSettingsAndCommandsWithoutCatalog() throws {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin, SurfaceOnlySearchTestPlugin()])
        let appCommand = appHostCommandDefinition(
            id: "app-command.toggle-dashboard",
            action: .appShortcut(.toggleDashboard)
        )
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: host,
            appHostCommandDefinitions: [appCommand]
        )

        XCTAssertTrue(host.pluginManagementItems.isEmpty)
        let configuration = try XCTUnwrap(index.items.first {
            $0.id == "plugin.configuration.\(plugin.metadata.id)"
        })
        XCTAssertEqual(
            configuration.action,
            .navigate(destination: .plugins(.configuration(plugin.metadata.id)), target: nil)
        )
        XCTAssertTrue(index.items.contains {
            $0.kind == .setting && $0.title == "自动切换"
        })
        XCTAssertFalse(index.items.contains {
            $0.kind == .setting && $0.title == "暂不可用设置"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .setting && $0.title == "辅助功能授权"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .setting && $0.title == "降低亮度"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .setting && $0.title == "快捷键目标"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .command && $0.title == "让显示器休眠"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .command && $0.title == host.menuBarPanels[0].title
        })
        XCTAssertFalse(index.items.contains {
            $0.kind == .command && $0.title == AppShortcutAction.openCommandPalette.title
        })
        XCTAssertFalse(index.items.contains {
            $0.kind == .command && $0.title == AppShortcutAction.openSettings.title
        })
        XCTAssertFalse(index.items.contains {
            $0.id == "app-command.open-command-palette"
        })
        XCTAssertFalse(index.items.contains {
            $0.id == "app-command.open-settings"
        })
        XCTAssertTrue(index.items.contains {
            $0.id == "general-setting.appearance" && $0.kind == .setting
        })
        XCTAssertTrue(index.items.contains {
            $0.id == "general-setting.floatingPanels" && $0.kind == .setting
        })
        XCTAssertTrue(index.items.contains {
            $0.id == "general-setting.preferencesBackup" && $0.kind == .setting
        })
    }

    func testMarketplaceDiscoveryOpensDetailAndHighlightsOnlyStaticActions() throws {
        let item = marketplaceDiscoveryItem()
        let results = MacToolsSearchIndexBuilder.marketplaceDiscoveryResults(for: item)
        let index = MacToolsSearchIndex(items: results)
        let detail = SettingsNavigationDestination.marketplaceDetail(
            MarketplacePluginDetailTarget(pluginID: item.id)
        )

        XCTAssertEqual(
            results.first(where: { $0.id == "plugin.marketplace.\(item.id)" })?.action,
            .navigate(destination: detail, target: nil)
        )
        let staticAction = try XCTUnwrap(index.results(matching: "temporary cleanup").first)
        XCTAssertEqual(
            staticAction.action,
            .navigate(
                destination: .marketplaceDetail(MarketplacePluginDetailTarget(
                    pluginID: item.id, providerID: "catalog-provider", actionID: "cleanup"
                )),
                target: nil
            )
        )
        let dynamicTemplate = try XCTUnwrap(index.results(matching: "saved profiles").first)
        XCTAssertEqual(dynamicTemplate.action, .navigate(destination: detail, target: nil))
        XCTAssertTrue(results.allSatisfy { result in
            guard case .navigate = result.action else { return false }
            return result.kind == .navigation && result.confirmation == nil
        })
    }

    func testExecutableActionsSuppressOnlyMatchingCapabilityDiscovery() {
        let item = marketplaceDiscoveryItem()
        let reference = ActionReference(key: ActionKey(providerID: "catalog-provider", actionID: "cleanup"))
        let command = MacToolsSearchResult(
            id: "cleanup-command", kind: .command, title: "Temporary cleanup", subtitle: item.title,
            detail: "", keywords: [], systemImage: "trash", action: .executeAction(reference),
            confirmation: nil, suggestionPriority: nil
        )
        let discovery = MacToolsSearchIndexBuilder.marketplaceDiscoveryResults(
            for: item, excludingActionKeys: [reference.key]
        )
        let index = MacToolsSearchIndex(items: [command] + discovery)

        XCTAssertEqual(index.results(matching: "temporary cleanup").first?.action, .executeAction(reference))
        XCTAssertFalse(discovery.contains {
            guard case let .navigate(.marketplaceDetail(target), _) = $0.action else { return false }
            return target.actionHighlight != nil
        })
        XCTAssertEqual(
            index.results(matching: "saved profiles").first?.action,
            .navigate(destination: .marketplaceDetail(.init(pluginID: item.id)), target: nil)
        )
        XCTAssertTrue(discovery.contains { $0.id == "plugin.marketplace.\(item.id)" })
    }

    func testCommandResultsCarryCanonicalActionReferences() throws {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.title == "让显示器休眠"
            }
        )

        guard case let .executeAction(reference) = result.action else {
            return XCTFail("Expected the shared action executor route")
        }
        XCTAssertEqual(reference.key, ActionKey(providerID: "searchable", actionID: "sleep"))
        XCTAssertNotNil(try? host.actionRegistry.registeredAction(for: reference).get())
        XCTAssertEqual(
            host.actionShortcutCatalogItems.first(where: { $0.reference == reference })?.status,
            .unassigned
        )
    }

    func testMacToolsSearchActionExecutesThroughPresentationRouting() async throws {
        let host = makePluginHostForTests(plugins: [])
        var requests: [AppPresentationRequest] = []
        host.appPresentationHandler = { requests.append($0) }
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.title == host.menuBarPanels[0].title
            }
        )
        guard case let .executeAction(reference) = result.action else {
            return XCTFail("Expected a canonical action")
        }

        let outcome = await host.actionExecutor.execute(
            ActionInvocation(reference: reference, source: .unifiedSearch, mode: .foreground)
        )

        XCTAssertEqual(outcome, .completed(.succeeded()))
        XCTAssertEqual(requests, [.toggleDashboard])
    }

    func testModelQueryBindingKeepsCanonicalQueryAndResultsInSync() {
        let suiteName = "MacToolsSearchQueryBindingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = UnifiedSearchPaletteModel(
            commandContext: AppHostCommandContext(
                pluginHost: makePluginHostForTests(plugins: [SearchableTestPlugin()]),
                launchAtLoginController: LaunchAtLoginController(
                    service: SearchTestLaunchAtLoginService()
                ),
                appearanceUserDefaults: defaults
            ),
            recentStore: CommandPaletteRecentStore(userDefaults: defaults)
        )
        var transitions: [(String, String)] = []
        let binding = model.queryBinding { oldQuery, newQuery in
            transitions.append((oldQuery, newQuery))
        }

        binding.wrappedValue = "快捷键目标"

        XCTAssertEqual(model.query, "快捷键目标")
        XCTAssertEqual(model.sections.map(\.kind), [.results])
        XCTAssertEqual(model.results.map(\.title), ["快捷键目标"])
        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(transitions.first?.0, "")
        XCTAssertEqual(transitions.first?.1, "快捷键目标")

        binding.wrappedValue = "快捷键目标"
        XCTAssertEqual(transitions.count, 1)

        binding.wrappedValue = ""
        XCTAssertEqual(model.query, "")
        XCTAssertFalse(model.sections.contains { $0.kind == .results })
        XCTAssertEqual(transitions.count, 2)
    }

    func testSearchUsesTitleDescriptionAndKeywordsWithAllTokenMatching() {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let index = MacToolsSearchIndexBuilder.build(pluginHost: host)

        XCTAssertEqual(
            index.results(matching: "快捷键 目标").first?.title,
            "快捷键目标"
        )
        XCTAssertTrue(
            index.results(matching: "外接 屏幕").contains {
                $0.title == "快捷键目标"
            }
        )
        XCTAssertTrue(index.results(matching: "不存在 屏幕").isEmpty)
    }

    func testRecencyOnlyBreaksEquivalentLexicalMatches() {
        let exact = MacToolsSearchResult(
            id: "exact",
            kind: .command,
            title: "Display",
            subtitle: "",
            detail: "",
            keywords: [],
            systemImage: "display",
            action: .executeAction(
                ActionReference(key: ActionKey(providerID: "plugin", actionID: "exact"))
            ),
            confirmation: nil,
            suggestionPriority: nil
        )
        let recentPrefixReference = ActionReference(
            key: ActionKey(providerID: "plugin", actionID: "prefix")
        )
        let recentPrefix = MacToolsSearchResult(
            id: "prefix",
            kind: .command,
            title: "Display Settings",
            subtitle: "",
            detail: "",
            keywords: [],
            systemImage: "display",
            action: .executeAction(recentPrefixReference),
            confirmation: nil,
            suggestionPriority: nil
        )
        let index = MacToolsSearchIndex(items: [recentPrefix, exact])

        XCTAssertEqual(
            index.results(
                matching: "display",
                recentReferences: [recentPrefixReference]
            ).map(\.id),
            ["exact", "prefix"]
        )
    }

    func testZeroQuerySectionsDeduplicateRecentFromSuggested() {
        let recent = searchResult(id: "recent", kind: .command)
        let suggested = searchResult(id: "suggested", kind: .navigation)

        let sections = MacToolsSearchPresentation.sections(
            query: "",
            results: [recent, suggested],
            recentResults: [recent]
        )

        XCTAssertEqual(sections.map(\.kind), [.recent, .suggested])
        XCTAssertEqual(sections[0].results.map(\.id), ["recent"])
        XCTAssertEqual(sections[1].results.map(\.id), ["suggested"])
    }

    func testSearchIndexUsesUniqueStableIdentifiers() {
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: makePluginHostForTests(plugins: [SearchableTestPlugin()])
        )

        XCTAssertEqual(Set(index.items.map(\.id)).count, index.items.count)
    }

    func testPluginHostPerformsOnlyDeclaredCommands() {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let definition = plugin.commandDefinitions[0]

        XCTAssertTrue(
            host.performCommand(
                pluginID: plugin.metadata.id,
                expectedDefinition: definition
            )
        )
        XCTAssertFalse(
            host.performCommand(
                pluginID: "missing",
                expectedDefinition: definition
            )
        )

        XCTAssertEqual(plugin.performedCommandIDs, ["sleep"])
    }

    func testPluginHostValidatesLiveExactSettingsTargets() {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let index = MacToolsSearchIndexBuilder.build(pluginHost: host)
        let targets = index.items.compactMap { item -> PluginSettingsSearchTarget? in
            guard
                case let .navigate(_, .plugin(target)) = item.action,
                target.pluginID == plugin.metadata.id
            else {
                return nil
            }
            return target
        }

        XCTAssertFalse(targets.isEmpty)
        XCTAssertTrue(targets.allSatisfy(host.hasPluginSettingsSearchTarget))
        XCTAssertFalse(
            host.hasPluginSettingsSearchTarget(
                PluginSettingsSearchTarget(
                    pluginID: plugin.metadata.id,
                    entryID: "removed-entry"
                )
            )
        )
        XCTAssertFalse(
            host.hasPluginSettingsSearchTarget(
                PluginSettingsSearchTarget(
                    pluginID: plugin.metadata.id,
                    entryID: "hidden-row"
                )
            )
        )
    }

    func testAppCommandFailsWithoutPresentationRouting() {
        let host = makePluginHostForTests(plugins: [])

        XCTAssertFalse(host.performAppCommand(.toggleDashboard))
    }

    private func marketplaceDiscoveryItem() -> PluginManagementItem {
        PluginManagementItem(
            id: "catalog-tool", title: "Catalog Tool", summary: "Available capabilities",
            version: "1.0.0", state: .available, packageURL: nil,
            requiresRestartToFullyUnload: false, releaseNotesURL: nil,
            productMetadata: PluginProductMetadata(
                presentation: nil, discovery: nil, requirements: nil, privacy: nil,
                actions: .init(providers: [.init(
                    id: "catalog-provider", kind: "native",
                    staticActions: [.init(
                        id: "cleanup", title: .init(["en": "Temporary cleanup"]),
                        description: .init(["en": "Remove temporary files"]),
                        keywords: ["cache"], systemImage: "trash", parameters: [],
                        parameterSummary: nil, permissionIDs: [], risk: "confirmation-required",
                        surfaces: ["unified-search"], automaticEligible: false,
                        externalInvocation: "disabled"
                    )],
                    dynamicTemplates: [.init(
                        id: "profiles", title: .init(["en": "Saved profiles"]),
                        description: .init(["en": "Choose a saved profile"]),
                        entrySource: "local-profiles", keywords: ["preset"], parameters: [],
                        parameterSummary: .init(["en": "Profile name"]),
                        localOnlyIdentity: true, riskVariesByEntry: nil,
                        automaticEligibilityVariesByEntry: nil, permissionIDs: [],
                        risk: "normal", surfaces: ["unified-search"], automaticEligible: false,
                        externalInvocation: "disabled"
                    )]
                )]),
                setup: nil, relationships: nil
            )
        )
    }

    private func searchResult(
        id: String,
        kind: MacToolsSearchResultKind
    ) -> MacToolsSearchResult {
        MacToolsSearchResult(
            id: id,
            kind: kind,
            title: id,
            subtitle: "",
            detail: "",
            keywords: [],
            systemImage: "magnifyingglass",
            action: .navigate(destination: .general, target: nil),
            confirmation: nil,
            suggestionPriority: nil
        )
    }

    private func appHostCommandDefinition(
        id: String,
        action: AppHostCommandAction
    ) -> AppHostCommandDefinition {
        AppHostCommandDefinition(
            id: id,
            title: AppShortcutAction.toggleDashboard.title,
            description: AppShortcutAction.toggleDashboard.description,
            keywords: [],
            systemImage: AppShortcutAction.toggleDashboard.systemImage,
            confirmation: nil,
            action: action
        )
    }
}

@MainActor
private final class SearchTestLaunchAtLoginService: LaunchAtLoginServicing {
    var isRegistered = false

    func register() throws {
        isRegistered = true
    }

    func unregister() throws {
        isRegistered = false
    }
}

@MainActor
private final class SearchableTestPlugin:
    MacToolsPlugin, PluginGroupedShortcutSettingsProviding, PluginSettingsSearchProviding, PluginCommandProviding {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    static let customEntryID = "shortcut-target"
    var usesShortcutGroup = false

    let metadata = PluginMetadata(
        id: "searchable",
        title: "显示工具",
        iconName: "display",
        iconTint: Color(nsColor: .systemBlue),
        order: 1,
        defaultDescription: "管理内建和外接显示器亮度"
    )
    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var performedCommandIDs: [String] = []
    var commandTitle = "让显示器休眠"

    var shortcutSettingsGroups: [PluginShortcutSettingsGroupConfiguration] {
        guard usesShortcutGroup else { return [] }
        return [PluginShortcutSettingsGroupConfiguration(
            id: "primary-shortcuts",
            title: "Primary Shortcuts",
            systemImage: "keyboard",
            shortcutDefinitionIDs: ["decrease"]
        )]
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "automatic",
                    title: "自动切换",
                    rows: [
                        PluginSettingsRow(
                            id: "automatic-status",
                            title: "自动切换",
                            description: "根据屏幕状态自动切换亮度。",
                            control: .status(
                                text: "已开启",
                                systemImage: "checkmark.circle",
                                tone: .positive,
                                actionTitle: nil
                            )
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "temporarily-unavailable",
                    title: "暂不可用设置",
                    isVisible: false,
                    rows: [
                        PluginSettingsRow(
                            id: "hidden-row",
                            title: "暂不可用设置",
                            control: .toggle(isOn: false)
                        )
                    ]
                )
            ]
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: "accessibility",
                kind: .accessibility,
                title: "辅助功能授权",
                description: "允许控制显示器。"
            )
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: "decrease",
                title: "降低亮度",
                description: "降低目标显示器亮度。",
                actionID: "decrease",
                scope: .global,
                defaultBinding: nil,
                isRequired: false,
                settingsGroupID: usesShortcutGroup ? "primary-shortcuts" : nil,
                settingsGroupTitle: usesShortcutGroup ? "Primary Shortcuts" : nil
            )
        ]
    }

    var settingsSearchEntries: [PluginSettingsSearchEntry] {
        [
            PluginSettingsSearchEntry(
                id: Self.customEntryID,
                title: "快捷键目标",
                description: "选择亮度快捷键控制的外接显示器。",
                keywords: ["屏幕", "作用范围"],
                systemImage: "display.2"
            )
        ]
    }

    var commandDefinitions: [PluginCommandDefinition] {
        [
            PluginCommandDefinition(
                id: "sleep",
                title: commandTitle,
                description: "立即让所有屏幕进入休眠。",
                systemImage: "display"
            )
        ]
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: false, footnote: nil)
    }

    func handleAction(_ action: PluginPanelAction) {}

    func handleCommand(id: String) {
        performedCommandIDs.append(id)
    }
}

@MainActor
private final class SurfaceOnlySearchTestPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    let metadata = PluginMetadata(
        id: "surface-only",
        title: "锁定屏幕",
        iconName: "lock",
        iconTint: Color(nsColor: .systemGray),
        order: 2,
        defaultDescription: "立即锁定屏幕"
    )
    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .button,
        menuActionBehavior: .dismissBeforeHandling
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    func handleAction(_ action: PluginPanelAction) {}
}
