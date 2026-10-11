import Foundation
import MacToolsPluginKit

enum MacToolsSearchResultKind: CaseIterable, Hashable {
    case navigation
    case setting
    case command

    var title: String {
        switch self {
        case .navigation:
            return AppL10n.search("search.group.navigation", defaultValue: "导航")
        case .setting:
            return AppL10n.search("search.group.settings", defaultValue: "设置")
        case .command:
            return AppL10n.search("search.group.commands", defaultValue: "命令")
        }
    }

    var actionTitle: String {
        switch self {
        case .navigation:
            return AppL10n.search("search.action.open", defaultValue: "打开")
        case .setting:
            return AppL10n.search("search.action.goTo", defaultValue: "前往")
        case .command:
            return AppL10n.search("search.action.run", defaultValue: "执行")
        }
    }
}

enum MacToolsSearchAction: Hashable {
    case navigate(
        destination: SettingsNavigationDestination,
        target: SettingsSearchRevealTarget?
    )
    case executeAction(ActionReference)
    case collectActionInput(ActionInputItem)
    case pluginCommand(
        pluginID: String,
        expectedDefinition: PluginCommandDefinition
    )
    case appHostCommand(expectedDefinition: AppHostCommandDefinition)
}

struct MacToolsSearchResult: Identifiable, Hashable {
    let id: String
    let kind: MacToolsSearchResultKind
    let title: String
    let subtitle: String
    let detail: String
    let keywords: [String]
    let systemImage: String
    let action: MacToolsSearchAction
    let confirmation: MacToolsCommandConfirmation?
    let suggestionPriority: Int?

    var accessibilityLabel: String {
        [title, subtitle, kind.title].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    fileprivate var normalizedTitle: String {
        Self.normalize(title)
    }

    fileprivate var normalizedSubtitle: String {
        Self.normalize(subtitle)
    }

    fileprivate var normalizedDetail: String {
        Self.normalize(detail)
    }

    fileprivate var normalizedKeywords: String {
        Self.normalize(keywords.joined(separator: " "))
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MacToolsSearchResultID {
    static func action(
        reference: ActionReference,
        catalogIndex: Int
    ) -> String {
        if reference.parameters.entries.isEmpty {
            return "action.parameterless.\(reference.key.id)"
        }
        return "action.parameterized.\(reference.key.id).\(catalogIndex)"
    }
}

enum MacToolsSearchSupportingText {
    static func actionSubtitle(
        ownerTitle: String,
        catalogSubtitle: String?
    ) -> String {
        guard let catalogSubtitle else { return ownerTitle }
        let trimmedSubtitle = catalogSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSubtitle.isEmpty,
            MacToolsSearchResult.normalize(trimmedSubtitle)
                != MacToolsSearchResult.normalize(ownerTitle) else {
            return ownerTitle
        }
        return "\(ownerTitle) · \(trimmedSubtitle)"
    }
}

struct MacToolsSearchIndex {
    let items: [MacToolsSearchResult]
    private let indexedItems: [IndexedItem]
    private let resultsByActionReference: [ActionReference: MacToolsSearchResult]

    init(items: [MacToolsSearchResult]) {
        self.items = items
        self.indexedItems = items.map(IndexedItem.init)
        self.resultsByActionReference = Dictionary(
            items.compactMap { result in
                guard case let .executeAction(reference) = result.action else { return nil }
                return (reference, result)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func result(for reference: ActionReference) -> MacToolsSearchResult? {
        resultsByActionReference[reference]
    }

    func results(
        matching query: String,
        recentReferences: [ActionReference] = []
    ) -> [MacToolsSearchResult] {
        let normalizedQuery = MacToolsSearchResult.normalize(query)
        guard !normalizedQuery.isEmpty else {
            return items
                .filter { $0.suggestionPriority != nil }
                .sorted(by: suggestionOrder)
        }

        let tokens = normalizedQuery
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        let recencyByReference = Dictionary(
            recentReferences.enumerated().map { index, reference in
                (reference, recentReferences.count - index)
            },
            uniquingKeysWith: max
        )

        return indexedItems
            .compactMap { item -> RankedItem? in
                guard tokens.allSatisfy(item.haystack.contains) else {
                    return nil
                }

                let recency: Int
                if case let .executeAction(reference) = item.result.action {
                    recency = recencyByReference[reference] ?? 0
                } else {
                    recency = 0
                }
                return RankedItem(
                    item: item,
                    tier: matchTier(item, query: normalizedQuery, tokens: tokens),
                    score: score(item, query: normalizedQuery, tokens: tokens),
                    recency: recency
                )
            }
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier {
                    return lhs.tier.rawValue > rhs.tier.rawValue
                }
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.recency != rhs.recency {
                    return lhs.recency > rhs.recency
                }

                if lhs.item.result.kind != rhs.item.result.kind {
                    return kindOrder(lhs.item.result.kind) < kindOrder(rhs.item.result.kind)
                }

                let titleOrder = lhs.item.result.title.localizedStandardCompare(rhs.item.result.title)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                return lhs.item.result.id < rhs.item.result.id
            }
            .map(\.item.result)
    }

    private func matchTier(
        _ item: IndexedItem,
        query: String,
        tokens: [String]
    ) -> MatchTier {
        if item.normalizedTitle == query {
            return .exactTitle
        }
        if item.normalizedTitle.hasPrefix(query) {
            return .titlePrefix
        }
        if item.normalizedTitle.contains(query)
            || tokens.allSatisfy(item.normalizedTitle.contains) {
            return .title
        }
        if item.normalizedKeywords.contains(query)
            || tokens.allSatisfy(item.normalizedKeywords.contains) {
            return .keyword
        }
        return .supportingText
    }

    private func score(
        _ item: IndexedItem,
        query: String,
        tokens: [String]
    ) -> Int {
        var score = 0

        if item.normalizedTitle == query {
            score += 1_000
        } else if item.normalizedTitle.hasPrefix(query) {
            score += 700
        } else if item.normalizedTitle.contains(query) {
            score += 500
        }

        for token in tokens {
            if item.normalizedTitle.contains(token) {
                score += 180
            }
            if item.normalizedSubtitle.contains(token) {
                score += 90
            }
            if item.normalizedDetail.contains(token) {
                score += 50
            }
            if item.normalizedKeywords.contains(token) {
                score += 30
            }
        }

        return score
    }

    private func suggestionOrder(
        _ lhs: MacToolsSearchResult,
        _ rhs: MacToolsSearchResult
    ) -> Bool {
        let lhsPriority = lhs.suggestionPriority ?? .max
        let rhsPriority = rhs.suggestionPriority ?? .max
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func kindOrder(_ kind: MacToolsSearchResultKind) -> Int {
        switch kind {
        case .navigation: 0
        case .setting: 1
        case .command: 2
        }
    }

    private struct IndexedItem {
        let result: MacToolsSearchResult
        let normalizedTitle: String
        let normalizedSubtitle: String
        let normalizedDetail: String
        let normalizedKeywords: String
        let haystack: String

        init(result: MacToolsSearchResult) {
            self.result = result
            normalizedTitle = result.normalizedTitle
            normalizedSubtitle = result.normalizedSubtitle
            normalizedDetail = result.normalizedDetail
            normalizedKeywords = result.normalizedKeywords
            haystack = [
                normalizedTitle,
                normalizedSubtitle,
                normalizedDetail,
                normalizedKeywords
            ].joined(separator: " ")
        }
    }

    private enum MatchTier: Int {
        case supportingText = 1
        case keyword = 2
        case title = 3
        case titlePrefix = 4
        case exactTitle = 5
    }

    private struct RankedItem {
        let item: IndexedItem
        let tier: MatchTier
        let score: Int
        let recency: Int
    }
}

enum MacToolsSearchSectionKind: Hashable {
    case recent
    case suggested
    case results

    var title: String? {
        switch self {
        case .recent:
            AppL10n.search("search.group.recent", defaultValue: "最近操作")
        case .suggested:
            AppL10n.search("search.group.suggested", defaultValue: "建议")
        case .results:
            nil
        }
    }
}

struct MacToolsSearchSection: Identifiable, Hashable {
    var id: MacToolsSearchSectionKind { kind }

    let kind: MacToolsSearchSectionKind
    let results: [MacToolsSearchResult]
}

enum MacToolsSearchPresentation {
    static let quickSelectionLimit = 9

    static func sections(
        query: String,
        results: [MacToolsSearchResult],
        recentResults: [MacToolsSearchResult]
    ) -> [MacToolsSearchSection] {
        guard MacToolsSearchResult.normalize(query).isEmpty else {
            return results.isEmpty ? [] : [
                MacToolsSearchSection(kind: .results, results: results)
            ]
        }

        let recent = Array(recentResults.prefix(CommandPaletteRecentStore.maximumVisibleReferenceCount))
        let recentIDs = Set(recent.map(\.id))
        let suggested = results.filter { !recentIDs.contains($0.id) }
        return [
            recent.isEmpty ? nil : MacToolsSearchSection(kind: .recent, results: recent),
            suggested.isEmpty ? nil : MacToolsSearchSection(kind: .suggested, results: suggested)
        ].compactMap { $0 }
    }

    static func quickSelectionNumber(
        for resultID: String,
        in results: [MacToolsSearchResult]
    ) -> Int? {
        guard
            let index = results.prefix(quickSelectionLimit)
                .firstIndex(where: { $0.id == resultID })
        else {
            return nil
        }

        return results.distance(from: results.startIndex, to: index) + 1
    }
}

enum MacToolsSearchActivationDecision: Equatable {
    case execute
    case confirm(MacToolsCommandConfirmation)

    static func resolve(for result: MacToolsSearchResult) -> MacToolsSearchActivationDecision {
        guard let confirmation = result.confirmation else {
            return .execute
        }
        return .confirm(confirmation)
    }
}

@MainActor
enum MacToolsSearchIndexBuilder {
    static func build(
        pluginHost: PluginHost,
        appHostCommandDefinitions: [AppHostCommandDefinition] = []
    ) -> MacToolsSearchIndex {
        var items: [MacToolsSearchResult] = [
            navigationResult(
                id: "navigation.actions-and-shortcuts",
                title: FeatureL10n.string("操作与快捷键"),
                subtitle: AppL10n.search("search.subtitle.macTools", defaultValue: "MacTools"),
                detail: FeatureL10n.string("查找 MacTools 与插件操作，并在同一个冲突空间中管理全局快捷键。"),
                systemImage: "command",
                destination: .plugins(.actionsAndShortcuts),
                suggestionPriority: 2
            ),
            navigationResult(
                id: "navigation.automation",
                title: FeatureL10n.string("自动化"),
                subtitle: AppL10n.search("search.subtitle.macTools", defaultValue: "MacTools"),
                detail: FeatureL10n.string("创建工作流后，可组合多个 MacTools 操作。"),
                systemImage: "bolt.horizontal.circle",
                destination: .plugins(.automation),
                suggestionPriority: 3
            ),
            navigationResult(
                id: "navigation.general",
                title: AppL10n.settings("tab.general", defaultValue: "通用"),
                subtitle: AppL10n.search("search.subtitle.appSettings", defaultValue: "应用设置"),
                detail: AppL10n.search(
                    "search.detail.general",
                    defaultValue: "外观、语言、菜单栏图标、登录启动和偏好备份。"
                ),
                systemImage: "gearshape",
                destination: .general,
                suggestionPriority: 6
            ),
            navigationResult(
                id: "navigation.permissions",
                title: AppL10n.settings("tab.permissions", defaultValue: "权限"),
                subtitle: AppL10n.search("search.subtitle.appSettings", defaultValue: "应用设置"),
                detail: AppL10n.settings(
                    "permissions.description",
                    defaultValue: "集中查看已安装功能使用的 macOS 权限。"
                ),
                systemImage: "lock.shield",
                destination: .permissions,
                suggestionPriority: 5
            ),
            navigationResult(
                id: "navigation.marketplace",
                title: AppL10n.settings("plugins.sidebar.marketplace", defaultValue: "插件市场"),
                subtitle: AppL10n.search("search.subtitle.plugins", defaultValue: "插件"),
                detail: AppL10n.plugins(
                    "plugin.marketplace.description",
                    defaultValue: "安装、更新和管理 MacTools 插件。"
                ),
                systemImage: "shippingbox",
                destination: .plugins(.marketplace),
                suggestionPriority: 4
            ),
            navigationResult(
                id: "navigation.about",
                title: AppL10n.settings("tab.about", defaultValue: "关于"),
                subtitle: AppL10n.search("search.subtitle.appSettings", defaultValue: "应用设置"),
                detail: AppL10n.search(
                    "search.detail.about",
                    defaultValue: "版本、更新和项目链接。"
                ),
                systemImage: "info.circle",
                destination: .about,
                suggestionPriority: 7
            )
        ]

        items += generalSettingsResults()

        let managementItemsByID = Dictionary(
            uniqueKeysWithValues: pluginHost.pluginManagementItems.map { ($0.id, $0) }
        )
        let configurationItemsByID = Dictionary(
            uniqueKeysWithValues: pluginHost.pluginSettingsItems.map { ($0.pluginID, $0) }
        )

        items += pluginHost.pluginSettingsItems.map { item in
            let managementItem = managementItemsByID[item.pluginID]
            return MacToolsSearchResult(
                id: "plugin.configuration.\(item.pluginID)",
                kind: .navigation,
                title: item.title,
                subtitle: AppL10n.settings(
                    "plugins.sidebar.configurationSection",
                    defaultValue: "插件设置"
                ),
                detail: item.description,
                keywords: pluginMetadataKeywords(
                    pluginID: item.pluginID,
                    category: managementItem?.category,
                    releaseChannel: managementItem?.releaseChannel
                ),
                systemImage: item.iconName,
                action: .navigate(
                    destination: .plugins(.configuration(item.pluginID)),
                    target: nil
                ),
                confirmation: nil,
                suggestionPriority: nil
            )
        }

        items += pluginHost.pluginSettingsItems.flatMap { item in
            settingResults(for: item)
        }

        items += pluginHost.pluginSettingsSearchItems.compactMap { providedItem in
            guard
                let configuration = configurationItemsByID[providedItem.pluginID],
                configuration.hasPluginContent
            else {
                return nil
            }

            let entry = providedItem.entry
            return MacToolsSearchResult(
                id: providedItem.id,
                kind: .setting,
                title: entry.title,
                subtitle: "\(configuration.title) › \(AppL10n.search("search.subtitle.customSetting", defaultValue: "设置"))",
                detail: entry.description,
                keywords: entry.keywords,
                systemImage: entry.systemImage,
                action: .navigate(
                    destination: .plugins(.configuration(providedItem.pluginID)),
                    target: .plugin(
                        PluginSettingsSearchTarget(
                            pluginID: providedItem.pluginID,
                            entryID: entry.id
                        )
                    )
                ),
                confirmation: nil,
                suggestionPriority: nil
            )
        }

        let pluginTitlesByID = Dictionary(
            pluginHost.pluginManagementItems.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        items += pluginHost.actionInputRegistry.items.map { item in
            MacToolsSearchResult(
                id: "action.input.\(item.id.id)", kind: .command,
                title: item.definition.title, subtitle: item.descriptor.destination,
                detail: item.definition.description,
                keywords: item.definition.keywords + item.descriptor.aliases,
                systemImage: item.definition.systemImage, action: .collectActionInput(item),
                confirmation: nil, suggestionPriority: nil
            )
        }
        items += pluginHost.actionCatalogEntries.enumerated().compactMap { index, entry in
            if entry.reference.key.providerID == "mactools",
               let appAction = AppShortcutAction(
                   rawValue: entry.reference.key.actionID
               ),
               !appAction.isCommandPaletteSearchEligible {
                return nil
            }
            guard case let .success(action) = pluginHost.actionRegistry.registeredAction(
                    for: entry.reference
            )
            else {
                return nil
            }

            let availability = pluginHost.actionAvailability(for: entry.reference)
            let ownerTitle = entry.reference.key.providerID == "mactools"
                ? AppL10n.search("search.subtitle.macTools", defaultValue: "MacTools")
                : pluginTitlesByID[entry.reference.key.providerID]
                    ?? entry.reference.key.providerID
            let subtitle = MacToolsSearchSupportingText.actionSubtitle(
                ownerTitle: ownerTitle,
                catalogSubtitle: entry.subtitle
            )
            let permissionTitles = pluginHost.actionPermissionTitles(for: entry.reference)
            let permissionSummary = permissionTitles.isEmpty
                ? nil
                : FeatureL10n.format(
                    "所需权限：%@",
                    FeatureL10n.joined(permissionTitles)
                )
            let detail = [action.definition.description, permissionSummary, availability.reason]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            let shortcutText = pluginHost.actionShortcutSettingsItem(
                for: entry.reference
            )?.bindingText

            return MacToolsSearchResult(
                id: MacToolsSearchResultID.action(
                    reference: entry.reference,
                    catalogIndex: index
                ),
                kind: .command,
                title: entry.title,
                subtitle: subtitle,
                detail: detail,
                keywords: action.definition.keywords + [shortcutText].compactMap { $0 },
                systemImage: action.definition.systemImage,
                action: .executeAction(entry.reference),
                confirmation: action.definition.risk == .confirmationRequired
                    ? action.definition.confirmation.map(MacToolsCommandConfirmation.init)
                    : nil,
                suggestionPriority: nil
            )
        }

        let actionKeys = Set(pluginHost.actionCatalogEntries.map(\.reference.key))
        items += pluginHost.pluginCommandItems.compactMap { item in
            guard !actionKeys.contains(
                ActionKey(providerID: item.pluginID, actionID: item.definition.id)
            ) else {
                return nil
            }

            return MacToolsSearchResult(
                id: item.id,
                kind: .command,
                title: item.definition.title,
                subtitle: item.pluginTitle,
                detail: item.definition.description,
                keywords: item.definition.keywords,
                systemImage: item.definition.systemImage,
                action: .pluginCommand(
                    pluginID: item.pluginID,
                    expectedDefinition: item.definition
                ),
                confirmation: item.definition.confirmation.map(MacToolsCommandConfirmation.init),
                suggestionPriority: nil
            )
        }

        items += appHostCommandDefinitions.compactMap { definition in
            if case let .appShortcut(action) = definition.action,
               action.isCommandPaletteSearchEligible {
                return nil
            }

            return MacToolsSearchResult(
                id: definition.id,
                kind: .command,
                title: definition.title,
                subtitle: AppL10n.search("search.subtitle.macTools", defaultValue: "MacTools"),
                detail: definition.description,
                keywords: definition.keywords,
                systemImage: definition.systemImage,
                action: .appHostCommand(expectedDefinition: definition),
                confirmation: definition.confirmation,
                suggestionPriority: nil
            )
        }

        // Discovery must not displace commands that Search can already execute.
        let executableActionKeys = Set(items.compactMap { result -> ActionKey? in
            switch result.action {
            case let .executeAction(reference):
                reference.key
            case let .collectActionInput(item):
                item.id
            case let .pluginCommand(pluginID, definition):
                ActionKey(providerID: pluginID, actionID: definition.id)
            default:
                nil
            }
        })
        items += pluginHost.pluginManagementItems.flatMap { item in
            marketplaceDiscoveryResults(for: item, excludingActionKeys: executableActionKeys)
        }

        return MacToolsSearchIndex(items: deduplicated(items))
    }

    static func marketplaceDiscoveryResults(
        for item: PluginManagementItem,
        excludingActionKeys: Set<ActionKey> = []
    ) -> [MacToolsSearchResult] {
        let marketplaceTitle = AppL10n.settings(
            "plugins.sidebar.marketplace",
            defaultValue: "插件市场"
        )
        let detailDestination = SettingsNavigationDestination.marketplaceDetail(
            MarketplacePluginDetailTarget(pluginID: item.id)
        )
        var results = [MacToolsSearchResult(
            id: "plugin.marketplace.\(item.id)",
            kind: .navigation,
            title: item.title,
            subtitle: marketplaceTitle,
            detail: item.detailText,
            keywords: pluginMetadataKeywords(
                pluginID: item.id,
                category: item.category,
                releaseChannel: item.releaseChannel,
                additionalKeywords: item.productSearchKeywords
            ) + [item.statusText, item.version] + [item.summary].compactMap { $0 },
            systemImage: "shippingbox",
            action: .navigate(destination: detailDestination, target: nil),
            confirmation: nil,
            suggestionPriority: nil
        )]

        for provider in item.productMetadata?.actions?.providers ?? [] {
            for action in provider.staticActions {
                guard !excludingActionKeys.contains(ActionKey(providerID: provider.id, actionID: action.id)) else {
                    continue
                }
                results.append(MacToolsSearchResult(
                    id: "plugin.marketplace-action.\(item.id).\(provider.id).\(action.id)",
                    kind: .navigation,
                    title: action.title.localizedValue() ?? action.id,
                    subtitle: "\(item.title) › \(marketplaceTitle)",
                    detail: action.description.localizedValue() ?? "",
                    keywords: action.keywords + [item.id, provider.id, action.id]
                        + [action.parameterSummary?.localizedValue()].compactMap { $0 },
                    systemImage: action.systemImage,
                    action: .navigate(
                        destination: .marketplaceDetail(MarketplacePluginDetailTarget(
                            pluginID: item.id,
                            providerID: provider.id,
                            actionID: action.id
                        )),
                        target: nil
                    ),
                    confirmation: nil,
                    suggestionPriority: nil
                ))
            }
            for template in provider.dynamicTemplates {
                guard !excludingActionKeys.contains(ActionKey(providerID: provider.id, actionID: template.id)) else {
                    continue
                }
                results.append(MacToolsSearchResult(
                    id: "plugin.marketplace-template.\(item.id).\(provider.id).\(template.id)",
                    kind: .navigation,
                    title: template.title.localizedValue() ?? template.id,
                    subtitle: "\(item.title) › \(marketplaceTitle)",
                    detail: template.description.localizedValue() ?? "",
                    keywords: template.keywords + [item.id, provider.id, template.id, template.entrySource]
                        + [template.parameterSummary.localizedValue()].compactMap { $0 },
                    systemImage: "sparkles",
                    action: .navigate(destination: detailDestination, target: nil),
                    confirmation: nil,
                    suggestionPriority: nil
                ))
            }
        }
        return results
    }

    private static func navigationResult(
        id: String,
        title: String,
        subtitle: String,
        detail: String,
        systemImage: String,
        destination: SettingsNavigationDestination,
        suggestionPriority: Int
    ) -> MacToolsSearchResult {
        MacToolsSearchResult(
            id: id,
            kind: .navigation,
            title: title,
            subtitle: subtitle,
            detail: detail,
            keywords: [],
            systemImage: systemImage,
            action: .navigate(destination: destination, target: nil),
            confirmation: nil,
            suggestionPriority: suggestionPriority
        )
    }

    private static func generalSettingsResults() -> [MacToolsSearchResult] {
        return [
            generalSettingResult(
                target: .launchAtLogin,
                title: AppL10n.settings("launchAtLogin.title", defaultValue: "开机时启动"),
                detail: AppL10n.settings(
                    "launchAtLogin.description",
                    defaultValue: "登录系统时自动启动 MacTools 并显示在菜单栏。"
                ),
                keywords: [
                    AppL10n.settings("general.section.startup", defaultValue: "启动")
                ],
                systemImage: "power"
            ),
            generalSettingResult(
                target: .appearance,
                title: AppL10n.settings("appearance.title", defaultValue: "应用外观"),
                detail: AppL10n.settings(
                    "appearance.description",
                    defaultValue: "自动跟随系统，也可以固定为深色或浅色。"
                ),
                keywords: AppAppearancePreference.allCases.map(\.title),
                systemImage: "circle.lefthalf.filled"
            ),
            generalSettingResult(
                target: .floatingPanels,
                title: AppL10n.settings(
                    "floatingPanelAppearance.title",
                    defaultValue: "浮动面板外观"
                ),
                detail: AppL10n.settings(
                    "floatingPanelAppearance.description",
                    defaultValue: "跟随 macOS 的透明效果，或使用不透明的实色背景。"
                ),
                keywords: PluginFloatingPanelAppearance.allCases.map(\.title),
                systemImage: "rectangle.on.rectangle"
            ),
            generalSettingResult(
                target: .language,
                title: AppL10n.settings("language.title", defaultValue: "语言"),
                detail: AppL10n.settings(
                    "language.description",
                    defaultValue: "默认跟随系统语言，也可以固定为指定语言。"
                ),
                keywords: AppLanguagePreference.allCases.map(\.pickerTitle),
                systemImage: "globe"
            ),
            generalSettingResult(
                target: .menuBarIcon,
                title: AppL10n.settings("menuBarIcon.title", defaultValue: "菜单栏图标"),
                detail: AppL10n.settings(
                    "menuBarIcon.description",
                    defaultValue: "统一设置浅色和深色菜单栏图标，导入时会保留原图。"
                ),
                keywords: [
                    AppL10n.settings("menuBarIcon.restoreDefault", defaultValue: "恢复默认")
                ],
                systemImage: "menubar.rectangle"
            ),
            generalSettingResult(
                target: .appShortcuts,
                title: AppL10n.settings("shortcuts.title", defaultValue: "键盘快捷键"),
                detail: AppL10n.settings(
                    "shortcuts.description",
                    defaultValue: "为常用动作配置全局快捷键。编辑后立即生效，必要项不可删除。"
                ),
                keywords: [],
                systemImage: "command"
            ),
            generalSettingResult(
                target: .preferencesBackup,
                title: AppL10n.preferencesBackup(
                    "preferencesBackup.title",
                    defaultValue: "导出与导入偏好设置"
                ),
                detail: AppL10n.preferencesBackup(
                    "preferencesBackup.description",
                    defaultValue: "包含应用偏好、插件布局、快捷键、工作流、自动化规则、已保存的运行链接和支持导出的插件设置；不包含权限、缓存、凭证或运行历史。"
                ),
                keywords: [
                    AppL10n.preferencesBackup(
                        "preferencesBackup.export",
                        defaultValue: "导出偏好设置…"
                    ),
                    AppL10n.preferencesBackup(
                        "preferencesBackup.import",
                        defaultValue: "导入偏好设置…"
                    )
                ],
                systemImage: "externaldrive.badge.checkmark"
            )
        ]
    }

    private static func generalSettingResult(
        target: GeneralSettingsSearchTarget,
        title: String,
        detail: String,
        keywords: [String],
        systemImage: String
    ) -> MacToolsSearchResult {
        MacToolsSearchResult(
            id: "general-setting.\(target.rawValue)",
            kind: .setting,
            title: title,
            subtitle: AppL10n.settings("tab.general", defaultValue: "通用"),
            detail: detail,
            keywords: keywords,
            systemImage: systemImage,
            action: .navigate(destination: .general, target: .general(target)),
            confirmation: nil,
            suggestionPriority: nil
        )
    }

    private static func settingResults(
        for item: PluginSettingsPageItem
    ) -> [MacToolsSearchResult] {
        let settings = item.sections.flatMap { section -> [MacToolsSearchResult] in
            guard section.isVisible, case let .rows(rows) = section.content else {
                return []
            }

            return rows.filter(\.isVisible).map { row in
                let helpText = row.help ?? row.helpItems.joined(separator: " ")
                let optionKeywords: [String]
                switch row.control {
                case let .picker(_, options, _), let .choiceGroup(_, options):
                    optionKeywords = options.flatMap { option in
                        [option.title, option.description].compactMap { $0 }
                    }
                default:
                    optionKeywords = []
                }

                return settingResult(
                    id: "setting-row.\(item.pluginID).\(row.id)",
                    item: item,
                    title: row.title,
                    detail: row.description ?? helpText,
                    keywords: row.keywords
                        + optionKeywords
                        + [section.title, helpText, row.error].compactMap { $0 },
                    systemImage: row.systemImage ?? section.systemImage ?? "slider.horizontal.3",
                    entryID: row.id
                )
            }
        }

        let permissions = item.missingPermissionCards.map { card in
            settingResult(
                id: "permission.\(card.id)",
                item: item,
                title: card.title,
                detail: card.description,
                keywords: [
                    AppL10n.settings(
                        "plugins.configuration.section.permissions",
                        defaultValue: "权限"
                    ),
                    card.statusText,
                    card.footnote
                ].compactMap { $0 },
                systemImage: card.iconSystemImage,
                entryID: card.id
            )
        }

        let shortcuts = shortcutSettingResults(for: item)

        return settings + permissions + shortcuts
    }

    private static func shortcutSettingResults(
        for item: PluginSettingsPageItem
    ) -> [MacToolsSearchResult] {
        guard item.shortcutItems.allSatisfy({ $0.settingsGroupID != nil }) else {
            return item.shortcutItems.map { shortcut in
                settingResult(
                    id: "shortcut.\(shortcut.id)",
                    item: item,
                    title: shortcut.settingsControlTitle ?? shortcut.title,
                    detail: shortcut.description,
                    keywords: [
                        AppL10n.settings(
                            "plugins.configuration.section.shortcuts",
                            defaultValue: "快捷键"
                        ),
                        shortcut.bindingText
                    ],
                    systemImage: shortcut.settingsControlSystemImage ?? "command",
                    entryID: shortcut.id
                )
            }
        }

        var groupOrder: [String] = []
        var groups: [String: [ShortcutSettingsItem]] = [:]
        for shortcut in item.shortcutItems {
            guard let groupID = shortcut.settingsGroupID else {
                continue
            }

            if groups[groupID] == nil {
                groupOrder.append(groupID)
            }
            groups[groupID, default: []].append(shortcut)
        }

        return groupOrder.compactMap { groupID in
            guard let shortcuts = groups[groupID], let first = shortcuts.first else {
                return nil
            }

            return settingResult(
                id: "shortcut-group.\(item.pluginID).\(groupID)",
                item: item,
                title: first.settingsGroupTitle ?? first.title,
                detail: first.settingsGroupDescription ?? first.description,
                keywords: [
                    AppL10n.settings(
                        "plugins.configuration.section.shortcuts",
                        defaultValue: "快捷键"
                    )
                ] + shortcuts.flatMap {
                    [$0.settingsControlTitle, $0.title, $0.bindingText].compactMap { $0 }
                },
                systemImage: first.settingsControlSystemImage ?? "command",
                entryID: groupID
            )
        }
    }

    private static func settingResult(
        id: String,
        item: PluginSettingsPageItem,
        title: String,
        detail: String,
        keywords: [String],
        systemImage: String,
        entryID: String
    ) -> MacToolsSearchResult {
        MacToolsSearchResult(
            id: id,
            kind: .setting,
            title: title,
            subtitle: item.title,
            detail: detail,
            keywords: keywords,
            systemImage: systemImage,
            action: .navigate(
                destination: .plugins(.configuration(item.pluginID)),
                target: .plugin(
                    PluginSettingsSearchTarget(
                        pluginID: item.pluginID,
                        entryID: entryID
                    )
                )
            ),
            confirmation: nil,
            suggestionPriority: nil
        )
    }

    static func pluginMetadataKeywords(
        pluginID: String,
        category: String?,
        releaseChannel: String?,
        additionalKeywords: [String] = []
    ) -> [String] {
        var keywords = [pluginID] + additionalKeywords

        if let category = nonEmptyMetadataValue(category) {
            keywords.append(category)
            keywords.append(PluginCategory(rawString: category).displayName)
        }

        if let releaseChannel = nonEmptyMetadataValue(releaseChannel) {
            keywords.append(releaseChannel)
            if let channel = PluginReleaseChannel(rawString: releaseChannel) {
                keywords.append(channel.displayName)
            }
        }

        return keywords
    }

    private static func nonEmptyMetadataValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func deduplicated(
        _ items: [MacToolsSearchResult]
    ) -> [MacToolsSearchResult] {
        var seenIDs: Set<String> = []
        return items.filter { seenIDs.insert($0.id).inserted }
    }
}
