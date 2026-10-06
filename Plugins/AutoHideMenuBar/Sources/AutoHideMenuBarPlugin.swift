import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class AutoHideMenuBarPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AutoHideMenuBarPluginProvider(context: context)
    }
}

@MainActor
private struct AutoHideMenuBarPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [AutoHideMenuBarPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class AutoHideMenuBarPlugin: MacToolsPlugin, PluginActionProviding, PluginActionPermissionProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("action.hide.title", defaultValue: "隐藏菜单栏"),
                systemImage: metadata.iconName,
                control: .toggle,
                state: state,
                menuActionBehavior: rowDescriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    private enum ActionID {
        static let setEnabled = "set-enabled"
        static let setMode = "set-mode"
        static let toggle = "toggle"
    }
    private enum PermissionID {
        static let automation = "automation"
    }
    var metadata: PluginMetadata {
        PluginMetadata(
            id: "auto-hide-menu-bar",
            title: localization.string("metadata.title", defaultValue: "自动隐藏菜单栏"),
            iconName: "menubar.rectangle",
            iconTint: Color(nsColor: .systemIndigo),
            order: 42,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "自动隐藏菜单栏，提供更完整的屏幕显示空间"
            )
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "AutoHideMenuBarPlugin")
    private let controller: any MenuBarAutoHideControlling
    private let localization: PluginLocalization

    private var mode: MenuBarAutoHideMode
    private var lastErrorMessage: String?

    init(
        controller: (any MenuBarAutoHideControlling)? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.controller = controller ?? MenuBarAutoHideController(localization: localization)
        self.mode = (try? self.controller.read()) ?? .never
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: modeTitle(mode),
            isOn: mode.hidesAnywhere,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.automation,
                kind: .automation,
                title: localization.string("permission.automation.title", defaultValue: "自动化"),
                description: localization.string(
                    "permission.automation.description",
                    defaultValue: "切换菜单栏自动隐藏时需要控制系统事件。"
                )
            ),
        ]
    }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: localization.string("metadata.title", defaultValue: "自动隐藏菜单栏"),
                description: localization.string("metadata.description", defaultValue: "自动隐藏菜单栏，提供更完整的屏幕显示空间"),
                keywords: [
                    localization.string("metadata.title", defaultValue: "自动隐藏菜单栏"),
                    localization.string("metadata.description", defaultValue: "自动隐藏菜单栏，提供更完整的屏幕显示空间"),
                ],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: localization.string("metadata.title", defaultValue: "自动隐藏菜单栏"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "自动隐藏菜单栏，提供更完整的屏幕显示空间"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "自动隐藏菜单栏"),
                    localization.string("metadata.description", defaultValue: "自动隐藏菜单栏，提供更完整的屏幕显示空间"),
                ],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: "enabled",
                        title: localization.string("metadata.title", defaultValue: "自动隐藏菜单栏"),
                        kind: .boolean
                    ),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setMode),
                title: localization.string("action.setMode.title", defaultValue: "Set Menu Bar Visibility"),
                description: localization.string(
                    "action.setMode.description",
                    defaultValue: "Choose when macOS automatically hides the menu bar."
                ),
                keywords: ["menu bar", "always", "desktop", "full screen", "never", "菜单栏"],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: "mode",
                        title: localization.string("parameter.mode.title", defaultValue: "Visibility"),
                        kind: .string
                    ),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        [
            ActionCatalogEntry(
                reference: toggleActionReference,
                title: mode.hidesAnywhere
                    ? localization.string("action.show.title", defaultValue: "显示菜单栏")
                    : localization.string("action.hide.title", defaultValue: "隐藏菜单栏"),
                subtitle: modeTitle(mode),
                presentationState: mode.hidesAnywhere ? .active : .inactive
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: localization.string("action.hide.title", defaultValue: "隐藏菜单栏")
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: localization.string("action.show.title", defaultValue: "显示菜单栏")
            ),
        ] + MenuBarAutoHideMode.allCases.map { candidate in
            ActionCatalogEntry(
                reference: modeReference(candidate),
                title: modeTitle(candidate),
                presentationState: mode == candidate ? .active : .inactive
            )
        }
    }

    func refresh() {
        guard let latestMode = try? controller.read() else { return }
        if latestMode != mode {
            mode = latestMode
            onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }

        setMode(isEnabled ? .always : .never)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(
            isGranted: false,
            footnote: permissionID == PermissionID.automation
                ? localization.string(
                    "permission.automation.footnote",
                    defaultValue: "macOS 会在首次使用时请求自动化授权。"
                )
                : nil,
            statusText: permissionID == PermissionID.automation
                ? localization.string("permission.automation.status", defaultValue: "按需确认")
                : nil,
            statusSystemImage: permissionID == PermissionID.automation ? "cursorarrow.click.2" : nil,
            statusTone: permissionID == PermissionID.automation ? .neutral : nil
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.automation else { return }
        requestPermissionGuidance?(PermissionID.automation)
    }
    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        guard actionKey.providerID == metadata.id else { return [] }
        return [PermissionID.automation]
    }
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let requestedMode: MenuBarAutoHideMode
        switch invocation.reference.key.actionID {
        case ActionID.toggle:
            requestedMode = ((try? controller.read()) ?? mode).hidesAnywhere ? .never : .always
        case ActionID.setEnabled:
            guard case let .boolean(value)? = invocation.reference.parameters["enabled"] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            requestedMode = value ? .always : .never
        case ActionID.setMode:
            guard case let .string(rawMode)? = invocation.reference.parameters["mode"],
                  let parsedMode = MenuBarAutoHideMode(rawValue: rawMode) else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            requestedMode = parsedMode
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        let succeeded = setMode(requestedMode)
        let failureMessage = localization.string(
            "error.toggleFailed",
            defaultValue: "切换菜单栏自动隐藏失败"
        )
        return ActionExecutionHandle {
            succeeded
                ? .succeeded()
                : .failed(message: failureMessage)
        }
    }

    private func actionReference(enabled: Bool) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
            parameters: try! ActionParameterSet(["enabled": .boolean(enabled)])
        )
    }

    private var toggleActionReference: ActionReference {
        ActionReference(key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle))
    }

    private func modeReference(_ mode: MenuBarAutoHideMode) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setMode),
            parameters: try! ActionParameterSet(["mode": .string(mode.rawValue)])
        )
    }

    private func modeTitle(_ mode: MenuBarAutoHideMode) -> String {
        switch mode {
        case .always: localization.string("mode.always", defaultValue: "Always")
        case .desktopOnly: localization.string("mode.desktopOnly", defaultValue: "On Desktop Only")
        case .fullScreenOnly: localization.string("mode.fullScreenOnly", defaultValue: "In Full Screen Only")
        case .never: localization.string("mode.never", defaultValue: "Never")
        }
    }

    @discardableResult
    private func setMode(_ requestedMode: MenuBarAutoHideMode) -> Bool {
        do {
            try controller.setMode(requestedMode)
            mode = try controller.read()
            guard mode == requestedMode else { throw MenuBarAutoHideError.updateFailed(restored: false) }
            lastErrorMessage = nil
            onStateChange?()
            return true
        } catch {
            logger.error("Failed to update menu bar auto-hide: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            refresh()
            onStateChange?()
            return false
        }
    }

}
