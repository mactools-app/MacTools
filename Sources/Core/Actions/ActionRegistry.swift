import Combine
import Foundation
import MacToolsPluginKit

enum ActionRegistryIssue: Error, Equatable {
    case invalidProviderID(String)
    case duplicateProviderID(String)
    case invalidDefinition(ActionKey, String)
    case duplicateDefinition(ActionKey)
    case invalidCatalogEntry(ActionReference, String)
    case duplicateCatalogEntry(ActionReference)
}

enum ActionRegistryError: Error, Equatable {
    case unknownAction(ActionKey)
    case schemaVersionMismatch(ActionKey, expected: Int, actual: Int)
    case migrationUnavailable(ActionKey, from: Int, to: Int)
    case invalidMigration(ActionKey)
    case invalidParameters(String)
    case providerChanged
    case providerFailure(String)
}

struct RegisteredAction: Equatable {
    let definition: ActionDefinition
    let catalogEntry: ActionCatalogEntry?
    let providerGeneration: UInt64
    let providerExecutionRevision: UInt64
}

enum ActionReferencePortability: Equatable {
    case portable
    case knownNonPortable
    case unknown
}

@MainActor
struct ActionProviderRegistration {
    let providerID: String
    let identity: ObjectIdentifier
    let definitions: [ActionDefinition]
    let catalogEntries: [ActionCatalogEntry]
    let executionRevision: () -> UInt64
    let availability: (ActionReference) -> ActionAvailability
    let exposurePolicy: (ActionReference, ActionExposureSurface) -> ActionExposurePolicy
    let migrate: (ActionReference, Int) -> ActionReference?
    let begin: (ActionInvocation) -> Result<ActionExecutionHandle, ActionRegistryError>

    init(
        providerID: String,
        identity: ObjectIdentifier,
        definitions: [ActionDefinition],
        catalogEntries: [ActionCatalogEntry],
        executionRevision: @escaping () -> UInt64 = { 0 },
        availability: @escaping (ActionReference) -> ActionAvailability,
        exposurePolicy: @escaping (
            ActionReference,
            ActionExposureSurface
        ) -> ActionExposurePolicy = { _, _ in .automatic },
        migrate: @escaping (ActionReference, Int) -> ActionReference? = { reference, version in
            reference.schemaVersion == version ? reference : nil
        },
        begin: @escaping (ActionInvocation) -> Result<ActionExecutionHandle, ActionRegistryError>
    ) {
        self.providerID = providerID
        self.identity = identity
        self.definitions = definitions
        self.catalogEntries = catalogEntries
        self.executionRevision = executionRevision
        self.availability = availability
        self.exposurePolicy = exposurePolicy
        self.migrate = migrate
        self.begin = begin
    }
}

@MainActor
final class ActionRegistry: ObservableObject {
    private struct ProviderState {
        let registration: ActionProviderRegistration
        let generation: UInt64
    }

    @Published private(set) var catalogEntries: [ActionCatalogEntry] = []
    @Published private(set) var issues: [ActionRegistryIssue] = []
    @Published private(set) var catalogRevision: UInt64 = 0
    @Published private(set) var availabilityRevision: UInt64 = 0

    private var providers: [String: ProviderState] = [:]
    private var definitions: [ActionKey: ActionDefinition] = [:]
    private var catalogByReference: [ActionReference: ActionCatalogEntry] = [:]
    private var nextGeneration: UInt64 = 1
    private var synchronizedRegistrations: [ActionProviderRegistration] = []

    @discardableResult
    func synchronize(_ registrations: [ActionProviderRegistration]) -> [ActionRegistryIssue] {
        if issues.isEmpty,
           registrations.count == synchronizedRegistrations.count,
           zip(registrations, synchronizedRegistrations).allSatisfy({ current, previous in
               current.providerID == previous.providerID
                   && current.identity == previous.identity
                   && current.definitions == previous.definitions
                   && current.catalogEntries == previous.catalogEntries
           }) {
            // Keep live callbacks current without repeating validation and index construction.
            for registration in registrations {
                if let previous = providers[registration.providerID] {
                    providers[registration.providerID] = ProviderState(registration: registration, generation: previous.generation)
                }
            }
            return issues
        }
        synchronizedRegistrations = registrations
        let previousDefinitions = definitions
        let previousCatalogEntries = catalogEntries
        var nextProviders: [String: ProviderState] = [:]
        var nextDefinitions: [ActionKey: ActionDefinition] = [:]
        var nextCatalog: [ActionReference: ActionCatalogEntry] = [:]
        var nextCatalogOrder: [ActionCatalogEntry] = []
        var collectedIssues: [ActionRegistryIssue] = []

        for registration in registrations {
            guard Self.isValidIdentifier(registration.providerID) else {
                collectedIssues.append(.invalidProviderID(registration.providerID))
                continue
            }
            guard nextProviders[registration.providerID] == nil else {
                collectedIssues.append(.duplicateProviderID(registration.providerID))
                continue
            }

            let generation: UInt64
            if let existing = providers[registration.providerID],
               existing.registration.identity == registration.identity,
               existing.registration.definitions == registration.definitions,
               existing.registration.catalogEntries == registration.catalogEntries {
                generation = existing.generation
            } else {
                generation = nextGeneration
                nextGeneration &+= 1
            }

            var acceptedDefinitions: [ActionDefinition] = []
            for definition in registration.definitions {
                if let reason = Self.validationFailure(
                    for: definition,
                    expectedProviderID: registration.providerID
                ) {
                    collectedIssues.append(.invalidDefinition(definition.key, reason))
                    continue
                }
                guard nextDefinitions[definition.key] == nil else {
                    collectedIssues.append(.duplicateDefinition(definition.key))
                    continue
                }
                nextDefinitions[definition.key] = definition
                acceptedDefinitions.append(definition)
            }

            let acceptedKeys = Set(acceptedDefinitions.map(\.key))
            var acceptedCatalog: [ActionCatalogEntry] = []
            for entry in registration.catalogEntries {
                guard acceptedKeys.contains(entry.reference.key),
                      let definition = nextDefinitions[entry.reference.key] else {
                    collectedIssues.append(
                        .invalidCatalogEntry(entry.reference, "missing-definition")
                    )
                    continue
                }
                guard entry.reference.schemaVersion == definition.parameterSchemaVersion else {
                    collectedIssues.append(
                        .invalidCatalogEntry(entry.reference, "schema-version-mismatch")
                    )
                    continue
                }
                if let reason = Self.parameterValidationFailure(
                    entry.reference.parameters,
                    for: definition
                ) {
                    collectedIssues.append(.invalidCatalogEntry(entry.reference, reason))
                    continue
                }
                guard nextCatalog[entry.reference] == nil else {
                    collectedIssues.append(.duplicateCatalogEntry(entry.reference))
                    continue
                }
                nextCatalog[entry.reference] = entry
                nextCatalogOrder.append(entry)
                acceptedCatalog.append(entry)
            }

            nextProviders[registration.providerID] = ProviderState(
                registration: ActionProviderRegistration(
                    providerID: registration.providerID,
                    identity: registration.identity,
                    definitions: acceptedDefinitions,
                    catalogEntries: acceptedCatalog,
                    executionRevision: registration.executionRevision,
                    availability: registration.availability,
                    exposurePolicy: registration.exposurePolicy,
                    migrate: registration.migrate,
                    begin: registration.begin
                ),
                generation: generation
            )
        }

        providers = nextProviders
        definitions = nextDefinitions
        catalogByReference = nextCatalog
        if catalogEntries != nextCatalogOrder {
            catalogEntries = nextCatalogOrder
        }
        if issues != collectedIssues {
            issues = collectedIssues
        }
        if previousDefinitions != nextDefinitions || previousCatalogEntries != nextCatalogOrder {
            catalogRevision &+= 1
        }
        return collectedIssues
    }

    func registeredAction(for reference: ActionReference) -> Result<RegisteredAction, ActionRegistryError> {
        guard let definition = definitions[reference.key],
              let provider = providers[reference.key.providerID] else {
            return .failure(.unknownAction(reference.key))
        }
        guard reference.schemaVersion == definition.parameterSchemaVersion else {
            return .failure(
                .schemaVersionMismatch(
                    reference.key,
                    expected: definition.parameterSchemaVersion,
                    actual: reference.schemaVersion
                )
            )
        }
        if let reason = Self.parameterValidationFailure(reference.parameters, for: definition) {
            return .failure(.invalidParameters(reason))
        }
        return .success(
            RegisteredAction(
                definition: definition,
                catalogEntry: catalogByReference[reference],
                providerGeneration: provider.generation,
                providerExecutionRevision: provider.registration.executionRevision()
            )
        )
    }

    func definition(for key: ActionKey) -> ActionDefinition? {
        definitions[key]
    }

    func portability(of reference: ActionReference) -> ActionReferencePortability {
        guard let definition = definitions[reference.key] else { return .unknown }
        guard case .success = registeredAction(for: reference) else {
            return .knownNonPortable
        }
        let schemaByID = Dictionary(
            uniqueKeysWithValues: definition.parameters.map { ($0.id, $0) }
        )
        return reference.parameters.entries.allSatisfy { entry in
            schemaByID[entry.name]?.privacy == .publicValue
                && schemaByID[entry.name]?.portability == .portable
        } ? .portable : .knownNonPortable
    }

    static func containsSensitiveParameters(
        _ reference: ActionReference,
        for definition: ActionDefinition
    ) -> Bool {
        let schemaByID = Dictionary(
            uniqueKeysWithValues: definition.parameters.map { ($0.id, $0) }
        )
        return reference.parameters.entries.contains { entry in
            schemaByID[entry.name]?.privacy == .sensitive
        }
    }

    func migrate(_ reference: ActionReference) -> Result<ActionReference, ActionRegistryError> {
        guard let definition = definitions[reference.key],
              let provider = providers[reference.key.providerID] else {
            return .failure(.unknownAction(reference.key))
        }
        let targetVersion = definition.parameterSchemaVersion
        guard reference.schemaVersion != targetVersion else {
            if let reason = Self.parameterValidationFailure(reference.parameters, for: definition) {
                return .failure(.invalidParameters(reason))
            }
            return .success(reference)
        }
        guard reference.schemaVersion < targetVersion,
              let migrated = provider.registration.migrate(reference, targetVersion) else {
            return .failure(
                .migrationUnavailable(
                    reference.key,
                    from: reference.schemaVersion,
                    to: targetVersion
                )
            )
        }
        guard migrated.key == reference.key,
              migrated.schemaVersion == targetVersion,
              Self.parameterValidationFailure(migrated.parameters, for: definition) == nil else {
            return .failure(.invalidMigration(reference.key))
        }
        return .success(migrated)
    }

    func invalidateAvailability() {
        availabilityRevision &+= 1
    }

    func availability(for reference: ActionReference) -> ActionAvailability {
        guard case .success = registeredAction(for: reference),
              let provider = providers[reference.key.providerID] else {
            return .unavailable(FeatureL10n.string("操作不可用。"))
        }
        return provider.registration.availability(reference)
    }

    func exposurePolicy(
        for reference: ActionReference,
        on surface: ActionExposureSurface
    ) -> ActionExposurePolicy {
        guard case .success = registeredAction(for: reference),
              let provider = providers[reference.key.providerID] else {
            return .excluded
        }
        return provider.registration.exposurePolicy(reference, surface)
    }

    func begin(
        _ invocation: ActionInvocation,
        expectedProviderGeneration: UInt64,
        expectedProviderExecutionRevision: UInt64
    ) -> Result<ActionExecutionHandle, ActionRegistryError> {
        guard case let .success(action) = registeredAction(for: invocation.reference),
              let provider = providers[invocation.reference.key.providerID] else {
            return .failure(.unknownAction(invocation.reference.key))
        }
        guard action.providerGeneration == expectedProviderGeneration,
              action.providerExecutionRevision == expectedProviderExecutionRevision else {
            return .failure(.providerChanged)
        }
        return provider.registration.begin(invocation)
    }

    static func parameterValidationFailure(
        _ parameters: ActionParameterSet,
        for definition: ActionDefinition
    ) -> String? {
        let schemaByID = Dictionary(uniqueKeysWithValues: definition.parameters.map { ($0.id, $0) })
        guard schemaByID.count == definition.parameters.count else {
            return "duplicate-parameter-schema"
        }

        for entry in parameters.entries {
            guard let parameter = schemaByID[entry.name] else {
                return "unknown-parameter:\(entry.name)"
            }
            guard parameter.kind.accepts(entry.value) else {
                return "wrong-parameter-type:\(entry.name)"
            }
        }

        let suppliedNames = Set(parameters.entries.map(\.name))
        if let missing = definition.parameters.first(where: {
            $0.isRequired && !suppliedNames.contains($0.id)
        }) {
            return "missing-parameter:\(missing.id)"
        }
        return nil
    }

    private static func validationFailure(
        for definition: ActionDefinition,
        expectedProviderID: String
    ) -> String? {
        guard definition.key.providerID == expectedProviderID else {
            return "provider-mismatch"
        }
        guard definition.parameterSchemaVersion > 0 else {
            return "invalid-schema-version"
        }
        guard isValidIdentifier(definition.key.actionID) else {
            return "invalid-action-id"
        }
        guard !definition.title.isEmpty, !definition.systemImage.isEmpty else {
            return "missing-presentation"
        }
        guard Set(definition.parameters.map(\.id)).count == definition.parameters.count,
              definition.parameters.allSatisfy({ isValidIdentifier($0.id) }) else {
            return "invalid-parameter-schema"
        }
        let requiresConfirmation = definition.risk == .confirmationRequired
            || definition.externalInvocationPolicy == .confirmAlways
        guard !requiresConfirmation || definition.confirmation != nil else {
            return "missing-confirmation"
        }
        guard definition.capabilities.contains(.background)
            || definition.capabilities.contains(.foregroundInteractive) else {
            return "missing-execution-mode"
        }
        let timeout = definition.executionTimeoutSeconds
        if !timeout.isFinite || timeout <= 0 || timeout > 86_400 {
            return "invalid-timeout"
        }
        return nil
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "."
                || scalar == "_"
                || scalar == "-"
        }
    }
}
