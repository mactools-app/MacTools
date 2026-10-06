import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

@MainActor
protocol AppHotkeyApplicationLaunching: AnyObject {
    func launch(_ bundleURL: URL) async throws
}

@MainActor
final class SystemAppHotkeyApplicationLauncher: AppHotkeyApplicationLaunching {
    private let bundleIdentifier: (URL) -> String?
    private let frontmostBundleIdentifier: () -> String?
    private let hideFrontmost: () -> Bool
    private let openApplication: (URL) async throws -> Void

    init(
        bundleIdentifier: @escaping (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier },
        frontmostBundleIdentifier: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        hideFrontmost: @escaping () -> Bool = {
            NSWorkspace.shared.frontmostApplication?.hide() ?? false
        },
        openApplication: ((URL) async throws -> Void)? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.hideFrontmost = hideFrontmost
        self.openApplication = openApplication ?? { url in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    func launch(_ bundleURL: URL) async throws {
        if let target = bundleIdentifier(bundleURL),
           target == frontmostBundleIdentifier() {
            guard hideFrontmost() else {
                throw NSError(domain: "AppHotkeyPlugin", code: 2)
            }
            return
        }

        try await openApplication(bundleURL)
    }
}

// MARK: - Bundle Factory

public final class AppHotkeyPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AppHotkeyPluginProvider(context: context)
    }
}

@MainActor
private struct AppHotkeyPluginProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] {
        [AppHotkeyPlugin(context: context)]
    }
}

// MARK: - Plugin

@MainActor
final class AppHotkeyPlugin:
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
                control: .toggle,
                state: state,
                menuActionBehavior: descriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }


    // MARK: Metadata

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "app-hotkey",
            title: localization.string("metadata.title", defaultValue: "应用快捷键"),
            iconName: "keyboard",
            iconTint: Color(nsColor: .systemYellow),
            order: 65,
            defaultDescription: localization.string("metadata.description", defaultValue: "为常用应用绑定全局快捷键")
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    // MARK: Callbacks

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    // MARK: Private

    private let store: AppHotkeyStore
    private let storage: PluginStorage
    private let localization: PluginLocalization
    private let applicationLauncher: any AppHotkeyApplicationLaunching
    private var isEnabled: Bool

    // MARK: Init

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "app-hotkey"),
        applicationLauncher: (any AppHotkeyApplicationLaunching)? = nil
    ) {
        self.localization = PluginLocalization(bundle: context.resourceBundle)
        self.storage = context.storage
        self.store = AppHotkeyStore(storage: context.storage)
        self.applicationLauncher = applicationLauncher ?? SystemAppHotkeyApplicationLauncher()
        // Enabled by default; only an explicit user pause stores `false`.
        self.isEnabled = context.storage.object(forKey: "isEnabled") == nil
            ? true
            : context.storage.bool(forKey: "isEnabled")
    }

    // MARK: MacToolsPlugin

    func activate(context: PluginRuntimeContext) {}

    func deactivate(reason: PluginDeactivationReason) {}

    func refresh() {}

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    // App-launch actions use the host action shortcut service. Specialized plugin shortcuts
    // remain available through `shortcutDefinitions` in other plugins.
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(
                id: "hotkey-manager",
                title: localization.string("settings.section.bindings", defaultValue: "应用绑定"),
                systemImage: "keyboard",
                presentation: .edgeToEdge
            ) { [self] _ in
                AppHotkeyManagerView(
                    store: self.store,
                    localization: self.localization,
                    onUpdate: { [weak self] in
                        self?.onStateChange?()
                    }
                )
            }
            .headerAccessory { [self] _ in
                Button {
                    AppHotkeyManagerView.addApp(
                        store: self.store,
                        localization: self.localization,
                        onUpdate: { [weak self] in
                            self?.onStateChange?()
                        }
                    )
                } label: {
                    Label(
                        localization.string("settings.add", defaultValue: "添加"),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        ])
    }

    // MARK: - Panel row

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: isEnabled,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setSwitch(value):
            isEnabled = value
            storage.set(value, forKey: "isEnabled")
            onStateChange?()
        default:
            break
        }
    }

    // MARK: Private

    private var panelSubtitle: String {
        let count = store.entries.count
        guard count > 0 else {
            return localization.string("panel.subtitle.empty", defaultValue: "暂无绑定，前往设置配置")
        }
        return isEnabled
            ? localization.format("panel.subtitle.enabledCountFormat", defaultValue: "已配置 %d 个应用", count)
            : localization.string("panel.subtitle.paused", defaultValue: "快捷键已暂停")
    }

    // MARK: Actions

    private var launchDefinition: ActionDefinition {
        ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: "launch"),
            title: localization.string("action.launch.title", defaultValue: "打开应用"),
            description: localization.string(
                "action.launch.description",
                defaultValue: "打开应用；若应用位于最前方则隐藏。"
            ),
            keywords: [
                localization.string("metadata.title", defaultValue: "应用快捷键"),
                localization.string("action.launch.title", defaultValue: "打开应用"),
            ],
            systemImage: "app.dashed",
            parameters: [
                ActionParameterDefinition(
                    id: "entryID",
                    title: localization.string("action.launch.app", defaultValue: "应用"),
                    kind: .string,
                    portability: .localOnly
                ),
            ],
            externalInvocationPolicy: .allowed,
            capabilities: [.automatic, .background, .foregroundInteractive]
        )
    }

    var actionDefinitions: [ActionDefinition] {
        [launchDefinition]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        store.entries.compactMap { entry in
            guard let parameters = try? ActionParameterSet([
                "entryID": .string(entry.id.uuidString.lowercased()),
            ]) else {
                return nil
            }
            return ActionCatalogEntry(
                reference: ActionReference(
                    key: launchDefinition.key,
                    parameters: parameters
                ),
                title: entry.displayName,
                subtitle: localization.string("metadata.title", defaultValue: "应用快捷键")
            )
        }
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard isEnabled else {
            return .unavailable(
                localization.string("action.unavailable.paused", defaultValue: "应用快捷键已暂停。")
            )
        }
        guard let entry = entry(for: reference), entry.bundleURL != nil else {
            return .unavailable(
                localization.string("action.unavailable.missing", defaultValue: "应用不可用。")
            )
        }
        return .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard actionAvailability(for: invocation.reference).isAvailable,
              let entry = entry(for: invocation.reference),
              let bundleURL = entry.bundleURL else {
            let failureMessage = localization.string(
                "action.unavailable.missing",
                defaultValue: "应用不可用。"
            )
            return ActionExecutionHandle(operation: {
                .failed(message: failureMessage)
            })
        }
        return ActionExecutionHandle { [applicationLauncher] in
            do {
                try await applicationLauncher.launch(bundleURL)
                return .succeeded()
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(message: error.localizedDescription)
            }
        }
    }

    var legacyActionShortcutAssignments: [LegacyActionShortcutAssignment] {
        actionCatalogEntries.compactMap { entry in
            guard let appEntry = self.entry(for: entry.reference),
                  let binding = appEntry.shortcut else {
                return nil
            }
            return LegacyActionShortcutAssignment(
                reference: entry.reference,
                binding: binding
            )
        }
    }

    func legacyActionShortcutsDidMigrate() {
        store.clearAllShortcuts()
        onStateChange?()
    }

    private func entry(for reference: ActionReference) -> AppShortcutEntry? {
        guard reference.key == launchDefinition.key,
              case let .string(rawID)? = reference.parameters["entryID"],
              let id = UUID(uuidString: rawID) else {
            return nil
        }
        return store.entries.first { $0.id == id }
    }

}
