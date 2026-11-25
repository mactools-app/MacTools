import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol WindowSwitcherCatalog: AnyObject {
    var onChange: (() -> Void)? { get set }
    var focusedWindowID: String? { get }
    var isInitialDiscoveryComplete: Bool { get }
    var isInvocationReady: Bool { get }
    var listingPolicy: WindowSwitcherListingPolicy { get set }
    func start()
    func stop()
    func refresh()
    func prepareForInvocation()
    func cancelInvocation()
    func entries(sortMode: WindowSwitcherSortMode) -> [WindowSwitcherAppEntry]
    func activate(_ entry: WindowSwitcherAppEntry, intent: WindowSwitcherActivationIntent) async -> WindowSwitcherActionResult
    func closeWindow(_ entry: WindowSwitcherAppEntry) async -> WindowSwitcherActionResult
    func quitApplication(_ entry: WindowSwitcherAppEntry) -> WindowSwitcherActionResult
}

extension WindowSwitcherCatalog {
    var isInvocationReady: Bool { isInitialDiscoveryComplete }
    func prepareForInvocation() { refresh() }
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
        var isFinishedLaunching = true
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
        var foregroundProcessIdentifier: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var isAccessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
        var isDragging: () -> Bool = { CGEventSource.buttonState(.combinedSessionState, button: .left) }
    }

    private struct FocusObservation {
        let workerPID: pid_t
        let id: String?
        let windowNumber: CGWindowID?
        let unavailable: Bool
        let reportedFocusedWindow: Bool
        var canInfer: Bool { !unavailable && !reportedFocusedWindow }

        init(workerPID: pid_t, scan: WindowSwitcherScan) {
            self.workerPID = workerPID
            id = scan.focusedID
            windowNumber = scan.focusedID.flatMap { id in scan.windows.first { $0.id == id }?.windowNumber }
            unavailable = scan.unavailable
            reportedFocusedWindow = scan.reportedFocusedWindow
        }
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
    private var excludedWindowNumbersByHost: [pid_t: Set<CGWindowID>] = [:]
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
    private var pendingFocus: [pid_t: [pid_t: FocusObservation]] = [:]
    private var inferredFocusWorkerLifetime: UUID?
    private var windowRecordsPending = false
    private var sleeping = false
    private var sessionInactive = false
    private var suspended: Bool { sleeping || sessionInactive }
    private var invocationGeneration = UUID()
    private var invocationInProgress = false
    private var invocationForegroundPID: pid_t?
    private var invocationCanRescanForeground = false
    private var invocationRequiredHosts: Set<pid_t> = []
    private var invocationScansStarted: Set<pid_t> = []
    private var queuedInvocationRetryHost: pid_t?
    private var invocationRequiresRecords = false
    private var invocationCanRetryForegroundDiscovery = false
    private var invocationRetryTask: Task<Void, Never>?
    private let allSpacesCatalog: WindowSwitcherWindowRecords
    private let discovery: DiscoveryEnvironment
    private var publication = WindowSwitcherPublishedWindows()
    private let hostWindows = WindowSwitcherHostWindows()
    private var allSpacesRecordsAreFresh = false
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
        inferredFocusWorkerLifetime = nil
        applicationInventory?.stop()
        allSpacesGeneration = UUID()
        resetInvocation()
        isInvocationReady = false
        windowRecordsPending = false
        allSpacesRefreshTask?.cancel(); allSpacesRefreshTask = nil
        allSpacesCatalog.stop()
        allSpacesRecords.removeAll()
        publication = WindowSwitcherPublishedWindows()
        hostWindows.reset()
        allSpacesRecordsAreFresh = false
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
        excludedWindowNumbersByHost.removeAll()
        unavailableApplicationCount = 0
    }

    /// Coalesces events by owner. A dirty host remains queued when a scan is in
    /// flight, so changes arriving during that scan get one follow-up read.
    func invalidate(processIdentifiers: Set<pid_t>, windowRecords: Bool) {
        guard running else { return }
        pendingInvalidations.formUnion(processIdentifiers.map { processMapping.host(for: $0) }.filter { expectedHostPIDs.contains($0) })
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

    func prepareForInvocation() {
        guard running else { return }
        resetInvocation()
        invocationInProgress = true
        invocationForegroundPID = discovery.foregroundProcessIdentifier()
        invocationCanRescanForeground = true
        isInvocationReady = false
        pendingFocus.removeAll()
        inferredFocusWorkerLifetime = nil
        publication.recency.clearInference()
        reloadForegroundApplication(invocationForegroundPID)
        applyInvalidations()
        invocationRequiredHosts = expectedHostPIDs
        invocationRequiresRecords = true
        invocationCanRetryForegroundDiscovery = true
        dirtyHosts.formUnion(expectedHostPIDs)
        windowRecordsPending = true
        markPublicationDirty()
        drainRefreshes()
    }

    func cancelInvocation() {
        guard invocationInProgress else { return }
        resetInvocation()
        pendingFocus.removeAll()
        applyInvalidations()
        drainRefreshes()
    }

    private func resetInvocation() {
        invocationGeneration = UUID()
        invocationInProgress = false
        invocationForegroundPID = nil
        invocationCanRescanForeground = false
        invocationRequiredHosts.removeAll()
        invocationScansStarted.removeAll()
        queuedInvocationRetryHost = nil
        invocationRequiresRecords = false
        invocationCanRetryForegroundDiscovery = false
        invocationRetryTask?.cancel()
        invocationRetryTask = nil
    }

    private func reloadForegroundApplication(_ pid: pid_t?) {
        applicationInventory?.reconcile(notify: false)
        if let pid { applicationInventory?.reload(processIdentifier: pid, notify: false) }
        reloadApplications()
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
                excludedWindowNumbersByHost.removeValue(forKey: pid)
                pendingFocus.removeValue(forKey: pid)
                removedProcesses.insert(pid)
                dirtyHosts.insert(oldMapping.host(for: pid))
                markPublicationDirty()
                continue
            }
        }
        for pid in Array(snapshots.keys) where !expectedHostPIDs.contains(pid) {
            snapshots.removeValue(forKey: pid)
            excludedWindowNumbersByHost.removeValue(forKey: pid)
            removedProcesses.insert(pid)
            markPublicationDirty()
        }
        dirtyHosts.formIntersection(expectedHostPIDs)
        invocationRequiredHosts.formIntersection(expectedHostPIDs)
        invocationScansStarted.formIntersection(expectedHostPIDs)
        if let queuedInvocationRetryHost, !expectedHostPIDs.contains(queuedInvocationRetryHost) {
            self.queuedInvocationRetryHost = nil
        }
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
        // Finish publishing the invocation's visibility snapshot before
        // servicing any refreshes queued behind it.
        if windowRecordsPending, !invocationInProgress || invocationRequiresRecords {
            refreshAllSpaces()
        }
        let foregroundHostPID = foregroundTarget()?.hostPID
        let pids = dirtyHosts.sorted {
            let lhsActive = $0 == foregroundHostPID
            let rhsActive = $1 == foregroundHostPID
            return lhsActive == rhsActive ? $0 < $1 : lhsActive
        }
        for pid in pids {
            guard activeScanCount < Self.maximumConcurrentScans else { break }
            guard !inFlight.contains(pid), let application = applicationsByPID[pid] else { continue }
            let worker = ensureWorker(pid: pid, launchDate: application.launchDate, applicationLifetime: application.lifetime)
            dirtyHosts.remove(pid)
            if invocationInProgress { invocationScansStarted.insert(pid) }
            if queuedInvocationRetryHost == pid {
                queuedInvocationRetryHost = nil
                pendingInvalidations.remove(pid)
            }
            inFlight.insert(pid)
            activeScanCount += 1
            let app = application.withPresentation()
            let invocation = invocationGeneration
            Task { [weak self] in
                defer {
                    if let self {
                        activeScanCount -= 1
                        drainRefreshes()
                    }
                }
                let result = await worker.scan()
                guard let self, running, workers[pid] === worker else { return }
                var entries = windowEntries(from: result, app: app, ownerPID: pid)
                var excludedWindowNumbers = result.excludedWindowNumbers
                var helperUnavailable = false
                var focusObservations = [pid: FocusObservation(workerPID: pid, scan: result)]
                for helperPID in (helperPIDsByHost[pid] ?? []).sorted() {
                    guard let helperApp = applicationsByPID[helperPID] else { continue }
                    let helperWorker = ensureWorker(pid: helperPID, launchDate: helperApp.launchDate,
                                                    applicationLifetime: helperApp.lifetime)
                    let helperScan = await helperWorker.scan()
                    guard running, workers[pid] === worker else { return }
                    guard workers[helperPID] === helperWorker else { continue }
                    if helperScan.unavailable { helperUnavailable = true }
                    focusObservations[helperPID] = FocusObservation(workerPID: helperPID, scan: helperScan)
                    excludedWindowNumbers.formUnion(helperScan.excludedWindowNumbers)
                    entries = WindowSwitcherListing.preferringUniqueWindowNumbers(
                        entries + windowEntries(from: helperScan, app: app, ownerPID: helperPID))
                }
                inFlight.remove(pid)
                let unavailableScan = result.unavailable || helperUnavailable
                if unavailableScan { unavailable.insert(pid) } else { unavailable.remove(pid) }
                unavailableApplicationCount = unavailable.count
                let previous = snapshots[pid]
                // A failed read is never evidence of a windowless application.
                if entries.isEmpty && !unavailableScan {
                    entries = [WindowSwitcherAppEntry(id: "app:\(worker.lifetime)", processIdentifier: pid,
                        bundleIdentifier: app.bundleIdentifier, appName: app.localizedName ?? "App",
                        windowTitle: nil, icon: app.icon, windowElement: nil, isMinimized: false,
                        applicationLaunchDate: app.launchDate, shortcutToken: nil, isHidden: app.isHidden)]
                }
                if !result.windowListReadSucceeded, entries.isEmpty, let previous {
                    entries = previous.map { var entry = $0; entry.metadataUnavailable = true; return entry }
                }
                snapshots[pid] = entries
                excludedWindowNumbersByHost[pid] = excludedWindowNumbers
                if previous != entries { markPublicationDirty() }
                if invocation == invocationGeneration, queuedInvocationRetryHost != pid {
                    invocationRequiredHosts.remove(pid)
                    if let target = foregroundTarget(), target.hostPID == pid {
                        pendingFocus[pid] = focusObservations
                    }
                }
                schedulePublication()
            }
        }
        schedulePublication()
    }

    private func foregroundTarget() -> (hostPID: pid_t, workerPID: pid_t)? {
        guard let foregroundPID = discovery.foregroundProcessIdentifier() else { return nil }
        let hostPID = processMapping.host(for: foregroundPID)
        guard expectedHostPIDs.contains(hostPID),
              foregroundPID == hostPID || helperPIDsByHost[hostPID]?.contains(foregroundPID) == true else { return nil }
        return (hostPID, foregroundPID)
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
                           displayContext: { self.displayContext(for: $0) })
        if NSApp.isActive, let focusedID = hostWindows.focusedID {
            publication.recency.observeForeground(entries: publication.entries.filter {
                $0.processIdentifier == ProcessInfo.processInfo.processIdentifier
            }, focusedWindowID: focusedID, unavailable: false)
        }
    }

    private func inferredForegroundWindowID(in entries: [WindowSwitcherAppEntry],
                                           target: (hostPID: pid_t, workerPID: pid_t)) -> String? {
        guard allSpacesRecordsAreFresh, !entries.isEmpty else { return nil }
        let onscreenWindowNumbers = foregroundOnscreenWindowNumbers(target: target)
        guard !hasUnresolvedOnscreenWindow(onscreenWindowNumbers, in: entries) else { return nil }
        // A fresh WindowServer snapshot can distinguish a visible window from
        // windows that are still restoring or live on other Spaces.
        let screenVisibility = Dictionary(allSpacesRecords.compactMap { record in
            record.isOnScreen.map { (record.windowNumber, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let excluded = excludedWindowNumbersByHost[target.hostPID] ?? []
        let candidates = entries.filter { entry in
            (entry.axWorkerPID == target.workerPID || entry.owningProcessIdentifier == target.workerPID)
                && isUsableWindow(entry)
                && !publication.lostAXConfirmation(entry)
                && (entry.windowElement != nil || entry.windowNumber.map(excluded.contains) != true)
                && entry.windowNumber.flatMap { screenVisibility[$0] } != false
        }
        if candidates.count == 1 { return candidates.first?.id }
        let onscreen = candidates.filter { $0.windowNumber.flatMap { screenVisibility[$0] } == true }
        return onscreen.count == 1 ? onscreen.first?.id : nil
    }

    private func isUsableWindow(_ entry: WindowSwitcherAppEntry) -> Bool {
        entry.isWindowEntry && !entry.isHidden && !entry.isMinimized
            && !entry.isOnOtherDesktop && !entry.metadataUnavailable
    }

    private func foregroundOnscreenWindowNumbers(target: (hostPID: pid_t, workerPID: pid_t)) -> Set<CGWindowID> {
        let ownerPIDs = target.workerPID == target.hostPID
            ? (helperPIDsByHost[target.hostPID] ?? []).union([target.workerPID])
            : [target.workerPID]
        return Set(allSpacesRecords.lazy.filter {
            $0.isOnScreen == true && $0.isOnActiveSpace != false && ownerPIDs.contains($0.processIdentifier)
        }.map(\.windowNumber)).subtracting(excludedWindowNumbersByHost[target.hostPID] ?? [])
    }

    private func hasUnresolvedOnscreenWindow(_ onscreen: Set<CGWindowID>, in entries: [WindowSwitcherAppEntry],
                                             requiresAXConfirmation: Bool = false) -> Bool {
        let listed = Set(entries.filter { entry in
            isUsableWindow(entry) && (entry.windowElement != nil
                || (!requiresAXConfirmation && !publication.lostAXConfirmation(entry)))
        }.compactMap(\.windowNumber))
        return !onscreen.isSubset(of: listed)
    }

    private func exactWindowID(for focus: FocusObservation, in entries: [WindowSwitcherAppEntry]) -> String? {
        // Deduplication can keep the host's AX row for a helper-owned window.
        entries.first { entry in
            (entry.workerWindowID ?? entry.id) == focus.id
                || (entry.owningProcessIdentifier == focus.workerPID
                    && focus.windowNumber != nil && entry.windowNumber == focus.windowNumber)
        }?.id
    }

    private func publishForegroundFocus() -> Bool {
        if invocationInProgress, discovery.foregroundProcessIdentifier() != invocationForegroundPID { return false }
        guard inferredFocusWorkerLifetime != nil || !pendingFocus.isEmpty else { return false }
        let target = foregroundTarget()
        let workerLifetime = target.flatMap { workers[$0.workerPID]?.lifetime }
        if let inferredFocusWorkerLifetime, inferredFocusWorkerLifetime != workerLifetime {
            self.inferredFocusWorkerLifetime = nil
            publication.recency.clearInference()
        }
        guard !pendingFocus.isEmpty else { return false }
        let observations = target.flatMap { pendingFocus[$0.hostPID] }
        pendingFocus.removeAll()
        guard let target, let observations, let focus = observations[target.workerPID] else {
            publication.recency.clearInference()
            inferredFocusWorkerLifetime = nil
            return false
        }
        let entries = publication.entries.filter { $0.processIdentifier == target.hostPID }
        var exactID = exactWindowID(for: focus, in: entries)
        // Workspace can report the host for a focused helper. A cached active
        // flag permits checking a helper's exact AX focus, but cannot infer it.
        if exactID == nil, !focus.reportedFocusedWindow, target.workerPID == target.hostPID {
            exactID = helperPIDsByHost[target.hostPID]?.sorted().lazy.compactMap { pid -> String? in
                guard self.applicationsByPID[pid]?.isActive == true, let helperFocus = observations[pid] else { return nil }
                return self.exactWindowID(for: helperFocus, in: entries)
            }.first
        }
        let shouldInfer = exactID == nil && focus.canInfer
        let unresolvedReportedFocus = exactID == nil && focus.reportedFocusedWindow
        // AX can finish before the current WindowServer read. Keep the focus
        // observation for publication when the matching visibility is available.
        let visibilityPending = invocationInProgress
            ? invocationRequiresRecords || !invocationRequiredHosts.isEmpty
            : windowRecordsPending || allSpacesRefreshTask != nil
        if shouldInfer || unresolvedReportedFocus, visibilityPending {
            pendingFocus[target.hostPID] = observations
            publication.recency.clearInference()
            inferredFocusWorkerLifetime = nil
            return false
        }
        let inferredID = shouldInfer ? inferredForegroundWindowID(in: entries, target: target) : nil
        inferredFocusWorkerLifetime = inferredID == nil ? nil : workerLifetime
        publication.recency.observeForeground(entries: entries, focusedWindowID: exactID,
            inferredWindowID: inferredID, unavailable: focus.unavailable)
        return unresolvedReportedFocus
    }

    private func reconcileInvocationForeground() {
        guard invocationInProgress else { return }
        let current = discovery.foregroundProcessIdentifier()
        guard current != invocationForegroundPID else { return }
        invocationForegroundPID = current
        publication.recency.clearFocus()
        inferredFocusWorkerLifetime = nil
        pendingFocus.removeAll()
        // A background scan can read the app's previous key window. Resolve
        // focus while it is foreground, once per invocation.
        guard invocationCanRescanForeground else { return }
        invocationCanRescanForeground = false
        reloadForegroundApplication(current)
        guard let target = foregroundTarget() else { return }
        invocationRequiresRecords = true
        windowRecordsPending = true
        requireInvocationScan(for: target.hostPID)
    }

    private func requireInvocationScan(for pid: pid_t) {
        queuedInvocationRetryHost = pid
        invocationRequiredHosts.insert(pid)
        dirtyHosts.insert(pid)
        drainRefreshes()
    }

    private func retryForegroundDiscoveryIfNeeded(unresolvedReportedFocus: Bool) {
        guard invocationCanRetryForegroundDiscovery else { return }
        invocationCanRetryForegroundDiscovery = false
        // A launch can put a window onscreen before the app publishes its AX
        // window list. Retry the scan while keeping the normal listing rules.
        guard allSpacesRecordsAreFresh, let target = foregroundTarget() else { return }
        let entries = publication.entries.filter { $0.processIdentifier == target.hostPID }
        let onscreen = foregroundOnscreenWindowNumbers(target: target)
        let hasConfirmedOnscreenFocus = entries.contains { entry in
            entry.id == publication.recency.confirmedFocusID
                && entry.windowNumber.map(onscreen.contains) == true
        }
        let missingAX = !hasConfirmedOnscreenFocus
            && hasUnresolvedOnscreenWindow(onscreen, in: entries, requiresAXConfirmation: unresolvedReportedFocus)
        // LaunchServices can report a foreground app before its window
        // appears in either source. Recapture visibility in that case too.
        let awaitingFirstWindow = onscreen.isEmpty
            && !entries.contains { $0.id == publication.recency.focusedID && isUsableWindow($0) }
            && applicationsByPID[target.workerPID].map { app in
                !app.isFinishedLaunching || app.launchDate.map { Date().timeIntervalSince($0) < 2 } == true
            } == true
        guard missingAX || awaitingFirstWindow else { return }
        invocationRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            invocationRetryTask = nil
            guard foregroundTarget()?.workerPID == target.workerPID else { schedulePublication(); return }
            if awaitingFirstWindow {
                invocationRequiresRecords = true
                windowRecordsPending = true
            }
            requireInvocationScan(for: target.hostPID)
        }
    }

    private func markPublicationDirty() {
        publicationDirty = true
        schedulePublication()
    }

    private func schedulePublication() {
        guard running, publicationTask == nil else { return }
        publicationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard !Task.isCancelled, let self, running else { return }
            publicationTask = nil
            let oldEntries = publication.entries
            let oldFocus = publication.recency.focusedID
            let wasComplete = isInitialDiscoveryComplete
            let wasReady = isInvocationReady
            if publicationDirty {
                publicationDirty = false
                for pid in removedProcesses { publication.removeProcess(pid) }
                removedProcesses.removeAll()
                rebuildPublication()
            }
            isInitialDiscoveryComplete = didReadAllSpaces && expectedHostPIDs.allSatisfy { snapshots[$0] != nil }
            let scansAreReady = isInitialDiscoveryComplete && !invocationRequiresRecords
                && invocationRequiredHosts.isEmpty && invocationRetryTask == nil
            if scansAreReady { reconcileInvocationForeground() }
            let unresolvedReportedFocus = publishForegroundFocus()
            let discoveryIsReady = scansAreReady && invocationRequiredHosts.isEmpty
            if discoveryIsReady { retryForegroundDiscoveryIfNeeded(unresolvedReportedFocus: unresolvedReportedFocus) }
            isInvocationReady = discoveryIsReady && invocationRequiredHosts.isEmpty
                && pendingFocus.isEmpty && invocationRetryTask == nil
            let completedInvocation = invocationInProgress && isInvocationReady
            if completedInvocation { invocationInProgress = false }
            if oldEntries != publication.entries || oldFocus != publication.recency.focusedID
                || wasComplete != isInitialDiscoveryComplete || wasReady != isInvocationReady {
                onChange?()
            }
            if completedInvocation, windowRecordsPending { drainRefreshes() }
        }
    }

    private func refreshAllSpaces() {
        guard allSpacesRefreshTask == nil else { return }
        windowRecordsPending = false
        let generation = allSpacesGeneration
        let invocation = invocationGeneration
        let isInvocationCapture = invocationInProgress && invocationRequiresRecords
        allSpacesRefreshTask = Task { [weak self] in
            guard let self else { return }
            let result = await allSpacesCatalog.freshWindowRecordSnapshot(requiresNewCapture: isInvocationCapture)
            guard !Task.isCancelled, running, allSpacesGeneration == generation else { return }
            allSpacesRefreshTask = nil
            let oldRecords = Dictionary(grouping: allSpacesRecords, by: \.processIdentifier)
            let newRecords = Dictionary(grouping: result.records, by: \.processIdentifier)
            let changedOwners = Set(oldRecords.keys).union(newRecords.keys).filter {
                oldRecords[$0]?.sorted { $0.windowNumber < $1.windowNumber }
                    != newRecords[$0]?.sorted { $0.windowNumber < $1.windowNumber }
            }
            let oldHelpers = helperPIDsByHost
            if allSpacesRecords != result.records || allSpacesRecordsAreFresh != result.isFresh { markPublicationDirty() }
            allSpacesRecords = result.records
            helperPIDsByHost = processMapping.helpersByHost(owningWindowsIn: allSpacesRecords)
            allSpacesRecordsAreFresh = result.isFresh
            if oldHelpers != helperPIDsByHost { reloadApplications() }
            let foregroundRetryHost = isInvocationCapture && invocation == invocationGeneration
                ? foregroundTarget()?.hostPID : nil
            // New helper ownership and missing AX events must schedule a scoped
            // scan, including when another read of that host is already active.
            for pid in expectedHostPIDs {
                let changed = changedOwners.contains { processMapping.host(for: $0) == pid }
                if oldHelpers[pid] != helperPIDsByHost[pid]
                    || (changed && pid != foregroundRetryHost && snapshots[pid] != nil) {
                    dirtyHosts.insert(pid)
                    // A newly mapped helper already requires a second AX pass
                    // for the foreground. It consumes the discovery retry.
                    if pid == foregroundRetryHost, invocationCanRetryForegroundDiscovery,
                       invocationScansStarted.contains(pid) {
                        invocationCanRetryForegroundDiscovery = false
                        queuedInvocationRetryHost = pid
                        invocationRequiredHosts.insert(pid)
                    }
                }
            }
            didReadAllSpaces = true
            if invocation == invocationGeneration {
                invocationRequiresRecords = false
                if !invocationInProgress, !isInvocationReady { invocationRequiredHosts.formUnion(dirtyHosts) }
            }
            schedulePublication()
            drainRefreshes()
        }
    }

    /// Only confirmed system IDs link AX and CG identities. Geometry/title
    /// guesses remain preview-only and must never rename a row or route actions.
    static func mergeAllSpacesEntries(_ entries: [WindowSwitcherAppEntry], records: [WindowSwitcherWindowRecord],
                                      knownWindowIDs: [CGWindowID: String] = [:],
                                      confirmedAXWindowNumbers: Set<CGWindowID> = [],
                                      hasConfirmedEmptyAXSnapshot: Bool = false,
                                      helperProcessIdentifiers: Set<pid_t> = []) -> [WindowSwitcherAppEntry] {
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
            // closes. Other-Space windows remain discoverable independently.
            guard !hasConfirmedEmptyAXSnapshot || (record.isOnScreen == false || (record.isOnScreen == nil && record.hasSpace == true)) else { return nil }
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
                                         records: [WindowSwitcherWindowRecord] = []) -> String? {
        let available = windows.filter { !$0.unavailable }
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
               let id = matchingFallbackWindowID(entry, windows: snapshot.windows, records: currentRecords) { return id }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(60))
        } while true
    }

    private func containsCurrentEntry(_ entry: WindowSwitcherAppEntry) -> Bool {
        entries(sortMode: .fixed).contains { $0.id == entry.id }
    }

    func activate(_ entry: WindowSwitcherAppEntry, intent: WindowSwitcherActivationIntent) async -> WindowSwitcherActionResult {
        guard intent.shouldContinue() else { return .cancelled }
        if entry.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            let result = await hostWindows.activate(entry, intent: intent)
            if result == .succeeded { publication.recency.record(entry.id) }
            refresh()
            return result
        }
        guard containsCurrentEntry(entry),
              let worker = processWorker(for: entry),
              let app = NSRunningApplication(processIdentifier: entry.processIdentifier), !app.isTerminated else { return .unavailable }
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
        if let resolved {
            if app.isHidden {
                _ = app.unhide()
                let deadline = ContinuousClock.now + .seconds(1)
                while app.isHidden && ContinuousClock.now < deadline {
                    guard intent.shouldContinue(), !app.isTerminated else { return .cancelled }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            guard intent.shouldContinue(), !app.isTerminated, !app.isHidden else { return .cancelled }
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
                if needsExactReveal, let number = entry.windowNumber,
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
            guard let matchedID = await Self.waitForFallbackWindow(entry, scan: { await worker.scan() },
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
        guard entry.isWindowEntry, containsCurrentEntry(entry), let worker = processWorker(for: entry) else { return .unavailable }
        var targetID = entry.workerWindowID ?? entry.id
        if entry.windowElement == nil {
            guard await allSpacesCatalog.isCurrentFallback(entry) else { return .unavailable }
            let scan = await worker.scan()
            guard scan.windowListReadSucceeded,
                  let matchedID = Self.matchingFallbackWindowID(entry, windows: scan.windows, records: allSpacesRecords) else { return .unavailable }
            targetID = matchedID
        }
        guard processWorker(for: entry) === worker else { return .unavailable }
        let result = await worker.perform(targetID, close: true)
        refresh()
        return result
    }

    func quitApplication(_ entry: WindowSwitcherAppEntry) -> WindowSwitcherActionResult {
        guard containsCurrentEntry(entry),
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
