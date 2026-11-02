import AppKit
import XCTest
import IOKit.pwr_mgt
import SwiftUI
import MacToolsPluginKit
@testable import KeepAwakePlugin

final class KeepAwakeStopScheduleFormattingTests: XCTestCase {
    private let localization = PluginLocalization(bundle: .main)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var locale: Locale { Locale(identifier: "en_US_POSIX") }
    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }
}

@MainActor
final class KeepAwakeSessionTests: XCTestCase {
    func testDisplayAssertionFailureDoesNotPreventSessionStart() throws {
        var createdKinds: [KeepAwakeSession.AssertionKind] = []
        var releasedAssertionIDs: [IOPMAssertionID] = []
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                createdKinds.append(kind)
                switch kind {
                case .system:
                    return (kIOReturnSuccess, 1)
                case .display:
                    return (kIOReturnError, 0)
                case .lidClose:
                    return (kIOReturnSuccess, 2)
                }
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                return kIOReturnSuccess
            }
        )

        try session.start(
            until: nil,
            preventDisplaySleep: true,
            preventLidCloseSleep: false
        )
        XCTAssertFalse(session.isPreventingDisplaySleep)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(createdKinds, [.system, .display])
        XCTAssertEqual(releasedAssertionIDs, [1])
    }

    func testDisplayAssertionCanBeUpdatedWithoutRestartingSystemAssertion() throws {
        var createdKinds: [KeepAwakeSession.AssertionKind] = []
        var releasedAssertionIDs: [IOPMAssertionID] = []
        var nextAssertionID = IOPMAssertionID(1)
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                createdKinds.append(kind)
                defer { nextAssertionID += 1 }
                return (kIOReturnSuccess, nextAssertionID)
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                return kIOReturnSuccess
            }
        )

        try session.start(
            until: nil,
            preventDisplaySleep: false,
            preventLidCloseSleep: false
        )
        try session.setPreventDisplaySleep(true)
        XCTAssertTrue(session.isPreventingDisplaySleep)
        try session.setPreventDisplaySleep(false)
        XCTAssertFalse(session.isPreventingDisplaySleep)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(createdKinds, [.system, .display])
        XCTAssertEqual(releasedAssertionIDs, [2, 1])
    }

    func testFailedDisplayAssertionCreationCanBeRetried() throws {
        var displayCreationAttempts = 0
        var releasedAssertionIDs: [IOPMAssertionID] = []
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                switch kind {
                case .system:
                    return (kIOReturnSuccess, 1)
                case .display:
                    displayCreationAttempts += 1
                    return displayCreationAttempts == 1
                        ? (kIOReturnError, 0)
                        : (kIOReturnSuccess, 2)
                case .lidClose:
                    return (kIOReturnSuccess, 3)
                }
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                return kIOReturnSuccess
            }
        )

        try session.start(
            until: nil,
            preventDisplaySleep: false,
            preventLidCloseSleep: false
        )
        XCTAssertThrowsError(try session.setPreventDisplaySleep(true))
        try session.setPreventDisplaySleep(true)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(displayCreationAttempts, 2)
        XCTAssertEqual(releasedAssertionIDs, [2, 1])
    }

    func testFailedDisplayAssertionReleaseRetainsAssertionForRetry() throws {
        var shouldFailDisplayRelease = true
        var releasedAssertionIDs: [IOPMAssertionID] = []
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                switch kind {
                case .system:
                    return (kIOReturnSuccess, 1)
                case .display:
                    return (kIOReturnSuccess, 2)
                case .lidClose:
                    return (kIOReturnSuccess, 3)
                }
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                if assertionID == 2, shouldFailDisplayRelease {
                    return kIOReturnError
                }
                return kIOReturnSuccess
            }
        )

        try session.start(
            until: nil,
            preventDisplaySleep: true,
            preventLidCloseSleep: false
        )
        XCTAssertThrowsError(try session.setPreventDisplaySleep(false))
        shouldFailDisplayRelease = false
        try session.setPreventDisplaySleep(false)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(releasedAssertionIDs, [2, 2, 1])
    }

    func testClosedLidAssertionCanBeEnabledAndReleasedDuringSession() throws {
        var createdKinds: [KeepAwakeSession.AssertionKind] = []
        var releasedAssertionIDs: [IOPMAssertionID] = []
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                createdKinds.append(kind)
                switch kind {
                case .system:
                    return (kIOReturnSuccess, 1)
                case .lidClose:
                    return (kIOReturnSuccess, 2)
                case .display:
                    return (kIOReturnSuccess, 3)
                }
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                return kIOReturnSuccess
            }
        )

        try session.start(
            until: nil,
            preventDisplaySleep: false,
            preventLidCloseSleep: false
        )
        try session.setPreventLidCloseSleep(true)
        try session.setPreventLidCloseSleep(false)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(createdKinds, [.system, .lidClose])
        XCTAssertEqual(releasedAssertionIDs, [2, 1])
    }

    func testFailedClosedLidAssertionReleaseCanBeRetried() throws {
        var shouldFailLidCloseRelease = true
        var releasedAssertionIDs: [IOPMAssertionID] = []
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                switch kind {
                case .system:
                    return (kIOReturnSuccess, 1)
                case .lidClose:
                    return (kIOReturnSuccess, 2)
                case .display:
                    return (kIOReturnSuccess, 3)
                }
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                if assertionID == 2, shouldFailLidCloseRelease {
                    return kIOReturnError
                }
                return kIOReturnSuccess
            }
        )

        try session.start(
            until: nil,
            preventDisplaySleep: false,
            preventLidCloseSleep: true
        )
        XCTAssertThrowsError(try session.setPreventLidCloseSleep(false))
        shouldFailLidCloseRelease = false
        try session.setPreventLidCloseSleep(false)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(releasedAssertionIDs, [2, 2, 1])
    }
}

@MainActor
final class KeepAwakeSessionFactory {
    private(set) var sessions: [MockKeepAwakeSession] = []
    let powerSourceMonitor: MockKeepAwakePowerSourceMonitor
    let virtualDisplayManager = MockKeepAwakeVirtualDisplayManager()
    let userActivityMaintainer = MockKeepAwakeUserActivityMaintainer()
    let displayProvider: MockKeepAwakeDisplayProvider
    var configureSession: ((MockKeepAwakeSession) -> Void)?

    init(
        powerSourceState: KeepAwakePowerSourceState = KeepAwakePowerSourceState(
            isPortableMac: true,
            isOnExternalPower: true,
            isLidClosed: true
        ),
        displays: [DisplayInfo] = []
    ) {
        powerSourceMonitor = MockKeepAwakePowerSourceMonitor(currentState: powerSourceState)
        displayProvider = MockKeepAwakeDisplayProvider(displays: displays)
    }

    func makePlugin(storage: KeepAwakeMemoryStorage) -> KeepAwakePlugin {
        KeepAwakePlugin(
            context: PluginRuntimeContext(pluginID: "keep-awake", storage: storage),
            powerSourceMonitor: powerSourceMonitor,
            virtualDisplayManager: virtualDisplayManager,
            userActivityMaintainer: userActivityMaintainer,
            displayProvider: displayProvider,
            sessionFactory: { [weak self] _, onEnd in
                let session = MockKeepAwakeSession(onEnd: onEnd)
                self?.configureSession?(session)
                self?.sessions.append(session)
                return session
            }
        )
    }
}

@MainActor
final class MockKeepAwakeVirtualDisplayManager: KeepAwakeVirtualDisplayManaging {
    var isAvailable = true
    private(set) var isActive = false
    var onUnexpectedTermination: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?

    func start() async throws {
        startCount += 1
        if let startError {
            throw startError
        }
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        stopCount += 1
        isActive = false
    }

    func simulateUnexpectedTermination() {
        isActive = false
        onUnexpectedTermination?()
    }
}

@MainActor
final class MockKeepAwakeUserActivityMaintainer: KeepAwakeUserActivityMaintaining {
    private(set) var isActive = false
    var onFailure: ((Error) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?
    var stopError: Error?

    func start() throws {
        guard !isActive else { return }
        startCount += 1
        if let startError {
            throw startError
        }
        isActive = true
    }

    func stop() throws {
        guard isActive else { return }
        stopCount += 1
        if let stopError {
            throw stopError
        }
        isActive = false
    }

    func simulateFailure(_ error: Error) {
        isActive = false
        onFailure?(error)
    }
}

final class MockKeepAwakeDisplayProvider: DisplayProviding {
    var displays: [DisplayInfo]

    init(displays: [DisplayInfo]) {
        self.displays = displays
    }

    func listConnectedDisplays() -> [DisplayInfo] {
        displays
    }

    func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        nil
    }
}

@MainActor
final class MockKeepAwakeSession: KeepAwakeSessionManaging {
    struct Configuration: Equatable {
        let endDate: Date?
        let preventDisplaySleep: Bool
        let preventLidCloseSleep: Bool
    }

    private let onEnd: (KeepAwakeSession.EndReason) -> Void
    private(set) var startedConfigurations: [Configuration] = []
    private(set) var displaySleepPreventionUpdates: [Bool] = []
    private(set) var lidCloseSleepPreventionUpdates: [Bool] = []
    private(set) var stopRequestCount = 0
    private(set) var isPreventingDisplaySleep = false
    var appliesDisplaySleepPreventionDuringStart = true
    var startError: Error?
    var displayUpdateError: Error?
    var lidCloseUpdateError: Error?

    init(onEnd: @escaping (KeepAwakeSession.EndReason) -> Void) {
        self.onEnd = onEnd
    }

    func start(
        until endDate: Date?,
        preventDisplaySleep: Bool,
        preventLidCloseSleep: Bool
    ) throws {
        startedConfigurations.append(
            Configuration(
                endDate: endDate,
                preventDisplaySleep: preventDisplaySleep,
                preventLidCloseSleep: preventLidCloseSleep
            )
        )
        if let startError {
            throw startError
        }
        if appliesDisplaySleepPreventionDuringStart {
            isPreventingDisplaySleep = preventDisplaySleep
        }
    }

    func setPreventDisplaySleep(_ preventDisplaySleep: Bool) throws {
        displaySleepPreventionUpdates.append(preventDisplaySleep)
        if let displayUpdateError {
            throw displayUpdateError
        }
        isPreventingDisplaySleep = preventDisplaySleep
    }

    func setPreventLidCloseSleep(_ preventLidCloseSleep: Bool) throws {
        lidCloseSleepPreventionUpdates.append(preventLidCloseSleep)
        if preventLidCloseSleep, let lidCloseUpdateError {
            throw lidCloseUpdateError
        }
    }

    func requestStop(reason: KeepAwakeSession.EndReason) {
        stopRequestCount += 1
        isPreventingDisplaySleep = false
        onEnd(reason)
    }
}

@MainActor
final class MockKeepAwakePowerSourceMonitor: KeepAwakePowerSourceMonitoring {
    private(set) var currentState: KeepAwakePowerSourceState
    var onChange: ((KeepAwakePowerSourceState) -> Void)?

    init(currentState: KeepAwakePowerSourceState) {
        self.currentState = currentState
    }

    func start() {}
    func stop() {}

    func send(_ state: KeepAwakePowerSourceState) {
        currentState = state
        onChange?(state)
    }
}

enum MockKeepAwakeSessionError: LocalizedError {
    case startFailed
    case displayUpdateFailed
    case lidCloseUpdateFailed

    var errorDescription: String? {
        switch self {
        case .startFailed:
            return "无法启动阻止休眠。"
        case .displayUpdateFailed:
            return "无法更新屏幕状态。"
        case .lidCloseUpdateFailed:
            return "无法更新合盖状态。"
        }
    }
}

enum MockVirtualDisplayError: LocalizedError {
    case creationFailed

    var errorDescription: String? {
        "无法创建软件显示器。"
    }
}

@MainActor
final class KeepAwakeMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }

    func set(_ value: Any?, forKey key: String) {
        guard let value else {
            values.removeValue(forKey: key)
            return
        }

        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }

        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}


@MainActor
final class KeepAwakeVoiceTests: XCTestCase {
    func testVoiceReportsSessionLifecycleWithoutStartingAnotherSession() async throws {
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: KeepAwakeMemoryStorage())
        func state() async throws -> [String: Any] {
            let text = try await plugin.readVoiceQuery(id: "keep-awake-state")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let idle = try await state()
        XCTAssertEqual(idle["enabled"] as? Bool, false)
        XCTAssertTrue(factory.sessions.isEmpty)
        plugin.handleAction(.setSwitch(true))
        let running = try await state()
        XCTAssertEqual(running["enabled"] as? Bool, true)
        XCTAssertEqual(factory.sessions.count, 1)
        plugin.handleAction(.setSwitch(false))
        let stopped = try await state()
        XCTAssertEqual(stopped["enabled"] as? Bool, false)
    }
}
