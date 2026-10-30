import Foundation

/// A single launchable application discovered by `InstalledApplicationScanner`.
struct InstalledApplication: Identifiable, Hashable, Sendable {
    /// Resolved absolute path of the `.app` bundle — stable and unique, used as identity.
    let id: String
    /// User-facing localized name (without the `.app` suffix).
    let name: String
    let url: URL
}


/// Pure, thread-safe application enumeration.
///
/// Design notes (validated on macOS 26.5.1 + cross-reviewed):
/// - Recursive directory scan, NOT Spotlight (`NSMetadataQuery` is unreliable when
///   Spotlight is disabled/excluded/reindexing) and NOT any private LaunchServices API
///   (no public "list all apps" API exists). Requires the host to be non-sandboxed.
/// - Includes `/System/Cryptexes/App/System/Applications` so cryptex-delivered system
///   apps (Safari, etc.) are not missed.
/// - `.skipsPackageDescendants` stops the enumerator from descending into `.app`
///   bundles; the `isNestedInsideAnotherApp` guard is cheap belt-and-suspenders for
///   helper/XPC apps embedded in another bundle.
/// - No name / bundle-id / "com.apple" denylist: only nested helpers and non-package
///   directories are excluded, so legitimately-named apps (including Tahoe's
///   `com.apple.apps.launcher`) are kept.
/// - Validity check uses `isDirectory` (a real `.app` is a package directory) instead
///   of `NSWorkspace`, keeping this type free of main-actor isolation so the scan can
///   run off the main thread.
enum InstalledApplicationScanner {
    /// Standard install locations. Non-existent roots are skipped.
    static let defaultSearchRoots: [String] = [
        "/Applications",
        NSHomeDirectory() + "/Applications",
        "/System/Applications",
        "/System/Cryptexes/App/System/Applications",
    ]

    static func scan(
        roots: [String] = defaultSearchRoots,
        fileManager: FileManager = .default
    ) -> [InstalledApplication] {
        var seen = Set<String>()
        var items: [InstalledApplication] = []

        for root in roots where fileManager.fileExists(atPath: root) {
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                // Keep scanning past unreadable/transient entries instead of aborting.
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "app" {
                let resolved = url.resolvingSymlinksInPath()
                let path = resolved.path
                guard isValidAppBundle(at: path, fileManager: fileManager),
                      !isNestedInsideAnotherApp(resolved),
                      seen.insert(path).inserted else { continue }
                items.append(InstalledApplication(
                    id: path,
                    name: displayName(for: resolved, fileManager: fileManager),
                    url: resolved
                ))
            }
        }

        // Sort by localized name; tie-break on the stable path id so apps with the
        // same display name (e.g. one in /Applications, one in ~/Applications) keep a
        // deterministic order (Swift's sort is not guaranteed stable).
        return items.sorted {
            switch $0.name.localizedCaseInsensitiveCompare($1.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return $0.id < $1.id
            }
        }
    }

    /// A real `.app` is a package directory that contains `Contents/Info.plist`.
    /// Requiring the Info.plist (which every real bundle has) rejects corrupt or
    /// placeholder directories merely named `X.app`, without dropping legitimate apps
    /// — and stays main-actor-free (no `NSWorkspace`) so the scan runs off-main.
    static func isValidAppBundle(at path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return fileManager.fileExists(atPath: (path as NSString).appendingPathComponent("Contents/Info.plist"))
    }

    /// Excludes helper/XPC/login-item apps embedded inside another `.app`
    /// (e.g. `Foo.app/Contents/.../Bar.app` has two `.app` path segments).
    static func isNestedInsideAnotherApp(_ url: URL) -> Bool {
        url.pathComponents.filter { $0.hasSuffix(".app") }.count > 1
    }

    static func displayName(for url: URL, fileManager: FileManager = .default) -> String {
        strippedAppSuffix(fileManager.displayName(atPath: url.path))
    }

    /// Removes only a trailing `.app` suffix — NOT every occurrence — so an app whose
    /// localized name legitimately contains ".app" is not mangled.
    static func strippedAppSuffix(_ name: String) -> String {
        name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
