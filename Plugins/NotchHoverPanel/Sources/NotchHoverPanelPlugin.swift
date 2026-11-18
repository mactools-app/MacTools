import AppKit
import SwiftUI
import MacToolsPluginKit

public final class NotchHoverPanelPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        NotchHoverPanelPluginProvider(context: context)
    }
}

@MainActor
private struct NotchHoverPanelPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            NotchHoverPanelPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class NotchHoverPanelPlugin: MacToolsPlugin, PluginMenuBarPanelPresenting,
    PluginAppMenuBarIconVisibilityControlling {
    private enum SettingsID {
        static let section = "hover"
        static let enabled = "enabled"
        static let showsMenuBarIcon = "show-menu-bar-icon"
        static let enableBelowTrigger = "enable-below-trigger"
        static let triggerWidth = "trigger-width"
        static let verticalTriggerReach = "vertical-trigger-reach"
        static let showDelay = "show-delay"
        static let hideDelay = "hide-delay"
        static let reset = "reset"
        static let status = "status"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "notch-hover-panel",
            title: localization.string("metadata.title", defaultValue: "灵动岛悬浮面板"),
            iconName: "rectangle.topthird.inset.filled",
            iconTint: Color(nsColor: .systemTeal),
            order: 41,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "鼠标悬停灵动岛两侧，或从灵动岛正下方往上移动时滑出 MacTools 面板"
            )
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var panelItems: [PluginPanelItem] {
        [
            .row(
                id: "control",
                initialPlacement: .featurePanel,
                descriptor: rowDescriptor,
                state: rowState,
                action: { [weak self] action in self?.handleRowAction(action) }
            ),
        ]
    }

    var settingsPage: PluginSettingsPage? {
        let snapshot = controller.snapshot
        var rows: [PluginSettingsRow] = [
            PluginSettingsRow(
                id: SettingsID.enabled,
                title: localization.string(
                    "settings.enabled.title",
                    defaultValue: "启用灵动岛悬浮面板"
                ),
                description: localization.string(
                    "settings.enabled.description",
                    defaultValue: "鼠标移入灵动岛两侧，或从灵动岛正下方往上接近灵动岛时显示 MacTools 面板。"
                ),
                systemImage: "rectangle.topthird.inset.filled",
                control: .toggle(isOn: snapshot.isEnabled)
            ),
            PluginSettingsRow(
                id: SettingsID.showsMenuBarIcon,
                title: localization.string(
                    "settings.showsMenuBarIcon.title",
                    defaultValue: "显示菜单栏图标"
                ),
                description: localization.string(
                    "settings.showsMenuBarIcon.description",
                    defaultValue: "关闭后隐藏 MacTools 菜单栏图标，可从灵动岛悬浮面板打开面板。"
                ),
                systemImage: "menubar.rectangle",
                isEnabled: snapshot.isEnabled,
                control: .toggle(isOn: snapshot.showsMenuBarIcon)
            ),
            PluginSettingsRow(
                id: SettingsID.triggerWidth,
                title: localization.string(
                    "settings.triggerWidth.title",
                    defaultValue: "触发宽度"
                ),
                description: localization.string(
                    "settings.triggerWidth.description",
                    defaultValue: "灵动岛两侧参与触发的宽度。"
                ),
                systemImage: "arrow.left.and.right",
                isEnabled: snapshot.isEnabled,
                control: .slider(
                    value: snapshot.triggerWidth,
                    range: NotchHoverGeometry.allowedTriggerWidthRange,
                    step: NotchHoverGeometry.triggerWidthStep,
                    valueFormat: PluginSettingsSliderValueFormat(suffix: " pt")
                )
            ),
            PluginSettingsRow(
                id: SettingsID.enableBelowTrigger,
                title: localization.string(
                    "settings.enableBelowTrigger.title",
                    defaultValue: "启用下方触发"
                ),
                description: localization.string(
                    "settings.enableBelowTrigger.description",
                    defaultValue: "从灵动岛正下方往上移动时也显示面板。"
                ),
                systemImage: "arrow.up.to.line",
                isEnabled: snapshot.isEnabled,
                control: .toggle(isOn: snapshot.isBelowTriggerEnabled)
            ),
            PluginSettingsRow(
                id: SettingsID.verticalTriggerReach,
                title: localization.string(
                    "settings.verticalTriggerReach.title",
                    defaultValue: "下方触发高度"
                ),
                description: localization.string(
                    "settings.verticalTriggerReach.description",
                    defaultValue: "灵动岛正下方参与触发的区域高度，向上滑动接近灵动岛时也会显示面板。"
                ),
                systemImage: "arrow.up.to.line",
                isEnabled: snapshot.isEnabled && snapshot.isBelowTriggerEnabled,
                control: .slider(
                    value: snapshot.verticalTriggerReach,
                    range: NotchHoverGeometry.allowedVerticalTriggerReachRange,
                    step: NotchHoverGeometry.verticalTriggerReachStep,
                    valueFormat: PluginSettingsSliderValueFormat(suffix: " pt")
                )
            ),
            PluginSettingsRow(
                id: SettingsID.showDelay,
                title: localization.string(
                    "settings.showDelay.title",
                    defaultValue: "显示延迟"
                ),
                description: localization.string(
                    "settings.showDelay.description",
                    defaultValue: "停留多久后滑出面板，避免误触。"
                ),
                systemImage: "timer",
                isEnabled: snapshot.isEnabled,
                control: .slider(
                    value: snapshot.showDelay,
                    range: 0...0.8,
                    step: 0.05,
                    valueFormat: PluginSettingsSliderValueFormat(suffix: " s")
                )
            ),
            PluginSettingsRow(
                id: SettingsID.hideDelay,
                title: localization.string(
                    "settings.hideDelay.title",
                    defaultValue: "隐藏延迟"
                ),
                description: localization.string(
                    "settings.hideDelay.description",
                    defaultValue: "鼠标离开后面板自动收起前的等待时间。"
                ),
                systemImage: "arrow.down.forward.and.arrow.up.backward",
                isEnabled: snapshot.isEnabled,
                control: .slider(
                    value: snapshot.hideDelay,
                    range: 0.05...1,
                    step: 0.05,
                    valueFormat: PluginSettingsSliderValueFormat(suffix: " s")
                )
            ),
            PluginSettingsRow(
                id: SettingsID.reset,
                title: localization.string(
                    "settings.reset.title",
                    defaultValue: "恢复默认设置"
                ),
                description: localization.string(
                    "settings.reset.description",
                    defaultValue: "将触发范围、显示延迟和菜单栏图标恢复为初始状态。"
                ),
                systemImage: "arrow.counterclockwise",
                control: .action(
                    title: localization.string(
                        "settings.reset.action",
                        defaultValue: "恢复默认"
                    ),
                    role: .normal
                )
            ),
        ]

        if !snapshot.hasSupportedDisplay {
            rows.append(
                PluginSettingsRow(
                    id: SettingsID.status,
                    title: localization.string(
                        "settings.status.title",
                        defaultValue: "灵动岛支持"
                    ),
                    description: localization.string(
                        "settings.status.noDisplay.description",
                        defaultValue: "连接带灵动岛的 Mac 屏幕后即可使用。"
                    ),
                    systemImage: "exclamationmark.triangle",
                    control: .status(
                        text: localization.string(
                            "settings.status.unavailable",
                            defaultValue: "未检测到"
                        ),
                        systemImage: "exclamationmark.triangle",
                        tone: .caution,
                        actionTitle: nil
                    )
                )
            )
        }

        return .form(
            description: localization.string(
                "settings.description",
                defaultValue: "面板沿用最近使用的主面板内容，鼠标离开面板和灵动岛区域后自动收起。"
            ),
            sections: [
                PluginSettingsSection(
                    id: SettingsID.section,
                    title: localization.string("settings.section", defaultValue: "悬浮行为"),
                    systemImage: "rectangle.topthird.inset.filled",
                    footer: localization.string(
                        "settings.footer",
                        defaultValue: "悬停灵动岛两侧，或从灵动岛正下方往上移动，即可显示面板；将鼠标移入面板可保持显示。"
                    ),
                    rows: rows
                ),
            ]
        )
    }

    var onStateChange: (() -> Void)? {
        get { controller.onStateChange }
        set { controller.onStateChange = newValue }
    }

    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var requestMenuBarPanelPresentation:
        ((PluginMenuBarPanelPresentationRequest) -> Bool)? {
        get { controller.requestMenuBarPanelPresentation }
        set { controller.requestMenuBarPanelPresentation = newValue }
    }

    var requestMenuBarPanelDismissal: ((_ animated: Bool) -> Bool)? {
        get { controller.requestMenuBarPanelDismissal }
        set { controller.requestMenuBarPanelDismissal = newValue }
    }

    var presentedMenuBarPanelScreenFrame: (() -> NSRect?)? {
        get { controller.presentedMenuBarPanelScreenFrame }
        set { controller.presentedMenuBarPanelScreenFrame = newValue }
    }

    var isPresentedMenuBarPanelVisible: (() -> Bool)? {
        get { controller.isPresentedMenuBarPanelVisible }
        set { controller.isPresentedMenuBarPanelVisible = newValue }
    }

    var requestAppMenuBarIconVisibility: ((Bool) -> Void)? {
        get { controller.requestAppMenuBarIconVisibility }
        set { controller.requestAppMenuBarIconVisibility = newValue }
    }

    private let controller: any NotchHoverPanelControlling
    private let localization: PluginLocalization

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "notch-hover-panel"),
        controller: (any NotchHoverPanelControlling)? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.controller = controller ?? NotchHoverPanelController(storage: context.storage)
    }

    var rowState: PluginPanelRowState {
        let snapshot = controller.snapshot
        let subtitle: String

        if !snapshot.isEnabled {
            subtitle = localization.string("panel.subtitle.disabled", defaultValue: "已关闭")
        } else if !snapshot.hasSupportedDisplay {
            subtitle = localization.string("panel.subtitle.noDisplay", defaultValue: "未检测到灵动岛")
        } else {
            subtitle = localization.string("panel.subtitle.enabled", defaultValue: "已开启")
        }

        return PluginPanelRowState(
            subtitle: subtitle,
            isOn: snapshot.isEnabled,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    func activate(context _: PluginRuntimeContext) {
        controller.activate()
    }

    func deactivate(reason: PluginDeactivationReason) {
        controller.deactivate()
    }

    func refresh() {
        controller.refresh()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setBoolean(controlID, value) where controlID == SettingsID.enabled:
            controller.setEnabled(value)
        case let .setBoolean(controlID, value) where controlID == SettingsID.showsMenuBarIcon:
            controller.setShowsMenuBarIcon(value)
        case let .setBoolean(controlID, value) where controlID == SettingsID.enableBelowTrigger:
            controller.setEnableBelowTrigger(value)
        case let .invoke(controlID) where controlID == SettingsID.reset:
            controller.resetToDefaults()
        case let .setNumber(controlID, value, phase) where phase == .committed:
            switch controlID {
            case SettingsID.triggerWidth:
                controller.setTriggerWidth(value)
            case SettingsID.verticalTriggerReach:
                controller.setVerticalTriggerReach(value)
            case SettingsID.showDelay:
                controller.setShowDelay(value)
            case SettingsID.hideDelay:
                controller.setHideDelay(value)
            default:
                break
            }
        default:
            break
        }
    }

    private func handleRowAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else { return }
        controller.setEnabled(isEnabled)
    }
}
