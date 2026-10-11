import AppKit
import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import IOKit
import MacToolsPluginKit
import OSLog

@MainActor
protocol MiddleClickSessionManaging: AnyObject {
    var requiredFingerCount: Int { get set }

    func activate()
    func deactivate()
    func setInputPaused(_ isPaused: Bool)
}

private enum MiddleClickEventPoster {
    static func postClick() {
        guard let location = CGEvent(source: nil)?.location,
              let mouseDown = makeEvent(type: .otherMouseDown, location: location),
              let mouseUp = makeEvent(type: .otherMouseUp, location: location)
        else {
            return
        }
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
    }

    private static func makeEvent(type: CGEventType, location: CGPoint) -> CGEvent? {
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .center
        )
        event?.setIntegerValueField(
            .mouseEventButtonNumber,
            value: Int64(CGMouseButton.center.rawValue)
        )
        return event
    }
}

/// Manages raw trackpad contact frames and emits a middle-click for a completed multi-finger tap.
///
/// Behavior follows artginzburg/MiddleClick and the current TrackpadGestures recognizer:
/// - raw active contacts are filtered from MultitouchSupport frames;
/// - a tap is recognized only after all configured fingers release within time/movement limits;
/// - `otherMouseDown/Up` is synthesized at the current cursor location;
/// - the matching native trackpad click is rewritten in place so the original left click does not
///   reach the application alongside the synthesized middle click;
///
/// Recovery hooks match artginzburg/MiddleClick:
/// - `didWakeNotification`: after wake, the multitouch driver may not be ready; rebuild listeners
///   after a delay.
/// - `CGDisplayRegisterReconfigurationCallback`: also schedule a rebuild after display changes.
/// - IOKit `AppleMultitouchDevice` first-match notification: rebuild when built-in or external
///   trackpads are re-enumerated.
///
/// Mutable state is read and written both by multitouch C callback threads and by the
/// main thread, so the type is explicitly marked `@unchecked Sendable`. All lifecycle methods
/// (`start`, `stop`, `activate`, `deactivate`) and internal restart scheduling are expected to run
/// on the main thread.
final class MiddleClickSession: MiddleClickSessionManaging, @unchecked Sendable {
    private typealias CallbackContext = PluginCallbackContext<MiddleClickSession>

    // MARK: - Config (set on the main thread, read from callback threads)

    nonisolated(unsafe) var requiredFingerCount: Int = 3 {
        didSet {
            tapPipeline.updateFingerCount(requiredFingerCount)
        }
    }

    // MARK: - Infrastructure

    var inputService: (any TrackpadInputService)?
    private lazy var inputSubscription: MiddleClickInputSubscription = {
        let pipeline = tapPipeline
        return MiddleClickInputSubscription { event in
            switch event {
            case .interrupted:
                pipeline.reset(preservingNativeUp: true)
            case let .frame(frame):
                let snapshot = MiddleClickContactFrame(deviceID: frame.deviceID,
                    timestamp: frame.timestamp, contacts: frame.contacts.map {
                        MiddleClickContactSnapshot(identifier: $0.identifier, x: $0.x, y: $0.y)
                    })
                if pipeline.process(snapshot) { MiddleClickEventPoster.postClick() }
            }
        }
    }()
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var eventTapCallbackPointer: UnsafeMutableRawPointer?
    private var wakeObserver: NSObjectProtocol?
    private var ioNotificationPort: IONotificationPortRef?
    private var ioArrivalIterator: io_iterator_t = 0
    private var ioTerminationIterator: io_iterator_t = 0
    private var ioCallbackPointer: UnsafeMutableRawPointer?
    private var displayCallbackRegistered = false
    private var displayCallbackPointer: UnsafeMutableRawPointer?
    private var restartWorkItem: DispatchWorkItem?
    nonisolated private let tapPipeline: MiddleClickTapPipeline
    private var inputIsPaused = false
    private let eventTapStartOverride: (() -> Void)?
    private let eventTapStopOverride: (() -> Void)?
    private let observesSystemEvents: Bool
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "MiddleClickSession")

    /// After wake, the multitouch driver may not be ready; delay before rebuilding listeners.
    /// Keep this aligned with artginzburg/MiddleClick at 10 seconds: long sleep can make driver
    /// re-enumeration vary across hardware, and 2-3 second delays reproduced "MiddleClick stopped
    /// working" in testing. Users rarely need middle-click in the first few seconds after unlock.
    private static let wakeRestartDelay: TimeInterval = 10
    private static let deviceChangeRestartDelay: TimeInterval = 0.5

    init(tapPipeline: MiddleClickTapPipeline = MiddleClickTapPipeline(fingerCount: 3),
         eventTapStart: (() -> Void)? = nil, eventTapStop: (() -> Void)? = nil,
         observesSystemEvents: Bool = true) {
        self.tapPipeline = tapPipeline
        self.eventTapStartOverride = eventTapStart
        self.eventTapStopOverride = eventTapStop
        self.observesSystemEvents = observesSystemEvents
    }

    // MARK: - Singleton Reference

    nonisolated(unsafe) static weak var activeSession: MiddleClickSession?

    // MARK: - CGEvent Tap

    private func startEventTap() {
        if let eventTapStartOverride { eventTapStartOverride(); return }
        if let eventTap, CFMachPortIsValid(eventTap), eventTapSource != nil {
            return
        }
        stopEventTap()

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)

        let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }

            let context = Unmanaged<CallbackContext>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            let passthrough = Unmanaged.passUnretained(event)

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                context.withOwner { session in
                    session.tapPipeline.reset(preservingNativeUp: true)
                    DispatchQueue.main.async { [weak session] in
                        session?.reenableEventTap()
                    }
                }
                return passthrough
            }

            let nativeEvent: MiddleClickNativeMouseEvent?
            switch type {
            case .leftMouseDown:
                nativeEvent = .down(.left)
            case .leftMouseUp:
                nativeEvent = .up(.left)
            case .rightMouseDown:
                nativeEvent = .down(.right)
            case .rightMouseUp:
                nativeEvent = .up(.right)
            default:
                nativeEvent = nil
            }

            guard let nativeEvent else { return passthrough }
            let decision = context.withOwner { session in
                session.handleNativeMouseEvent(nativeEvent)
            } ?? .passThrough

            switch decision {
            case .passThrough:
                return passthrough
            case .rewriteAsMiddle:
                let isDown = type == .leftMouseDown || type == .rightMouseDown
                event.type = isDown ? .otherMouseDown : .otherMouseUp
                event.setIntegerValueField(
                    .mouseEventButtonNumber,
                    value: Int64(CGMouseButton.center.rawValue)
                )
                return passthrough
            }
        }

        let context = CallbackContext(owner: self)
        let callbackPointer = Unmanaged.passRetained(context).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: callbackPointer
        ) else {
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            logger.error("failed to create CGEvent tap; check Accessibility permission")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            logger.error("failed to create CGEvent tap run-loop source")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        eventTapCallbackPointer = callbackPointer
        logger.info("CGEvent tap started")
    }

    private func reenableEventTap() {
        guard let eventTap, CFMachPortIsValid(eventTap) else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopEventTap() {
        if let eventTapStopOverride { eventTapStopOverride(); return }
        callbackContext(from: eventTapCallbackPointer)?.invalidate()
        guard let eventTap else {
            eventTapSource = nil
            releaseEventTapCallbackContext()
            return
        }

        if CFMachPortIsValid(eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        self.eventTapSource = nil
        releaseEventTapCallbackContext()
        logger.info("CGEvent tap stopped")
    }

    private func releaseEventTapCallbackContext() {
        guard let eventTapCallbackPointer else { return }
        callbackContext(from: eventTapCallbackPointer)?.invalidate()
        Unmanaged<CallbackContext>.fromOpaque(eventTapCallbackPointer).release()
        self.eventTapCallbackPointer = nil
    }

    // MARK: - Multitouch Listeners

    func setInputService(_ service: any TrackpadInputService) {
        inputService = service
        if !inputIsPaused { startTouchListeners() }
    }

    private func startTouchListeners() {
        guard let inputService else { return }
        inputSubscription.start(service: inputService)
    }

    private func stopTouchListeners(preservingNativeUp: Bool = false) {
        inputSubscription.stop()
        tapPipeline.reset(preservingNativeUp: preservingNativeUp)
    }

    // MARK: - Start / Stop

    func start() {
        guard !inputIsPaused else { return }
        startTouchListeners()
        startEventTap()
        if observesSystemEvents {
            observeSystemWake()
            observeMultitouchDeviceArrival()
            observeDisplayReconfiguration()
        }
        logger.info("multitouch listener started deviceCount=\(self.inputService?.devices.count ?? 0, privacy: .public)")
    }

    func stop() {
        cancelPendingRestart()
        removeDisplayReconfigurationObserver()
        removeMultitouchDeviceObserver()
        removeSystemWakeObserver()
        stopEventTap()
        stopTouchListeners()
        logger.info("multitouch listener stopped")
    }

    func activate() {
        MiddleClickSession.activeSession?.stop()
        MiddleClickSession.activeSession = self
        start()
    }

    func deactivate() {
        if MiddleClickSession.activeSession === self {
            MiddleClickSession.activeSession = nil
        }
        stop()
    }

    func setInputPaused(_ isPaused: Bool) {
        guard inputIsPaused != isPaused else { return }
        inputIsPaused = isPaused
        tapPipeline.setPaused(isPaused)
        if isPaused {
            cancelPendingRestart()
            removeDisplayReconfigurationObserver()
            removeMultitouchDeviceObserver()
            removeSystemWakeObserver()
            stopTouchListeners(preservingNativeUp: true)
            finishPausedEventTapIfPossible()
        } else {
            start()
        }
    }

    nonisolated func handleNativeMouseEvent(_ event: MiddleClickNativeMouseEvent) -> MiddleClickNativeEventDecision {
        let decision = tapPipeline.handleNativeMouseEvent(event)
        if case .up = event {
            DispatchQueue.main.async { [weak self] in self?.finishPausedEventTapIfPossible() }
        }
        return decision
    }

    private func finishPausedEventTapIfPossible() {
        // A rewritten Down owns its exact Up. Keep only that terminal conversion
        // active while paused; new clicks and contact recognition pass through.
        guard inputIsPaused, !tapPipeline.hasPendingNativeUp else { return }
        stopEventTap()
    }

    // MARK: - System Recovery: Listener Restart

    /// Rebuilds shared touch subscriptions while keeping the session object.
    /// Used after wake, display reconfiguration, and trackpad re-enumeration.
    private func restartListeners() {
        guard !inputIsPaused else { return }
        logger.info("rebuilding multitouch and CGEvent tap listeners")
        if !tapPipeline.hasPendingNativeUp { stopEventTap() }
        stopTouchListeners(preservingNativeUp: true)
        startTouchListeners()
        startEventTap()
        logger.info("listener rebuild completed deviceCount=\(self.inputService?.devices.count ?? 0, privacy: .public)")
    }

    private func scheduleRestart(after delay: TimeInterval, reason: String) {
        guard !inputIsPaused else { return }
        logger.info("scheduled listener restart reason=\(reason, privacy: .public) delay=\(delay, privacy: .public)")
        cancelPendingRestart()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.restartListeners()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingRestart() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
    }

    // MARK: - NSWorkspace Wake Notification

    private func observeSystemWake() {
        guard wakeObserver == nil else { return }
        let restartDelay = Self.wakeRestartDelay
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRestart(after: restartDelay, reason: "systemWake")
            }
        }
    }

    private func removeSystemWakeObserver() {
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    // MARK: - IOKit Trackpad Device Arrival Notification

    /// Observes `AppleMultitouchDevice` first-match notifications. When the system re-enumerates
    /// trackpads after wake, external attach/detach, or driver reset, schedule a short-delay rebuild
    /// so the MTDevice list matches the actual hardware.
    private func observeMultitouchDeviceArrival() {
        guard ioNotificationPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logger.error("failed to create IONotificationPort; skipping device arrival observer")
            return
        }

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        let context = CallbackContext(owner: self)
        let callbackPointer = Unmanaged.passRetained(context).toOpaque()
        var arrivalIterator: io_iterator_t = 0
        let arrivalResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("AppleMultitouchDevice"),
            { userData, iterator in
                // The iterator must be drained or subsequent notifications will not fire.
                MiddleClickSession.drainIterator(iterator)
                guard let userData else { return }
                let context = Unmanaged<CallbackContext>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                context.withOwner { session in
                    DispatchQueue.main.async { [weak session] in
                        session?.scheduleRestart(
                            after: MiddleClickSession.deviceChangeRestartDelay,
                            reason: "multitouchDeviceArrived"
                        )
                    }
                }
            },
            callbackPointer,
            &arrivalIterator
        )

        guard arrivalResult == KERN_SUCCESS else {
            logger.error("IOServiceAddMatchingNotification failed result=\(arrivalResult, privacy: .public)")
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            IONotificationPortDestroy(port)
            return
        }

        var terminationIterator: io_iterator_t = 0
        let terminationResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("AppleMultitouchDevice"),
            { userData, iterator in
                MiddleClickSession.drainIterator(iterator)
                guard let userData else { return }
                let context = Unmanaged<CallbackContext>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                context.withOwner { session in
                    DispatchQueue.main.async { [weak session] in
                        session?.scheduleRestart(
                            after: MiddleClickSession.deviceChangeRestartDelay,
                            reason: "multitouchDeviceRemoved"
                        )
                    }
                }
            },
            callbackPointer,
            &terminationIterator
        )

        guard terminationResult == KERN_SUCCESS else {
            logger.error("IOServiceAddMatchingNotification termination failed result=\(terminationResult, privacy: .public)")
            context.invalidate()
            IOObjectRelease(arrivalIterator)
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            IONotificationPortDestroy(port)
            return
        }

        Self.drainIterator(arrivalIterator)
        Self.drainIterator(terminationIterator)

        ioNotificationPort = port
        ioArrivalIterator = arrivalIterator
        ioTerminationIterator = terminationIterator
        ioCallbackPointer = callbackPointer
    }

    private func removeMultitouchDeviceObserver() {
        callbackContext(from: ioCallbackPointer)?.invalidate()
        if ioArrivalIterator != 0 {
            IOObjectRelease(ioArrivalIterator)
            ioArrivalIterator = 0
        }
        if ioTerminationIterator != 0 {
            IOObjectRelease(ioTerminationIterator)
            ioTerminationIterator = 0
        }
        if let port = ioNotificationPort {
            IONotificationPortDestroy(port)
            ioNotificationPort = nil
        }
        if let ioCallbackPointer {
            Unmanaged<CallbackContext>.fromOpaque(ioCallbackPointer).release()
            self.ioCallbackPointer = nil
        }
    }

    private static func drainIterator(_ iterator: io_iterator_t) {
        while true {
            let next = IOIteratorNext(iterator)
            if next == 0 { break }
            IOObjectRelease(next)
        }
    }

    // MARK: - Display Reconfiguration Callback

    private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userData in
        let interesting: CGDisplayChangeSummaryFlags = [.setModeFlag, .addFlag, .removeFlag, .disabledFlag]
        guard !flags.intersection(interesting).isEmpty else { return }
        guard let userData else { return }
        let context = Unmanaged<CallbackContext>
            .fromOpaque(userData)
            .takeUnretainedValue()
        context.withOwner { session in
            DispatchQueue.main.async { [weak session] in
                session?.scheduleRestart(after: 2, reason: "displayReconfigured")
            }
        }
    }

    /// Observes display reconfiguration. Clamshell changes, external-display attach, and topology
    /// changes can invalidate the multitouch path. Match artginzburg/MiddleClick by restarting only
    /// for substantive changes such as setMode, add, remove, or disabled.
    private func observeDisplayReconfiguration() {
        guard !displayCallbackRegistered else { return }
        let context = CallbackContext(owner: self)
        let callbackPointer = Unmanaged.passRetained(context).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(
            Self.displayReconfigurationCallback,
            callbackPointer
        )
        if result == .success {
            displayCallbackRegistered = true
            displayCallbackPointer = callbackPointer
        } else {
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            logger.error("CGDisplayRegisterReconfigurationCallback failed result=\(result.rawValue, privacy: .public)")
        }
    }

    private func removeDisplayReconfigurationObserver() {
        guard displayCallbackRegistered else { return }
        callbackContext(from: displayCallbackPointer)?.invalidate()
        CGDisplayRemoveReconfigurationCallback(
            Self.displayReconfigurationCallback,
            displayCallbackPointer
        )
        displayCallbackRegistered = false
        if let displayCallbackPointer {
            Unmanaged<CallbackContext>.fromOpaque(displayCallbackPointer).release()
            self.displayCallbackPointer = nil
        }
    }

    private nonisolated func callbackContext(
        from pointer: UnsafeMutableRawPointer?
    ) -> CallbackContext? {
        guard let pointer else { return nil }
        return Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
    }
}
