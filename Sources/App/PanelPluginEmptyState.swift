import MacToolsPluginKit
import SwiftUI

struct PanelPluginEmptyState: View {
    let systemImage: String
    @ObservedObject var pluginHost: PluginHost
    let onEditLayout: () -> Void
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
                .font(PluginTypography.sectionTitle.font)
            if status.isActive, !status.detailText.isEmpty {
                Text(status.detailText)
                    .font(PluginTypography.detail.font)
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
                Image(systemName: PluginSystemImage.resolvedName(systemImage))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.text.secondary)
                    .accessibilityHidden(true)

                Text(hasInstalledPlugins
                    ? FeatureL10n.string("此面板暂无内容")
                    : AppL10n.plugins("plugin.panel.empty.title", defaultValue: "暂无插件"))
                    .font(PluginTypography.sectionTitle.font)
                    .foregroundStyle(theme.text.primary)
            }

            Text(hasInstalledPlugins
                ? FeatureL10n.string("在编辑面板中添加内容")
                : AppL10n.plugins("plugin.panel.empty.installDescription", defaultValue: "安装插件后即可添加内容"))
                .font(PluginTypography.detail.font)
                .foregroundStyle(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            actionLink
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var hasInstalledPlugins: Bool { pluginHost.hasInstalledDynamicPlugins }

    private var actionLink: some View {
        Button(hasInstalledPlugins
            ? PanelLayoutCopy.edit
            : AppL10n.plugins("plugin.empty.install", defaultValue: "去安装")) {
            if hasInstalledPlugins {
                onEditLayout()
            } else {
                pluginHost.presentPluginMarketplace()
            }
        }
        .buttonStyle(.link)
        .font(PluginTypography.control.font)
        .foregroundStyle(theme.accent)
        .help(hasInstalledPlugins
            ? PanelLayoutCopy.edit
            : AppL10n.plugins("plugin.empty.openMarketplace", defaultValue: "打开插件市场"))
        .accessibilityIdentifier(hasInstalledPlugins ? "panel.empty.edit" : "panel.empty.install")
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }
}
