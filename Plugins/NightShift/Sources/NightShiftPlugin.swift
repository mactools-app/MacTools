import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class NightShiftPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        NightShiftPluginProvider(context: context)
    }
}

@MainActor
private struct NightShiftPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [NightShiftPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class NightShiftPlugin: MacToolsPlugin, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("metadata.title", defaultValue: metadata.title),
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
        static let toggle = "toggle"
    }

    private enum ErrorState {
        case toggleFailed
    }
    var metadata: PluginMetadata {
        PluginMetadata(
            id: "night-shift",
            title: localization.string("metadata.title", defaultValue: "夜览"),
            iconName: "lamp.floor",
            iconTint: Color(nsColor: .systemOrange),
            order: 35,
            defaultDescription: localization.string("metadata.description", defaultValue: "降低蓝光，使屏幕颜色更暖")
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "NightShiftPlugin")
    private let localization: PluginLocalization
    private let controller: any NightShiftControlling
    private var isEnabled: Bool
    private var lastErrorState: ErrorState?

    private var lastErrorMessage: String? {
        switch lastErrorState {
        case .toggleFailed:
            localization.string("error.toggleFailed", defaultValue: "切换夜览失败")
        case nil:
            nil
        }
    }

    init(
        controller: any NightShiftControlling = CBNightShiftController(),
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.controller = controller
        self.isEnabled = controller.getStatus()
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: isEnabled
                ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
            isOn: isEnabled,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: localization.string("metadata.title", defaultValue: "夜览"),
                description: localization.string("metadata.description", defaultValue: "降低蓝光，使屏幕颜色更暖"),
                keywords: [
                    localization.string("metadata.title", defaultValue: "夜览"),
                    localization.string("metadata.description", defaultValue: "降低蓝光，使屏幕颜色更暖"),
                ],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: localization.string("metadata.title", defaultValue: "夜览"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "降低蓝光，使屏幕颜色更暖"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "夜览"),
                    localization.string("metadata.description", defaultValue: "降低蓝光，使屏幕颜色更暖"),
                ],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: "enabled",
                        title: localization.string("metadata.title", defaultValue: "夜览"),
                        kind: .boolean
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
                title: isEnabled
                    ? localization.string("action.disable.title", defaultValue: "停用夜览")
                    : localization.string("action.enable.title", defaultValue: "启用夜览"),
                subtitle: isEnabled
                    ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                    : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
                presentationState: isEnabled ? .active : .inactive
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: localization.string("action.enable.title", defaultValue: "启用夜览")
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: localization.string("action.disable.title", defaultValue: "停用夜览")
            ),
        ]
    }

    func refresh() {
        let current = controller.getStatus()
        if current != isEnabled {
            isEnabled = current
            onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(enable) = action else { return }
        setNightShift(enable)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let enabled: Bool
        switch invocation.reference.key.actionID {
        case ActionID.toggle:
            enabled = !controller.getStatus()
        case ActionID.setEnabled:
            guard case let .boolean(value)? = invocation.reference.parameters["enabled"] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            enabled = value
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        let succeeded = setNightShift(enabled)
        let message = lastErrorMessage
        let failureMessage = message
            ?? localization.string("error.toggleFailed", defaultValue: "切换夜览失败")
        return ActionExecutionHandle {
            succeeded
                ? .succeeded()
                : .failed(message: failureMessage)
        }
    }

    // MARK: - Private

    private func actionReference(enabled: Bool) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
            parameters: try! ActionParameterSet(["enabled": .boolean(enabled)])
        )
    }

    private var toggleActionReference: ActionReference {
        ActionReference(key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle))
    }

    @discardableResult
    private func setNightShift(_ enable: Bool) -> Bool {
        let success = controller.setEnabled(enable)
        if success {
            isEnabled = enable
            lastErrorState = nil
            onStateChange?()
        } else {
            logger.error("Failed to \(enable ? "enable" : "disable", privacy: .public) Night Shift")
            lastErrorState = .toggleFailed
            onStateChange?()
        }
        return success
    }
}
