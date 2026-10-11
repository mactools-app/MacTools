import MacToolsPluginKit

/// Reuses declarations from unchanged plugins only inside a host projection update.
/// Live action execution and shortcut resolution outside that update always read again.
@MainActor
final class PluginDerivedStateReadCache {
    enum Projection: Hashable {
        case actionDefinitions, actionCatalog, commands, settingsSearch, settingsPage
        case shortcutSettingsGroups, actionShortcutSettings
    }

    private struct Entry {
        let pluginID: String
        var values: [Projection: Any] = [:]
    }

    private struct ValueBox<Value> { let value: Value }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var revision: UInt64 = 0
    private var updateDepth = 0

    func beginUpdate(plugins: [any MacToolsPlugin], dirtyPluginIDs: Set<String>?) {
        let identities = Set(plugins.map(ObjectIdentifier.init))
        entries = entries.filter { identities.contains($0.key) }
        if let dirtyPluginIDs {
            entries = entries.filter { !dirtyPluginIDs.contains($0.value.pluginID) }
        } else {
            entries.removeAll()
        }
        revision &+= 1
        updateDepth += 1
    }

    func endUpdate() { updateDepth -= 1 }

    func invalidate(pluginID: String) {
        entries = entries.filter { $0.value.pluginID != pluginID }
        revision &+= 1
    }

    func value<Value>(
        for plugin: any MacToolsPlugin,
        projection: Projection,
        read: () -> Value
    ) -> Value {
        guard updateDepth > 0 else { return read() }
        let identity = ObjectIdentifier(plugin)
        if let box = entries[identity]?.values[projection] as? ValueBox<Value> {
            return box.value
        }
        let readRevision = revision
        let value = read()
        // A getter may reenter the host and notify it before returning.
        if revision == readRevision {
            var entry = entries[identity] ?? Entry(pluginID: plugin.metadata.id)
            entry.values[projection] = ValueBox(value: value)
            entries[identity] = entry
        }
        return value
    }
}
