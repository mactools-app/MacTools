import AppKit
import CoreFoundation
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

protocol DockCommandRunning {
    func setDockAutohide(_ isEnabled: Bool) throws
}

struct ProcessDockCommandRunner: DockCommandRunning {
    private let localization: PluginLocalization

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
    }

    func setDockAutohide(_ isEnabled: Bool) throws {
        let script = """
        tell application "System Events"
            tell dock preferences
                set autohide to \(isEnabled ? "true" : "false")
            end tell
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)

        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "AutoHideDockPlugin",
                code: (error[NSAppleScript.errorNumber] as? Int) ?? 1,
                userInfo: [
                    NSLocalizedDescriptionKey: message?.isEmpty == false
                        ? message!
                        : localization.string(
                            "error.toggleFailed",
                            defaultValue: "切换 Dock 自动隐藏失败"
                        ),
                ]
            )
        }
    }
}

public final class AutoHideDockPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AutoHideDockPluginProvider(context: context)
    }
}

@MainActor
private struct AutoHideDockPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [AutoHideDockPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class AutoHideDockPlugin: MacToolsPlugin, PluginActionProviding, PluginActionPermissionProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("action.hide.title", defaultValue: "隐藏程序坞"),
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
    private enum PermissionID {
        static let automation = "automation"
    }
    var metadata: PluginMetadata {
        PluginMetadata(
            id: "auto-hide-dock",
            title: localization.string("metadata.title", defaultValue: "自动隐藏程序坞"),
            iconName: "rectangle.bottomthird.inset.filled",
            iconTint: Color(nsColor: .systemBlue),
            order: 45,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "自动隐藏程序坞，提供更干净的桌面环境"
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

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "AutoHideDockPlugin")
    private let commandRunner: any DockCommandRunning
    private let stateReader: () -> Bool
    private let localization: PluginLocalization

    private var isDockHidden: Bool
    private var lastErrorMessage: String?

    init(
        commandRunner: (any DockCommandRunning)? = nil,
        stateReader: @escaping () -> Bool = { AutoHideDockPlugin.readDockAutohideState() },
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.commandRunner = commandRunner ?? ProcessDockCommandRunner(localization: localization)
        self.stateReader = stateReader
        self.isDockHidden = stateReader()
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: isDockHidden
                ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
            isOn: isDockHidden,
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
                    defaultValue: "切换程序坞自动隐藏时需要控制系统事件。"
                )
            ),
        ]
    }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: localization.string("metadata.title", defaultValue: "自动隐藏程序坞"),
                description: localization.string("metadata.description", defaultValue: "自动隐藏程序坞，提供更干净的桌面环境"),
                keywords: [localization.string("metadata.title", defaultValue: "自动隐藏程序坞"), "Dock"],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: localization.string("metadata.title", defaultValue: "自动隐藏程序坞"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "自动隐藏程序坞，提供更干净的桌面环境"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "自动隐藏程序坞"),
                    "Dock",
                ],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: "enabled",
                        title: localization.string("metadata.title", defaultValue: "自动隐藏程序坞"),
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
                title: isDockHidden
                    ? localization.string("action.show.title", defaultValue: "显示程序坞")
                    : localization.string("action.hide.title", defaultValue: "隐藏程序坞"),
                subtitle: isDockHidden
                    ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                    : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
                presentationState: isDockHidden ? .active : .inactive
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: localization.string("action.hide.title", defaultValue: "隐藏程序坞")
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: localization.string("action.show.title", defaultValue: "显示程序坞")
            ),
        ]
    }

    func refresh() {
        let latestState = stateReader()
        if latestState != isDockHidden {
            isDockHidden = latestState
            onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }

        setDockHidden(isEnabled)
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
        let succeeded = setDockHidden(enabled)
        let failureMessage = localization.string(
            "error.toggleFailed",
            defaultValue: "切换 Dock 自动隐藏失败"
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

    @discardableResult
    private func setDockHidden(_ isEnabled: Bool) -> Bool {
        do {
            try commandRunner.setDockAutohide(isEnabled)
            isDockHidden = isEnabled
            lastErrorMessage = nil
            onStateChange?()
            return true
        } catch {
            logger.error("Failed to update Dock auto-hide: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            refresh()
            onStateChange?()
            return false
        }
    }

    private nonisolated static func readDockAutohideState() -> Bool {
        let domain = "com.apple.dock" as CFString
        _ = CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("autohide" as CFString, domain) as? NSNumber)?
            .boolValue ?? false
    }
}
