import MacToolsPluginKit

enum NotchHoverPanelStyle: String, Sendable {
    case morph
    case classic

    static let pluginID = "notch-hover-panel"
    static let storageKey = "notch-hover.panel-style"
    static let hostSupportKey = "MTSupportsNotchHoverPanelStyles"

    @MainActor
    static func stored(in storage: any PluginStorage) -> Self {
        storage.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .morph
    }
}
