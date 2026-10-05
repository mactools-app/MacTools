import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

enum WindowSwitcherDiagnostic: Equatable {
    case actionRequested, actionUnavailable, actionFailed
    case assignedConflict, assignedUnavailable
    case accessibilityRevoked, accessibilityRequired, discoveryTimeout, shortcutTapUnavailable

    init?(actionResult: WindowSwitcherActionResult) {
        switch actionResult {
        case .succeeded, .cancelled: return nil
        case .requested: self = .actionRequested
        case .unavailable: self = .actionUnavailable
        case .failed: self = .actionFailed
        }
    }

    func message(using localization: PluginLocalization) -> String {
        switch self {
        case .actionRequested:
            localization.string("action.requested", defaultValue: "已发送请求；应用可能会要求保存更改。")
        case .actionUnavailable:
            localization.string("action.unavailable", defaultValue: "窗口已关闭或暂时无法访问，请重新选择。")
        case .actionFailed:
            localization.string("action.failed", defaultValue: "未能确认目标窗口，请重试或检查辅助功能权限。")
        case .assignedConflict:
            localization.string("chooser.assignedConflict", defaultValue: "快捷键已占用，请重新输入")
        case .assignedUnavailable:
            localization.string("chooser.assignedUnavailable", defaultValue: "无法修改此窗口的快捷键")
        case .accessibilityRevoked:
            localization.string("error.accessibilityRevoked", defaultValue: "辅助功能权限已关闭，窗口切换已暂停。")
        case .accessibilityRequired:
            localization.string("error.accessibilityRequired", defaultValue: "窗口切换需要辅助功能权限，请先前往设置完成授权。")
        case .discoveryTimeout:
            localization.string("error.discoveryTimeout", defaultValue: "尚未读取到可切换窗口，请稍后重试。")
        case .shortcutTapUnavailable:
            localization.string("error.shortcutTap", defaultValue: "无法监听快捷键，请检查辅助功能权限。")
        }
    }
}

public final class WindowSwitcherPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        WindowSwitcherPluginProvider(context: context)
    }
}

@MainActor
private struct WindowSwitcherPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            WindowSwitcherPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class WindowSwitcherPlugin: MacToolsPlugin, AccessibilityPermissionRefreshing, DisplayTopologyRefreshing,
    PluginShortcutEventHandling, PluginShortcutBindingChangeHandling, PluginFocusedWindowTargetConsuming,
    PluginActionProviding, PluginActionPermissionProviding, PluginInlineShortcutSettingsContextConsuming {
    private enum SettingsID {
        static let enabled = "enabled"
        static let mode = "mode"
        static let sortMode = "sort-mode"
        static let shortcutPreset = "switching-shortcut"
        static let companion = "companion-defaults"
        static let commandTab = "command-tab"
        static let preview = "selected-preview"
        static let minimized = "minimized-windows"
        static let otherDesktops = "other-desktop-windows"
        static let fullscreenSpaces = "fullscreen-space-windows"
    }


    var metadata: PluginMetadata {
        PluginMetadata(
            id: WindowSwitcherConstants.pluginID,
            title: localization.string("metadata.title", defaultValue: "窗口切换"),
            iconName: "rectangle.2.swap",
            iconTint: Color(nsColor: .systemIndigo),
            order: 64,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "快速切换正在运行的窗口"
            )
        )
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    private var skippedSingleWindow = false
    var inlineShortcutSettingsContextProvider: (() -> PluginSettingsContext)?
    private var shortcutPresetError: String?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)? {
        didSet { configureShortcutBindings() }
    }
    var focusedWindowTargetProvider: (() -> PluginFocusedWindowTarget?)?

    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?) {
        configureShortcutBindings()
    }

    let store: WindowSwitcherStore

    private let localization: PluginLocalization
    private let appCatalog: any WindowSwitcherCatalog
    private let overlayController: WindowSwitcherOverlayController
    private let shortcutTap: any WindowSwitcherShortcutListening
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool

    private var isActive = false
    private var isRecordingShortcut = false
    private var isAccessibilityGranted: Bool
    private var lastError: WindowSwitcherDiagnostic?
    private var lastErrorMessage: String? { lastError?.message(using: localization) }
    private(set) var session: WindowSwitcherSession?
    private var sessionGeneration = 0
    private var invocationPID: pid_t?
    private(set) var pendingInvocation: (reversed: Bool, currentApp: Bool, persistent: Bool)?
    private let discoveryTimeout: Duration
    private var pendingRelease = false
    private var pendingSteps = 0
    private var showTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: WindowSwitcherConstants.pluginID),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        appCatalog: any WindowSwitcherCatalog = WindowSwitcherAppCatalog(),
        overlayController: WindowSwitcherOverlayController? = nil,
        shortcutTap: any WindowSwitcherShortcutListening = WindowSwitcherShortcutTap(),
        discoveryTimeout: Duration = .seconds(2),
        accessibilityTrusted: @escaping @MainActor () -> Bool = WindowSwitcherAccessibilityCheck.isTrusted,
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = WindowSwitcherAccessibilityCheck.requestTrust(prompt:)
    ) {
        self.discoveryTimeout = discoveryTimeout
        self.localization = localization
        self.store = WindowSwitcherStore(storage: context.storage)
        self.appCatalog = appCatalog
        self.overlayController = overlayController ?? WindowSwitcherOverlayController(localization: localization)
        self.shortcutTap = shortcutTap
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.isAccessibilityGranted = accessibilityTrusted()

        self.appCatalog.listingPolicy = store.configuration.listingPolicy
        self.appCatalog.onChange = { [weak self] in
            self?.catalogDidChange()
        }
        self.overlayController.onSelect = { [weak self] entry in
            self?.select(entry)
        }
        self.overlayController.onQuit = { [weak self] entry in
            self?.quit(entry)
        }
        self.overlayController.onClose = { [weak self] entry in
            self?.close(entry)
        }
        self.overlayController.onShortcutChange = { [weak self] entry, token in
            guard let self, let session = self.session, session.usesDirectKeys else { return .unavailable }
            return self.store.setManualShortcut(token, for: entry.id, in: session.entries)
        }
        self.overlayController.onSessionChange = { [weak self] session in
            self?.session = session
            self?.shortcutTap.setEditing(session.usesDirectKeys ||
                (session.isPersistent && self?.overlayController.isEditingSearch == true) ||
                self?.overlayController.isPresentingMenu == true)
        }
        self.overlayController.onSearchEditingChange = { [weak self] editing in
            self?.shortcutTap.setEditing((editing && self?.session?.isPersistent == true) ||
                self?.session?.usesDirectKeys == true || self?.overlayController.isPresentingMenu == true)
        }
        self.overlayController.onMenuTrackingChange = { [weak self] tracking in
            self?.shortcutTap.setEditing(tracking ||
                (self?.session?.isPersistent == true && self?.overlayController.isEditingSearch == true) ||
                self?.session?.usesDirectKeys == true)
        }
        self.overlayController.onLayoutChange = { [weak self] layout in
            self?.store.setPreferredLayout(layout)
        }
        self.overlayController.onPreviewChange = { [weak self] value in
            self?.store.setShowsPreview(value)
            self?.onStateChange?()
        }
        self.overlayController.onModeChange = { [weak self] mode in
            self?.changeModeFromChooser(mode)
        }
        self.overlayController.onCancel = { [weak self] in
            self?.cancelSession()
        }
        self.shortcutTap.onShortcutPressed = { [weak self] reversed, isRepeat, currentApp in
            self?.handleShortcutPressed(reversed: reversed, isRepeat: isRepeat, currentApp: currentApp)
        }
        self.shortcutTap.onShortcutReleased = { [weak self] in
            self?.handleShortcutReleased()
        }
        self.shortcutTap.onAccessibilityRevoked = { [weak self] in
            self?.refreshAccessibilityPermission()
        }
        self.shortcutTap.onEscape = { [weak self] in
            self?.cancelSession()
        }
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: WindowSwitcherConstants.accessibilityPermissionID,
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于接管切换快捷键并切换其他应用窗口。"
                )
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: WindowSwitcherConstants.shortcutDefinitionID,
                title: localization.string("shortcut.switcher.title", defaultValue: "窗口切换"),
                description: localization.string(
                    "shortcut.switcher.description",
                    defaultValue: "显示或切换正在运行的窗口。"
                ),
                actionID: WindowSwitcherConstants.shortcutActionID,
                scope: .whilePluginActive,
                defaultBinding: allWindowsDefaultBinding,
                isRequired: true,
                settingsGroupID: "window-switcher",
                settingsGroupTitle: localization.string("shortcut.group.title", defaultValue: "窗口切换"),
                settingsGroupDescription: localization.string(
                    "shortcut.group.description",
                    defaultValue: "修改用于唤起窗口切换的快捷键。"
                ),
                settingsControlTitle: localization.string("chooser.all", defaultValue: "全部窗口")
            ),
            PluginShortcutDefinition(
                id: WindowSwitcherConstants.currentAppShortcutID,
                title: localization.string("action.currentApp.title", defaultValue: "当前应用窗口"), description: localization.string("shortcut.currentApp.description", defaultValue: "切换当前应用的窗口。"),
                actionID: WindowSwitcherConstants.currentAppActionID,
                scope: .whilePluginActive,
                defaultBinding: store.configuration.usesCompanionDefaults ? WindowSwitcherShortcutBindingStore.currentAppBinding : nil,
                isRequired: false,
                settingsGroupID: "window-switcher",
                settingsControlTitle: localization.string("chooser.current", defaultValue: "当前应用")
            ),
        ]
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(
                    providerID: metadata.id,
                    actionID: WindowSwitcherConstants.shortcutActionID
                ),
                title: localization.string(
                    "shortcut.switcher.title",
                    defaultValue: "窗口切换"
                ),
                description: localization.string(
                    "shortcut.switcher.description",
                    defaultValue: "显示或切换正在运行的窗口。"
                ),
                keywords: [metadata.title, "Window Switcher"],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: WindowSwitcherConstants.currentAppActionID),
                title: localization.string("action.currentApp.title", defaultValue: "当前应用窗口"), description: localization.string("action.currentApp.description", defaultValue: "搜索和选择当前应用的窗口。"),
                keywords: [metadata.title, "Current App Windows"], systemImage: metadata.iconName,
                externalInvocationPolicy: .unavailable, capabilities: [.foregroundInteractive]
            ),
        ]
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        actionDefinitions.contains { $0.key == actionKey }
            ? [WindowSwitcherConstants.accessibilityPermissionID]
            : []
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard actionDefinitions.contains(where: { $0.key == reference.key }) else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        guard store.configuration.isEnabled else {
            return .unavailable(localization.string(
                "settings.status.disabled.description",
                defaultValue: "暂停快捷键监听，系统默认切换保持不变。"
            ))
        }
        guard isAccessibilityGranted else {
            return .unavailable(localization.string(
                "error.accessibilityRequired",
                defaultValue: "窗口切换需要辅助功能权限，请先前往设置完成授权。"
            ))
        }
        return .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let availability = actionAvailability(for: invocation.reference)
        guard availability.isAvailable else {
            return ActionExecutionHandle {
                .failed(message: availability.reason ?? PluginKitLocalization.actionUnavailable)
            }
        }
        // Capture the host's pre-palette target before its temporary UI closes.
        let targetPID = focusedWindowTargetProvider?()?.application.processIdentifier
        var generation: Int?
        return ActionExecutionHandle(operation: { [weak self] in
            guard let self, !Task.isCancelled else { return .cancelled }
            beginSession(reversed: false, currentApp: invocation.reference.key.actionID == WindowSwitcherConstants.currentAppActionID,
                         persistent: true, targetPID: targetPID)
            generation = sessionGeneration
            while pendingInvocation != nil, generation == sessionGeneration, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !Task.isCancelled else { return .cancelled }
            if skippedSingleWindow { return .succeeded() }
            if generation == sessionGeneration { await showTask?.value }
            guard generation == sessionGeneration, session != nil, overlayController.isVisible else {
                return lastErrorMessage.map { .failed(message: $0) } ?? .cancelled
            }
            return .succeeded()
        }, cancel: { [weak self] in
            guard let self, generation == sessionGeneration else { return }
            cancelSession()
        })
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "status",
                    title: localization.string("settings.status.sectionTitle", defaultValue: "状态"),
                    systemImage: "power",
                    rows: [
                        PluginSettingsRow(
                            id: SettingsID.enabled,
                            title: localization.string("settings.status.title", defaultValue: "启用窗口切换"),
                            description: store.configuration.isEnabled
                                ? localization.string("settings.status.enabled.description", defaultValue: "接管切换快捷键，显示并切换应用窗口。")
                                : localization.string("settings.status.disabled.description", defaultValue: "暂停快捷键监听，系统默认切换保持不变。"),
                            systemImage: "rectangle.2.swap",
                            error: lastErrorMessage,
                            control: .toggle(isOn: store.configuration.isEnabled)
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "preview",
                    title: localization.string("settings.preview.sectionTitle", defaultValue: "预览"),
                    systemImage: "rectangle.on.rectangle",
                    rows: [
                        PluginSettingsRow(
                            id: SettingsID.preview, title: localization.string("settings.preview.title", defaultValue: "选中窗口预览"),
                            description: localization.string("settings.preview.description", defaultValue: "仅预览选中窗口。需在系统设置中允许录屏，不启用预览也可搜索和切换。"),
                            systemImage: "rectangle.on.rectangle",
                            control: .toggle(isOn: store.configuration.showsPreview)
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "window-scope",
                    title: localization.string("settings.scope.sectionTitle", defaultValue: "窗口范围"),
                    systemImage: "square.on.square",
                    rows: [
                        PluginSettingsRow(
                            id: SettingsID.minimized,
                            title: localization.string("settings.minimized.title", defaultValue: "包含最小化窗口"),
                            description: localization.string("settings.minimized.description", defaultValue: "选择后会还原并切换到已最小化的窗口。"),
                            systemImage: "minus.rectangle",
                            control: .toggle(isOn: store.configuration.includesMinimizedWindows)
                        ),
                        PluginSettingsRow(
                            id: SettingsID.otherDesktops,
                            title: localization.string("settings.otherDesktops.title", defaultValue: "包含其他桌面上的窗口"),
                            description: localization.string("settings.otherDesktops.description", defaultValue: "可切换到其他桌面或空间上的窗口。"),
                            systemImage: "menubar.dock.rectangle",
                            control: .toggle(isOn: store.configuration.includesOtherDesktopWindows)
                        ),
                        PluginSettingsRow(
                            id: SettingsID.fullscreenSpaces,
                            title: localization.string("settings.fullscreen.title", defaultValue: "包含全屏空间中的窗口"),
                            description: localization.string("settings.fullscreen.description", defaultValue: "包括全屏 App 所在的独立空间。"),
                            systemImage: "arrow.up.left.and.arrow.down.right",
                            control: .toggle(isOn: store.configuration.includesFullscreenSpaceWindows)
                        )
                    ]
                ),
                PluginSettingsSection(id: "behavior-options",
                    title: localization.string("settings.mode.title", defaultValue: "默认行为"),
                    systemImage: "keyboard") { [weak self] _ in
                    if let self {
                        WindowSwitcherBehaviorSettingsView(localization: localization, group: .behavior,
                            mode: Binding(get: { self.store.configuration.mode }, set: {
                                self.handleSettingsAction(.setSelection(controlID: SettingsID.mode, optionID: $0.rawValue))
                            }), sortMode: Binding(get: { self.store.configuration.sortMode }, set: {
                                self.handleSettingsAction(.setSelection(controlID: SettingsID.sortMode, optionID: $0.rawValue))
                            }))
                    }
                },
                PluginSettingsSection(id: "order-options",
                    title: localization.string("settings.sort.title", defaultValue: "排序"),
                    systemImage: "arrow.up.arrow.down") { [weak self] _ in
                    if let self {
                        WindowSwitcherBehaviorSettingsView(localization: localization, group: .order,
                            mode: Binding(get: { self.store.configuration.mode }, set: {
                                self.handleSettingsAction(.setSelection(controlID: SettingsID.mode, optionID: $0.rawValue))
                            }), sortMode: Binding(get: { self.store.configuration.sortMode }, set: {
                                self.handleSettingsAction(.setSelection(controlID: SettingsID.sortMode, optionID: $0.rawValue))
                            }))
                    }
                },
                PluginSettingsSection(id: "shortcut-hotkeys", title: localization.string("settings.hotkeys", defaultValue: "快捷键"),
                    systemImage: "command", embeddedShortcutGroupIDs: ["window-switcher"]) { [weak self] context in
                    if let self {
                        WindowSwitcherShortcutSettingsView(context: context, localization: localization,
                            onRecordingChange: { [weak self] in self?.setShortcutRecording($0) },
                            binding: { id in self.shortcutBindingResolver?(id) ?? (self.shortcutBindingResolver == nil
                                ? (id == WindowSwitcherConstants.currentAppShortcutID ? WindowSwitcherShortcutBindingStore.currentAppBinding : self.allWindowsDefaultBinding) : nil) })
                    }
                }
            ]
        )
    }

    func activate(context: PluginRuntimeContext) {
        isActive = true
        refreshAccessibilityPermission()
        syncShortcutTap()
    }

    func deactivate(reason: PluginDeactivationReason) {
        isActive = false
        isRecordingShortcut = false
        cancelSession()
        shortcutTap.stop()
        appCatalog.stop()
    }

    func refresh() {
        refreshAccessibilityPermission()
        syncShortcutTap()
        onStateChange?()
    }

    func refreshDisplayTopology() {
        appCatalog.refresh()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == WindowSwitcherConstants.accessibilityPermissionID else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }

        return PluginPermissionState(
            isGranted: isAccessibilityGranted,
            footnote: isAccessibilityGranted
                ? nil
                : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "系统设置 → 隐私与安全性 → 辅助功能，允许 MacTools。"
                )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == WindowSwitcherConstants.accessibilityPermissionID else {
            return
        }

        handleAccessibilityPermissionAction()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setBoolean(controlID, value):
            switch controlID {
            case SettingsID.enabled: store.setEnabled(value)
            case SettingsID.preview: store.setShowsPreview(value)
            case SettingsID.minimized: store.setIncludesMinimizedWindows(value)
            case SettingsID.otherDesktops: store.setIncludesOtherDesktopWindows(value)
            case SettingsID.fullscreenSpaces: store.setIncludesFullscreenSpaceWindows(value)
            default: return
            }
        case let .invoke(controlID):
            guard controlID == SettingsID.companion || controlID == SettingsID.commandTab else { return }
            applySwitchingShortcut(controlID == SettingsID.commandTab
                ? WindowSwitcherShortcutBindingStore.legacyBinding
                : WindowSwitcherShortcutBindingStore.defaultBinding)
            return
        case let .setSelection(controlID, optionID):
            switch controlID {
            case SettingsID.shortcutPreset:
                guard optionID == "command-tab" || optionID == "option-tab" else { return }
                applySwitchingShortcut(optionID == "command-tab"
                    ? WindowSwitcherShortcutBindingStore.legacyBinding : WindowSwitcherShortcutBindingStore.defaultBinding)
                return
            case SettingsID.mode:
                guard let mode = WindowSwitcherMode(rawValue: optionID) else { return }
                store.setMode(mode)
            case SettingsID.sortMode:
                guard let sortMode = WindowSwitcherSortMode(rawValue: optionID) else { return }
                store.setSortMode(sortMode)
            default:
                return
            }
        default:
            return
        }
        configurationDidChange()
    }

    var switchingShortcutSelection: String {
        let binding = shortcutBindingResolver?(WindowSwitcherConstants.shortcutDefinitionID)
            ?? (shortcutBindingResolver == nil ? allWindowsDefaultBinding : nil)
        if binding == WindowSwitcherShortcutBindingStore.legacyBinding { return "command-tab" }
        if binding == WindowSwitcherShortcutBindingStore.defaultBinding { return "option-tab" }
        return "custom"
    }

    private var switchingShortcutOptions: [PluginSettingsOption] {
        var options = [
            PluginSettingsOption(id: "option-tab", title: localization.string("settings.shortcutPreset.option", defaultValue: "⌥Tab · 保留系统切换")),
            PluginSettingsOption(id: "command-tab", title: localization.string("settings.shortcutPreset.command", defaultValue: "⌘Tab · 替代系统切换"))
        ]
        if switchingShortcutSelection == "custom" {
            options.append(PluginSettingsOption(id: "custom", title: localization.string("settings.shortcutPreset.custom", defaultValue: "自定义快捷键")))
        }
        return options
    }

    private func applySwitchingShortcut(_ binding: ShortcutBinding) {
        guard let context = inlineShortcutSettingsContextProvider?(),
              let item = context.shortcutItem(definitionID: WindowSwitcherConstants.shortcutDefinitionID) else {
            shortcutPresetError = localization.string("settings.shortcut.unavailable", defaultValue: "快捷键设置暂不可用，请重新打开设置。")
            onStateChange?()
            return
        }
        switch context.recordShortcut(binding, for: item.id) {
        case .accepted:
            // This explicit choice replaces an existing custom assignment. Keep the
            // inherited default at Option-Tab so the recorder's reset restores it.
            store.useCompanionDefaults()
            shortcutPresetError = nil
            configurationDidChange()
        case let .rejected(message):
            shortcutPresetError = message
            onStateChange?()
        }
    }

    func handleShortcutAction(id: String) {
        guard [WindowSwitcherConstants.shortcutActionID, WindowSwitcherConstants.currentAppActionID].contains(id),
              store.configuration.isEnabled
        else {
            return
        }

        handleShortcutPressed(reversed: false, isRepeat: false, currentApp: id == WindowSwitcherConstants.currentAppActionID)
    }

    func handleShortcutEvent(id: String, phase: PluginShortcutEventPhase) {
        guard [WindowSwitcherConstants.shortcutActionID, WindowSwitcherConstants.currentAppActionID].contains(id),
              store.configuration.isEnabled
        else {
            return
        }

        switch phase {
        case .pressed:
            handleShortcutPressed(reversed: false, isRepeat: false, currentApp: id == WindowSwitcherConstants.currentAppActionID)
        case .released:
            handleShortcutReleased()
        }
    }

    func refreshAccessibilityPermission() {
        let previous = isAccessibilityGranted
        isAccessibilityGranted = accessibilityTrusted()

        if previous && !isAccessibilityGranted {
            cancelSession()
            shortcutTap.stop()
            appCatalog.stop()
            if store.configuration.isEnabled {
                lastError = .accessibilityRevoked
            }
        } else if !previous && isAccessibilityGranted {
            lastError = nil
            syncShortcutTap()
        }

        if previous != isAccessibilityGranted {
            onStateChange?()
        }
    }

    private var settingsModeDescription: String {
        switch store.configuration.mode {
        case .keyWindow:
            localization.string("settings.mode.legacy.description", defaultValue: "按已分配的按键直接打开窗口。点击搜索框开始搜索。")
        case .searchSelect:
            localization.string(
                "settings.mode.search.description",
                defaultValue: "输入搜索，按快捷键选择下一个窗口，按回车打开。"
            )
        case .directCycle:
            localization.string(
                "settings.mode.directCycle.description",
                defaultValue: "按住快捷键循环选择，松开后切换窗口。"
            )
        }
    }

    private var settingsSortDescription: String {
        switch store.configuration.sortMode {
        case .recentUse:
            localization.string(
                "settings.sort.recentUse.description",
                defaultValue: "按窗口最近使用时间排列，便于回到上一个窗口。"
            )
        case .fixed:
            localization.string(
                "settings.sort.fixed.description",
                defaultValue: "先按应用名称，再按窗口标题排序。"
            )
        }
    }

    private func configurationDidChange() {
        cancelSession()
        appCatalog.listingPolicy = store.configuration.listingPolicy
        if !store.configuration.isEnabled { lastError = nil }
        syncShortcutTap()
        onStateChange?()
    }

    private func changeModeFromChooser(_ mode: WindowSwitcherMode) {
        guard var session, overlayController.isVisible else { return }
        store.setMode(mode)
        session.query = ""
        session.invocationModifiers = []
        // A mouse-selected mode stays open until Enter or Escape. The next
        // shortcut invocation retains Cycle mode's release-to-switch behavior.
        session.isPersistent = true
        session.usesDirectKeys = mode == .keyWindow
        session.reconcile(mode == .keyWindow
            ? store.assignShortcuts(to: appCatalog.entries(sortMode: store.configuration.sortMode))
            : appCatalog.entries(sortMode: store.configuration.sortMode))
        self.session = session
        shortcutTap.setEditing(mode == .keyWindow)
        overlayController.applyMode(mode, session: session)
        onStateChange?()
    }

    private func handleShortcutPressed(reversed: Bool, isRepeat: Bool, currentApp: Bool = false) {
        guard store.configuration.isEnabled, ensureAccessibilityForInvocation() else { return }
        // Tab switching remains available while searching. Preserve ordinary custom
        // editing chords (for example Command-C) in the native text responder.
        if session?.isPersistent == true, overlayController.isEditingSearch {
            let id = currentApp ? WindowSwitcherConstants.currentAppShortcutID : WindowSwitcherConstants.shortcutDefinitionID
            let binding = shortcutBindingResolver?(id)
                ?? (shortcutBindingResolver == nil ? (currentApp ? WindowSwitcherShortcutBindingStore.currentAppBinding : allWindowsDefaultBinding) : nil)
            guard let binding, [UInt16(48), UInt16(50)].contains(binding.keyCode) else { return }
        }
        if session?.usesDirectKeys == true || overlayController.isPresentingMenu { return }
        if var session {
            session.navigateScope(currentApp: currentApp, direction: reversed ? -1 : 1)
            if !session.isPersistent { session.invocationModifiers = invocationModifiers(currentApp: currentApp) }
            self.session = session
            overlayController.update(session)
            overlayController.noteCyclingInput()
        } else if let pending = pendingInvocation {
            if !pending.persistent, pendingRelease, !isRepeat {
                beginSession(reversed: reversed, currentApp: currentApp, persistent: false)
            } else if !pending.persistent {
                pendingSteps += reversed ? -1 : 1
            }
        } else {
            beginSession(reversed: reversed, currentApp: currentApp, persistent: store.configuration.mode != .directCycle)
        }
    }

    private func handleShortcutReleased() {
        guard store.configuration.isEnabled, ensureAccessibilityForInvocation() else { return }
        if pendingInvocation != nil { pendingRelease = true; return }
        guard let session, !session.isPersistent, !overlayController.deferReleaseForMenu() else { return }
        if let entry = session.selected { select(entry) } else { cancelSession() }
    }

    private func beginSession(reversed: Bool, currentApp: Bool, persistent: Bool, targetPID: pid_t? = nil) {
        guard ensureAccessibilityForInvocation() else { return }
        cancelSession()
        skippedSingleWindow = false
        shortcutTap.setSessionActive(true)
        invocationPID = targetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        appCatalog.prepareForInvocation()
        let entries = appCatalog.entries(sortMode: store.configuration.sortMode)
        if entries.isEmpty || !appCatalog.isInvocationReady {
            pendingInvocation = (reversed, currentApp, persistent)
            pendingSteps = persistent ? 0 : (reversed ? -1 : 1)
            shortcutTap.setEditing(false)
            pendingRelease = false
            let generation = sessionGeneration
            showTask = Task { [weak self] in
                try? await Task.sleep(for: self?.discoveryTimeout ?? .seconds(2))
                guard !Task.isCancelled, let self, sessionGeneration == generation, pendingInvocation != nil else { return }
                cancelSession()
                lastError = .discoveryTimeout
                onStateChange?()
            }
            return
        }
        present(entries, reversed: reversed, currentApp: currentApp, persistent: persistent)
    }

    private func present(_ entries: [WindowSwitcherAppEntry], reversed: Bool, currentApp: Bool, persistent: Bool, steps: Int? = nil) {
        let scope: WindowSwitcherSession.Scope = currentApp
            ? invocationPID.map(WindowSwitcherSession.Scope.currentApplication) ?? .all : .all
        let directKeys = store.configuration.mode == .keyWindow
        let assignedEntries = directKeys ? store.assignShortcuts(to: entries) : entries
        var value = WindowSwitcherSession(entries: assignedEntries, selectedID: appCatalog.focusedWindowID,
            scope: scope, isPersistent: persistent, originalWindowID: appCatalog.focusedWindowID)
        value.usesDirectKeys = directKeys
        value.protectedCommandKeys = store.protectedCommandKeys
        if store.configuration.protectsLegacyCommands { value.protectedCommandKeys.formUnion(["w", "q"]) }
        if currentApp, value.results.count <= 1 {
            cancelSession()
            skippedSingleWindow = true
            return
        }
        let hasFocusedTarget = value.results.contains { $0.id == value.selectedID }
        value.normalizeSelection()
        if !persistent || (!directKeys && store.configuration.sortMode == .recentUse) {
            value.invocationModifiers = invocationModifiers(currentApp: currentApp)
            let delta = steps ?? (reversed ? -1 : 1)
            value.advance(!hasFocusedTarget && delta > 0 ? delta - 1 : delta)
        }
        session = value
        shortcutTap.setEditing(directKeys)
        let generation = sessionGeneration
        // A quick release after invocation reconciliation commits without flashing UI.
        showTask?.cancel()
        showTask = Task { [weak self] in
            if !persistent { try? await Task.sleep(for: .milliseconds(140)) }
            guard !Task.isCancelled, let self, sessionGeneration == generation, let session else { return }
            overlayController.show(session, currentPID: invocationPID, showsPreview: store.configuration.showsPreview,
                                   preferredLayout: store.configuration.preferredLayout, mode: store.configuration.mode)
        }
    }

    private func catalogDidChange() {
        guard isActive else { return }
        refreshAccessibilityPermission()
        guard isAccessibilityGranted, pendingInvocation != nil || session != nil else { return }
        let entries = appCatalog.entries(sortMode: store.configuration.sortMode)
        if let pending = pendingInvocation, appCatalog.isInvocationReady, !entries.isEmpty {
            pendingInvocation = nil
            present(entries, reversed: pending.reversed, currentApp: pending.currentApp, persistent: pending.persistent, steps: pendingSteps)
            pendingSteps = 0
            if pendingRelease { pendingRelease = false; handleShortcutReleased() }
        } else if var session {
            session.reconcile(session.usesDirectKeys ? store.assignShortcuts(to: entries) : entries)
            session.protectedCommandKeys.formUnion(store.protectedCommandKeys)
            self.session = session
            if overlayController.isVisible { overlayController.update(session) }
        }
        // Window contents and recency belong to the switcher session. Permission
        // and settings changes notify the host through their own mutation paths.
    }

    private func select(_ entry: WindowSwitcherAppEntry) {
        let intent = WindowSwitcherActivationIntent(targetPID: entry.processIdentifier)
        showTask?.cancel()
        session = nil
        shortcutTap.setSessionActive(false)
        shortcutTap.setEditing(false)
        sessionGeneration += 1
        let generation = sessionGeneration
        overlayController.hide(restoringFocus: false)
        actionTask?.cancel()
        actionTask = Task { [weak self] in
            defer { intent.finish() }
            guard let self, !Task.isCancelled else { return }
            guard intent.shouldContinue() else { return }
            let result = await appCatalog.activate(entry, intent: intent)
            guard sessionGeneration == generation, !Task.isCancelled else { return }
            lastError = WindowSwitcherDiagnostic(actionResult: result)
            // A late verification failure must not steal focus back after
            // the user has already switched. Keep the error in settings.
            onStateChange?()
        }
    }

    private func close(_ entry: WindowSwitcherAppEntry) {
        let generation = sessionGeneration
        actionTask?.cancel()
        actionTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let result = await appCatalog.closeWindow(entry)
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            if let diagnostic = WindowSwitcherDiagnostic(actionResult: result) { overlayController.showMessage(diagnostic) }
        }
    }

    private func quit(_ entry: WindowSwitcherAppEntry) {
        let result = appCatalog.quitApplication(entry)
        if let diagnostic = WindowSwitcherDiagnostic(actionResult: result) { overlayController.showMessage(diagnostic) }
        // Keep rows until the catalog confirms termination; save dialogs may cancel it.
    }

    private func cancelSession() {
        shortcutTap.setSessionActive(false)
        shortcutTap.setEditing(false)
        sessionGeneration += 1
        showTask?.cancel(); showTask = nil
        actionTask?.cancel(); actionTask = nil
        pendingInvocation = nil; pendingRelease = false; pendingSteps = 0
        overlayController.hide()
        session = nil
    }

    private func ensureAccessibilityForInvocation() -> Bool {
        guard isActive, !isRecordingShortcut else { return false }
        refreshAccessibilityPermission()
        guard isAccessibilityGranted else {
            lastError = .accessibilityRequired
            requestPermissionGuidance?(WindowSwitcherConstants.accessibilityPermissionID)
            onStateChange?()
            return false
        }

        let hadError = lastErrorMessage != nil
        lastError = nil
        syncShortcutTap()
        if hadError { onStateChange?() }
        return true
    }

    private func handleAccessibilityPermissionAction() {
        if isAccessibilityGranted {
            refreshAccessibilityPermission()
            return
        }

        isAccessibilityGranted = requestAccessibilityTrust(true)
        if isAccessibilityGranted {
            lastError = nil
            syncShortcutTap()
        } else {
            lastError = .accessibilityRequired
        }
        onStateChange?()
    }

    private func invocationModifiers(currentApp: Bool) -> NSEvent.ModifierFlags {
        let id = currentApp ? WindowSwitcherConstants.currentAppShortcutID : WindowSwitcherConstants.shortcutDefinitionID
        let fallback = currentApp ? (store.configuration.usesCompanionDefaults ? WindowSwitcherShortcutBindingStore.currentAppBinding : nil) : allWindowsDefaultBinding
        let binding: ShortcutBinding?
        if let shortcutBindingResolver { binding = shortcutBindingResolver(id) }
        else { binding = WindowSwitcherShortcutBindingStore.resolvedBinding(id: id, defaultBinding: fallback) }
        guard let modifiers = binding?.modifiers else { return [] }
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }

    private func configureShortcutBindings() {
        guard !isRecordingShortcut else {
            shortcutTap.configure(allBinding: nil, currentAppBinding: nil)
            return
        }
        func resolve(_ id: String, defaultBinding: ShortcutBinding?) -> ShortcutBinding? {
            // A host-supplied nil is authoritative, including conflict suppression.
            if let shortcutBindingResolver { return shortcutBindingResolver(id) }
            return WindowSwitcherShortcutBindingStore.resolvedBinding(id: id, defaultBinding: defaultBinding)
        }
        shortcutTap.configure(allBinding: resolve(WindowSwitcherConstants.shortcutDefinitionID, defaultBinding: allWindowsDefaultBinding),
            currentAppBinding: resolve(WindowSwitcherConstants.currentAppShortcutID,
                defaultBinding: store.configuration.usesCompanionDefaults ? WindowSwitcherShortcutBindingStore.currentAppBinding : nil))
    }

    func setShortcutRecording(_ recording: Bool) {
        isRecordingShortcut = recording && isActive
        if isRecordingShortcut { cancelSession() }
        syncShortcutTap()
    }

    private func syncShortcutTap() {
        configureShortcutBindings()
        if isActive && !isRecordingShortcut && store.configuration.isEnabled && isAccessibilityGranted {
            appCatalog.start()
            shortcutTap.start()
            if !shortcutTap.isRunning { lastError = .shortcutTapUnavailable }
        } else {
            shortcutTap.stop()
            appCatalog.stop()
        }
    }

    private var allWindowsDefaultBinding: ShortcutBinding {
        store.configuration.usesCompanionDefaults
            ? WindowSwitcherShortcutBindingStore.defaultBinding
            : WindowSwitcherShortcutBindingStore.legacyBinding
    }
}
