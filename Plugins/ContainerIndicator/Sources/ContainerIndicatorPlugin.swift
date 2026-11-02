import AppKit
import MacToolsPluginKit
import SwiftUI

public final class ContainerIndicatorPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        ContainerIndicatorPluginProvider(context: context)
    }
}

@MainActor
private struct ContainerIndicatorPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let controller = ContainerIndicatorController(localization: localization)
        return [
            ContainerIndicatorPlugin(
                controller: controller,
                localization: localization,
                storage: context.storage
            ),
        ]
    }
}

/// Panel-only entry point for Apple's `container` CLI: a single dashboard card
/// shows the container service status with start/stop controls, plus the
/// container and machine lists with their own lifecycle buttons.
@MainActor
final class ContainerIndicatorPlugin: MacToolsPlugin {
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    let metadata: PluginMetadata
    let controller: ContainerIndicatorController
    let localization: PluginLocalization

    private var visibleItemIDs = Set<String>()
    /// The configuration window keeps polling alive on its own: the panel is
    /// often dismissed while the inspector stays on screen.
    private let detailPresenter = ContainerIndicatorDetailPresenter()
    private var detailWindowIsOpen = false

    private let storage: any PluginStorage
    private let installedTerminalApplications: () -> [ContainerTerminalApplication]
    private var terminalApplication: ContainerTerminalApplication

    private enum ItemID {
        static let widget = "overview"
    }

    private enum ControlID {
        static let terminalApplication = "terminal-application"
    }

    private enum StorageKey {
        static let terminalApplication = "terminal.application.v1"
    }

    init(
        controller: ContainerIndicatorController,
        localization: PluginLocalization,
        storage: (any PluginStorage)? = nil,
        installedTerminalApplications: (() -> [ContainerTerminalApplication])? = nil
    ) {
        let resolvedStorage = storage
            ?? UserDefaultsPluginStorage(pluginID: "container-indicator")
        let resolvedInstalledApplications = installedTerminalApplications
            ?? { ContainerTerminalApplicationCatalog.installedApplications() }
        self.controller = controller
        self.localization = localization
        self.storage = resolvedStorage
        self.installedTerminalApplications = resolvedInstalledApplications
        let storedApplication = resolvedStorage.string(forKey: StorageKey.terminalApplication)
            .flatMap(ContainerTerminalApplication.init(rawValue:))
        // Prefer a terminal that can add a tab to the existing window when the
        // user has not chosen one yet. Terminal.app has no such command, so it
        // remains the fallback instead of the default.
        let preferredApplication = resolvedInstalledApplications()
            .first(where: { $0 == .ghostty || $0 == .iterm })
            ?? .systemDefault
        let selectedApplication = storedApplication ?? preferredApplication
        self.terminalApplication = selectedApplication
        self.metadata = PluginMetadata(
            id: "container-indicator",
            title: localization.string("metadata.title", defaultValue: "Apple Container状态"),
            iconName: "shippingbox",
            iconTint: Color(nsColor: .systemBlue),
            order: 75,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "监控并管理 container 服务、容器与虚拟机"
            )
        )
        controller.terminalApplication = selectedApplication
        controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
        detailPresenter.onVisibilityChange = { [weak self] isVisible in
            guard let self else { return }
            let wasMonitoring = detailWindowIsOpen || !visibleItemIDs.isEmpty
            detailWindowIsOpen = isVisible
            let isMonitoring = isVisible || !visibleItemIDs.isEmpty
            if isMonitoring, !wasMonitoring {
                controller.startMonitoring()
            } else if !isMonitoring, wasMonitoring {
                controller.stopMonitoring()
            }
        }
    }

    // MARK: - Panel

    var panelItems: [PluginPanelItem] {
        [
            .widget(
                id: ItemID.widget,
                initialPlacement: .dashboard,
                descriptor: widgetDescriptor,
                state: widgetState,
                content: { [weak self] context in
                    guard let self else { return AnyView(EmptyView()) }
                    return AnyView(
                        ContainerIndicatorWidgetCard(
                            controller: controller,
                            localization: localization,
                            pluginTitle: metadata.title,
                            reportContentHeight: context.reportContentHeight,
                            openDetails: { [weak self] container in
                                self?.openDetails(container)
                            }
                        )
                    )
                }
            )
            .onVisibilityChange { [weak self] isVisible in
                self?.updateVisibility(of: ItemID.widget, isVisible: isVisible)
            },
        ]
    }

    private var widgetDescriptor: PluginPanelWidgetDescriptor {
        // Fallback span before the first height report; the host then resizes
        // the card from the intrinsic height reported by the widget content.
        PluginPanelWidgetDescriptor(
            span: PluginPanelWidgetSpan(
                width: 4,
                height: PluginPanelWidgetLayoutMetrics.default.heightSpan(
                    fittingContentHeight: ContainerIndicatorWidgetLayout.cardContentHeight
                )
            )!
        )
    }

    private var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(
            subtitle: controller.statusText,
            isActive: controller.snapshot.status == .running,
            isEnabled: controller.isCommandAvailable,
            isAvailable: true,
            errorMessage: controller.lastErrorMessage
        )
    }

    private func updateVisibility(of itemID: String, isVisible: Bool) {
        let wasMonitoring = detailWindowIsOpen || !visibleItemIDs.isEmpty
        if isVisible {
            visibleItemIDs.insert(itemID)
        } else {
            visibleItemIDs.remove(itemID)
        }
        let isMonitoring = detailWindowIsOpen || !visibleItemIDs.isEmpty
        if isMonitoring, !wasMonitoring {
            controller.startMonitoring()
        } else if !isMonitoring, wasMonitoring {
            controller.stopMonitoring()
        }
    }

    // MARK: - Settings

    var settingsPage: PluginSettingsPage? {
        var applications = installedTerminalApplications()
        if !applications.contains(.systemDefault) {
            applications.insert(.systemDefault, at: 0)
        }
        // A terminal removed since the setting was saved must not leave the
        // picker pointing at an option that is no longer listed.
        let selection = applications.contains(terminalApplication)
            ? terminalApplication
            : .systemDefault
        let options = applications.map { application in
            PluginSettingsOption(
                id: application.optionID,
                title: localization.string(
                    application.localizationKey,
                    defaultValue: application.defaultTitle
                )
            )
        }

        return .form(
            description: localization.string(
                "settings.description",
                defaultValue: "监控并管理 container 服务、容器与虚拟机。"
            ),
            sections: [
                PluginSettingsSection(
                    id: "terminal",
                    title: localization.string("settings.terminal.title", defaultValue: "终端"),
                    systemImage: "terminal",
                    footer: localization.string(
                        "settings.terminal.footer",
                        defaultValue: "仅列出已安装的终端应用；选择系统默认时由 macOS 决定打开方式。"
                    ),
                    rows: [
                        PluginSettingsRow(
                            id: ControlID.terminalApplication,
                            title: localization.string(
                                "settings.terminal.application.title",
                                defaultValue: "终端应用"
                            ),
                            description: localization.string(
                                "settings.terminal.application.description",
                                defaultValue: "打开容器或虚拟机交互式终端时使用的应用。"
                            ),
                            systemImage: "macwindow",
                            control: .picker(
                                selectionID: selection.optionID,
                                options: options,
                                style: .menu
                            )
                        ),
                    ]
                ),
            ]
        )
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard case let .setSelection(controlID, optionID) = action,
              controlID == ControlID.terminalApplication,
              let application = ContainerTerminalApplication(rawValue: optionID)
        else {
            return
        }

        terminalApplication = application
        controller.terminalApplication = application
        storage.set(application.rawValue, forKey: StorageKey.terminalApplication)
        onStateChange?()
    }

    // MARK: - Details

    private func openDetails(_ container: ContainerInstance) {
        detailPresenter.present(
            container: container,
            controller: controller,
            localization: localization
        )
    }

    // MARK: - Lifecycle

    func activate(context: PluginRuntimeContext) {
        controller.refreshNow()
    }

    func deactivate(reason: PluginDeactivationReason) {
        detailPresenter.close()
        detailWindowIsOpen = false
        controller.stopMonitoring()
    }

    func refresh() {
        controller.refreshNow()
    }
}
