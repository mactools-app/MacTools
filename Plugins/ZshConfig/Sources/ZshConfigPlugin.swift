import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

// MARK: - Bundle Factory

public final class ZshConfigPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        ZshConfigPluginProvider(context: context)
    }
}

@MainActor
private struct ZshConfigPluginProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] {
        [ZshConfigPlugin(context: context)]
    }
}

// MARK: - Control IDs

private enum ControlID {
    static let openSettings = "zsh-open-config"
}

// MARK: - Plugin

@MainActor
final class ZshConfigPlugin: MacToolsPlugin, PluginSettingsPresenting {
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
                control: .button,
                state: state,
                menuActionBehavior: descriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }


    private enum PermissionID {
        static let automation = "automation"
    }

    // MARK: Metadata

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "zsh-config",
            title: localization.string("metadata.title", defaultValue: "zsh 配置"),
            iconName: "curlybraces",
            iconTint: Color(nsColor: .systemGreen),
            order: 72,
            defaultDescription: localization.string("metadata.description", defaultValue: "快速编辑 zsh 配置文件")
        )
    }

    let rowDescriptor: PluginPanelRowDescriptor

    // MARK: Callbacks

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    // MARK: Private

    private let store: ZshConfigStore
    private let localization: PluginLocalization
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "ZshConfigPlugin"
    )

    // MARK: Init

    init(context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "zsh-config")) {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        self.store = ZshConfigStore(localization: localization)
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: { localization.string("panel.button.edit", defaultValue: "编辑") }
        )
    }

    // MARK: - MacToolsPlugin

    func activate(context: PluginRuntimeContext) {
        store.refreshStatusMap()
    }

    func refresh() {
        store.refreshStatusMap()
        onStateChange?()
    }

    // MARK: - Panel row

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case .invokeAction(controlID: "execute") = action else { return }
        requestSettingsPresentation?()
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.automation,
                kind: .automation,
                title: localization.string("permission.automation.title", defaultValue: "自动化"),
                description: localization.string(
                    "permission.automation.description",
                    defaultValue: "从终端载入配置时需要控制“终端”。"
                )
            ),
        ]
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(
            isGranted: false,
            footnote: permissionID == PermissionID.automation
                ? localization.string(
                    "permission.automation.footnote",
                    defaultValue: "macOS 会在首次从终端载入配置时请求自动化授权。"
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

    // MARK: - Configuration

    var settingsPage: PluginSettingsPage? {
        .workspace(
            description: localization.string(
                "configuration.description",
                defaultValue: "在应用内直接查看和编辑 zsh 配置文件，支持常用片段快速插入。"
            ),
            scrolling: .selfManaged
        ) { [self] _ in
            ZshConfigEditorView(store: self.store, localization: self.localization)
        }
    }

    // MARK: - Private Helpers

    private var panelSubtitle: String {
        let existing = ZshConfigFileType.allCases.filter {
            store.statusMap[$0]?.exists == true
        }
        if existing.isEmpty {
            return localization.string("panel.subtitle.noFiles", defaultValue: "未找到配置文件，点击设置创建")
        }
        return metadata.defaultDescription
    }
}
