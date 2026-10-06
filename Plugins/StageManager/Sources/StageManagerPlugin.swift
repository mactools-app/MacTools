import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

enum StageManagerDefaults {
    static let windowManagerDomain = "com.apple.WindowManager"
    static let globallyEnabledKey = "GloballyEnabled"
}

protocol StageManagerCommandRunning {
    func setStageManagerEnabled(_ isEnabled: Bool) throws
}

struct DefaultsStageManagerCommandRunner: StageManagerCommandRunning {
    private let localization: PluginLocalization

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
    }

    func setStageManagerEnabled(_ isEnabled: Bool) throws {
        guard let defaults = UserDefaults(suiteName: StageManagerDefaults.windowManagerDomain) else {
            throw NSError(
                domain: "StageManagerPlugin",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: localization.string(
                        "error.preferencesUnavailable",
                        defaultValue: "无法访问台前调度偏好设置"
                    )
                ]
            )
        }

        defaults.set(isEnabled, forKey: StageManagerDefaults.globallyEnabledKey)

        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.WindowManager.GloballyEnabled.changed"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

public final class StageManagerPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        StageManagerPluginProvider(context: context)
    }
}

@MainActor
private struct StageManagerPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [StageManagerPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class StageManagerPlugin: MacToolsPlugin, PluginActionProviding {
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
            id: "stage-manager",
            title: localization.string("metadata.title", defaultValue: "台前调度"),
            iconName: "sidebar.squares.leading",
            iconTint: Color(nsColor: .systemTeal),
            order: 48,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "开启台前调度，集中显示当前窗口并把其他窗口收纳到侧边"
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

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "StageManagerPlugin")
    private let commandRunner: any StageManagerCommandRunning
    private let stateReader: () -> Bool
    private let localization: PluginLocalization

    private var isStageManagerEnabled: Bool
    private var lastErrorMessage: String?

    init(
        commandRunner: (any StageManagerCommandRunning)? = nil,
        stateReader: @escaping () -> Bool = { StageManagerPlugin.readStageManagerState() },
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.commandRunner = commandRunner ?? DefaultsStageManagerCommandRunner(localization: localization)
        self.stateReader = stateReader
        self.isStageManagerEnabled = stateReader()
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: isStageManagerEnabled
                ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
            isOn: isStageManagerEnabled,
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
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "Stage Manager"],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "Stage Manager"],
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
        [
            ActionCatalogEntry(
                reference: toggleActionReference,
                title: isStageManagerEnabled
                    ? localization.string("action.disable.title", defaultValue: "关闭台前调度")
                    : localization.string("action.enable.title", defaultValue: "开启台前调度"),
                subtitle: isStageManagerEnabled
                    ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                    : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
                presentationState: isStageManagerEnabled ? .active : .inactive
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: "\(metadata.title) · \(localization.string("panel.subtitle.enabled", defaultValue: "已开启"))"
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: "\(metadata.title) · \(localization.string("panel.subtitle.disabled", defaultValue: "已关闭"))"
            ),
        ]
    }

    func refresh() {
        let latestState = stateReader()
        if latestState != isStageManagerEnabled {
            isStageManagerEnabled = latestState
            onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }

        setStageManagerEnabled(isEnabled)
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
            enabled = !stateReader()
        case ActionID.setEnabled:
            guard case let .boolean(value)? = invocation.reference.parameters["enabled"] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            enabled = value
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        let succeeded = setStageManagerEnabled(enabled)
        let failureMessage = lastErrorMessage ?? localization.string(
            "error.preferencesUnavailable",
            defaultValue: "无法访问台前调度偏好设置"
        )
        return ActionExecutionHandle {
            succeeded ? .succeeded() : .failed(message: failureMessage)
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

    @discardableResult
    private func setStageManagerEnabled(_ isEnabled: Bool) -> Bool {
        do {
            try commandRunner.setStageManagerEnabled(isEnabled)
            isStageManagerEnabled = isEnabled
            lastErrorMessage = nil
            onStateChange?()
            return true
        } catch {
            logger.error("Failed to update Stage Manager state: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            refresh()
            onStateChange?()
            return false
        }
    }

    private nonisolated static func readStageManagerState() -> Bool {
        let defaults = UserDefaults(suiteName: StageManagerDefaults.windowManagerDomain)
        return defaults?.object(forKey: StageManagerDefaults.globallyEnabledKey) as? Bool ?? false
    }
}
