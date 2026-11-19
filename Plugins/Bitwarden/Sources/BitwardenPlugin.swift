import AppKit
import MacToolsPluginKit
import SwiftUI

public final class BitwardenPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        BitwardenPluginProvider(context: context)
    }
}

@MainActor
private struct BitwardenPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [BitwardenPlugin(context: context)]
    }
}

@MainActor
final class BitwardenPlugin: MacToolsPlugin, PluginSettingsPresenting, PluginCommandProviding {
    private let vault: BitwardenVault
    private let bundle: Bundle
    private var sleepObserver: (any NSObjectProtocol)?
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    init(context: PluginRuntimeContext) {
        bundle = context.resourceBundle
        let support = context.supportDirectory ?? URL.applicationSupportDirectory
            .appending(path: "MacTools/Bitwarden", directoryHint: .isDirectory)
        vault = BitwardenVault(cli: BitwardenCLI(directory: support.appending(path: "CLI", directoryHint: .isDirectory)))
        vault.onStatusChange = { [weak self] in self?.onStateChange?() }
    }

    var metadata: PluginMetadata {
        .init(id: "bitwarden", title: "Bitwarden", iconName: "lock.shield", iconTint: .blue,
              order: 121, defaultDescription: text("vault.description", fallback: "Manage your Bitwarden vault"))
    }

    var panelItems: [PluginPanelItem] {
        let state = PluginPanelRowState(
            subtitle: text("vault.\(vault.status.rawValue)", fallback: "Bitwarden"),
            isOn: vault.status == .unlocked, isEnabled: true, isAvailable: true, detail: nil, errorMessage: nil
        )
        let descriptor = PluginPanelRowDescriptor(
            controlStyle: .button, menuActionBehavior: .dismissBeforeHandling,
            buttonTitle: text("vault.open", fallback: "Open Vault")
        )
        return [
            .row(id: "control", initialPlacement: .featurePanel, descriptor: descriptor, state: state,
                 action: { [weak self] _ in self?.requestSettingsPresentation?() }),
            .iconWidget(id: "quick-control", title: "Bitwarden", systemImage: "lock.shield", control: .button,
                        state: state, menuActionBehavior: .dismissBeforeHandling,
                        action: { [weak self] _ in self?.requestSettingsPresentation?() }),
        ]
    }

    var settingsPage: PluginSettingsPage? {
        .workspace(description: metadata.defaultDescription, scrolling: .selfManaged) { [vault, bundle] _ in
            BitwardenWorkspace(vault: vault, bundle: bundle)
        }.onVisibilityChange { [weak self] visible in
            if visible { self?.refresh() } else { self?.vault.lock() }
        }
    }

    var commandDefinitions: [PluginCommandDefinition] {
        [
            .init(id: "open-bitwarden", title: text("vault.open", fallback: "Open Vault"),
                  description: metadata.defaultDescription, keywords: ["bitwarden", "vault"], systemImage: "lock.shield"),
            .init(id: "lock-vault", title: text("vault.lock", fallback: "Lock"),
                  description: text("vault.lockDescription", fallback: "Lock the Bitwarden vault"),
                  keywords: ["bitwarden", "vault"], systemImage: "lock"),
        ]
    }

    func handleCommand(id: String) {
        switch id {
        case "open-bitwarden": requestSettingsPresentation?()
        case "lock-vault": vault.lock()
        default: break
        }
    }

    func activate(context: PluginRuntimeContext) {
        refresh()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.vault.lock() }
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        vault.lock()
    }

    func refresh() {
        Task { [vault] in await vault.refreshStatus() }
    }

    private func text(_ key: String, fallback: String) -> String {
        PluginLocalization(bundle: bundle, table: "Vault").string(key, defaultValue: fallback)
    }
}
