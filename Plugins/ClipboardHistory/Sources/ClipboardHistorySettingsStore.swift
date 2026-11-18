import Foundation
import MacToolsPluginKit

enum ClipboardSequentialHUDDismissal: Int, CaseIterable, Identifiable, Sendable {
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30
    case never = -1

    var id: Int { rawValue }
    var interval: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }
}

enum ClipboardSnippetKeywordExpansionStatus: Equatable, Sendable {
    case off
    case noKeywords
    case accessibilityRequired
    case ready
    case unavailable
}

@MainActor
final class ClipboardHistorySettingsStore: ObservableObject {
    private enum Key {
        static let retentionDeferred = "retention-restoration-deferred.v1"
        static let isPaused = "collection-paused"
        static let maximumItemCount = "maximum-item-count"
        static let expirationDays = "expiration-days"
        static let maximumItemByteCount = "maximum-item-byte-count"
        static let maximumTotalPayloadByteCount = "maximum-total-payload-byte-count"
        static let excludedApplications = "excluded-applications"
        static let didCompleteInitialSetup = "did-complete-initial-setup"
        static let didPresentInitialSetup = "did-present-initial-setup"
        static let sequentialHUDDismissal = "sequential-hud-dismissal"
        static let hidesSequentialHUDPreview = "sequential-hud-hide-preview"
        static let showsPanelPreview = "history-panel-show-preview"
        static let keywordExpansionEnabled = "saved-keyword-expansion-enabled"
        static let maximumExpandedTextByteCount = "snippet-maximum-expanded-text-byte-count"
        static let panelPositions = "history-panel-positions-by-display"
        static let remembersPanelFilters = "remember-panel-filters"
        static let panelFilters = "last-panel-filters.v1"
    }

    static let allowedItemCounts = [
        100,
        250,
        500,
        1_000,
        2_500,
        5_000,
        ClipboardHistorySettings.maximumSupportedItemCount,
    ]
    static let allowedItemByteCounts = [
        1 * 1_024 * 1_024,
        5 * 1_024 * 1_024,
        20 * 1_024 * 1_024,
        30 * 1_024 * 1_024,
        50 * 1_024 * 1_024,
    ]
    static let allowedTotalPayloadByteCounts = [
        64 * 1_024 * 1_024,
        256 * 1_024 * 1_024,
        512 * 1_024 * 1_024,
        1 * 1_024 * 1_024 * 1_024,
        ClipboardHistorySettings.maximumSupportedTotalPayloadByteCount,
    ]
    static let allowedExpandedTextByteCounts = [1, 5, 20, 50].map { $0 * 1_024 * 1_024 }

    @Published var maximumExpandedTextByteCount: Int {
        didSet {
            guard !isApplyingPortableSnapshot, maximumExpandedTextByteCount != oldValue else { return }
            let candidate = Self.validExpandedTextByteCount(maximumExpandedTextByteCount)
            let previous = portableStore.currentValues()
            guard portableStore.commit([Key.maximumExpandedTextByteCount: .integer(candidate)]) else {
                isApplyingPortableSnapshot = true
                maximumExpandedTextByteCount = oldValue
                isApplyingPortableSnapshot = false
                return
            }
            if previous != portableStore.currentValues() {
                portableRevision &+= 1
                onPersistentPreferencesChange?()
            }
            onChange?()
        }
    }

    static func validExpandedTextByteCount(_ value: Int) -> Int {
        allowedExpandedTextByteCounts.contains(value) ? value : ClipboardSnippetExpansionContext.defaultMaximumUTF8ByteCount
    }

    @Published var isPaused: Bool {
        didSet {
            storage.set(isPaused, forKey: Key.isPaused)
            onChange?()
        }
    }

    @Published var maximumItemCount: Int {
        didSet {
            guard !isApplyingPortableSnapshot, maximumItemCount != oldValue else { return }
            let candidate = Self.validItemCount(maximumItemCount)
            let previous = portableStore.currentValues()
            guard portableStore.commit([Key.maximumItemCount: .integer(candidate), Key.retentionDeferred: .boolean(false)]) else {
                isApplyingPortableSnapshot = true
                maximumItemCount = oldValue
                isApplyingPortableSnapshot = false
                return
            }
            if previous != portableStore.currentValues() {
                portableRevision &+= 1
                onPersistentPreferencesChange?()
            }
            onChange?()
        }
    }

    @Published var expiration: ClipboardHistoryExpiration {
        didSet {
            guard !isApplyingPortableSnapshot, expiration != oldValue else { return }
            let candidate = expiration
            let previous = portableStore.currentValues()
            guard portableStore.commit([Key.expirationDays: .integer(candidate.rawValue), Key.retentionDeferred: .boolean(false)]) else {
                isApplyingPortableSnapshot = true
                expiration = oldValue
                isApplyingPortableSnapshot = false
                return
            }
            if previous != portableStore.currentValues() {
                portableRevision &+= 1
                onPersistentPreferencesChange?()
            }
            onChange?()
        }
    }

    @Published var maximumItemByteCount: Int {
        didSet {
            guard !isApplyingPortableSnapshot, maximumItemByteCount != oldValue else { return }
            let candidate = Self.validItemByteCount(maximumItemByteCount)
            let previous = portableStore.currentValues()
            guard portableStore.commit([Key.maximumItemByteCount: .integer(candidate), Key.retentionDeferred: .boolean(false)]) else {
                isApplyingPortableSnapshot = true
                maximumItemByteCount = oldValue
                isApplyingPortableSnapshot = false
                return
            }
            if previous != portableStore.currentValues() {
                portableRevision &+= 1
                onPersistentPreferencesChange?()
            }
            onChange?()
        }
    }

    @Published var maximumTotalPayloadByteCount: Int {
        didSet {
            guard !isApplyingPortableSnapshot, maximumTotalPayloadByteCount != oldValue else { return }
            let candidate = Self.validTotalPayloadByteCount(maximumTotalPayloadByteCount)
            let previous = portableStore.currentValues()
            guard portableStore.commit([Key.maximumTotalPayloadByteCount: .integer(candidate), Key.retentionDeferred: .boolean(false)]) else {
                isApplyingPortableSnapshot = true
                maximumTotalPayloadByteCount = oldValue
                isApplyingPortableSnapshot = false
                return
            }
            if previous != portableStore.currentValues() {
                portableRevision &+= 1
                onPersistentPreferencesChange?()
            }
            onChange?()
        }
    }

    @Published var excludedApplications: [ClipboardExcludedApplication] {
        didSet {
            guard !isApplyingPortableSnapshot, excludedApplications != oldValue else { return }
            let candidate = Self.normalizedApplications(excludedApplications)
            let previous = portableStore.currentValues()
            guard let data = try? JSONEncoder().encode(candidate), portableStore.commit([Key.excludedApplications: .data(data)]) else {
                isApplyingPortableSnapshot = true
                excludedApplications = oldValue
                isApplyingPortableSnapshot = false
                return
            }
            if previous != portableStore.currentValues() {
                portableRevision &+= 1
                onPersistentPreferencesChange?()
            }
            onChange?()
        }
    }

    @Published private(set) var hasCompletedInitialSetup: Bool
    @Published private(set) var remembersPanelFilters: Bool
    private var rememberedPanelFilters: ClipboardHistoryFilterState?
    private(set) var hasPresentedInitialSetup: Bool

    @Published var sequentialHUDDismissal: ClipboardSequentialHUDDismissal {
        didSet {
            guard !isApplyingPortableSnapshot, sequentialHUDDismissal != oldValue else { return }
            let candidate = sequentialHUDDismissal
            let previous = portableStore.currentValues()
            guard portableStore.commit([Key.sequentialHUDDismissal: .integer(candidate.rawValue)]) else {
                isApplyingPortableSnapshot = true
                sequentialHUDDismissal = oldValue
                isApplyingPortableSnapshot = false
                return
            }
            if previous != portableStore.currentValues() {
                portableRevision &+= 1
                onPersistentPreferencesChange?()
            }
            onChange?()
        }
    }

    @Published var hidesSequentialHUDPreview: Bool {
        didSet {
            guard !isApplyingPortableSnapshot, hidesSequentialHUDPreview != oldValue else { return }
            let candidate = hidesSequentialHUDPreview
            let previous = portableStore.currentValues()
            guard portableStore.commit([Key.hidesSequentialHUDPreview: .boolean(candidate)]) else {
                isApplyingPortableSnapshot = true
                hidesSequentialHUDPreview = oldValue
                isApplyingPortableSnapshot = false
                return
            }
            if previous != portableStore.currentValues() {
                portableRevision &+= 1
                onPersistentPreferencesChange?()
            }
            onChange?()
        }
    }

    @Published var showsPanelPreview: Bool {
        didSet {
            guard !isApplyingPortableSnapshot, showsPanelPreview != oldValue else { return }
            let candidate = showsPanelPreview
            let previous = portableStore.currentValues()
            guard portableStore.commit([Key.showsPanelPreview: .boolean(candidate)]) else {
                isApplyingPortableSnapshot = true
                showsPanelPreview = oldValue
                isApplyingPortableSnapshot = false
                return
            }
            if previous != portableStore.currentValues() {
                portableRevision &+= 1
                onPersistentPreferencesChange?()
            }
            onChange?()
        }
    }

    @Published var isKeywordExpansionEnabled: Bool {
        didSet {
            storage.set(isKeywordExpansionEnabled, forKey: Key.keywordExpansionEnabled)
            onChange?()
        }
    }

    @Published private(set) var keywordExpansionStatus: ClipboardSnippetKeywordExpansionStatus
    @Published var keywordExpansionDiagnostic: ClipboardSnippetExpansionDiagnostic?

    private var isApplyingPortableSnapshot = false
    private(set) var portableRevision: UInt64 = 0
    var onPersistentPreferencesChange: (() -> Void)?

    private static func integer(_ fallback: Int, allowed: [Int]) -> PortablePreferenceField {
        PortablePreferenceField(fallback: .integer(fallback)) {
            if case let .integer(value) = $0 { allowed.contains(value) } else { false }
        }
    }
    private static func portableStore(storage: any PluginStorage) -> PortablePreferencesStore {
        let defaults = ClipboardHistorySettings.defaults
        return PortablePreferencesStore(storage: storage, fields: [
            Key.retentionDeferred: .boolean(false),
            Key.maximumItemCount: integer(defaults.maximumItemCount, allowed: allowedItemCounts),
            Key.expirationDays: integer(defaults.expiration.rawValue, allowed: ClipboardHistoryExpiration.allCases.map(\.rawValue)),
            Key.maximumItemByteCount: integer(defaults.maximumItemByteCount, allowed: allowedItemByteCounts),
            Key.maximumTotalPayloadByteCount: integer(defaults.maximumTotalPayloadByteCount, allowed: allowedTotalPayloadByteCounts),
            Key.sequentialHUDDismissal: integer(10, allowed: ClipboardSequentialHUDDismissal.allCases.map(\.rawValue)),
            Key.hidesSequentialHUDPreview: .boolean(false),
            Key.remembersPanelFilters: .boolean(false),
            Key.showsPanelPreview: .boolean(true),
            Key.maximumExpandedTextByteCount: integer(ClipboardSnippetExpansionContext.defaultMaximumUTF8ByteCount, allowed: allowedExpandedTextByteCounts),
            Key.excludedApplications: .data(try! JSONEncoder().encode(defaults.excludedApplications), maximumBytes: 256 * 1_024) { data in
                guard let apps = try? JSONDecoder().decode([ClipboardExcludedApplication].self, from: data), apps.count <= 512,
                      Set(apps.map { $0.bundleIdentifier.lowercased() }).count == apps.count else { return false }
                return apps.allSatisfy { !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier.utf8.count <= 255 && !$0.name.isEmpty && $0.name.utf8.count <= 256
                    && !$0.bundleIdentifier.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains)
                    && !$0.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
            }
        ])
    }
    private var portableStore: PortablePreferencesStore { Self.portableStore(storage: storage) }
    private static var portableKeys: Set<String> {
        [Key.maximumItemCount, Key.expirationDays, Key.maximumItemByteCount, Key.maximumTotalPayloadByteCount,
         Key.sequentialHUDDismissal, Key.hidesSequentialHUDPreview, Key.showsPanelPreview,
         Key.maximumExpandedTextByteCount, Key.excludedApplications, Key.remembersPanelFilters]
    }

    var isRetentionDeferred: Bool {
        guard portableStore.recover(),
              let values = portableStore.currentValues(including: [Key.retentionDeferred]),
              case let .boolean(deferred) = values[Key.retentionDeferred] else { return true }
        return deferred
    }

    @discardableResult
    func setRetentionDeferred(_ deferred: Bool) -> Bool {
        guard portableStore.recover() else { return false }
        if portableStore.currentValues(including: [Key.retentionDeferred])?[Key.retentionDeferred] == .boolean(deferred) { return true }
        return portableStore.commit([Key.retentionDeferred: .boolean(deferred)])
    }

    func portableBackup() -> Data? {
        guard let apps = try? JSONEncoder().encode(Self.normalizedApplications(excludedApplications).sorted { $0.bundleIdentifier < $1.bundleIdentifier }) else { return nil }
        return portableStore.backup(including: Self.portableKeys, overriding: [Key.excludedApplications: .data(apps)])
    }
    func restorePortableBackup(_ data: Data) -> Bool {
        let previous = portableBackup()
        guard var values = portableStore.validatedValues(from: data),
              Set(values.keys).isSubset(of: Self.portableKeys), portableStore.recover(),
              let current = portableStore.currentValues(including: Self.portableKeys) else { return false }
        let retentionKeys: Set<String> = [Key.maximumItemCount, Key.expirationDays, Key.maximumItemByteCount, Key.maximumTotalPayloadByteCount]
        if retentionKeys.contains(where: { values[$0] != nil && values[$0] != current[$0] }) {
            values[Key.retentionDeferred] = .boolean(true)
        }
        guard portableStore.commit(values) else { return false }
        let restored = ClipboardHistorySettingsStore(storage: storage)
        isApplyingPortableSnapshot = true
        maximumItemCount = restored.maximumItemCount
        expiration = restored.expiration
        maximumItemByteCount = restored.maximumItemByteCount
        maximumTotalPayloadByteCount = restored.maximumTotalPayloadByteCount
        excludedApplications = restored.excludedApplications
        sequentialHUDDismissal = restored.sequentialHUDDismissal
        hidesSequentialHUDPreview = restored.hidesSequentialHUDPreview
        showsPanelPreview = restored.showsPanelPreview
        maximumExpandedTextByteCount = restored.maximumExpandedTextByteCount
        remembersPanelFilters = restored.remembersPanelFilters
        if !remembersPanelFilters {
            rememberedPanelFilters = nil
            storage.removeObject(forKey: Key.panelFilters)
        }
        isApplyingPortableSnapshot = false
        if previous != portableBackup() {
            portableRevision &+= 1
            onPersistentPreferencesChange?()
        }
        return true
    }

    var onChange: (() -> Void)?

    private let storage: PluginStorage
    private var panelPositions: [String: ClipboardHistoryPanelPosition]

    init(storage: PluginStorage) {
        self.storage = storage
        _ = Self.portableStore(storage: storage).recover()
        let remembers = storage.bool(forKey: Key.remembersPanelFilters)
        remembersPanelFilters = remembers
        if remembers, let data = storage.data(forKey: Key.panelFilters), data.count <= 512,
           let decoded = try? JSONDecoder().decode(ClipboardHistoryFilterState.self, from: data) {
            rememberedPanelFilters = decoded.normalized
        }
        if let data = storage.data(forKey: Key.panelPositions),
           let positions = try? JSONDecoder().decode([String: ClipboardHistoryPanelPosition].self, from: data) {
            panelPositions = positions.filter { $0.value.isValid }
        } else {
            panelPositions = [:]
        }
        let defaults = ClipboardHistorySettings.defaults
        let completedInitialSetup = storage.bool(forKey: Key.didCompleteInitialSetup)
        // Collection is privacy-sensitive on a new installation. Existing installations retain
        // their persisted pause value, while a completed setup without that legacy key remains on.
        isPaused = storage.object(forKey: Key.isPaused) == nil
            ? !completedInitialSetup
            : storage.bool(forKey: Key.isPaused)

        let storedItemCount = storage.integer(forKey: Key.maximumItemCount)
        maximumItemCount = Self.validItemCount(
            storedItemCount == 0 ? defaults.maximumItemCount : storedItemCount
        )

        let storedExpiration = storage.integer(forKey: Key.expirationDays)
        expiration = storage.object(forKey: Key.expirationDays) == nil
            ? defaults.expiration
            : ClipboardHistoryExpiration(rawValue: storedExpiration) ?? defaults.expiration

        let storedItemByteCount = storage.integer(forKey: Key.maximumItemByteCount)
        maximumItemByteCount = Self.validItemByteCount(
            storedItemByteCount == 0 ? defaults.maximumItemByteCount : storedItemByteCount
        )

        let storedTotalPayloadByteCount = storage.integer(forKey: Key.maximumTotalPayloadByteCount)
        maximumTotalPayloadByteCount = Self.validTotalPayloadByteCount(
            storedTotalPayloadByteCount == 0
                ? defaults.maximumTotalPayloadByteCount
                : storedTotalPayloadByteCount
        )

        if let data = storage.data(forKey: Key.excludedApplications),
           let decoded = try? JSONDecoder().decode([ClipboardExcludedApplication].self, from: data) {
            excludedApplications = Self.normalizedApplications(decoded)
        } else {
            excludedApplications = defaults.excludedApplications
        }
        hasCompletedInitialSetup = completedInitialSetup
        hasPresentedInitialSetup = storage.bool(forKey: Key.didPresentInitialSetup)
        sequentialHUDDismissal = ClipboardSequentialHUDDismissal(
            rawValue: storage.integer(forKey: Key.sequentialHUDDismissal)
        ) ?? .tenSeconds
        hidesSequentialHUDPreview = storage.bool(forKey: Key.hidesSequentialHUDPreview)
        showsPanelPreview = storage.object(forKey: Key.showsPanelPreview) as? Bool ?? true
        let keywordExpansionEnabled = storage.bool(forKey: Key.keywordExpansionEnabled)
        maximumExpandedTextByteCount = Self.validExpandedTextByteCount(storage.integer(forKey: Key.maximumExpandedTextByteCount))
        isKeywordExpansionEnabled = keywordExpansionEnabled
        keywordExpansionStatus = keywordExpansionEnabled ? .noKeywords : .off
    }

    var snapshot: ClipboardHistorySettings {
        ClipboardHistorySettings(
            isPaused: isPaused,
            maximumItemCount: maximumItemCount,
            expiration: expiration,
            maximumItemByteCount: maximumItemByteCount,
            maximumTotalPayloadByteCount: maximumTotalPayloadByteCount,
            excludedApplications: excludedApplications
        )
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
    }

    var openingPanelFilters: ClipboardHistoryFilterState {
        remembersPanelFilters ? rememberedPanelFilters ?? .defaults : .defaults
    }

    func panelFiltersForOpening(explicitScope: ClipboardPanelMode? = nil) -> ClipboardHistoryFilterState {
        explicitScope.map { ClipboardHistoryFilterState(scope: $0).normalized } ?? openingPanelFilters
    }

    func setRemembersPanelFilters(_ remembers: Bool, current: ClipboardHistoryFilterState) {
        guard remembers != remembersPanelFilters,
              portableStore.commit([Key.remembersPanelFilters: .boolean(remembers)]) else { return }
        remembersPanelFilters = remembers
        if remembers {
            recordPanelFilters(current)
        } else {
            rememberedPanelFilters = nil
            storage.removeObject(forKey: Key.panelFilters)
        }
        portableRevision &+= 1
        onPersistentPreferencesChange?()
        onChange?()
    }

    func recordPanelFilters(_ filters: ClipboardHistoryFilterState) {
        guard remembersPanelFilters, let data = try? JSONEncoder().encode(filters.normalized) else { return }
        storage.set(data, forKey: Key.panelFilters)
        guard storage.data(forKey: Key.panelFilters) == data else { return }
        rememberedPanelFilters = filters.normalized
    }

    func panelPosition(for screenID: String) -> ClipboardHistoryPanelPosition? {
        panelPositions[screenID]
    }

    func setPanelPosition(_ position: ClipboardHistoryPanelPosition, for screenID: String) {
        guard position.isValid, panelPositions[screenID] != position else { return }
        panelPositions[screenID] = position
        if let data = try? JSONEncoder().encode(panelPositions) {
            storage.set(data, forKey: Key.panelPositions)
        }
    }

    func setKeywordExpansionStatus(_ status: ClipboardSnippetKeywordExpansionStatus) {
        guard keywordExpansionStatus != status else { return }
        keywordExpansionStatus = status
    }

    func refreshKeywordExpansion() {
        onChange?()
    }

    func addExcludedApplications(_ applications: [ClipboardExcludedApplication]) {
        excludedApplications = Self.normalizedApplications(excludedApplications + applications)
    }

    func removeExcludedApplication(bundleIdentifier: String) {
        excludedApplications.removeAll {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    func completeInitialSetup() {
        guard !hasCompletedInitialSetup else { return }
        hasCompletedInitialSetup = true
        storage.set(true, forKey: Key.didCompleteInitialSetup)
        onChange?()
    }

    func shouldAutomaticallyPresentInitialSetup() -> Bool {
        guard !hasCompletedInitialSetup, !hasPresentedInitialSetup else {
            return false
        }
        hasPresentedInitialSetup = true
        storage.set(true, forKey: Key.didPresentInitialSetup)
        return true
    }

    private static func validItemCount(_ value: Int) -> Int {
        return allowedItemCounts.contains(value)
            ? value
            : ClipboardHistorySettings.defaultMaximumItemCount
    }

    private static func validItemByteCount(_ value: Int) -> Int {
        allowedItemByteCounts.contains(value) ? value : ClipboardHistorySettings.defaultMaximumItemByteCount
    }

    private static func validTotalPayloadByteCount(_ value: Int) -> Int {
        allowedTotalPayloadByteCounts.contains(value)
            ? value
            : ClipboardHistorySettings.defaultMaximumTotalPayloadByteCount
    }

    private static func normalizedApplications(
        _ applications: [ClipboardExcludedApplication]
    ) -> [ClipboardExcludedApplication] {
        var seen = Set<String>()
        return applications
            .filter { !$0.bundleIdentifier.isEmpty }
            .filter { seen.insert($0.bundleIdentifier.lowercased()).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
