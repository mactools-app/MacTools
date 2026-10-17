import Foundation
import MacToolsPluginKit

enum AutoInputStoreMutationResult: Equatable {
    case committed
    case rejected(rollbackSucceeded: Bool)
}

@MainActor
final class AutoInputStore: ObservableObject {
    private enum Keys {
        static let legacyIsEnabled = "isEnabled"
        static let isAutoSwitchEnabled = "isAutoSwitchEnabled"
        static let isInputHUDEnabled = "isInputHUDEnabled"
        static let reducesFrequentHUDPresentations = "reducesFrequentHUDPresentations"
        static let inputHUDReminderIntervalSeconds = "inputHUDReminderIntervalSeconds"
        static let inputHUDAppSwitchReminderCount = "inputHUDAppSwitchReminderCount"
        static let isInteractiveHUDEnabled = "isInteractiveHUDEnabled"
        static let inputHUDSize = "inputHUDSize"
        static let inputHUDPosition = "inputHUDPosition"
        static let remembersLastInputSource = "remembersLastInputSource"
        static let rules = "rules"
        static let memories = "memories"
    }

    @Published private(set) var isAutoSwitchEnabled: Bool
    @Published private(set) var isInputHUDEnabled: Bool
    @Published private(set) var reducesFrequentHUDPresentations: Bool
    @Published private(set) var inputHUDReminderIntervalSeconds: Int
    @Published private(set) var inputHUDAppSwitchReminderCount: Int
    @Published private(set) var isInteractiveHUDEnabled: Bool
    @Published private(set) var inputHUDSize: AutoInputHUDSize
    @Published private(set) var inputHUDPosition: AutoInputHUDPosition
    @Published private(set) var remembersLastInputSource: Bool
    @Published private(set) var rules: [AutoInputRule]
    @Published private(set) var persistenceFailure: AutoInputStoreMutationResult?

    private(set) var memories: [String: String]

    private let storage: PluginStorage
    private let encoder = JSONEncoder()

    init(storage: PluginStorage) {
        self.storage = storage
        Self.migrateAutoSwitchPreferenceIfNeeded(storage: storage)
        self.isAutoSwitchEnabled = storage.object(forKey: Keys.isAutoSwitchEnabled) == nil
            ? true
            : storage.bool(forKey: Keys.isAutoSwitchEnabled)
        self.isInputHUDEnabled = storage.object(forKey: Keys.isInputHUDEnabled) == nil
            ? false
            : storage.bool(forKey: Keys.isInputHUDEnabled)
        self.reducesFrequentHUDPresentations = storage.object(
            forKey: Keys.reducesFrequentHUDPresentations
        ) == nil
            ? false
            : storage.bool(forKey: Keys.reducesFrequentHUDPresentations)
        self.inputHUDReminderIntervalSeconds = AutoInputHUDReminderLimits
            .normalizedIntervalSeconds(
                storage.object(forKey: Keys.inputHUDReminderIntervalSeconds) == nil
                    ? AutoInputHUDReminderLimits.defaultIntervalSeconds
                    : storage.integer(forKey: Keys.inputHUDReminderIntervalSeconds)
            )
        self.inputHUDAppSwitchReminderCount = AutoInputHUDReminderLimits
            .normalizedAppSwitchCount(
                storage.object(forKey: Keys.inputHUDAppSwitchReminderCount) == nil
                    ? AutoInputHUDReminderLimits.defaultAppSwitchCount
                    : storage.integer(forKey: Keys.inputHUDAppSwitchReminderCount)
            )
        self.isInteractiveHUDEnabled = storage.object(forKey: Keys.isInteractiveHUDEnabled) == nil
            ? false
            : storage.bool(forKey: Keys.isInteractiveHUDEnabled)
        self.inputHUDSize = storage.string(forKey: Keys.inputHUDSize)
            .flatMap(AutoInputHUDSize.init(rawValue:)) ?? .standard
        self.inputHUDPosition = storage.string(forKey: Keys.inputHUDPosition)
            .flatMap(AutoInputHUDPosition.init(rawValue:)) ?? .automatic
        self.remembersLastInputSource = storage.object(forKey: Keys.remembersLastInputSource) == nil
            ? true
            : storage.bool(forKey: Keys.remembersLastInputSource)
        let decodedRules = Self.decode([AutoInputRule].self, from: storage.data(forKey: Keys.rules)) ?? []
        self.rules = Self.normalizedRules(decodedRules)
        let decodedMemories = Self.decode([String: String].self, from: storage.data(forKey: Keys.memories)) ?? [:]
        self.memories = decodedMemories.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    @discardableResult
    func setAutoSwitchEnabled(_ value: Bool) -> AutoInputStoreMutationResult {
        guard isAutoSwitchEnabled != value else { return record(.committed) }
        let result = persist(value, forKey: Keys.isAutoSwitchEnabled)
        if result == .committed { isAutoSwitchEnabled = value }
        return record(result)
    }

    @discardableResult
    func setInputHUDEnabled(_ value: Bool) -> AutoInputStoreMutationResult {
        guard isInputHUDEnabled != value else { return record(.committed) }
        let result = persist(value, forKey: Keys.isInputHUDEnabled)
        if result == .committed { isInputHUDEnabled = value }
        return record(result)
    }

    @discardableResult
    func setReducesFrequentHUDPresentations(_ value: Bool) -> AutoInputStoreMutationResult {
        guard reducesFrequentHUDPresentations != value else { return record(.committed) }
        let result = persist(value, forKey: Keys.reducesFrequentHUDPresentations)
        if result == .committed { reducesFrequentHUDPresentations = value }
        return record(result)
    }

    @discardableResult
    func setInputHUDReminderIntervalSeconds(_ value: Int) -> AutoInputStoreMutationResult {
        let normalizedValue = AutoInputHUDReminderLimits.normalizedIntervalSeconds(value)
        guard inputHUDReminderIntervalSeconds != normalizedValue else {
            return record(.committed)
        }
        let result = persist(normalizedValue, forKey: Keys.inputHUDReminderIntervalSeconds)
        if result == .committed { inputHUDReminderIntervalSeconds = normalizedValue }
        return record(result)
    }

    @discardableResult
    func setInputHUDAppSwitchReminderCount(_ value: Int) -> AutoInputStoreMutationResult {
        let normalizedValue = AutoInputHUDReminderLimits.normalizedAppSwitchCount(value)
        guard inputHUDAppSwitchReminderCount != normalizedValue else {
            return record(.committed)
        }
        let result = persist(normalizedValue, forKey: Keys.inputHUDAppSwitchReminderCount)
        if result == .committed { inputHUDAppSwitchReminderCount = normalizedValue }
        return record(result)
    }

    @discardableResult
    func setInteractiveHUDEnabled(_ value: Bool) -> AutoInputStoreMutationResult {
        guard isInteractiveHUDEnabled != value else { return record(.committed) }
        let result = persist(value, forKey: Keys.isInteractiveHUDEnabled)
        if result == .committed { isInteractiveHUDEnabled = value }
        return record(result)
    }

    @discardableResult
    func setInputHUDSize(_ value: AutoInputHUDSize) -> AutoInputStoreMutationResult {
        guard inputHUDSize != value else { return record(.committed) }
        let result = persist(value.rawValue, forKey: Keys.inputHUDSize)
        if result == .committed { inputHUDSize = value }
        return record(result)
    }

    @discardableResult
    func setInputHUDPosition(_ value: AutoInputHUDPosition) -> AutoInputStoreMutationResult {
        guard inputHUDPosition != value else { return record(.committed) }
        let result = persist(value.rawValue, forKey: Keys.inputHUDPosition)
        if result == .committed { inputHUDPosition = value }
        return record(result)
    }

    @discardableResult
    func setRemembersLastInputSource(_ value: Bool) -> AutoInputStoreMutationResult {
        guard remembersLastInputSource != value else { return record(.committed) }
        let result = persist(value, forKey: Keys.remembersLastInputSource)
        if result == .committed { remembersLastInputSource = value }
        return record(result)
    }

    @discardableResult
    func upsertRule(_ rule: AutoInputRule) -> AutoInputStoreMutationResult {
        var candidate = rules
        if let index = candidate.firstIndex(where: { $0.bundleIdentifier == rule.bundleIdentifier }) {
            candidate[index] = rule
        } else {
            candidate.append(rule)
        }
        candidate.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let result = persist(candidate, forKey: Keys.rules)
        if result == .committed { rules = candidate }
        return record(result)
    }

    @discardableResult
    func updateRule(bundleIdentifier: String, inputSourceID: String) -> AutoInputStoreMutationResult {
        guard let index = rules.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return record(.committed)
        }
        var candidate = rules
        candidate[index].inputSourceID = inputSourceID
        let result = persist(candidate, forKey: Keys.rules)
        if result == .committed { rules = candidate }
        return record(result)
    }

    @discardableResult
    func updateRuleKeyboardMode(
        bundleIdentifier: String,
        keyboardMode: AutoInputKeyboardMode
    ) -> AutoInputStoreMutationResult {
        guard let index = rules.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }),
              rules[index].keyboardMode != keyboardMode else {
            return record(.committed)
        }
        var candidate = rules
        candidate[index].keyboardMode = keyboardMode
        let result = persist(candidate, forKey: Keys.rules)
        if result == .committed { rules = candidate }
        return record(result)
    }

    @discardableResult
    func removeRule(bundleIdentifier: String) -> AutoInputStoreMutationResult {
        let candidate = rules.filter { $0.bundleIdentifier != bundleIdentifier }
        guard candidate != rules else { return record(.committed) }
        let result = persist(candidate, forKey: Keys.rules)
        if result == .committed { rules = candidate }
        return record(result)
    }

    func rule(for bundleIdentifier: String) -> AutoInputRule? {
        rules.first { $0.bundleIdentifier == bundleIdentifier }
    }

    var hasKeyboardModeRules: Bool {
        rules.contains { $0.keyboardMode != .system }
    }

    @discardableResult
    func remember(inputSourceID: String, for bundleIdentifier: String) -> AutoInputStoreMutationResult {
        guard memories[bundleIdentifier] != inputSourceID else { return record(.committed) }
        var candidate = memories
        candidate[bundleIdentifier] = inputSourceID
        let result = persist(candidate, forKey: Keys.memories)
        if result == .committed { memories = candidate }
        return record(result)
    }

    func rememberedInputSourceID(for bundleIdentifier: String) -> String? {
        memories[bundleIdentifier]
    }

    private func persist(_ value: Bool, forKey key: String) -> AutoInputStoreMutationResult {
        let previous = storage.object(forKey: key)
        storage.set(value, forKey: key)
        guard let persisted = storage.object(forKey: key) as? Bool, persisted == value else {
            restore(previous, forKey: key)
            return .rejected(rollbackSucceeded: rawValue(storage.object(forKey: key), equals: previous))
        }
        return .committed
    }

    private func persist(_ value: String, forKey key: String) -> AutoInputStoreMutationResult {
        let previous = storage.object(forKey: key)
        storage.set(value, forKey: key)
        guard storage.string(forKey: key) == value else {
            restore(previous, forKey: key)
            return .rejected(rollbackSucceeded: rawValue(storage.object(forKey: key), equals: previous))
        }
        return .committed
    }

    private func persist(_ value: Int, forKey key: String) -> AutoInputStoreMutationResult {
        let previous = storage.object(forKey: key)
        storage.set(value, forKey: key)
        guard storage.integer(forKey: key) == value,
              storage.object(forKey: key) != nil else {
            restore(previous, forKey: key)
            return .rejected(rollbackSucceeded: rawValue(storage.object(forKey: key), equals: previous))
        }
        return .committed
    }

    private func persist<Value: Encodable>(
        _ value: Value,
        forKey key: String
    ) -> AutoInputStoreMutationResult {
        guard let data = try? encoder.encode(value) else {
            return .rejected(rollbackSucceeded: true)
        }
        let previous = storage.object(forKey: key)
        storage.set(data, forKey: key)
        guard storage.data(forKey: key) == data else {
            restore(previous, forKey: key)
            return .rejected(
                rollbackSucceeded: rawValue(storage.object(forKey: key), equals: previous)
            )
        }
        return .committed
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            storage.set(value, forKey: key)
        } else {
            storage.removeObject(forKey: key)
        }
    }

    private func rawValue(_ lhs: Any?, equals rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs as NSObject, rhs as NSObject): lhs.isEqual(rhs)
        default: false
        }
    }

    private func record(_ result: AutoInputStoreMutationResult) -> AutoInputStoreMutationResult {
        persistenceFailure = result == .committed ? nil : result
        return result
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data?) -> Value? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func migrateAutoSwitchPreferenceIfNeeded(storage: PluginStorage) {
        guard storage.object(forKey: Keys.isAutoSwitchEnabled) == nil,
              let legacyValue = storage.object(forKey: Keys.legacyIsEnabled) as? Bool
        else { return }

        storage.set(legacyValue, forKey: Keys.isAutoSwitchEnabled)
        guard storage.object(forKey: Keys.isAutoSwitchEnabled) as? Bool == legacyValue else {
            return
        }
        storage.removeObject(forKey: Keys.legacyIsEnabled)
    }

    private static func normalizedRules(_ rules: [AutoInputRule]) -> [AutoInputRule] {
        var rulesByBundleID: [String: AutoInputRule] = [:]
        for rule in rules where !rule.bundleIdentifier.isEmpty && !rule.inputSourceID.isEmpty {
            rulesByBundleID[rule.bundleIdentifier] = rule
        }
        return rulesByBundleID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}
