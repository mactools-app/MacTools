import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MacToolsPluginKit

enum WindowSwitcherConstants {
    static let pluginID = "window-switcher"
    static let shortcutDefinitionID = "switcher"
    static let shortcutActionID = "switch"
    static let accessibilityPermissionID = "accessibility"
    static let currentAppShortcutID = "current-app"
    static let currentAppActionID = "switch-current-app"
}

enum WindowSwitcherMode: String, Codable, CaseIterable, Identifiable {
    case keyWindow
    case searchSelect
    case directCycle

    var id: String { rawValue }

    var next: WindowSwitcherMode {
        switch self {
        case .searchSelect: .directCycle
        case .directCycle: .keyWindow
        case .keyWindow: .searchSelect
        }
    }
}

enum WindowSwitcherSortMode: String, Codable, CaseIterable, Identifiable {
    case recentUse
    case fixed

    var id: String { rawValue }
}

enum WindowSwitcherLayout: String, Codable {
    case grid, list
}

struct WindowSwitcherConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var mode: WindowSwitcherMode
    var sortMode: WindowSwitcherSortMode
    var protectsLegacyCommands = false
    var interactionVersion: Int = 2
    var usesCompanionDefaults: Bool = true
    var showsPreview: Bool = true
    var preferredLayout: WindowSwitcherLayout? = nil
    var includesMinimizedWindows = true
    var includesOtherDesktopWindows = true
    var includesFullscreenSpaceWindows = true

    init(
        isEnabled: Bool,
        mode: WindowSwitcherMode,
        sortMode: WindowSwitcherSortMode
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.sortMode = sortMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.mode = try container.decodeIfPresent(WindowSwitcherMode.self, forKey: .mode) ?? .keyWindow
        // Only the experimental search builds wrote companion-default metadata.
        // Stable keyWindow profiles keep their assigned-key behavior.
        if mode == .keyWindow, !container.contains(.interactionVersion), container.contains(.usesCompanionDefaults) {
            mode = .searchSelect
        }
        protectsLegacyCommands = try container.decodeIfPresent(Bool.self, forKey: .protectsLegacyCommands)
            ?? !container.contains(.interactionVersion)
        self.sortMode = try container.decodeIfPresent(WindowSwitcherSortMode.self, forKey: .sortMode) ?? .recentUse
        // Existing installations keep their inherited Command-Tab binding until
        // they explicitly choose the companion preset. Custom bindings are untouched.
        self.usesCompanionDefaults = try container.decodeIfPresent(Bool.self, forKey: .usesCompanionDefaults) ?? false
        self.showsPreview = try container.decodeIfPresent(Bool.self, forKey: .showsPreview) ?? false
        self.preferredLayout = try container.decodeIfPresent(WindowSwitcherLayout.self, forKey: .preferredLayout)
        self.includesMinimizedWindows = try container.decodeIfPresent(Bool.self, forKey: .includesMinimizedWindows) ?? true
        self.includesOtherDesktopWindows = try container.decodeIfPresent(Bool.self, forKey: .includesOtherDesktopWindows) ?? true
        self.includesFullscreenSpaceWindows = try container.decodeIfPresent(Bool.self, forKey: .includesFullscreenSpaceWindows) ?? true
    }

    var listingPolicy: WindowSwitcherListingPolicy {
        WindowSwitcherListingPolicy(
            includesMinimizedWindows: includesMinimizedWindows,
            includesOtherDesktopWindows: includesOtherDesktopWindows,
            includesFullscreenSpaceWindows: includesFullscreenSpaceWindows
        )
    }

    static let `default` = WindowSwitcherConfiguration(
        isEnabled: true,
        mode: .searchSelect,
        sortMode: .recentUse
    )

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case mode
        case sortMode
        case protectsLegacyCommands
        case interactionVersion
        case usesCompanionDefaults
        case showsPreview
        case preferredLayout
        case includesMinimizedWindows
        case includesOtherDesktopWindows
        case includesFullscreenSpaceWindows
    }
}

struct WindowSwitcherShortcutBindingState: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var manual: [String: String]
    var automatic: [String: String]

    init(
        version: Int = currentVersion,
        manual: [String: String] = [:],
        automatic: [String: String] = [:]
    ) {
        self.version = version
        self.manual = manual
        self.automatic = automatic
    }
}

enum WindowSwitcherShortcutCustomizationResult {
    case updated([WindowSwitcherAppEntry])
    case conflict
    case unavailable
}

@MainActor
final class WindowSwitcherStore: ObservableObject {
    private enum Keys {
        static let configuration = "configuration"
        static let shortcutBindings = "shortcut-bindings"
        static let obsoleteShortcutAssignments = "shortcut-assignments"
    }

    @Published private(set) var configuration: WindowSwitcherConfiguration
    @Published private(set) var shortcutBindings: WindowSwitcherShortcutBindingState

    private let storage: PluginStorage
    private let processIsRunning: (pid_t) -> Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        storage: PluginStorage,
        processIsRunning: @escaping (pid_t) -> Bool = {
            NSRunningApplication(processIdentifier: $0)?.isTerminated == false
        }
    ) {
        self.storage = storage
        _ = Self.portableStore(storage: storage).recover()
        self.processIsRunning = processIsRunning
        if let data = storage.data(forKey: Keys.configuration),
           let loaded = try? decoder.decode(WindowSwitcherConfiguration.self, from: data) {
            self.configuration = loaded
        } else if storage.object(forKey: Keys.configuration) != nil || storage.object(forKey: Keys.shortcutBindings) != nil
                    || storage.object(forKey: Keys.obsoleteShortcutAssignments) != nil {
            // Older default-mode users did not necessarily save configuration.
            // Letter assignment storage is evidence of an existing installation.
            var legacy = WindowSwitcherConfiguration.default
            legacy.mode = .keyWindow
            legacy.usesCompanionDefaults = false
            self.configuration = legacy
        } else {
            self.configuration = .default
        }

        if let data = storage.data(forKey: Keys.shortcutBindings),
           let loaded = try? decoder.decode(WindowSwitcherShortcutBindingState.self, from: data) {
            self.shortcutBindings = loaded
        } else {
            self.shortcutBindings = WindowSwitcherShortcutBindingState()
        }
        if storage.object(forKey: Keys.shortcutBindings) != nil || configuration.mode == .keyWindow {
            configuration.protectsLegacyCommands = true
        }
        // Persist the interaction version so explicit legacy choices cannot be
        // mistaken for experimental search profiles on the next launch.
        persist()
    }

    private struct PortableConfiguration: Codable, Equatable {
        let isEnabled: Bool
        let mode: WindowSwitcherMode
        let sortMode: WindowSwitcherSortMode
        let showsPreview: Bool
        let preferredLayout: WindowSwitcherLayout?
        let includesMinimizedWindows: Bool
        let includesOtherDesktopWindows: Bool
        let includesFullscreenSpaceWindows: Bool
    }
    private struct PortablePreferences: Codable {
        let formatVersion: Int
        let configuration: PortableConfiguration
        let manualAppBindings: [String: String]
    }
    var onPersistentPreferencesChange: (() -> Void)?
    private static func portableStore(storage: any PluginStorage) -> PortablePreferencesStore {
        PortablePreferencesStore(storage: storage, fields: [
            Keys.configuration: .data(try! JSONEncoder().encode(WindowSwitcherConfiguration.default), maximumBytes: 16_384) {
                (try? JSONDecoder().decode(WindowSwitcherConfiguration.self, from: $0)) != nil
            },
            Keys.shortcutBindings: .data(try! JSONEncoder().encode(WindowSwitcherShortcutBindingState()), maximumBytes: 256 * 1_024) {
                (try? JSONDecoder().decode(WindowSwitcherShortcutBindingState.self, from: $0))?.version == WindowSwitcherShortcutBindingState.currentVersion
            }
        ])
    }
    private var portableStore: PortablePreferencesStore { Self.portableStore(storage: storage) }
    private static func isPortableIdentity(_ identity: String) -> Bool {
        guard identity.hasPrefix("bundle:") else { return false }
        let bundleID = identity.dropFirst("bundle:".count)
        return !bundleID.isEmpty && bundleID.utf8.count <= 255
            && bundleID.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0) }
    }
    private func portableBindings(_ state: WindowSwitcherShortcutBindingState) -> [String: String] {
        state.manual.filter { Self.isPortableIdentity($0.key) }
    }
    private func portableConfiguration(_ value: WindowSwitcherConfiguration) -> PortableConfiguration {
        PortableConfiguration(isEnabled: value.isEnabled, mode: value.mode, sortMode: value.sortMode,
            showsPreview: value.showsPreview, preferredLayout: value.preferredLayout,
            includesMinimizedWindows: value.includesMinimizedWindows, includesOtherDesktopWindows: value.includesOtherDesktopWindows,
            includesFullscreenSpaceWindows: value.includesFullscreenSpaceWindows)
    }
    private func decodedPortable(_ data: Data) -> PortablePreferences? {
        guard data.count <= 128 * 1_024, let payload = try? decoder.decode(PortablePreferences.self, from: data), payload.formatVersion == 1,
              payload.manualAppBindings.count <= WindowSwitcherShortcutAssignment.maximumShortcutCount,
              payload.manualAppBindings.allSatisfy({ Self.isPortableIdentity($0.key)
                  && WindowSwitcherShortcutAssignment.normalizedManualToken($0.value) == $0.value
                  && !WindowSwitcherShortcutAssignment.reservedTokens.contains($0.value) }) else { return nil }
        return payload
    }
    func portableBackup() -> Data? {
        guard portableStore.backup() != nil else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(PortablePreferences(formatVersion: 1, configuration: portableConfiguration(configuration), manualAppBindings: portableBindings(shortcutBindings))),
              decodedPortable(data) != nil else { return nil }
        return data
    }
    func restorePortableBackup(_ data: Data) -> Bool {
        guard shortcutBindings.version == WindowSwitcherShortcutBindingState.currentVersion,
              let payload = decodedPortable(data) else { return false }
        var candidate = configuration
        candidate.isEnabled = payload.configuration.isEnabled
        candidate.mode = payload.configuration.mode
        candidate.sortMode = payload.configuration.sortMode
        candidate.showsPreview = payload.configuration.showsPreview
        candidate.preferredLayout = payload.configuration.preferredLayout
        candidate.includesMinimizedWindows = payload.configuration.includesMinimizedWindows
        candidate.includesOtherDesktopWindows = payload.configuration.includesOtherDesktopWindows
        candidate.includesFullscreenSpaceWindows = payload.configuration.includesFullscreenSpaceWindows
        if candidate.mode == .keyWindow { candidate.protectsLegacyCommands = true }
        var bindings = shortcutBindings
        bindings.manual = bindings.manual.filter { !Self.isPortableIdentity($0.key) }
            .merging(payload.manualAppBindings, uniquingKeysWith: { _, incoming in incoming })
        guard let configData = try? encoder.encode(candidate), let bindingData = try? encoder.encode(bindings) else { return false }
        let changed = portableConfiguration(configuration) != payload.configuration || portableBindings(shortcutBindings) != payload.manualAppBindings
        guard portableStore.commit([Keys.configuration: .data(configData), Keys.shortcutBindings: .data(bindingData)]) else { return false }
        configuration = candidate
        shortcutBindings = bindings
        if changed { onPersistentPreferencesChange?() }
        return true
    }

    func setMode(_ mode: WindowSwitcherMode) {
        var candidate = configuration
        candidate.mode = mode
        if mode == .keyWindow { candidate.protectsLegacyCommands = true }
        _ = commitConfiguration(candidate)
    }
    func setSortMode(_ value: WindowSwitcherSortMode) { var candidate = configuration; candidate.sortMode = value; _ = commitConfiguration(candidate) }
    func setEnabled(_ value: Bool) { var candidate = configuration; candidate.isEnabled = value; _ = commitConfiguration(candidate) }
    func useCompanionDefaults() { var candidate = configuration; candidate.usesCompanionDefaults = true; _ = commitConfiguration(candidate) }
    func setShowsPreview(_ value: Bool) { var candidate = configuration; candidate.showsPreview = value; _ = commitConfiguration(candidate) }
    func setIncludesMinimizedWindows(_ value: Bool) { var candidate = configuration; candidate.includesMinimizedWindows = value; _ = commitConfiguration(candidate) }
    func setIncludesOtherDesktopWindows(_ value: Bool) { var candidate = configuration; candidate.includesOtherDesktopWindows = value; _ = commitConfiguration(candidate) }
    func setIncludesFullscreenSpaceWindows(_ value: Bool) { var candidate = configuration; candidate.includesFullscreenSpaceWindows = value; _ = commitConfiguration(candidate) }
    func setPreferredLayout(_ value: WindowSwitcherLayout) { var candidate = configuration; candidate.preferredLayout = value; _ = commitConfiguration(candidate) }

    private func persist() { _ = commitConfiguration(configuration) }

    @discardableResult
    private func commitConfiguration(_ candidate: WindowSwitcherConfiguration) -> Bool {
        let previous = storage.data(forKey: Keys.configuration).flatMap { try? decoder.decode(WindowSwitcherConfiguration.self, from: $0) }
        guard let data = try? encoder.encode(candidate), portableStore.commit([Keys.configuration: .data(data)]) else { return false }
        configuration = candidate
        if previous.map({ portableConfiguration($0) != portableConfiguration(candidate) }) ?? true { onPersistentPreferencesChange?() }
        return true
    }

    var protectedCommandKeys: Set<String> {
        Set((Array(shortcutBindings.manual.values) + Array(shortcutBindings.automatic.values)).compactMap {
            guard let key = WindowSwitcherSelectionShortcut(storageValue: $0), key.usesCommand else { return nil }
            return key.key
        })
    }

    func assignShortcuts(to entries: [WindowSwitcherAppEntry]) -> [WindowSwitcherAppEntry] {
        removeExpiredWindowBindings(for: entries)
        let result = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            bindingState: shortcutBindings
        )

        if result.bindingState != shortcutBindings {
            shortcutBindings = result.bindingState
            persistShortcutBindings()
        }

        return result.entries
    }

    func setManualShortcut(
        _ rawToken: String?,
        for entryID: String,
        in entries: [WindowSwitcherAppEntry]
    ) -> WindowSwitcherShortcutCustomizationResult {
        removeExpiredWindowBindings(for: entries)
        let identities = WindowSwitcherShortcutAssignment.identities(for: entries)
        guard let targetIndex = entries.firstIndex(where: { $0.id == entryID }),
              identities.indices.contains(targetIndex)
        else {
            return .unavailable
        }

        let targetIdentity = identities[targetIndex]
        let current = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            bindingState: shortcutBindings
        )
        var updatedState = current.bindingState

        if let rawToken {
            guard let token = WindowSwitcherShortcutAssignment.normalizedManualToken(rawToken) else {
                return .unavailable
            }
            guard !WindowSwitcherShortcutAssignment.reservedTokens.contains(token) else { return .conflict }

            guard !hasShortcutConflict(
                token,
                targetIdentity: targetIdentity,
                identities: identities,
                current: current
            ) else {
                return .conflict
            }

            updatedState.manual[targetIdentity] = token
        } else {
            updatedState.manual.removeValue(forKey: targetIdentity)
        }

        let appIdentity = entries[targetIndex].appIdentifier
        if Self.isPortableIdentity(appIdentity), updatedState.manual[appIdentity] != nil,
           entries.filter({ $0.appIdentifier == appIdentity }).count == 1 {
            updatedState.manual[appIdentity] = rawToken.flatMap(WindowSwitcherShortcutAssignment.normalizedManualToken)
        }
        let updated = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            bindingState: updatedState
        )
        if updated.bindingState != shortcutBindings {
            shortcutBindings = updated.bindingState
            guard persistShortcutBindings() else { return .unavailable }
        }
        return .updated(updated.entries)
    }

    func hasShortcutConflict(
        _ rawToken: String,
        for entryID: String,
        in entries: [WindowSwitcherAppEntry]
    ) -> Bool {
        removeExpiredWindowBindings(for: entries)
        guard let token = WindowSwitcherShortcutAssignment.normalizedManualToken(rawToken) else {
            return true
        }
        guard !WindowSwitcherShortcutAssignment.reservedTokens.contains(token) else { return true }

        let identities = WindowSwitcherShortcutAssignment.identities(for: entries)
        guard let targetIndex = entries.firstIndex(where: { $0.id == entryID }),
              identities.indices.contains(targetIndex)
        else {
            return true
        }

        let current = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            bindingState: shortcutBindings
        )
        return hasShortcutConflict(
            token,
            targetIdentity: identities[targetIndex],
            identities: identities,
            current: current
        )
    }

    private func hasShortcutConflict(
        _ token: String,
        targetIdentity: String,
        identities: [String],
        current: WindowSwitcherShortcutAssignment.Result
    ) -> Bool {
        let activeIdentities = Set(identities)
        let conflictsWithSavedManualBinding = current.bindingState.manual.contains {
            identity, assignedToken in
            identity != targetIdentity
                && !WindowSwitcherShortcutAssignment.isUnresolvedLegacyIdentity(
                    identity,
                    activeIdentities: activeIdentities
                )
                && WindowSwitcherShortcutAssignment.normalizedManualToken(assignedToken) == token
        }
        let conflictsWithRunningEntry = current.entries.enumerated().contains { index, entry in
            identities[index] != targetIdentity && entry.shortcutToken == token
        }
        return conflictsWithSavedManualBinding || conflictsWithRunningEntry
    }

    @discardableResult
    private func persistShortcutBindings() -> Bool {
        let previous = storage.data(forKey: Keys.shortcutBindings).flatMap { try? decoder.decode(WindowSwitcherShortcutBindingState.self, from: $0) } ?? .init()
        guard let data = try? encoder.encode(shortcutBindings), portableStore.commit([Keys.shortcutBindings: .data(data)]) else {
            shortcutBindings = previous
            return false
        }
        if portableBindings(previous) != portableBindings(shortcutBindings) { onPersistentPreferencesChange?() }
        return true
    }

    private func removeExpiredWindowBindings(for entries: [WindowSwitcherAppEntry]) {
        let activeProcessIdentifiers = Set(entries.compactMap { entry in
            entry.isWindowEntry ? entry.processIdentifier : nil
        })
        let previousState = shortcutBindings

        shortcutBindings.manual = shortcutBindings.manual.filter { identity, _ in
            !isExpiredWindowIdentity(identity, activeProcessIdentifiers: activeProcessIdentifiers)
        }
        shortcutBindings.automatic = shortcutBindings.automatic.filter { identity, _ in
            !isExpiredWindowIdentity(identity, activeProcessIdentifiers: activeProcessIdentifiers)
        }

        if shortcutBindings != previousState {
            persistShortcutBindings()
        }
    }

    private func isExpiredWindowIdentity(
        _ identity: String,
        activeProcessIdentifiers: Set<pid_t>
    ) -> Bool {
        let components = identity.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 4,
              components[0] == "window",
              let processIdentifier = pid_t(components[1]),
              !activeProcessIdentifiers.contains(processIdentifier)
        else {
            return false
        }

        return !processIsRunning(processIdentifier)
    }
}

struct WindowSwitcherAppEntry: Identifiable {
    var id: String
    var processIdentifier: pid_t
    let bundleIdentifier: String?
    let appName: String
    var windowTitle: String?
    let icon: NSImage?
    let windowElement: AXUIElement?
    let isMinimized: Bool
    var workerWindowID: String? = nil
    var windowNumber: CGWindowID?
    let windowBounds: CGRect?
    let applicationLaunchDate: Date?
    var shortcutToken: String?
    var bounds: CGRect = .zero
    var isHidden: Bool = false
    var metadataUnavailable: Bool = false
    var displayNameContext: String? = nil
    var displayID: UInt32? = nil
    var axWorkerPID: pid_t? = nil
    var windowOwnerPID: pid_t? = nil
    /// Capture candidates may be owned by a compositor helper that differs
    /// from both the host and the AX worker. Only catalog-verified related
    /// processes are allowed to participate in cross-process preview matching.
    var previewProcessIdentifiers: Set<pid_t> = []
    var isOnOtherDesktop: Bool = false
    var isOnFullscreenSpace: Bool = false

    init(
        id: String,
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        appName: String,
        windowTitle: String?,
        icon: NSImage?,
        windowElement: AXUIElement?,
        isMinimized: Bool,
        windowNumber: CGWindowID? = nil,
        windowBounds: CGRect? = nil,
        applicationLaunchDate: Date? = nil,
        shortcutToken: String?,
        bounds: CGRect = .zero,
        isHidden: Bool = false,
        metadataUnavailable: Bool = false,
        displayNameContext: String? = nil,
        displayID: UInt32? = nil
    ) {
        self.id = id
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.icon = icon
        self.windowElement = windowElement
        self.isMinimized = isMinimized
        self.windowNumber = windowNumber
        self.windowBounds = windowBounds
        self.applicationLaunchDate = applicationLaunchDate
        self.shortcutToken = shortcutToken
        self.bounds = bounds == .zero ? windowBounds ?? .zero : bounds
        self.isHidden = isHidden
        self.metadataUnavailable = metadataUnavailable
        self.displayNameContext = displayNameContext
        self.displayID = displayID
    }

    var displayName: String {
        guard let title = cleanWindowTitle else {
            return isWindowEntry ? "\(appName) — 无标题窗口" : appName
        }

        return title
    }

    func localizedGridTitle(using localization: PluginLocalization) -> String {
        if let title = cleanWindowTitle { return title }
        return appName
    }

    func localizedDisplayName(using localization: PluginLocalization) -> String {
        guard let title = cleanWindowTitle else {
            return isWindowEntry ? localization.format("window.untitled", defaultValue: "%@ — 无标题窗口", appName) : appName
        }
        return title
    }

    var displaySubtitle: String? {
        guard let title = cleanWindowTitle,
              title.caseInsensitiveCompare(appName) != .orderedSame
        else {
            return nil
        }

        return appName
    }

    var shortcutDisplay: String? {
        shortcutToken.flatMap(WindowSwitcherSelectionShortcut.init(storageValue:))?.displayValue
    }

    var isWindowEntry: Bool {
        windowElement != nil || windowNumber != nil
    }

    var owningProcessIdentifier: pid_t {
        windowOwnerPID ?? processIdentifier
    }

    var appIdentifier: String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier)"
        }

        return "pid:\(processIdentifier)"
    }

    private var cleanWindowTitle: String? {
        guard let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else {
            return nil
        }

        return title
    }
}

struct WindowSwitcherSelectionShortcut: Equatable {
    private static let commandPrefix = "cmd+"

    let key: String
    let usesCommand: Bool

    init?(key: String, usesCommand: Bool) {
        let normalizedKey = key.lowercased()
        guard Self.isAllowedKey(normalizedKey) else {
            return nil
        }

        self.key = normalizedKey
        self.usesCommand = usesCommand
    }

    init?(storageValue: String) {
        let normalized = storageValue.lowercased()
        let usesCommand = normalized.hasPrefix(Self.commandPrefix)
        let key = usesCommand
            ? String(normalized.dropFirst(Self.commandPrefix.count))
            : normalized
        self.init(key: key, usesCommand: usesCommand)
    }

    var storageValue: String {
        usesCommand ? Self.commandPrefix + key : key
    }

    var displayValue: String {
        (usesCommand ? "⌘" : "") + key.uppercased()
    }

    private static func isAllowedKey(_ key: String) -> Bool {
        guard key.unicodeScalars.count == 1,
              let scalar = key.unicodeScalars.first
        else {
            return false
        }

        return (scalar.value >= 97 && scalar.value <= 122)
            || (scalar.value >= 48 && scalar.value <= 57)
    }
}

extension WindowSwitcherAppEntry: Equatable {
    static func == (lhs: WindowSwitcherAppEntry, rhs: WindowSwitcherAppEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.displaySubtitle == rhs.displaySubtitle
            && lhs.shortcutToken == rhs.shortcutToken
            && lhs.isMinimized == rhs.isMinimized
            && lhs.isHidden == rhs.isHidden
            && lhs.metadataUnavailable == rhs.metadataUnavailable
            && lhs.bounds == rhs.bounds
            && lhs.windowNumber == rhs.windowNumber
            && lhs.displayNameContext == rhs.displayNameContext
            && lhs.displayID == rhs.displayID
            && lhs.axWorkerPID == rhs.axWorkerPID
            && lhs.windowOwnerPID == rhs.windowOwnerPID
            && lhs.previewProcessIdentifiers == rhs.previewProcessIdentifiers
            && lhs.isOnOtherDesktop == rhs.isOnOtherDesktop
            && lhs.isOnFullscreenSpace == rhs.isOnFullscreenSpace
    }
}

enum WindowSwitcherShortcutAssignment {
    struct Result {
        let entries: [WindowSwitcherAppEntry]
        let bindingState: WindowSwitcherShortcutBindingState
    }

    private struct Target {
        let index: Int
        let identity: String
        let legacyIdentity: String?
        let preferredToken: String?
    }

    static let letterKeyOrder: [String] = [
        "f", "j", "d", "k", "s", "l", "a", "g", "h",
        "e", "i", "r", "u", "w", "o", "q", "p",
        "c", "m", "v", "n", "x", "b", "z", "t", "y",
    ]
    static let digitKeyOrder: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    static let reservedTokens: Set<String> = ["cmd+f"]
    static let maximumShortcutCount = (letterKeyOrder.count + digitKeyOrder.count) * 2 - reservedTokens.count

    static func assignShortcuts(to entries: [WindowSwitcherAppEntry]) -> [WindowSwitcherAppEntry] {
        assignShortcuts(to: entries, bindingState: WindowSwitcherShortcutBindingState()).entries
    }

    static func assignShortcuts(
        to entries: [WindowSwitcherAppEntry],
        bindingState: WindowSwitcherShortcutBindingState
    ) -> Result {
        guard !entries.isEmpty else {
            return Result(entries: [], bindingState: bindingState)
        }

        let targets = assignmentTargets(for: entries)
        let resolvedBindingState = migrateUnambiguousLegacyBindings(
            from: bindingState,
            targets: targets
        )
        let activeIdentities = Set(targets.map(\.identity))
        let reservedManualTokens = Set<String>(resolvedBindingState.manual.compactMap { identity, rawToken in
            guard !isUnresolvedLegacyIdentity(identity, activeIdentities: activeIdentities) else {
                return nil
            }

            return normalizedManualToken(rawToken)
        })
        let availableTokens = shortcutTokens(count: maximumShortcutCount)
        var assignedTokens = Array<String?>(repeating: nil, count: entries.count)
        var activeManualTokens = Set<String>()
        var usedTokens = reservedManualTokens.union(reservedTokens)

        for target in targets {
            guard let token = resolvedBindingState.manual[target.identity].flatMap(normalizedManualToken),
                  !reservedTokens.contains(token),
                  activeManualTokens.insert(token).inserted
            else {
                continue
            }

            assignedTokens[target.index] = token
        }

        for target in targets where assignedTokens[target.index] == nil {
            guard let token = resolvedBindingState.automatic[target.identity].flatMap(normalizedShortcutToken),
                  !usedTokens.contains(token)
            else {
                continue
            }

            assignedTokens[target.index] = token
            usedTokens.insert(token)
        }

        for target in targets where assignedTokens[target.index] == nil {
            guard let token = target.preferredToken,
                  !usedTokens.contains(token)
            else {
                continue
            }

            assignedTokens[target.index] = token
            usedTokens.insert(token)
        }

        for target in targets where assignedTokens[target.index] == nil {
            guard let token = availableTokens.first(where: { !usedTokens.contains($0) }) else {
                continue
            }

            assignedTokens[target.index] = token
            usedTokens.insert(token)
        }

        let assignedEntries = entries.enumerated().map { index, entry in
            var copy = entry
            copy.shortcutToken = assignedTokens[index]
            return copy
        }
        let updatedState = updatedBindingState(
            from: resolvedBindingState,
            targets: targets,
            assignedTokens: assignedTokens
        )
        return Result(entries: assignedEntries, bindingState: updatedState)
    }

    static func shortcutTokens(count: Int) -> [String] {
        guard count > 0 else {
            return []
        }

        let plainTokens = letterKeyOrder + digitKeyOrder
        let commandTokens = plainTokens.map { "cmd+\($0)" }.filter { !reservedTokens.contains($0) }
        return Array((plainTokens + commandTokens).prefix(count))
    }

    static func identities(for entries: [WindowSwitcherAppEntry]) -> [String] {
        assignmentTargets(for: entries).map(\.identity)
    }

    static func normalizedManualToken(_ token: String) -> String? {
        WindowSwitcherSelectionShortcut(storageValue: token)?.storageValue
    }

    private static func assignmentTargets(for entries: [WindowSwitcherAppEntry]) -> [Target] {
        var appOccurrences: [String: Int] = [:]
        var axWindowOccurrences: [String: Int] = [:]
        let windowCounts = entries.reduce(into: [String: Int]()) { counts, entry in
            guard entry.isWindowEntry else {
                return
            }

            counts[entry.appIdentifier, default: 0] += 1
        }

        return entries.enumerated().map { index, entry in
            let appIdentifier = entry.appIdentifier
            let ordinalIdentity: String?
            let preferredToken: String?
            if entry.windowElement != nil {
                let occurrence = axWindowOccurrences[appIdentifier, default: 0]
                axWindowOccurrences[appIdentifier] = occurrence + 1
                ordinalIdentity = nil
                preferredToken = occurrence == 0 ? preferredSingleKeyToken(for: entry) : nil
            } else if entry.windowNumber != nil {
                ordinalIdentity = nil
                preferredToken = nil
            } else {
                let occurrence = appOccurrences[appIdentifier, default: 0]
                appOccurrences[appIdentifier] = occurrence + 1
                ordinalIdentity = occurrence == 0
                    ? appIdentifier
                    : "\(appIdentifier)#window:\(occurrence + 1)"
                preferredToken = occurrence == 0 ? preferredSingleKeyToken(for: entry) : nil
            }

            let identity: String
            if let windowNumber = entry.windowNumber {
                identity = "window:\(entry.processIdentifier):cg:\(windowNumber)"
            } else if entry.windowElement != nil {
                identity = "window:\(entry.processIdentifier):ax:\(entry.id)"
            } else {
                identity = ordinalIdentity ?? appIdentifier
            }

            return Target(
                index: index,
                identity: identity,
                legacyIdentity: entry.isWindowEntry && windowCounts[appIdentifier] == 1
                    ? appIdentifier
                    : nil,
                preferredToken: preferredToken
            )
        }
    }

    private static func migrateUnambiguousLegacyBindings(
        from bindingState: WindowSwitcherShortcutBindingState,
        targets: [Target]
    ) -> WindowSwitcherShortcutBindingState {
        var state = bindingState

        for target in targets {
            guard let legacyIdentity = target.legacyIdentity,
                  state.manual[target.identity] == nil,
                  let token = state.manual[legacyIdentity]
            else {
                continue
            }

            state.manual[target.identity] = token
        }

        for target in targets {
            guard let legacyIdentity = target.legacyIdentity,
                  state.automatic[target.identity] == nil,
                  let token = state.automatic.removeValue(forKey: legacyIdentity)
            else {
                continue
            }

            state.automatic[target.identity] = token
        }

        return state
    }

    static func isUnresolvedLegacyIdentity(
        _ identity: String,
        activeIdentities: Set<String>
    ) -> Bool {
        guard !activeIdentities.contains(identity) else {
            return false
        }

        return identity.contains("#window:")
            || identity.hasPrefix("bundle:")
            || identity.hasPrefix("pid:")
    }

    private static func updatedBindingState(
        from bindingState: WindowSwitcherShortcutBindingState,
        targets: [Target],
        assignedTokens: [String?]
    ) -> WindowSwitcherShortcutBindingState {
        var state = bindingState
        state.version = WindowSwitcherShortcutBindingState.currentVersion
        let validManualBindings = state.manual.compactMapValues(normalizedManualToken)
        state.manual = validManualBindings
        let activeTargetIdentities = Set(targets.map(\.identity))
        let effectiveManualBindings = validManualBindings.filter { identity, token in
            !reservedTokens.contains(token) && !isUnresolvedLegacyIdentity(identity, activeIdentities: activeTargetIdentities)
        }
        let manualIdentities = Set(effectiveManualBindings.keys)
        let manualTokens = Set(effectiveManualBindings.values)
        var activeTokens = Set<String>()
        var activeIdentities = Set<String>()

        for target in targets {
            guard let token = assignedTokens[target.index]
            else {
                continue
            }

            activeTokens.insert(token)
            guard !manualIdentities.contains(target.identity) else {
                continue
            }

            state.automatic[target.identity] = token
            activeIdentities.insert(target.identity)
        }

        for (identity, rawToken) in state.automatic {
            guard let token = normalizedShortcutToken(rawToken), !reservedTokens.contains(token) else {
                state.automatic.removeValue(forKey: identity)
                continue
            }

            if isUnresolvedLegacyIdentity(identity, activeIdentities: activeTargetIdentities) {
                continue
            }

            let conflictsWithManual = !manualIdentities.contains(identity) && manualTokens.contains(token)
            let conflictsWithActive = !activeIdentities.contains(identity)
                && !manualIdentities.contains(identity)
                && activeTokens.contains(token)
            if conflictsWithManual || conflictsWithActive {
                state.automatic.removeValue(forKey: identity)
            }
        }

        guard state.automatic.count > 256 else {
            return state
        }

        let retainedIdentities = activeIdentities.union(manualIdentities)
        let retained = state.automatic.filter { retainedIdentities.contains($0.key) }
        let inactive = state.automatic
            .filter { !retainedIdentities.contains($0.key) }
            .sorted { $0.key < $1.key }
            .prefix(max(0, 256 - retained.count))
        state.automatic = inactive.reduce(into: retained) { result, item in
            result[item.key] = item.value
        }
        return state
    }

    private static func preferredSingleKeyToken(for entry: WindowSwitcherAppEntry) -> String? {
        let candidates = [
            entry.appName,
            entry.bundleIdentifier?.split(separator: ".").last.map(String.init),
            entry.bundleIdentifier,
        ].compactMap { $0 }

        for candidate in candidates {
            if let token = firstASCIIKey(in: candidate) {
                return token
            }
        }

        return nil
    }

    private static func firstASCIIKey(in text: String) -> String? {
        for scalar in text.lowercased().unicodeScalars {
            guard scalar.value >= 97, scalar.value <= 122 else {
                continue
            }

            return String(Character(scalar))
        }

        return nil
    }

    private static func normalizedShortcutToken(_ token: String) -> String? {
        WindowSwitcherSelectionShortcut(storageValue: token)?.storageValue
    }
}

enum WindowSwitcherShortcutBindingStore {
    static let defaultBinding = ShortcutBinding(
        keyCode: UInt16(kVK_Tab),
        modifiers: .option
    )
    static let legacyBinding = ShortcutBinding(keyCode: UInt16(kVK_Tab), modifiers: .command)
    static let currentAppBinding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_Grave), modifiers: .command)

    private static let defaultsKey = "shortcut.customization.\(itemID)"

    static var itemID: String {
        "\(WindowSwitcherConstants.pluginID).shortcut.\(WindowSwitcherConstants.shortcutDefinitionID)"
    }

    static func resolvedBinding(userDefaults: UserDefaults = .standard) -> ShortcutBinding? {
        resolvedBinding(id: WindowSwitcherConstants.shortcutDefinitionID, defaultBinding: defaultBinding, userDefaults: userDefaults)
    }

    static func resolvedBinding(id: String, defaultBinding: ShortcutBinding?, userDefaults: UserDefaults = .standard) -> ShortcutBinding? {
        let key = "shortcut.customization.\(WindowSwitcherConstants.pluginID).shortcut.\(id)"
        guard let data = userDefaults.data(forKey: key) else {
            return defaultBinding
        }

        do {
            let customization = try JSONDecoder().decode(ShortcutCustomization.self, from: data)
            return ShortcutStoreResolve.resolve(customization: customization, defaultBinding: defaultBinding)
        } catch {
            return defaultBinding
        }
    }
}

private enum ShortcutStoreResolve {
    static func resolve(customization: ShortcutCustomization, defaultBinding: ShortcutBinding?) -> ShortcutBinding? {
        switch customization {
        case .inheritDefault:
            return defaultBinding
        case let .custom(binding):
            return binding
        case .cleared:
            return nil
        }
    }
}
