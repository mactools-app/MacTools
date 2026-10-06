import AppKit
import MacToolsPluginKit
import SwiftUI

extension AIUsagePlugin {
    var settingsPage: PluginSettingsPage? {
        let preferences = model.preferences
        return .form(description: strings.text("settings.description", "集中查看订阅额度和重置时间。"), sections: [
            PluginSettingsSection(
                id: "data-access", title: strings.text("settings.access", "数据访问"), systemImage: "lock.shield",
                footer: strings.text("access.footer", "仅读取登录凭据并向对应服务查询额度，不读取对话、不保存令牌。授权与服务展示独立，无需辅助功能或完全磁盘访问权限。"),
                rows: [
                    PluginSettingsRow(id: ControlID.access, title: strings.text("access.allow", "读取本机登录文件"),
                                      description: strings.text("access.description", "允许读取 Codex 和 Claude Code 的本机登录文件。"),
                                      control: .toggle(isOn: preferences.allowsCredentialAccess)),
                    PluginSettingsRow(id: ControlID.keychain, title: strings.text("keychain.title", "读取 Claude Code 钥匙串"),
                                      description: model.keychainAccessFailure.map { strings.failure($0, provider: .claude) }
                                        ?? (model.isAuthorizingKeychain ? strings.text("keychain.authorizing", "正在请求钥匙串访问…")
                                            : strings.text("keychain.description", "开启时可能请求 macOS 授权，后台读取不会弹窗。")),
                                      control: .toggle(isOn: preferences.allowsClaudeKeychain))
                ]
            ),
            PluginSettingsSection(id: "providers", title: strings.text("settings.providers", "AI 服务"),
                                  systemImage: "square.stack.3d.up", presentation: .edgeToEdge) { [self] _ in
                AIUsageServiceSettingsView(model: model, strings: strings, assets: assets)
            },
            PluginSettingsSection(id: "menu-bar", title: strings.text("settings.menuBar", "菜单栏"), systemImage: "menubar.rectangle", rows: [
                PluginSettingsRow(id: ControlID.menuBar, title: strings.text("menuBar.show", "在菜单栏显示用量"),
                                  description: strings.text("menuBar.description", "显示所有已启用服务的剩余额度。点击打开仪表盘，右键打开设置。"),
                                  control: .toggle(isOn: preferences.showsMenuBar))
            ]),
            PluginSettingsSection(id: "refresh", title: strings.text("settings.refresh", "刷新"), systemImage: "arrow.clockwise",
                                  footer: strings.text("refresh.footer", "锁屏和睡眠时暂停刷新。请求失败后自动延迟重试，手动刷新至少间隔 1 分钟。"), rows: [
                PluginSettingsRow(id: ControlID.interval, title: strings.text("refresh.interval", "自动刷新间隔"),
                                  control: .picker(selectionID: String(preferences.refreshInterval), options:
                                    AIUsagePreferences.refreshIntervals.map {
                                        PluginSettingsOption(id: String($0), title: strings.localization.format("refresh.minutes", defaultValue: "%d 分钟", $0 / 60))
                                    }, style: .menu)),
                PluginSettingsRow(id: ControlID.refresh, title: strings.text("refresh.now", "立即刷新"),
                                  isEnabled: !preferences.queryableProviders.isEmpty && !model.isRefreshing,
                                  control: .action(title: model.isRefreshing ? strings.text("refresh.running", "正在刷新…") : strings.text("refresh.now", "立即刷新"), role: .normal))
            ])
        ])
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setBoolean(id, value):
            if id == ControlID.keychain {
                model.setClaudeKeychainAccess(value)
                return
            }
            model.updatePreferences { preferences in
                switch id {
                case ControlID.access: preferences.allowsCredentialAccess = value
                case ControlID.menuBar: preferences.showsMenuBar = value
                case ControlID.provider(.codex): preferences.codexEnabled = value
                case ControlID.provider(.claude): preferences.claudeEnabled = value
                default: break
                }
            }
        case let .setSelection(id, value):
            if id == ControlID.interval, let interval = Int(value), AIUsagePreferences.refreshIntervals.contains(interval) {
                model.updatePreferences { $0.refreshInterval = interval }
            }
        case let .invoke(id):
            if id == ControlID.refresh { model.refresh(manual: true) }
            else if let provider = AIUsageProvider.allCases.first(where: { ControlID.web($0) == id }) {
                NSWorkspace.shared.open(provider.dashboardURL)
            }
        default: break
        }
    }
}

struct AIUsageServiceSettingsView: View {
    @ObservedObject var model: AIUsageViewModel
    let strings: AIUsageStrings
    let assets: AIUsageProviderAssets

    var body: some View {
        VStack(spacing: 0) {
            ForEach(AIUsageProvider.allCases) { provider in
                if provider != AIUsageProvider.allCases.first { Divider() }
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Image(nsImage: assets.image(for: provider)).resizable().scaledToFit()
                        .frame(width: 22, height: 22).accessibilityHidden(true)
                    PluginSettingsItem(title: provider.title) {
                        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                            Button(strings.text("provider.open", "打开网页")) { NSWorkspace.shared.open(provider.dashboardURL) }
                                .buttonStyle(.bordered).controlSize(.small)
                            Toggle(provider.title, isOn: Binding(
                                get: { model.preferences.enabledProviders.contains(provider) },
                                set: { enabled in
                                    model.updatePreferences {
                                        if provider == .codex { $0.codexEnabled = enabled } else { $0.claudeEnabled = enabled }
                                    }
                                }
                            ))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .help(strings.text("provider.show", "在仪表盘和菜单栏显示"))
                        }
                        .fixedSize()
                    }
                }
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
            }
        }
    }
}
