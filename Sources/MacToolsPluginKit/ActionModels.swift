import Foundation

public struct ActionKey: Hashable, Codable, Sendable, Identifiable {
    public let providerID: String
    public let actionID: String

    public init(providerID: String, actionID: String) {
        self.providerID = providerID
        self.actionID = actionID
    }

    public var id: String {
        "\(providerID)/\(actionID)"
    }
}

public enum ActionParameterValue: Hashable, Codable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case string
        case integer
        case double
        case boolean
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .value))
        case .double:
            let value = try container.decode(Double.self, forKey: .value)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Action parameter doubles must be finite."
                )
            }
            self = .double(value)
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .double(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Action parameter doubles must be finite."
                    )
                )
            }
            try container.encode(Kind.double, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public enum ActionParameterSetError: Error, Equatable, Sendable {
    case tooManyEntries
    case invalidName(String)
    case duplicateName(String)
    case stringTooLong(String)
    case nonFiniteNumber(String)
    case payloadTooLarge
}

public struct ActionParameterSet: Hashable, Codable, Sendable {
    public struct Entry: Hashable, Codable, Sendable {
        public let name: String
        public let value: ActionParameterValue

        public init(name: String, value: ActionParameterValue) {
            self.name = name
            self.value = value
        }
    }

    public static let maximumEntryCount = 32
    public static let maximumNameByteCount = 128
    public static let maximumStringByteCount = 4 * 1_024
    public static let maximumPayloadByteCount = 16 * 1_024

    public static let empty = try! ActionParameterSet(entries: [])

    public let entries: [Entry]

    public init(entries: [Entry]) throws {
        guard entries.count <= Self.maximumEntryCount else {
            throw ActionParameterSetError.tooManyEntries
        }

        let sortedEntries = entries.sorted { $0.name < $1.name }
        var previousName: String?
        var payloadByteCount = 0

        for entry in sortedEntries {
            guard Self.isValidName(entry.name) else {
                throw ActionParameterSetError.invalidName(entry.name)
            }
            guard entry.name != previousName else {
                throw ActionParameterSetError.duplicateName(entry.name)
            }
            previousName = entry.name
            payloadByteCount += entry.name.utf8.count

            switch entry.value {
            case let .string(value):
                guard value.utf8.count <= Self.maximumStringByteCount else {
                    throw ActionParameterSetError.stringTooLong(entry.name)
                }
                payloadByteCount += value.utf8.count
            case let .double(value):
                guard value.isFinite else {
                    throw ActionParameterSetError.nonFiniteNumber(entry.name)
                }
                payloadByteCount += 16
            case .integer, .boolean:
                payloadByteCount += 16
            }
        }

        guard payloadByteCount <= Self.maximumPayloadByteCount else {
            throw ActionParameterSetError.payloadTooLarge
        }
        self.entries = sortedEntries
    }

    public init(_ values: [String: ActionParameterValue]) throws {
        try self.init(entries: values.map(Entry.init))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(entries: container.decode([Entry].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }

    public subscript(name: String) -> ActionParameterValue? {
        entries.first(where: { $0.name == name })?.value
    }

    private static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maximumNameByteCount else {
            return false
        }
        return name.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "."
                || scalar == "_"
                || scalar == "-"
        }
    }
}

public enum ActionParameterKind: String, Hashable, Codable, Sendable {
    case string
    case integer
    case double
    case boolean

    public func accepts(_ value: ActionParameterValue) -> Bool {
        switch (self, value) {
        case (.string, .string), (.integer, .integer), (.double, .double), (.boolean, .boolean):
            return true
        default:
            return false
        }
    }
}

public enum ActionParameterPrivacy: String, Hashable, Codable, Sendable {
    case publicValue
    case sensitive
}

public enum ActionParameterPortability: String, Hashable, Codable, Sendable {
    case portable
    case localOnly
}

public struct ActionParameterDefinition: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: ActionParameterKind
    public let isRequired: Bool
    public let privacy: ActionParameterPrivacy
    public let portability: ActionParameterPortability

    public init(
        id: String,
        title: String,
        kind: ActionParameterKind,
        isRequired: Bool = true,
        privacy: ActionParameterPrivacy = .publicValue,
        portability: ActionParameterPortability = .portable
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isRequired = isRequired
        self.privacy = privacy
        self.portability = portability
    }
}

public enum ActionRisk: String, Hashable, Codable, Sendable {
    case safe
    case confirmationRequired
}

public enum ActionExternalInvocationPolicy: String, Hashable, Codable, Sendable {
    case unavailable
    case allowed
    case confirmAlways
}

/// Controls how the host admits overlapping invocations of the same action reference.
/// Providers should choose `.allowConcurrent` only when overlapping work is known to be safe.
public enum ActionConcurrencyPolicy: String, Hashable, Codable, Sendable {
    case serialize
    case rejectWhileRunning
    case allowConcurrent
}

public struct ActionExecutionCapabilities: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8

    public static let background = ActionExecutionCapabilities(rawValue: 1 << 0)
    public static let foregroundInteractive = ActionExecutionCapabilities(rawValue: 1 << 1)
    public static let cancellable = ActionExecutionCapabilities(rawValue: 1 << 2)
    /// The action publishes durable progress and cancellation state outside the
    /// surface that invoked it, so transient surfaces may close after it starts.
    public static let reportsProgress = ActionExecutionCapabilities(rawValue: 1 << 3)
    /// The action can change the connected-display topology or active display mode.
    /// The host uses this to detach AppKit's remote text-completion UI before the
    /// display server wakes or reorders status-item windows.
    public static let changesDisplayConfiguration = ActionExecutionCapabilities(rawValue: 1 << 4)
    /// The provider explicitly permits this action to run from unattended automatic rules.
    /// Background support alone does not imply that the action is safe to automate.
    public static let automatic = ActionExecutionCapabilities(rawValue: 1 << 5)
    /// Invoking this action opens an interface; it does not complete work selected in that interface.
    /// Voice planners must use it only for an explicit request to show the interface. Added in host 2.2.4.
    public static let opensInterface = ActionExecutionCapabilities(rawValue: 1 << 6)

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

/// A request-specific prompt and opaque identity, revalidated after approval.
/// Identity binds the resolved target and must not contain secret values.
public struct ActionConfirmationPreparation: Equatable, Sendable {
    public let confirmation: ActionConfirmation
    public let contextIdentity: String

    public init(confirmation: ActionConfirmation, contextIdentity: String) {
        self.confirmation = confirmation
        self.contextIdentity = contextIdentity
    }
}

/// Optional companion contract; existing provider witness tables remain unchanged.
@MainActor
public protocol PluginActionConfirmationProviding: AnyObject {
    /// Return nil when a concrete request cannot safely be described or revalidated.
    func actionConfirmation(for reference: ActionReference) -> ActionConfirmationPreparation?
}

public struct ActionConfirmation: Hashable, Codable, Sendable {
    public let title: String
    public let message: String
    public let confirmButtonTitle: String

    public init(title: String, message: String, confirmButtonTitle: String) {
        self.title = title
        self.message = message
        self.confirmButtonTitle = confirmButtonTitle
    }
}

public struct ActionDefinition: Hashable, Codable, Sendable, Identifiable {
    public let key: ActionKey
    public let parameterSchemaVersion: Int
    public let title: String
    public let description: String
    public let keywords: [String]
    public let systemImage: String
    public let parameters: [ActionParameterDefinition]
    public let risk: ActionRisk
    public let confirmation: ActionConfirmation?
    public let externalInvocationPolicy: ActionExternalInvocationPolicy
    public let capabilities: ActionExecutionCapabilities
    public let concurrencyPolicy: ActionConcurrencyPolicy
    public let executionTimeoutSeconds: Double

    public init(
        key: ActionKey,
        parameterSchemaVersion: Int = 1,
        title: String,
        description: String,
        keywords: [String] = [],
        systemImage: String,
        parameters: [ActionParameterDefinition] = [],
        risk: ActionRisk = .safe,
        confirmation: ActionConfirmation? = nil,
        externalInvocationPolicy: ActionExternalInvocationPolicy = .unavailable,
        capabilities: ActionExecutionCapabilities = [.foregroundInteractive],
        concurrencyPolicy: ActionConcurrencyPolicy = .rejectWhileRunning,
        executionTimeoutSeconds: Double = 30
    ) {
        self.key = key
        self.parameterSchemaVersion = parameterSchemaVersion
        self.title = title
        self.description = description
        self.keywords = keywords
        self.systemImage = systemImage
        self.parameters = parameters
        self.risk = risk
        self.confirmation = confirmation
        self.externalInvocationPolicy = externalInvocationPolicy
        self.capabilities = capabilities
        self.concurrencyPolicy = concurrencyPolicy
        self.executionTimeoutSeconds = executionTimeoutSeconds
    }

    public var id: ActionKey {
        key
    }
}

public struct ActionReference: Hashable, Codable, Sendable, Identifiable {
    public let key: ActionKey
    public let schemaVersion: Int
    public let parameters: ActionParameterSet

    private enum CodingKeys: String, CodingKey {
        case key
        case schemaVersion
        case parameters
    }

    public init(
        key: ActionKey,
        schemaVersion: Int = 1,
        parameters: ActionParameterSet = .empty
    ) {
        self.key = key
        self.schemaVersion = schemaVersion
        self.parameters = parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(ActionKey.self, forKey: .key)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        parameters = try container.decode(ActionParameterSet.self, forKey: .parameters)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(parameters, forKey: .parameters)
    }

    public var id: ActionReference {
        self
    }
}

public enum ActionPresentationState: String, Hashable, Codable, Sendable {
    case inactive
    case active
}

public struct ActionCatalogEntry: Hashable, Codable, Sendable, Identifiable {
    public let reference: ActionReference
    public let title: String
    public let subtitle: String?
    public let presentationState: ActionPresentationState?

    public init(
        reference: ActionReference,
        title: String,
        subtitle: String? = nil,
        presentationState: ActionPresentationState? = nil
    ) {
        self.reference = reference
        self.title = title
        self.subtitle = subtitle
        self.presentationState = presentationState
    }

    public var id: ActionReference {
        reference
    }
}

public struct ActionAvailability: Hashable, Codable, Sendable {
    public let isAvailable: Bool
    public let reason: String?

    public init(isAvailable: Bool, reason: String? = nil) {
        self.isAvailable = isAvailable
        self.reason = reason
    }

    public static let available = ActionAvailability(isAvailable: true)

    public static func unavailable(_ reason: String) -> ActionAvailability {
        ActionAvailability(isAvailable: false, reason: reason)
    }
}

/// A host-owned system surface that can discover and invoke canonical actions.
///
/// This is string-backed so adding another integration does not require making
/// an existing plugin's switch over surfaces exhaustive.
public struct ActionExposureSurface: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public static let appIntents = ActionExposureSurface(rawValue: "app-intents")

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A provider veto layered underneath the host surface's own safety policy.
/// `.automatic` never bypasses host checks for risk, availability, permissions,
/// parameters, or foreground interaction.
public enum ActionExposurePolicy: String, Hashable, Codable, Sendable {
    case automatic
    case excluded
}

public enum ActionExecutionSource: String, Hashable, Codable, Sendable {
    case unifiedSearch
    case globalShortcut
    case runLink
    case workflow
    case automaticRule
    case actionGrid
    case trackpadGesture
    case appIntent
    case cli
    case manual
    case test
}

public enum ActionExecutionMode: String, Hashable, Codable, Sendable {
    case background
    case foreground
}

public struct ActionInvocation: Hashable, Codable, Sendable {
    public let reference: ActionReference
    public let source: ActionExecutionSource
    public let mode: ActionExecutionMode

    public init(
        reference: ActionReference,
        source: ActionExecutionSource,
        mode: ActionExecutionMode
    ) {
        self.reference = reference
        self.source = source
        self.mode = mode
    }
}

public enum ActionExecutionResult: Equatable, Sendable {
    case succeeded(message: String? = nil)
    case failed(message: String)
    case cancelled
}

@MainActor
public final class ActionExecutionHandle {
    private let operation: @MainActor () async -> ActionExecutionResult
    private let cancellationHandler: @MainActor () -> Void
    private var task: Task<ActionExecutionResult, Never>?
    private var isCancelled = false

    public init(
        operation: @escaping @MainActor () async -> ActionExecutionResult,
        cancel: @escaping @MainActor () -> Void = {}
    ) {
        self.operation = operation
        self.cancellationHandler = cancel
    }

    public func result() async -> ActionExecutionResult {
        guard !isCancelled else {
            return .cancelled
        }
        if let task {
            let result = await task.value
            return isCancelled ? .cancelled : result
        }

        let operation = self.operation
        let task = Task { @MainActor in
            await operation()
        }
        self.task = task
        let result = await task.value
        return isCancelled ? .cancelled : result
    }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        task?.cancel()
        cancellationHandler()
    }
}

@MainActor
public protocol PluginActionProviding: AnyObject {
    var actionDefinitions: [ActionDefinition] { get }
    var actionCatalogEntries: [ActionCatalogEntry] { get }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability
    func migrateActionReference(
        _ reference: ActionReference,
        toSchemaVersion schemaVersion: Int
    ) -> ActionReference?
    /// Accepts an already validated invocation and returns promptly with an execution handle.
    /// Expensive work belongs in the handle's asynchronous operation, not in this method.
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle
}

/// Describes a host-rendered shortcut section for a subset of a plugin's canonical actions.
///
/// This companion contract keeps shortcut persistence, conflict handling, and registration in
/// the host while allowing a plugin to place the relevant actions beside its own settings. It is
/// separate from `MacToolsPlugin` and `PluginActionProviding` so existing PluginKit v4 witness
/// tables remain unchanged.
public struct PluginActionShortcutSettingsConfiguration: Sendable {
    /// Stable settings-search entry used by the host-rendered action shortcut section.
    ///
    /// This is a static contract rather than stored configuration so adding it does not change
    /// the binary layout of the public PluginKit v4 value type.
    public static let settingsSearchEntryID = "action-shortcuts"

    public let title: String
    public let description: String?
    public let systemImage: String
    public let actionIDs: Set<String>
    public let placementAfterSectionID: String?

    public init(
        title: String,
        description: String? = nil,
        systemImage: String = "command",
        actionIDs: Set<String>,
        placementAfterSectionID: String? = nil
    ) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.actionIDs = actionIDs
        self.placementAfterSectionID = placementAfterSectionID
    }
}

@MainActor
public protocol PluginActionShortcutSettingsProviding: AnyObject {
    var actionShortcutSettingsConfiguration: PluginActionShortcutSettingsConfiguration { get }
}

/// Describes one host-rendered shortcut group that may combine canonical actions with
/// plugin-private shortcuts. Persistence, conflict handling, and registration remain host-owned.
public struct PluginShortcutSettingsGroupConfiguration: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let description: String?
    public let systemImage: String
    public let actionIDs: Set<String>
    public let shortcutDefinitionIDs: Set<String>
    public let placementAfterSectionID: String?

    public init(
        id: String,
        title: String,
        description: String? = nil,
        systemImage: String = "command",
        actionIDs: Set<String> = [],
        shortcutDefinitionIDs: Set<String> = [],
        placementAfterSectionID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.actionIDs = actionIDs
        self.shortcutDefinitionIDs = shortcutDefinitionIDs
        self.placementAfterSectionID = placementAfterSectionID
    }
}

/// Optional companion contract for settings pages that need more than one shortcut group or need
/// to place a plugin-private shortcut beside a canonical action without changing either model.
@MainActor
public protocol PluginGroupedShortcutSettingsProviding: AnyObject {
    var shortcutSettingsGroups: [PluginShortcutSettingsGroupConfiguration] { get }
}

/// Optional presentation hints for host-rendered shortcut groups. These hints do not change the
/// shortcut model or persistence and therefore remain safe for older plugin packages.
@MainActor
public protocol PluginShortcutSettingsGroupPresentationProviding: AnyObject {
    var shortcutDefinitionFirstSettingsGroupIDs: Set<String> { get }
    var collapsibleShortcutSettingsGroupIDs: Set<String> { get }
    var collapsibleActionSettingsGroupIDs: Set<String> { get }
}

public extension PluginShortcutSettingsGroupPresentationProviding {
    var shortcutDefinitionFirstSettingsGroupIDs: Set<String> { [] }
    var collapsibleShortcutSettingsGroupIDs: Set<String> { [] }
    var collapsibleActionSettingsGroupIDs: Set<String> { [] }
}

/// Declares action IDs that this plugin intentionally removed. The host discards only matching
/// shortcut assignments while retaining assignments for actions that are merely unavailable.
@MainActor
public protocol PluginRetiredActionShortcutProviding: AnyObject {
    var retiredActionShortcutIDs: Set<String> { get }
}

/// Optional host bridge for plugins that offer named shortcut presets.
///
/// The host validates and persists the complete preset atomically. `managedActionIDs` identifies
/// assignments replaced by the preset; an empty bindings dictionary therefore clears that set.
/// The callback returns a localized error message when the preset cannot be applied.
public struct PluginActionShortcutPresetPreviewItem: Equatable, Sendable {
    public let actionID: String
    public let currentBinding: ShortcutBinding?
    public let proposedBinding: ShortcutBinding?
    public let conflictOwnerDescription: String?

    public init(
        actionID: String,
        currentBinding: ShortcutBinding?,
        proposedBinding: ShortcutBinding?,
        conflictOwnerDescription: String? = nil
    ) {
        self.actionID = actionID
        self.currentBinding = currentBinding
        self.proposedBinding = proposedBinding
        self.conflictOwnerDescription = conflictOwnerDescription
    }

    public var changesBinding: Bool {
        currentBinding != proposedBinding
    }
}

public struct PluginActionShortcutPresetPreview: Equatable, Sendable {
    public let items: [PluginActionShortcutPresetPreviewItem]
    public let errorMessage: String?

    public init(
        items: [PluginActionShortcutPresetPreviewItem],
        errorMessage: String? = nil
    ) {
        self.items = items
        self.errorMessage = errorMessage
    }

    public var hasChanges: Bool {
        items.contains(where: \.changesBinding)
    }

    public var canApply: Bool {
        errorMessage == nil && !items.contains(where: { $0.conflictOwnerDescription != nil })
    }
}

@MainActor
public protocol PluginActionShortcutPresetApplying: AnyObject {
    var previewActionShortcutPreset: ((
        _ managedActionIDs: Set<String>,
        _ bindingsByActionID: [String: ShortcutBinding]
    ) -> PluginActionShortcutPresetPreview)? { get set }
    var applyActionShortcutPreset: ((
        _ managedActionIDs: Set<String>,
        _ bindingsByActionID: [String: ShortcutBinding]
    ) -> String?)? { get set }
}

/// Optional host transaction used when a plugin mutation and its managed shortcut replacement
/// must either both persist or restore the exact previous assignment records.
@MainActor
public protocol PluginActionShortcutReplacementTransactionApplying: AnyObject {
    var currentActionShortcutBindings: ((
        _ managedActionIDs: Set<String>
    ) -> [String: [ShortcutBinding]])? { get set }
    var performActionShortcutReplacementTransaction: ((
        _ managedActionIDs: Set<String>,
        _ bindingsByActionID: [String: ShortcutBinding],
        _ mutation: () -> String?
    ) -> String?)? { get set }
}

/// Optional hook for plugins whose custom settings UI summarizes action shortcut assignments.
/// The host invokes it after the shared action-shortcut state changes so cached plugin views can
/// publish fresh derived state without polling or owning a parallel shortcut store.
@MainActor
public protocol PluginActionShortcutAssignmentChangeHandling: AnyObject {
    func actionShortcutAssignmentsDidChange()
}

/// Optional live revision for provider-owned execution state that is not represented by an
/// `ActionDefinition` or `ActionCatalogEntry`. The host revalidates this value after confirmation
/// and immediately before execution so mutable payloads cannot be substituted after approval.
@MainActor
public protocol PluginActionExecutionRevisionProviding: AnyObject {
    var actionExecutionRevision: UInt64 { get }
}

/// Optional provider-owned veto for system surfaces that discover canonical actions.
/// Providers that do not implement this contract use `.automatic`; the host surface
/// remains responsible for applying its own conservative eligibility policy.
@MainActor
public protocol PluginActionExposureProviding: AnyObject {
    func exposurePolicy(
        for reference: ActionReference,
        on surface: ActionExposureSurface
    ) -> ActionExposurePolicy
}

/// Optional action-to-permission mapping used by discovery surfaces. Providers
/// retain ownership of live permission state and final execution validation.
@MainActor
public protocol PluginActionPermissionProviding: AnyObject {
    func permissionRequirementIDs(for actionKey: ActionKey) -> [String]
}

public struct LegacyActionShortcutAssignment: Hashable, Codable, Sendable {
    public let reference: ActionReference
    public let binding: ShortcutBinding
    public let legacyShortcutDefinitionID: String?

    public init(
        reference: ActionReference,
        binding: ShortcutBinding,
        legacyShortcutDefinitionID: String? = nil
    ) {
        self.reference = reference
        self.binding = binding
        self.legacyShortcutDefinitionID = legacyShortcutDefinitionID
    }
}

/// Optional one-shot bridge for plugins that registered ordinary shortcuts before actions existed.
/// The host persists the returned assignments before invoking the completion callback.
@MainActor
public protocol PluginLegacyActionShortcutProviding: AnyObject {
    var legacyActionShortcutAssignments: [LegacyActionShortcutAssignment] { get }
    func legacyActionShortcutsDidMigrate()
}

public extension PluginActionProviding {
    var actionCatalogEntries: [ActionCatalogEntry] {
        actionDefinitions.compactMap { definition in
            guard definition.parameters.isEmpty else {
                return nil
            }
            return ActionCatalogEntry(
                reference: ActionReference(
                    key: definition.key,
                    schemaVersion: definition.parameterSchemaVersion
                ),
                title: definition.title
            )
        }
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        .available
    }

    func migrateActionReference(
        _ reference: ActionReference,
        toSchemaVersion schemaVersion: Int
    ) -> ActionReference? {
        guard reference.schemaVersion == schemaVersion else {
            return nil
        }
        return reference
    }
}

/// Optional signal for persisted action-safety changes that must reach the host registry
/// synchronously rather than through the ordinary coalesced plugin-state refresh.
@MainActor
public protocol PluginActionSafetyStateChangeProviding: AnyObject {
    var onActionSafetyStateChange: (() -> Void)? { get set }
}
