import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class DisplaySleepPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DisplaySleepPluginProvider(context: context)
    }
}

@MainActor
private struct DisplaySleepPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [DisplaySleepPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class DisplaySleepPlugin:
    MacToolsPlugin, PluginCommandProviding, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("metadata.title", defaultValue: metadata.title),
                systemImage: metadata.iconName,
                control: .button,
                state: state,
                menuActionBehavior: rowDescriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "display-sleep",
            title: localization.string("metadata.title", defaultValue: "显示器休眠"),
            iconName: "display",
            iconTint: Color(nsColor: .systemIndigo),
            order: 97,
            defaultDescription: localization.string("metadata.description", defaultValue: "立即让显示器休眠")
        )
    }

    let rowDescriptor: PluginPanelRowDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "DisplaySleepPlugin"
    )
    private let localization: PluginLocalization
    private let presentationPreparation: @MainActor @Sendable () -> Void
    private let displaySleepRequest: @MainActor @Sendable () async -> Bool

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        presentationPreparation: @escaping @MainActor @Sendable () -> Void = {
            PluginPresentationSafety.prepareForWindowOrdering()
        },
        displaySleepRequest: @escaping @MainActor @Sendable () async -> Bool = {
            await DisplaySleepPlugin.requestDisplaySleep()
        }
    ) {
        self.localization = localization
        self.presentationPreparation = presentationPreparation
        self.displaySleepRequest = displaySleepRequest
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: { localization.string("panel.button.sleep", defaultValue: "休眠") }
        )
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var commandDefinitions: [PluginCommandDefinition] {
        [
            PluginCommandDefinition(
                id: "execute",
                title: localization.string(
                    "metadata.title",
                    defaultValue: "显示器休眠"
                ),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "立即让显示器休眠"
                ),
                systemImage: metadata.iconName
            )
        ]
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: "execute"),
                title: localization.string("metadata.title", defaultValue: "显示器休眠"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "立即让显示器休眠"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "显示器休眠"),
                    localization.string("metadata.description", defaultValue: "立即让显示器休眠"),
                ],
                systemImage: metadata.iconName,
                confirmation: ActionConfirmation(
                    title: localization.string(
                        "action.confirmation.title",
                        defaultValue: "让显示器休眠？"
                    ),
                    message: localization.string(
                        "action.confirmation.message",
                        defaultValue: "此运行链接将立即关闭显示器。"
                    ),
                    confirmButtonTitle: localization.string(
                        "action.confirmation.confirm",
                        defaultValue: "休眠"
                    )
                ),
                externalInvocationPolicy: .confirmAlways,
                capabilities: [.automatic, .background, .foregroundInteractive, .changesDisplayConfiguration]
            ),
        ]
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            return await self.sleepDisplays()
                ? .succeeded()
                : .failed(message: self.localization.string(
                    "error.sleepFailed",
                    defaultValue: "无法让显示器进入休眠。"
                ))
        }
    }

    func handleCommand(id: String) {
        guard id == "execute" else {
            return
        }

        handleAction(.invokeAction(controlID: "execute"))
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .invokeAction(controlID) = action, controlID == "execute" else {
            return
        }

        Task { @MainActor [weak self] in
            _ = await self?.sleepDisplays()
        }
    }

    private func sleepDisplays() async -> Bool {
        presentationPreparation()
        let succeeded = await displaySleepRequest()
        if succeeded {
            logger.info("Requested display sleep via pmset")
        } else {
            logger.error("pmset displaysleepnow failed")
        }
        return succeeded
    }

    nonisolated private static func requestDisplaySleep() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["displaysleepnow"]
            do {
                try task.run()
                task.waitUntilExit()
                return task.terminationReason == .exit && task.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}
