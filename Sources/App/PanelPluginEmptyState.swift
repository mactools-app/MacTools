import MacToolsPluginKit
import SwiftUI

struct PanelPluginEmptyState: View {
    let tab: MenuBarPanelTab
    @ObservedObject var pluginHost: PluginHost
    let onInstall: () -> Void
    @Environment(\.menuBarPanelTheme) private var theme

    var body: some View {
        if pluginHost.isPreparingPlugins {
            preparingState
        } else {
            emptyState
        }
    }

    private var preparingState: some View {
        let status = pluginHost.automaticPluginUpdateStatus
        return VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(status.isActive
                ? status.title
                : AppL10n.plugins("plugin.panel.loading.title", defaultValue: "正在加载插件"))
                .font(.system(size: 13, weight: .semibold))
            if status.isActive, !status.detailText.isEmpty {
                Text(status.detailText)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                Image(systemName: PluginSystemImage.resolvedName(tab.systemImage))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.text.secondary)

                Text(AppL10n.plugins("plugin.panel.empty.title", defaultValue: "暂无插件"))
                    .font(.system(size: 14, weight: .semibold))
            }

            installButton
            Button(FeatureL10n.string("工具组合…")) { pluginHost.presentStarterPacks() }
                .buttonStyle(.link)
                .font(PluginTypography.control.font)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var installButton: some View {
        Button(action: onInstall) {
            Text(AppL10n.plugins("plugin.empty.install", defaultValue: "去安装"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.accent)
        }
            .buttonStyle(.link)
            .help(AppL10n.plugins("plugin.empty.openMarketplace", defaultValue: "打开插件市场"))
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
    }
}
