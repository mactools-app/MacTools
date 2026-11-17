import AppKit
@preconcurrency import ApplicationServices
import SwiftUI
import MacToolsPluginKit

public final class IslandNotificationsPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        IslandNotificationsProvider(context: context)
    }
}

@MainActor
private struct IslandNotificationsProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] { [IslandNotificationsPlugin(context: context)] }
}

@MainActor
final class IslandNotificationsPlugin: MacToolsPlugin {
    private let controller: IslandNotificationsController
    private let localization: PluginLocalization
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestPermissionGuidance: ((String) -> Void)?
    var onStateChange: (() -> Void)? {
        get { controller.onStateChange }
        set { controller.onStateChange = newValue }
    }

    init(context: PluginRuntimeContext) {
        localization = PluginLocalization(bundle: context.resourceBundle)
        controller = IslandNotificationsController(storage: context.storage, localization: localization)
    }

    var metadata: PluginMetadata {
        PluginMetadata(id: "island-notifications",
                       title: localization.string("metadata.title", defaultValue: "灵动岛通知"),
                       iconName: "bell.badge.fill", iconTint: .cyan, order: 42,
                       defaultDescription: localization.string("metadata.description", defaultValue: "在灵动岛显示通知，保留通知中心历史记录。"))
    }

    var panelItems: [PluginPanelItem] {
        // The list only exists where the island does, so other Macs never get a Notifications panel.
        (controller.hasDisplay ? [historyWidget] : []) + [enabledRow]
    }

    private var historyWidget: PluginPanelItem {
        .widget(id: "history", initialPlacement: .dashboard,
                 descriptor: PluginPanelWidgetDescriptor(span: PluginPanelWidgetSpan(
                     width: PluginPanelWidgetSpan.maximumWidth,
                     height: controller.historySpan)!),
                 state: PluginPanelWidgetState(subtitle: metadata.defaultDescription, isActive: false,
                                               isEnabled: true, isAvailable: true, errorMessage: nil),
                 content: { [controller, localization] _ in
                     GeometryReader { proxy in
                         IslandNotificationHistoryView(size: proxy.size, history: controller.history, localization: localization,
                                                       onOpen: { controller.openHistory($0) },
                                                       onClear: { controller.clearHistory($0) },
                                                       onContentHeight: { controller.setHistoryContentHeight($0) })
                     }
                 })
        .onVisibilityChange { [controller] visible in
            if visible { controller.historyBecameVisible() }
        }
    }

    private var enabledRow: PluginPanelItem {
        .row(id: "enabled", initialPlacement: .featurePanel,
              descriptor: PluginPanelRowDescriptor(controlStyle: .switch, menuActionBehavior: .keepPresented),
              state: PluginPanelRowState(subtitle: status, isOn: controller.enabled, isEnabled: true, isAvailable: true, detail: nil, errorMessage: nil),
              action: { [weak self] action in
                  if case let .setSwitch(value) = action { self?.setEnabled(value) }
              })
    }

    private var status: String {
        if !controller.hasDisplay { return localization.string("status.noDisplay", defaultValue: "需要配备摄像头岛的 MacBook Pro（macOS 27 或更高版本）") }
        return controller.enabled ? localization.string("status.enabled", defaultValue: "已开启") : localization.string("status.disabled", defaultValue: "已关闭")
    }

    var settingsPage: PluginSettingsPage? {
        .form(description: localization.string("metadata.description", defaultValue: "在灵动岛显示通知，保留通知中心历史记录。"), sections: [
            PluginSettingsSection(id: "notifications", title: localization.string("metadata.title", defaultValue: "灵动岛通知"), systemImage: "bell.badge.fill", rows: [
                PluginSettingsRow(id: "enabled", title: localization.string("settings.enabled", defaultValue: "启用灵动岛通知"), description: status,
                                  systemImage: "bell.badge.fill", control: .toggle(isOn: controller.enabled)),
                PluginSettingsRow(id: "previewLines", title: localization.string("settings.previewLines", defaultValue: "预览行数"),
                                  description: localization.string("settings.previewLines.description", defaultValue: "展开前显示的消息行数。向下滚动卡片可查看全文。"),
                                  systemImage: "text.alignleft",
                                  control: .picker(selectionID: String(controller.previewLines),
                                                   options: IslandNotificationPresenter.previewLineRange.map {
                                                       PluginSettingsOption(id: String($0), title: $0.formatted(.number.locale(PluginRuntimeLocalization.locale)))
                                                   }, style: .menu)),
            ]),
        ])
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [PluginPermissionRequirement(id: "accessibility", kind: .accessibility,
                                     title: localization.string("permission.title", defaultValue: "辅助功能授权"),
                                     description: localization.string("permission.description", defaultValue: "用于读取和移动系统通知横幅。"))]
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: controller.trusted, footnote: nil)
    }

    func handlePermissionAction(id: String) {
        guard id == "accessibility" else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        controller.refresh()
    }

    private func setEnabled(_ value: Bool) {
        controller.setEnabled(value)
        if value, !controller.trusted { requestPermissionGuidance?("accessibility") }
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setBoolean(id, value) where id == "enabled": setEnabled(value)
        case let .setSelection(id, option) where id == "previewLines": Int(option).map(controller.setPreviewLines)
        default: break
        }
    }
    func activate(context: PluginRuntimeContext) { controller.activate() }
    func deactivate(reason: PluginDeactivationReason) { controller.deactivate() }
    func refresh() { controller.refresh() }
}
