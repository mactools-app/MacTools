import MacToolsPluginKit

/// Older compatible packages own their native listener and cannot join the
/// weighing pause. Other legacy plugins remain compatible with the host.
@MainActor
enum TrackpadInputCompatibility {
    private static let rawInputPluginIDs: Set<String> = ["middle-click", "trackpad-gestures"]

    static func canWeigh(with plugins: [any MacToolsPlugin]) -> Bool {
        !plugins.contains {
            rawInputPluginIDs.contains($0.metadata.id) && !($0 is any TrackpadInputServiceConsuming)
        }
    }
}
