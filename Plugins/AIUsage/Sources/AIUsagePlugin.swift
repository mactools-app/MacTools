import AppKit
import Combine
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

/// Shows the AI page ported from Vorssaint: plan limits, API value, trend,
/// models, projects, activity and Codex resets of the coding agents on this
/// Mac, read from their local logs.
///
/// Reading runs while the page is on screen. Out of sight the service is
/// paused: no timer, poller or file watcher runs, and the next look reads
/// only what the agents wrote meanwhile.
@MainActor
final class AIUsagePlugin: MacToolsPlugin, PluginSettingsPresenting {
    private enum ID {
        static let widget = "widget"
    }

    let localization: PluginLocalization
    private let service = AgentUsageService.shared
    private var active = false
    private var visible = false
    private var observation: AnyCancellable?
    /// The widget height last handed to the host, in grid rows.
    private var heightRows = 0
    /// Tells the host when a portable choice changed, from Settings or from the page itself (both
    /// write their own defaults), so automatic backup and sync pick it up.
    let preferencesChange = PluginPersistentPreferencesChangeEmitter()
    private var portableSnapshot: AIUsagePreferencesBackup
    private var defaultsObservation: AnyCancellable?

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    init(context: PluginRuntimeContext) {
        localization = PluginLocalization(bundle: context.resourceBundle)
        AgentPluginEnvironment.resourceBundle = context.resourceBundle
        AgentPluginEnvironment.cacheDirectory = context.cacheDirectory
        AgentPluginEnvironment.supportDirectory = context.supportDirectory
        // Before anything reads the providers: the earlier plugin's choices carry over once.
        let migrated = AIUsagePreferencesBackup.migrateLegacyPreferences(from: context.storage)
        portableSnapshot = AIUsagePreferencesBackup.current()
        if migrated { preferencesChange.didPersist() }
        defaultsObservation = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.portableDefaultsMayHaveChanged() }
    }

    private func portableDefaultsMayHaveChanged() {
        let current = AIUsagePreferencesBackup.current()
        guard current != portableSnapshot else { return }
        portableSnapshot = current
        preferencesChange.didPersist()
    }

    var metadata: PluginMetadata {
        PluginMetadata(id: "ai-usage", title: localization.string("metadata.title", defaultValue: "AI 用量"),
                       iconName: "gauge.with.dots.needle.33percent", iconTint: .blue, order: 23,
                       defaultDescription: localization.string(
                           "metadata.description",
                           defaultValue: "查看 Claude、Codex、OpenCode 和 GitHub Copilot 的额度、用量与趋势"))
    }

    var panelItems: [PluginPanelItem] {
        [
            .widget(id: ID.widget, initialPlacement: .dashboard,
                    descriptor: descriptor, state: widgetState,
                    content: { [weak self] context in
                        guard let self else { return AnyView(EmptyView()) }
                        return self.makeView(context: context)
                    })
                .onVisibilityChange { [weak self] visible in self?.pageVisibilityChanged(visible) },
        ]
    }

    private var descriptor: PluginPanelWidgetDescriptor {
        PluginPanelWidgetDescriptor(span: PluginPanelWidgetSpan(width: PluginPanelWidgetSpan.maximumWidth,
                                                                height: max(1, currentHeightRows))!)
    }

    private var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(subtitle: metadata.defaultDescription,
                               isActive: !service.snapshot.seen.isEmpty,
                               isEnabled: true, isAvailable: true, errorMessage: nil)
    }

    private static var pageWidth: CGFloat {
        PluginPanelWidgetLayoutMetrics.default.itemWidth(forSpanWidth: PluginPanelWidgetSpan.maximumWidth)
    }

    private var currentHeightRows: Int {
        let height = NotchAgentsLayout.height(snapshot: service.snapshot, claudeProfile: service.claudeProfile,
                                              width: Self.pageWidth)
        return PluginPanelWidgetLayoutMetrics.default.heightSpan(fittingContentHeight: height)
    }

    private func makeView(context: PluginPanelWidgetContext) -> AnyView {
        AnyView(
            GeometryReader { proxy in
                NotchAgentsView(size: proxy.size)
            }
            .environment(\.agentOpenSettings) { [weak self] in
                context.dismiss()
                self?.requestSettingsPresentation?()
            }
        )
    }

    func activate(context: PluginRuntimeContext) {
        active = true
        AgentPluginEnvironment.active = true
        heightRows = currentHeightRows
        // The page's height follows the cards it shows; anything else in a
        // new snapshot redraws the page through its own observation.
        observation = service.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.snapshotChanged() }
        // The first read takes the history of the last thirteen weeks, once;
        // later launches resume from the saved progress.
        service.syncWithPreferences()
        if !visible { service.pause() }
    }

    func deactivate(reason: PluginDeactivationReason) {
        active = false
        visible = false
        observation = nil
        // Quitting and updating keep the saved progress, so the next launch
        // reads only what the agents wrote meanwhile instead of thirteen
        // weeks of logs. Disabling or removing the plugin removes it. The
        // service is stopped while still marked active: it keeps progress
        // only for an active plugin.
        service.stop(keepingProgress: reason == .hostShutdown || reason == .updating, quitting: reason == .hostShutdown)
        AgentPluginEnvironment.active = false
    }

    func refresh() {}

    func handleSettingsAction(_ action: PluginSettingsAction) {}

    /// A preference changed in Settings: the service reads the agents chosen
    /// now, and the widget takes the height of the cards shown now.
    func preferencesChanged() {
        guard active else { return }
        service.syncWithPreferences()
        if !visible { service.pause() }
        snapshotChanged()
    }

    private func pageVisibilityChanged(_ shown: Bool) {
        guard active, shown != visible else { return }
        visible = shown
        if shown {
            service.syncWithPreferences()
            service.pageDidAppear()
        } else {
            service.pageDidDisappear()
            service.pause()
        }
    }

    private func snapshotChanged() {
        let rows = currentHeightRows
        guard rows != heightRows else { return }
        heightRows = rows
        onStateChange?()
    }
}
