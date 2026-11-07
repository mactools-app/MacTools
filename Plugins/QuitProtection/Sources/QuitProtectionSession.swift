import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MacToolsPluginKit

/// The session tap records the physical gesture. Only the later tap, after
/// macOS has attached the destination PID, may claim the shortcut.
@MainActor
final class QuitProtectionSession {
    enum Feedback {
        case holding(duration: Duration, deadline: ContinuousClock.Instant)
        case ready
        case doublePress(deadline: ContinuousClock.Instant)
    }

    struct Destination: Equatable {
        let app: NSRunningApplication
        let generation: UInt64
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
    private var quitRule = QuitProtectionRule()
    private var enabled = false
    private var generation: UInt64 = 0
    private var commandWasDown = false
    private var commandIsEligible = false
    private var candidate: Candidate?
    private var eventClock = QuitProtectionEventClock()
    private var gesture = QuitProtectionGesture<Destination>()
    private var escapeClaimed = false
    private var deadline: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    var showFeedback: ((NSRunningApplication, Feedback) -> Void)?
    var hideFeedback: (() -> Void)?
    var availabilityChanged: (() -> Void)?

    var isRunning: Bool {
        guard let sessionTap, let deliveryTap else { return false }
        return CGEvent.tapIsEnabled(tap: sessionTap.port) && CGEvent.tapIsEnabled(tap: deliveryTap.port)
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
                stop()
                start()
            }
        } else if gesture.hasClaimedKeys || escapeClaimed {
            if drain == nil {
                drain = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    self?.stop()
                }
            }
        } else {
            stop()
        }
    }

    func stop() {
        drain?.cancel()
        drain = nil
        invalidateDestination()
        gesture.resetObservation()
        escapeClaimed = false
        commandWasDown = false
        eventClock = QuitProtectionEventClock()
        sessionTap?.stop()
        deliveryTap?.stop()
        sessionTap = nil
        deliveryTap = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func start() {
        guard let observed = makeTap(
            at: .cgSessionEventTap, place: .headInsertEventTap,
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
        commandWasDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
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
            if gesture.hasPendingConfirmation { invalidateDestination() }
            return
        }
        if type == .flagsChanged {
            if !flags.contains(.maskCommand) {
                commandWasDown = false
                commandIsEligible = false
                candidate = nil
                if gesture.pendingHold != nil { cancelConfirmation() }
            } else if !commandWasDown {
                commandWasDown = true
                commandIsEligible = isLocal && (keyCode == kVK_Command || keyCode == kVK_RightCommand)
            }
            if gesture.pendingHold != nil && flags != .maskCommand { cancelConfirmation() }
            return
        }
        if type == .keyUp {
            if isLocal, let hold = gesture.pendingHold, hold.keyCode == keyCode {
                candidate = Candidate(timestamp: event.timestamp, keyCode: keyCode)
            }
            return
        }
        guard type == .keyDown else { return }
        candidate = nil
        if keyCode == kVK_Escape, gesture.hasPendingConfirmation { return }
        guard flags.contains(.maskCommand),
              NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased() == "q" else {
            if commandWasDown { commandIsEligible = false }
            cancelConfirmation()
            return
        }
        if enabled, isLocal, commandIsEligible, !IsSecureEventInputEnabled() {
            candidate = Candidate(timestamp: event.timestamp, keyCode: keyCode)
        }
    }

    private func shouldSuppress(_ type: CGEventType, event: CGEvent) -> Bool {
        if handleInterruption(type) { return false }
        guard !MacToolsSyntheticInputEvent.isMarked(event),
              event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else { return false }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == kVK_Escape, escapeClaimed || (type == .keyDown && gesture.hasPendingConfirmation) {
            escapeClaimed = type == .keyDown
            cancelConfirmation()
            finishDrainIfPossible()
            return true
        }
        if type == .keyUp {
            let hold = gesture.pendingHold
            let instant = eventClock.instant(for: event.timestamp, receivedAt: .now)
            if let hold, hold.keyCode == keyCode {
                let target = candidate?.matches(timestamp: event.timestamp, keyCode: keyCode) == true
                    ? destination(for: event)
                    : nil
                if let instant, let confirmed = gesture.confirmHold(
                    generation: hold.generation, at: instant, target: target,
                    chordStillHeld: event.flags.intersection(Self.modifiers) == .maskCommand
                ) {
                    perform(confirmed, keyCode: keyCode)
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
        let instant = eventClock.instant(for: event.timestamp, receivedAt: .now)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
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
            return false
        case .suppress:
            return true
        case .startedDoublePress, .needsExtraModifier:
            clearFeedback()
            return true
        case let .startedHold(hold):
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
            perform(target, keyCode: keyCode)
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
        guard enabled, commandIsEligible, isRunning, !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
              event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(app.processIdentifier),
              let identifier = app.bundleIdentifier, !Self.forwardingApp(identifier),
              quitRule.includes(bundleIdentifier: identifier) else { return nil }
        return Destination(app: app, generation: generation)
    }

    private static func forwardingApp(_ identifier: String) -> Bool {
        let identifier = identifier.lowercased()
        return identifier == "com.apple.screensharing" || identifier.hasPrefix("com.microsoft.rdc")
            || identifier.hasPrefix("com.parallels.") || identifier.hasPrefix("com.vmware.")
            || identifier.hasPrefix("org.virtualbox.") || identifier.hasPrefix("com.utmapp.")
            || identifier.hasPrefix("com.teamviewer.") || identifier.hasPrefix("com.anydesk.")
            || identifier.hasPrefix("com.citrix.") || identifier.hasPrefix("com.realvnc.")
    }

    private func showReleasePrompt(for hold: QuitProtectionGesture<Destination>.Hold) {
        guard gesture.pendingHold?.generation == hold.generation else { return }
        deadline = nil
        feedbackTask?.cancel()
        feedbackTask = nil
        showFeedback?(hold.target.app, .ready)
    }

    private func perform(_ target: Destination, keyCode: UInt16) {
        guard commandIsEligible, canDeliver(to: target) else { return }
        if target.app.bundleIdentifier == QuitProtectionChromeQuit.bundleIdentifier {
            // Chrome's keyboard-only warning would treat replay as a new,
            // unconfirmed gesture. Invoke its normal Quit menu after ours.
            Task { [weak self] in
                guard let self, self.canDeliver(to: target) else { return }
                let item = QuitProtectionChromeQuit.menuItem(in: target.app.processIdentifier)
                guard self.canDeliver(to: target) else { return }
                if let item {
                    guard AXUIElementSetMessagingTimeout(item, 0.025) == .success else { return }
                    // An AX timeout can occur after delivery. Never replay it.
                    AXUIElementPerformAction(item, kAXPressAction as CFString)
                } else {
                    self.postQuitShortcut(to: target.app, keyCode: keyCode)
                }
            }
        } else {
            postQuitShortcut(to: target.app, keyCode: keyCode)
        }
    }

    private func canDeliver(to target: Destination) -> Bool {
        enabled && isRunning && !IsSecureEventInputEnabled() && target.generation == generation
            && !target.app.isTerminated && NSWorkspace.shared.frontmostApplication == target.app
    }

    private func postQuitShortcut(to app: NSRunningApplication, keyCode: UInt16) {
        guard CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        for event in [down, up] {
            event.flags = .maskCommand
            MacToolsSyntheticInputEvent.mark(event)
            event.postToPid(app.processIdentifier)
        }
    }

    private func handleInterruption(_ type: CGEventType) -> Bool {
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else { return false }
        invalidateDestination()
        gesture.resetObservation()
        escapeClaimed = false
        commandWasDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
        Task { [weak self] in self?.availabilityChanged?() }
        return true
    }

    private func cancelConfirmation() {
        gesture.cancel()
        deadline?.cancel()
        deadline = nil
        clearFeedback()
    }

    private func invalidateDestination() {
        generation &+= 1
        commandIsEligible = false
        candidate = nil
        cancelConfirmation()
    }

    private func finishDrainIfPossible() {
        if !enabled, !gesture.hasClaimedKeys, !escapeClaimed {
            Task { [weak self] in
                guard let self, !self.enabled, !self.gesture.hasClaimedKeys, !self.escapeClaimed else { return }
                self.stop()
            }
        }
    }
}
