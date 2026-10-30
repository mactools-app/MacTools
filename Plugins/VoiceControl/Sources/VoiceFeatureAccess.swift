import Foundation

/// The automatic policy admits new providers; explicit exclusions always take precedence.
struct VoiceFeatureAccess: Equatable {
    var automaticallyAllowNewPlugins = true
    var excludedPluginIDs: Set<String> = []
    var approvedPluginIDs: Set<String> = []

    func isAllowed(_ id: String) -> Bool {
        !excludedPluginIDs.contains(id) && (automaticallyAllowNewPlugins || approvedPluginIDs.contains(id))
    }

    mutating func setAutomaticallyAllowNewPlugins(_ value: Bool, currentPluginIDs: Set<String>) {
        guard value != automaticallyAllowNewPlugins else { return }
        if !value {
            // Keep current choices when switching to manual approval, including earlier
            // approvals for temporarily unavailable providers.
            approvedPluginIDs.formUnion(currentPluginIDs.filter { isAllowed($0) })
        }
        automaticallyAllowNewPlugins = value
    }

    mutating func setAllowed(_ allowed: Bool, for ids: Set<String>) {
        if allowed {
            excludedPluginIDs.subtract(ids)
            approvedPluginIDs.formUnion(ids)
        } else {
            excludedPluginIDs.formUnion(ids)
            approvedPluginIDs.subtract(ids)
        }
    }

    func exclusions(for currentPluginIDs: Set<String>) -> Set<String> {
        excludedPluginIDs.union(currentPluginIDs.filter { !isAllowed($0) })
    }
}
