import AppKit
import ApplicationServices
import Foundation

struct WindowSwitcherOpening {
    let entries: [WindowSwitcherAppEntry]
    let focusedWindowID: String?
}

@MainActor
protocol WindowSwitcherCatalog: AnyObject {
    var onChange: (() -> Void)? { get set }
    var listingPolicy: WindowSwitcherListingPolicy { get set }
    func start()
    func stop()
    func refresh()
    func prepareForInvocation(sortMode: WindowSwitcherSortMode)
    func opening(sortMode: WindowSwitcherSortMode, deadlineReached: Bool) -> WindowSwitcherOpening?
    func cancelInvocation()
    func entries(sortMode: WindowSwitcherSortMode) -> [WindowSwitcherAppEntry]
    func activate(_ entry: WindowSwitcherAppEntry, intent: WindowSwitcherActivationIntent) async -> WindowSwitcherActionResult
    func closeWindow(_ entry: WindowSwitcherAppEntry) async -> WindowSwitcherActionResult
    func quitApplication(_ entry: WindowSwitcherAppEntry) -> WindowSwitcherActionResult
}

extension WindowSwitcherCatalog {
    func prepareForInvocation(sortMode: WindowSwitcherSortMode) { refresh() }
    func cancelInvocation() {}

    var listingPolicy: WindowSwitcherListingPolicy {
        get { .default }
        set { _ = newValue }
    }
}

@MainActor
final class WindowSwitcherAppCatalog: WindowSwitcherCatalog {
    struct Application {
        struct Presentation {
            var localizedName: String?
            var icon: NSImage?
            var isHidden: Bool
            var isActive: Bool
        }

        var processIdentifier: pid_t
        var bundleIdentifier: String?
        var bundlePath: String?
        var localizedName: String?
        var icon: NSImage? = nil
        var launchDate: Date? = nil
        var lifetime: UUID? = nil
        var isRegular = true
        var isHidden = false
        var isActive = false
        var loadPresentation: (() -> Presentation)? = nil

        func withPresentation() -> Application {
            guard let loadPresentation else { return self }
            let presentation = loadPresentation()
            var result = self
            result.localizedName = presentation.localizedName
            result.icon = presentation.icon
            result.isHidden = presentation.isHidden
            result.isActive = presentation.isActive
            result.loadPresentation = nil
            return result
        }
    }

    struct DiscoveryEnvironment {
        var applications: (() -> [Application])? = nil
        var isAccessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
        var isDragging: () -> Bool = { CGEventSource.buttonState(.combinedSessionState, button: .left) }
    }

    var onChange: (() -> Void)?
    private(set) var isInitialDiscoveryComplete = false
    private(set) var isInvocationReady = false
    private(set) var unavailableApplicationCount = 0
    var focusedWindowID: String? { publication.recency.focusedID }
    var listingPolicy = WindowSwitcherListingPolicy.default {
        didSet {
            guard listingPolicy != oldValue else { return }
            rebuildPublication()
            onChange?()
        }
    }
    private var processMapping = WindowSwitcherProcessMapping.Snapshot()
    private var helperPIDsByHost: [pid_t: Set<pid_t>] = [:]
    private var expectedHostPIDs: Set<pid_t> = []
    private let notificationCenter: NotificationCenter
    private let accessFactory: @Sendable (pid_t) -> any WindowSwitcherAXAccess
    private var observers: [NSObjectProtocol] = []
    private var workers: [pid_t: WindowSwitcherProcessWorker] = [:]
    private var snapshots: [pid_t: [WindowSwitcherAppEntry]] = [:]
    private var completeWindowLists: [pid_t: WindowSwitcherPublishedWindows.CompleteWindowList] = [:]
    private var inFlight: Set<pid_t> = []
    // Kept across stop/start until the actual worker returns.
    private var activeScanCount = 0
    private var dirtyHosts: Set<pid_t> = []
    private var pendingInvalidations: Set<pid_t> = []
    private var pendingRecordsInvalidation = false
    private var applicationsByPID: [pid_t: Application] = [:]
    private var mappingCandidates: [WindowSwitcherProcessMapping.Candidate] = []
    private let applicationInventory: WindowSwitcherApplicationInventory?
    private static let maximumConcurrentScans = 4
    private var unavailable: Set<pid_t> = []
    private var timer: Timer?
    private var running = false
    private var invalidationTask: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?
    private var publicationDirty = false
    private var removedProcesses: Set<pid_t> = []
    private var pendingFocus: [pid_t: (id: String?, unavailable: Bool)] = [:]
    private var windowRecordsPending = false
    private var sleeping = false
    private var sessionInactive = false
    private var suspended: Bool { sleeping || sessionInactive }
    private var invocationGeneration = UUID()
    private var invocationRequiredHosts: Set<pid_t> = []
    private var invocationRequiresRecords = false
    private let allSpacesCatalog: WindowSwitcherWindowRecords
    private let discovery: DiscoveryEnvironment
    private var publication = WindowSwitcherPublishedWindows()
    private let hostWindows = WindowSwitcherHostWindows()
    private var allSpacesRecordsAreFresh = false
    private var windowRecordsStartedAt: ContinuousClock.Instant?
    private var allSpacesRecords: [WindowSwitcherWindowRecord] = []
    private var allSpacesRefreshTask: Task<Void, Never>?
    private var allSpacesGeneration = UUID()
    private var didReadAllSpaces = false

    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         accessFactory: @escaping @Sendable (pid_t) -> any WindowSwitcherAXAccess = { _ in SystemWindowSwitcherAXAccess() },
         allSpacesCatalog: WindowSwitcherWindowRecords = WindowSwitcherWindowRecords(),
         discovery: DiscoveryEnvironment = DiscoveryEnvironment()) {
        self.notificationCenter = notificationCenter
        self.accessFactory = accessFactory
        self.allSpacesCatalog = allSpacesCatalog
        self.discovery = discovery
        applicationInventory = discovery.applications == nil ? WindowSwitcherApplicationInventory() : nil
    }

    func start() {
        guard !running else { return }
        running = true
        let lifecycle = allSpacesGeneration
        applicationInventory?.onChange = { [weak self] pids in
            guard let self, running else { return }
            reloadApplications()
            invalidate(processIdentifiers: pids, windowRecords: true)
        }
        applicationInventory?.start()
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                Task { @MainActor [weak self] in
                    guard let self, running, allSpacesGeneration == lifecycle else { return }
                    applicationInventory?.reconcile(notify: false)
                    if let pid { applicationInventory?.reload(processIdentifier: pid) }
                    reloadApplications()
                    if let pid { invalidate(processIdentifiers: [pid], windowRecords: true) }
                    else { refresh() }
                }
            })
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, running, allSpacesGeneration == lifecycle else { return }
                    if name == NSWorkspace.didWakeNotification { sleeping = false }
                    if name == NSWorkspace.sessionDidBecomeActiveNotification { sessionInactive = false }
                    refresh()
                }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, running, allSpacesGeneration == lifecycle else { return }
                    if name == NSWorkspace.willSleepNotification { sleeping = true }
                    if name == NSWorkspace.sessionDidResignActiveNotification { sessionInactive = true }
                }
            })
        }
        // Recover omitted/unsupported AX events without continuously scanning
        // every application. Invocation always requests its own reconciliation.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, allSpacesGeneration == lifecycle else { return }
                refresh()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        running = false
        sleeping = false
        sessionInactive = false
        invalidationTask?.cancel(); invalidationTask = nil
        publicationTask?.cancel(); publicationTask = nil
        publicationDirty = false
        removedProcesses.removeAll()
        pendingFocus.removeAll()
        applicationInventory?.stop()
        allSpacesGeneration = UUID()
        invocationGeneration = UUID()
        invocationRequiredHosts.removeAll()
        invocationRequiresRecords = false
        isInvocationReady = false
        cancelInvocation()
        windowRecordsPending = false
        allSpacesRefreshTask?.cancel(); allSpacesRefreshTask = nil
        allSpacesCatalog.stop()
        allSpacesRecords.removeAll()
        publication = WindowSwitcherPublishedWindows()
        hostWindows.reset()
        allSpacesRecordsAreFresh = false
        windowRecordsStartedAt = nil
        didReadAllSpaces = false
        isInitialDiscoveryComplete = false
        expectedHostPIDs = []
        processMapping = WindowSwitcherProcessMapping.Snapshot()
        mappingCandidates.removeAll()
        applicationsByPID.removeAll()
        helperPIDsByHost.removeAll()
        dirtyHosts.removeAll()
        pendingInvalidations.removeAll()
        pendingRecordsInvalidation = false
        timer?.invalidate(); timer = nil
        observers.forEach(notificationCenter.removeObserver); observers.removeAll()
        workers.values.forEach { $0.stop() }; workers.removeAll()
        snapshots.removeAll(); inFlight.removeAll(); unavailable.removeAll()
        completeWindowLists.removeAll()
        unavailableApplicationCount = 0
    }

    /// Coalesces events by owner. A dirty host remains queued when a scan is in
    /// flight, so changes arriving during that scan get one follow-up read.
    func invalidate(processIdentifiers: Set<pid_t>, windowRecords: Bool) {
        guard running else { return }
        let hosts = Set(processIdentifiers.map { processMapping.host(for: $0) })
        pendingInvalidations.formUnion(hosts.intersection(expectedHostPIDs))
        pendingRecordsInvalidation = pendingRecordsInvalidation || windowRecords
        if processIdentifiers.contains(ProcessInfo.processInfo.processIdentifier) { markPublicationDirty() }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard running, !suspended, invalidationTask == nil else { return }
        invalidationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            invalidationTask = nil
            applyInvalidations()
            drainRefreshes()
        }
    }

    private func applyInvalidations() {
        dirtyHosts.formUnion(pendingInvalidations.intersection(expectedHostPIDs))
        pendingInvalidations.removeAll()
        windowRecordsPending = windowRecordsPending || pendingRecordsInvalidation
        pendingRecordsInvalidation = false
    }

    func refresh() {
        guard running, !suspended else { return }
        applicationInventory?.reconcile(notify: false)
        reloadApplications()
        applyInvalidations()
        dirtyHosts.formUnion(expectedHostPIDs)
        windowRecordsPending = true
        markPublicationDirty()
        drainRefreshes()
    }

    func prepareForInvocation(sortMode: WindowSwitcherSortMode) {
        guard running else { return }
        cancelInvocation()
        invocationGeneration = UUID()
        isInvocationReady = false
        applicationInventory?.reconcile(notify: false)
        reloadApplications()
        applyInvalidations()
        invocationRequiredHosts = expectedHostPIDs
        invocationRequiresRecords = true
        dirtyHosts.formUnion(expectedHostPIDs)
        windowRecordsPending = true
        markPublicationDirty()
        drainRefreshes()
    }

    private func reloadApplications() {
        let oldMapping = processMapping
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = discovery.applications?() ?? applicationInventory?.applications ?? []
        applicationsByPID = Dictionary(runningApps.map { ($0.processIdentifier, $0) },
                                       uniquingKeysWith: { first, _ in first })
        let candidates = runningApps.map {
            WindowSwitcherProcessMapping.Candidate(processIdentifier: $0.processIdentifier,
                bundleIdentifier: $0.bundleIdentifier, bundlePath: $0.bundlePath, isRegular: $0.isRegular)
        }.sorted { $0.processIdentifier < $1.processIdentifier }
        if candidates != mappingCandidates {
            mappingCandidates = candidates
            processMapping = WindowSwitcherProcessMapping.snapshot(candidates: candidates, ownPID: ownPID)
            helperPIDsByHost = processMapping.helpersByHost(owningWindowsIn: allSpacesRecords)
        }
        expectedHostPIDs = Set(runningApps.filter {
            $0.isRegular && $0.processIdentifier != ownPID && $0.processIdentifier > 0
                && processMapping.host(for: $0.processIdentifier) == $0.processIdentifier
        }.map(\.processIdentifier))
        let liveWorkerPIDs = expectedHostPIDs.union(helperPIDsByHost.values.flatMap { $0 })
        for pid in Array(workers.keys) {
            guard liveWorkerPIDs.contains(pid), let app = applicationsByPID[pid],
                  workers[pid]?.launchDate == app.launchDate,
                  workers[pid]?.applicationLifetime == app.lifetime else {
                workers.removeValue(forKey: pid)?.stop()
                inFlight.remove(pid)
                unavailable.remove(pid)
                snapshots.removeValue(forKey: pid)
                completeWindowLists.removeValue(forKey: pid)
                pendingFocus.removeValue(forKey: pid)
                removedProcesses.insert(pid)
                dirtyHosts.insert(oldMapping.host(for: pid))
                markPublicationDirty()
                continue
            }
        }
        for pid in Array(snapshots.keys) where !expectedHostPIDs.contains(pid) {
            snapshots.removeValue(forKey: pid)
            completeWindowLists.removeValue(forKey: pid)
            removedProcesses.insert(pid)
            markPublicationDirty()
        }
        dirtyHosts.formIntersection(expectedHostPIDs)
        invocationRequiredHosts.formIntersection(expectedHostPIDs)
        dirtyHosts.formUnion(expectedHostPIDs.filter { snapshots[$0] == nil })
    }

    private func drainRefreshes() {
        guard running, !suspended else { return }
        guard discovery.isAccessibilityTrusted() else {
            onChange?()
            return
        }
        // Preserve pending work during tracking; the short retry exists only
        // while a user drag prevents a requested refresh from proceeding.
        guard !discovery.isDragging() else { scheduleRefresh(); return }
        if windowRecordsPending { refreshAllSpaces() }
        let pids = dirtyHosts.sorted {
            let lhsActive = activeWorkerPID(for: $0) != nil
            let rhsActive = activeWorkerPID(for: $1) != nil
            return lhsActive == rhsActive ? $0 < $1 : lhsActive
        }
        for pid in pids {
            guard activeScanCount < Self.maximumConcurrentScans else { break }
            guard !inFlight.contains(pid), let application = applicationsByPID[pid] else { continue }
            let worker = ensureWorker(pid: pid, launchDate: application.launchDate, applicationLifetime: application.lifetime)
            dirtyHosts.remove(pid)
            inFlight.insert(pid)
            activeScanCount += 1
            let app = application.withPresentation()
            let invocation = invocationGeneration
            let recordsBeforeScan = allSpacesRecords
            Task { [weak self] in
                defer {
                    if let self {
                        activeScanCount -= 1
                        drainRefreshes()
                    }
                }
                let startedAt = ContinuousClock.now
                let result = await worker.scan()
                guard let self, running, workers[pid] === worker else { return }
                var entries = windowEntries(from: result, app: app, ownerPID: pid)
                var helperUnavailable = false
                var helperFocusIDs: [pid_t: String] = [:]
                var completedHelpers = Set<pid_t>()
                for helperPID in (helperPIDsByHost[pid] ?? []).sorted() {
                    guard let helperApp = applicationsByPID[helperPID] else { continue }
                    let helperWorker = ensureWorker(pid: helperPID, launchDate: helperApp.launchDate,
                                                    applicationLifetime: helperApp.lifetime)
                    let helperScan = await helperWorker.scan()
                    guard running, workers[pid] === worker else { return }
                    guard workers[helperPID] === helperWorker else { continue }
                    if helperScan.unavailable { helperUnavailable = true }
                    helperFocusIDs[helperPID] = helperScan.focusedID
                    completedHelpers.insert(helperPID)
                    entries = WindowSwitcherListing.preferringUniqueWindowNumbers(
                        entries + windowEntries(from: helperScan, app: app, ownerPID: helperPID))
                }
                inFlight.remove(pid)
                let unavailableScan = result.unavailable || helperUnavailable
                if unavailableScan { unavailable.insert(pid) } else { unavailable.remove(pid) }
                unavailableApplicationCount = unavailable.count
                let previous = snapshots[pid]
                let allWorkersRead = (helperPIDsByHost[pid] ?? []).isSubset(of: completedHelpers)
                let previousList = completeWindowLists[pid]
                if !unavailableScan, allWorkersRead {
                    let listReadAt = result.windowListReadAt ?? startedAt
                    let windowServerNumbersAtEmptyRead = entries.isEmpty
                        ? emptyListExclusions(for: pid, readAt: listReadAt, recordsBeforeScan: recordsBeforeScan,
                                              previousList: previousList) : nil
                    completeWindowLists[pid] = .init(startedAt: listReadAt,
                        windowNumbers: Set(entries.compactMap(\.windowNumber)),
                        windowServerNumbersAtEmptyRead: windowServerNumbersAtEmptyRead)
                }
                let completeList = completeWindowLists[pid]
                if !result.windowListReadSucceeded, entries.isEmpty, let previous, !previous.isEmpty {
                    entries = previous.map { var entry = $0; entry.metadataUnavailable = true; return entry }
                } else if entries.isEmpty, !unavailableScan || previous?.isEmpty == false {
                    // Keep app metadata for WindowServer rows even if an incomplete
                    // read could not produce any current AX windows.
                    let application = WindowSwitcherAppEntry(id: "app:\(worker.lifetime)", processIdentifier: pid,
                        bundleIdentifier: app.bundleIdentifier, appName: app.localizedName ?? "App",
                        windowTitle: nil, icon: app.icon, windowElement: nil, isMinimized: false,
                        applicationLaunchDate: app.launchDate, shortcutToken: nil, isHidden: app.isHidden,
                        metadataUnavailable: unavailableScan || !allWorkersRead)
                    entries = [application]
                }
                snapshots[pid] = entries
                let changedWindowListFreshness = windowRecordsStartedAt.map { capturedAt in
                    (previousList.map { $0.startedAt > capturedAt } == true)
                        != (completeList.map { $0.startedAt > capturedAt } == true)
                } ?? false
                if previous != entries || changedWindowListFreshness
                    || previousList?.windowNumbers != completeList?.windowNumbers
                    || previousList?.windowServerNumbersAtEmptyRead != completeList?.windowServerNumbersAtEmptyRead {
                    markPublicationDirty()
                }
                if let activePID = activeWorkerPID(for: pid) {
                    pendingFocus[pid] = (activePID == pid ? result.focusedID : helperFocusIDs[activePID], unavailableScan)
                    markPublicationDirty()
                }
                if invocation == invocationGeneration {
                    invocationRequiredHosts.remove(pid)
                }
                schedulePublication()
            }
        }
        schedulePublication()
    }

    private func activeWorkerPID(for hostPID: pid_t) -> pid_t? {
        if let helperPID = (helperPIDsByHost[hostPID] ?? []).sorted().first(where: {
            applicationsByPID[$0]?.isActive == true
        }) {
            return helperPID
        }
        return applicationsByPID[hostPID]?.isActive == true ? hostPID : nil
    }

    func entries(sortMode: WindowSwitcherSortMode) -> [WindowSwitcherAppEntry] {
        let entries = WindowSwitcherListing.apply(publication.entries, policy: listingPolicy)
        switch sortMode {
        case .recentUse: return publication.recency.sort(entries)
        case .fixed: return entries.sorted {
            let appOrder = $0.appName.localizedCaseInsensitiveCompare($1.appName)
            let order = appOrder == .orderedSame
                ? $0.displayName.localizedCaseInsensitiveCompare($1.displayName) : appOrder
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        }
    }

    private func ensureWorker(pid: pid_t, launchDate: Date?, applicationLifetime: UUID? = nil) -> WindowSwitcherProcessWorker {
        if let existing = workers[pid], existing.launchDate == launchDate,
           existing.applicationLifetime == applicationLifetime { return existing }
        workers.removeValue(forKey: pid)?.stop()
        if processMapping.host(for: pid) == pid {
            snapshots.removeValue(forKey: pid)
            removedProcesses.insert(pid)
            markPublicationDirty()
        }
        inFlight.remove(pid)
        let created = WindowSwitcherProcessWorker(pid: pid, launchDate: launchDate,
            applicationLifetime: applicationLifetime, access: accessFactory(pid)) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, workers[event.processIdentifier]?.lifetime == event.lifetime else { return }
                invalidate(processIdentifiers: [event.processIdentifier], windowRecords: event.kind.requiresWindowRecords)
            }
        }
        workers[pid] = created
        return created
    }

    private func windowEntries(from scan: WindowSwitcherScan, app: Application, ownerPID: pid_t) -> [WindowSwitcherAppEntry] {
        scan.windows.map { window in
            var entry = WindowSwitcherAppEntry(id: window.id, processIdentifier: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier, appName: app.localizedName ?? "App",
                windowTitle: window.title, icon: app.icon, windowElement: window.element,
                isMinimized: window.minimized, windowNumber: window.windowNumber, applicationLaunchDate: app.launchDate, shortcutToken: nil)
            entry.bounds = window.bounds
            entry.isHidden = app.isHidden
            entry.metadataUnavailable = window.unavailable
            entry.windowOwnerPID = ownerPID
            entry.axWorkerPID = ownerPID
            entry.isOnFullscreenSpace = window.isFullscreen
            entry.workerWindowID = window.id
            let display = displayContext(for: window.bounds)
            entry.displayNameContext = display?.name
            entry.displayID = display?.id
            return entry
        }
    }

    private func processWorker(for entry: WindowSwitcherAppEntry) -> WindowSwitcherProcessWorker? {
        // A compositor owner can differ from the process exposing this AX record.
        // Never redirect a recorded AX identity to another worker.
        if let axWorkerPID = entry.axWorkerPID { return workers[axWorkerPID] }
        if entry.windowElement != nil { return workers[entry.processIdentifier] }
        return workers[entry.owningProcessIdentifier] ?? workers[entry.processIdentifier]
    }

    private func rebuildPublication() {
        publication.update(snapshots: snapshots, records: allSpacesRecords, recordsAreFresh: allSpacesRecordsAreFresh, localEntries: hostWindows.entries(),
                           helperProcessIdentifiers: helperPIDsByHost,
                           completeWindowLists: completeWindowLists,
                           recordsStartedAt: windowRecordsStartedAt,
                           displayContext: { self.displayContext(for: $0) })
        if NSApp.isActive, let focusedID = hostWindows.focusedID {
            publication.recency.observeForeground(entries: publication.entries.filter {
                $0.processIdentifier == ProcessInfo.processInfo.processIdentifier
            }, focusedWindowID: focusedID, unavailable: false)
        }
    }

    func opening(sortMode: WindowSwitcherSortMode, deadlineReached: Bool = false) -> WindowSwitcherOpening? {
        publishCompletedUpdates()
        guard isInvocationReady else { return nil }
        let rows = entries(sortMode: sortMode).filter { !$0.isAwaitingWindowConfirmation }
        guard !rows.isEmpty else { return nil }
        let focus = rows.contains { $0.id == focusedWindowID } ? focusedWindowID : nil
        return WindowSwitcherOpening(entries: rows, focusedWindowID: focus)
    }

    private func markPublicationDirty() {
        publicationDirty = true
        schedulePublication()
    }

    private func publishWindowRows() {
        guard publicationDirty else { return }
        publicationDirty = false
        for pid in removedProcesses { publication.removeProcess(pid) }
        removedProcesses.removeAll()
        rebuildPublication()
    }

    private func publishCompletedUpdates() {
        publishWindowRows()
        for (pid, focus) in pendingFocus where activeWorkerPID(for: pid) != nil {
            let entries = publication.entries.filter { $0.processIdentifier == pid }
            let id = entries.first { ($0.workerWindowID ?? $0.id) == focus.id }?.id
            publication.recency.observeForeground(entries: entries, focusedWindowID: id, unavailable: focus.unavailable)
        }
        pendingFocus.removeAll()
        isInitialDiscoveryComplete = didReadAllSpaces && expectedHostPIDs.allSatisfy { snapshots[$0] != nil }
        isInvocationReady = isInitialDiscoveryComplete && !invocationRequiresRecords && invocationRequiredHosts.isEmpty
    }

    private func schedulePublication() {
        guard running, publicationTask == nil else { return }
        publicationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard !Task.isCancelled, let self, running else { return }
            publicationTask = nil
            let oldEntries = publication.entries
            let oldFocus = focusedWindowID
            let wasComplete = isInitialDiscoveryComplete
            let wasReady = isInvocationReady
            publishCompletedUpdates()
            if oldEntries != publication.entries || oldFocus != focusedWindowID
                || wasComplete != isInitialDiscoveryComplete || wasReady != isInvocationReady {
                onChange?()
            }
        }
    }

    private func refreshAllSpaces() {
        guard allSpacesRefreshTask == nil else { return }
        windowRecordsPending = false
        let generation = allSpacesGeneration
        let invocation = invocationGeneration
        allSpacesRefreshTask = Task { [weak self] in
            guard let self else { return }
            let result = await allSpacesCatalog.freshWindowRecordSnapshot()
            guard !Task.isCancelled, running, allSpacesGeneration == generation else { return }
            allSpacesRefreshTask = nil
            let oldRecords = Dictionary(grouping: allSpacesRecords, by: \.processIdentifier)
            let newRecords = Dictionary(grouping: result.records, by: \.processIdentifier)
            let changedOwners = Set(oldRecords.keys).union(newRecords.keys).filter {
                oldRecords[$0]?.sorted { $0.windowNumber < $1.windowNumber }
                    != newRecords[$0]?.sorted { $0.windowNumber < $1.windowNumber }
            }
            let oldHelpers = helperPIDsByHost
            let capturedAt = result.startedAt ?? windowRecordsStartedAt
            if let startedAt = result.startedAt {
                // An older capture can finish after the AX list read. A newer
                // capture can only retire exclusions for that read.
                let recordsByHost = Dictionary(grouping: result.records) { processMapping.host(for: $0.processIdentifier) }
                for (pid, list) in completeWindowLists {
                    guard let numbersAtEmptyRead = list.windowServerNumbersAtEmptyRead else { continue }
                    let captured = recordsByHost[pid, default: []]
                    completeWindowLists[pid]?.windowServerNumbersAtEmptyRead = startedAt <= list.startedAt
                        ? numbersAtEmptyRead.union(captured.lazy.filter(Self.canBeExcludedByEmptyAXRead).map(\.windowNumber))
                        : numbersAtEmptyRead.intersection(captured.lazy.filter { $0.isOnActiveSpace != false }.map(\.windowNumber))
                }
            }
            let windowListsChangedFreshness = completeWindowLists.values.contains { list in
                (windowRecordsStartedAt.map { $0 < list.startedAt } == true) != (capturedAt.map { $0 < list.startedAt } == true)
            }
            let pendingWindowEvidenceChanged = result.startedAt.map {
                publication.hasNewPendingWindowEvidence(from: windowRecordsStartedAt, to: $0)
            } == true
            if allSpacesRecords != result.records || allSpacesRecordsAreFresh != result.isFresh
                || windowListsChangedFreshness || pendingWindowEvidenceChanged {
                markPublicationDirty()
            }
            allSpacesRecords = result.records
            helperPIDsByHost = processMapping.helpersByHost(owningWindowsIn: allSpacesRecords)
            allSpacesRecordsAreFresh = result.isFresh
            windowRecordsStartedAt = capturedAt
            if oldHelpers != helperPIDsByHost { reloadApplications() }
            // New helper ownership and missing AX events must schedule a scoped
            // scan, including when another read of that host is already active.
            for pid in expectedHostPIDs {
                let changed = changedOwners.contains { processMapping.host(for: $0) == pid }
                if oldHelpers[pid] != helperPIDsByHost[pid] || (changed && snapshots[pid] != nil) {
                    dirtyHosts.insert(pid)
                }
            }
            didReadAllSpaces = true
            if invocation == invocationGeneration { invocationRequiresRecords = false }
            if !isInvocationReady { invocationRequiredHosts.formUnion(dirtyHosts) }
            schedulePublication()
            drainRefreshes()
        }
    }

    private func emptyListExclusions(for pid: pid_t, readAt: ContinuousClock.Instant,
                                     recordsBeforeScan: [WindowSwitcherWindowRecord],
                                     previousList: WindowSwitcherPublishedWindows.CompleteWindowList?) -> Set<CGWindowID> {
        let captureFollowsRead = windowRecordsStartedAt.map { $0 > readAt } == true
        let recordsAtRead = captureFollowsRead ? recordsBeforeScan : allSpacesRecords
        var excluded = Set(recordsAtRead.lazy.filter {
            self.processMapping.host(for: $0.processIdentifier) == pid && Self.canBeExcludedByEmptyAXRead($0)
        }.map(\.windowNumber))
        // AX can already identify a closed window before WindowServer has
        // provided its first usable capture.
        excluded.formUnion(previousList?.windowNumbers ?? [])
        excluded.formUnion(previousList?.windowServerNumbersAtEmptyRead ?? [])
        excluded.subtract(allSpacesRecords.lazy.filter {
            self.processMapping.host(for: $0.processIdentifier) == pid && $0.isOnActiveSpace == false
        }.map(\.windowNumber))
        guard captureFollowsRead else { return excluded }
        return excluded.intersection(allSpacesRecords.lazy.filter {
            self.processMapping.host(for: $0.processIdentifier) == pid && $0.isOnActiveSpace != false
        }.map(\.windowNumber))
    }

    private static func canBeExcludedByEmptyAXRead(_ record: WindowSwitcherWindowRecord) -> Bool {
        record.isOnActiveSpace != false
            && (record.isOnScreen == true || (record.isOnScreen == nil && record.hasSpace != true))
    }

    /// Only confirmed system IDs link AX and CG identities. Geometry/title
    /// guesses remain preview-only and must never rename a row or route actions.
    static func mergeAllSpacesEntries(_ entries: [WindowSwitcherAppEntry], records: [WindowSwitcherWindowRecord],
                                      knownWindowIDs: [CGWindowID: String] = [:],
                                      confirmedAXWindowNumbers: Set<CGWindowID> = [],
                                      windowNumbersExcludedByEmptyAXList: Set<CGWindowID> = [],
                                      helperProcessIdentifiers: Set<pid_t> = [],
                                      unconfirmedWindowNumbers: Set<CGWindowID> = []) -> [WindowSwitcherAppEntry] {
        guard let application = entries.first else { return entries }
        let hostPID = application.processIdentifier
        let records = records.filter { $0.processIdentifier == hostPID || helperProcessIdentifiers.contains($0.processIdentifier) }
        let recordsByNumber = Dictionary(records.map { ($0.windowNumber, $0) }, uniquingKeysWith: { first, _ in first })
        var claimed = Set<CGWindowID>()
        let windows = entries.filter { $0.windowElement != nil }.compactMap { entry -> WindowSwitcherAppEntry? in
            var window = entry
            window.workerWindowID = entry.workerWindowID ?? entry.id
            if let number = entry.windowNumber {
                // Multiple AX aliases for one system window are one row.
                guard claimed.insert(number).inserted else { return nil }
                if let knownID = knownWindowIDs[number] { window.id = knownID }
                if let record = recordsByNumber[number] {
                    // AX can expose titleless compositor surfaces as ordinary
                    // windows. A WindowServer record with no Space and no
                    // on-screen presence confirms that this is not a window
                    // the user can switch to. Keep minimized windows, whose
                    // Space membership may be absent while they are restored.
                    let hasTitle = window.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    if !window.isMinimized,
                       !hasTitle,
                       record.hasSpace == false, record.isOnScreen != true {
                        return nil
                    }
                    window.windowOwnerPID = record.processIdentifier
                    window.isOnOtherDesktop = record.isOnActiveSpace == false
                    window.isOnFullscreenSpace = window.isOnFullscreenSpace || record.isOnFullscreenSpace == true
                }
            }
            return window
        }
        let fallback = records.compactMap { record -> WindowSwitcherAppEntry? in
            guard !claimed.contains(record.windowNumber) else { return nil }
            // A complete empty AX scan rules out current-Space window rows.
            // WindowServer may still retain named surfaces after the last window
            // closes. Retain previously known rows while Space evidence catches up.
            let awaitingConfirmation = unconfirmedWindowNumbers.contains(record.windowNumber)
            guard !windowNumbersExcludedByEmptyAXList.contains(record.windowNumber) || awaitingConfirmation || record.isOnScreen == false
                    || (record.isOnScreen == nil && record.hasSpace == true) else { return nil }
            // Unknown Space membership is not proof that a newly discovered
            // off-screen surface is a window. Previously AX-confirmed windows
            // may survive a missing Space query, but not a confirmed removal.
            guard record.isOnScreen == true || record.hasSpace == true
                || (record.hasSpace == nil && confirmedAXWindowNumbers.contains(record.windowNumber)) else { return nil }
            // Do not replace usable AX windows with ambiguous CG duplicates.
            guard !windows.contains(where: { $0.windowNumber == nil && sameBounds($0.bounds, record.bounds) }) else { return nil }
            // Missing title metadata (for example without Screen Recording)
            // must not hide otherwise valid off-Space candidates. Explicitly
            // empty titles still require AX confirmation to exclude helper surfaces.
            let unavailableOffSpaceTitle = !record.titleIsAvailable
                && record.isOnScreen != true && record.hasSpace == true
            guard confirmedAXWindowNumbers.contains(record.windowNumber)
                || !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || unavailableOffSpaceTitle else { return nil }
            var fallbackEntry = WindowSwitcherAppEntry(id: knownWindowIDs[record.windowNumber] ?? "window:cg:\(application.processIdentifier):\(application.applicationLaunchDate.map { String($0.timeIntervalSince1970) } ?? application.id):\(record.windowNumber)",
                processIdentifier: application.processIdentifier, bundleIdentifier: application.bundleIdentifier,
                appName: application.appName, windowTitle: record.titleIsAvailable ? record.title : nil, icon: application.icon,
                windowElement: nil, isMinimized: false, windowNumber: record.windowNumber,
                windowBounds: record.bounds, applicationLaunchDate: application.applicationLaunchDate,
                shortcutToken: nil, bounds: record.bounds, isHidden: application.isHidden)
            fallbackEntry.windowOwnerPID = record.processIdentifier
            fallbackEntry.isOnOtherDesktop = record.isOnActiveSpace == false
            fallbackEntry.isOnFullscreenSpace = record.isOnFullscreenSpace == true
            return fallbackEntry
        }
        return windows + fallback
    }

    static func sameBounds(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2 &&
            abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
    }

    static func matchingFallbackWindowID(_ entry: WindowSwitcherAppEntry, windows: [WindowSwitcherWindowSnapshot],
                                         records: [WindowSwitcherWindowRecord] = [], expectedElement: AXUIElement? = nil) -> String? {
        let available = windows.filter { window in
            !window.unavailable && expectedElement.map { CFEqual($0, window.element) } != false
        }
        if let number = entry.windowNumber {
            let candidates = available.map {
                WindowSwitcherAppEntry(id: $0.id, processIdentifier: entry.processIdentifier,
                    bundleIdentifier: entry.bundleIdentifier, appName: entry.appName, windowTitle: $0.title,
                    icon: nil, windowElement: $0.element, isMinimized: $0.minimized,
                    windowNumber: $0.windowNumber, shortcutToken: nil, bounds: $0.bounds)
            }
            let exact = mergeAllSpacesEntries(candidates, records: records).filter {
                $0.windowElement != nil && $0.windowNumber == number
            }
            return exact.count == 1 ? exact[0].id : nil
        }
        let geometry = available.filter { sameBounds($0.bounds, entry.bounds) }
        if geometry.count == 1 { return geometry[0].id }
        let titled = geometry.filter { entry.windowTitle?.isEmpty == false && $0.title == entry.windowTitle }
        return titled.count == 1 ? titled[0].id : nil
    }

    /// Wait for Space transitions by observing fresh state, never replaying the
    /// app activation or choosing an arbitrary same-title window.
    static func waitForFallbackWindow(_ entry: WindowSwitcherAppEntry,
                                      expectedElement: AXUIElement? = nil,
                                      timeout: Duration = .seconds(1.2),
                                      scan: () async -> WindowSwitcherScan,
                                      records: () async -> [WindowSwitcherWindowRecord]) async -> String? {
        let deadline = ContinuousClock.now + timeout
        repeat {
            guard !Task.isCancelled else { return nil }
            let snapshot = await scan()
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            let currentRecords = await records()
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            if snapshot.windowListReadSucceeded,
               let id = matchingFallbackWindowID(entry, windows: snapshot.windows, records: currentRecords,
                                                 expectedElement: expectedElement) { return id }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(60))
        } while true
    }

    private func currentEntry(matching entry: WindowSwitcherAppEntry) -> WindowSwitcherAppEntry? {
        entries(sortMode: .fixed).first { $0.id == entry.id }
    }

    func canActivate(_ entry: WindowSwitcherAppEntry) -> Bool {
        // The open chooser may still hold the row from before it became pending.
        currentEntry(matching: entry)?.isAwaitingWindowConfirmation == false
    }

    func activate(_ entry: WindowSwitcherAppEntry, intent: WindowSwitcherActivationIntent) async -> WindowSwitcherActionResult {
        guard intent.shouldContinue() else { return .cancelled }
        if entry.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            let result = await hostWindows.activate(entry, intent: intent)
            if result == .succeeded { publication.recency.record(entry.id) }
            refresh()
            return result
        }
        guard canActivate(entry),
              let worker = processWorker(for: entry),
              let app = NSRunningApplication(processIdentifier: entry.processIdentifier), !app.isTerminated else { return .unavailable }
        let expectedElement = entry.windowElement ?? publication.retainedAXElement(for: entry)
        var isFallback = entry.windowElement == nil && entry.windowNumber != nil
        guard entry.applicationLaunchDate == nil || app.launchDate == nil || entry.applicationLaunchDate == app.launchDate else { return .unavailable }
        let isValid: Bool
        if isFallback {
            isValid = await allSpacesCatalog.isCurrentFallback(entry)
        } else if entry.isWindowEntry {
            let live = await worker.validate(entry.workerWindowID ?? entry.id)
            // Some apps omit other-Space windows from AXWindows. A fresh exact
            // WindowServer record can authorize reveal, followed by AX reacquisition.
            if !live, entry.windowNumber != nil {
                isFallback = true
                isValid = await allSpacesCatalog.isCurrentFallback(entry)
            } else {
                isValid = live
            }
        } else {
            isValid = true
        }
        guard intent.shouldContinue() else { return .cancelled }
        guard isValid, processWorker(for: entry) === worker else { return .unavailable }
        let ownerPID = entry.owningProcessIdentifier
        // A minimized window on the active or an unknown Space needs ordinary
        // AX restoration. An explicitly other-Space target still needs the
        // exact path, which restores it before switching to that Space.
        let needsExactReveal = isFallback || Self.needsExactSpaceReveal(entry, records: allSpacesRecords)
        let resolved: WindowSwitcherResolvedWindow?
        if needsExactReveal, WindowSwitcherWindowServer.supportsExactActivation, let number = entry.windowNumber {
            resolved = await worker.resolveOffSpaceWindow(number, ownerPID: ownerPID, cancellation: intent.cancellation)
        } else { resolved = nil }
        guard intent.shouldContinue(), processWorker(for: entry) === worker, !app.isTerminated else { return .cancelled }
        guard canActivate(entry) else { return .unavailable }
        if let resolved {
            guard expectedElement.map({ CFEqual($0, resolved.element) }) != false else { return .unavailable }
            if app.isHidden {
                _ = app.unhide()
                let deadline = ContinuousClock.now + .seconds(1)
                while app.isHidden && ContinuousClock.now < deadline {
                    guard intent.shouldContinue(), !app.isTerminated else { return .cancelled }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            guard intent.shouldContinue(), !app.isTerminated, !app.isHidden else { return .cancelled }
            guard canActivate(entry) else { return .unavailable }
            let result = await worker.focusOffSpaceWindow(resolved, cancellation: intent.cancellation)
            guard intent.shouldContinue() else { return .cancelled }
            let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.processIdentifier
            if result == .succeeded && isFrontmost { publication.recency.record(entry.id) }
            refresh()
            return result == .succeeded && !isFrontmost ? .failed : result
        }
        let prepared = await WindowSwitcherApplicationActivation.prepare(state: {
            .init(isHidden: app.isHidden,
                  isFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.processIdentifier,
                  isTerminated: app.isTerminated || self.processWorker(for: entry) !== worker)
        }, request: { request in
            guard intent.shouldContinue() else { return }
            switch request {
            case .unhide: _ = app.unhide()
            case .activate:
                if needsExactReveal, expectedElement == nil, let number = entry.windowNumber,
                   WindowSwitcherWindowServer.activate(number, pid: ownerPID, cancellation: intent.cancellation) { return }
                NSApp.yieldActivation(to: app)
                if isFallback {
                    // Public fallback when the optional exact-window bridge is unavailable.
                    _ = app.activate(options: [.activateAllWindows])
                    return
                }
                // Native activation is a request, not a guarantee. Its observed
                // outcome controls the one-shot alternate path below.
                _ = app.activate(options: [])
            }
        }, activateAllSpaces: needsExactReveal, fallbackRequest: {
            guard intent.shouldContinue() else { return }
            _ = await worker.requestApplicationActivation(cancellation: intent.cancellation)
        }, shouldContinue: {
            intent.shouldContinue()
        })
        guard prepared == .succeeded else { return prepared }
        if !entry.isWindowEntry {
            publication.recency.record(entry.id)
            refresh()
            return .succeeded
        }
        let cancellation = intent.cancellation
        let targetPID = entry.processIdentifier
        let targetID: String
        if isFallback {
            // Re-read after the owning app switches Spaces. Never choose one of
            // several same-title/geometry candidates or replay activation.
            guard let matchedID = await Self.waitForFallbackWindow(entry, expectedElement: expectedElement, scan: { await worker.scan() },
                records: { await self.allSpacesCatalog.freshRecordsForActivation() }) else {
                return intent.shouldContinue() ? .unavailable : .cancelled
            }
            guard self.processWorker(for: entry) === worker, !Task.isCancelled else { return .cancelled }
            targetID = matchedID
        } else {
            targetID = entry.workerWindowID ?? entry.id
        }
        guard intent.shouldContinue(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return .cancelled }
        guard canActivate(entry) else { return .unavailable }
        let result = await worker.perform(targetID, close: false, cancellation: cancellation)
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.processIdentifier
        if result == .succeeded && isFrontmost { publication.recency.record(entry.id) }
        refresh()
        return result == .succeeded && !isFrontmost ? .failed : result
    }

    static func needsExactSpaceReveal(
        _ entry: WindowSwitcherAppEntry,
        records: [WindowSwitcherWindowRecord]
    ) -> Bool {
        return records.contains {
            let matches = $0.windowNumber == entry.windowNumber
                && ($0.processIdentifier == entry.processIdentifier
                    || $0.processIdentifier == entry.owningProcessIdentifier)
                && $0.isOnScreen != true && $0.hasSpace == true
            guard matches else { return false }
            return !entry.isMinimized || $0.isOnActiveSpace == false
        }
    }

    func closeWindow(_ entry: WindowSwitcherAppEntry) async -> WindowSwitcherActionResult {
        if entry.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            let result = hostWindows.close(entry)
            refresh()
            return result
        }
        guard let target = confirmedCloseTarget(matching: entry),
              let worker = processWorker(for: target) else { return .unavailable }
        let targetID: String
        if let element = target.windowElement {
            if let originalElement = entry.windowElement {
                guard CFEqual(originalElement, element) else { return .unavailable }
                targetID = target.workerWindowID ?? target.id
            } else {
                // The menu may still hold a WindowServer-only row. Validate
                // that row before using the Accessibility handle found later.
                guard entry.windowNumber == target.windowNumber,
                      await allSpacesCatalog.isCurrentFallback(entry),
                      let current = confirmedCloseTarget(matching: entry),
                      current.windowNumber == entry.windowNumber, processWorker(for: current) === worker,
                      let currentElement = current.windowElement, CFEqual(currentElement, element) else { return .unavailable }
                targetID = current.workerWindowID ?? current.id
            }
        } else {
            let previousElement = publication.retainedAXElement(for: target)
            let fallback = entry.windowElement == nil ? entry : target
            guard fallback.windowNumber == target.windowNumber,
                  await allSpacesCatalog.isCurrentFallback(fallback) else { return .unavailable }
            let scan = await worker.scan()
            guard scan.windowListReadSucceeded,
                  let matchedID = Self.matchingFallbackWindowID(target, windows: scan.windows, records: allSpacesRecords),
                  let matchedWindow = scan.windows.first(where: { $0.id == matchedID }),
                  let current = confirmedCloseTarget(matching: target), current.windowNumber == target.windowNumber,
                  processWorker(for: current) === worker else { return .unavailable }
            // A reused WindowServer number cannot override a known AX identity.
            let currentElement = current.windowElement ?? publication.retainedAXElement(for: current)
            guard entry.windowElement.map({ CFEqual($0, matchedWindow.element) }) != false,
                  previousElement.map({ CFEqual($0, matchedWindow.element) }) != false,
                  currentElement.map({ CFEqual($0, matchedWindow.element) }) != false else { return .unavailable }
            targetID = matchedWindow.id
        }
        let result = await worker.perform(targetID, close: true)
        refresh()
        return result
    }

    private func confirmedCloseTarget(matching entry: WindowSwitcherAppEntry) -> WindowSwitcherAppEntry? {
        guard let current = currentEntry(matching: entry), current.processIdentifier == entry.processIdentifier,
              current.isWindowEntry, !current.isAwaitingWindowConfirmation,
              current.windowElement != nil || !current.metadataUnavailable else { return nil }
        return current
    }

    func quitApplication(_ entry: WindowSwitcherAppEntry) -> WindowSwitcherActionResult {
        guard currentEntry(matching: entry) != nil,
              let app = NSRunningApplication(processIdentifier: entry.processIdentifier), !app.isTerminated else { return .unavailable }
        guard entry.applicationLaunchDate == nil || app.launchDate == nil || entry.applicationLaunchDate == app.launchDate else { return .unavailable }
        let requested = app.terminate()
        refresh()
        return requested ? .requested : .failed
    }

    private func displayContext(for bounds: CGRect) -> (id: UInt32, name: String)? {
        // AX uses a top-left origin. Convert screens without treating an offscreen
        // window as belonging to another Space; public AX exposes no Space ID.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.max { lhs, rhs in
            func area(_ screen: NSScreen) -> CGFloat {
                let r = CGRect(x: screen.frame.minX, y: top - screen.frame.maxY,
                               width: screen.frame.width, height: screen.frame.height).intersection(bounds)
                return r.isNull ? 0 : r.width * r.height
            }
            return area(lhs) < area(rhs)
        }.flatMap { screen in
            let rect = CGRect(x: screen.frame.minX, y: top - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
            guard rect.intersects(bounds),
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.localizedName)
        }
    }
}
