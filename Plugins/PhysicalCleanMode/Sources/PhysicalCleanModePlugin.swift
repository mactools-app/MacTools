import AppKit
import Carbon
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class PhysicalCleanModePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        PhysicalCleanModePluginProvider(context: context)
    }
}

@MainActor
private struct PhysicalCleanModePluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [PhysicalCleanModePlugin(context: context)]
    }
}

@MainActor
final class PhysicalCleanModePlugin: MacToolsPlugin, AccessibilityPermissionRefreshing, PluginActionProviding, PluginActionPermissionProviding {
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
                control: .button,
                state: state,
                menuActionBehavior: rowDescriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    private enum StorageKey {
        static let legacyEnabledState = "feature.cleanModeEnabled"
    }

    private enum ActionID {
        static let enter = "enter"
        static let exitPhysicalCleanMode = "exitPhysicalCleanMode"
    }

    private enum PermissionID {
        static let accessibility = "accessibility"
    }

    private enum ShortcutID {
        static let exitPhysicalCleanMode = "exit-physical-clean-mode"
    }

    private enum ShortcutSettingsGroupID {
        static let exitPhysicalCleanMode = "physical-clean-mode.exit"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "physical-clean-mode",
            title: localization.string("metadata.title", defaultValue: "清洁模式"),
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemCyan),
            order: 100,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "屏幕全黑并临时禁用键盘输入"
            )
        )
    }

    let rowDescriptor: PluginPanelRowDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let storage: PluginStorage
    private let localization: PluginLocalization
    private let accessibilityReader: @MainActor () -> Bool
    private let accessibilityRequester: @MainActor (Bool) -> Bool
    private let logger = PhysicalCleanModeLog.plugin
    private var isAccessibilityGranted: Bool
    private var lastErrorKey: String?
    private var lastErrorMessage: String?
    private var session: PhysicalCleanModeSession?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "physical-clean-mode"),
        userDefaults: UserDefaults? = nil,
        accessibilityReader: @escaping @MainActor () -> Bool = AccessibilityCheck.isTrusted,
        accessibilityRequester: @escaping @MainActor (Bool) -> Bool = AccessibilityCheck.requestTrust
    ) {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        self.accessibilityReader = accessibilityReader
        self.accessibilityRequester = accessibilityRequester
        self.storage = userDefaults.map {
            UserDefaultsPluginStorage(pluginID: context.pluginID, userDefaults: $0)
        } ?? context.storage
        self.isAccessibilityGranted = accessibilityReader()
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: { localization.string("panel.button.enter", defaultValue: "开启") }
        )

        storage.migrateValueIfNeeded(
            fromLegacyKey: StorageKey.legacyEnabledState,
            to: StorageKey.legacyEnabledState
        )
        storage.removeObject(forKey: StorageKey.legacyEnabledState)
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            // Preserve session activity for host status, not a toggle control.
            isOn: session != nil,
            isEnabled: session == nil,
            isAvailable: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能授权"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "辅助功能权限是清洁模式运行所需的必要权限。"
                )
            )
        ]
    }


    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: ShortcutID.exitPhysicalCleanMode,
                title: localization.string("shortcut.exit.title", defaultValue: "退出清洁模式"),
                description: localization.string(
                    "shortcut.exit.description",
                    defaultValue: "清洁模式启用时用于恢复输入和关闭黑屏覆盖的快捷键。"
                ),
                actionID: ActionID.exitPhysicalCleanMode,
                scope: .whilePluginActive,
                defaultBinding: ShortcutBinding(
                    keyCode: UInt16(kVK_Escape),
                    modifiers: [.control, .command]
                ),
                isRequired: true,
                settingsGroupID: ShortcutSettingsGroupID.exitPhysicalCleanMode,
                settingsGroupTitle: localization.string("shortcut.exit.settingsGroupTitle", defaultValue: "退出快捷键"),
                settingsGroupDescription: localization.string(
                    "shortcut.exit.settingsGroupDescription",
                    defaultValue: "清洁模式启用时恢复输入并关闭黑屏覆盖。"
                )
            )
        ]
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.enter),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "clean", "keyboard"],
                systemImage: metadata.iconName,
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: metadata.title,
                    message: metadata.defaultDescription,
                    confirmButtonTitle: metadata.title
                ),
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            ),
        ]
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        actionKey.actionID == ActionID.enter ? [PermissionID.accessibility] : []
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.actionID == ActionID.enter else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        guard session == nil else {
            return .unavailable(panelSubtitle)
        }
        guard isAccessibilityGranted else {
            return .unavailable(localizedErrorMessage(for: "error.accessibilityRequired"))
        }
        guard let exitBinding = shortcutBindingResolver?(ShortcutID.exitPhysicalCleanMode),
              exitBinding.isValid else {
            return .unavailable(localizedErrorMessage(for: "error.invalidExitShortcut"))
        }
        return .available
    }

    func refresh() {
        let previousAccessState = isAccessibilityGranted
        isAccessibilityGranted = accessibilityReader()

        if isAccessibilityGranted {
            clearErrorIfKey("error.accessibilityRequired")
        } else if session != nil {
            session?.requestEmergencyExit(message: localization.string(
                "error.accessibilityRevokedEmergencyExit",
                defaultValue: "辅助功能授权已失效，已自动退出清洁模式。"
            ))
        }

        if previousAccessState != isAccessibilityGranted {
            notifyChange()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .invokeAction(controlID) = action, controlID == "execute" else { return }
        if PhysicalCleanModeLog.isVerboseLoggingEnabled {
            logger.debug("panel action enter")
        }
        enterPhysicalCleanModeIfPossible()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        switch permissionID {
        case PermissionID.accessibility:
            return PluginPermissionState(
                isGranted: isAccessibilityGranted,
                footnote: lastErrorMessage
            )
        default:
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.accessibility else {
            return
        }

        if isAccessibilityGranted {
            refresh()
        } else {
            requestAccessibilityPermission(showSettingsGuidance: false)
        }
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {}

    func handleShortcutAction(id: String) {
        guard id == ActionID.exitPhysicalCleanMode else {
            return
        }

        session?.requestStop(reason: .userRequested)
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let availability = actionAvailability(for: invocation.reference)
        guard availability.isAvailable else {
            return ActionExecutionHandle {
                .failed(message: availability.reason ?? PluginKitLocalization.actionUnavailable)
            }
        }
        enterPhysicalCleanModeIfPossible()
        let succeeded = session != nil
        let failureMessage = lastErrorMessage ?? PluginKitLocalization.actionUnavailable
        return ActionExecutionHandle {
            succeeded ? .succeeded() : .failed(message: failureMessage)
        }
    }

    private var panelSubtitle: String {
        if let session {
            return localization.format(
                "panel.subtitle.enabledExitFormat",
                defaultValue: "已启用，使用 %@ 退出",
                ShortcutFormatter.displayString(for: session.exitBinding)
            )
        }

        if isAccessibilityGranted {
            return metadata.defaultDescription
        }

        return localization.string("panel.subtitle.needsAccessibility", defaultValue: "启用前需要辅助功能授权")
    }

    private func requestAccessibilityPermission(showSettingsGuidance: Bool) {
        if PhysicalCleanModeLog.isVerboseLoggingEnabled {
            logger.debug("request accessibility permission showSettingsGuidance=\(showSettingsGuidance, privacy: .public)")
        }
        isAccessibilityGranted = accessibilityRequester(true)

        if isAccessibilityGranted {
            clearError()
        } else {
            logger.notice("accessibility permission is required before entering physical clean mode")
            setError("error.accessibilityRequired")

            if showSettingsGuidance {
                requestPermissionGuidance?(PermissionID.accessibility)
            }
        }

        notifyChange()
    }

    private func enterPhysicalCleanModeIfPossible() {
        guard session == nil else { return }
        isAccessibilityGranted = accessibilityReader()

        guard isAccessibilityGranted else {
            requestAccessibilityPermission(showSettingsGuidance: true)
            return
        }

        guard let exitBinding = shortcutBindingResolver?(ShortcutID.exitPhysicalCleanMode), exitBinding.isValid else {
            logger.error("entry aborted because exit shortcut is missing or invalid")
            setError("error.invalidExitShortcut")
            notifyChange()
            return
        }

        let session = PhysicalCleanModeSession(
            exitBinding: exitBinding,
            onEnd: { [weak self] reason in
                self?.handleSessionEnd(reason)
            },
            localization: localization
        )

        do {
            self.session = session
            if PhysicalCleanModeLog.isVerboseLoggingEnabled {
                logger.debug("starting physical clean mode session exitBinding=\(ShortcutFormatter.displayString(for: exitBinding), privacy: .public)")
            }
            try session.start()

            guard self.session === session else {
                logger.error("session ended during startup sequence before completion")
                return
            }

            clearError()
            notifyChange()
        } catch {
            if self.session === session {
                self.session = nil
            }
            logger.error("physical clean mode session start failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            notifyChange()
        }
    }

    private func handleSessionEnd(_ reason: PhysicalCleanModeSession.EndReason) {
        switch reason {
        case .userRequested:
            break
        case .emergency:
            logger.error("physical clean mode session ended unexpectedly reason=\(String(describing: reason), privacy: .public)")
        }

        session = nil

        switch reason {
        case .userRequested:
            clearError()
        case let .emergency(message):
            setRawError(message)
        }

        notifyChange()
    }

    private func clearError() {
        lastErrorKey = nil
        lastErrorMessage = nil
    }

    private func clearErrorIfKey(_ key: String) {
        guard lastErrorKey == key else { return }
        clearError()
    }

    private func setError(_ key: String) {
        lastErrorKey = key
        lastErrorMessage = localizedErrorMessage(for: key)
    }

    private func setRawError(_ message: String) {
        lastErrorKey = nil
        lastErrorMessage = message
    }

    private func localizedErrorMessage(for key: String) -> String {
        switch key {
        case "error.accessibilityRequired":
            return localization.string(key, defaultValue: "清洁模式需要辅助功能权限，请先前往设置完成授权。")
        case "error.invalidExitShortcut":
            return localization.string(key, defaultValue: "请先在功能中设置有效的退出快捷键。")
        default:
            return localization.string(key, defaultValue: "清洁模式不可用。")
        }
    }

    private func notifyChange() {
        onStateChange?()
    }

    // MARK: - AccessibilityPermissionRefreshing

    func refreshAccessibilityPermission() {
        refresh()
    }
}
