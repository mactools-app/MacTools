import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class MiddleClickPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        MiddleClickPluginProvider(context: context)
    }
}

@MainActor
private struct MiddleClickPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            MiddleClickPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            )
        ]
    }
}

/// Converts a trackpad tap with the configured finger count into a middle-button click.
@MainActor
final class MiddleClickPlugin: MacToolsPlugin, AccessibilityPermissionRefreshing,
    PluginActionProviding, PluginActionPermissionProviding,
    PluginInputGestureClaimProviding, PluginInputGestureConflictConsuming
{
    private enum ActionID {
        static let toggle = "toggle"
    }
    private enum PermissionID {
        static let accessibility = "accessibility"
    }

    private enum SettingsID {
        static let section = "click-behavior"
        static let enabled = "enabled"
        static let fingerCount = "finger-count"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "middle-click",
            title: localization.string("metadata.title", defaultValue: "模拟鼠标中键"),
            iconName: "hand.tap",
            iconTint: Color(nsColor: .systemIndigo),
            order: 55,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "触控板轻点 → 模拟鼠标中键"
            )
        )
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    let store: MiddleClickStore

    private let localization: PluginLocalization
    private let makeSession: @MainActor () -> any MiddleClickSessionManaging
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "MiddleClickPlugin"
    )

    private var isAccessibilityGranted: Bool
    private var session: (any MiddleClickSessionManaging)?
    private var hasAccessibilityError = false
    private var externalGestureConflicts: [PluginInputGestureConflict] = []

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "middle-click"),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        makeSession: @escaping @MainActor () -> any MiddleClickSessionManaging = {
            MiddleClickSession()
        },
        accessibilityTrusted: @escaping @MainActor () -> Bool = MiddleClickAccessibilityCheck.isTrusted,
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = MiddleClickAccessibilityCheck.requestTrust(prompt:)
    ) {
        self.localization = localization
        self.store = MiddleClickStore(storage: context.storage)
        self.makeSession = makeSession
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.isAccessibilityGranted = accessibilityTrusted()
    }

    func activate(context: PluginRuntimeContext) {
        refreshAccessibilityPermission()
        applyCurrentConfiguration()
    }

    func deactivate(reason: PluginDeactivationReason) {
        // Process-local callbacks must never survive removal of this plugin instance.
        // During an update we preserve the stored enabled preference, then the replacement
        // instance recreates its session from that preference when it activates.
        stopSession()
        onStateChange?()
    }

    func refresh() {
        refreshAccessibilityPermission()
        applyCurrentConfiguration()
        onStateChange?()
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string(
                    "permission.accessibility.title",
                    defaultValue: "辅助功能授权"
                ),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "模拟鼠标中键需要辅助功能权限才能正常工作。"
                )
            )
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var activeInputGestureClaims: [PluginInputGestureClaim] {
        guard store.isEnabled else { return [] }
        return [inputGestureClaim(for: store.requiredFingerCount)]
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .unavailable,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        [
            ActionCatalogEntry(
                reference: toggleActionReference,
                title: store.isEnabled
                    ? localization.string(
                        "action.disable.title",
                        defaultValue: "关闭模拟鼠标中键"
                    )
                    : localization.string(
                        "action.enable.title",
                        defaultValue: "开启模拟鼠标中键"
                    ),
                subtitle: activeConflictMessage ?? metadata.defaultDescription,
                presentationState: store.isEnabled && activeConflictMessage == nil
                    ? .active
                    : .inactive
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key == toggleActionReference.key else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        // Turning an enabled listener off must remain possible even if permission was
        // revoked or an advanced Trackpad Gestures mapping has since claimed the tap.
        guard !store.isEnabled else { return .available }
        guard isAccessibilityGranted else {
            return .unavailable(accessibilityRequiredMessage)
        }
        if let activeConflictMessage {
            return .unavailable(activeConflictMessage)
        }
        return .available
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        guard actionKey == toggleActionReference.key, !store.isEnabled else { return [] }
        return [PermissionID.accessibility]
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard invocation.reference.key == toggleActionReference.key else {
            return ActionExecutionHandle {
                .failed(message: PluginKitLocalization.actionInvalidParameters)
            }
        }
        return ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            return self.setEnabled(!self.store.isEnabled, promptForPermission: false)
        }
    }

    func inputGestureConflictsDidChange(_ conflicts: [PluginInputGestureConflict]) {
        externalGestureConflicts = conflicts
        applyCurrentConfiguration()
    }

    var settingsPage: PluginSettingsPage? {
        let localizedTitle = localization.string(
            "metadata.title",
            defaultValue: "模拟鼠标中键"
        )
        let localizedDescription = localization.string(
            "metadata.description",
            defaultValue: "触控板轻点 → 模拟鼠标中键"
        )

        return .form(description: localizedDescription, sections: [
            PluginSettingsSection(
                id: SettingsID.section,
                title: localization.string("settings.section.title", defaultValue: "设置"),
                systemImage: "hand.tap",
                rows: [
                    PluginSettingsRow(
                        id: SettingsID.enabled,
                        title: localizedTitle,
                        description: localizedDescription,
                        systemImage: "power",
                        error: configurationErrorMessage,
                        control: .toggle(isOn: store.isEnabled)
                    ),
                    PluginSettingsRow(
                        id: SettingsID.fingerCount,
                        title: localization.string(
                            "settings.fingerCount.title",
                            defaultValue: "手指数量"
                        ),
                        description: localization.string(
                            "settings.fingerCount.description",
                            defaultValue: "用指定数量的手指在触控板上轻点，将模拟鼠标中键点击"
                        ),
                        systemImage: "hand.raised",
                        control: .picker(
                            selectionID: String(store.requiredFingerCount),
                            options: [3, 4, 5].map { count in
                                PluginSettingsOption(
                                    id: String(count),
                                    title: localization.format(
                                        "settings.fingerCount.optionFormat",
                                        defaultValue: "%d指",
                                        count
                                    )
                                )
                            },
                            style: .segmented
                        )
                    )
                ]
            )
        ])
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.accessibility else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }

        return PluginPermissionState(
            isGranted: isAccessibilityGranted,
            footnote: isAccessibilityGranted ? nil : localization.string(
                "permission.accessibility.footnote",
                defaultValue: "前往系统设置 → 隐私与安全性 → 辅助功能，授权 MacTools。"
            )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.accessibility else { return }

        if isAccessibilityGranted {
            refresh()
            return
        }

        isAccessibilityGranted = requestAccessibilityTrust(true)
        if isAccessibilityGranted {
            hasAccessibilityError = false
            applyCurrentConfiguration()
        } else {
            hasAccessibilityError = true
        }
        onStateChange?()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setBoolean(controlID, value):
            guard controlID == SettingsID.enabled else { return }
            _ = setEnabled(value, promptForPermission: true)

        case let .setSelection(controlID, optionID):
            guard controlID == SettingsID.fingerCount,
                  let count = Int(optionID),
                  (3...5).contains(count)
            else {
                return
            }

            store.setRequiredFingerCount(count)
            applyCurrentConfiguration()
            onStateChange?()

        default:
            return
        }
    }

    func handleShortcutAction(id: String) {}

    func refreshAccessibilityPermission() {
        let previous = isAccessibilityGranted
        isAccessibilityGranted = accessibilityTrusted()

        if previous && !isAccessibilityGranted {
            stopSession()
            store.setEnabled(false)
            hasAccessibilityError = true
        } else if !previous && isAccessibilityGranted {
            hasAccessibilityError = false
            applyCurrentConfiguration()
        }

        if previous != isAccessibilityGranted {
            onStateChange?()
        }
    }

    private func setEnabled(
        _ isEnabled: Bool,
        promptForPermission: Bool
    ) -> ActionExecutionResult {
        hasAccessibilityError = false

        guard isEnabled else {
            store.setEnabled(false)
            stopSession()
            onStateChange?()
            return .succeeded()
        }

        isAccessibilityGranted = accessibilityTrusted()
        if !isAccessibilityGranted, promptForPermission {
            isAccessibilityGranted = requestAccessibilityTrust(true)
        }

        guard isAccessibilityGranted else {
            hasAccessibilityError = true
            requestPermissionGuidance?(PermissionID.accessibility)
            onStateChange?()
            return .failed(message: accessibilityRequiredMessage)
        }

        store.setEnabled(true)
        if let activeConflictMessage {
            stopSession()
            onStateChange?()
            return .failed(message: activeConflictMessage)
        }

        startSession()
        onStateChange?()
        return .succeeded()
    }

    private func applyCurrentConfiguration() {
        guard store.isEnabled else {
            stopSession()
            return
        }

        guard isAccessibilityGranted else {
            stopSession()
            hasAccessibilityError = true
            return
        }
        guard activeConflictMessage == nil else {
            stopSession()
            return
        }

        startSession()
    }

    private func startSession() {
        if let session {
            session.requiredFingerCount = store.requiredFingerCount
            return
        }

        let newSession = makeSession()
        newSession.requiredFingerCount = store.requiredFingerCount
        newSession.activate()
        session = newSession
        logger.info(
            "middle click enabled requiredFingerCount=\(self.store.requiredFingerCount, privacy: .public)"
        )
    }

    private func stopSession() {
        guard let session else { return }
        session.deactivate()
        self.session = nil
        logger.info("middle click disabled")
    }

    private var accessibilityRequiredMessage: String {
        localization.string(
            "error.accessibilityRequired",
            defaultValue: "模拟鼠标中键需要辅助功能权限，请先前往设置完成授权。"
        )
    }

    private var configurationErrorMessage: String? {
        if hasAccessibilityError { return accessibilityRequiredMessage }
        return store.isEnabled ? activeConflictMessage : nil
    }

    private var activeConflictMessage: String? {
        let claimID = inputGestureClaim(for: store.requiredFingerCount).id
        guard let conflict = externalGestureConflicts.first(where: { $0.claim.id == claimID }) else {
            return nil
        }
        return localization.format(
            "error.gestureConflict.format",
            defaultValue: "该轻点手势正由“%@”使用。请先停用对应映射。",
            conflict.ownerPluginTitle
        )
    }

    private func inputGestureClaim(for fingerCount: Int) -> PluginInputGestureClaim {
        PluginInputGestureClaim(
            id: "trackpad.tap.\(fingerCount)",
            title: localization.format(
                "settings.fingerCount.optionFormat",
                defaultValue: "%d指",
                fingerCount
            )
        )
    }

    private var toggleActionReference: ActionReference {
        ActionReference(key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle))
    }
}
