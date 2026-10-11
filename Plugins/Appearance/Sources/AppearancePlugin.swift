import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class AppearancePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AppearancePluginProvider(context: context)
    }
}

@MainActor
private struct AppearancePluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [AppearancePlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class AppearancePlugin: MacToolsPlugin, PluginActionProviding, PluginActionPermissionProviding {
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
        static let setMode = "set-mode"
    }
    private enum PermissionID {
        static let automation = "automation"
    }
    var metadata: PluginMetadata {
        PluginMetadata(
            id: "appearance",
            title: localization.string("metadata.title", defaultValue: "深色模式"),
            iconName: "circle.lefthalf.filled",
            iconTint: Color(nsColor: .systemIndigo),
            order: 30,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "切换系统亮色与深色外观"
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

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "AppearancePlugin")
    private let localization: PluginLocalization
    private var isDarkMode: Bool = false
    private let appearanceController: any SystemAppearanceControlling
    private var appearanceSnapshot: SystemAppearanceSnapshot?
    private nonisolated(unsafe) var themeObserver: NSObjectProtocol?

    init(localization: PluginLocalization = PluginLocalization(bundle: .main),
         appearanceController: (any SystemAppearanceControlling)? = nil) {
        self.localization = localization
        self.appearanceController = appearanceController ?? SystemAppearanceController()
        isDarkMode = Self.readSystemDarkMode()
        appearanceSnapshot = try? self.appearanceController.read()
        if let appearanceSnapshot { isDarkMode = appearanceSnapshot.isDark }
        observeSystemAppearanceChanges()
    }

    deinit {
        if let observer = themeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: isDarkMode
                ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
            isOn: isDarkMode,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
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
                    defaultValue: "切换系统外观时需要控制系统事件。"
                )
            ),
        ]
    }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: localization.string("metadata.title", defaultValue: "深色模式"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "切换系统亮色与深色外观"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "深色模式"),
                    localization.string("metadata.description", defaultValue: "切换系统亮色与深色外观"),
                ],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: localization.string("metadata.title", defaultValue: "深色模式"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "切换系统亮色与深色外观"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "深色模式"),
                    localization.string("metadata.description", defaultValue: "切换系统亮色与深色外观"),
                ],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: "enabled",
                        title: localization.string("metadata.title", defaultValue: "深色模式"),
                        kind: .boolean
                    ),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setMode),
                title: localization.string("action.setMode.title", defaultValue: "设置系统外观"),
                description: localization.string("action.setMode.description", defaultValue: "选择自动、浅色或深色系统外观。"),
                keywords: ["appearance", "auto", "light", "dark", "系统外观"],
                systemImage: metadata.iconName,
                parameters: [.init(id: "mode", title: localization.string("parameter.mode.title", defaultValue: "Appearance"), kind: .string)],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        [
            ActionCatalogEntry(
                reference: toggleActionReference,
                title: isDarkMode
                    ? localization.string("action.enableLight.title", defaultValue: "启用浅色模式")
                    : localization.string("action.enableDark.title", defaultValue: "启用深色模式"),
                subtitle: isDarkMode
                    ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                    : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
                presentationState: isDarkMode ? .active : .inactive
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: localization.string("action.enableDark.title", defaultValue: "启用深色模式")
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: localization.string("action.enableLight.title", defaultValue: "启用浅色模式")
            ),
        ] + SystemAppearanceMode.allCases.map { mode in
            ActionCatalogEntry(
                reference: modeReference(mode),
                title: localization.string("action.mode.\(mode.rawValue)", defaultValue: "System Appearance: \(mode.title)"),
                presentationState: appearanceSnapshot?.mode == mode ? .active : .inactive
            )
        }
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
        if actionKey.actionID == ActionID.setMode { return [] }
        return [PermissionID.automation]
    }
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.actionID == ActionID.setMode else { return .available }
        guard case let .string(rawMode)? = reference.parameters["mode"], SystemAppearanceMode(rawValue: rawMode) != nil else {
            return .unavailable(PluginKitLocalization.actionInvalidParameters)
        }
        return appearanceSnapshot == nil
            ? .unavailable(SystemAppearanceError.unavailable.localizedDescription) : .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        if invocation.reference.key.actionID == ActionID.setMode {
            guard case let .string(rawMode)? = invocation.reference.parameters["mode"],
                  let mode = SystemAppearanceMode(rawValue: rawMode) else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .cancelled }
                do {
                    try appearanceController.setMode(mode)
                    refresh()
                    guard appearanceSnapshot?.mode == mode else { throw SystemAppearanceError.verificationFailed(restored: false) }
                    return .succeeded()
                } catch {
                    refresh()
                    return .failed(message: error.localizedDescription)
                }
            }
        }
        let enabled: Bool
        switch invocation.reference.key.actionID {
        case ActionID.toggle:
            enabled = !Self.readSystemDarkMode()
        case ActionID.setEnabled:
            guard case let .boolean(value)? = invocation.reference.parameters["enabled"] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            enabled = value
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        let succeeded = setDarkMode(enabled)
        let failureMessage = localization.string(
            "error.toggleFailed",
            defaultValue: "切换系统外观失败。"
        )
        return ActionExecutionHandle {
            succeeded
                ? .succeeded()
                : .failed(message: failureMessage)
        }
    }

    func refresh() {
        let snapshot = try? appearanceController.read()
        let current = snapshot?.isDark ?? Self.readSystemDarkMode()
        if current != isDarkMode || snapshot != appearanceSnapshot {
            isDarkMode = current
            appearanceSnapshot = snapshot
            onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(enable) = action else { return }
        setDarkMode(enable)
    }

    // MARK: - Private

    private static func readSystemDarkMode() -> Bool {
        let style = UserDefaults(suiteName: ".GlobalPreferences")?.string(forKey: "AppleInterfaceStyle")
        return style == "Dark"
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

    private func modeReference(_ mode: SystemAppearanceMode) -> ActionReference {
        ActionReference(key: .init(providerID: metadata.id, actionID: ActionID.setMode),
                        parameters: try! .init(["mode": .string(mode.rawValue)]))
    }

    @discardableResult
    private func setDarkMode(_ enable: Bool) -> Bool {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to \(enable ? "true" : "false")
            end tell
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
        if let error {
            logger.error("Failed to set dark mode: \(error)")
            return false
        } else {
            refresh()
            return true
        }
    }

    private func observeSystemAppearanceChanges() {
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
    }
}
