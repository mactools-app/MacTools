import AppKit

/// Presentation-independent state shared by the list and card layouts.
struct WindowSwitcherSession {
    enum Scope: Equatable { case all, currentApplication(pid_t) }
    var entries: [WindowSwitcherAppEntry]
    var selectedID: String?
    var scope: Scope = .all
    var query = ""
    var display: UInt32?
    var isPersistent: Bool
    let originalWindowID: String?
    var usesDirectKeys = false
    var protectedCommandKeys: Set<String> = []
    var invocationModifiers: NSEvent.ModifierFlags = []

    var results: [WindowSwitcherAppEntry] {
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        let filtered = entries.filter { entry in
            if case let .currentApplication(pid) = scope, entry.processIdentifier != pid { return false }
            if let display, entry.displayID != display { return false }
            let text = "\(entry.appName) \(entry.windowTitle ?? "")"
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return terms.allSatisfy(text.contains)
        }
        guard !terms.isEmpty else { return filtered }
        func rank(_ entry: WindowSwitcherAppEntry) -> Int {
            let title = (entry.windowTitle ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let app = entry.appName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let phrase = terms.joined(separator: " ")
            if title == phrase { return 0 }
            if title.hasPrefix(phrase) { return 1 }
            if app == phrase { return 2 }
            if app.hasPrefix(phrase) { return 3 }
            return 4
        }
        // Preserve the frozen session order for equally relevant matches.
        return filtered.enumerated().sorted {
            let lhs = rank($0.element), rhs = rank($1.element)
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }

    var displays: [(id: UInt32, name: String)] {
        let names = Dictionary(entries.compactMap { entry -> (UInt32, String)? in
            guard let id = entry.displayID, let name = entry.displayNameContext else { return nil }
            return (id, name)
        }, uniquingKeysWith: { first, _ in first })
        let counts = Dictionary(names.values.map { ($0, 1) }, uniquingKeysWith: +)
        var occurrences: [String: Int] = [:]
        return names.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }.map { id, name in
            occurrences[name, default: 0] += 1
            return (id: id, name: counts[name, default: 0] > 1 ? "\(name) (\(occurrences[name]!))" : name)
        }
    }

    func canSwitchCurrentApplication(_ pid: pid_t?) -> Bool {
        guard let pid else { return false }
        return entries.filter { $0.processIdentifier == pid && $0.isWindowEntry }.count > 1
    }

    var scopedApplicationPID: pid_t? {
        if case let .currentApplication(pid) = scope { return pid }
        return nil
    }

    var scopeTargetPID: pid_t? { scopedApplicationPID ?? selected?.processIdentifier }

    /// Scope changes keep the highlighted window; subsequent presses advance.
    mutating func navigateScope(currentApp: Bool, direction: Int) {
        if currentApp {
            guard let pid = scopeTargetPID, canSwitchCurrentApplication(pid) else { return }
            if scope == .currentApplication(pid) { advance(direction) }
            else { scope = .currentApplication(pid); normalizeSelection() }
        } else if scope != .all {
            scope = .all
            normalizeSelection()
        } else {
            advance(direction)
        }
    }

    var selected: WindowSwitcherAppEntry? { results.first { $0.id == selectedID } }

    mutating func reconcile(_ updated: [WindowSwitcherAppEntry]) {
        // Freeze the session order, updating metadata and appending new arrivals.
        let byID = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let existing = Set(entries.map(\.id))
        entries = entries.compactMap { byID[$0.id] } + updated.filter { !existing.contains($0.id) }
        normalizeSelection()
    }

    mutating func normalizeSelection() {
        if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
    }

    mutating func advance(_ delta: Int) {
        let candidates = results
        guard !candidates.isEmpty else { selectedID = nil; return }
        let anchor = candidates.firstIndex { $0.id == selectedID } ?? 0
        selectedID = candidates[(anchor + delta % candidates.count + candidates.count) % candidates.count].id
    }

    mutating func beginSearch() { isPersistent = true; usesDirectKeys = false }

    /// Filtering and selection do not change the footprint of an invocation.
    var sizingResultCount: Int {
        var unfiltered = self
        unfiltered.query = ""
        return unfiltered.results.count
    }

    static func panelFrame(visibleFrame: CGRect, preview: Bool, count: Int = 12,
                           layout: WindowSwitcherLayout = .grid) -> CGRect {
        // Bound arithmetic even for an unexpectedly large catalog.
        let count = min(10_000, max(1, count))
        let desiredColumns = count <= 6 ? count : count <= 10 ? 5 : 6
        let width = min(layout == .list ? 600 : max(560, CGFloat(desiredColumns) * 132 + 44),
                        max(0, visibleFrame.width - 24))
        // Allow room for a legacy scrollbar when the results overflow.
        let columns = max(1, Int((width - 44) / 132))
        let rows = (count + columns - 1) / columns
        let contentHeight = layout == .list
            ? max(110, CGFloat(min(count, preview ? 4 : 10)) * 56)
            : max(110, CGFloat(min(rows, preview ? 2 : 4)) * 96 + 8)
        let height = min(150 + contentHeight + (preview ? 350 : 0),
                         max(0, min(visibleFrame.height * 0.85, visibleFrame.height - 24)))
        return CGRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2, width: width, height: height)
    }

}

struct WindowSwitcherRecency {
    private(set) var ids: [String] = []
    private(set) var focusedID: String?

    mutating func observeForeground(entries: [WindowSwitcherAppEntry], focusedWindowID: String?, unavailable: Bool) {
        if let focusedWindowID, entries.contains(where: { $0.id == focusedWindowID }) {
            record(focusedWindowID)
        } else if !unavailable, entries.count == 1, let fallback = entries.first, !fallback.isWindowEntry {
            record(fallback.id)
        } else {
            // An unknown foreground target must not keep another app's window
            // marked current. Keep its recency position, but clear the anchor.
            focusedID = nil
        }
    }
    mutating func record(_ id: String) {
        focusedID = id
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
    }
    mutating func retain(_ live: Set<String>) {
        ids.removeAll { !live.contains($0) }
        if let focusedID, !live.contains(focusedID) { self.focusedID = nil }
    }
    func sort(_ entries: [WindowSwitcherAppEntry]) -> [WindowSwitcherAppEntry] {
        let ranks = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        return entries.enumerated().sorted {
            let lhs = ranks[$0.element.id] ?? Int.max
            let rhs = ranks[$1.element.id] ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }
}
