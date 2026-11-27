import AppKit

/// One publication transaction owns row identities. Readers never modify this
/// state, and selection, actions, and recency all consume the same published IDs.
@MainActor
struct WindowSwitcherPublishedWindows {
    private(set) var entries: [WindowSwitcherAppEntry] = []
    private(set) var knownWindowIDs: [pid_t: [CGWindowID: String]] = [:]
    var recency = WindowSwitcherRecency()
    private var confirmedAXWindowNumbers: [pid_t: Set<CGWindowID>] = [:]
    private var axAliases: [pid_t: [String: String]] = [:]

    mutating func removeProcess(_ pid: pid_t) {
        knownWindowIDs.removeValue(forKey: pid)
        axAliases.removeValue(forKey: pid)
        confirmedAXWindowNumbers.removeValue(forKey: pid)
        entries.removeAll { $0.processIdentifier == pid }
    }

    mutating func update(snapshots: [pid_t: [WindowSwitcherAppEntry]], records: [WindowSwitcherWindowRecord],
                         recordsAreFresh: Bool, localEntries: [WindowSwitcherAppEntry] = [],
                         helperProcessIdentifiers: [pid_t: Set<pid_t>] = [:],
                         displayContext: (CGRect) -> (id: UInt32, name: String)? = { _ in nil }) {
        for pid in Set(knownWindowIDs.keys).union(axAliases.keys) where snapshots[pid] == nil {
            removeProcess(pid)
        }
        var published: [WindowSwitcherAppEntry] = []
        var claimedWindowNumbers = Set<CGWindowID>()
        for pid in snapshots.keys.sorted() {
            let raw = snapshots[pid] ?? []
            // A continuously observed AX replacement is a new lifetime even if
            // WindowServer immediately reuses its number. Fallback-to-AX discovery
            // still retains its public ID across legitimate Space transitions.
            let previousAX = Dictionary(entries.filter { $0.processIdentifier == pid && $0.windowElement != nil && $0.windowNumber != nil }
                .map { ($0.windowNumber!, $0) }, uniquingKeysWith: { first, _ in first })
            for entry in raw {
                if let number = entry.windowNumber, let element = entry.windowElement,
                   let previous = previousAX[number], let oldElement = previous.windowElement,
                   !CFEqual(oldElement, element) {
                    knownWindowIDs[pid]?.removeValue(forKey: number)
                    confirmedAXWindowNumbers[pid]?.remove(number)
                }
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
            confirmedAXWindowNumbers[pid, default: []].formUnion(raw.filter { $0.windowElement != nil }.compactMap(\.windowNumber))
            let helpers = helperProcessIdentifiers[pid] ?? []
            let processRecords = records.filter { $0.processIdentifier == pid || helpers.contains($0.processIdentifier) }
            let merged = WindowSwitcherAppCatalog.mergeAllSpacesEntries(normalized, records: processRecords,
                knownWindowIDs: knownWindowIDs[pid] ?? [:],
                confirmedAXWindowNumbers: confirmedAXWindowNumbers[pid] ?? [],
                hasConfirmedEmptyAXSnapshot: recordsAreFresh && raw.contains { !$0.isWindowEntry && !$0.metadataUnavailable },
                helperProcessIdentifiers: helpers)
            var nextAliases: [String: String] = [:]
            var seenIDs = Set<String>()
            for var entry in merged {
                guard entry.isWindowEntry, seenIDs.insert(entry.id).inserted else { continue }
                entry.previewProcessIdentifiers = helpers
                    .union([entry.processIdentifier, entry.owningProcessIdentifier])
                if let number = entry.windowNumber, !claimedWindowNumbers.insert(number).inserted { continue }
                // Register CG-only rows too, before later AX discovery can give
                // the same window a different public identity.
                if let number = entry.windowNumber { knownWindowIDs[pid, default: [:]][number] = entry.id }
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
