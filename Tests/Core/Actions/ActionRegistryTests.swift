import Combine
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class ActionRegistryTests: XCTestCase {
    func testUnchangedCatalogKeepsPublicationsQuietAndRefreshesProviderCallbacks() {
        let registry = ActionRegistry(), provider = ActionRegistryTestProvider()
        let definition = makeActionDefinition()
        let reference = ActionReference(key: definition.key)
        func registration(_ availability: ActionAvailability, title: String = "Toggle") -> ActionProviderRegistration {
            ActionProviderRegistration(providerID: definition.key.providerID, identity: ObjectIdentifier(provider),
                definitions: [definition], catalogEntries: [.init(reference: reference, title: title)],
                availability: { _ in availability },
                begin: { _ in .success(ActionExecutionHandle { .succeeded() }) })
        }
        registry.synchronize([registration(.available)])
        var catalogPublications = 0, issuePublications = 0
        let catalog = registry.$catalogEntries.dropFirst().sink { _ in catalogPublications += 1 }
        let issues = registry.$issues.dropFirst().sink { _ in issuePublications += 1 }
        registry.synchronize([registration(.unavailable("Busy"))])
        XCTAssertEqual(catalogPublications, 0)
        XCTAssertEqual(issuePublications, 0)
        XCTAssertEqual(registry.availability(for: reference), .unavailable("Busy"))
        registry.synchronize([registration(.available, title: "Renamed")])
        XCTAssertEqual(catalogPublications, 1)
        XCTAssertEqual(registry.availability(for: reference), .available)
        withExtendedLifetime((catalog, issues)) {}
    }

    func testCatalogPresentationStateRoundTripsAndLegacyPayloadDefaultsToNil() throws {
        let reference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "toggle")
        )
        let entry = ActionCatalogEntry(
            reference: reference,
            title: "Turn Off",
            subtitle: "Active",
            presentationState: .active
        )
        let encoded = try JSONEncoder().encode(entry)

        XCTAssertEqual(try JSONDecoder().decode(ActionCatalogEntry.self, from: encoded), entry)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "presentationState")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyEntry = try JSONDecoder().decode(ActionCatalogEntry.self, from: legacyData)

        XCTAssertNil(legacyEntry.presentationState)
        XCTAssertEqual(legacyEntry.reference, reference)
    }

    func testRegistryRejectsUnknownParametersAndInvalidProviderDefinitions() throws {
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let definition = makeActionDefinition(
            parameters: [
                ActionParameterDefinition(id: "enabled", title: "启用", kind: .boolean),
            ]
        )
        let issues = registry.synchronize([
            provider.registration(definitions: [definition], catalogEntries: []),
        ])
        XCTAssertTrue(issues.isEmpty)

        let invalidReference = ActionReference(
            key: definition.key,
            parameters: try ActionParameterSet(["other": .boolean(true)])
        )
        XCTAssertEqual(
            registry.registeredAction(for: invalidReference),
            .failure(.invalidParameters("unknown-parameter:other"))
        )

        let invalidDefinition = ActionDefinition(
            key: ActionKey(providerID: "different-provider", actionID: "toggle"),
            title: "切换",
            description: "",
            systemImage: "switch.2"
        )
        XCTAssertEqual(
            registry.synchronize([
                provider.registration(definitions: [invalidDefinition], catalogEntries: []),
            ]),
            [.invalidDefinition(invalidDefinition.key, "provider-mismatch")]
        )
    }

    func testReferencePortabilityDistinguishesPortableKnownLocalAndUnknownActions() throws {
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let portable = makeActionDefinition(parameters: [
            ActionParameterDefinition(id: "value", title: "Value", kind: .string),
        ])
        let local = ActionDefinition(
            key: ActionKey(providerID: portable.key.providerID, actionID: "local"),
            title: "Local",
            description: "",
            systemImage: "externaldrive",
            parameters: [
                ActionParameterDefinition(
                    id: "device",
                    title: "Device",
                    kind: .string,
                    portability: .localOnly
                ),
            ]
        )
        registry.synchronize([provider.registration(
            definitions: [portable, local],
            catalogEntries: []
        )])
        let portableReference = ActionReference(
            key: portable.key,
            parameters: try ActionParameterSet(["value": .string("shared")])
        )
        let localReference = ActionReference(
            key: local.key,
            parameters: try ActionParameterSet(["device": .string("this-mac")])
        )
        let unknown = ActionReference(
            key: ActionKey(providerID: "missing", actionID: "run")
        )

        XCTAssertEqual(registry.portability(of: portableReference), .portable)
        XCTAssertEqual(registry.portability(of: localReference), .knownNonPortable)
        XCTAssertEqual(registry.portability(of: unknown), .unknown)
    }

    func testRegistryRejectsConfirmAlwaysDefinitionWithoutConfirmationMetadata() {
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let definition = makeActionDefinition(externalPolicy: .confirmAlways)

        let issues = registry.synchronize([
            provider.registration(
                definitions: [definition],
                catalogEntries: [
                    ActionCatalogEntry(
                        reference: ActionReference(key: definition.key),
                        title: definition.title
                    ),
                ]
            ),
        ])

        XCTAssertTrue(issues.contains(
            .invalidDefinition(definition.key, "missing-confirmation")
        ))
        XCTAssertNil(registry.definition(for: definition.key))
        XCTAssertTrue(registry.catalogEntries.isEmpty)
    }

    func testRegistryRetainsGenerationForIdenticalProviderAndInvalidatesChangedProvider() {
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let definition = makeActionDefinition()
        let entry = ActionCatalogEntry(
            reference: ActionReference(key: definition.key),
            title: definition.title
        )

        registry.synchronize([
            provider.registration(definitions: [definition], catalogEntries: [entry]),
        ])
        let first = try! registry.registeredAction(for: entry.reference).get()

        registry.synchronize([
            provider.registration(definitions: [definition], catalogEntries: [entry]),
        ])
        let unchanged = try! registry.registeredAction(for: entry.reference).get()
        XCTAssertEqual(unchanged.providerGeneration, first.providerGeneration)

        let renamed = ActionDefinition(
            key: definition.key,
            title: "新的标题",
            description: definition.description,
            systemImage: definition.systemImage
        )
        registry.synchronize([
            provider.registration(definitions: [renamed], catalogEntries: []),
        ])
        let changed = try! registry.registeredAction(
            for: ActionReference(key: definition.key)
        ).get()
        XCTAssertNotEqual(changed.providerGeneration, first.providerGeneration)
    }

    func testOneDefinitionCanPublishMultipleConcreteCatalogEntries() throws {
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let definition = makeActionDefinition(
            parameters: [
                ActionParameterDefinition(id: "display", title: "显示器", kind: .string),
            ]
        )
        let internalDisplay = ActionCatalogEntry(
            reference: ActionReference(
                key: definition.key,
                parameters: try ActionParameterSet(["display": .string("internal")])
            ),
            title: "内建显示器"
        )
        let externalDisplay = ActionCatalogEntry(
            reference: ActionReference(
                key: definition.key,
                parameters: try ActionParameterSet(["display": .string("external")])
            ),
            title: "外接显示器"
        )

        registry.synchronize([
            provider.registration(
                definitions: [definition],
                catalogEntries: [internalDisplay, externalDisplay]
            ),
        ])

        XCTAssertEqual(Set(registry.catalogEntries), Set([internalDisplay, externalDisplay]))
    }

    func testRegistryMigratesOlderReferencesAndRejectsFutureOrInvalidMigrations() throws {
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let definition = makeActionDefinition(
            parameterSchemaVersion: 2,
            parameters: [
                ActionParameterDefinition(id: "enabled", title: "启用", kind: .boolean),
            ]
        )
        let currentReference = ActionReference(
            key: definition.key,
            schemaVersion: 2,
            parameters: try ActionParameterSet(["enabled": .boolean(true)])
        )
        registry.synchronize([
            provider.registration(
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: currentReference, title: "启用")],
                migrate: { reference, targetVersion in
                    guard reference.schemaVersion == 1, targetVersion == 2 else { return nil }
                    return ActionReference(
                        key: reference.key,
                        schemaVersion: targetVersion,
                        parameters: try! ActionParameterSet(["enabled": .boolean(true)])
                    )
                }
            ),
        ])
        let legacyReference = ActionReference(key: definition.key, schemaVersion: 1)
        let futureReference = ActionReference(key: definition.key, schemaVersion: 3)

        XCTAssertEqual(registry.migrate(legacyReference), .success(currentReference))
        XCTAssertEqual(
            registry.registeredAction(for: legacyReference),
            .failure(.schemaVersionMismatch(definition.key, expected: 2, actual: 1))
        )
        XCTAssertEqual(
            registry.migrate(futureReference),
            .failure(.migrationUnavailable(definition.key, from: 3, to: 2))
        )

        registry.synchronize([
            provider.registration(
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: currentReference, title: "启用")],
                migrate: { reference, _ in reference }
            ),
        ])
        XCTAssertEqual(
            registry.migrate(legacyReference),
            .failure(.invalidMigration(definition.key))
        )
    }

    func testCatalogAndAvailabilityRevisionsAdvanceIndependently() {
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let definition = makeActionDefinition()
        let registration = provider.registration(
            definitions: [definition],
            catalogEntries: []
        )

        registry.synchronize([registration])
        let catalogRevision = registry.catalogRevision
        let availabilityRevision = registry.availabilityRevision
        registry.synchronize([registration])
        registry.invalidateAvailability()

        XCTAssertEqual(registry.catalogRevision, catalogRevision)
        XCTAssertEqual(registry.availabilityRevision, availabilityRevision + 1)

        let renamed = ActionDefinition(
            key: definition.key,
            title: "新标题",
            description: definition.description,
            systemImage: definition.systemImage,
            externalInvocationPolicy: definition.externalInvocationPolicy,
            capabilities: definition.capabilities
        )
        registry.synchronize([
            provider.registration(definitions: [renamed], catalogEntries: []),
        ])
        XCTAssertEqual(registry.catalogRevision, catalogRevision + 1)
        XCTAssertEqual(registry.availabilityRevision, availabilityRevision + 1)
    }

    func testExposurePolicyDefaultsToAutomaticAndUnknownActionsFailClosed() {
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let definition = makeActionDefinition()
        let reference = ActionReference(key: definition.key)

        registry.synchronize([
            provider.registration(definitions: [definition], catalogEntries: []),
        ])

        XCTAssertEqual(
            registry.exposurePolicy(for: reference, on: .appIntents),
            .automatic
        )
        XCTAssertEqual(
            registry.exposurePolicy(
                for: ActionReference(
                    key: ActionKey(providerID: "missing", actionID: "run")
                ),
                on: .appIntents
            ),
            .excluded
        )
    }

    func testExposurePolicyUsesCurrentProviderDecision() {
        let registry = ActionRegistry()
        let provider = ActionRegistryTestProvider()
        let definition = makeActionDefinition()
        let reference = ActionReference(key: definition.key)
        provider.exposurePolicy = .excluded

        registry.synchronize([
            provider.registration(definitions: [definition], catalogEntries: []),
        ])

        XCTAssertEqual(
            registry.exposurePolicy(for: reference, on: .appIntents),
            .excluded
        )

        provider.exposurePolicy = .automatic
        XCTAssertEqual(
            registry.exposurePolicy(for: reference, on: .appIntents),
            .automatic
        )
    }
}

@MainActor
final class ActionRegistryTestProvider {
    var availability: ActionAvailability = .available
    var exposurePolicy: ActionExposurePolicy = .automatic
    var beginResult: ActionExecutionResult = .succeeded()

    func registration(
        definitions: [ActionDefinition],
        catalogEntries: [ActionCatalogEntry],
        migrate: @escaping (ActionReference, Int) -> ActionReference? = { reference, version in
            reference.schemaVersion == version ? reference : nil
        }
    ) -> ActionProviderRegistration {
        ActionProviderRegistration(
            providerID: "test-provider",
            identity: ObjectIdentifier(self),
            definitions: definitions,
            catalogEntries: catalogEntries,
            availability: { [weak self] _ in
                self?.availability ?? .unavailable("missing")
            },
            exposurePolicy: { [weak self] _, _ in
                self?.exposurePolicy ?? .excluded
            },
            migrate: migrate,
            begin: { [weak self] _ in
                guard let self else {
                    return .failure(.providerFailure("missing"))
                }
                let result = self.beginResult
                return .success(
                    ActionExecutionHandle(operation: { result })
                )
            }
        )
    }
}

func makeActionDefinition(
    parameterSchemaVersion: Int = 1,
    parameters: [ActionParameterDefinition] = [],
    risk: ActionRisk = .safe,
    confirmation: ActionConfirmation? = nil,
    externalPolicy: ActionExternalInvocationPolicy = .allowed,
    capabilities: ActionExecutionCapabilities = [.background, .foregroundInteractive],
    concurrencyPolicy: ActionConcurrencyPolicy = .rejectWhileRunning,
    timeout: Double = 30
) -> ActionDefinition {
    ActionDefinition(
        key: ActionKey(providerID: "test-provider", actionID: "toggle"),
        parameterSchemaVersion: parameterSchemaVersion,
        title: "切换",
        description: "切换测试状态",
        systemImage: "switch.2",
        parameters: parameters,
        risk: risk,
        confirmation: confirmation,
        externalInvocationPolicy: externalPolicy,
        capabilities: capabilities,
        concurrencyPolicy: concurrencyPolicy,
        executionTimeoutSeconds: timeout
    )
}
