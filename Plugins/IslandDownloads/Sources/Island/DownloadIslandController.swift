import AppKit
import ApplicationServices
import Combine
import OSLog

/// Shows the compact download activity beside the island while a download runs. It measures the
/// island and the free menu-bar space when a download starts, the app in front changes or
/// MenuBarAgent reports a change; progress only updates the labels.
@MainActor
final class DownloadIslandController {
    var enabled = false { didSet { if enabled != oldValue { schedule() } } }
    private let service = NotchDownloadService.shared
    private let indicator = DownloadIslandIndicator()
    private let watcher = DownloadMenuBarWatcher()
    private var subscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var work: DispatchWorkItem?
    private var measuring = false
    private var again = false
    private var generation = 0
    /// The download the shape was measured for; another one needs room for its own name.
    private var measuredID: String?
    private let logger = Logger(subsystem: "MacTools.IslandDownloads", category: "island")

    init() {
        indicator.onClick = { [weak self] in self?.revealCurrent() }
        watcher.onChange = { [weak self] in self?.schedule(remeasure: true) }
    }

    func start() {
        guard subscription == nil else { return }
        subscription = service.$items.receive(on: RunLoop.main).sink { [weak self] _ in self?.itemsChanged() }
        let center = NSWorkspace.shared.notificationCenter
        // The app in front owns the menus left of the island.
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(remeasure: true) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(remeasure: true) }
        })
    }

    func stop() {
        generation += 1
        subscription = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        work?.cancel(); work = nil
        indicator.hide()
        watcher.stop()
        measuredID = nil
    }

    private var current: NotchDownloadItem? {
        service.items.first { $0.active && !$0.completed }
    }

    private func itemsChanged() {
        guard let current, allowed else { schedule(); return }
        updateLabels(current)
        if current.id != measuredID || !indicator.isVisible { schedule() }
        else if hoverPanelVisible { indicator.hide() }
    }

    private var allowed: Bool {
        enabled && current != nil && AXIsProcessTrusted() && Self.notchAnchor() != nil
    }

    private func schedule(remeasure: Bool = false) {
        if remeasure { measuredID = nil }
        guard work == nil else { return }
        let next = DispatchWorkItem { [weak self] in
            self?.work = nil
            self?.update()
        }
        work = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: next)
    }

    private func update() {
        guard allowed, let current, let anchor = Self.notchAnchor(),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }),
              let desktopTop = NSScreen.screens.first?.frame.maxY else {
            indicator.hide(); watcher.stop(); measuredID = nil
            return
        }
        // The hover panel covers the island while it is open; the activity waits underneath it.
        if hoverPanelVisible { indicator.hide(); measuredID = nil; return }
        guard !measuring else { again = true; return }
        measuring = true
        let generation = generation
        let resting = Self.restingIsland(for: anchor)
        let screenFrame = screen.frame
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let agent = NSWorkspace.shared.runningApplications.first(where: DownloadIslandAX.isMenuBarAgent)?.processIdentifier
        let id = current.id
        let nameWidth = DownloadIslandMetrics.nameWidth(current.name)
        DownloadIslandAX.queue.async { [weak self] in
            let surroundings = DownloadIslandAX.surroundings(restingIsland: resting, screen: screenFrame,
                                                             desktopTop: desktopTop, frontPID: front, agentPID: agent)
            let item = surroundings.map { IslandAXItem(value: $0.nearestItem) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.measuring = false
                    defer { if self.again { self.again = false; self.schedule() } }
                    guard self.generation == generation, self.allowed, self.current?.id == id else {
                        if self.current == nil { self.indicator.hide(); self.watcher.stop() }
                        return
                    }
                    if let agent { self.watcher.start(pid: agent); self.watcher.observe(item?.value) }
                    guard let surroundings else {
                        // Unknown space is never assumed free.
                        self.logger.notice("download activity hidden: menu bar or island unreadable")
                        self.indicator.hide(); self.measuredID = id
                        return
                    }
                    let layout = DownloadIslandLayout.resolve(island: surroundings.island,
                                                              systemActivity: surroundings.systemActivity,
                                                              nameWidth: nameWidth,
                                                              leftLimit: surroundings.leftLimit,
                                                              rightLimit: surroundings.rightLimit)
                    self.measuredID = id
                    if let current = self.current { self.updateLabels(current) }
                    guard layout != self.indicator.layout || !self.indicator.isVisible else { return }
                    if self.hoverPanelVisible { self.indicator.hide(); return }
                    self.indicator.show(layout)
                }
            }
        }
    }

    private func updateLabels(_ item: NotchDownloadItem) {
        let text = NotchDownloadStrings.current
        indicator.update(name: item.name, fraction: item.fraction, receivedBytes: item.receivedBytes,
                         accessibility: "\(text.inProgress): \(item.name)")
    }

    /// Like tapping a compact Live Activity: opens where the download lands.
    private func revealCurrent() {
        guard let item = current else { return }
        let target = NotchDownloadSupport.expectedURL(for: item.url) ?? item.url
        let shown = FileManager.default.fileExists(atPath: target.path) ? target : item.url
        NSWorkspace.shared.activateFileViewerSelecting([shown])
    }

    /// The host's island hover panel shares the process; it is the large nonactivating panel over
    /// the island.
    private var hoverPanelVisible: Bool {
        guard let anchor = Self.notchAnchor() else { return false }
        let area = anchor.insetBy(dx: 0, dy: -64)
        return NSApp.windows.contains { window in
            window.isVisible && window is NSPanel && window.styleMask.contains(.nonactivatingPanel)
                && window.level == .statusBar && window.frame.width >= 260 && window.frame.height > 64
                && window.frame.intersects(area)
        }
    }

    /// These features are built for the floating camera island of the MacBook Pro that came with
    /// macOS 27: a short pill just below the top of the display. A classic notch (wide, reaching
    /// the display edge) is not one, and neither is an earlier macOS; there the feature stays off.
    static func isCameraIsland(_ anchor: CGRect) -> Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
            && anchor.width < anchor.height * 3
    }

    /// The camera housing between the built-in display's two menu-bar areas, on the camera island only.
    static func notchAnchor() -> CGRect? {
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDisplayIsBuiltin(id.uint32Value) != 0, CGDisplayIsActive(id.uint32Value) != 0,
                  let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
                  !left.isEmpty, !right.isEmpty else { continue }
            let height = max(left.height, right.height)
            let width = screen.frame.width - left.width - right.width
            guard height > 0, width > 0 else { continue }
            let anchor = CGRect(x: screen.frame.minX + left.width, y: screen.frame.maxY - height, width: width, height: height)
            return isCameraIsland(anchor) ? anchor : nil
        }
        return nil
    }

    /// The system island at rest: the camera housing, a few points below the top of a floating cutout.
    static func restingIsland(for anchor: CGRect) -> CGRect {
        let inset = anchor.width >= anchor.height * 3 ? 0 : min(6, anchor.height * 0.2)
        return CGRect(x: anchor.minX, y: anchor.minY, width: anchor.width, height: anchor.height - inset)
    }
}

/// Carries one AX element from the AX queue to the main thread.
private struct IslandAXItem: @unchecked Sendable {
    let value: AXUIElement?
}
