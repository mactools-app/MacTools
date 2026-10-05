import AppKit
import MacToolsPluginKit
import SwiftUI

public final class ActionGridPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        ActionGridPluginProvider(context: context)
    }
}

@MainActor
private struct ActionGridPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            ActionGridPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class ActionGridPlugin:
    MacToolsPlugin,
    PluginSettingsPresenting,
    PluginActionProviding,
    ActionGridHostContextConsuming,
    ActionSurfaceAssignmentSummarizing,
    PluginPortablePreferencesProviding,
    PluginPersistentPreferencesChangeSignaling,
    PluginPortablePreferencesRestorationReporting,
    PluginPortablePreferencesActionReferencesProviding
{
    static let showActionKey = ActionKey(providerID: "action-grid", actionID: "show")

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "action-grid",
            title: localization.string("metadata.title", defaultValue: "操作网格"),
            iconName: "square.grid.3x3",
            iconTint: Color(nsColor: .systemTeal),
            order: 74,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "在指针附近打开常用操作网格"
            )
        )
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?
    var onPersistentPreferencesChange: (() -> Void)? {
        get { persistentPreferencesChanges.onChange }
        set { persistentPreferencesChanges.onChange = newValue }
    }
    var actionGridHostContext: ActionGridHostContext? {
        didSet {
            if let actionGridHostContext,
                store.migrate(using: actionGridHostContext) {
                onStateChange?()
                persistentPreferencesChanges.didPersist()
            }
        }
    }

    let store: ActionGridStore
    private let localization: PluginLocalization
    private let persistentPreferencesChanges = PluginPersistentPreferencesChangeEmitter()

    init(
        context: PluginRuntimeContext,
        localization: PluginLocalization? = nil
    ) {
        let localization = localization ?? PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        self.store = ActionGridStore(storage: context.storage)
        if store.didPersistPortablePreferencesDuringInitialization {
            persistentPreferencesChanges.didPersist()
        }
    }

    var settingsPage: PluginSettingsPage? {
        .workspace(
            description: localization.string(
                "metadata.description",
                defaultValue: "在指针附近打开常用操作网格"
            ),
            scrolling: .host
        ) { [weak self] _ in
            if let self {
                ActionGridSettingsView(plugin: self, store: self.store)
            } else {
                EmptyView()
            }
        }
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: Self.showActionKey,
                title: localization.string(
                    "action.show.title",
                    defaultValue: "显示操作网格"
                ),
                description: localization.string(
                    "action.show.description",
                    defaultValue: "在指针附近打开操作网格。"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "操作网格"),
                    localization.string("action.show.title", defaultValue: "显示操作网格"),
                    "action",
                    "grid",
                    "launcher",
                ],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.foregroundInteractive],
                executionTimeoutSeconds: 30
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key == Self.showActionKey else {
            return .unavailable(localized("操作不可用。"))
        }
        guard !presentationEntries(store.entries).isEmpty else {
            return .unavailable(localized("请先配置操作网格。"))
        }
        guard actionGridHostContext?.canPresent == true else {
            return .unavailable(localized("操作网格暂时无法显示。"))
        }
        return .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { [weak self] in
            guard let self, let context = self.actionGridHostContext else {
                return .failed(
                    message: self?.localized("操作网格暂时无法显示。")
                        ?? PluginKitLocalization.actionUnavailable
                )
            }
            let entries = self.presentationEntries(self.store.entries)
            guard !entries.isEmpty,
                  context.present(entries: entries, source: invocation.source) else {
                return .failed(message: self.localized("无法显示操作网格。"))
            }
            return .succeeded()
        }
    }

    func actionSurfaceCatalogDidChange() {
        guard let actionGridHostContext else { return }
        if store.migrate(using: actionGridHostContext) {
            onStateChange?()
            persistentPreferencesChanges.didPersist()
        }
    }

    func makePortablePreferencesBackup() -> Data? {
        store.portableBackup(using: actionGridHostContext)
    }

    func restorePortablePreferences(from data: Data) {
        let previousEntries = store.entries
        if store.restorePortableBackup(data, using: actionGridHostContext) {
            if store.entries != previousEntries {
                onStateChange?()
                persistentPreferencesChanges.didPersist()
            }
        }
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        let previousEntries = store.entries
        let restored = store.restorePortableBackup(data, using: actionGridHostContext)
        if restored, store.entries != previousEntries {
            onStateChange?()
            persistentPreferencesChanges.didPersist()
        }
        return restored
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        store.actionReferences(inPortableBackup: data)
    }

    func catalogItems(
        excluding entryID: UUID? = nil,
        in folderID: UUID? = nil
    ) -> [ActionSurfaceCatalogItem] {
        let currentEntries = store.entries(in: folderID)
        return actionGridHostContext?.catalog.filter { item in
            guard item.reference.key != Self.showActionKey else { return false }
            return !currentEntries.contains { entry in
                entry.folder == nil && entry.id != entryID && entry.reference == item.reference
            }
        } ?? []
    }

    func item(for reference: ActionReference) -> ActionSurfaceCatalogItem? {
        actionGridHostContext?.item(for: reference)
    }

    @discardableResult
    func openOwner(for reference: ActionReference) -> Bool {
        actionGridHostContext?.openOwner(for: reference) ?? false
    }

    func suggestedReferences() -> [ActionReference] {
        let items = catalogItems()
        let priorities = [
            ActionKey(providerID: "lock-screen", actionID: "execute"),
            ActionKey(providerID: "display-sleep", actionID: "execute"),
            ActionKey(providerID: "microphone-mute", actionID: "set-enabled"),
            ActionKey(providerID: "launchpad", actionID: "toggleLaunchpad"),
        ]
        var result = priorities.compactMap { key in items.first { $0.reference.key == key }?.reference }
        let selected = Set(result)
        result.append(contentsOf: items.lazy.filter { $0.isSafe && !selected.contains($0.reference) }.map(\.reference))
        return Array(result.prefix(6))
    }

    func actionSurfaceAssignmentSummary(
        for reference: ActionReference
    ) -> ActionSurfaceAssignmentSummary? {
        guard let path = assignmentPath(for: reference, in: store.entries) else {
            return nil
        }
        return ActionSurfaceAssignmentSummary(
            surfaceID: metadata.id,
            surfaceTitle: localization.string("metadata.title", defaultValue: "操作网格"),
            systemImage: metadata.iconName,
            detail: path
        )
    }

    private func presentationEntries(
        _ entries: [ActionGridEntry]
    ) -> [ActionGridPresentationEntry] {
        entries.compactMap { entry in
            if let folder = entry.folder {
                return ActionGridPresentationEntry(
                    id: entry.id.uuidString.lowercased(),
                    folderTitle: entry.customTitle ?? localized("文件夹"),
                    systemImage: folder.systemImage,
                    children: presentationEntries(folder.entries),
                    slotIndex: entry.slot
                )
            }
            guard entry.reference.key != Self.showActionKey else { return nil }
            return entry.presentationEntry
        }
    }

    private func assignmentPath(
        for reference: ActionReference,
        in entries: [ActionGridEntry]
    ) -> String? {
        for (index, entry) in entries.enumerated() {
            if entry.folder == nil, entry.reference == reference {
                return localizedFormat("第 %d 个条目", (entry.slot ?? index) + 1)
            }
            if let folder = entry.folder,
               let nested = assignmentPath(for: reference, in: folder.entries) {
                return "\(entry.customTitle ?? localized("文件夹")) › \(nested)"
            }
        }
        return nil
    }

    func localized(_ source: String) -> String {
        localization.string(source, defaultValue: source)
    }

    func localizedFormat(_ source: String, _ arguments: CVarArg...) -> String {
        String(
            format: localized(source),
            locale: PluginRuntimeLocalization.locale,
            arguments: arguments
        )
    }

    var accessibilityCopy: ActionGridAccessibilityCopy {
        ActionGridAccessibilityCopy(
            summaryFormat: localized("%@，%@，%@"),
            settingsLabelFormat: localized("设置“%@”"),
            replaceLabelFormat: localized("替换“%@”"),
            removeLabelFormat: localized("移除“%@”"),
            settingsButtonTitle: localized("设置"),
            replacementMenuTitle: localized("替换"),
            settingsHelp: localized("打开操作提供者设置"),
            replaceHelp: localized("选择其他操作替换此条目"),
            removeHelp: localized("从操作网格移除此条目")
        )
    }

    func notifyMutation() {
        onStateChange?()
        persistentPreferencesChanges.didPersist()
    }
}
