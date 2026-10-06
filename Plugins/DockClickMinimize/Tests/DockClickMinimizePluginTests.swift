import CoreGraphics
import Foundation
import MacToolsPluginKit
import XCTest
@testable import DockClickMinimizePlugin

@MainActor
final class DockClickMinimizePluginTests: XCTestCase {
    func testFirstLaunchIsEnabledAndStartsMonitoring() {
        let monitor = MockDockClickMonitor()
        let context = makeContext()
        let plugin = makePlugin(context: context, monitor: monitor)

        plugin.activate(context: context)

        XCTAssertTrue(plugin.rowState.isOn)
        XCTAssertEqual(monitor.startCallCount, 1)
    }

    func testDisablingStopsMonitoring() {
        let monitor = MockDockClickMonitor()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(context: context, monitor: monitor)
        plugin.activate(context: context)

        plugin.handleAction(.setSwitch(false))

        XCTAssertEqual(monitor.stopCallCount, 1)
        XCTAssertFalse(plugin.rowState.isOn)
    }

    func testDeactivationAlwaysStopsMonitoring() {
        let monitor = MockDockClickMonitor()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(context: context, monitor: monitor)
        plugin.activate(context: context)

        plugin.deactivate(reason: .updating)

        XCTAssertEqual(monitor.stopCallCount, 1)
    }

    func testMissingPermissionPreventsMonitoring() {
        let monitor = MockDockClickMonitor()
        let permissions = PermissionState(accessibilityGranted: false, inputMonitoringStatus: .denied)
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(context: context, monitor: monitor, permissions: permissions)

        plugin.activate(context: context)

        XCTAssertEqual(monitor.startCallCount, 0)
        XCTAssertNotNil(plugin.rowState.errorMessage)
        XCTAssertFalse(plugin.permissionState(for: "accessibility").isGranted)
        XCTAssertFalse(plugin.permissionState(for: "input-monitoring").isGranted)
    }

    func testRetainedPermissionErrorSwitchesLanguageWithoutRestartingMonitor() throws {
        let original = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(original) }
        let resource = try makeLocalizationBundle()
        defer { try? FileManager.default.removeItem(at: resource.directory) }
        PluginRuntimeLocalization.source.setPreference("en")
        let monitor = MockDockClickMonitor()
        let permissions = PermissionState(accessibilityGranted: false, inputMonitoringStatus: .denied)
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(
            context: context,
            monitor: monitor,
            permissions: permissions,
            localization: PluginLocalization(bundle: resource.bundle)
        )
        var permissionRequests = 0
        plugin.requestPermissionGuidance = { _ in permissionRequests += 1 }
        plugin.activate(context: context)
        defer { plugin.deactivate(reason: .hostShutdown) }
        XCTAssertEqual(plugin.rowState.errorMessage, "English permission error")
        let stops = monitor.stopCallCount

        PluginRuntimeLocalization.source.setPreference("ar")
        XCTAssertEqual(plugin.rowState.errorMessage, "خطأ الأذونات")
        XCTAssertEqual(monitor.startCallCount, 0)
        XCTAssertEqual(monitor.stopCallCount, stops)
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertTrue(plugin.rowState.isOn)
    }

    func testExplicitEnableRequestsMissingPermissionGuidance() {
        let permissions = PermissionState(
            accessibilityGranted: false,
            inputMonitoringStatus: .denied
        )
        let context = makeContext(isEnabled: false)
        let plugin = makePlugin(context: context, permissions: permissions)
        var requestedPermissionIDs: [String] = []
        plugin.requestPermissionGuidance = { requestedPermissionIDs.append($0) }

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(requestedPermissionIDs, ["accessibility"])
        XCTAssertNotNil(plugin.rowState.errorMessage)
    }

    func testMonitorStartupFailureIsExposed() {
        let monitor = MockDockClickMonitor(startResult: false)
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(context: context, monitor: monitor)

        plugin.activate(context: context)

        XCTAssertEqual(monitor.startCallCount, 1)
        XCTAssertNotNil(plugin.rowState.errorMessage)
    }

    func testResolverAcceptsOnlyApplicationDockItemWithBundleURL() {
        let target = DockClickResolver.applicationTarget(
            from: DockItemSnapshot(
                processIdentifier: 42,
                role: DockClickResolver.dockItemRole,
                subrole: DockClickResolver.applicationDockItemSubrole,
                url: URL(fileURLWithPath: "/Applications/Safari.app")
            ),
            dockProcessIdentifier: 42,
            bundleIdentifierForURL: { _ in "com.apple.Safari" }
        )

        XCTAssertEqual(target, DockApplicationTarget(bundleIdentifier: "com.apple.Safari"))
    }

    func testResolverRejectsTrashFoldersFilesAndUnknownDockItems() {
        let snapshots = [
            DockItemSnapshot(processIdentifier: 42, role: DockClickResolver.dockItemRole, subrole: "AXTrashDockItem", url: nil),
            DockItemSnapshot(processIdentifier: 42, role: DockClickResolver.dockItemRole, subrole: "AXFolderDockItem", url: URL(fileURLWithPath: "/Users/me/Downloads")),
            DockItemSnapshot(processIdentifier: 42, role: DockClickResolver.dockItemRole, subrole: "AXApplicationDockItem", url: URL(fileURLWithPath: "/tmp/file.pdf")),
            DockItemSnapshot(processIdentifier: 7, role: DockClickResolver.dockItemRole, subrole: DockClickResolver.applicationDockItemSubrole, url: URL(fileURLWithPath: "/Applications/Safari.app")),
        ]

        for snapshot in snapshots {
            XCTAssertNil(
                DockClickResolver.applicationTarget(
                    from: snapshot,
                    dockProcessIdentifier: 42,
                    bundleIdentifierForURL: { _ in nil }
                )
            )
        }
    }

    func testGesturePolicyRejectsDraggingAndLongPresses() {
        XCTAssertTrue(
            DockClickGesturePolicy.isCompletedClick(
                downLocation: .zero,
                upLocation: CGPoint(x: DockClickGesturePolicy.maximumDistance, y: 0),
                duration: DockClickGesturePolicy.maximumDuration
            )
        )
        XCTAssertFalse(
            DockClickGesturePolicy.isCompletedClick(
                downLocation: .zero,
                upLocation: CGPoint(x: DockClickGesturePolicy.maximumDistance + 1, y: 0),
                duration: 0
            )
        )
        XCTAssertFalse(
            DockClickGesturePolicy.isCompletedClick(
                downLocation: .zero,
                upLocation: .zero,
                duration: DockClickGesturePolicy.maximumDuration + 0.01
            )
        )
    }

    func testActiveApplicationClickHidesExactlyOnceAfterDelay() async {
        let monitor = MockDockClickMonitor()
        let applicationHider = MockDockApplicationHider(hasVisibleWindow: true)
        let frontmost = MutableFrontmostApplicationProvider(application: safariApplication)
        let scheduler = ManualScheduler()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(
            context: context,
            monitor: monitor,
            applicationHider: applicationHider,
            frontmostApplicationProvider: frontmost,
            scheduler: scheduler
        )
        plugin.activate(context: context)

        monitor.emit(target: safariTarget, frontmostApplication: safariApplication)
        await waitUntil { !scheduler.actions.isEmpty }
        scheduler.runNext()

        XCTAssertEqual(applicationHider.hiddenProcessIdentifiers, [safariApplication.processIdentifier])
    }

    func testFrontmostApplicationChangeBeforeDelayDoesNotHide() async {
        let monitor = MockDockClickMonitor()
        let applicationHider = MockDockApplicationHider(hasVisibleWindow: true)
        let frontmost = MutableFrontmostApplicationProvider(application: safariApplication)
        let scheduler = ManualScheduler()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(
            context: context,
            monitor: monitor,
            applicationHider: applicationHider,
            frontmostApplicationProvider: frontmost,
            scheduler: scheduler
        )
        plugin.activate(context: context)

        monitor.emit(target: safariTarget, frontmostApplication: safariApplication)
        await waitUntil { !scheduler.actions.isEmpty }
        frontmost.application = DockFrontmostApplication(bundleIdentifier: "com.apple.Terminal", processIdentifier: 99)
        scheduler.runNext()

        XCTAssertTrue(applicationHider.hiddenProcessIdentifiers.isEmpty)
    }

    func testDisablingBeforeDelayDoesNotHide() async {
        let monitor = MockDockClickMonitor()
        let applicationHider = MockDockApplicationHider(hasVisibleWindow: true)
        let scheduler = ManualScheduler()
        let context = makeContext(isEnabled: true)
        let plugin = makePlugin(context: context, monitor: monitor, applicationHider: applicationHider, scheduler: scheduler)
        plugin.activate(context: context)

        monitor.emit(target: safariTarget, frontmostApplication: safariApplication)
        await waitUntil { !scheduler.actions.isEmpty }
        plugin.handleAction(.setSwitch(false))
        scheduler.runNext()

        XCTAssertTrue(applicationHider.hiddenProcessIdentifiers.isEmpty)
    }

    private var safariTarget: DockApplicationTarget {
        DockApplicationTarget(bundleIdentifier: "com.apple.Safari")
    }

    private func makeLocalizationBundle() throws -> (bundle: Bundle, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("LocalizationTests.bundle", isDirectory: true)
        for (language, values) in [
            "en": ["error.accessibilityRequired": "English permission error"],
            "ar": ["error.accessibilityRequired": "خطأ الأذونات"],
        ] {
            let languageURL = bundleURL.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: languageURL, withIntermediateDirectories: true)
            try values.map { "\"\($0.key)\" = \"\($0.value)\";" }
                .joined(separator: "\n")
                .write(
                    to: languageURL.appendingPathComponent("Localizable.strings"),
                    atomically: true,
                    encoding: .utf8
                )
        }
        return (try XCTUnwrap(Bundle(url: bundleURL)), directory)
    }

    private var safariApplication: DockFrontmostApplication {
        DockFrontmostApplication(bundleIdentifier: "com.apple.Safari", processIdentifier: 123)
    }

    private func makePlugin(
        context: PluginRuntimeContext? = nil,
        monitor: MockDockClickMonitor? = nil,
        applicationHider: MockDockApplicationHider? = nil,
        frontmostApplicationProvider: MutableFrontmostApplicationProvider? = nil,
        permissions: PermissionState? = nil,
        scheduler: ManualScheduler? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> DockClickMinimizePlugin {
        let monitor = monitor ?? MockDockClickMonitor()
        let applicationHider = applicationHider ?? MockDockApplicationHider(hasVisibleWindow: true)
        let frontmostApplicationProvider = frontmostApplicationProvider ?? MutableFrontmostApplicationProvider(
            application: DockFrontmostApplication(
                bundleIdentifier: "com.apple.Safari",
                processIdentifier: 123
            )
        )
        let permissions = permissions ?? PermissionState()
        let scheduler = scheduler ?? ManualScheduler()

        return DockClickMinimizePlugin(
            context: context ?? makeContext(),
            monitor: monitor,
            applicationHider: applicationHider,
            frontmostApplicationProvider: frontmostApplicationProvider,
            localization: localization,
            accessibilityTrusted: { permissions.accessibilityGranted },
            requestAccessibilityTrust: { _ in permissions.accessibilityGranted },
            inputMonitoringStatus: { permissions.inputMonitoringStatus },
            scheduleDelayedAction: { scheduler.schedule($0) }
        )
    }

    private func makeContext(isEnabled: Bool? = nil) -> PluginRuntimeContext {
        let storage = DockClickMinimizeMemoryStorage()
        if let isEnabled {
            storage.set(isEnabled, forKey: "dock-click-minimize.enabled")
        }
        return PluginRuntimeContext(pluginID: "dock-click-minimize", storage: storage)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        attempts: Int = 100
    ) async {
        for _ in 0 ..< attempts {
            if predicate() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous Dock Click state")
    }
}

@MainActor
private final class MockDockClickMonitor: @preconcurrency DockClickMonitoring {
    var onApplicationClick: ((DockApplicationTarget, DockFrontmostApplication) -> Void)?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private let startResult: Bool

    init(startResult: Bool = true) {
        self.startResult = startResult
    }

    func start() -> Bool {
        startCallCount += 1
        return startResult
    }

    func stop() {
        stopCallCount += 1
    }

    func emit(target: DockApplicationTarget, frontmostApplication: DockFrontmostApplication) {
        onApplicationClick?(target, frontmostApplication)
    }
}

@MainActor
private final class MockDockApplicationHider: @preconcurrency DockApplicationHiding {
    var hasVisibleWindowResult: Bool
    private(set) var hasVisibleWindowCallCount = 0
    private(set) var hiddenProcessIdentifiers: [pid_t] = []
    private let suspendsVisibilityCheck: Bool
    private var visibilityContinuation: CheckedContinuation<Bool, Never>?

    init(hasVisibleWindow: Bool, suspendsVisibilityCheck: Bool = false) {
        self.hasVisibleWindowResult = hasVisibleWindow
        self.suspendsVisibilityCheck = suspendsVisibilityCheck
    }

    func hasVisibleWindow(for processIdentifier: pid_t) async -> Bool {
        hasVisibleWindowCallCount += 1
        guard suspendsVisibilityCheck else {
            return hasVisibleWindowResult
        }
        return await withCheckedContinuation { continuation in
            visibilityContinuation = continuation
        }
    }

    func resumeVisibilityCheck() {
        visibilityContinuation?.resume(returning: hasVisibleWindowResult)
        visibilityContinuation = nil
    }

    func hideApplication(bundleIdentifier: String, processIdentifier: pid_t) -> Bool {
        guard hasVisibleWindowResult else { return false }
        hiddenProcessIdentifiers.append(processIdentifier)
        return true
    }
}

@MainActor
private final class MutableFrontmostApplicationProvider: @preconcurrency DockFrontmostApplicationProviding {
    var application: DockFrontmostApplication?
    private(set) var frontmostApplicationCallCount = 0

    init(application: DockFrontmostApplication?) {
        self.application = application
    }

    func frontmostApplication() -> DockFrontmostApplication? {
        frontmostApplicationCallCount += 1
        return application
    }
}

@MainActor
private final class ManualScheduler {
    var actions: [@MainActor () -> Void] = []

    func schedule(_ action: @escaping @MainActor () -> Void) {
        actions.append(action)
    }

    func runNext() {
        actions.removeFirst()()
    }
}

@MainActor
private final class PermissionState {
    var accessibilityGranted: Bool
    var inputMonitoringStatus: DockClickMinimizeInputMonitoringStatus

    init(
        accessibilityGranted: Bool = true,
        inputMonitoringStatus: DockClickMinimizeInputMonitoringStatus = .granted
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringStatus = inputMonitoringStatus
    }
}

@MainActor
private final class DockClickMinimizeMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}
