// SPDX-License-Identifier: GPL-3.0-only
// Restored and adapted for MacTools on 2026-09-07.

import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import MacToolsPluginKit

public final class MenuBarHiddenPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        MenuBarHiddenPluginProvider(context: context)
    }
}

@MainActor
private struct MenuBarHiddenPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            MenuBarHiddenPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class MenuBarHiddenPlugin: MacToolsPlugin, PluginActionProviding, MenuBarHostStatusItemRecovering {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("control") }
                    else { self?.panelItemDidBecomeHidden("control") }
                },
            .widget(id: "widget", initialPlacement: .dashboard,
                    descriptor: descriptor, state: widgetState,
                    content: { [weak self] context in
                        self?.makeView(context: context) ?? AnyView(EmptyView())
                    })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("widget") }
                    else { self?.panelItemDidBecomeHidden("widget") }
                },
        ]
    }

    private enum ActionID {
        static let setEnabled = "set-enabled"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: MenuBarHiddenConstants.pluginID,
            title: localization.string("metadata.title", defaultValue: "隐藏菜单栏图标"),
            iconName: "menubar.arrow.up.rectangle",
            iconTint: Color(nsColor: .systemBlue),
            order: 12,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "隐藏菜单栏图标并支持拖拽布局与点击转发"
            )
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var descriptor: PluginPanelWidgetDescriptor {
        let items = controller.snapshot.hiddenItems + controller.snapshot.alwaysHiddenItems
        let height = MenuBarHiddenComponentIconLayout.spanHeight(
            forItems: items,
            iconCache: controller.manager.iconCache
        )
        return PluginPanelWidgetDescriptor(
            span: PluginPanelWidgetSpan(width: 4, height: height)!
        )
    }

    private let context: PluginRuntimeContext
    private let localization: PluginLocalization
    private let controller: MenuBarHiddenController
    private var launchObserver: NSObjectProtocol?

    var hostStatusItemFrameProvider: (() -> NSRect?)? {
        get { controller.manager.hostStatusItemFrameProvider }
        set {
            controller.manager.hostStatusItemFrameProvider = newValue
            activateAfterHostStatusItem()
        }
    }

    var resetHostStatusItemPosition: (() -> Void)? {
        get { controller.manager.resetHostStatusItemPosition }
        set { controller.manager.resetHostStatusItemPosition = newValue }
    }

    var onStateChange: (() -> Void)? {
        didSet {
            controller.onStateChange = onStateChange
            controller.manager.iconCache.onLayoutMetricsChange = onStateChange
        }
    }

    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: MenuBarHiddenConstants.pluginID),
        controller: MenuBarHiddenController? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.context = context
        self.localization = localization
        let ctrl = controller ?? MenuBarHiddenController(context: context, localization: localization)
        self.controller = ctrl

        if controller != nil {
            ctrl.activate()
        }
    }

    // MARK: - Lifecycle

    func activate(context _: PluginRuntimeContext) {
        activateAfterHostStatusItem()
    }

    func deactivate(reason: PluginDeactivationReason) {
        guard reason.requiresStateCleanup else { return }
        if let launchObserver {
            NotificationCenter.default.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        controller.setHiddenIconsPanelVisible(false)
        controller.deactivate()
    }

    func panelItemDidBecomeVisible(_ surface: String) {
        guard surface == "widget" else {
            return
        }

        controller.setHiddenIconsPanelVisible(true)
        controller.refreshPermissions()
    }

    func panelItemDidBecomeHidden(_ surface: String) {
        guard surface == "widget" else {
            return
        }

        controller.setHiddenIconsPanelVisible(false)
    }

    private func activateAfterHostStatusItem() {
        // The host app's NSStatusItem is created inside applicationDidFinishLaunching.
        // NSStatusBar inserts later items to the LEFT of earlier ones, so we must
        // install the divider AFTER the host icon exists. Otherwise expanding the
        // divider would push our own icon off-screen.
        if hostStatusItemFrameProvider?() != nil {
            DispatchQueue.main.async { [weak self] in
                self?.controller.activate()
            }
        } else if launchObserver == nil {
            launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.activateAfterHostStatusItem() }
            }
        }
    }

    // MARK: - Panel state

    var rowState: PluginPanelRowState {
        return PluginPanelRowState(
            subtitle: controller.panelSubtitle,
            isOn: controller.isEnabled,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var widgetState: PluginPanelWidgetState {
        let shouldShowHiddenIconsCard = controller.currentPermissions().canManageItems
            && controller.showsHiddenIconsInPanel
        return PluginPanelWidgetState(
            subtitle: shouldShowHiddenIconsCard ? controller.componentSubtitle : "",
            isActive: controller.isEnabled,
            isEnabled: shouldShowHiddenIconsCard,
            isAvailable: shouldShowHiddenIconsCard,
            errorMessage: nil
        )
    }

    // MARK: - Permissions
    //
    // The toggle works without permissions; only drag-reorder and click
    // forwarding need them. The host UI uses these to display permission
    // status cards.

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: "accessibility",
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于合成鼠标事件以拖拽菜单栏图标并转发点击"
                )
            ),
            PluginPermissionRequirement(
                id: "screen-recording",
                kind: .screenRecording,
                title: localization.string("permission.screenRecording.title", defaultValue: "屏幕录制"),
                description: localization.string(
                    "permission.screenRecording.description",
                    defaultValue: "用于捕获菜单栏图标的真实外观，仅授权后才能在面板中查看与点击"
                )
            ),
        ]
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        let permissions = controller.currentPermissions()
        switch permissionID {
        case "accessibility":
            let granted = permissions.hasAccessibility
            return PluginPermissionState(
                isGranted: granted,
                footnote: granted ? nil : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "未授权时仍可使用隐藏开关，但无法拖拽或转发点击"
                )
            )
        case "screen-recording":
            let granted = permissions.hasScreenRecording
            return PluginPermissionState(
                isGranted: granted,
                footnote: granted ? nil : localization.string(
                    "permission.screenRecording.footnote",
                    defaultValue: "未授权时仍可使用隐藏开关，但布局栏与弹窗不可用"
                )
            )
        default:
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
    }

    func handlePermissionAction(id permissionID: String) {
        controller.refreshPermissions()
        switch permissionID {
        case "accessibility":
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        case "screen-recording":
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        default:
            break
        }
    }

    // MARK: - Configuration

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "menu bar"],
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
                reference: actionReference(enabled: true),
                title: "\(metadata.title) · \(localization.string("panel.subtitle.enabled", defaultValue: "已启用"))"
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: "\(metadata.title) · \(localization.string("panel.subtitle.disabled", defaultValue: "已关闭"))"
            ),
        ]
    }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(
                id: "behavior",
                title: controller.localization.string("settings.behavior.title", defaultValue: "行为"),
                systemImage: "switch.2",
                presentation: .edgeToEdge
            ) { [controller] _ in
                MenuBarHiddenSettingsView(controller: controller, section: .behavior)
            },
            PluginSettingsSection(
                id: "layout",
                title: controller.localization.string("settings.layout.title", defaultValue: "菜单栏布局"),
                systemImage: "rectangle.split.2x1",
                presentation: .edgeToEdge
            ) { [controller] _ in
                MenuBarHiddenSettingsView(controller: controller, section: .layout)
            }
        ])
        .onVisibilityChange { [controller] isVisible in
            controller.setSettingsVisible(isVisible)
        }
    }

    // MARK: - Actions

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(enabled) = action else { return }
        controller.isEnabled = enabled
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard invocation.reference.key.actionID == ActionID.setEnabled,
              case let .boolean(enabled)? = invocation.reference.parameters["enabled"] else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        return ActionExecutionHandle { [weak self] in
            guard let self else {
                return .failed(message: PluginKitLocalization.actionUnavailable)
            }
            return self.controller.setEnabled(enabled) == .committed
                ? .succeeded()
                : .failed(message: PluginKitLocalization.actionFailed)
        }
    }

    // MARK: - Component panel

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
        AnyView(
            MenuBarHiddenComponentView(
                controller: controller,
                context: context
            )
        )
    }

    private func actionReference(enabled: Bool) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
            parameters: try! ActionParameterSet(["enabled": .boolean(enabled)])
        )
    }
}
