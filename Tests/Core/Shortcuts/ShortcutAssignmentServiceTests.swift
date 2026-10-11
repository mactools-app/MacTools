import Carbon
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class ShortcutAssignmentServiceTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "ShortcutAssignmentServiceTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testCommandNumberAssignmentPersistsRegistersAndClears() throws {
        let harness = try makeHarness()
        let reference = harness.references[0]
        let binding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_1), modifiers: .command)

        XCTAssertEqual(
            harness.service.assign(binding, to: reference),
            .success
        )

        let item = try XCTUnwrap(harness.service.settingsItems.first)
        XCTAssertEqual(item.assignment.reference, reference)
        XCTAssertEqual(item.state, .registered)
        XCTAssertEqual(harness.registrar.registeredBindings, [binding])
        XCTAssertEqual(
            harness.service.reference(
                forShortcutID: try XCTUnwrap(
                    harness.manager.debugRegistrationsForTests.first {
                        $0.binding == binding
                    }?.shortcutID
                )
            ),
            reference
        )

        let reloadedStore = ActionShortcutAssignmentStore(defaults: harness.defaults)
        XCTAssertEqual(reloadedStore.assignments(), harness.service.assignments)

        let restored = try makeHarness(defaults: harness.defaults)
        XCTAssertEqual(restored.registrar.registeredBindings, [binding])
        XCTAssertEqual(restored.service.settingsItems.map(\.state), [.registered])
        XCTAssertEqual(restored.service.clear(reference), .success)
        XCTAssertTrue(reloadedStore.assignments().isEmpty)
        XCTAssertTrue(restored.manager.registrationStatuses.isEmpty)
        XCTAssertEqual(restored.registrar.unregisteredCount, 1)
    }

    func testCorruptAssignmentPayloadRejectsOrdinaryMutationWithoutOverwritingBytes() throws {
        let harness = try makeHarness()
        let corrupt = Data("not-json".utf8)
        harness.defaults.set(corrupt, forKey: "action-shortcuts.assignments")

        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[0]),
            .failure(.recoveryRequired)
        )
        XCTAssertEqual(
            harness.service.clear(harness.references[0]),
            .failure(.recoveryRequired)
        )
        XCTAssertEqual(harness.defaults.data(forKey: "action-shortcuts.assignments"), corrupt)
    }

    func testRejectedAssignmentPayloadWriteRestoresPreviousBytes() {
        let defaults = RejectingActionShortcutDefaults()
        let store = ActionShortcutAssignmentStore(defaults: defaults)
        let first = ActionShortcutAssignmentRecord(
            reference: ActionReference(
                key: ActionKey(providerID: "shortcut-tests", actionID: "first")
            ),
            binding: ShortcutBinding(keyCode: 10, modifiers: [.command, .option])
        )
        XCTAssertEqual(store.replaceAll([first]), .committed)
        let previousData = defaults.data(forKey: "action-shortcuts.assignments")

        defaults.blockedSetKeys = ["action-shortcuts.assignments"]
        let second = ActionShortcutAssignmentRecord(
            reference: ActionReference(
                key: ActionKey(providerID: "shortcut-tests", actionID: "second")
            ),
            binding: ShortcutBinding(keyCode: 11, modifiers: [.command, .shift])
        )

        XCTAssertEqual(
            store.replaceAll([second]),
            .rejected(rollbackSucceeded: true)
        )
        XCTAssertEqual(defaults.data(forKey: "action-shortcuts.assignments"), previousData)
        XCTAssertEqual(store.assignments(), [first])
    }

    func testConflictReplacementIsAtomicAndReservedBindingsCannotBeReplaced() throws {
        let harness = try makeHarness()
        let first = harness.references[0]
        let second = harness.references[1]
        let binding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_9), modifiers: .command)
        XCTAssertEqual(harness.service.assign(binding, to: first), .success)

        XCTAssertEqual(
            harness.service.assign(binding, to: second),
            .failure(.conflict(ownerDescription: "操作 1"))
        )
        XCTAssertEqual(harness.service.assignments.map(\.reference), [first])

        XCTAssertEqual(
            harness.service.assign(
                binding,
                to: second,
                replacingConflictingActionAssignments: true
            ),
            .success
        )
        XCTAssertEqual(harness.service.assignments.map(\.reference), [second])

        let reserved = GlobalShortcutManager.Registration(
            shortcutID: "special.release-aware",
            binding: harness.bindings[1]
        )
        harness.service.synchronize(
            reservedRegistrations: [reserved],
            reservedOwnerDescriptions: [reserved.shortcutID: "亮度连续调节"]
        )
        XCTAssertEqual(
            harness.service.assign(
                harness.bindings[1],
                to: first,
                replacingConflictingActionAssignments: true
            ),
            .failure(.conflict(ownerDescription: "亮度连续调节"))
        )
        XCTAssertEqual(harness.service.assignments.map(\.reference), [second])

        for keyCode in [kVK_UpArrow, kVK_DownArrow] {
            let navigationBinding = ShortcutBinding(keyCode: UInt16(keyCode), modifiers: [.control, .command])
            XCTAssertEqual(
                harness.service.assign(navigationBinding, to: first),
                .failure(.invalidBinding(.duplicate(ownerDescription: AppMetadata.appName)))
            )
        }
        XCTAssertEqual(harness.service.assignments.map(\.reference), [second])
    }

    func testPresetReplacementIsConflictCheckedAndAtomic() throws {
        let harness = try makeHarness()
        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[1]),
            .success
        )

        XCTAssertEqual(
            harness.service.replaceAssignments(
                providerID: "shortcut-tests",
                managedActionIDs: ["action-1"],
                bindingsByActionID: ["action-1": harness.bindings[0]]
            ),
            .failure(.conflict(ownerDescription: "操作 2"))
        )
        XCTAssertEqual(harness.service.assignments.map(\.reference), [harness.references[1]])

        XCTAssertEqual(
            harness.service.replaceAssignments(
                providerID: "shortcut-tests",
                managedActionIDs: ["action-1", "action-2"],
                bindingsByActionID: [
                    "action-1": harness.bindings[0],
                    "action-2": harness.bindings[1],
                ]
            ),
            .success
        )
        XCTAssertEqual(
            Set(harness.service.assignments.map(\.reference)),
            Set(harness.references)
        )

        XCTAssertEqual(
            harness.service.replaceAssignments(
                providerID: "shortcut-tests",
                managedActionIDs: ["action-1", "action-2"],
                bindingsByActionID: [:]
            ),
            .success
        )
        XCTAssertTrue(harness.service.assignments.isEmpty)
    }

    func testPresetPreviewShowsChangesWithoutMutatingAssignments() throws {
        let harness = try makeHarness()
        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[0]),
            .success
        )
        let assignmentsBeforePreview = harness.service.assignments

        let preview = harness.service.replacementPreview(
            providerID: "shortcut-tests",
            managedActionIDs: ["action-1", "action-2"],
            bindingsByActionID: [
                "action-1": harness.bindings[1],
                "action-2": harness.bindings[0],
            ]
        )

        XCTAssertTrue(preview.canApply)
        XCTAssertTrue(preview.hasChanges)
        XCTAssertEqual(preview.items.count, 2)
        XCTAssertEqual(
            preview.items.first(where: { $0.actionID == "action-1" })?.currentBinding,
            harness.bindings[0]
        )
        XCTAssertEqual(harness.service.assignments, assignmentsBeforePreview)
    }

    func testReplacementTransactionRestoresExactConvergedRecordsWhenMutationFails() throws {
        let reporter = PreferencesBackupChangeReporter()
        var reportedSources: [PreferencesBackupChangeSource] = []
        reporter.onCommittedChange = { reportedSources.append($0) }
        let harness = try makeHarness(preferencesBackupChangeReporter: reporter)
        let records = [
            ActionShortcutAssignmentRecord(
                reference: harness.references[0],
                binding: harness.bindings[0]
            ),
            ActionShortcutAssignmentRecord(
                reference: harness.references[0],
                binding: harness.bindings[1]
            ),
        ]
        XCTAssertEqual(
            ActionShortcutAssignmentStore(defaults: harness.defaults).replaceAll(records),
            .committed
        )

        let error = harness.service.performReplacementTransaction(
            providerID: "shortcut-tests",
            managedActionIDs: ["action-1"],
            bindingsByActionID: [:]
        ) {
            "Layout storage failed"
        }

        XCTAssertEqual(error, "Layout storage failed")
        XCTAssertEqual(harness.service.assignments, records)
        XCTAssertEqual(reportedSources, [])
    }

    func testUnavailableAssignmentsAreRetainedButNotRegistered() throws {
        let harness = try makeHarness()
        let reference = harness.references[0]
        XCTAssertEqual(harness.service.assign(harness.bindings[0], to: reference), .success)

        harness.registry.synchronize([])
        harness.service.synchronize(
            reservedRegistrations: [],
            reservedOwnerDescriptions: [:]
        )

        XCTAssertEqual(harness.service.assignments.first?.reference, reference)
        XCTAssertEqual(
            harness.service.settingsItems.first?.state,
            .unavailable(reason: FeatureL10n.string("操作不可用。"))
        )
        XCTAssertFalse(
            harness.manager.debugRegistrationsForTests.contains {
                $0.binding == harness.bindings[0]
            }
        )
    }

    func testAssignmentUnregistersWhenForegroundCapabilityDisappearsAndRecovers() throws {
        let harness = try makeHarness()
        let reference = harness.references[0]
        XCTAssertEqual(harness.service.assign(harness.bindings[0], to: reference), .success)
        let provider = ShortcutActionTestProvider()

        func registration(
            capabilities: ActionExecutionCapabilities
        ) -> ActionProviderRegistration {
            let definitions = harness.references.map { reference in
                ActionDefinition(
                    key: reference.key,
                    title: reference.key.actionID,
                    description: "",
                    systemImage: "bolt",
                    externalInvocationPolicy: .allowed,
                    capabilities: capabilities
                )
            }
            return ActionProviderRegistration(
                providerID: reference.key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: definitions,
                catalogEntries: definitions.map {
                    ActionCatalogEntry(reference: ActionReference(key: $0.key), title: $0.title)
                },
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            )
        }

        harness.registry.synchronize([registration(capabilities: [.background])])
        harness.service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])

        XCTAssertEqual(harness.service.assignments.first?.reference, reference)
        XCTAssertEqual(
            harness.service.settingsItems.first?.state,
            .unavailable(reason: FeatureL10n.string("操作不可用。"))
        )
        XCTAssertFalse(
            harness.manager.debugRegistrationsForTests.contains {
                $0.binding == harness.bindings[0]
            }
        )

        harness.registry.synchronize([
            registration(capabilities: [.background, .foregroundInteractive]),
        ])
        harness.service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])

        XCTAssertEqual(harness.service.settingsItems.first?.state, .registered)
        XCTAssertTrue(
            harness.manager.debugRegistrationsForTests.contains {
                $0.binding == harness.bindings[0]
            }
        )
    }

    func testCarbonRegistrationFailureIsVisibleAndRecoverable() throws {
        let harness = try makeHarness()
        harness.registrar.failures[harness.bindings[0]] = -9876

        XCTAssertEqual(
            harness.service.assign(harness.bindings[0], to: harness.references[0]),
            .success
        )
        XCTAssertEqual(
            harness.service.settingsItems.first?.state,
            .registrationFailed(code: -9876)
        )

        harness.registrar.failures.removeAll()
        harness.service.synchronize(
            reservedRegistrations: [],
            reservedOwnerDescriptions: [:]
        )
        XCTAssertEqual(harness.service.settingsItems.first?.state, .registered)
    }

    func testLegacyMigrationIsIdempotentAndClearsSourceOnlyAfterPersistence() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ActionShortcutAssignmentStore(userDefaults: defaults)
        let reference = ActionReference(
            key: ActionKey(providerID: "mactools", actionID: "app.open-settings")
        )
        let binding = ShortcutBinding(keyCode: 12, modifiers: [.command, .option])
        var didPersistCount = 0
        XCTAssertFalse(store.hasMigratedLegacyAppAssignments)

        XCTAssertEqual(
            store.migrateLegacyAppAssignments([(reference, binding)]) {
                XCTAssertTrue(defaults.bool(forKey: "action-shortcuts.migrated-app-shortcuts"))
                didPersistCount += 1
            },
            .migrated
        )
        XCTAssertEqual(
            store.migrateLegacyAppAssignments([(reference, binding)]) {
                didPersistCount += 1
            },
            .alreadyMigrated
        )
        XCTAssertEqual(didPersistCount, 1)
        XCTAssertTrue(store.hasMigratedLegacyAppAssignments)
        XCTAssertEqual(store.assignments().map(\.reference), [reference])
        XCTAssertEqual(store.assignments().map(\.binding), [binding])
    }

    func testRollbackFailureReconcilesRuntimeToUnreadableDurablePayload() throws {
        let defaults = ScriptedActionShortcutDefaults()
        let store = ActionShortcutAssignmentStore(defaults: defaults)
        let registry = ActionRegistry()
        let provider = ShortcutActionTestProvider()
        let reference = ActionReference(
            key: ActionKey(providerID: "shortcut-tests", actionID: "action")
        )
        let definition = ActionDefinition(
            key: reference.key,
            title: "操作",
            description: "",
            systemImage: "bolt",
            externalInvocationPolicy: .allowed,
            capabilities: [.background, .foregroundInteractive]
        )
        registry.synchronize([
            ActionProviderRegistration(
                providerID: reference.key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: reference, title: "操作")],
                availability: { _ in .available },
                begin: { _ in .success(ActionExecutionHandle(operation: { .succeeded() })) }
            ),
        ])
        let originalBinding = ShortcutBinding(keyCode: 10, modifiers: [.command, .option])
        XCTAssertEqual(
            store.replaceAll([
                ActionShortcutAssignmentRecord(reference: reference, binding: originalBinding),
            ]),
            .committed
        )
        let manager = GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        let service = ShortcutAssignmentService(registry: registry, store: store, shortcutManager: manager)
        service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])
        XCTAssertEqual(service.settingsItems.map(\.state), [.registered])

        defaults.payloadWriteBehaviors = [.corrupt, .ignore]
        let replacement = ShortcutBinding(keyCode: 11, modifiers: [.command, .shift])
        XCTAssertEqual(
            service.assign(replacement, to: reference),
            .failure(.persistenceRollbackFailed)
        )
        XCTAssertTrue(service.settingsItems.isEmpty)
        XCTAssertNil(service.reference(forShortcutID: manager.debugRegistrationsForTests.first?.shortcutID ?? ""))
        XCTAssertTrue(manager.debugRegistrationsForTests.isEmpty)
        XCTAssertNotNil(store.loadError)
    }

    private func makeHarness(
        defaults suppliedDefaults: (any ActionShortcutAssignmentPersisting)? = nil,
        preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil
    ) throws -> ShortcutServiceHarness {
        let defaults: any ActionShortcutAssignmentPersisting
        if let suppliedDefaults {
            defaults = suppliedDefaults
        } else {
            let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            userDefaults.removePersistentDomain(forName: suiteName)
            defaults = userDefaults
        }
        let registry = ActionRegistry()
        let provider = ShortcutActionTestProvider()
        let definitions = (1 ... 2).map { index in
            ActionDefinition(
                key: ActionKey(providerID: "shortcut-tests", actionID: "action-\(index)"),
                title: "操作 \(index)",
                description: "测试操作",
                systemImage: "bolt",
                externalInvocationPolicy: .allowed,
                capabilities: [.background, .foregroundInteractive]
            )
        }
        let entries = definitions.map {
            ActionCatalogEntry(reference: ActionReference(key: $0.key), title: $0.title)
        }
        registry.synchronize([
            ActionProviderRegistration(
                providerID: "shortcut-tests",
                identity: ObjectIdentifier(provider),
                definitions: definitions,
                catalogEntries: entries,
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
        let registrar = FakeCarbonHotKeyRegistrar()
        let manager = GlobalShortcutManager(registrar: registrar)
        let service = ShortcutAssignmentService(
            registry: registry,
            store: ActionShortcutAssignmentStore(
                defaults: defaults,
                preferencesBackupChangeReporter: preferencesBackupChangeReporter
            ),
            shortcutManager: manager
        )
        service.synchronize(reservedRegistrations: [], reservedOwnerDescriptions: [:])
        return ShortcutServiceHarness(
            defaults: defaults,
            registry: registry,
            registrar: registrar,
            manager: manager,
            service: service,
            references: entries.map(\.reference),
            bindings: [
                ShortcutBinding(keyCode: 10, modifiers: [.command, .option]),
                ShortcutBinding(keyCode: 11, modifiers: [.command, .shift]),
            ]
        )
    }
}

@MainActor
private final class ShortcutActionTestProvider {}

@MainActor
private final class RejectingActionShortcutDefaults: ActionShortcutAssignmentPersisting {
    var blockedSetKeys: Set<String> = []
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) {
        guard !blockedSetKeys.contains(defaultName) else { return }
        values[defaultName] = value
    }
    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}

@MainActor
private final class ScriptedActionShortcutDefaults: ActionShortcutAssignmentPersisting {
    enum PayloadWriteBehavior {
        case accept
        case corrupt
        case ignore
    }

    var payloadWriteBehaviors: [PayloadWriteBehavior] = []
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }

    func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "action-shortcuts.assignments", !payloadWriteBehaviors.isEmpty {
            switch payloadWriteBehaviors.removeFirst() {
            case .accept:
                values[defaultName] = value
            case .corrupt:
                values[defaultName] = Data("corrupt".utf8)
            case .ignore:
                break
            }
            return
        }
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}

@MainActor
private struct ShortcutServiceHarness {
    let defaults: any ActionShortcutAssignmentPersisting
    let registry: ActionRegistry
    let registrar: FakeCarbonHotKeyRegistrar
    let manager: GlobalShortcutManager
    let service: ShortcutAssignmentService
    let references: [ActionReference]
    let bindings: [ShortcutBinding]
}

@MainActor
final class FakeCarbonHotKeyRegistrar: CarbonHotKeyRegistering {
    var failures: [ShortcutBinding: OSStatus] = [:]
    private(set) var registeredBindings: [ShortcutBinding] = []
    private(set) var unregisteredCount = 0

    func register(
        binding: ShortcutBinding,
        signature: OSType,
        carbonID: UInt32
    ) -> Result<EventHotKeyRef, GlobalShortcutRegistrationError> {
        if let status = failures[binding] {
            return .failure(.system(status))
        }
        registeredBindings.append(binding)
        return .success(OpaquePointer(bitPattern: Int(carbonID))!)
    }

    func unregister(_ reference: EventHotKeyRef) {
        unregisteredCount += 1
    }
}
