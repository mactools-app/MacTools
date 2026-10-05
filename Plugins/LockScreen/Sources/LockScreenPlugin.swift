import Darwin
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class LockScreenPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        LockScreenPluginProvider(context: context)
    }
}

@MainActor
private struct LockScreenPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [LockScreenPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class LockScreenPlugin:
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
            id: "lock-screen",
            title: localization.string("metadata.title", defaultValue: "锁定屏幕"),
            iconName: "lock",
            iconTint: Color(nsColor: .systemGray),
            order: 96,
            defaultDescription: localization.string("metadata.description", defaultValue: "立即锁定屏幕")
        )
    }

    let rowDescriptor: PluginPanelRowDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "LockScreenPlugin"
    )
    private let localization: PluginLocalization
    private let lockRequest: @MainActor @Sendable () async -> Bool

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        lockRequest: @escaping @MainActor @Sendable () async -> Bool = {
            await LockScreenPlugin.requestImmediateLock()
        }
    ) {
        self.localization = localization
        self.lockRequest = lockRequest
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: { localization.string("panel.button.lock", defaultValue: "锁定") }
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
                    defaultValue: "锁定屏幕"
                ),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "立即锁定屏幕"
                ),
                systemImage: metadata.iconName
            )
        ]
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: "execute"),
                title: localization.string("metadata.title", defaultValue: "锁定屏幕"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "立即锁定屏幕"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "锁定屏幕"),
                    localization.string("metadata.description", defaultValue: "立即锁定屏幕"),
                ],
                systemImage: metadata.iconName,
                confirmation: ActionConfirmation(
                    title: localization.string(
                        "action.confirmation.title",
                        defaultValue: "锁定屏幕？"
                    ),
                    message: localization.string(
                        "action.confirmation.message",
                        defaultValue: "此运行链接将立即锁定屏幕。"
                    ),
                    confirmButtonTitle: localization.string(
                        "action.confirmation.confirm",
                        defaultValue: "锁定"
                    )
                ),
                externalInvocationPolicy: .confirmAlways,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            return await self.lockScreen()
                ? .succeeded()
                : .failed(message: self.localization.string(
                    "error.lockFailed",
                    defaultValue: "无法立即锁定屏幕。"
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
            _ = await self?.lockScreen()
        }
    }

    private func lockScreen() async -> Bool {
        let succeeded = await lockRequest()
        if succeeded {
            logger.info("Screen locked successfully")
        } else {
            logger.error("Immediate screen lock failed")
        }
        return succeeded
    }

    nonisolated private static func requestImmediateLock() async -> Bool {
        await Task.detached(priority: .userInitiated) {
        let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/login"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            _ = startScreenSaverFallback()
            return false
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            _ = startScreenSaverFallback()
            return false
        }

        typealias LockScreenFunction = @convention(c) () -> Int32
        let lockScreenImmediately = unsafeBitCast(symbol, to: LockScreenFunction.self)
        let result = lockScreenImmediately()
        guard result == 0 else {
            _ = startScreenSaverFallback()
            return false
        }
        return true
        }.value
    }

    nonisolated private static func startScreenSaverFallback() -> Bool {
        let task = Process()
        task.executableURL = URL(
            fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app/Contents/MacOS/ScreenSaverEngine"
        )

        do {
            try task.run()
            return true
        } catch {
            return false
        }
    }
}
