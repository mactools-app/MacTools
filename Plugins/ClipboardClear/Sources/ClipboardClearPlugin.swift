import Foundation
import AppKit
import SwiftUI
import OSLog
import MacToolsPluginKit

public final class ClipboardClearPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        ClipboardClearPluginProvider(context: context)
    }
}

@MainActor
private struct ClipboardClearPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [ClipboardClearPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class ClipboardClearPlugin: MacToolsPlugin, PluginActionProviding {
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

    static let pluginID = "clipboard-clear"
    static let pluginOrder: Int = 120

    private enum ActionID {
        static let clear = "clear"
    }

    private let pasteboard: NSPasteboard
    private let localization: PluginLocalization
    private var canClearClipboard = false

    var metadata: PluginMetadata {
        PluginMetadata(
            id: ClipboardClearPlugin.pluginID,
            title: localization.string("metadata.title", defaultValue: "清空剪贴板"),
            iconName: "trash",
            iconTint: .accentColor,
            order: ClipboardClearPlugin.pluginOrder,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "一键清空当前剪贴板内容"
            )
        )
    }

    let rowDescriptor: PluginPanelRowDescriptor

    init(
        pasteboard: NSPasteboard = .general,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.pasteboard = pasteboard
        self.localization = localization
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: { localization.string("panel.button.clear", defaultValue: "清空") }
        )
        canClearClipboard = Self.hasClipboardContents(in: pasteboard)
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.clear),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "clipboard", "pasteboard"],
                systemImage: metadata.iconName,
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: metadata.title,
                    message: metadata.defaultDescription,
                    confirmButtonTitle: localization.string("panel.button.clear", defaultValue: "清空")
                ),
                externalInvocationPolicy: .confirmAlways,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        canClearClipboard
            ? .available
            : .unavailable(metadata.defaultDescription)
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isEnabled: canClearClipboard,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        if case .invokeAction(let controlID) = action, controlID == "execute" {
            clearClipboard()
        }
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard invocation.reference.key.actionID == ActionID.clear else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        guard canClearClipboard else {
            return ActionExecutionHandle { .failed(message: self.metadata.defaultDescription) }
        }
        clearClipboard()
        return ActionExecutionHandle { .succeeded() }
    }

    func refresh() {
        syncPasteboardState(forceNotify: false)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState { PluginPermissionState(isGranted: false, footnote: nil) }
    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    private func syncPasteboardState(forceNotify: Bool) {
        let hasContents = Self.hasClipboardContents(in: pasteboard)
        let didChange = canClearClipboard != hasContents
        canClearClipboard = hasContents

        if forceNotify || didChange {
            onStateChange?()
        }
    }

    private func clearClipboard() {
        pasteboard.clearContents()
        syncPasteboardState(forceNotify: true)
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.example.mactools",
            category: "ClipboardClearPlugin"
        ).info("Clipboard cleared")
    }

    nonisolated private static func hasClipboardContents(in pasteboard: NSPasteboard) -> Bool {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return false
        }

        return items.contains { !$0.types.isEmpty }
    }
}
