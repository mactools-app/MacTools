import AppKit
import Foundation

/// Full Disk Access helpers for the settings permission card. TCC silently
/// denies (EPERM) protected app-container data without FDA, so the plugin
/// probes the same FDA-class paths DiskClean uses and guides the user to the
/// Privacy & Security pane; macOS offers no programmatic FDA request.
enum SystemDataFullDiskAccess {
    /// Probe targets, tried in order; first successful open wins.
    /// - TCC.db: present on any account that has made a privacy decision;
    ///   broadest coverage and pure FDA-class protection.
    /// - Safari bookmarks: fallback when TCC.db is missing (brand-new
    ///   account); same silent EPERM class.
    /// Missing file and denial both count as "not granted": only a successful
    /// content open proves FDA.
    static let probePaths = [
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Safari/Bookmarks.plist",
    ]

    static func hasFullDiskAccess() -> Bool {
        probePaths.contains { canOpenForReading(atPath: $0) }
    }

    private static func canOpenForReading(atPath path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        try? handle.close()
        return true
    }

    /// Opens the Full Disk Access pane in System Settings.
    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
