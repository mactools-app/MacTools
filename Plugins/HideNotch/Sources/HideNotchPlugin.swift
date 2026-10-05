import Foundation
import SwiftUI
import MacToolsPluginKit

public final class HideNotchPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        HideNotchPluginProvider(context: context)
    }
}

@MainActor
private struct HideNotchPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [HideNotchPlugin(context: context)]
    }
}

@MainActor
final class HideNotchPlugin: MacToolsPlugin, PluginActionProviding {
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

    private enum ActionID {
        static let setEnabled = "set-enabled"
        static let toggle = "toggle"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "hide-notch",
            title: localization.string("metadata.title", defaultValue: "隐藏刘海"),
            iconName: "rectangle.topthird.inset.filled",
            iconTint: Color(nsColor: .labelColor),
            order: 40,
            defaultDescription: localization.string("metadata.description", defaultValue: "自动遮挡刘海屏顶部区域")
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let controller: HideNotchWallpaperControlling
    private let localization: PluginLocalization

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "hide-notch"),
        controller: HideNotchWallpaperControlling? = nil,
        localization: PluginLocalization? = nil
    ) {
        let localization = localization ?? PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        self.controller = controller ?? HideNotchController(
            maskManager: HideNotchDesktopMaskManager(localization: localization),
            context: context,
            localization: localization
        )
        self.controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    var rowState: PluginPanelRowState {
        let snapshot = controller.snapshot()

        if !snapshot.hasSupportedDisplay {
            let subtitle = snapshot.isEnabled
                ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                : localization.string("panel.subtitle.noSupportedDisplay", defaultValue: "未检测到刘海屏")

            return PluginPanelRowState(
                subtitle: subtitle,
                isOn: snapshot.isEnabled,
                isEnabled: false,
                isAvailable: true,
                detail: nil,
                errorMessage: snapshot.errorMessage
            )
        }

        let subtitle: String
        if snapshot.isEnabled {
            subtitle = localization.string("panel.subtitle.enabled", defaultValue: "已开启")
        } else if snapshot.isProcessing {
            subtitle = localization.string("panel.subtitle.closing", defaultValue: "正在关闭")
        } else {
            subtitle = metadata.defaultDescription
        }

        return PluginPanelRowState(
            subtitle: subtitle,
            isOn: snapshot.isEnabled,
            isEnabled: !snapshot.isProcessing,
            isAvailable: true,
            detail: nil,
            errorMessage: snapshot.errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "notch"],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "notch"],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(id: "enabled", title: metadata.title, kind: .boolean),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        let isEnabled = controller.snapshot().isEnabled
        return [
            ActionCatalogEntry(
                reference: toggleActionReference,
                title: isEnabled
                    ? localization.string("action.disable.title", defaultValue: "显示刘海")
                    : localization.string("action.enable.title", defaultValue: "隐藏刘海"),
                subtitle: isEnabled
                    ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                    : metadata.defaultDescription,
                presentationState: isEnabled ? .active : .inactive
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: "\(metadata.title) · \(localization.string("panel.subtitle.enabled", defaultValue: "已开启"))"
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: "\(metadata.title) · \(localization.string("panel.subtitle.closing", defaultValue: "正在关闭"))"
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        let snapshot = controller.snapshot()
        guard snapshot.hasSupportedDisplay || snapshot.isEnabled else {
            return .unavailable(localization.string(
                "panel.subtitle.noSupportedDisplay",
                defaultValue: "未检测到刘海屏"
            ))
        }
        guard !snapshot.isProcessing else {
            return .unavailable(localization.string("panel.subtitle.closing", defaultValue: "正在关闭"))
        }
        return .available
    }

    func refresh() {
        controller.refresh()
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await controller.setEnabledAndWait(isEnabled)
            onStateChange?()
        }
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let enabled: Bool
        switch invocation.reference.key.actionID {
        case ActionID.toggle:
            enabled = !controller.snapshot().isEnabled
        case ActionID.setEnabled:
            guard case let .boolean(value)? = invocation.reference.parameters["enabled"] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            enabled = value
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        let availability = actionAvailability(for: invocation.reference)
        guard availability.isAvailable else {
            return ActionExecutionHandle {
                .failed(message: availability.reason ?? PluginKitLocalization.actionUnavailable)
            }
        }
        let controller = controller
        return ActionExecutionHandle { [weak self] in
            let result = await controller.setEnabledAndWait(enabled)
            self?.onStateChange?()
            switch result {
            case .succeeded:
                return .succeeded()
            case let .failed(message):
                return .failed(message: message)
            }
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    private func actionReference(enabled: Bool) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
            parameters: try! ActionParameterSet(["enabled": .boolean(enabled)])
        )
    }

    private var toggleActionReference: ActionReference {
        ActionReference(key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle))
    }
}
