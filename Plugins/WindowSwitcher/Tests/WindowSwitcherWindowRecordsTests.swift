import AppKit
import XCTest
@testable import WindowSwitcherPlugin

private final class WindowRecordResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [WindowSwitcherWindowRecord]?
    init(_ value: [WindowSwitcherWindowRecord]?) { self.value = value }
    func set(_ value: [WindowSwitcherWindowRecord]?) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func get() -> [WindowSwitcherWindowRecord]? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class BlockingWindowRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var completions = 0
    private var blocked = true
    let release = DispatchSemaphore(value: 0)

    var counts: (started: Int, completed: Int) {
        lock.lock(); defer { lock.unlock() }
        return (calls, completions)
    }

    func unblock() { lock.lock(); blocked = false; lock.unlock() }

    func read() -> [WindowSwitcherWindowRecord]? {
        lock.lock()
        calls += 1
        let number = calls
        let shouldWait = blocked
        lock.unlock()
        if shouldWait { _ = release.wait(timeout: .now() + 3) }
        lock.lock(); completions += 1; lock.unlock()
        return [.init(windowNumber: UInt32(number), processIdentifier: 42, title: "Fixture", isOnScreen: true,
                      bounds: CGRect(x: 0, y: 30, width: 800, height: 600))]
    }
}

@MainActor
final class WindowSwitcherWindowRecordsTests: XCTestCase {
    func testCancellingOneWaiterDoesNotCancelOtherWaiters() async throws {
        let provider = BlockingWindowRecords()
        let reader = WindowSwitcherWindowRecords(windowRecordRefreshTimeout: 2, windowRecordProvider: { provider.read() })
        defer { provider.release.signal(); reader.stop() }
        let first = Task { await reader.freshWindowRecordSnapshot() }
        let second = Task { await reader.freshWindowRecordSnapshot() }
        try await waitUntil { provider.counts.started == 1 }
        first.cancel()
        let cancelled = await first.value
        XCTAssertFalse(cancelled.isFresh)
        provider.release.signal()
        let snapshot = await second.value
        XCTAssertTrue(snapshot.isFresh)
        XCTAssertEqual(provider.counts.started, 1)
        XCTAssertEqual(snapshot.records.map(\.windowNumber), [1])
    }

    func testTimeoutKeepsPhysicalQueriesBoundedAndIgnoresTheirLateResults() async throws {
        let provider = BlockingWindowRecords()
        let reader = WindowSwitcherWindowRecords(windowRecordRefreshTimeout: 0.03, windowRecordProvider: { provider.read() })
        defer { provider.release.signal(); provider.release.signal(); reader.stop() }
        let first = await reader.freshWindowRecordSnapshot()
        let second = await reader.freshWindowRecordSnapshot()
        let blocked = await reader.freshWindowRecordSnapshot()
        XCTAssertFalse(first.isFresh)
        XCTAssertFalse(second.isFresh)
        XCTAssertFalse(blocked.isFresh)
        XCTAssertEqual(provider.counts.started, 2)
        provider.unblock()
        provider.release.signal()
        provider.release.signal()
        try await waitUntil { provider.counts.completed == 2 }
        // Allow the completion messages, not just the provider calls, to return.
        await Task.yield()
        let current = await reader.freshWindowRecordSnapshot()
        XCTAssertTrue(current.isFresh)
        XCTAssertEqual(current.records.map(\.windowNumber), [3])
    }

    func testStopResumesWaitersWithoutWaitingForSystemQuery() async throws {
        let provider = BlockingWindowRecords()
        let reader = WindowSwitcherWindowRecords(windowRecordRefreshTimeout: 2, windowRecordProvider: { provider.read() })
        defer { provider.release.signal(); reader.stop() }
        let task = Task { await reader.freshWindowRecordSnapshot() }
        try await waitUntil { provider.counts.started == 1 }
        reader.stop()
        let stopped = await task.value
        XCTAssertFalse(stopped.isFresh)
        XCTAssertTrue(stopped.records.isEmpty)
        XCTAssertEqual(provider.counts.completed, 0)
        provider.unblock()
        let current = await reader.freshWindowRecordSnapshot()
        XCTAssertTrue(current.isFresh)
        XCTAssertEqual(current.records.map(\.windowNumber), [2])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    func testInventorySharesTopologyAndRefreshesItOnNextScan() {
        let records = (1...3).map {
            WindowSwitcherWindowRecord(windowNumber: UInt32($0), processIdentifier: 42, title: "Fixture",
                isOnScreen: false, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        var displayReads = 0
        var membershipReads: [CGWindowID] = []
        var currentSpace = 1
        let displays: () -> [[String: Any]]? = {
            displayReads += 1
            return [["Current Space": ["ManagedSpaceID": currentSpace],
                     "Spaces": [["id64": 2, "type": 4]]]]
        }
        let memberships: (CGWindowID) -> [UInt64]? = {
            membershipReads.append($0)
            return [UInt64($0)]
        }
        let first = WindowSwitcherSpaceMembership.classify(records: records, loadDisplays: displays, loadMemberships: memberships)
        XCTAssertEqual(displayReads, 1)
        XCTAssertEqual(membershipReads, [1, 2, 3])
        XCTAssertEqual(first.map(\.isOnActiveSpace), [true, false, false])
        XCTAssertEqual(first.map(\.isOnFullscreenSpace), [false, true, false])
        currentSpace = 2
        let second = WindowSwitcherSpaceMembership.classify(records: records, loadDisplays: displays, loadMemberships: memberships)
        XCTAssertEqual(displayReads, 2)
        XCTAssertEqual(second.map(\.isOnActiveSpace), [false, true, false])
    }

    func testInventoryPreservesUnknownAndEmptySpaceMembership() {
        let records = (1...3).map {
            WindowSwitcherWindowRecord(windowNumber: UInt32($0), processIdentifier: 42, title: "Fixture",
                isOnScreen: false, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        var displayReads = 0
        let classified = WindowSwitcherSpaceMembership.classify(records: records, loadDisplays: {
            displayReads += 1
            return nil
        }, loadMemberships: { $0 == 1 ? [1] : ($0 == 2 ? [] : nil) })
        XCTAssertEqual(displayReads, 1)
        XCTAssertEqual(classified.map(\.hasSpace), [true, false, nil])
        XCTAssertTrue(classified.allSatisfy { $0.isOnActiveSpace == nil && $0.isOnFullscreenSpace == nil })

        let partial = WindowSwitcherSpaceMembership.classify(records: records, loadDisplays: {
            [["Current Space": ["ManagedSpaceID": 1]], [:]]
        }, loadMemberships: { [UInt64($0)] })
        XCTAssertEqual(partial.map(\.isOnActiveSpace), [true, nil, nil])
    }

    func testActiveSpaceMembershipCoversSeparateDisplaysAndFullscreen() {
        let displays: [[String: Any]] = [
            ["Current Space": ["ManagedSpaceID": NSNumber(value: 1)]],
            ["Current Space": ["ManagedSpaceID": NSNumber(value: 223)]]
        ]
        XCTAssertEqual(WindowSwitcherSpaceMembership.intersectsActiveSpaces([223], displays: displays), true)
        XCTAssertEqual(WindowSwitcherSpaceMembership.intersectsActiveSpaces([219], displays: displays), false)
        XCTAssertEqual(WindowSwitcherSpaceMembership.intersectsActiveSpaces([219, 1], displays: displays), true)
        XCTAssertNil(WindowSwitcherSpaceMembership.intersectsActiveSpaces([], displays: displays))
        XCTAssertNil(WindowSwitcherSpaceMembership.intersectsActiveSpaces([219], displays: [[:]]))
        XCTAssertNil(WindowSwitcherSpaceMembership.intersectsActiveSpaces([219], displays: displays + [[:]]))
        XCTAssertEqual(WindowSwitcherSpaceMembership.intersectsActiveSpaces([223], displays: displays + [[:]]), true)
    }

    func testFocusEventsRemainBalancedWhenPostingFailsOrCancellationArrives() {
        let cancellation = WindowSwitcherActionCancellation()
        var packets: [[UInt8]] = []
        WindowSwitcherWindowServer.sendFocusEvents(3133) { bytes in
            packets.append(bytes)
            cancellation.cancel()
            return -1
        }
        XCTAssertEqual(packets.map { $0[8] }, [1, 2])
        for packet in packets {
            XCTAssertEqual(packet.count, 256)
            XCTAssertEqual(packet[4], 248)
            XCTAssertEqual(packet[58], 16)
            packet.withUnsafeBytes {
                XCTAssertEqual($0.loadUnaligned(fromByteOffset: 60, as: CGWindowID.self), 3133)
                let point = $0.loadUnaligned(fromByteOffset: 32, as: CGPoint.self)
                XCTAssertEqual(point, CGPoint(x: 300_000, y: 300_000))
            }
        }
    }

    func testRetainedAXWindowCanRevalidateUsingItsSystemIDAndBounds() async {
        let bounds = CGRect(x: 0, y: 30, width: 800, height: 600)
        let record = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42,
            title: "Other Space", isOnScreen: nil, bounds: bounds, hasSpace: true)
        let response = WindowRecordResponse([record])
        let reader = WindowSwitcherWindowRecords(windowRecordProvider: { response.get() })
        defer { reader.stop() }
        var entry = WindowSwitcherAppEntry(id: "retained", processIdentifier: 42,
            bundleIdentifier: "fixture", appName: "Fixture", windowTitle: "Other Space", icon: nil,
            windowElement: AXUIElementCreateApplication(42), isMinimized: false, windowNumber: 7, shortcutToken: nil)
        entry.bounds = bounds
        XCTAssertNil(entry.windowBounds)
        let valid = await reader.isCurrentFallback(entry)
        XCTAssertTrue(valid)
        let differentlyNamed = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42,
            title: "WindowServer title", isOnScreen: nil, bounds: bounds, hasSpace: true)
        response.set([differentlyNamed])
        let differentTitle = await reader.isCurrentFallback(entry)
        XCTAssertTrue(differentTitle)
        response.set([WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42,
            title: "Other Space", isOnScreen: nil, bounds: bounds, hasSpace: false)])
        let orderedOut = await reader.isCurrentFallback(entry)
        XCTAssertFalse(orderedOut)
        response.set([])
        let closed = await reader.isCurrentFallback(entry)
        XCTAssertFalse(closed)
    }

    func testFallbackAcceptsHelperOwnerAndNearbyBounds() async {
        let bounds = CGRect(x: 0, y: 30, width: 800, height: 600)
        let record = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 200,
            title: "Inbox", isOnScreen: false, bounds: bounds, hasSpace: true)
        let response = WindowRecordResponse([record])
        let reader = WindowSwitcherWindowRecords(windowRecordProvider: { response.get() })
        defer { reader.stop() }
        var entry = WindowSwitcherAppEntry(id: "chrome", processIdentifier: 100,
            bundleIdentifier: "com.google.Chrome", appName: "Chrome", windowTitle: "Inbox", icon: nil,
            windowElement: nil, isMinimized: false, windowNumber: 7, shortcutToken: nil)
        entry.windowOwnerPID = 200
        entry.bounds = bounds.offsetBy(dx: 1, dy: -1)
        let valid = await reader.isCurrentFallback(entry)
        XCTAssertTrue(valid)
    }

    func testFullscreenSpaceIDsUseManagedDisplayType() {
        let displays: [[String: Any]] = [[
            "Spaces": [
                ["id64": NSNumber(value: 10), "type": NSNumber(value: 0)],
                ["id64": NSNumber(value: 44), "type": NSNumber(value: 4)]
            ]
        ]]
        XCTAssertEqual(WindowSwitcherSpaceMembership.fullscreenSpaceIDs(in: displays), [44])
    }

    func testNativeBridgeRequiresExactWindowOwner() {
        let record = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42,
            title: "Fixture", isOnScreen: nil, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(WindowSwitcherWindowServer.matches(7, pid: 42, records: [record]))
        XCTAssertFalse(WindowSwitcherWindowServer.matches(7, pid: 43, records: [record]))
        XCTAssertFalse(WindowSwitcherWindowServer.matches(8, pid: 42, records: [record]))
        XCTAssertFalse(WindowSwitcherWindowServer.matches(0, pid: 42, records: [record]))
    }

    func testFailedReadKeepsSnapshotButCannotAuthorizeActionAndEmptyReadClearsIt() async {
        let record = WindowSwitcherWindowRecord(windowNumber: 1, processIdentifier: 42, title: "Fixture", isOnScreen: true,
            bounds: CGRect(x: 0, y: 30, width: 800, height: 600))
        let response = WindowRecordResponse([record])
        let reader = WindowSwitcherWindowRecords(windowRecordProvider: { response.get() })
        defer { reader.stop() }
        let first = await reader.freshWindowRecordSnapshot()
        XCTAssertTrue(first.isFresh)
        XCTAssertEqual(first.records, [record])
        response.set(nil)
        let failed = await reader.freshWindowRecordSnapshot()
        XCTAssertFalse(failed.isFresh)
        XCTAssertEqual(failed.records, [record])
        let actionRecords = await reader.freshRecordsForActivation()
        XCTAssertTrue(actionRecords.isEmpty)
        response.set([])
        let empty = await reader.freshWindowRecordSnapshot()
        XCTAssertTrue(empty.isFresh)
        XCTAssertTrue(empty.records.isEmpty)
    }
}
