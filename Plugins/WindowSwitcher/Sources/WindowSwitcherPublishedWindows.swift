import AppKit
import ApplicationServices

/// One publication transaction owns row identities. Readers never modify this
/// state, and selection, actions, and recency all consume the same published IDs.
@MainActor
struct WindowSwitcherPublishedWindows {
    struct CompleteWindowList {
        let startedAt: ContinuousClock.Instant
        let windowNumbers: Set<CGWindowID>
        var windowServerNumbersAtEmptyRead: Set<CGWindowID>?
    }

    private struct RetainedWindow {
        var awaitingConfirmationSince: ContinuousClock.Instant?
        let previousAX: AXUIElement?
    }

    private(set) var entries: [WindowSwitcherAppEntry] = []
    private(set) var knownWindowIDs: [pid_t: [CGWindowID: String]] = [:]
    var recency = WindowSwitcherRecency()
    private var confirmedAXWindowNumbers: [pid_t: Set<CGWindowID>] = [:]
    private var axAliases: [pid_t: [String: String]] = [:]
    private var retainedWindows: [pid_t: [CGWindowID: RetainedWindow]] = [:]

    func retainedAXElement(for entry: WindowSwitcherAppEntry) -> AXUIElement? {
        guard let number = entry.windowNumber else { return nil }
        return retainedWindows[entry.processIdentifier]?[number]?.previousAX
    }

    func hasNewPendingWindowEvidence(from previousCapture: ContinuousClock.Instant?, to capture: ContinuousClock.Instant) -> Bool {
        retainedWindows.values.contains { windows in
            windows.values.contains { window in
                guard let omittedAt = window.awaitingConfirmationSince else { return false }
                return capture >= omittedAt && previousCapture.map { $0 < omittedAt } != false
            }
        }
    }

    mutating func removeProcess(_ pid: pid_t) {
        knownWindowIDs.removeValue(forKey: pid)
        axAliases.removeValue(forKey: pid)
        confirmedAXWindowNumbers.removeValue(forKey: pid)
        retainedWindows.removeValue(forKey: pid)
        entries.removeAll { $0.processIdentifier == pid }
    }

    mutating func update(snapshots: [pid_t: [WindowSwitcherAppEntry]], records: [WindowSwitcherWindowRecord],
                         recordsAreFresh: Bool, localEntries: [WindowSwitcherAppEntry] = [],
                         helperProcessIdentifiers: [pid_t: Set<pid_t>] = [:],
                         completeWindowLists: [pid_t: CompleteWindowList] = [:],
                         recordsStartedAt: ContinuousClock.Instant? = nil,
                         displayContext: (CGRect) -> (id: UInt32, name: String)? = { _ in nil }) {
        for pid in Set(knownWindowIDs.keys).union(axAliases.keys) where snapshots[pid] == nil {
            removeProcess(pid)
        }
        var published: [WindowSwitcherAppEntry] = []
        var claimedWindowNumbers = Set<CGWindowID>()
        for pid in snapshots.keys.sorted() {
            let raw = snapshots[pid] ?? []
            let helpers = helperProcessIdentifiers[pid] ?? []
            let processRecords = records.filter { $0.processIdentifier == pid || helpers.contains($0.processIdentifier) }
            let priorRetained = retainedWindows[pid] ?? [:]
            let completeList = completeWindowLists[pid]
            // A continuously observed AX replacement is a new lifetime even if
            // WindowServer immediately reuses its number. Fallback-to-AX discovery
            // retains its public ID across legitimate Space transitions. A retained
            // row keeps its last AX handle even after its new Space is confirmed.
            let previousAX = Dictionary(entries.filter { $0.processIdentifier == pid && $0.windowElement != nil && $0.windowNumber != nil }
                .map { ($0.windowNumber!, $0) }, uniquingKeysWith: { first, _ in first })
            for entry in raw where !entry.metadataUnavailable {
                guard let number = entry.windowNumber, let element = entry.windowElement,
                      let oldElement = priorRetained[number]?.previousAX ?? previousAX[number]?.windowElement,
                      !CFEqual(oldElement, element) else { continue }
                knownWindowIDs[pid]?.removeValue(forKey: number)
                confirmedAXWindowNumbers[pid]?.remove(number)
            }
            let previousAliases = axAliases[pid] ?? [:]
            let normalized = raw.map { entry in
                var entry = entry
                if entry.windowElement != nil {
                    let workerID = entry.workerWindowID ?? entry.id
                    entry.workerWindowID = workerID
                    entry.id = previousAliases[workerID] ?? entry.id
                }
                return entry
            }
            let liveAXNumbers = Set(raw.filter { $0.windowElement != nil && !$0.metadataUnavailable }.compactMap(\.windowNumber))
            confirmedAXWindowNumbers[pid, default: []].formUnion(liveAXNumbers)
            var retained: [CGWindowID: RetainedWindow] = [:]
            var unconfirmed = Set<CGWindowID>()
            for record in processRecords {
                let number = record.windowNumber
                guard !liveAXNumbers.contains(number), completeList?.windowNumbers.contains(number) != true else { continue }
                var window = priorRetained[number]
                if let omittedAt = window?.awaitingConfirmationSince {
                    let placementIsKnown = record.isOnScreen == true || record.hasSpace != nil || record.isOnActiveSpace != nil
                    if recordsAreFresh, recordsStartedAt.map({ $0 >= omittedAt }) == true, placementIsKnown {
                        window?.awaitingConfirmationSince = nil
                    }
                } else if let completeList, let recordsStartedAt, completeList.startedAt > recordsStartedAt,
                          confirmedAXWindowNumbers[pid]?.contains(number) == true,
                          record.isOnActiveSpace != false, record.isOnScreen ?? (record.isOnActiveSpace == true) {
                    // The complete AX list omitted a previously known window
                    // still shown on the active Space by an older capture.
                    window = RetainedWindow(awaitingConfirmationSince: completeList.startedAt,
                                            previousAX: window?.previousAX ?? previousAX[number]?.windowElement)
                }
                retained[number] = window
                if window?.awaitingConfirmationSince != nil { unconfirmed.insert(number) }
            }
            let excludedWindowNumbers: Set<CGWindowID>
            if !recordsAreFresh {
                excludedWindowNumbers = []
            } else if raw.contains(where: { !$0.isWindowEntry && !$0.metadataUnavailable }) {
                excludedWindowNumbers = Set(processRecords.map(\.windowNumber))
            } else {
                // A failed read carries forward the exclusion of previously seen
                // records. A new WindowServer row can still pass the usual checks.
                excludedWindowNumbers = completeList?.windowServerNumbersAtEmptyRead ?? []
            }
            let merged = WindowSwitcherAppCatalog.mergeAllSpacesEntries(normalized, records: processRecords,
                knownWindowIDs: knownWindowIDs[pid] ?? [:],
                confirmedAXWindowNumbers: confirmedAXWindowNumbers[pid] ?? [],
                windowNumbersExcludedByEmptyAXList: excludedWindowNumbers,
                helperProcessIdentifiers: helpers, unconfirmedWindowNumbers: unconfirmed)
            var nextAliases: [String: String] = [:]
            var publishedRetained: [CGWindowID: RetainedWindow] = [:]
            var seenIDs = Set<String>()
            for var entry in merged {
                guard entry.isWindowEntry, seenIDs.insert(entry.id).inserted else { continue }
                entry.previewProcessIdentifiers = helpers
                    .union([entry.processIdentifier, entry.owningProcessIdentifier])
                if let number = entry.windowNumber, !claimedWindowNumbers.insert(number).inserted { continue }
                // Register CG-only rows too, before later AX discovery can give
                // the same window a different public identity.
                if let number = entry.windowNumber {
                    knownWindowIDs[pid, default: [:]][number] = entry.id
                    entry.isAwaitingWindowConfirmation = unconfirmed.contains(number)
                    publishedRetained[number] = retained[number]
                }
                if let workerID = entry.workerWindowID { nextAliases[workerID] = entry.id }
                if entry.windowElement == nil && entry.isWindowEntry && !recordsAreFresh {
                    entry.metadataUnavailable = true
                }
                if entry.displayID == nil, let display = displayContext(entry.bounds) {
                    entry.displayID = display.id
                    entry.displayNameContext = display.name
                }
                published.append(entry)
            }
            axAliases[pid] = nextAliases
            retainedWindows[pid] = publishedRetained.isEmpty ? nil : publishedRetained
            // A failed CG read cannot establish closure. Even a successful read
            // must not discard an ID independently confirmed by live AX data.
            if recordsAreFresh {
                let liveNumbers = Set(processRecords.map(\.windowNumber)).union(raw.compactMap(\.windowNumber))
                knownWindowIDs[pid] = knownWindowIDs[pid]?.filter { liveNumbers.contains($0.key) }
                confirmedAXWindowNumbers[pid]?.formIntersection(liveNumbers)
            }
        }
        entries = published + localEntries
        recency.retain(Set(entries.map(\.id)))
    }
}
