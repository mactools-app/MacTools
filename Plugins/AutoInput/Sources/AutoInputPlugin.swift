import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

enum AutoInputSettingsSearchEntryID {
    static let behavior = "behavior"
    static let rules = "rules"
    static let hud = "hud"
    static let shortcuts = PluginActionShortcutSettingsConfiguration.settingsSearchEntryID
}

public final class AutoInputPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AutoInputPluginProvider(context: context)
    }
}

@MainActor
private struct AutoInputPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [AutoInputPlugin(context: context)]
    }
}

@MainActor
final class AutoInputPlugin: MacToolsPlugin, PluginApplicationActivityStateHandling, AccessibilityPermissionRefreshing, PluginActionProviding, PluginActionShortcutSettingsProviding, PluginSettingsSearchProviding {
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

    private enum PermissionID {
        static let accessibility = "accessibility"
    }

    private enum ActionID {
        static let selectSource = "select-input-source"
        static let setEnabled = "set-enabled"
        static let toggle = "toggle"
    }

    private enum ActionParameterID {
        static let inputSource = "inputSourceID"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "auto-input",
            title: localization.string("metadata.title", defaultValue: "自动切换输入法"),
            iconName: "keyboard",
            iconTint: Color(nsColor: .systemBlue),
            order: 66,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "按应用记住并自动切换输入法"
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

    private let store: AutoInputStore
    private let controller: AutoInputController
    private let localization: PluginLocalization

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "auto-input"),
        sourceController: AutoInputSourceControlling? = nil,
        applicationMonitor: AutoInputApplicationMonitoring? = nil,
        focusObserver: AutoInputFocusObserving? = nil,
        hudPresenter: InputSourceHUDPresenting? = nil,
        hudLabelResolver: InputSourceHUDLabelResolving? = nil,
        accessibilityCheck: AutoInputAccessibilityChecking? = nil
    ) {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let store = AutoInputStore(storage: context.storage)
        let controller = AutoInputController(
            store: store,
            sourceController: sourceController ?? CarbonAutoInputSourceCatalog(),
            applicationMonitor: applicationMonitor ?? WorkspaceAutoInputApplicationMonitor(),
            focusObserver: focusObserver ?? AccessibilityAutoInputFocusObserver(),
            hudPresenter: hudPresenter ?? InputSourceHUDController(),
            hudLabelResolver: hudLabelResolver ?? StandardInputSourceHUDLabelResolver(),
            accessibilityCheck: accessibilityCheck ?? SystemAutoInputAccessibilityCheck(),
            switchErrorMessage: {
                localization.string("error.switchFailed", defaultValue: "无法切换输入法")
            }
        )
        self.localization = localization
        self.store = store
        self.controller = controller
        controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: store.isAutoSwitchEnabled,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: persistenceErrorMessage ?? controller.errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string(
                    "permission.accessibility.title",
                    defaultValue: "辅助功能"
                ),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "仅用于在文本输入区域和终端附近显示当前输入法。"
                )
            ),
        ]
    }

    func refreshAccessibilityPermission() {
        controller.refreshAccessibilityPermissionState()
    }

    var actionShortcutSettingsConfiguration: PluginActionShortcutSettingsConfiguration {
        PluginActionShortcutSettingsConfiguration(
            title: localization.string(
                "settings.shortcuts.title",
                defaultValue: "输入法快捷键"
            ),
            description: localization.string(
                "settings.shortcuts.description",
                defaultValue: "为常用输入法分配全局快捷键，按下即可直接切换。"
            ),
            actionIDs: [ActionID.selectSource],
            placementAfterSectionID: "hud"
        )
    }

    var settingsSearchEntries: [PluginSettingsSearchEntry] {
        [
            PluginSettingsSearchEntry(
                id: AutoInputSettingsSearchEntryID.behavior,
                title: localization.string(
                    "settings.memory.title",
                    defaultValue: "自动记忆"
                ),
                description: localization.string(
                    "settings.memory.description",
                    defaultValue: "切回应用时恢复上次使用的输入法。"
                ),
                keywords: [
                    localization.string(
                        "settings.behavior.title",
                        defaultValue: "切换行为"
                    ),
                ],
                systemImage: "arrow.counterclockwise"
            ),
            PluginSettingsSearchEntry(
                id: AutoInputSettingsSearchEntryID.rules,
                title: localization.string(
                    "settings.rules.title",
                    defaultValue: "固定规则"
                ),
                description: localization.string(
                    "settings.rules.empty",
                    defaultValue: "添加应用，为它指定固定输入法"
                ),
                keywords: [
                    localization.string(
                        "settings.rules.add",
                        defaultValue: "添加"
                    ),
                    localization.string(
                        "action.selectSource.parameterTitle",
                        defaultValue: "输入法"
                    ),
                ],
                systemImage: "app.badge.checkmark"
            ),
            PluginSettingsSearchEntry(
                id: AutoInputSettingsSearchEntryID.hud,
                title: localization.string(
                    "settings.hud.title",
                    defaultValue: "输入法提示"
                ),
                description: localization.string(
                    "settings.hud.description",
                    defaultValue: "聚焦文本输入区域或终端时，在附近短暂显示当前输入法。需要辅助功能权限。"
                ),
                keywords: [
                    localization.string(
                        "settings.hud.size.title",
                        defaultValue: "提示大小"
                    ),
                    localization.string(
                        "settings.hud.position.title",
                        defaultValue: "提示位置"
                    ),
                    localization.string(
                        "settings.hud.position.at-pointer",
                        defaultValue: "指针处"
                    ),
                    localization.string(
                        "settings.hud.interactive.title",
                        defaultValue: "交互式提示"
                    ),
                    localization.string(
                        "settings.hud.reducedFrequency.title",
                        defaultValue: "减少频繁提示"
                    ),
                    localization.string(
                        "settings.hud.reminderInterval.title",
                        defaultValue: "提示间隔"
                    ),
                    localization.string(
                        "settings.hud.appSwitchReminder.title",
                        defaultValue: "应用切换提示"
                    ),
                    "HUD",
                ],
                systemImage: "text.cursor"
            ),
            PluginSettingsSearchEntry(
                id: AutoInputSettingsSearchEntryID.shortcuts,
                title: localization.string(
                    "settings.shortcuts.title",
                    defaultValue: "输入法快捷键"
                ),
                description: localization.string(
                    "settings.shortcuts.description",
                    defaultValue: "为常用输入法分配全局快捷键，按下即可直接切换。"
                ),
                keywords: [
                    localization.string(
                        "action.selectSource.parameterTitle",
                        defaultValue: "输入法"
                    ),
                ],
                systemImage: "command"
            ),
        ]
    }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(
                id: "behavior",
                title: localization.string("settings.behavior.title", defaultValue: "切换行为"),
                systemImage: "character.cursor.ibeam",
                presentation: .edgeToEdge
            ) { [self] _ in
                AutoInputSettingsView(
                    store: store,
                    controller: controller,
                    localization: localization,
                    onChange: { [weak self] in
                        self?.controller.configurationDidChange()
                        self?.onStateChange?()
                    },
                    onHUDChange: { [weak self] enabled in
                        self?.controller.configurationDidChange(
                            promptForAccessibility: enabled
                        )
                        self?.onStateChange?()
                    },
                    section: .behavior
                )
            },
            PluginSettingsSection(
                id: "rules",
                title: localization.string("settings.rules.title", defaultValue: "固定规则"),
                systemImage: "app.badge.checkmark",
                presentation: .edgeToEdge
            ) { [self] _ in
                AutoInputSettingsView(
                    store: store,
                    controller: controller,
                    localization: localization,
                    onChange: { [weak self] in
                        self?.controller.configurationDidChange()
                        self?.onStateChange?()
                    },
                    onHUDChange: { _ in },
                    section: .rules
                )
            }
            .headerAccessory { [self] _ in
                Button {
                    AutoInputSettingsView.addApplication(
                        store: self.store,
                        controller: self.controller,
                        localization: self.localization,
                        onChange: { [weak self] in
                            self?.controller.configurationDidChange()
                            self?.onStateChange?()
                        }
                    )
                } label: {
                    Label(
                        localization.string("settings.rules.add", defaultValue: "添加"),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.sources.isEmpty)
            },
            PluginSettingsSection(
                id: "hud",
                title: localization.string("settings.hud.title", defaultValue: "输入法提示"),
                systemImage: "text.cursor",
                presentation: .edgeToEdge
            ) { [self] _ in
                AutoInputSettingsView(
                    store: store,
                    controller: controller,
                    localization: localization,
                    onChange: { [weak self] in
                        self?.controller.configurationDidChange()
                        self?.onStateChange?()
                    },
                    onHUDChange: { [weak self] enabled in
                        self?.controller.configurationDidChange(
                            promptForAccessibility: enabled
                        )
                        self?.onStateChange?()
                    },
                    section: .hud
                )
            }
        ])
        .onVisibilityChange { [weak self] isVisible in
            self?.controller.settingsVisibilityDidChange(isVisible)
        }
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: "enabled",
                        title: metadata.title,
                        kind: .boolean
                    ),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.selectSource),
                title: localization.string(
                    "action.selectSource.definitionTitle",
                    defaultValue: "选择输入法"
                ),
                description: localization.string(
                    "action.selectSource.description",
                    defaultValue: "直接切换到指定输入法。"
                ),
                keywords: [
                    metadata.title,
                    localization.string(
                        "action.selectSource.definitionTitle",
                        defaultValue: "选择输入法"
                    ),
                ],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: ActionParameterID.inputSource,
                        title: localization.string(
                            "action.selectSource.parameterTitle",
                            defaultValue: "输入法"
                        ),
                        kind: .string,
                        portability: .localOnly
                    ),
                ],
                externalInvocationPolicy: .unavailable,
                capabilities: [.automatic, .background, .foregroundInteractive],
                concurrencyPolicy: .serialize
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        let stateActions = [
            ActionCatalogEntry(
                reference: toggleActionReference,
                title: store.isAutoSwitchEnabled
                    ? localization.string("action.disable.title", defaultValue: "暂停自动切换输入法")
                    : localization.string("action.enable.title", defaultValue: "开启自动切换输入法"),
                subtitle: panelSubtitle,
                presentationState: store.isAutoSwitchEnabled ? .active : .inactive
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: "\(metadata.title) · \(localization.string("panel.subtitle.remembering", defaultValue: "自动记忆已开启"))"
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: "\(metadata.title) · \(localization.string("panel.subtitle.paused", defaultValue: "已暂停"))"
            ),
        ]
        let sourceActions = controller.sources.map { source in
            ActionCatalogEntry(
                reference: sourceActionReference(sourceID: source.id),
                title: localization.format(
                    "action.selectSource.titleFormat",
                    defaultValue: "切换到 %@",
                    source.name
                ),
                subtitle: metadata.title,
                presentationState: controller.currentSourceID == source.id ? .active : .inactive
            )
        }
        return stateActions + sourceActions
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.actionID == ActionID.selectSource else {
            return .available
        }
        guard let sourceID = sourceID(for: reference),
              controller.sources.contains(where: { $0.id == sourceID }) else {
            return .unavailable(localization.string(
                "action.selectSource.unavailable",
                defaultValue: "输入法已停用或不可用。"
            ))
        }
        return .available
    }

    func activate(context: PluginRuntimeContext) {
        controller.start()
    }

    func deactivate(reason: PluginDeactivationReason) {
        controller.stop()
    }

    func refresh() {
        controller.refresh()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.accessibility else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
        return PluginPermissionState(
            isGranted: controller.isAccessibilityGranted,
            footnote: controller.isAccessibilityGranted
                ? nil
                : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "系统设置 → 隐私与安全性 → 辅助功能，允许 MacTools。自动切换输入法不受影响。"
                )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.accessibility else { return }
        _ = controller.requestAccessibilityPermission()
        if !controller.isAccessibilityGranted {
            requestPermissionGuidance?(PermissionID.accessibility)
        }
        onStateChange?()
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(value) = action else { return }
        _ = setAutoSwitchEnabled(value)
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        switch invocation.reference.key.actionID {
        case ActionID.toggle:
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .cancelled }
                return self.setAutoSwitchEnabled(!self.store.isAutoSwitchEnabled)
            }
        case ActionID.setEnabled:
            guard case let .boolean(value)? = invocation.reference.parameters["enabled"] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .cancelled }
                return self.setAutoSwitchEnabled(value)
            }
        case ActionID.selectSource:
            guard let sourceID = sourceID(for: invocation.reference) else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .cancelled }
                do {
                    try self.controller.selectSource(id: sourceID)
                    return .succeeded()
                } catch AutoInputSourceError.sourceUnavailable {
                    return .failed(message: self.localization.string(
                        "action.selectSource.unavailable",
                        defaultValue: "输入法已停用或不可用。"
                    ))
                } catch {
                    return .failed(message: self.localization.string(
                        "error.switchFailed",
                        defaultValue: "无法切换输入法"
                    ))
                }
            }
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
    }

    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        controller.setInteractive(state.allowsBackgroundWork)
    }

    private var panelSubtitle: String {
        guard store.isAutoSwitchEnabled else {
            return localization.string("panel.subtitle.paused", defaultValue: "已暂停")
        }
        if !store.rules.isEmpty {
            return localization.format(
                "panel.subtitle.rulesFormat",
                defaultValue: "%d 条固定规则",
                store.rules.count
            )
        }
        if store.remembersLastInputSource {
            return localization.string("panel.subtitle.remembering", defaultValue: "自动记忆已开启")
        }
        return localization.string("panel.subtitle.noRules", defaultValue: "暂无切换规则")
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

    private func sourceActionReference(sourceID: String) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.selectSource),
            parameters: try! ActionParameterSet([
                ActionParameterID.inputSource: .string(sourceID),
            ])
        )
    }

    private func sourceID(for reference: ActionReference) -> String? {
        guard reference.key == ActionKey(
            providerID: metadata.id,
            actionID: ActionID.selectSource
        ), case let .string(sourceID)? = reference.parameters[ActionParameterID.inputSource]
        else { return nil }
        return sourceID
    }

    private var persistenceErrorMessage: String? {
        guard case let .rejected(rollbackSucceeded)? = store.persistenceFailure else {
            return nil
        }
        return rollbackSucceeded
            ? localization.string(
                "error.persistenceFailed",
                defaultValue: "无法保存自动切换输入法设置。"
            )
            : localization.string(
                "error.persistenceRollbackFailed",
                defaultValue: "无法保存自动切换输入法设置，且恢复先前设置失败。"
            )
    }

    private func setAutoSwitchEnabled(_ enabled: Bool) -> ActionExecutionResult {
        guard store.setAutoSwitchEnabled(enabled) == .committed else {
            onStateChange?()
            return .failed(message: persistenceErrorMessage ?? PluginKitLocalization.actionUnavailable)
        }
        controller.configurationDidChange()
        onStateChange?()
        return .succeeded()
    }
}
