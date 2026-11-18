import ApplicationServices
import Carbon.HIToolbox
import Foundation
import MacToolsPluginKit

protocol WindowSwitcherShortcutListening: AnyObject {
    var onShortcutPressed: @MainActor (Bool, Bool, Bool) -> Void { get set }
    var onShortcutReleased: @MainActor () -> Void { get set }
    var onEscape: @MainActor () -> Void { get set }
    var onAccessibilityRevoked: @MainActor () -> Void { get set }
    var isRunning: Bool { get }
    func start()
    func stop()
    func configure(allBinding: ShortcutBinding?, currentAppBinding: ShortcutBinding?)
    func setEditing(_ value: Bool)
    func setSessionActive(_ value: Bool)
}

final class WindowSwitcherShortcutTap: WindowSwitcherShortcutListening, @unchecked Sendable {
    static let willHandleShortcut = Notification.Name("MacTools.WindowSwitcher.willHandleShortcut")

    var onShortcutPressed: @MainActor (_ reversed: Bool, _ isRepeat: Bool, _ currentApp: Bool) -> Void = { _, _, _ in }
    var onShortcutReleased: @MainActor () -> Void = {}
    var onEscape: @MainActor () -> Void = {}
    var onAccessibilityRevoked: @MainActor () -> Void = {}
    private var didReportAccessibilityRevocation = false

    private let lock = NSLock()
    private var currentBinding: ShortcutBinding?
    private var currentAppBinding: ShortcutBinding?
    private var activeModifiers: ShortcutModifiers?
    private var isEditing = false
    private var sessionActive = false
    private var deliveryGeneration = 0
    private var lifecycleGeneration = 0
    private let accessibilityTrusted: @Sendable () -> Bool
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(accessibilityTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.accessibilityTrusted = accessibilityTrusted
    }

    var isRunning: Bool {
        lock.withLock { tap != nil }
    }

    func start() {
        lock.lock()
        let alreadyRunning = tap != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        lock.lock()
        tap = newTap
        runLoopSource = source
        lock.unlock()
    }

    func stop() {
        let state = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
            let state = (tap, runLoopSource)
            tap = nil
            runLoopSource = nil
            activeModifiers = nil
            didReportAccessibilityRevocation = false
            deliveryGeneration += 1
            lifecycleGeneration += 1
            sessionActive = false; isEditing = false
            return state
        }

        if let tap = state.0 {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = state.1 {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    func configure(allBinding: ShortcutBinding?, currentAppBinding: ShortcutBinding?) {
        lock.withLock {
            self.currentBinding = allBinding
            self.currentAppBinding = currentAppBinding
        }
    }

    func setEditing(_ value: Bool) { lock.withLock { isEditing = value } }
    func setSessionActive(_ value: Bool) {
        lock.withLock {
            sessionActive = value
            if !value { deliveryGeneration += 1 }
        }
    }

    private func activeModifiersSnapshot() -> ShortcutModifiers? {
        lock.withLock { activeModifiers }
    }

    private func setActiveModifiers(_ modifiers: ShortcutModifiers?) {
        lock.withLock {
            activeModifiers = modifiers
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard accessibilityTrusted() else {
            let notify = lock.withLock {
                activeModifiers = nil
                guard !didReportAccessibilityRevocation else { return false }
                didReportAccessibilityRevocation = true
                return true
            }
            if notify { deliverLifecycleCallback { $0.onAccessibilityRevoked() } }
            return Unmanaged.passUnretained(event)
        }
        lock.withLock { didReportAccessibilityRevocation = false }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ tap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            return handleKeyDown(event)
        case .flagsChanged:
            return handleFlagsChanged(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Keep the configured Tab switch chord inside the persistent search panel.
        // Ordinary editing shortcuts and IME keys still belong to its responder.
        let editing = lock.withLock { isEditing }
        if editing, ![UInt16(kVK_Tab), UInt16(kVK_ANSI_Grave)].contains(keyCode) { return Unmanaged.passUnretained(event) }
        if keyCode == UInt16(kVK_Escape), lock.withLock({ sessionActive || activeModifiers != nil }) {
            setActiveModifiers(nil)
            deliverLifecycleCallback { $0.onEscape() }
            return nil
        }

        // Escape and text editing belong to the panel's native responder chain,
        // including marked-text cancellation by an input method.
        let bindings = lock.withLock { [(currentBinding, false), (currentAppBinding, true)] }
        // An explicitly configured chord wins over another binding's implicit
        // Shift-to-reverse variant, regardless of which scope owns it.
        let exact = bindings.first { binding, _ in
            binding.map { keyCode == $0.keyCode && $0.matches(eventFlags: event.flags, allowingExtraShift: false) } ?? false
        }
        guard let match = exact ?? bindings.first(where: { binding, _ in
            binding.map { keyCode == $0.keyCode && $0.matches(eventFlags: event.flags, allowingExtraShift: true) } ?? false
        }), let binding = match.0 else { return Unmanaged.passUnretained(event) }
        let currentApp = match.1

        // The tap runs on the main run loop. Notify Quit Protection before
        // consuming the key or queuing chooser presentation.
        NotificationCenter.default.post(name: Self.willHandleShortcut, object: nil)
        setActiveModifiers(binding.modifiers)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let reversed = !binding.modifiers.contains(.shift) && event.flags.contains(.maskShift)

        let generation = lock.withLock { deliveryGeneration }
        DispatchQueue.main.async {
            guard self.lock.withLock({ self.deliveryGeneration == generation }) else { return }
            self.onShortcutPressed(reversed, isRepeat, currentApp)
        }

        return nil
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let activeModifiers = activeModifiersSnapshot(),
              !activeModifiers.isHeld(in: event.flags)
        else {
            return Unmanaged.passUnretained(event)
        }

        setActiveModifiers(nil)
        deliverLifecycleCallback { $0.onShortcutReleased() }
        return Unmanaged.passUnretained(event)
    }

    // Session setup invalidates queued presses but must preserve the release
    // already queued behind a quick press. Only a stopped listener ends this epoch.
    private func deliverLifecycleCallback(_ action: @escaping @MainActor @Sendable (WindowSwitcherShortcutTap) -> Void) {
        let generation = lock.withLock { lifecycleGeneration }
        DispatchQueue.main.async {
            guard self.lock.withLock({ self.lifecycleGeneration == generation }) else { return }
            action(self)
        }
    }

    private nonisolated static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return nil
        }

        let tap = Unmanaged<WindowSwitcherShortcutTap>.fromOpaque(userInfo).takeUnretainedValue()
        return tap.handle(type: type, event: event)
    }
}

private extension ShortcutBinding {
    func matches(eventFlags: CGEventFlags, allowingExtraShift: Bool) -> Bool {
        let actual = eventFlags.significantShortcutFlags
        let required = modifiers.cgEventFlags

        if allowingExtraShift, !required.contains(.maskShift) {
            return actual == required || actual == required.union(.maskShift)
        }

        return actual == required
    }
}

private extension ShortcutModifiers {
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) {
            flags.insert(.maskCommand)
        }
        if contains(.control) {
            flags.insert(.maskControl)
        }
        if contains(.option) {
            flags.insert(.maskAlternate)
        }
        if contains(.shift) {
            flags.insert(.maskShift)
        }
        return flags
    }

    func isHeld(in eventFlags: CGEventFlags) -> Bool {
        let actual = eventFlags.significantShortcutFlags
        return actual.intersection(cgEventFlags) == cgEventFlags
    }
}

private extension CGEventFlags {
    var significantShortcutFlags: CGEventFlags {
        intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
