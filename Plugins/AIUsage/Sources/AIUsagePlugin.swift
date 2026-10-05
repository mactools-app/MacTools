import AppKit
import MacToolsPluginKit
import SwiftUI

public final class AIUsagePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AIUsagePluginProvider(context: context)
    }
}

@MainActor
private struct AIUsagePluginProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] {
        [AIUsagePlugin(context: context)]
    }
}

@MainActor
final class AIUsagePlugin: MacToolsPlugin, PluginSettingsPresenting, PluginDashboardPresenting, PluginApplicationActivityStateHandling, PluginRuntimeLocalizationRefreshing {
    var panelItems: [PluginPanelItem] {
        return [
            .widget(id: "widget", initialPlacement: .dashboard,
                    descriptor: descriptor, state: widgetState,
                    content: { [weak self] context in
                        self?.makeView(context: context) ?? AnyView(EmptyView())
                    })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("widget") }
                    else { self?.panelItemDidBecomeHidden("widget") }
                },
        ]
    }

    enum ControlID {
        static let access = "credential-access"
        static let keychain = "authorize-claude-keychain"
        static let menuBar = "menu-bar"
        static let interval = "refresh-interval"
        static let refresh = "refresh"
        static func provider(_ provider: AIUsageProvider) -> String { "enable-\(provider.rawValue)" }
        static func web(_ provider: AIUsageProvider) -> String { "web-\(provider.rawValue)" }
    }

    let model: AIUsageViewModel
    let strings: AIUsageStrings
    let assets: AIUsageProviderAssets
    private let menuBar = AIUsageMenuBarController()
    private var active = false
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?
    var requestDashboardPresentation: (() -> Void)?

    init(context: PluginRuntimeContext, model: AIUsageViewModel? = nil) {
        self.model = model ?? AIUsageViewModel(storage: context.storage)
        assets = AIUsageProviderAssets(bundle: context.resourceBundle)
        strings = AIUsageStrings(localization: PluginLocalization(bundle: context.resourceBundle))
        self.model.onChange = { [weak self] in
            self?.updateMenuBar()
            self?.onStateChange?()
        }
        self.model.onPresentationTick = { [weak self] in self?.updateMenuBar() }
        menuBar.openDashboard = { [weak self] in self?.requestDashboardPresentation?() }
        menuBar.openSettings = { [weak self] in self?.requestSettingsPresentation?() }
    }

    var metadata: PluginMetadata {
        PluginMetadata(id: "ai-usage", title: strings.text("metadata.title", "AI 用量"),
                       iconName: "gauge.with.dots.needle.33percent", iconTint: .blue, order: 23,
                       defaultDescription: strings.text("metadata.description", "查看 Codex 与 Claude Code 订阅额度和重置时间"))
    }

    var descriptor: PluginPanelWidgetDescriptor {
        let providers = model.preferences.enabledProviders
        let height: Int
        if providers.isEmpty {
            height = 16
        } else {
            let content = providers.reduce(0) { total, provider in
                total + (model.states[provider]?.snapshot.map { 94 + max(0, $0.windows.count - 1) * 45 + (model.states[provider]?.failure == nil ? 0 : 32) } ?? 84)
            }
            height = Int(ceil(Double(28 + content + max(0, providers.count - 1) * 25) / 8))
        }
        return PluginPanelWidgetDescriptor(span: PluginPanelWidgetSpan(width: 4, height: height)!)
    }

    var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(subtitle: metadata.defaultDescription,
                             isActive: model.states.values.contains { $0.snapshot != nil },
                             isEnabled: true, isAvailable: true, errorMessage: nil)
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
        AnyView(AIUsageComponentView(model: model, strings: strings, assets: assets) { [weak self] in
            context.dismiss()
            self?.requestSettingsPresentation?()
        })
    }

    func activate(context: PluginRuntimeContext) { active = true; model.start(); updateMenuBar() }
    func deactivate(reason: PluginDeactivationReason) { active = false; model.stop(); menuBar.remove() }
    func refresh() { model.refresh(); updateMenuBar() }
    func refreshLocalization() { updateMenuBar() }
    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) { model.setActivity(state) }
    func panelItemDidBecomeVisible(_ surface: String) {
        if surface == "widget" { model.panelVisible = true }
        model.refresh()
    }
    func panelItemDidBecomeHidden(_ surface: String) {
        if surface == "widget" { model.panelVisible = false }
    }

    func updateMenuBar() {
        let preferences = model.preferences
        guard active, preferences.showsMenuBar, !preferences.enabledProviders.isEmpty else {
            menuBar.remove(); return
        }
        menuBar.update(.make(providers: preferences.enabledProviders, states: model.states,
                             interval: Double(preferences.refreshInterval), now: Date(), strings: strings), assets: assets)
    }
}
