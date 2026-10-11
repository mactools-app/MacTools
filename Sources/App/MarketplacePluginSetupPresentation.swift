import Foundation
import MacToolsPluginKit

/// Projects existing repair destinations without requesting permissions or running plugin actions.
struct MarketplacePluginSetupPresentation {
    enum Intent: Equatable {
        case permission(pluginID: String, permissionID: String)
        case recheckRequirements
        case openSettings(pluginID: String)
    }

    struct Action {
        let title: String
        let intent: Intent
    }

    struct Issue: Identifiable {
        enum Kind: String, Equatable {
            case permission
            case restart
            case loadFailure
            case runtimeIsolation
            case incompatible
            case revoked
            case runtimeUnavailable
        }

        let id: String
        let kind: Kind
        let title: String
        let detail: String
        let systemImage: String
        let permissionCard: PluginPermissionCard?
        let action: Action?
    }

    let issues: [Issue]

    init(
        item: PluginManagementItem,
        missingPermissionCards: [PluginPermissionCard],
        runtimeIsolationFailure: String? = nil,
        isRuntimeLoaded: Bool,
        hasSettings: Bool
    ) {
        let isInstalled = item.packageURL != nil
        let settingsAction = isInstalled && hasSettings ? Action(
            title: AppL10n.plugins("plugin.marketplace.openSettings", defaultValue: "打开设置"),
            intent: .openSettings(pluginID: item.id)
        ) : nil
        let recheckAction = Action(
            title: AppL10n.plugins("plugin.requirement.recheck", defaultValue: "重新检查"),
            intent: .recheckRequirements
        )
        var problems: [Issue] = []
        func append(_ kind: Issue.Kind, title: String, detail: String, symbol: String, action: Action?) {
            problems.append(Issue(
                id: "\(item.id).setup.\(kind.rawValue)", kind: kind, title: title, detail: detail,
                systemImage: symbol, permissionCard: nil, action: action
            ))
        }

        switch item.state {
        case let .failed(reason):
            append(.loadFailure, title: item.statusText, detail: reason,
                   symbol: "exclamationmark.triangle", action: recheckAction)
        case let .incompatible(reason):
            append(.incompatible, title: item.statusText, detail: reason,
                   symbol: "exclamationmark.triangle", action: recheckAction)
        case .revoked:
            append(.revoked, title: item.statusText, detail: item.detailText,
                   symbol: "exclamationmark.triangle", action: nil)
        case .available, .localDevelopment, .installed, .updateAvailable, .restartRequired:
            break
        }

        if isInstalled, item.state == .restartRequired || item.requiresRestartToFullyUnload {
            append(.restart,
                   title: AppL10n.plugins("plugin.status.restartRequired", defaultValue: "需重启"),
                   detail: AppL10n.plugins("plugin.marketplace.setup.restart.description", defaultValue: "请重启 MacTools，以启用已安装的插件版本。"),
                   symbol: "restart.circle", action: nil)
        }
        if isInstalled, let failure = runtimeIsolationFailure {
            append(.runtimeIsolation,
                   title: AppL10n.plugins("plugin.status.failed", defaultValue: "加载失败"),
                   detail: AppL10n.pluginsFormat(
                       "plugin.marketplace.setup.runtimeIsolation.descriptionFormat",
                       defaultValue: "%@\n请重启 MacTools，以重新加载此插件。",
                       failure
                   ),
                   symbol: "exclamationmark.triangle", action: settingsAction)
        } else if isInstalled, !isRuntimeLoaded, problems.isEmpty {
            append(.runtimeUnavailable,
                   title: AppL10n.plugins("plugin.marketplace.setup.runtimeUnavailable.title", defaultValue: "插件尚未就绪"),
                   detail: AppL10n.plugins("plugin.marketplace.setup.runtimeUnavailable.description", defaultValue: "插件包已安装，但尚未加载。请重新检查；若仍不可用，请重启 MacTools。"),
                   symbol: "exclamationmark.triangle", action: recheckAction)
        }

        if isInstalled, isRuntimeLoaded, runtimeIsolationFailure == nil {
            var includedIDs: Set<String> = []
            for card in missingPermissionCards where card.pluginID == item.id && includedIDs.insert(card.id).inserted {
                problems.append(Issue(
                    id: card.id, kind: .permission, title: card.title, detail: card.description,
                    systemImage: card.iconSystemImage, permissionCard: card,
                    action: Action(title: card.buttonTitle,
                                   intent: .permission(pluginID: card.pluginID, permissionID: card.permissionID))
                ))
            }
        }

        issues = problems
    }
}
