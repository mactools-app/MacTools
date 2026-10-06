import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class IPOverviewPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        IPOverviewPluginProvider(context: context)
    }
}

@MainActor
private struct IPOverviewPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [IPOverviewPlugin(context: context, localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class IPOverviewPlugin:
    MacToolsPlugin, PluginSettingsPresenting, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("control") }
                    else { self?.panelItemDidBecomeHidden("control") }
                },
        ]
    }

    private enum ActionID {
        static let copyLocalIPv4 = "copy-local-ipv4"
        static let copyPublicIPv4 = "copy-public-ipv4"
    }

    enum ControlID {
        static let openSettings = "execute"
        static let copyIP = "ip-overview-copy-ip"
        static let copyLocalIPv4 = "ip-overview-copy-local-ipv4"
        static let copyPublicIPv4 = "ip-overview-copy-public-ipv4"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "ip-overview",
            title: localization.string("metadata.title", defaultValue: "IP 检测"),
            iconName: "network",
            iconTint: Color(nsColor: .systemBlue),
            order: 12,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "查看公网 IP、本地地址和归属地"
            )
        )
    }

    let rowDescriptor: PluginPanelRowDescriptor

    private let viewModel: IPOverviewViewModel
    private let localization: PluginLocalization

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "ip-overview"),
        viewModel: IPOverviewViewModel? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.viewModel = viewModel ?? IPOverviewViewModel(storage: context.storage, localization: localization)
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: { localization.string("panel.button.check", defaultValue: "检测") }
        )
        self.viewModel.onSnapshotChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    func activate(context: PluginRuntimeContext) {
        viewModel.refreshIfNeeded()
    }

    func deactivate(reason: PluginDeactivationReason) {
        viewModel.cancel()
    }

    func refresh() {
        viewModel.refreshAddresses()
    }

    func panelItemDidBecomeVisible(_ surface: String) {
        guard surface == "control" else {
            return
        }

        viewModel.refreshAddresses()
    }

    func panelItemDidBecomeHidden(_ surface: String) {}

    private var addressControls: [PluginPanelControl] {
        let snapshot = viewModel.snapshot
        let localKind = localization.string("landing.local", defaultValue: "本地")
        let localLabel = "\(localKind) IPv4"
        let publicLabel = localization.string("publicIP.title", defaultValue: "公网 IP")
        return [
            addressControl(
                id: ControlID.copyLocalIPv4,
                address: snapshot.preferredLocalIPv4?.address,
                label: localLabel,
                copyHelp: localization.format(
                    "copy.ip.help",
                    defaultValue: "复制 %@ IP",
                    localKind
                )
            ),
            addressControl(
                id: ControlID.copyPublicIPv4,
                address: snapshot.preferredPublicIPv4?.ip,
                label: publicLabel,
                copyHelp: localization.string(
                    "panel.action.copyPublicIP",
                    defaultValue: "复制公网 IP"
                )
            )
        ]
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: viewModel.snapshot.isRefreshing,
            isEnabled: true,
            isAvailable: true,
            detail: PluginPanelDetail(controls: addressControls),
            errorMessage: viewModel.snapshot.errorMessage
        )
    }

    var actionDefinitions: [ActionDefinition] {
        let localKind = localization.string("landing.local", defaultValue: "本地")
        return [
            copyActionDefinition(
                id: ActionID.copyLocalIPv4,
                title: localization.format("copy.ip.help", defaultValue: "复制 %@ IP", localKind)
            ),
            copyActionDefinition(
                id: ActionID.copyPublicIPv4,
                title: localization.string("panel.action.copyPublicIP", defaultValue: "复制公网 IP")
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        switch reference.key.actionID {
        case ActionID.copyLocalIPv4, ActionID.copyPublicIPv4:
            return .available
        default:
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let actionID = invocation.reference.key.actionID
        guard actionID == ActionID.copyLocalIPv4 || actionID == ActionID.copyPublicIPv4 else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }

        return ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            await self.viewModel.refreshAddressesAndWait()
            guard !Task.isCancelled else { return .cancelled }

            let value = self.copyValue(for: actionID)
            guard let value, !value.isEmpty else {
                let fallbackMessage = actionID == ActionID.copyLocalIPv4
                    ? PluginKitLocalization.actionUnavailable
                    : self.localization.string("service.error.noPublicIP", defaultValue: "未能从外部检测源获取公网 IP")
                return .failed(
                    message: self.viewModel.snapshot.errorMessage
                        ?? fallbackMessage
                )
            }
            self.viewModel.copy(value)
            return .succeeded()
        }
    }

    private func copyValue(for actionID: String) -> String? {
        actionID == ActionID.copyLocalIPv4
            ? viewModel.snapshot.preferredLocalIPv4?.address
            : viewModel.snapshot.preferredPublicIPv4?.ip
    }

    var settingsPage: PluginSettingsPage? {
        .workspace(description: metadata.defaultDescription, scrolling: .host) { _ in
            IPOverviewComponentView(
                viewModel: self.viewModel,
                localization: self.localization,
                startsInDetails: true,
                showsBackButton: false,
                showsDetailHeader: false,
                managesScrolling: false
            )
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .invokeAction(controlID):
            handleInvoke(controlID: controlID)
        case .setDisclosureExpanded,
             .setSwitch,
             .setSelection,
             .setNavigationSelection,
             .clearNavigationSelection,
             .setDate,
             .setSlider:
            break
        }
    }

    private var panelSubtitle: String {
        let snapshot = viewModel.snapshot
        if snapshot.isRefreshing {
            return localization.string("panel.subtitle.refreshing", defaultValue: "正在检测公网 IP...")
        }

        if let ip = snapshot.preferredPublicIPv4?.ip {
            return displayIP(ip)
        }

        if let errorMessage = snapshot.errorMessage {
            return errorMessage
        }

        return metadata.defaultDescription
    }

    private func handleInvoke(controlID: String) {
        switch controlID {
        case ControlID.openSettings:
            requestSettingsPresentation?()
        case ControlID.copyIP:
            viewModel.copy(viewModel.snapshot.preferredPublicIPv4?.ip)
        case ControlID.copyLocalIPv4:
            viewModel.copy(viewModel.snapshot.preferredLocalIPv4?.address)
        case ControlID.copyPublicIPv4:
            viewModel.copy(viewModel.snapshot.preferredPublicIPv4?.ip)
        default:
            break
        }
    }

    private func displayIP(_ value: String) -> String {
        viewModel.hidesSensitiveInfo ? IPOverviewSensitiveValueMask.maskedIP(value) : value
    }

    private func addressControl(
        id: String,
        address: String?,
        label: String,
        copyHelp: String
    ) -> PluginPanelControl {
        PluginPanelControl(
            id: id,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: label,
            valueLabel: copyHelp,
            actionTitle: address.map(displayIP) ?? "--",
            actionIconSystemName: "doc.on.doc",
            actionBehavior: .keepPresented,
            isEnabled: address != nil
        )
    }

    private func copyActionDefinition(id: String, title: String) -> ActionDefinition {
        ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: id),
            title: title,
            description: metadata.defaultDescription,
            keywords: [metadata.title, title, "IP", "copy"],
            systemImage: "doc.on.doc",
            externalInvocationPolicy: .allowed,
            capabilities: [.automatic, .background, .foregroundInteractive],
            executionTimeoutSeconds: 30
        )
    }
}
