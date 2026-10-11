import Foundation

/// Session-only feedback for explicit catalog operations, scoped to one plugin.
struct PluginMarketplaceOperation: Equatable {
    enum Kind: Equatable {
        case install
        case update
    }

    enum Phase: Equatable {
        case running
        case completed
        case failed(String)
    }

    let kind: Kind
    let phase: Phase

    var isActive: Bool { phase == .running }
}

enum PluginMarketplaceOperationError: LocalizedError {
    case catalogUnavailable
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .catalogUnavailable:
            AppL10n.plugins(
                "plugin.marketplace.detail.catalogUnavailable",
                defaultValue: "插件列表暂不可用，请稍后重试。"
            )
        case .operationInProgress:
            AppL10n.plugins(
                "plugin.marketplace.detail.operationInProgress",
                defaultValue: "此插件正在安装或更新，请稍候。"
            )
        }
    }
}
