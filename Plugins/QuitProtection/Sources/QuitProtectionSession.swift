import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MacToolsPluginKit

/// The session tap records the physical gesture. Only the later tap, after
/// macOS has attached the destination PID, may claim the shortcut.
@MainActor
final class QuitProtectionSession {
    enum Feedback: Equatable {
        case holding(duration: Duration, deadline: ContinuousClock.Instant)
        case ready
        case doublePress(deadline: ContinuousClock.Instant)
        case chromeUnavailable
    }

    struct Destination: Equatable {
        let app: NSRunningApplication
        let generation: UInt64
        let keyCode: UInt16
        let keyboardLayout: QuitProtectionKeyboardLayout
    }

    private struct Candidate {
        let timestamp: CGEventTimestamp
        let keyCode: UInt16

        func matches(timestamp: CGEventTimestamp, keyCode: UInt16) -> Bool {
            self.timestamp == timestamp && self.keyCode == keyCode
        }
    }

    private struct Tap {
        let port: CFMachPort
        let source: CFRunLoopSource

        func stop() {
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(port)
        }
    }

    private static let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
    private static let keyboardEvents: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
    private static let pointerEvents: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    private var sessionTap: Tap?
    private var deliveryTap: Tap?
    private var activationObserver: (any NSObjectProtocol)?
    private var chooserObserver: (any NSObjectProtocol)?
    private var chooserShortcutObserver: (any NSObjectProtocol)?
    private var inputClaimObserver: (any NSObjectProtocol)?
    private var keyboardLayoutObserver: (any NSObjectProtocol)?
    private var quitRule = QuitProtectionRule()
    private var enabled = false
    private var generation: UInt64 = 0
    private var routing = QuitProtectionInputRouting()
    private var candidate: Candidate?
    private var eventClock = QuitProtectionEventClock()
    private var gesture = QuitProtectionGesture<Destination>()
    private var escapeClaimed = false
    private var deadline: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var inputWatch: Task<Void, Never>?
    var showFeedback: ((NSRunningApplication, Feedback) -> Void)?
    var hideFeedback: (() -> Void)?
    var availabilityChanged: (() -> Void)?

    private var isRunning: Bool {
        guard let sessionTap, let deliveryTap else { return false }
        return CGEvent.tapIsEnabled(tap: sessionTap.port) && CGEvent.tapIsEnabled(tap: deliveryTap.port)
    }

    var isProtecting: Bool { enabled && isRunning }

    private var hasClaimedInput: Bool { gesture.hasClaimedKeys || escapeClaimed }

    static var hasRequiredPermissions: Bool {
        AXIsProcessTrusted() && CGPreflightPostEventAccess() && CGPreflightListenEventAccess()
    }

    func update(quit: QuitProtectionRule, enabled: Bool) {
        if quitRule != quit || self.enabled != enabled {
            quitRule = quit
            self.enabled = enabled
            invalidateDestination()
        }
        if enabled {
            drain?.cancel()
            drain = nil
            if !isRunning {
                stop(preservingClaimedKeys: true)
                start()
            }
        } else if hasClaimedInput {
            drainReleasedClaimsWhilePaused()
        } else {
            stop()
        }
    }

    func stop(preservingClaimedKeys: Bool = false) {
        drain?.cancel()
        drain = nil
        invalidateDestination()
        gesture.resetObservation(preservingClaimedKeys: preservingClaimedKeys)
        if !preservingClaimedKeys { escapeClaimed = false }
        routing.reset(commandIsDown: false)
        eventClock = QuitProtectionEventClock()
        sessionTap?.stop()
        deliveryTap?.stop()
        sessionTap = nil
        deliveryTap = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let chooserObserver {
            NotificationCenter.default.removeObserver(chooserObserver)
            self.chooserObserver = nil
        }
        if let chooserShortcutObserver {
            NotificationCenter.default.removeObserver(chooserShortcutObserver)
            self.chooserShortcutObserver = nil
        }
        if let inputClaimObserver {
            NotificationCenter.default.removeObserver(inputClaimObserver)
            self.inputClaimObserver = nil
        }
        if let keyboardLayoutObserver {
            DistributedNotificationCenter.default().removeObserver(keyboardLayoutObserver)
            self.keyboardLayoutObserver = nil
        }
    }

    private func start() {
        guard let observed = makeTap(
            at: .cgSessionEventTap, place: QuitProtectionInputRouting.sessionTapPlacement,
            events: Self.keyboardEvents + Self.pointerEvents, callback: Self.observe
        ) else { return }
        guard let delivery = makeTap(
            at: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
            events: [.keyDown, .keyUp], callback: Self.deliver
        ) else {
            observed.stop()
            return
        }
        sessionTap = observed
        deliveryTap = delivery
        routing.reset(commandIsDown: CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand))
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // An ordinary focus change (for example, Command-H) ends the old
            // gesture without disarming a fresh Command-Q in the new app.
            MainActor.assumeIsolated {
                // The later tap still validates the destination of a new press.
                // The activation notice can arrive between its two callbacks.
                self?.invalidateDestination(keepingCandidate: true)
            }
        }
        chooserObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard Self.isWindowSwitcher(window) else { return }
                self?.invalidateSwitcherRouting()
            }
        }
        // Window Switcher can consume its shortcut in an earlier tap, before
        // its chooser is visible or the destination PID changes.
        chooserShortcutObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("MacTools.WindowSwitcher.willHandleShortcut"), object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateSwitcherRouting() }
        }
        inputClaimObserver = NotificationCenter.default.addObserver(
            forName: .macToolsWillClaimPhysicalInput, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateDestination() }
        }
        keyboardLayoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateDestination() }
        }
    }

    private func makeTap(
        at location: CGEventTapLocation,
        place: CGEventTapPlacement,
        events: [CGEventType],
        callback: CGEventTapCallBack
    ) -> Tap? {
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: location, place: place, options: .defaultTap, eventsOfInterest: mask,
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return Tap(port: port, source: source)
    }

    private static let observe: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<QuitProtectionSession>.fromOpaque(context).takeUnretainedValue()
        nonisolated(unsafe) let event = event
        MainActor.assumeIsolated { owner.observe(type, event: event) }
        return Unmanaged.passUnretained(event)
    }

    private static let deliver: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<QuitProtectionSession>.fromOpaque(context).takeUnretainedValue()
        nonisolated(unsafe) let event = event
        let suppress = MainActor.assumeIsolated { owner.shouldSuppress(type, event: event) }
        return suppress ? nil : Unmanaged.passUnretained(event)
    }

    private func observe(_ type: CGEventType, event: CGEvent) {
        if handleInterruption(type) { return }
        guard !MacToolsSyntheticInputEvent.isMarked(event) else { return }
        let isLocal = event.getIntegerValueField(.eventSourceUnixProcessID) == 0
        let flags = event.flags.intersection(Self.modifiers)
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        if Self.pointerEvents.contains(type) {
            cancelDelivery()
            if gesture.hasPendingConfirmation { cancelConfirmation() }
            return
        }
        if IsSecureEventInputEnabled() {
            resetAfterInputInterruption()
            return
        }
        if type == .flagsChanged {
            let isCommandKey = keyCode == kVK_Command || keyCode == kVK_RightCommand
            routing.observeModifiers(
                commandIsDown: flags.contains(.maskCommand),
                beganWithLocalCommandKey: isLocal && isCommandKey
            )
            if !flags.contains(.maskCommand) {
                candidate = nil
            }
            if (isLocal && !isCommandKey && gesture.hasPendingConfirmation)
                || (gesture.pendingHold != nil && flags != .maskCommand) {
                cancelConfirmation()
            }
            return
        }
        if type == .keyUp {
            if isLocal, let hold = gesture.pendingHold, hold.keyCode == keyCode {
                candidate = Candidate(timestamp: event.timestamp, keyCode: keyCode)
            }
            return
        }
        guard type == .keyDown else { return }
        cancelDelivery()
        candidate = nil
        if let instant = eventClock.instant(for: event.timestamp, receivedAt: .now),
           gesture.expireDoublePress(at: instant) {
            clearFeedback()
        }
        if keyCode == kVK_Escape, gesture.hasPendingConfirmation { return }
        let isQuit = flags == .maskCommand && NSEvent(cgEvent: event)?.characters?.lowercased() == "q"
        let eligible = routing.observeKeyDown(keyCode: keyCode, flags: flags, isQuit: isQuit, isLocal: isLocal)
        guard isQuit else {
            cancelConfirmation()
            return
        }
        if enabled, eligible {
            candidate = Candidate(timestamp: event.timestamp, keyCode: keyCode)
        }
    }

    private func shouldSuppress(_ type: CGEventType, event: CGEvent) -> Bool {
        if handleInterruption(type) { return false }
        guard !MacToolsSyntheticInputEvent.isMarked(event),
              event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else { return false }
        if IsSecureEventInputEnabled() {
            resetAfterInputInterruption()
            return false
        }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let instant = eventClock.instant(for: event.timestamp, receivedAt: .now)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if keyCode == kVK_Escape {
            var cancelsPending = false
            if type == .keyDown, !isRepeat {
                escapeClaimed = false
                if let target = gesture.pendingTarget {
                    let holdKeyIsDown = gesture.pendingHold.map {
                        CGEventSource.keyState(.combinedSessionState, key: $0.keyCode)
                    }
                    let flags = event.flags.intersection(Self.modifiers)
                    if let instant, !gesture.expireDoublePress(at: instant), holdKeyIsDown != false,
                       flags.isEmpty || (flags == .maskCommand && holdKeyIsDown == true) {
                        cancelsPending = destinationPID(for: event) == target.app.processIdentifier
                            && canDeliver(to: target)
                    }
                    cancelConfirmation()
                }
            }
            if escapeClaimed || cancelsPending {
                escapeClaimed = type == .keyDown
                finishDrainIfPossible()
                return true
            }
            return false
        }
        if type == .keyUp {
            let hold = gesture.pendingHold
            if let hold, hold.keyCode == keyCode {
                let target = candidate?.matches(timestamp: event.timestamp, keyCode: keyCode) == true
                    ? destination(for: event)
                    : nil
                if let instant, let confirmed = gesture.confirmHold(
                    generation: hold.generation, at: instant, target: target,
                    chordStillHeld: event.flags.intersection(Self.modifiers) == .maskCommand
                ) {
                    perform(confirmed)
                }
                candidate = nil
                cancelConfirmation()
            }
            if instant == nil { cancelConfirmation() }
            let claimed = gesture.keyUp(keyCode: keyCode, at: instant ?? .now)
            if claimed, let instant, let target = gesture.pendingTarget,
               case let .doublePress(interval) = quitRule.confirmation {
                scheduleFeedback(.doublePress(deadline: instant + interval), for: target)
            }
            finishDrainIfPossible()
            return claimed
        }
        guard type == .keyDown else { return false }

        let intent: QuitProtectionGesture<Destination>.Intent?
        if !isRepeat, instant != nil, let candidate, candidate.matches(timestamp: event.timestamp, keyCode: keyCode),
           event.flags.intersection(Self.modifiers) == .maskCommand, let target = destination(for: event) {
            intent = quitRule.intent(for: target, additionalModifier: nil, verifiedExtraModifier: nil)
        } else {
            intent = nil
        }
        candidate = nil
        switch gesture.keyDown(
            keyCode: keyCode, isRepeat: isRepeat,
            intent: intent, at: instant ?? .now
        ) {
        case .passThrough:
            if !gesture.hasPendingConfirmation { clearFeedback() }
            finishDrainIfPossible()
            return false
        case .suppress:
            return true
        case .startedDoublePress, .needsExtraModifier:
            clearFeedback()
            watchInputWhilePending()
            return true
        case let .startedHold(hold):
            watchInputWhilePending()
            if case let .hold(duration) = quitRule.confirmation {
                scheduleFeedback(.holding(duration: duration, deadline: hold.deadline), for: hold.target)
            }
            deadline?.cancel()
            deadline = Task { [weak self] in
                do { try await Task.sleep(until: hold.deadline, clock: .continuous) } catch { return }
                self?.showReleasePrompt(for: hold)
            }
            return true
        case let .confirmed(target):
            cancelConfirmation()
            perform(target)
            return true
        }
    }

    private func scheduleFeedback(_ state: Feedback, for target: Destination) {
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            self?.showFeedback?(target.app, state)
        }
    }

    private func clearFeedback() {
        feedbackTask?.cancel()
        feedbackTask = nil
        hideFeedback?()
    }

    private func destination(for event: CGEvent) -> Destination? {
        guard isProtecting, routing.commandIsEligible, Self.hasRequiredPermissions, !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
              let pid = destinationPID(for: event),
              matchesDestination(pid, frontmostPID: app.processIdentifier),
              let identifier = app.bundleIdentifier, !Self.forwardingApp(identifier),
              quitRule.includes(bundleIdentifier: identifier) else { return nil }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let reportedType = event.getIntegerValueField(.keyboardEventKeyboardType)
        let keyboardType = reportedType > 0 ? UInt32(clamping: reportedType) : UInt32(LMGetKbdType())
        guard let layout = QuitProtectionKeyboardLayout.current(keyboardType: keyboardType),
              layout.isQuitKey(keyCode) else { return nil }
        return Destination(app: app, generation: generation, keyCode: keyCode, keyboardLayout: layout)
    }

    private func destinationPID(for event: CGEvent) -> Int32? {
        Int32(exactly: event.getIntegerValueField(.eventTargetUnixProcessID))
    }

    private static func isWindowSwitcher(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "WindowSwitcherChooser"
    }

    private func matchesDestination(_ pid: Int32, frontmostPID: Int32?) -> Bool {
        QuitProtectionInputRouting.matchesDestination(
            pid, frontmostPID: frontmostPID,
            windowSwitcherIsVisible: NSApp?.windows.contains { $0.isVisible && Self.isWindowSwitcher($0) } == true
        )
    }

    private static func forwardingApp(_ identifier: String) -> Bool {
        let identifier = identifier.lowercased()
        return identifier == "com.apple.screensharing" || identifier.hasPrefix("com.microsoft.rdc")
            || identifier.hasPrefix("com.parallels.") || identifier.hasPrefix("com.vmware.")
            || identifier.hasPrefix("org.virtualbox.") || identifier.hasPrefix("com.utmapp.")
            || identifier.hasPrefix("com.teamviewer.") || identifier.hasPrefix("com.anydesk.")
            || identifier.hasPrefix("com.citrix.") || identifier.hasPrefix("com.realvnc.")
            || identifier == "codes.rambo.virtualbuddy" || identifier == "com.carriez.rustdesk"
            || identifier == "com.parsec.www" || identifier == "com.p5sys.jump.mac.viewer"
            || identifier == "com.p5sys.jump.mac.viewer.web"
            || identifier == "com.tigervnc.tigervnc"
    }

    private func showReleasePrompt(for hold: QuitProtectionGesture<Destination>.Hold) {
        guard gesture.pendingHold?.generation == hold.generation else { return }
        deadline = nil
        if IsSecureEventInputEnabled() {
            resetAfterInputInterruption()
            return
        }
        guard canDeliver(to: hold.target) else {
            invalidateDestination()
            return
        }
        guard CGEventSource.keyState(.combinedSessionState, key: hold.keyCode) else {
            clearFeedback()
            return
        }
        feedbackTask?.cancel()
        feedbackTask = nil
        showFeedback?(hold.target.app, .ready)
    }

    private func perform(_ target: Destination) {
        guard routing.commandIsEligible, canDeliver(to: target) else { return }
        if QuitProtectionChromeQuit.handles(bundleIdentifier: target.app.bundleIdentifier) {
            // Chrome's keyboard-only warning would treat replay as a new,
            // unconfirmed gesture. Invoke its normal Quit menu after ours.
            cancelDelivery()
            let pid = target.app.processIdentifier
            deliveryTask = Task { [weak self] in
                guard !Task.isCancelled, let self else { return }
                defer {
                    if !Task.isCancelled { self.deliveryTask = nil }
                }
                guard self.canDeliver(to: target) else { return }
                let result = await Task.detached(priority: .userInitiated) {
                    QuitProtectionChromeQuit.lookup(in: pid)
                }.value
                guard !Task.isCancelled, self.canDeliver(to: target) else { return }
                switch result {
                case .menuItem(let item):
                    // An AX timeout can occur after delivery. Never replay it.
                    if QuitProtectionChromeQuit.requiresRecoveryGuidance(afterPress: item.press()) {
                        self.scheduleFeedback(.chromeUnavailable, for: target)
                    }
                case .reassigned:
                    self.postQuitShortcut(to: target)
                case .unavailable:
                    self.scheduleFeedback(.chromeUnavailable, for: target)
                }
            }
            watchInputWhilePending()
        } else {
            postQuitShortcut(to: target)
        }
    }

    private func canDeliver(to target: Destination) -> Bool {
        isProtecting && Self.hasRequiredPermissions && !IsSecureEventInputEnabled() && target.generation == generation
            && !target.app.isTerminated
            && QuitProtectionKeyboardLayout.current(keyboardType: target.keyboardLayout.keyboardType) == target.keyboardLayout
            && target.keyboardLayout.isQuitKey(target.keyCode)
            && matchesDestination(target.app.processIdentifier,
                                  frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    private func postQuitShortcut(to target: Destination) {
        guard CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .privateState) else { return }
        source.keyboardType = target.keyboardLayout.keyboardType
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: target.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: target.keyCode, keyDown: false) else { return }
        for event in [down, up] {
            event.flags = .maskCommand
            MacToolsSyntheticInputEvent.mark(event)
            event.postToPid(target.app.processIdentifier)
        }
    }

    private func watchInputWhilePending() {
        guard inputWatch == nil else { return }
        inputWatch = Task { [weak self] in
            let interrupted = await QuitProtectionInputWatch.wasInterrupted(whilePending: {
                guard let self else { return false }
                return self.deliveryTask != nil || (self.gesture.hasPendingConfirmation
                    && (self.gesture.doublePressDeadline.map { $0 >= .now } ?? true))
            })
            guard !Task.isCancelled, let self else { return }
            self.inputWatch = nil
            if interrupted { self.resetAfterInputInterruption() }
        }
    }

    private func cancelDelivery() {
        deliveryTask?.cancel()
        deliveryTask = nil
    }

    private func handleInterruption(_ type: CGEventType) -> Bool {
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else { return false }
        resetAfterInputInterruption()
        Task { [weak self] in self?.availabilityChanged?() }
        return true
    }

    private func resetAfterInputInterruption() {
        invalidateDestination()
        gesture.resetObservation(preservingClaimedKeys: true)
        routing.reset(commandIsDown: CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand))
    }

    private func cancelConfirmation() {
        gesture.cancel()
        deadline?.cancel()
        deadline = nil
        if deliveryTask == nil {
            inputWatch?.cancel()
            inputWatch = nil
        }
        clearFeedback()
    }

    private func invalidateDestination(keepingCandidate: Bool = false) {
        generation &+= 1
        cancelDelivery()
        if !keepingCandidate { candidate = nil }
        cancelConfirmation()
    }

    private func invalidateSwitcherRouting() {
        routing.invalidate()
        invalidateDestination()
    }

    private func drainReleasedClaimsWhilePaused() {
        guard drain == nil else { return }
        drain = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2), tolerance: .milliseconds(250))
                } catch { return }
                guard let self, !self.enabled else { return }
                self.gesture.discardReleasedClaims {
                    CGEventSource.keyState(.combinedSessionState, key: $0)
                }
                if self.escapeClaimed, !CGEventSource.keyState(.combinedSessionState, key: UInt16(kVK_Escape)) {
                    self.escapeClaimed = false
                }
                if !self.hasClaimedInput {
                    self.stop()
                    return
                }
            }
        }
    }

    private func finishDrainIfPossible() {
        if !enabled, !hasClaimedInput {
            Task { [weak self] in
                guard let self, !self.enabled, !self.hasClaimedInput else { return }
                self.stop()
            }
        }
    }
}
