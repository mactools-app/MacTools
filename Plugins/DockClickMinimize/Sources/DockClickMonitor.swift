import AppKit
import CoreGraphics
import Foundation

struct DockFrontmostApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
}

protocol DockFrontmostApplicationProviding: AnyObject {
    func frontmostApplication() -> DockFrontmostApplication?
}

final class WorkspaceDockFrontmostApplicationProvider: DockFrontmostApplicationProviding {
    func frontmostApplication() -> DockFrontmostApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier
        else {
            return nil
        }
        return DockFrontmostApplication(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: application.processIdentifier
        )
    }
}

protocol DockClickMonitoring: AnyObject {
    var onApplicationClick: ((DockApplicationTarget, DockFrontmostApplication) -> Void)? { get set }
    var activityGeneration: Int { get }
    @discardableResult
    func start() -> Bool
    func stop()
}

enum DockClickModifierPolicy {
    private static let modifiedClickFlags: CGEventFlags = [
        .maskCommand,
        .maskAlternate,
        .maskControl,
        .maskShift,
    ]

    static func isPlainClick(flags: CGEventFlags) -> Bool {
        flags.intersection(modifiedClickFlags).isEmpty
    }
}

enum DockClickGesturePolicy {
    static let maximumDuration: TimeInterval = 0.35
    static let maximumDistance: CGFloat = 4

    static func isWithinMaximumDistance(
        downLocation: CGPoint,
        currentLocation: CGPoint
    ) -> Bool {
        hypot(
            currentLocation.x - downLocation.x,
            currentLocation.y - downLocation.y
        ) <= maximumDistance
    }

    static func isCompletedClick(
        downLocation: CGPoint,
        upLocation: CGPoint,
        duration: TimeInterval
    ) -> Bool {
        guard duration <= maximumDuration else {
            return false
        }
        return isWithinMaximumDistance(
            downLocation: downLocation,
            currentLocation: upLocation
        )
    }
}

// Event-tap state stays on the main run loop; Accessibility resolution is confined to accessibilityQueue.
final class DockClickMonitor: DockClickMonitoring, @unchecked Sendable {
    private let logger = DockClickLog.monitor
    private let resolver: any DockApplicationResolving
    private let frontmostApplicationProvider: any DockFrontmostApplicationProviding
    private let workspaceNotificationCenter: NotificationCenter
    private let accessibilityQueue = DispatchQueue(
        label: "cc.ggbond.mactools.dock-click-minimize.accessibility"
    )
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var gestureTracker = DockClickGestureTracker()
    private var applicationObservers: [NSObjectProtocol] = []

    var onApplicationClick: ((DockApplicationTarget, DockFrontmostApplication) -> Void)?

    var activityGeneration: Int { gestureTracker.generation }

    init(
        resolver: any DockApplicationResolving = DockAccessibilityResolver(),
        frontmostApplicationProvider: any DockFrontmostApplicationProviding = WorkspaceDockFrontmostApplicationProvider(),
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.resolver = resolver
        self.frontmostApplicationProvider = frontmostApplicationProvider
        self.workspaceNotificationCenter = workspaceNotificationCenter
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else {
            return true
        }

        let events = CGEventMask(1) << CGEventType.leftMouseDown.rawValue
            | CGEventMask(1) << CGEventType.leftMouseUp.rawValue
            | CGEventMask(1) << CGEventType.leftMouseDragged.rawValue
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: events,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to create Hide Active App on Dock Click event tap")
            return false
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            logger.error("Failed to create Hide Active App on Dock Click run loop source")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        observeApplicationChanges()
        resetGestureTracker()
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func stop() {
        gestureTracker.reset(frontmostApplication: nil, at: DispatchTime.now().uptimeNanoseconds)
        applicationObservers.forEach(workspaceNotificationCenter.removeObserver)
        applicationObservers.removeAll()
        guard let eventTap else {
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        runLoopSource = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<DockClickMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetGestureTracker()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if let frontmostApplication = gestureTracker.handle(
            type: type,
            event: event,
            frontmostApplication: frontmostApplicationProvider.frontmostApplication(),
            observedAt: DispatchTime.now().uptimeNanoseconds
        ) {
            resolveClick(at: event.location, frontmostApplication: frontmostApplication)
        }
        return Unmanaged.passUnretained(event)
    }

    private func observeApplicationChanges() {
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            let observer = workspaceNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.resetGestureTracker()
            }
            applicationObservers.append(observer)
        }
    }

    private func resetGestureTracker() {
        gestureTracker.reset(
            frontmostApplication: frontmostApplicationProvider.frontmostApplication(),
            at: DispatchTime.now().uptimeNanoseconds
        )
    }

    private func resolveClick(at location: CGPoint, frontmostApplication: DockFrontmostApplication) {
        let generation = gestureTracker.generation
        accessibilityQueue.async { [weak self] in
            guard let self,
                  let target = self.resolver.resolveApplication(at: location)
            else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.gestureTracker.generation,
                      self.eventTap != nil
                else {
                    return
                }
                self.onApplicationClick?(target, frontmostApplication)
            }
        }
    }
}
