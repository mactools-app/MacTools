import AppKit
import ApplicationServices
import XCTest
import MacToolsPluginKit
@testable import AutoInputPlugin

@MainActor
final class AutoInputStoreTests: XCTestCase {
    func testDefaultsAndPersistence() {
        let storage = AutoInputMemoryStorage()
        let store = AutoInputStore(storage: storage)
        XCTAssertTrue(store.isAutoSwitchEnabled)
        XCTAssertFalse(store.isInputHUDEnabled)
        XCTAssertFalse(store.reducesFrequentHUDPresentations)
        XCTAssertEqual(store.inputHUDReminderIntervalSeconds, 60)
        XCTAssertEqual(store.inputHUDAppSwitchReminderCount, 3)
        XCTAssertFalse(store.isInteractiveHUDEnabled)
        XCTAssertEqual(store.inputHUDSize, .standard)
        XCTAssertEqual(store.inputHUDPosition, .automatic)
        XCTAssertTrue(store.remembersLastInputSource)

        store.setAutoSwitchEnabled(false)
        store.setInputHUDEnabled(true)
        store.setReducesFrequentHUDPresentations(true)
        store.setInputHUDReminderIntervalSeconds(25)
        store.setInputHUDAppSwitchReminderCount(2)
        store.setInteractiveHUDEnabled(true)
        store.setInputHUDSize(.large)
        store.setInputHUDPosition(.atPointer)
        store.setRemembersLastInputSource(false)
        store.upsertRule(makeRule(bundleID: "com.example.editor", sourceID: "zh"))
        store.remember(inputSourceID: "en", for: "com.example.terminal")

        let reloaded = AutoInputStore(storage: storage)
        XCTAssertFalse(reloaded.isAutoSwitchEnabled)
        XCTAssertTrue(reloaded.isInputHUDEnabled)
        XCTAssertTrue(reloaded.reducesFrequentHUDPresentations)
        XCTAssertEqual(reloaded.inputHUDReminderIntervalSeconds, 25)
        XCTAssertEqual(reloaded.inputHUDAppSwitchReminderCount, 2)
        XCTAssertTrue(reloaded.isInteractiveHUDEnabled)
        XCTAssertEqual(reloaded.inputHUDSize, .large)
        XCTAssertEqual(reloaded.inputHUDPosition, .atPointer)
        XCTAssertFalse(reloaded.remembersLastInputSource)
        XCTAssertEqual(reloaded.rule(for: "com.example.editor")?.inputSourceID, "zh")
        XCTAssertEqual(reloaded.rememberedInputSourceID(for: "com.example.terminal"), "en")
    }

    func testUpsertKeepsOneRulePerBundleIdentifier() {
        let store = AutoInputStore(storage: AutoInputMemoryStorage())
        store.upsertRule(makeRule(bundleID: "com.example.app", sourceID: "en"))
        store.upsertRule(makeRule(bundleID: "com.example.app", sourceID: "zh"))

        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rules[0].inputSourceID, "zh")
    }

    func testKeyboardModeDefaultsToSystemAndPersists() {
        let storage = AutoInputMemoryStorage()
        let store = AutoInputStore(storage: storage)
        store.upsertRule(makeRule(bundleID: "com.example.editor", sourceID: "en"))
        XCTAssertEqual(store.rule(for: "com.example.editor")?.keyboardMode, .system)
        XCTAssertFalse(store.hasKeyboardModeRules)

        store.updateRuleKeyboardMode(
            bundleIdentifier: "com.example.editor",
            keyboardMode: .standardFunctionKeys
        )

        XCTAssertTrue(store.hasKeyboardModeRules)
        let reloaded = AutoInputStore(storage: storage)
        XCTAssertEqual(
            reloaded.rule(for: "com.example.editor")?.keyboardMode,
            .standardFunctionKeys
        )
    }

    func testLegacyRulesWithoutKeyboardModeFollowSystem() {
        let storage = AutoInputMemoryStorage()
        let legacyRules = """
        [{"bundleIdentifier":"com.example.legacy","displayName":"Legacy","inputSourceID":"en"}]
        """
        storage.setRawValue(Data(legacyRules.utf8), forKey: "rules")

        let store = AutoInputStore(storage: storage)

        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rule(for: "com.example.legacy")?.keyboardMode, .system)
    }

    func testRejectedWritesDoNotPublishBooleanOrRuleCandidates() {
        let storage = AutoInputMemoryStorage()
        storage.blockedSetKeys = [
            "isAutoSwitchEnabled",
            "isInputHUDEnabled",
            "reducesFrequentHUDPresentations",
            "inputHUDReminderIntervalSeconds",
            "inputHUDAppSwitchReminderCount",
            "isInteractiveHUDEnabled",
            "inputHUDSize",
            "inputHUDPosition",
            "rules",
        ]
        let store = AutoInputStore(storage: storage)

        XCTAssertEqual(store.setAutoSwitchEnabled(false), .rejected(rollbackSucceeded: true))
        XCTAssertEqual(store.setInputHUDEnabled(true), .rejected(rollbackSucceeded: true))
        XCTAssertEqual(
            store.setReducesFrequentHUDPresentations(true),
            .rejected(rollbackSucceeded: true)
        )
        XCTAssertEqual(
            store.setInputHUDReminderIntervalSeconds(25),
            .rejected(rollbackSucceeded: true)
        )
        XCTAssertEqual(
            store.setInputHUDAppSwitchReminderCount(2),
            .rejected(rollbackSucceeded: true)
        )
        XCTAssertEqual(store.setInteractiveHUDEnabled(true), .rejected(rollbackSucceeded: true))
        XCTAssertEqual(store.setInputHUDSize(.large), .rejected(rollbackSucceeded: true))
        XCTAssertEqual(store.setInputHUDPosition(.above), .rejected(rollbackSucceeded: true))
        XCTAssertTrue(store.isAutoSwitchEnabled)
        XCTAssertFalse(store.isInputHUDEnabled)
        XCTAssertFalse(store.reducesFrequentHUDPresentations)
        XCTAssertEqual(store.inputHUDReminderIntervalSeconds, 60)
        XCTAssertEqual(store.inputHUDAppSwitchReminderCount, 3)
        XCTAssertFalse(store.isInteractiveHUDEnabled)
        XCTAssertEqual(store.inputHUDSize, .standard)
        XCTAssertEqual(store.inputHUDPosition, .automatic)
        XCTAssertEqual(
            store.upsertRule(makeRule(bundleID: "com.example.app", sourceID: "en")),
            .rejected(rollbackSucceeded: true)
        )
        XCTAssertTrue(store.rules.isEmpty)

        let reloaded = AutoInputStore(storage: storage)
        XCTAssertTrue(reloaded.isAutoSwitchEnabled)
        XCTAssertFalse(reloaded.isInputHUDEnabled)
        XCTAssertFalse(reloaded.reducesFrequentHUDPresentations)
        XCTAssertEqual(reloaded.inputHUDReminderIntervalSeconds, 60)
        XCTAssertEqual(reloaded.inputHUDAppSwitchReminderCount, 3)
        XCTAssertFalse(reloaded.isInteractiveHUDEnabled)
        XCTAssertEqual(reloaded.inputHUDSize, .standard)
        XCTAssertEqual(reloaded.inputHUDPosition, .automatic)
        XCTAssertTrue(reloaded.rules.isEmpty)
    }

}

@MainActor
final class AutoInputControllerTests: XCTestCase {
    func testFixedRuleTakesPriorityOverRememberedSource() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))
        fixture.store.remember(inputSourceID: "en", for: fixture.app.bundleIdentifier)

        fixture.controller.start()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
        XCTAssertEqual(fixture.controller.target(for: fixture.app.bundleIdentifier)?.reason, .fixedRule)
    }

    func testRememberedSourceIsRestoredWithoutFixedRule() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.remember(inputSourceID: "zh", for: fixture.app.bundleIdentifier)

        fixture.controller.start()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
        XCTAssertEqual(fixture.controller.target(for: fixture.app.bundleIdentifier)?.reason, .remembered)
    }

    func testUnavailableFixedRuleFallsBackToRememberedSource() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "missing"))
        fixture.store.remember(inputSourceID: "zh", for: fixture.app.bundleIdentifier)

        fixture.controller.start()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
    }

    func testDisabledPluginDoesNotSwitchOrRemember() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))
        fixture.store.setAutoSwitchEnabled(false)

        fixture.controller.start()
        fixture.sources.currentSourceID = "zh"
        fixture.sources.emitChange()

        XCTAssertTrue(fixture.sources.selectedIDs.isEmpty)
        XCTAssertNil(fixture.store.rememberedInputSourceID(for: fixture.app.bundleIdentifier))
    }

    func testSourceChangeRemembersCurrentInputSourceForFrontmostApp() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.controller.start()

        fixture.sources.currentSourceID = "zh"
        fixture.sources.emitChange()

        XCTAssertEqual(fixture.store.rememberedInputSourceID(for: fixture.app.bundleIdentifier), "zh")
    }

    func testSelectionFailurePublishesError() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.sources.selectionError = AutoInputSourceError.selectionFailed(-1)
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))

        fixture.controller.start()

        XCTAssertEqual(fixture.controller.errorMessage, "无法切换输入法")
    }

    func testStopRemovesObservers() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.controller.start()
        fixture.controller.stop()

        XCTAssertEqual(fixture.sources.stopCount, 1)
        XCTAssertEqual(fixture.applications.stopCount, 1)
        XCTAssertEqual(fixture.focusObserver.stopCount, 0)
        XCTAssertGreaterThanOrEqual(fixture.hud.dismissCount, 1)
    }

    func testHUDStartsOnlyWhenEnabledAndAccessibilityIsGranted() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)

        fixture.controller.start()
        XCTAssertEqual(fixture.focusObserver.startCount, 0)

        fixture.store.setInputHUDEnabled(true)
        fixture.controller.configurationDidChange()

        XCTAssertEqual(fixture.focusObserver.startCount, 1)
        fixture.focusObserver.focus(AutoInputEditableFocus(frame: CGRect(x: 100, y: 200, width: 300, height: 24)))
        XCTAssertEqual(fixture.hud.presentations.last?.sourceName, "ABC")
        XCTAssertEqual(
            fixture.hud.presentations.last?.configuration,
            AutoInputHUDConfiguration(size: .standard, position: .automatic)
        )
    }

    func testHUDPermissionDenialDoesNotDisableAutomaticSwitching() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: false)
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))
        fixture.store.setInputHUDEnabled(true)

        fixture.controller.start()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
        XCTAssertEqual(fixture.focusObserver.startCount, 0)
        XCTAssertFalse(fixture.controller.isAccessibilityGranted)
    }

    func testAccessibilityRevocationStopsHUDAndPreservesAutomaticSwitching() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()
        fixture.focusObserver.focus(AutoInputEditableFocus(frame: CGRect(x: 100, y: 200, width: 300, height: 24)))

        fixture.accessibility.isTrusted = false
        fixture.focusObserver.invalidateAccessibility()

        XCTAssertFalse(fixture.controller.isAccessibilityGranted)
        XCTAssertEqual(fixture.focusObserver.stopCount, 1)
        XCTAssertGreaterThanOrEqual(fixture.hud.dismissCount, 1)
        XCTAssertEqual(fixture.applications.stopCount, 0)
    }

    func testKeyboardModeAppliesForRuleWhileAppIsFrontmost() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.upsertRule(makeRule(
            bundleID: fixture.app.bundleIdentifier,
            sourceID: "zh",
            keyboardMode: .standardFunctionKeys
        ))

        fixture.controller.start()

        XCTAssertEqual(fixture.functionKeys.writes, [true])
        XCTAssertTrue(fixture.functionKeys.isStandardFunctionKeysEnabled)
    }

    func testKeyboardModeAppliesWithoutAutomaticSwitching() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(false)
        fixture.store.upsertRule(makeRule(
            bundleID: fixture.app.bundleIdentifier,
            sourceID: "zh",
            keyboardMode: .standardFunctionKeys
        ))

        fixture.controller.start()

        XCTAssertEqual(fixture.functionKeys.writes, [true])
        XCTAssertTrue(fixture.sources.selectedIDs.isEmpty)
    }

    func testKeyboardModeRestoresForAppWithoutRule() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.functionKeys.isStandardFunctionKeysEnabled = true
        fixture.store.upsertRule(makeRule(
            bundleID: fixture.app.bundleIdentifier,
            sourceID: "zh",
            keyboardMode: .mediaShortcuts
        ))

        fixture.controller.start()
        XCTAssertEqual(fixture.functionKeys.writes, [false])

        fixture.applications.activate(AutoInputApplication(
            bundleIdentifier: "com.example.other",
            displayName: "Other",
            bundleURL: nil,
            processIdentifier: 202
        ))

        XCTAssertEqual(fixture.functionKeys.writes, [false, true])
        XCTAssertTrue(fixture.functionKeys.isStandardFunctionKeysEnabled)
    }

    func testStopRestoresKeyboardMode() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.upsertRule(makeRule(
            bundleID: fixture.app.bundleIdentifier,
            sourceID: "zh",
            keyboardMode: .standardFunctionKeys
        ))
        fixture.controller.start()
        XCTAssertEqual(fixture.functionKeys.writes, [true])

        fixture.controller.stop()

        XCTAssertEqual(fixture.functionKeys.writes, [true, false])
        XCTAssertFalse(fixture.functionKeys.isStandardFunctionKeysEnabled)
    }

    private func makeFixture(
        currentSourceID: String,
        accessibilityGranted: Bool = false,
        application: AutoInputApplication? = nil,
        hudLabelResolver: InputSourceHUDLabelResolving = StandardInputSourceHUDLabelResolver(),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> AutoInputFixture {
        let storage = AutoInputMemoryStorage()
        let store = AutoInputStore(storage: storage)
        let sources = FakeAutoInputSourceController(
            sources: [
                AutoInputSource(id: "en", name: "ABC"),
                AutoInputSource(id: "zh", name: "中文")
            ],
            currentSourceID: currentSourceID
        )
        let app = application ?? AutoInputApplication(
            bundleIdentifier: "com.example.editor",
            displayName: "Editor",
            bundleURL: URL(fileURLWithPath: "/Applications/Editor.app"),
            processIdentifier: 101
        )
        let applications = FakeAutoInputApplicationMonitor(frontmostApplication: app)
        let focusObserver = FakeAutoInputFocusObserver()
        let hud = FakeInputSourceHUDPresenter()
        let accessibility = FakeAutoInputAccessibilityCheck(isTrusted: accessibilityGranted)
        let functionKeys = FakeAutoInputFunctionKeyController()
        let applicationNotificationCenter = NotificationCenter()
        let controller = AutoInputController(
            store: store,
            sourceController: sources,
            applicationMonitor: applications,
            focusObserver: focusObserver,
            hudPresenter: hud,
            hudLabelResolver: hudLabelResolver,
            accessibilityCheck: accessibility,
            functionKeyController: functionKeys,
            applicationNotificationCenter: applicationNotificationCenter,
            now: now
        )
        return AutoInputFixture(
            store: store,
            sources: sources,
            applications: applications,
            focusObserver: focusObserver,
            hud: hud,
            accessibility: accessibility,
            functionKeys: functionKeys,
            applicationNotificationCenter: applicationNotificationCenter,
            controller: controller,
            app: app
        )
    }
}

@MainActor
final class AutoInputPluginPanelTests: XCTestCase {

    func testCanonicalActionCanPauseAutoInput() async throws {
        let storage = AutoInputMemoryStorage()
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: FakeAutoInputSourceController(sources: [], currentSourceID: nil),
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil),
            functionKeyController: FakeAutoInputFunctionKeyController()
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.last?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertFalse(plugin.rowState.isOn)
    }

    func testCanonicalMutationIsDeferredAndRejectedPersistenceReturnsFailure() async throws {
        let storage = AutoInputMemoryStorage()
        storage.blockedSetKeys = ["isAutoSwitchEnabled"]
        let sources = FakeAutoInputSourceController(sources: [], currentSourceID: nil)
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: sources,
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil),
            functionKeyController: FakeAutoInputFunctionKeyController()
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.last?.reference)

        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        ))
        XCTAssertTrue(plugin.rowState.isOn)

        let result = await handle.result()

        guard case .failed = result else { return XCTFail("expected persistence failure") }
        XCTAssertTrue(plugin.rowState.isOn)
        XCTAssertNotNil(plugin.rowState.errorMessage)
        XCTAssertTrue(sources.selectedIDs.isEmpty)
        XCTAssertTrue(AutoInputStore(storage: storage).isAutoSwitchEnabled)
    }

    func testCanonicalInputSourceSelectionWorksWhenAutomaticSwitchingAndHUDAreOff() async throws {
        let storage = AutoInputMemoryStorage()
        AutoInputStore(storage: storage).setAutoSwitchEnabled(false)
        let sources = FakeAutoInputSourceController(
            sources: [
                AutoInputSource(id: "en", name: "ABC"),
                AutoInputSource(id: "zh", name: "中文"),
            ],
            currentSourceID: "en"
        )
        let applications = FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: sources,
            applicationMonitor: applications,
            functionKeyController: FakeAutoInputFunctionKeyController()
        )
        plugin.activate(context: PluginRuntimeContext(pluginID: "auto-input"))

        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first {
            $0.reference.parameters["inputSourceID"] == .string("zh")
        }?.reference)
        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(sources.selectedIDs, ["zh"])
        XCTAssertEqual(sources.startCount, 1)
        XCTAssertEqual(applications.startCount, 0)
        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["accessibility"])
        XCTAssertEqual(
            plugin.actionCatalogEntries.first { $0.reference == reference }?.presentationState,
            .active
        )
    }

    func testRemovedInputSourceMakesStoredActionUnavailableAndFailsClearly() async throws {
        let sources = FakeAutoInputSourceController(
            sources: [AutoInputSource(id: "en", name: "ABC")],
            currentSourceID: nil
        )
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(
                pluginID: "auto-input",
                storage: AutoInputMemoryStorage()
            ),
            sourceController: sources,
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil),
            functionKeyController: FakeAutoInputFunctionKeyController()
        )
        plugin.activate(context: PluginRuntimeContext(pluginID: "auto-input"))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first {
            $0.reference.key.actionID == "select-input-source"
        }?.reference)

        sources.sources = []
        sources.emitChange()

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()
        guard case let .failed(message) = result else {
            return XCTFail("expected unavailable input source failure")
        }
        XCTAssertEqual(message, "输入法已停用或不可用。")
        XCTAssertTrue(sources.selectedIDs.isEmpty)
    }

}

private func makeRule(
    bundleID: String,
    sourceID: String,
    keyboardMode: AutoInputKeyboardMode = .system
) -> AutoInputRule {
    AutoInputRule(
        bundleIdentifier: bundleID,
        displayName: bundleID,
        bundleURL: nil,
        inputSourceID: sourceID,
        keyboardMode: keyboardMode
    )
}

@MainActor
private struct AutoInputFixture {
    let store: AutoInputStore
    let sources: FakeAutoInputSourceController
    let applications: FakeAutoInputApplicationMonitor
    let focusObserver: FakeAutoInputFocusObserver
    let hud: FakeInputSourceHUDPresenter
    let accessibility: FakeAutoInputAccessibilityCheck
    let functionKeys: FakeAutoInputFunctionKeyController
    let applicationNotificationCenter: NotificationCenter
    let controller: AutoInputController
    let app: AutoInputApplication
}

@MainActor
private final class FakeAutoInputSourceController: AutoInputSourceControlling {
    var onSourcesChanged: (() -> Void)?
    var sources: [AutoInputSource]
    var currentSourceID: String?
    var selectedIDs: [String] = []
    var selectionAttemptIDs: [String] = []
    var startCount = 0
    var stopCount = 0
    var refreshCount = 0
    var selectionError: Error?

    init(sources: [AutoInputSource], currentSourceID: String?) {
        self.sources = sources
        self.currentSourceID = currentSourceID
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func refresh() { refreshCount += 1 }

    func selectSource(id: String) throws {
        selectionAttemptIDs.append(id)
        if let selectionError { throw selectionError }
        selectedIDs.append(id)
        currentSourceID = id
    }

    func emitChange() {
        onSourcesChanged?()
    }
}

@MainActor
private final class FakeAutoInputApplicationMonitor: AutoInputApplicationMonitoring {
    var onApplicationActivated: ((AutoInputApplication) -> Void)?
    var frontmostApplication: AutoInputApplication?
    var stopCount = 0
    var startCount = 0

    init(frontmostApplication: AutoInputApplication?) {
        self.frontmostApplication = frontmostApplication
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }

    func activate(_ application: AutoInputApplication) {
        frontmostApplication = application
        onApplicationActivated?(application)
    }
}

@MainActor
private final class FakeAutoInputFocusObserver: AutoInputFocusObserving {
    var onEditableFocusChanged: ((AutoInputEditableFocus?) -> Void)?
    var onAccessibilityInvalidated: (() -> Void)?
    var startCount = 0
    var stopCount = 0
    var refreshCount = 0
    private(set) var currentFocus: AutoInputEditableFocus?

    func start() { startCount += 1 }

    func stop() {
        stopCount += 1
        currentFocus = nil
        onEditableFocusChanged?(nil)
    }

    func refreshFocusedElement() {
        refreshCount += 1
        onEditableFocusChanged?(currentFocus)
    }

    func focus(_ focus: AutoInputEditableFocus?) {
        currentFocus = focus
        onEditableFocusChanged?(focus)
    }

    func setCurrentFocusWithoutNotification(_ focus: AutoInputEditableFocus?) {
        currentFocus = focus
    }

    func invalidateAccessibility() {
        onAccessibilityInvalidated?()
    }
}

@MainActor
private final class FakeInputSourceHUDPresenter: InputSourceHUDPresenting {
    struct Presentation: Equatable {
        let sourceName: String
        let modeIndicator: String?
        let frame: CGRect
        let avoidanceFrame: CGRect
        let configuration: AutoInputHUDConfiguration
    }

    var presentations: [Presentation] = []
    var activationHandlers: [(() -> Void)?] = []
    var dismissCount = 0

    func show(
        label: InputSourceHUDLabel,
        near focusedFrame: CGRect,
        avoiding editableFrame: CGRect,
        configuration: AutoInputHUDConfiguration,
        presentationID _: AutoInputHUDPresentationID,
        onActivate: (() -> Void)?
    ) {
        presentations.append(Presentation(
            sourceName: label.title,
            modeIndicator: label.modeIndicator,
            frame: focusedFrame,
            avoidanceFrame: editableFrame,
            configuration: configuration
        ))
        activationHandlers.append(onActivate)
    }

    func activateLastPresentation() {
        activationHandlers.last.flatMap { $0 }?()
    }

    func dismiss() {
        dismissCount += 1
    }
}

@MainActor
private final class FakeAutoInputAccessibilityCheck: AutoInputAccessibilityChecking {
    var isTrusted: Bool
    var requestResult: Bool
    var requestCount = 0

    init(isTrusted: Bool) {
        self.isTrusted = isTrusted
        self.requestResult = isTrusted
    }

    func requestTrust(prompt: Bool) -> Bool {
        if prompt { requestCount += 1 }
        isTrusted = requestResult
        return isTrusted
    }
}

@MainActor
private final class FakeAutoInputFunctionKeyController: AutoInputFunctionKeyControlling {
    var isStandardFunctionKeysEnabled: Bool
    var writes: [Bool] = []
    var writeResult = true

    init(isStandardFunctionKeysEnabled: Bool = false) {
        self.isStandardFunctionKeysEnabled = isStandardFunctionKeysEnabled
    }

    @discardableResult
    func setStandardFunctionKeysEnabled(_ isEnabled: Bool) -> Bool {
        writes.append(isEnabled)
        guard writeResult else { return false }
        isStandardFunctionKeysEnabled = isEnabled
        return true
    }
}

@MainActor
private final class AutoInputMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]
    var blockedSetKeys: Set<String> = []

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        guard !blockedSetKeys.contains(key) else { return }
        values[key] = value
    }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }

    func setRawValue(_ value: Any, forKey key: String) {
        values[key] = value
    }

    func rawValue(forKey key: String) -> Any? {
        values[key]
    }
}
