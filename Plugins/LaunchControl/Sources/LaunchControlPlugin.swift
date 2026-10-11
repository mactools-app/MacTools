import Foundation
import SwiftUI
import MacToolsPluginKit

public final class LaunchControlPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        LaunchControlPluginProvider(context: context)
    }
}

@MainActor
private struct LaunchControlPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let controller = LaunchControlController(context: context, localization: localization)
        return [LaunchControlPlugin(context: context, controller: controller, localization: localization)]
    }
}

@MainActor
final class LaunchControlPlugin:
    MacToolsPlugin, PluginSettingsPresenting, PluginSettingsSearchFocusing, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    private enum ActionID {
        static let start = "start-favorite"
        static let stop = "stop-favorite"
        static let restart = "restart-favorite"
        static let itemIDParameter = "item-id"
    }

    enum ControlID {
        static let refresh = "launch-control-refresh"
        static let openManager = "launch-control-open-manager"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "launch-control",
            title: localization.string("metadata.title", defaultValue: "启动项"),
            iconName: "powerplug",
            iconTint: Color(nsColor: .systemOrange),
            order: 95,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "查看和管理 launchctl 启动项"
            )
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    private let controller: LaunchControlController
    private let localization: PluginLocalization
    private let settingsSearchFocusController = LaunchControlSettingsSearchFocusController()
    private var isExpanded = false

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "launch-control"),
        controller: LaunchControlController? = nil,
        localization: PluginLocalization? = nil
    ) {
        let localization = localization ?? PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        self.controller = controller ?? LaunchControlController(context: context, localization: localization)
        self.controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    var rowState: PluginPanelRowState {
        let snapshot = controller.snapshot
        return PluginPanelRowState(
            subtitle: subtitle(for: snapshot),
            isOn: snapshot.isRefreshing,
            isEnabled: true,
            isAvailable: true,
            detail: isExpanded ? buildDetail(for: snapshot) : nil,
            errorMessage: snapshot.errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }
    var actionDefinitions: [ActionDefinition] {
        [
            favoriteActionDefinition(action: .start, actionID: ActionID.start, risk: .safe),
            favoriteActionDefinition(action: .stop, actionID: ActionID.stop, risk: .confirmationRequired),
            favoriteActionDefinition(action: .restart, actionID: ActionID.restart, risk: .confirmationRequired),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        controller.snapshot.items
            .filter { $0.isFavorite && $0.canManage }
            .flatMap { item in
                [
                    catalogEntry(action: .start, actionID: ActionID.start, item: item),
                    catalogEntry(action: .stop, actionID: ActionID.stop, item: item),
                    catalogEntry(action: .restart, actionID: ActionID.restart, item: item),
                ]
            }
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard managedAction(for: reference.key.actionID) != nil,
              case let .string(itemID)? = reference.parameters[ActionID.itemIDParameter],
              let item = controller.snapshot.items.first(where: { $0.id == itemID })
        else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        guard item.isFavorite else {
            return .unavailable(localization.string("originFilter.favorite.title", defaultValue: "已关注"))
        }
        guard item.canManage else {
            return .unavailable(localization.string(
                "controller.operation.readOnly",
                defaultValue: "系统或全局启动项默认只读，避免误操作。"
            ))
        }
        return controller.snapshot.isRefreshing
            ? .unavailable(localization.string("panel.action.refreshing", defaultValue: "正在刷新"))
            : .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard let action = managedAction(for: invocation.reference.key.actionID),
              case let .string(itemID)? = invocation.reference.parameters[ActionID.itemIDParameter],
              let item = controller.snapshot.items.first(where: { $0.id == itemID }),
              item.isFavorite,
              item.canManage,
              !controller.snapshot.isRefreshing
        else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionUnavailable) }
        }
        let controller = controller
        return ActionExecutionHandle {
            let success = await controller.performManagedActionAndWait(action, item: item)
            return success
                ? .succeeded()
                : .failed(message: controller.snapshot.errorMessage ?? PluginKitLocalization.actionUnavailable)
        }
    }

    var settingsPage: PluginSettingsPage? {
        let localization = localization
        return .workspace(description: metadata.defaultDescription, scrolling: .selfManaged) { _ in
            LaunchControlManagerView(
                controller: self.controller,
                localization: localization,
                searchFocusController: self.settingsSearchFocusController
            )
        }
    }

    func focusSettingsSearch() {
        settingsSearchFocusController.requestFocus()
    }

    func refresh() {
        if controller.snapshot.items.isEmpty {
            controller.refresh()
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        controller.cancelRefresh()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(value):
            isExpanded = value
            onStateChange?()
        case let .invokeAction(controlID):
            if controlID == ControlID.refresh {
                controller.refresh()
            } else if controlID == ControlID.openManager {
                requestSettingsPresentation?()
            }
        case .setSwitch,
             .setSelection,
             .setNavigationSelection,
             .clearNavigationSelection,
             .setDate,
             .setSlider:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    private func buildDetail(for snapshot: LaunchControlSnapshot) -> PluginPanelDetail {
        let refreshControl = PluginPanelControl(
            id: ControlID.refresh,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: snapshot.isRefreshing
                ? localization.string("panel.action.refreshing", defaultValue: "正在刷新")
                : localization.string("panel.action.refresh", defaultValue: "刷新列表"),
            actionIconSystemName: "arrow.clockwise",
            isEnabled: !snapshot.isRefreshing
        )

        let openManagerControl = PluginPanelControl(
            id: ControlID.openManager,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.openManager", defaultValue: "打开管理器"),
            actionIconSystemName: "arrow.up.right.square",
            actionBehavior: .dismissBeforeHandling,
            showsLeadingDivider: true,
            isEnabled: true
        )

        return PluginPanelDetail(primaryControls: [refreshControl, openManagerControl], secondaryPanel: nil)
    }

    private func subtitle(for snapshot: LaunchControlSnapshot) -> String {
        if snapshot.isRefreshing {
            return localization.string(
                "panel.subtitle.refreshing",
                defaultValue: "正在扫描 LaunchAgent 与 LaunchDaemon"
            )
        }

        if snapshot.items.isEmpty {
            return localization.string(
                "panel.subtitle.empty",
                defaultValue: "打开管理器或刷新后查看启动项"
            )
        }

        let userCreatedCount = snapshot.items.filter { $0.origin == .userCreated }.count
        let runningCount = snapshot.items.filter { $0.state == .running }.count
        return localization.format(
            "panel.subtitle.summary",
            defaultValue: "%d 项 · %d 运行中 · %d 用户创建",
            snapshot.items.count,
            runningCount,
            userCreatedCount
        )
    }

    private func favoriteActionDefinition(
        action: LaunchControlManagedAction,
        actionID: String,
        risk: ActionRisk
    ) -> ActionDefinition {
        let title = action.title(localization: localization)
        return ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: actionID),
            title: title,
            description: metadata.defaultDescription,
            keywords: [metadata.title, title, "launchctl"],
            systemImage: actionSystemImage(action),
            parameters: [
                ActionParameterDefinition(
                    id: ActionID.itemIDParameter,
                    title: metadata.title,
                    kind: .string,
                    portability: .localOnly
                ),
            ],
            risk: risk,
            confirmation: risk == .confirmationRequired
                ? ActionConfirmation(
                    title: title,
                    message: metadata.defaultDescription,
                    confirmButtonTitle: title
                )
                : nil,
            externalInvocationPolicy: .unavailable,
            capabilities: [.automatic, .background, .foregroundInteractive],
            executionTimeoutSeconds: 15
        )
    }

    private func catalogEntry(
        action: LaunchControlManagedAction,
        actionID: String,
        item: LaunchControlItem
    ) -> ActionCatalogEntry {
        let parameters = try! ActionParameterSet([
            ActionID.itemIDParameter: .string(item.id),
        ])
        return ActionCatalogEntry(
            reference: ActionReference(
                key: ActionKey(providerID: metadata.id, actionID: actionID),
                parameters: parameters
            ),
            title: "\(action.title(localization: localization)) · \(item.label)",
            subtitle: item.note.isEmpty ? item.statusText(localization: localization) : item.note
        )
    }

    private func managedAction(for actionID: String) -> LaunchControlManagedAction? {
        switch actionID {
        case ActionID.start: .start
        case ActionID.stop: .stop
        case ActionID.restart: .restart
        default: nil
        }
    }

    private func actionSystemImage(_ action: LaunchControlManagedAction) -> String {
        switch action {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        default: "powerplug"
        }
    }
}
