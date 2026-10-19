import AppKit
import ApplicationServices
import XCTest
@testable import AutoInputPlugin

@MainActor
final class AutoInputFocusObserverTests: XCTestCase {
    func testUnresponsiveRegistrationDoesNotBlockMainActorAndStopDiscardsItsResult() async {
        let entered = expectation(description: "Registration started")
        let completed = expectation(description: "Registration returned")
        let backend = BlockingAutoInputRegistration(entered: entered, completed: completed)
        let runLoop = AutoInputAccessibilityRunLoop()
        let observer = makeObserver(backend: backend, runLoop: runLoop)
        var invalidations = 0
        observer.onAccessibilityInvalidated = { invalidations += 1 }
        observer.start()
        await fulfillment(of: [entered], timeout: 5)
        defer { backend.release.signal(); observer.stop(); runLoop.shutdown() }

        // Reaching this main-actor continuation while AX registration is blocked
        // is the behavior under test; there is no wall-clock performance target.
        XCTAssertFalse(backend.ranOnMainThread)
        observer.stop()
        backend.release.signal()
        await fulfillment(of: [completed], timeout: 5)
        await drain(runLoop)
        XCTAssertEqual(invalidations, 0)
    }

    func testRestartRejectsRetiredRegistrationAndDeliversCurrentPermissionFailure() async {
        let entered = expectation(description: "First registration started")
        let completed = expectation(description: "Both registrations returned")
        completed.expectedFulfillmentCount = 2
        let currentFailure = expectation(description: "Current permission failure delivered")
        let backend = BlockingAutoInputRegistration(entered: entered, completed: completed)
        let runLoop = AutoInputAccessibilityRunLoop()
        let observer = makeObserver(backend: backend, runLoop: runLoop)
        var invalidations = 0
        observer.onAccessibilityInvalidated = {
            XCTAssertTrue(Thread.isMainThread)
            invalidations += 1
            currentFailure.fulfill()
        }
        observer.start()
        await fulfillment(of: [entered], timeout: 5)
        defer { backend.release.signal(); observer.stop(); runLoop.shutdown() }
        observer.stop()
        observer.start()
        backend.release.signal()
        await fulfillment(of: [completed, currentFailure], timeout: 5)
        await drain(runLoop)
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(backend.registrationCount, 2)
    }

    func testLocalFocusResolutionRemainsOnMainActorWhileRegistrationWaits() async {
        let entered = expectation(description: "Registration entered")
        let completed = expectation(description: "Registration returned")
        let resolved = expectation(description: "Focused app resolved")
        resolved.assertForOverFulfill = false
        let backend = BlockingAutoInputRegistration(entered: entered, completed: completed)
        let runLoop = AutoInputAccessibilityRunLoop()
        let observer = AccessibilityAutoInputFocusObserver(workspace: AutoInputTestApplications(),
            notificationCenter: NotificationCenter(), focusedApplicationProcessIdentifier: {
                XCTAssertTrue(Thread.isMainThread, "Local AX lookups can invoke AppKit field editors inline")
                resolved.fulfill()
                return nil
            }, registrationBackend: backend, runLoop: runLoop)
        observer.start()
        await fulfillment(of: [entered], timeout: 5)
        observer.refreshFocusedElement()
        await fulfillment(of: [resolved], timeout: 5)
        observer.stop()
        backend.release.signal()
        await fulfillment(of: [completed], timeout: 5)
        await drain(runLoop)
        runLoop.shutdown()
    }

    func testLatestQueuedActivationSurvivesTerminationWhileWorkerIsBlocked() async {
        let previous = AutoInputTestApplication(processIdentifier: 101)
        let next = AutoInputTestApplication(processIdentifier: 202)
        let latest = AutoInputTestApplication(processIdentifier: 303)
        for activations in [[next], [next, latest]] {
            let entered = expectation(description: "Previous app registration entered")
            let completed = expectation(description: "Previous app registration returned")
            completed.assertForOverFulfill = false
            let backend = BlockingAutoInputRegistration(entered: entered, completed: completed, status: .notImplemented)
            let runLoop = AutoInputAccessibilityRunLoop()
            let notifications = NotificationCenter()
            let current = activations.last!
            let observer = AccessibilityAutoInputFocusObserver(
                workspace: AutoInputTestApplications(frontmostApplication: previous),
                notificationCenter: notifications,
                focusedApplicationProcessIdentifier: { current.processIdentifier },
                registrationBackend: backend, runLoop: runLoop)
            observer.start()
            await fulfillment(of: [entered], timeout: 5)
            defer { backend.release.signal(); observer.stop(); runLoop.shutdown() }

            for application in activations {
                notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: application])
            }
            notifications.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: previous])
            backend.release.signal()
            await fulfillment(of: [completed], timeout: 5)
            await drain(runLoop)

            XCTAssertEqual(backend.registeredProcessIdentifiers,
                [previous.processIdentifier, current.processIdentifier],
                "Termination must preserve observation of the latest app and skip obsolete activations")
        }
    }

    func testForegroundWorkOvertakesQueuedAccessoryWork() async {
        let entered = expectation(description: "Current AX request entered")
        let release = DispatchSemaphore(value: 0)
        let order = AutoInputWorkOrder()
        let runLoop = AutoInputAccessibilityRunLoop()
        defer { release.signal(); runLoop.shutdown() }
        runLoop.perform {
            entered.fulfill()
            release.wait()
        }
        await fulfillment(of: [entered], timeout: 5)
        runLoop.perform { order.append("accessory") }
        runLoop.perform(priority: .foreground) { order.append("foreground") }
        release.signal()
        await drain(runLoop)
        XCTAssertEqual(order.values, ["foreground", "accessory"])
    }

    private func makeObserver(backend: BlockingAutoInputRegistration,
                              runLoop: AutoInputAccessibilityRunLoop) -> AccessibilityAutoInputFocusObserver {
        AccessibilityAutoInputFocusObserver(workspace: AutoInputTestApplications(),
            notificationCenter: NotificationCenter(), focusedApplicationProcessIdentifier: { nil },
            registrationBackend: backend, runLoop: runLoop)
    }

    private func drain(_ runLoop: AutoInputAccessibilityRunLoop) async {
        await withCheckedContinuation { continuation in
            runLoop.perform {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

@MainActor
private struct AutoInputTestApplications: AutoInputApplicationProviding {
    var frontmostApplication: NSRunningApplication? = .current
    var runningApplications: [NSRunningApplication] { [] }
}

private final class AutoInputTestApplication: NSRunningApplication, @unchecked Sendable {
    private let identifier: pid_t

    init(processIdentifier: pid_t) {
        identifier = processIdentifier
        super.init()
    }

    override var processIdentifier: pid_t { identifier }
    override var bundleIdentifier: String? { "test.auto-input.\(identifier)" }
    override var activationPolicy: NSApplication.ActivationPolicy { .regular }
}

private final class BlockingAutoInputRegistration: AutoInputAccessibilityRegistering, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let isTrusted = true
    private let entered: XCTestExpectation
    private let completed: XCTestExpectation
    private let lock = NSLock()
    private let status: AXError
    private var registeredPIDs: [pid_t] = []
    private var usedMainThread = false
    var registrationCount: Int { lock.withLock { registeredPIDs.count } }
    var registeredProcessIdentifiers: [pid_t] { lock.withLock { registeredPIDs } }
    var ranOnMainThread: Bool { lock.withLock { usedMainThread } }

    init(entered: XCTestExpectation, completed: XCTestExpectation, status: AXError = .apiDisabled) {
        self.entered = entered
        self.completed = completed
        self.status = status
    }

    func register(processIdentifier: pid_t, callback: AXObserverCallback,
                  context: UnsafeMutableRawPointer) -> AutoInputAccessibilityRegistrationResult {
        let first = lock.withLock {
            registeredPIDs.append(processIdentifier)
            usedMainThread = usedMainThread || Thread.isMainThread
            return registeredPIDs.count == 1
        }
        if first {
            entered.fulfill()
            // A broken synchronous implementation fails the thread assertion
            // without deadlocking the entire test runner.
            if !Thread.isMainThread { release.wait() }
        }
        completed.fulfill()
        return .init(status: status)
    }
}

private final class AutoInputWorkOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    var values: [String] { lock.withLock { storedValues } }
    func append(_ value: String) { lock.withLock { storedValues.append(value) } }
}
