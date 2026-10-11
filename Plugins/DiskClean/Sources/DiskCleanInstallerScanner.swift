import Darwin
import Foundation

// MARK: - Kind

/// Leftover installer kind (design §10.2). Raw value is the lowercase extension; classification is extension-only.
enum DiskCleanInstallerKind: String, CaseIterable, Equatable, Sendable {
    case diskImage = "dmg"
    case installerPackage = "pkg"
    case discImage = "iso"
    case signedArchive = "xip"
    /// A `.zip` may be an installer or a user archive. Never selected by default.
    case zipArchive = "zip"

    var fileExtension: String { rawValue }

    /// Whether this format is almost certainly an installer. `.zip` is the only exception.
    var isLikelyInstaller: Bool { self != .zipArchive }

    var displayName: String {
        switch self {
        case .diskImage:
            return "磁盘映像"
        case .installerPackage:
            return "安装包"
        case .discImage:
            return "光盘映像"
        case .signedArchive:
            return "签名归档"
        case .zipArchive:
            return "压缩包"
        }
    }

    /// Stable synthetic target ID (`DiskCleanRuleCatalogV2` builds targets from this).
    /// Written as-is into audit logs; changing it changes historical record semantics.
    var targetID: String {
        "installer." + rawValue
    }

    static let byExtension: [String: DiskCleanInstallerKind] = Dictionary(
        uniqueKeysWithValues: DiskCleanInstallerKind.allCases.map { ($0.rawValue, $0) }
    )
}

// MARK: - Candidate

struct DiskCleanInstallerCandidate: Identifiable, Equatable, Sendable {
    /// Why the item is not selected by default. Selected candidates have no note.
    enum Note: Equatable, Sendable {
        /// Modified within 7 days; may still be in use (just downloaded, pending install).
        case recentlyModified
        /// A `.zip` is not necessarily an installer.
        case mayNotBeInstaller
    }

    /// Physical path (Downloads directory realpath-normalized, then filename appended; leaf not resolved).
    let path: String
    let kind: DiskCleanInstallerKind
    /// Logical size for preview. **Authoritative size still comes from the unified sizing pipeline**
    /// (design §3.2 typed path); this is only `st_size` captured at discovery for immediate list display.
    let byteSize: Int64
    let modifiedAt: Date
    let isSelectedByDefault: Bool
    let note: Note?

    var id: String { path }

    var displayName: String { (path as NSString).lastPathComponent }
}

// MARK: - Scan result

/// Result of scanning `~/Downloads`.
///
/// `denied` and `scanned(candidates: [])` **must stay distinct**: when TCC denies access the
/// directory may still hold tens of GB of installers, and showing "nothing to clean" would lie.
/// The former should guide authorization; the latter is truly empty.
enum DiskCleanInstallerScanOutcome: Equatable, Sendable {
    case scanned(candidates: [DiskCleanInstallerCandidate])
    /// Permission denied (TCC not granted or directory permissions).
    case denied(path: String)
    /// Otherwise unavailable: missing path, not a directory, non-local volume.
    case unavailable(path: String, reason: DiskCleanScanCompleteness.PartialReason)

    var candidates: [DiskCleanInstallerCandidate] {
        if case let .scanned(candidates) = self { return candidates }
        return []
    }
}

// MARK: - Scanner

/// Leftover-installer scan (design §10.2).
///
/// `~/Downloads` is **top-level only, no recursion**: subdirectories are usually user-organized
/// material, and recursing for `.dmg` would surface already-archived content.
///
/// Blocking, but only top-level bulk metadata reads plus `fstatat` for matching installers; cost scales with
/// entry count and never descends, so WorkerPool abandon budgets are unnecessary—that machinery
/// is for recursive sizing that can hang forever.
struct DiskCleanInstallerScanner: Sendable {
    /// Installers older than this age are selected by default. Fresh downloads may not be installed yet.
    static let defaultStaleAge: TimeInterval = 7 * 24 * 60 * 60

    /// Scan scope. Tilde-prefixed so the rule catalog can write it into `reservedRootPaths`
    /// (`expandedReservedRootPaths()` expands it).
    static let defaultDownloadsPath = "~/Downloads"

    private let downloadsPath: String
    private let staleAge: TimeInterval
    private let opener: DiskCleanRootOpener
    private let sourceFactory: any DiskCleanDirectoryEntrySourceFactory
    private let now: @Sendable () -> Date

    /// `downloadsPath` is the injection point: tests pass a temp directory and never touch real `~/Downloads`.
    init(
        downloadsPath: String = DiskCleanRuleTarget.expandHome(
            in: DiskCleanInstallerScanner.defaultDownloadsPath,
            homeDirectory: NSHomeDirectory()
        ),
        staleAge: TimeInterval = defaultStaleAge,
        opener: DiskCleanRootOpener = DiskCleanRootOpener(),
        sourceFactory: any DiskCleanDirectoryEntrySourceFactory = DiskCleanDiscoveryEntrySourceFactory(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.downloadsPath = downloadsPath
        self.staleAge = staleAge
        self.opener = opener
        self.sourceFactory = sourceFactory
        self.now = now
    }

    func scan() -> DiskCleanInstallerScanOutcome {
        // Fully resolve the directory with realpath (user Downloads may be a symlink to an
        // external volume). On failure, pass the original path to the opener so it reports the
        // precise failure reason instead of guessing here.
        let path = DiskCleanPhysicalPath.realpath(of: downloadsPath) ?? downloadsPath

        switch opener.open(path: path) {
        case let .failed(reason):
            return reason == .permissionDenied ? .denied(path: path) : .unavailable(path: path, reason: reason)

        case .resolved:
            // Not a directory: Downloads was replaced by a file or symlink.
            return .unavailable(path: path, reason: .walkError)

        case let .directory(fileDescriptor, _):
            return collect(fileDescriptor: fileDescriptor, directoryPath: path)
        }
    }

    // MARK: Internals

    /// Takes ownership of `fileDescriptor`.
    private func collect(fileDescriptor: Int32, directoryPath: String) -> DiskCleanInstallerScanOutcome {
        let source: any DiskCleanDirectoryEntrySource
        do {
            source = try sourceFactory.makeSource(fileDescriptor: fileDescriptor)
        } catch {
            // Protocol contract: on makeSource throw, fd ownership remains with the caller.
            close(fileDescriptor)
            let code = (error as? DiskCleanPOSIXError)?.code ?? EIO
            return code == EPERM || code == EACCES
                ? .denied(path: directoryPath)
                : .unavailable(path: directoryPath, reason: .walkError)
        }
        defer { source.close() }

        let observedAt = now()
        var candidates: [DiskCleanInstallerCandidate] = []

        do {
            while let batch = try source.nextBatch() {
                for entry in batch {
                    if case let .unresolved(code) = entry {
                        // A vanished entry can be skipped; other failures may hide installers
                        // or signal a malformed bulk batch and must not look like success.
                        if code == ENOENT { continue }
                        throw DiskCleanPOSIXError(code: code)
                    }
                    guard case let .resolved(resolved) = entry else { continue }
                    // Regular files only: do not follow symlinks (would delete the link, not the installer),
                    // and do not recurse into directories.
                    guard resolved.fileType == .regularFile else { continue }
                    guard
                        let name = Self.name(of: resolved),
                        let kind = DiskCleanInstallerKind.byExtension[(name as NSString).pathExtension.lowercased()],
                        let status = Self.status(name: name, directoryFileDescriptor: source.directoryFileDescriptor)
                    else { continue }

                    let modifiedAt = DiskCleanRootIdentity.date(from: status.st_mtimespec)
                    candidates.append(
                        makeCandidate(
                            path: directoryPath + "/" + name,
                            kind: kind,
                            byteSize: max(status.st_size, 0),
                            modifiedAt: modifiedAt,
                            observedAt: observedAt
                        )
                    )
                }
            }
        } catch {
            // Never treat an enumeration failure as a successful partial scan.
            let code = (error as? DiskCleanPOSIXError)?.code ?? EIO
            return code == EPERM || code == EACCES
                ? .denied(path: directoryPath)
                : .unavailable(path: directoryPath, reason: .walkError)
        }

        // readdir order is filesystem-defined; sorting stabilizes both the list and tests.
        return .scanned(candidates: candidates.sorted { $0.path < $1.path })
    }

    private func makeCandidate(
        path: String,
        kind: DiskCleanInstallerKind,
        byteSize: Int64,
        modifiedAt: Date,
        observedAt: Date
    ) -> DiskCleanInstallerCandidate {
        let isStale = observedAt.timeIntervalSince(modifiedAt) > staleAge
        let note: DiskCleanInstallerCandidate.Note?
        if !kind.isLikelyInstaller {
            note = .mayNotBeInstaller
        } else if !isStale {
            note = .recentlyModified
        } else {
            note = nil
        }

        return DiskCleanInstallerCandidate(
            path: path,
            kind: kind,
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            isSelectedByDefault: kind.isLikelyInstaller && isStale,
            note: note
        )
    }

    /// Separate `fstatat` for mtime—directory entries carry type and size only, not timestamps.
    /// Reuse the same call's `st_size` so size and time come from one observation.
    private static func status(name: String, directoryFileDescriptor: Int32) -> stat? {
        var status = stat()
        guard fstatat(directoryFileDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        // The entry may have changed since the bulk read. Only a current regular file is an installer.
        guard DiskCleanRootIdentity.FileType(mode: status.st_mode) == .regularFile else { return nil }
        return status
    }

    private static func name(of entry: DiskCleanResolvedEntry) -> String? {
        let bytes = entry.nameBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        // Invalid UTF-8 names cannot safely become candidate paths; prefer under-reporting.
        return String(bytes: bytes, encoding: .utf8)
    }
}
