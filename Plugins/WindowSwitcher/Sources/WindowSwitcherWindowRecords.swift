import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Darwin

struct WindowSwitcherWindowRecord: Equatable, Sendable {
    static let minimumWindowSize = CGSize(width: 80, height: 60)

    let windowNumber: CGWindowID
    let processIdentifier: pid_t
    let title: String
    let isOnScreen: Bool?
    let bounds: CGRect
    var hasSpace: Bool? = nil
    var titleIsAvailable = true
    var isOnActiveSpace: Bool? = nil
    var isOnFullscreenSpace: Bool? = nil

    static func parse(_ windowInfo: [[String: Any]]) -> [Self] {
        var seenWindowNumbers = Set<CGWindowID>()
        var records: [WindowSwitcherWindowRecord] = []

        for item in windowInfo {
            guard let windowNumber = number(in: item, forKey: kCGWindowNumber),
                  windowNumber > 0,
                  let processIdentifier = processIdentifier(in: item),
                  processIdentifier > 0,
                  number(in: item, forKey: kCGWindowLayer) == 0,
                  let alpha = numericValue(in: item, forKey: kCGWindowAlpha),
                  alpha > 0,
                  alpha <= 1,
                  let bounds = rect(in: item[kCGWindowBounds as String]),
                  bounds.width >= minimumWindowSize.width,
                  bounds.height >= minimumWindowSize.height
            else {
                continue
            }

            guard seenWindowNumbers.insert(windowNumber).inserted else {
                continue
            }

            records.append(
                WindowSwitcherWindowRecord(
                    windowNumber: windowNumber,
                    processIdentifier: processIdentifier,
                    title: item[kCGWindowName as String] as? String ?? "",
                    isOnScreen: boolean(in: item, forKey: kCGWindowIsOnscreen),
                    bounds: bounds,
                    // Core Graphics can omit names without Screen Recording
                    // permission. Absence is not evidence of an empty title.
                    titleIsAvailable: item[kCGWindowName as String] != nil
                )
            )
        }

        return records
    }

    private static func number(in item: [String: Any], forKey key: CFString) -> UInt32? {
        guard let rawValue = numericValue(in: item, forKey: key),
              rawValue.rounded() == rawValue,
              rawValue >= 0,
              rawValue <= Double(UInt32.max)
        else {
            return nil
        }

        return UInt32(rawValue)
    }

    private static func boolean(in item: [String: Any], forKey key: CFString) -> Bool? {
        guard let value = item[key as String] as? NSNumber else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == CFBooleanGetTypeID() else {
            return nil
        }

        return value.boolValue
    }

    private static func numericValue(in item: [String: Any], forKey key: CFString) -> Double? {
        guard let value = item[key as String] as? NSNumber else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) != CFBooleanGetTypeID() else {
            return nil
        }

        let rawValue = value.doubleValue
        guard rawValue.isFinite else {
            return nil
        }

        return rawValue
    }

    private static func processIdentifier(in item: [String: Any]) -> pid_t? {
        guard let rawValue = numericValue(in: item, forKey: kCGWindowOwnerPID),
              rawValue.rounded() == rawValue,
              rawValue > 0,
              rawValue <= Double(pid_t.max)
        else {
            return nil
        }

        return pid_t(rawValue)
    }

    private static func rect(in value: Any?) -> CGRect? {
        guard let dictionary = value as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dictionary),
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite
        else {
            return nil
        }

        return rect
    }
}

struct WindowSwitcherWindowRecordSnapshot: Sendable {
    let records: [WindowSwitcherWindowRecord]
    let isFresh: Bool
}

/// The all-Spaces CG reader is kept separate from AX discovery and actions.
/// Slow system reads are bounded and stale data can never authorize an action.
@MainActor
final class WindowSwitcherWindowRecords {
    private static let maxWindowRecordRefreshesInFlight = 2
    private let windowRecordProvider: @Sendable () -> [WindowSwitcherWindowRecord]?
    private let windowRecordRefreshTimeout: TimeInterval
    private var windowRecords: [WindowSwitcherWindowRecord] = []
    private var windowRecordRefreshTask: Task<[WindowSwitcherWindowRecord]?, Never>?
    private var windowRecordRefreshGeneration: UInt64 = 0
    private var windowRecordRefreshInFlightCount = 0
    private var timeoutTask: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<WindowSwitcherWindowRecordSnapshot, Never>] = [:]

    init(windowRecordRefreshTimeout: TimeInterval = 0.75,
         windowRecordProvider: @escaping @Sendable () -> [WindowSwitcherWindowRecord]? = {
             guard let info = CGWindowListCopyWindowInfo(
                 [.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
             return WindowSwitcherSpaceMembership.classify(records: WindowSwitcherWindowRecord.parse(info))
         }) {
        self.windowRecordRefreshTimeout = windowRecordRefreshTimeout.isFinite ? max(0, windowRecordRefreshTimeout) : 0.75
        self.windowRecordProvider = windowRecordProvider
    }

    func stop() {
        windowRecordRefreshGeneration &+= 1
        windowRecordRefreshTask?.cancel()
        windowRecordRefreshTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        windowRecords.removeAll()
        finishWaiters(isFresh: false)
    }

    func windowRecordsSnapshot() async -> [WindowSwitcherWindowRecord] {
        await freshWindowRecords()
    }

    func freshRecordsForActivation() async -> [WindowSwitcherWindowRecord] {
        let snapshot = await freshWindowRecordSnapshot()
        return snapshot.isFresh && !Task.isCancelled ? snapshot.records : []
    }

    func isCurrentFallback(_ entry: WindowSwitcherAppEntry) async -> Bool {
        let snapshot = await freshWindowRecordSnapshot()
        return !Task.isCancelled && snapshot.isFresh && currentWindowRecord(for: entry, in: snapshot.records) != nil
    }

    private func currentWindowRecord(
        for entry: WindowSwitcherAppEntry,
        in records: [WindowSwitcherWindowRecord]
    ) -> WindowSwitcherWindowRecord? {
        guard let windowNumber = entry.windowNumber,
              entry.bounds.width > 0, entry.bounds.height > 0,
              let record = records.first(where: {
                  $0.windowNumber == windowNumber
                      && ($0.processIdentifier == entry.processIdentifier
                          || $0.processIdentifier == entry.owningProcessIdentifier)
              }),
              WindowSwitcherAppCatalog.sameBounds(record.bounds, entry.bounds)
        else {
            return nil
        }

        // A retained AX entry may refer to a just-closed surface. Only positive
        // visibility or Space evidence permits revealing it after AX omitted it.
        guard entry.windowElement == nil || record.isOnScreen == true || record.hasSpace == true else { return nil }
        // AX and WindowServer can use different titles (notably Chrome). The
        // retained AX window already supplied the exact ID; fallback-only rows
        // still require their original WindowServer title to match.
        if entry.windowElement == nil, !record.title.isEmpty,
           let expectedTitle = entry.windowTitle,
           !expectedTitle.isEmpty,
           record.title != expectedTitle {
            return nil
        }

        return record
    }

    private func refreshWindowRecords() {
        guard windowRecordRefreshTask == nil,
              windowRecordRefreshInFlightCount < Self.maxWindowRecordRefreshesInFlight
        else {
            return
        }

        windowRecordRefreshGeneration &+= 1
        let generation = windowRecordRefreshGeneration
        let provider = windowRecordProvider
        windowRecordRefreshInFlightCount += 1
        let task = Task.detached(priority: .userInitiated) {
            provider()
        }
        windowRecordRefreshTask = task
        let timeout = windowRecordRefreshTimeout
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self?.abandonWindowRecordRefresh(generation: generation)
        }

        Task { @MainActor [weak self] in
            let records = await task.value
            guard let self,
                  self.windowRecordRefreshInFlightCount > 0
            else {
                return
            }
            self.windowRecordRefreshInFlightCount -= 1

            guard self.windowRecordRefreshGeneration == generation else {
                return
            }

            guard self.windowRecordRefreshTask != nil else {
                return
            }

            self.windowRecordRefreshTask = nil
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            // Failure is not a successful empty scan. Retain the last snapshot
            // for presentation, but never mark it fresh enough for an action.
            if let records {
                self.windowRecords = records
            }
            self.finishWaiters(isFresh: records != nil)
        }
    }

    private func freshWindowRecords() async -> [WindowSwitcherWindowRecord] {
        await freshWindowRecordSnapshot().records
    }

    func freshWindowRecordSnapshot() async -> WindowSwitcherWindowRecordSnapshot {
        guard !Task.isCancelled else { return .init(records: windowRecords, isFresh: false) }
        refreshWindowRecords()
        guard windowRecordRefreshTask != nil else {
            return WindowSwitcherWindowRecordSnapshot(records: windowRecords, isFresh: false)
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .init(records: windowRecords, isFresh: false))
                    return
                }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                waiters.removeValue(forKey: id)?.resume(returning: .init(records: windowRecords, isFresh: false))
            }
        }
    }

    private func abandonWindowRecordRefresh(generation: UInt64) {
        guard windowRecordRefreshGeneration == generation else {
            return
        }

        windowRecordRefreshTask?.cancel()
        windowRecordRefreshTask = nil
        windowRecordRefreshGeneration &+= 1
        timeoutTask?.cancel()
        timeoutTask = nil
        finishWaiters(isFresh: false)
    }

    private func finishWaiters(isFresh: Bool) {
        let pending = waiters
        waiters.removeAll()
        let snapshot = WindowSwitcherWindowRecordSnapshot(records: windowRecords, isFresh: isFresh)
        for continuation in pending.values { continuation.resume(returning: snapshot) }
    }
}

/// Optional read-only WindowServer metadata distinguishes ordered-out utility
/// surfaces from real windows on another Space. Missing APIs/data stay unknown.
enum WindowSwitcherSpaceMembership {
    private typealias Connection = @convention(c) () -> UInt32
    private typealias CopySpaces = @convention(c) (UInt32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private static let functions: (Connection, CopySpaces)? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let connection = dlsym(handle, "CGSMainConnectionID"),
              let spaces = dlsym(handle, "CGSCopySpacesForWindows") else { return nil }
        return (unsafeBitCast(connection, to: Connection.self), unsafeBitCast(spaces, to: CopySpaces.self))
    }()

    private typealias CopyDisplays = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private static let copyDisplays: CopyDisplays? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let pointer = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(pointer, to: CopyDisplays.self)
    }()

    /// Query every display: the globally active Space is insufficient when
    /// displays have separate Spaces. Unknown topology preserves the fallback.
    static func isOnActiveSpace(_ window: CGWindowID) -> Bool? {
        guard let (connection, copySpaces) = functions, let copyDisplays else { return nil }
        let client = connection()
        guard let spaces = copySpaces(client, 7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber],
              let displays = copyDisplays(client)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return intersectsActiveSpaces(spaces.map(\.uint64Value), displays: displays)
    }

    static func intersectsActiveSpaces(_ memberships: [UInt64], displays: [[String: Any]]) -> Bool? {
        guard !memberships.isEmpty, !displays.isEmpty else { return nil }
        var unknown = false
        for display in displays {
            guard let current = display["Current Space"] as? [String: Any],
                  let id = (current["ManagedSpaceID"] ?? current["id64"]) as? NSNumber,
                  id.uint64Value > 0 else { unknown = true; continue }
            if memberships.contains(id.uint64Value) { return true }
        }
        return unknown ? nil : false
    }

    struct Classification: Equatable, Sendable {
        var hasSpace: Bool? = nil
        var isOnActiveSpace: Bool? = nil
        var isOnFullscreenSpace: Bool? = nil
    }

    private struct Topology {
        var activeIDs = Set<UInt64>()
        var fullscreenIDs = Set<UInt64>()
        var hasUnknownActiveSpace = false

        init(displays: [[String: Any]]?) {
            guard let displays, !displays.isEmpty else {
                hasUnknownActiveSpace = true
                return
            }
            fullscreenIDs = fullscreenSpaceIDs(in: displays)
            for display in displays {
                guard let current = display["Current Space"] as? [String: Any],
                      let id = (current["ManagedSpaceID"] ?? current["id64"]) as? NSNumber,
                      id.uint64Value > 0 else { hasUnknownActiveSpace = true; continue }
                activeIDs.insert(id.uint64Value)
            }
        }

        func classify(_ memberships: [UInt64]?) -> Classification {
            guard let memberships else { return Classification() }
            var result = Classification(hasSpace: !memberships.isEmpty)
            if !memberships.isEmpty {
                result.isOnActiveSpace = !activeIDs.isDisjoint(with: memberships)
                    ? true : (hasUnknownActiveSpace ? nil : false)
            }
            if !fullscreenIDs.isEmpty {
                result.isOnFullscreenSpace = !fullscreenIDs.isDisjoint(with: memberships)
            }
            return result
        }
    }

    static func managedDisplays() -> [[String: Any]]? {
        guard let (connection, _) = functions, let copyDisplays else { return nil }
        return copyDisplays(connection())?.takeRetainedValue() as? [[String: Any]]
    }

    static func memberships(_ window: CGWindowID) -> [UInt64]? {
        guard let (connection, copySpaces) = functions,
              let spaces = copySpaces(connection(), 7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        else { return nil }
        return spaces.map(\.uint64Value)
    }

    static func classify(_ window: CGWindowID) -> Classification {
        Topology(displays: managedDisplays()).classify(memberships(window))
    }

    /// Share one topology snapshot across the inventory, including failed reads.
    /// The next inventory reads it again so Space changes are never cached across scans.
    static func classify(records: [WindowSwitcherWindowRecord],
                         loadDisplays: () -> [[String: Any]]? = { managedDisplays() },
                         loadMemberships: (CGWindowID) -> [UInt64]? = { memberships($0) }) -> [WindowSwitcherWindowRecord] {
        guard !records.isEmpty else { return [] }
        let topology = Topology(displays: loadDisplays())
        return records.map { record in
            var record = record
            let classification = topology.classify(loadMemberships(record.windowNumber))
            record.hasSpace = classification.hasSpace ?? record.hasSpace
            record.isOnActiveSpace = classification.isOnActiveSpace
            record.isOnFullscreenSpace = classification.isOnFullscreenSpace
            return record
        }
    }

    static func fullscreenSpaceIDs(in displays: [[String: Any]]) -> Set<UInt64> {
        var ids = Set<UInt64>()
        for display in displays {
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard (space["type"] as? NSNumber)?.intValue == 4,
                      let id = (space["id64"] as? NSNumber)?.uint64Value, id > 0 else { continue }
                ids.insert(id)
            }
        }
        return ids
    }

    static func hasSpace(_ window: CGWindowID) -> Bool? {
        memberships(window).map { !$0.isEmpty }
    }
}
