import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit.hidsystem
import MacToolsPluginKit
import OSLog

protocol InputRemappingEventTapping: AnyObject {
    var isCaptureSequenceActive: Bool { get }
    var emergencyStopHandler: (@Sendable () -> Void)? { get set }
    func update(rules: [InputRemappingRule])
    func start() -> Bool
    func stop()
    func beginInputCapture(_ handler: @escaping @Sendable (InputRemappingCapturedInput) -> Void) -> Bool
    func beginShortcutCapture(_ handler: @escaping @Sendable (ShortcutBinding) -> Void) -> Bool
    func cancelButtonCapture()
    func execute(_ action: InputRemappingRule.Action) -> Bool
}

enum InputRemappingSystemDefinedEvent {
    static let auxiliaryControlButtonSubtype: Int16 = 8
    static let keyDownState: Int32 = 0xA00
    static let keyUpState: Int32 = 0xB00

    static func data1(keyType: Int32, state: Int32) -> Int {
        Int((keyType << 16) | state)
    }
}

final class InputRemappingEventTap: InputRemappingEventTapping, @unchecked Sendable {
    static let syntheticMarker = MacToolsSyntheticInputEvent.marker
    private static let scrollCaptureQuiescence: TimeInterval = 0.25
    private static let emergencyStopKeyCode = UInt16(kVK_Escape)
    private static let emergencyStopModifiers: ShortcutModifiers = [.control, .option, .command]

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "InputRemappingEventTap"
    )
    private let rulesLock = NSLock()

    private var currentRules: [InputRemappingRule] = []
    private var inputCaptureHandler: (@Sendable (InputRemappingCapturedInput) -> Void)?
    private var shortcutCaptureHandler: (@Sendable (ShortcutBinding) -> Void)?
    private var capturedKeyAwaitingUp: UInt16?
    private var capturedMouseButtonAwaitingUp: Int64?
    private var capturedScrollUntil: TimeInterval?
    private var emergencyStopKeyAwaitingUp = false
    private var scrollCaptureGeneration = 0
    private var eventProcessor = InputRemappingEventProcessor()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let captureStartResult: Bool?
    var emergencyStopHandler: (@Sendable () -> Void)?

    init(captureStartResult: Bool? = nil) {
        self.captureStartResult = captureStartResult
    }

    var isCaptureSequenceActive: Bool {
        rulesLock.lock()
        defer { rulesLock.unlock() }
        return inputCaptureHandler != nil
            || shortcutCaptureHandler != nil
            || capturedKeyAwaitingUp != nil
            || capturedMouseButtonAwaitingUp != nil
            || capturedScrollUntil != nil
            || emergencyStopKeyAwaitingUp
    }

    func update(rules: [InputRemappingRule]) {
        rulesLock.lock()
        currentRules = rules
        rulesLock.unlock()
    }

    func start() -> Bool {
        if let captureStartResult {
            return captureStartResult
        }
        guard tap == nil else { return true }

        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            logger.error("Failed to create input remapping event tap")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        eventProcessor.reset()
        clearCaptureState()
        guard let tap else { return }

        CGEvent.tapEnable(tap: tap, enable: false)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    func beginInputCapture(_ handler: @escaping @Sendable (InputRemappingCapturedInput) -> Void) -> Bool {
        rulesLock.lock()
        inputCaptureHandler = handler
        rulesLock.unlock()

        guard start() else {
            cancelButtonCapture()
            return false
        }
        return true
    }

    func beginShortcutCapture(_ handler: @escaping @Sendable (ShortcutBinding) -> Void) -> Bool {
        rulesLock.lock()
        shortcutCaptureHandler = handler
        rulesLock.unlock()
        guard start() else {
            cancelButtonCapture()
            return false
        }
        return true
    }

    func cancelButtonCapture() {
        clearCaptureState()
        scheduleStopIfNoMonitoringNeeded()
    }

    private func clearCaptureState() {
        rulesLock.lock()
        inputCaptureHandler = nil
        shortcutCaptureHandler = nil
        capturedKeyAwaitingUp = nil
        capturedMouseButtonAwaitingUp = nil
        capturedScrollUntil = nil
        emergencyStopKeyAwaitingUp = false
        scrollCaptureGeneration += 1
        rulesLock.unlock()
    }

    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        return Unmanaged<InputRemappingEventTap>
            .fromOpaque(info)
            .takeUnretainedValue()
            .handle(type: type, event: event)
    }

    func handle(type: CGEventType, event: CGEvent,
                performAction: ((InputRemappingRule.Action) -> Bool)? = nil) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard !Self.isMarkedSynthetic(event) else {
            return Unmanaged.passUnretained(event)
        }
        let execute = performAction ?? self.execute

        if type == .keyDown || type == .keyUp {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if consumeEmergencyStop(type: type, keyCode: keyCode, flags: event.flags) {
                if type == .keyDown { reportInputClaim() }
                return nil
            }
        }

        if type == .keyDown || type == .keyUp {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if consumeCapturedKeyEvent(type: type, keyCode: keyCode) {
                if type == .keyDown { reportInputClaim() }
                return nil
            }
        }

        if type == .scrollWheel,
           consumeCapturedScroll(at: TimeInterval(event.timestamp) / 1_000_000_000) {
            return nil
        }

        if type == .keyDown, let shortcut = shortcutCapture(from: event) {
            rulesLock.lock()
            let handler = shortcutCaptureHandler
            shortcutCaptureHandler = nil
            if handler != nil { capturedKeyAwaitingUp = shortcut.keyCode }
            rulesLock.unlock()
            if let handler {
                reportInputClaim()
                handler(shortcut)
                return nil
            }
        }

        if let capturedInput = capturedInput(from: event, type: type) {
            rulesLock.lock()
            let handler = inputCaptureHandler
            inputCaptureHandler = nil
            if handler != nil {
                switch capturedInput {
                case let .keyboard(keyCode, _):
                    capturedKeyAwaitingUp = keyCode
                case let .mouseButton(number, _):
                    capturedMouseButtonAwaitingUp = number
                case .scroll:
                    capturedScrollUntil = TimeInterval(event.timestamp) / 1_000_000_000
                        + Self.scrollCaptureQuiescence
                    scrollCaptureGeneration += 1
                }
            }
            rulesLock.unlock()
            if let handler {
                if type != .scrollWheel { reportInputClaim() }
                if case .scroll = capturedInput {
                    scheduleScrollCaptureCompletion()
                }
                handler(capturedInput)
                return nil
            }
        }

        if type == .keyDown || type == .keyUp {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let rules = rulesSnapshot()
            let shouldConsume = eventProcessor.shouldConsumeKeyboard(
                isKeyDown: type == .keyDown,
                keyCode: keyCode,
                flags: event.flags,
                isMarkedSynthetic: false,
                rules: rules,
                execute: { action in
                    reportInputClaim()
                    return execute(action)
                }
            )
            return shouldConsume ? nil : Unmanaged.passUnretained(event)
        }

        if type == .scrollWheel, let direction = scrollDirection(from: event) {
            let rules = rulesSnapshot()
            let shouldConsume = InputRemappingRuleMatcher.scrollRule(for: direction, flags: event.flags, in: rules).map { execute($0.action) } == true
            return shouldConsume ? nil : Unmanaged.passUnretained(event)
        }

        let phase: InputRemappingMouseEventPhase
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            phase = .down
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            phase = .up
        default:
            return Unmanaged.passUnretained(event)
        }

        let buttonNumber = mouseButtonNumber(for: type, event: event)
        if phase == .up, consumeCapturedMouseUp(buttonNumber) {
            return nil
        }
        let rules = rulesSnapshot()

        let shouldConsume = eventProcessor.shouldConsume(
            phase: phase,
            buttonNumber: buttonNumber,
            flags: event.flags,
            isMarkedSynthetic: false,
            rules: rules,
            timestamp: TimeInterval(event.timestamp) / 1_000_000_000,
            execute: { action in
                if phase == .down { reportInputClaim() }
                return execute(action)
            }
        )
        return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    private func reportInputClaim() {
        NotificationCenter.default.post(name: .macToolsWillClaimPhysicalInput, object: nil)
    }

    static func isMarkedSynthetic(_ event: CGEvent) -> Bool {
        MacToolsSyntheticInputEvent.isMarked(event)
    }

    private func shortcutCapture(from event: CGEvent) -> ShortcutBinding? {
        ShortcutBinding(
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: InputRemappingRule.modifiers(from: event.flags)
        )
    }

    private func rulesSnapshot() -> [InputRemappingRule] {
        rulesLock.lock()
        defer { rulesLock.unlock() }
        return currentRules
    }

    private func consumeCapturedKeyEvent(type: CGEventType, keyCode: UInt16) -> Bool {
        rulesLock.lock()
        guard capturedKeyAwaitingUp == keyCode else {
            rulesLock.unlock()
            return false
        }
        if type == .keyUp {
            capturedKeyAwaitingUp = nil
        }
        rulesLock.unlock()
        if type == .keyUp {
            scheduleStopIfNoMonitoringNeeded()
        }
        return true
    }

    private func consumeEmergencyStop(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        rulesLock.lock()
        if type == .keyUp, keyCode == Self.emergencyStopKeyCode, emergencyStopKeyAwaitingUp {
            emergencyStopKeyAwaitingUp = false
            rulesLock.unlock()
            scheduleStopIfNoMonitoringNeeded()
            return true
        }
        guard type == .keyDown,
              keyCode == Self.emergencyStopKeyCode,
              InputRemappingRule.modifiers(from: flags) == Self.emergencyStopModifiers
        else {
            rulesLock.unlock()
            return false
        }
        let shouldNotify = !emergencyStopKeyAwaitingUp
        emergencyStopKeyAwaitingUp = true
        inputCaptureHandler = nil
        shortcutCaptureHandler = nil
        capturedKeyAwaitingUp = nil
        capturedMouseButtonAwaitingUp = nil
        capturedScrollUntil = nil
        scrollCaptureGeneration += 1
        let handler = emergencyStopHandler
        rulesLock.unlock()
        if shouldNotify {
            handler?()
        }
        return true
    }

    private func consumeCapturedScroll(at timestamp: TimeInterval) -> Bool {
        rulesLock.lock()
        guard let capturedScrollUntil else {
            rulesLock.unlock()
            return false
        }
        guard timestamp <= capturedScrollUntil else {
            self.capturedScrollUntil = nil
            scrollCaptureGeneration += 1
            rulesLock.unlock()
            scheduleStopIfNoMonitoringNeeded()
            return false
        }
        self.capturedScrollUntil = timestamp + Self.scrollCaptureQuiescence
        scrollCaptureGeneration += 1
        rulesLock.unlock()
        scheduleScrollCaptureCompletion()
        return true
    }

    private func consumeCapturedMouseUp(_ buttonNumber: Int64) -> Bool {
        rulesLock.lock()
        guard capturedMouseButtonAwaitingUp == buttonNumber else {
            rulesLock.unlock()
            return false
        }
        capturedMouseButtonAwaitingUp = nil
        rulesLock.unlock()
        scheduleStopIfNoMonitoringNeeded()
        return true
    }

    private func scheduleScrollCaptureCompletion() {
        rulesLock.lock()
        let generation = scrollCaptureGeneration
        rulesLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollCaptureQuiescence) { [weak self] in
            guard let self else { return }
            self.rulesLock.lock()
            guard self.scrollCaptureGeneration == generation else {
                self.rulesLock.unlock()
                return
            }
            self.capturedScrollUntil = nil
            self.rulesLock.unlock()
            self.scheduleStopIfNoMonitoringNeeded()
        }
    }

    private func scheduleStopIfNoMonitoringNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCaptureSequenceActive else { return }
            let needsMonitoring = self.rulesSnapshot().contains { $0.isRunnable && $0.requiresEventTap }
            if !needsMonitoring {
                self.stop()
            }
        }
    }

    private func capturedInput(from event: CGEvent, type: CGEventType) -> InputRemappingCapturedInput? {
        let modifiers = InputRemappingRule.modifiers(from: event.flags)
        switch type {
        case .keyDown:
            return .keyboard(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), modifiers: modifiers)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .mouseButton(number: mouseButtonNumber(for: type, event: event), modifiers: modifiers)
        case .scrollWheel:
            guard let direction = scrollDirection(from: event) else { return nil }
            return .scroll(direction: direction, modifiers: modifiers)
        default:
            return nil
        }
    }

    private func mouseButtonNumber(for type: CGEventType, event: CGEvent) -> Int64 {
        switch type {
        case .leftMouseDown, .leftMouseUp: 0
        case .rightMouseDown, .rightMouseUp: 1
        default: event.getIntegerValueField(.mouseEventButtonNumber)
        }
    }

    private func scrollDirection(from event: CGEvent) -> InputRemappingScrollDirection? {
        let vertical = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        if vertical > 0 { return .up }
        if vertical < 0 { return .down }
        let horizontal = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        if horizontal > 0 { return .right }
        if horizontal < 0 { return .left }
        return nil
    }

    func execute(_ action: InputRemappingRule.Action) -> Bool {
        switch action {
        case let .shortcut(binding):
            return post(keyCode: binding.keyCode, modifiers: binding.modifiers)
        case let .keyTap(keyTap):
            guard let keyTap else { return false }
            return KeyboardKeyTapEventPoster.post(keyTap)
        case .mouseBack:
            return postMouse(button: 3)
        case .mouseForward:
            return postMouse(button: 4)
        case .mouseMiddle:
            return postMouse(button: 2)
        case .missionControl:
            return post(keyCode: UInt16(kVK_UpArrow), modifiers: [.control])
        case .spaceLeft:
            return post(keyCode: UInt16(kVK_LeftArrow), modifiers: [.control])
        case .spaceRight:
            return post(keyCode: UInt16(kVK_RightArrow), modifiers: [.control])
        case .mediaPlayPause:
            return postSystemKey(NX_KEYTYPE_PLAY)
        case .volumeDown:
            return postSystemKey(NX_KEYTYPE_SOUND_DOWN)
        case .volumeUp:
            return postSystemKey(NX_KEYTYPE_SOUND_UP)
        }
    }

    private func postMouse(button: Int64) -> Bool {
        guard let cursorEvent = CGEvent(source: nil),
              let down = CGEvent(
                mouseEventSource: nil,
                mouseType: .otherMouseDown,
                mouseCursorPosition: cursorEvent.location,
                mouseButton: .center
              ),
              let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .otherMouseUp,
                mouseCursorPosition: cursorEvent.location,
                mouseButton: .center
              )
        else {
            logger.error("Failed to create remapped mouse events")
            return false
        }

        for event in [down, up] {
            event.setIntegerValueField(.mouseEventButtonNumber, value: button)
            postSynthetic(event)
        }
        return true
    }

    private func post(keyCode: UInt16, modifiers: ShortcutModifiers) -> Bool {
        guard let down = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: false
        ) else {
            logger.error("Failed to create remapped keyboard events")
            return false
        }

        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }

        for event in [down, up] {
            event.flags = flags
            postSynthetic(event)
        }
        return true
    }

    private func postSystemKey(_ keyType: Int32) -> Bool {
        guard let down = makeSystemKeyEvent(
            keyType: keyType,
            state: InputRemappingSystemDefinedEvent.keyDownState
        ), let up = makeSystemKeyEvent(
            keyType: keyType,
            state: InputRemappingSystemDefinedEvent.keyUpState
        )
        else {
            logger.error("Failed to create remapped system key events")
            return false
        }

        postSynthetic(down)
        postSynthetic(up)
        return true
    }

    private func makeSystemKeyEvent(keyType: Int32, state: Int32) -> CGEvent? {
        return NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: InputRemappingSystemDefinedEvent.auxiliaryControlButtonSubtype,
            data1: InputRemappingSystemDefinedEvent.data1(keyType: keyType, state: state),
            data2: -1
        )?.cgEvent
    }

    private func postSynthetic(_ event: CGEvent) {
        MacToolsSyntheticInputEvent.mark(event)
        event.post(tap: .cghidEventTap)
    }
}
