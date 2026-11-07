import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
private final class QuitProtectionFixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
        styleMask: [.titled, .closable], backing: .buffered, defer: false
    )
    private let status = NSTextField(labelWithString: "Ready")
    private let observeRouting: Bool
    private let verifyNativeMenu: Bool
    private var rule = QuitProtectionRule()
    private var gesture = QuitProtectionGesture<Int>()
    private var monitor: Any?
    private var deadline: Task<Void, Never>?
    private var taps: [CFMachPort] = []
    private var escapeClaimed = false
    private var closingFixture = false
    private var quitRequests = 0

    init(observeRouting: Bool, verifyNativeMenu: Bool, confirmation: QuitProtectionRule.Confirmation) {
        self.observeRouting = observeRouting
        self.verifyNativeMenu = verifyNativeMenu
        rule.confirmation = confirmation
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        rule.isEnabled = true
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            rule.selectedApps = [bundleIdentifier]
        }

        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu

        if verifyNativeMenu {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                         timestamp: 0, windowNumber: 0, context: nil, characters: "q",
                                         charactersIgnoringModifiers: "q", isARepeat: false, keyCode: UInt16(kVK_ANSI_Q))
            guard let event, deliverQuit(event), quitRequests == 1 else {
                FileHandle.standardError.write(Data("The fixture did not receive exactly one native Quit request.\n".utf8))
                exit(1)
            }
            print("Native Quit reached the fixture once and the termination delegate cancelled it.")
            exit(0)
        }

        let instructions = NSTextField(wrappingLabelWithString: instructions)
        instructions.frame = NSRect(x: 22, y: 74, width: 436, height: 54)
        status.frame = NSRect(x: 22, y: 36, width: 436, height: 24)
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Quit Protection Fixture"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(instructions)
        window.contentView?.addSubview(status)
        window.center()

        if observeRouting {
            installRoutingObservers()
        } else {
            let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var instructions: String {
        if observeRouting {
            return "Routing observation only. The fixture stays open if it receives a native Quit request."
        }
        switch rule.confirmation {
        case .hold:
            return "Tap ⌘Q to cancel, or hold it for 0.8 seconds to invoke the fixture’s native Quit menu item."
        case .doublePress:
            return "Press ⌘Q twice within 0.6 seconds to invoke the fixture’s native Quit menu item."
        case .extraModifier:
            return "Press ⌥⌘Q to invoke the fixture’s native Quit menu item."
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !closingFixture else { return .terminateNow }
        quitRequests += 1
        status.stringValue = "Native Quit requested (\(quitRequests)). Fixture kept open."
        if observeRouting {
            Self.log("nativeQuitRequests=\(quitRequests) fixturePID=\(ProcessInfo.processInfo.processIdentifier)")
        }
        return .terminateCancel
    }

    func windowDidResignKey(_ notification: Notification) {
        cancel("Focus changed. Hold cancelled.", resetObservation: true)
        escapeClaimed = false
    }

    func windowWillClose(_ notification: Notification) {
        closingFixture = true
        cancel("", resetObservation: true)
        if let monitor { NSEvent.removeMonitor(monitor) }
        for tap in taps { CFMachPortInvalidate(tap) }
        NSApp.terminate(nil)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(Self.shortcutModifiers)
        if event.type == .flagsChanged {
            if gesture.pendingHold != nil, flags != .command {
                cancel("Modifier changed. Hold cancelled.")
            }
            return event
        }

        if event.type != .keyDown && event.type != .keyUp {
            gesture.cancelDoublePress()
            return event
        }

        if event.keyCode == UInt16(kVK_Escape) {
            if event.type == .keyUp, escapeClaimed {
                escapeClaimed = false
                return nil
            }
            if event.type == .keyDown, escapeClaimed || gesture.hasPendingConfirmation {
                escapeClaimed = true
                cancel("Escape pressed. Confirmation cancelled.")
                return nil
            }
        }

        if event.type == .keyUp {
            guard gesture.keyUp(keyCode: event.keyCode, at: .now) else { return event }
            if deadline != nil { cancel("Released early. Quit cancelled.") }
            return nil
        }

        let result = gesture.keyDown(
            keyCode: event.keyCode, isRepeat: event.isARepeat, intent: intent(for: event, flags: flags), at: .now
        )
        switch result {
        case .passThrough:
            return event
        case .suppress:
            return nil
        case .startedDoublePress:
            status.stringValue = "Press ⌘Q again to confirm."
            return nil
        case .needsExtraModifier:
            status.stringValue = "Press ⌥⌘Q to confirm."
            return nil
        case .confirmed:
            if !deliverQuit(event) { status.stringValue = "The fixture menu did not handle the shortcut." }
            return nil
        case let .startedHold(attempt):
            status.stringValue = "Keep holding ⌘Q…"
            deadline = Task { [weak self] in
                do {
                    try await Task.sleep(until: attempt.deadline, clock: .continuous)
                } catch {
                    return
                }
                self?.confirm(attempt, event: event)
            }
            return nil
        }
    }

    private func intent(for event: NSEvent, flags: NSEvent.ModifierFlags) -> QuitProtectionGesture<Int>.Intent? {
        guard event.charactersIgnoringModifiers?.lowercased() == "q", let target = currentTarget else { return nil }
        guard flags == .command || flags == [.command, .option] else { return nil }
        let additionalModifier: QuitProtectionRule.Modifier? = flags.contains(.option) ? .option : nil
        // Option is available in this fixture's own menu. External apps need separate conflict checks.
        return rule.intent(for: target, additionalModifier: additionalModifier, verifiedExtraModifier: .option)
    }

    private var currentTarget: Int? {
        guard NSApp.isActive, window.isKeyWindow, rule.includes(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            return nil
        }
        return window.windowNumber
    }

    private func confirm(_ attempt: QuitProtectionGesture<Int>.Hold, event: NSEvent) {
        guard gesture.pendingHold?.generation == attempt.generation else { return }
        deadline = nil
        let commandIsDown = NSEvent.modifierFlags.intersection(Self.shortcutModifiers) == .command
        let keyIsDown = CGEventSource.keyState(.combinedSessionState, key: event.keyCode)
        guard gesture.confirmHold(generation: attempt.generation, at: .now, target: currentTarget,
                                  chordStillHeld: commandIsDown && keyIsDown) != nil else {
            status.stringValue = "Hold cancelled. Command down: \(commandIsDown), key down: \(keyIsDown)."
            return
        }
        if !deliverQuit(event) {
            status.stringValue = "The fixture menu did not handle the shortcut."
        }
    }

    private func deliverQuit(_ event: NSEvent) -> Bool {
        // The prototype routes only to the fixture's own menu.
        guard let baseEvent = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: .command,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, characters: "q",
            charactersIgnoringModifiers: "q", isARepeat: false, keyCode: event.keyCode
        ) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: baseEvent) == true
    }

    private func cancel(_ message: String, resetObservation: Bool = false) {
        let wasPending = gesture.hasPendingConfirmation || deadline != nil
        deadline?.cancel()
        deadline = nil
        if resetObservation { gesture.resetObservation() } else { gesture.cancel() }
        if wasPending { status.stringValue = message }
    }

    private func installRoutingObservers() {
        guard CGPreflightListenEventAccess() else {
            status.stringValue = "Input Monitoring unavailable for this fixture."
            Self.log("Routing observation unavailable: listen preflight failed.")
            return
        }

        for location in [CGEventTapLocation.cgSessionEventTap, .cgAnnotatedSessionEventTap] {
            guard let tap = Self.makeRoutingTap(at: location),
                  let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                Self.log("Could not install listen-only tap at \(location.rawValue).")
                continue
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            taps.append(tap)
        }
        status.stringValue = "\(taps.count) listen-only taps active."
        Self.log("listenOnlyTaps=\(taps.count) fixturePID=\(ProcessInfo.processInfo.processIdentifier)")
    }

    private static func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func preflight() {
        let canListen = CGPreflightListenEventAccess()
        print("Listen event access: \(canListen)")
        print("Post event access: \(CGPreflightPostEventAccess())")
        guard canListen else { return }

        for (name, location) in [("Session", CGEventTapLocation.cgSessionEventTap),
                                 ("Annotated session", .cgAnnotatedSessionEventTap)] {
            let tap = makeRoutingTap(at: location)
            print("\(name) listen-only tap created: \(tap != nil)")
            if let tap { CFMachPortInvalidate(tap) }
        }
    }

    private static func makeRoutingTap(at location: CGEventTapLocation) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: location, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue,
            callback: observe, userInfo: UnsafeMutableRawPointer(bitPattern: Int(location.rawValue) + 1)
        )
    }

    private static let observe: CGEventTapCallBack = { _, type, event, info in
        // Routing diagnostics are limited to fresh Command-Q events with the fixture frontmost.
        guard type == .keyDown,
              event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]) == .maskCommand,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_Q),
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return Unmanaged.passUnretained(event)
        }

        let location = Int(bitPattern: info) - 1
        let target = event.getIntegerValueField(.eventTargetUnixProcessID)
        MainActor.assumeIsolated {
            let fixturePID = ProcessInfo.processInfo.processIdentifier
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID {
                log("tap=\(location) targetPID=\(target) fixturePID=\(fixturePID)")
            }
        }
        return Unmanaged.passUnretained(event)
    }
}

@main
enum QuitProtectionFixtureMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--preflight") {
            QuitProtectionFixture.preflight()
            return
        }

        let verifyNativeMenu = CommandLine.arguments.contains("--verify-native-menu")
        let confirmation: QuitProtectionRule.Confirmation = if CommandLine.arguments.contains("--double-press") {
            .doublePress(.milliseconds(600))
        } else if CommandLine.arguments.contains("--extra-modifier") {
            .extraModifier(.option)
        } else {
            .hold(.milliseconds(800))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(verifyNativeMenu ? .accessory : .regular)
        let fixture = QuitProtectionFixture(
            observeRouting: CommandLine.arguments.contains("--observe-routing"),
            verifyNativeMenu: verifyNativeMenu,
            confirmation: confirmation
        )
        app.delegate = fixture
        withExtendedLifetime(fixture) { app.run() }
    }
}
