import AppKit
import MacToolsPluginKit
import SwiftUI

public final class ScreenshotPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        ScreenshotPluginProvider(context: context)
    }
}

@MainActor
private struct ScreenshotPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [ScreenshotPlugin(context: context)]
    }
}

@MainActor
final class ScreenshotPlugin: MacToolsPlugin, PluginActionProviding, PluginActionPermissionProviding, PluginActionShortcutSettingsProviding, PluginLegacyActionShortcutProviding, DisplayTopologyRefreshing {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    private enum ID {
        static let plugin = "screenshot"
        static let capture = "capture"
        static let quickCapture = "quick-capture"
        static let shortcutPlacement = "shortcut-placement"
        static let execute = "execute"
        static let permission = "screen-recording"
        static let folder = "save-folder"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: ID.plugin,
            title: environment.string("metadata.title", "截图"),
            iconName: "camera.viewfinder",
            iconTint: Color(nsColor: .systemBlue),
            order: 105,
            defaultDescription: environment.string("metadata.summary", "截图、标注、提取文字与录屏")
        )
    }
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let environment: ScreenshotEnvironment
    private let coordinator: ScreenshotCoordinator
    private let screenAccess: @MainActor () -> Bool
    private let requestScreenAccess: @MainActor () -> Void
    private let capture: @MainActor (Bool) -> Void
    private let folderPicker: @MainActor (URL) -> URL?
    private var isGranted: Bool
    private var isActive = true
    private var lastError: String?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "screenshot"),
        screenAccess: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        requestScreenAccess: @escaping @MainActor () -> Void = ScreenshotPlugin.openScreenCaptureSettings,
        capture: (@MainActor (Bool) -> Void)? = nil,
        folderPicker: (@MainActor (URL) -> URL?)? = nil
    ) {
        let environment = ScreenshotEnvironment(context: context)
        let coordinator = ScreenshotCoordinator(environment: environment)
        self.environment = environment
        self.coordinator = coordinator
        self.screenAccess = screenAccess
        self.requestScreenAccess = requestScreenAccess
        self.capture = capture ?? { [weak coordinator] quick in coordinator?.capture(quick: quick) }
        self.folderPicker = folderPicker ?? { folder in
            Self.chooseFolder(folder, environment: environment)
        }
        self.isGranted = screenAccess()
        coordinator.onStateChange = { [weak self] in self?.onStateChange?() }
        coordinator.onError = { [weak self] message in
            self?.lastError = message
            self?.onStateChange?()
        }
    }

    var rowDescriptor: PluginPanelRowDescriptor {
        PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitle: coordinator.isRecording
                ? environment.string("panel.stopRecording", "停止录屏")
                : coordinator.isScrolling
                    ? environment.string("panel.finishScrolling", "完成")
                    : environment.string("action.capture.title", "截图")
        )
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: coordinator.isBusy,
            isEnabled: isActive && (!coordinator.isBusy || canFinishSession),
            isAvailable: true,
            detail: nil,
            errorMessage: lastError
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [PluginPermissionRequirement(
            id: ID.permission,
            kind: .screenRecording,
            title: environment.string("permission.screenRecording.title", "录屏权限"),
            description: environment.string("permission.screenRecording.description", "用于截取屏幕内容和录屏，图像与识别结果仅在本机处理。")
        )]
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: ID.plugin, actionID: ID.capture),
                title: environment.string("action.capture.title", "截图"),
                description: environment.string("action.capture.description", "框选区域或窗口，标注、识别文字或二维码，也可滚动截图和录屏。"),
                keywords: [metadata.title, "screenshot", "OCR", "Snap"],
                systemImage: "camera.viewfinder",
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: ID.plugin, actionID: ID.quickCapture),
                title: environment.string("action.quickCapture.title", "快速截图"),
                description: environment.string("action.quickCapture.description", "框选后立即复制到剪贴板。"),
                keywords: [metadata.title, "screenshot", "clipboard"],
                systemImage: "camera",
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        actionDefinitions.map { definition in
            PluginShortcutDefinition(
                id: definition.key.actionID,
                title: definition.title,
                description: definition.description,
                actionID: definition.key.actionID,
                scope: .global,
                defaultBinding: nil,
                isRequired: false
            )
        }
    }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            // The host inserts the canonical action-shortcut section after this
            // zero-row anchor, keeping output settings below the shortcuts.
            PluginSettingsSection(id: ID.shortcutPlacement, rows: []),
            PluginSettingsSection(
                id: "output",
                title: environment.string("settings.output.title", "保存"),
                systemImage: "folder",
                footer: environment.string("settings.output.description", "截图完成后默认复制；使用保存按钮可保存 PNG。录屏保存为 MOV，需要 macOS 15 或更高版本。"),
                rows: [PluginSettingsRow(
                    id: ID.folder,
                    title: environment.string("settings.folder.title", "保存位置"),
                    description: environment.saveFolder.path,
                    systemImage: "folder",
                    control: .action(title: environment.string("settings.folder.choose", "选择文件夹…"), role: .normal)
                )]
            ),
        ])
    }

    var actionShortcutSettingsConfiguration: PluginActionShortcutSettingsConfiguration {
        PluginActionShortcutSettingsConfiguration(
            title: environment.string("settings.shortcuts.title", "快捷键"),
            description: environment.string(
                "settings.shortcuts.description",
                "设置截图和快速截图的全局快捷键。"
            ),
            actionIDs: [ID.capture, ID.quickCapture],
            placementAfterSectionID: ID.shortcutPlacement
        )
    }

    var legacyActionShortcutAssignments: [LegacyActionShortcutAssignment] {
        shortcutDefinitions.compactMap { definition in
            guard let binding = shortcutBindingResolver?(definition.id) else { return nil }
            return LegacyActionShortcutAssignment(
                reference: ActionReference(
                    key: ActionKey(providerID: ID.plugin, actionID: definition.actionID)
                ),
                binding: binding,
                legacyShortcutDefinitionID: definition.id
            )
        }
    }

    func legacyActionShortcutsDidMigrate() {}

    func refresh() {
        let granted = screenAccess()
        guard granted != isGranted else { return }
        isGranted = granted
        if granted {
            lastError = nil
        } else {
            coordinator.cancel()
        }
        onStateChange?()
    }

    func activate(context: PluginRuntimeContext) {
        isActive = true
        refresh()
        coordinator.prepareCaptureSurfaces()
        onStateChange?()
    }

    func refreshDisplayTopology() {
        guard isActive else { return }
        coordinator.refreshDisplayTopology()
    }

    func deactivate(reason: PluginDeactivationReason) {
        isActive = false
        coordinator.cancel()
        lastError = nil
        onStateChange?()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(
            isGranted: permissionID != ID.permission || isGranted,
            footnote: permissionID == ID.permission && !isGranted ? permissionGuidance : nil
        )
    }

    func handlePermissionAction(id: String) {
        guard id == ID.permission else { return }
        requestScreenAccess()
        refresh()
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        isKnownAction(actionKey) ? [ID.permission] : []
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard isKnownAction(reference.key), reference.schemaVersion == 1, isActive else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        if canFinishSession { return .available }
        guard isGranted else { return .unavailable(permissionGuidance) }
        guard !coordinator.isBusy else { return .unavailable(panelSubtitle) }
        return .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { [weak self] in
            guard let self, !Task.isCancelled else { return .cancelled }
            guard invocation.mode == .foreground, invocation.source != .automaticRule else {
                return .failed(message: PluginKitLocalization.actionUnavailable)
            }
            let availability = actionAvailability(for: invocation.reference)
            guard availability.isAvailable else {
                return .failed(message: availability.reason ?? PluginKitLocalization.actionUnavailable)
            }
            return beginCapture(quick: invocation.reference.key.actionID == ID.quickCapture)
                ? .succeeded() : .failed(message: lastError ?? PluginKitLocalization.actionUnavailable)
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case .invokeAction(ID.execute) = action else { return }
        beginCapture(quick: false)
    }

    func handleShortcutAction(id: String) {
        guard id == ID.capture || id == ID.quickCapture else { return }
        beginCapture(quick: id == ID.quickCapture)
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard isActive, case .invoke(ID.folder) = action,
              let folder = folderPicker(environment.saveFolder), isActive, folder.isFileURL else { return }
        environment.saveFolder = folder
        onStateChange?()
    }

    @discardableResult
    private func beginCapture(quick: Bool) -> Bool {
        guard isActive else { return false }
        isGranted = screenAccess()
        guard isGranted || canFinishSession else {
            lastError = permissionGuidance
            onStateChange?()
            requestPermissionGuidance?(ID.permission)
            return false
        }
        guard !coordinator.isBusy || canFinishSession else { return false }
        lastError = nil
        capture(quick)
        onStateChange?()
        return true
    }

    private var canFinishSession: Bool { coordinator.isRecording || coordinator.isScrolling }

    private var permissionGuidance: String {
        environment.string("permission.screenRecording.guidance", "请在系统设置 → 隐私与安全性 → 录屏与系统录音（或录屏）中授权 MacTools。")
    }

    private var panelSubtitle: String {
        if coordinator.isRecording {
            return environment.string("panel.recording", "正在录屏，再次点击或使用截图快捷键停止")
        }
        if coordinator.isScrolling {
            return environment.string("panel.scrolling", "滚动页面后点击完成，或使用截图快捷键完成")
        }
        if coordinator.isBusy { return environment.string("panel.capturing", "正在截图…") }
        return isGranted ? metadata.defaultDescription : permissionGuidance
    }

    private func isKnownAction(_ key: ActionKey) -> Bool {
        key.providerID == ID.plugin && (key.actionID == ID.capture || key.actionID == ID.quickCapture)
    }

    private static func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func chooseFolder(_ current: URL, environment: ScreenshotEnvironment) -> URL? {
        let panel = NSOpenPanel()
        environment.savePanel = panel
        defer { if environment.savePanel === panel { environment.savePanel = nil } }
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = current
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
