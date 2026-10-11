import Combine
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class LaunchpadPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        LaunchpadPluginProvider(context: context)
    }
}

private struct LaunchpadPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            LaunchpadPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class LaunchpadPlugin:
    MacToolsPlugin, PluginActionProviding, PluginLegacyActionShortcutProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        let descriptor = rowDescriptor
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: descriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("metadata.title", defaultValue: metadata.title),
                systemImage: metadata.iconName,
                control: .button,
                state: state,
                menuActionBehavior: descriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    private enum ControlID {
        static let execute = "execute"
    }
    private enum ActionID {
        static let toggle = "toggleLaunchpad"
    }
    private enum ShortcutID {
        static let toggle = "launchpad.toggle"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "launchpad",
            title: localization.string("metadata.title", defaultValue: "启动台"),
            iconName: "square.grid.3x3.fill",
            iconTint: Color(nsColor: .systemBlue),
            order: 12,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "唤出应用网格，搜索并启动"
            )
        )
    }

    let rowDescriptor: PluginPanelRowDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "LaunchpadPlugin"
    )

    private let preferences: LaunchpadPreferences
    private let layoutStore: LaunchpadLayoutStore
    private let overlay: LaunchpadOverlayController
    private let localization: PluginLocalization
    private let hotCornerMonitor = LaunchpadHotCornerMonitor()
    private var cancellables = Set<AnyCancellable>()

    init(
        context: PluginRuntimeContext,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: { localization.string("panel.button.open", defaultValue: "打开") }
        )
        let preferences = LaunchpadPreferences(storage: context.storage)
        // Same scoped storage as preferences; owned here so the layout (and its @Published
        // changes) outlives individual overlay sessions and drives grid re-renders.
        let layoutStore = LaunchpadLayoutStore(storage: context.storage)
        self.preferences = preferences
        self.layoutStore = layoutStore
        self.overlay = LaunchpadOverlayController(
            preferences: preferences,
            layoutStore: layoutStore,
            localization: localization
        )

        hotCornerMonitor.onTrigger = { [weak self] in self?.openLaunchpad() }
        // Apply the saved corner now and whenever the user changes it in settings.
        preferences.$hotCorner
            .sink { [weak hotCornerMonitor] corner in hotCornerMonitor?.update(corner: corner) }
            .store(in: &cancellables)
        layoutStore.$layout
            .dropFirst()
            .sink { [weak self] _ in self?.onStateChange?() }
            .store(in: &cancellables)
        preferences.$hiddenAppIDs
            .dropFirst()
            .sink { [weak self] _ in self?.onStateChange?() }
            .store(in: &cancellables)
    }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(
                id: "window",
                title: localization.string("settings.window.title", defaultValue: "窗口"),
                systemImage: "macwindow",
                presentation: .edgeToEdge
            ) { [preferences, layoutStore, localization] _ in
                LaunchpadSettingsView(
                    preferences: preferences,
                    layoutStore: layoutStore,
                    localization: localization,
                    sectionKind: .window
                )
            },
            PluginSettingsSection(
                id: "appearance",
                title: localization.string("settings.appearance.title", defaultValue: "外观"),
                systemImage: "paintbrush",
                presentation: .edgeToEdge
            ) { [preferences, layoutStore, localization] _ in
                LaunchpadSettingsView(
                    preferences: preferences,
                    layoutStore: layoutStore,
                    localization: localization,
                    sectionKind: .appearance
                )
            },
            PluginSettingsSection(
                id: "background",
                title: localization.string("settings.background.title", defaultValue: "背景"),
                systemImage: "circle.lefthalf.filled",
                presentation: .edgeToEdge
            ) { [preferences, layoutStore, localization] _ in
                LaunchpadSettingsView(
                    preferences: preferences,
                    layoutStore: layoutStore,
                    localization: localization,
                    sectionKind: .background
                )
            },
            PluginSettingsSection(
                id: "grid",
                title: localization.string("settings.grid.title", defaultValue: "网格"),
                systemImage: "square.grid.3x3",
                presentation: .edgeToEdge
            ) { [preferences, layoutStore, localization] _ in
                LaunchpadSettingsView(
                    preferences: preferences,
                    layoutStore: layoutStore,
                    localization: localization,
                    sectionKind: .grid
                )
            },
            PluginSettingsSection(
                id: "sorting",
                title: localization.string("settings.sorting.title", defaultValue: "排序"),
                systemImage: "arrow.up.arrow.down",
                presentation: .edgeToEdge,
                isVisible: layoutStore.layout != nil
            ) { [preferences, layoutStore, localization] _ in
                LaunchpadSettingsView(
                    preferences: preferences,
                    layoutStore: layoutStore,
                    localization: localization,
                    sectionKind: .sorting
                )
            },
            PluginSettingsSection(
                id: "hidden-apps",
                title: localization.string("settings.hiddenApps.title", defaultValue: "隐藏的应用"),
                systemImage: "eye.slash",
                presentation: .edgeToEdge,
                isVisible: !preferences.hiddenAppIDs.isEmpty
            ) { [preferences, layoutStore, localization] _ in
                LaunchpadSettingsView(
                    preferences: preferences,
                    layoutStore: layoutStore,
                    localization: localization,
                    sectionKind: .hiddenApps
                )
            }
        ])
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

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: ShortcutID.toggle,
                title: localization.string("shortcut.toggle.title", defaultValue: "打开启动台"),
                description: localization.string(
                    "shortcut.toggle.description",
                    defaultValue: "全局快捷键唤出或收起应用网格。默认未设置，可在此自定义。"
                ),
                actionID: ActionID.toggle,
                scope: .global,
                defaultBinding: nil,        // v1: do not claim system or user hotkeys by default.
                isRequired: false
            )
        ]
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .invokeAction(controlID) = action, controlID == ControlID.execute else {
            return
        }
        openLaunchpad()
    }

    func handleShortcutAction(id: String) {
        guard id == ActionID.toggle else { return }
        openLaunchpad()
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: localization.string("shortcut.toggle.title", defaultValue: "打开启动台"),
                description: localization.string(
                    "shortcut.toggle.description",
                    defaultValue: "全局快捷键唤出或收起应用网格。默认未设置，可在此自定义。"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "启动台"),
                    localization.string("shortcut.toggle.title", defaultValue: "打开启动台"),
                    "Launchpad",
                ],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.foregroundInteractive]
            ),
        ]
    }

    var legacyActionShortcutAssignments: [LegacyActionShortcutAssignment] {
        guard let binding = shortcutBindingResolver?(ShortcutID.toggle) else {
            return []
        }
        return [
            LegacyActionShortcutAssignment(
                reference: ActionReference(
                    key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle)
                ),
                binding: binding,
                legacyShortcutDefinitionID: ShortcutID.toggle
            ),
        ]
    }

    func legacyActionShortcutsDidMigrate() {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        openLaunchpad()
        return ActionExecutionHandle { .succeeded() }
    }

    private func openLaunchpad() {
        overlay.toggle()
    }

    func activate(context: PluginRuntimeContext) {
        // Resume after a pause, such as re-enabling the plugin after hiding or disabling it:
        // `deactivate` stopped the cursor poll but
        // the corner preference kept its value, so the `$hotCorner` sink (fires on CHANGE) never
        // re-arms it — re-apply explicitly here.
        hotCornerMonitor.update(corner: preferences.hotCorner)
        // Warm the app catalog in the background now, so the first summon shows
        // icons at once instead of waiting for the disk scan on the hot path.
        overlay.prewarm()
    }

    func deactivate(reason: PluginDeactivationReason) {
        if reason.requiresStateCleanup {
            hotCornerMonitor.stop()      // stop the cursor poll; no runaway timer
            overlay.close()
        }
    }
}
