import AppKit
import ApplicationServices
import Foundation
import MacToolsPluginKit

struct AutoInputEditableFocusIdentity: Hashable, Sendable {
    private let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

struct AutoInputEditableFocus: Equatable, Sendable {
    let frame: CGRect
    let avoidanceFrame: CGRect
    let applicationProcessIdentifier: pid_t?
    let applicationBundleIdentifier: String?
    let isFromAccessoryApplication: Bool
    let identity: AutoInputEditableFocusIdentity

    init(
        frame: CGRect,
        avoidanceFrame: CGRect? = nil,
        applicationProcessIdentifier: pid_t? = nil,
        applicationBundleIdentifier: String? = nil,
        isFromAccessoryApplication: Bool = false,
        identity: AutoInputEditableFocusIdentity = AutoInputEditableFocusIdentity()
    ) {
        self.frame = frame
        self.avoidanceFrame = avoidanceFrame ?? frame
        self.applicationProcessIdentifier = applicationProcessIdentifier
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.isFromAccessoryApplication = isFromAccessoryApplication
        self.identity = identity
    }
}

@MainActor
protocol AutoInputFocusObserving: AnyObject {
    var onEditableFocusChanged: ((AutoInputEditableFocus?) -> Void)? { get set }
    var onAccessibilityInvalidated: (() -> Void)? { get set }

    func start()
    func stop()
    func refreshFocusedElement()
}

@MainActor
protocol AutoInputAccessibilityChecking: AnyObject {
    var isTrusted: Bool { get }

    @discardableResult
    func requestTrust(prompt: Bool) -> Bool
}

struct AutoInputObservationLifecycle {
    private(set) var generation = 0
    private(set) var isRunning = false

    mutating func start() -> Int {
        generation &+= 1
        isRunning = true
        return generation
    }

    mutating func stop() {
        isRunning = false
        generation &+= 1
    }

    func accepts(_ scheduledGeneration: Int) -> Bool {
        isRunning && generation == scheduledGeneration
    }
}

struct AutoInputApplicationObservationRegistry {
    private(set) var frontmostProcessIdentifier: pid_t?
    private(set) var accessoryProcessIdentifiers: Set<pid_t> = []

    mutating func activateRegularApplication(processIdentifier: pid_t) -> pid_t? {
        defer { frontmostProcessIdentifier = processIdentifier }
        guard frontmostProcessIdentifier != processIdentifier else { return nil }
        return frontmostProcessIdentifier
    }

    mutating func registerAccessoryApplication(processIdentifier: pid_t) {
        accessoryProcessIdentifiers.insert(processIdentifier)
    }

    mutating func terminateApplication(processIdentifier: pid_t) {
        accessoryProcessIdentifiers.remove(processIdentifier)
        if frontmostProcessIdentifier == processIdentifier {
            frontmostProcessIdentifier = nil
        }
    }

    func focusCandidates(
        focusedApplicationProcessIdentifier: pid_t?,
        preferredProcessIdentifier: pid_t?
    ) -> [pid_t] {
        let registeredProcessIdentifiers = accessoryProcessIdentifiers.union(
            frontmostProcessIdentifier.map { [$0] } ?? []
        )
        if let focusedApplicationProcessIdentifier {
            return registeredProcessIdentifiers.contains(focusedApplicationProcessIdentifier)
                ? [focusedApplicationProcessIdentifier]
                : []
        }

        if let preferredProcessIdentifier,
           preferredProcessIdentifier == frontmostProcessIdentifier {
            return [preferredProcessIdentifier]
        }
        return frontmostProcessIdentifier.map { [$0] } ?? []
    }
}

struct AutoInputObservationRegistrationRetryPolicy {
    private var attemptsByProcessIdentifier: [pid_t: Int] = [:]

    mutating func nextDelayMilliseconds(processIdentifier: pid_t) -> Int? {
        let attempt = attemptsByProcessIdentifier[processIdentifier, default: 0] + 1
        guard attempt <= 3 else {
            attemptsByProcessIdentifier.removeValue(forKey: processIdentifier)
            return nil
        }
        attemptsByProcessIdentifier[processIdentifier] = attempt
        return 100 * (1 << (attempt - 1))
    }

    mutating func reset(processIdentifier: pid_t) {
        attemptsByProcessIdentifier.removeValue(forKey: processIdentifier)
    }

    mutating func reset() {
        attemptsByProcessIdentifier.removeAll()
    }
}

@MainActor
final class SystemAutoInputAccessibilityCheck: AutoInputAccessibilityChecking {
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestTrust(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

struct AutoInputObservedApplication: Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let isAccessory: Bool

    @MainActor
    init(_ application: NSRunningApplication) {
        processIdentifier = application.processIdentifier
        bundleIdentifier = application.bundleIdentifier
        isAccessory = application.activationPolicy == .accessory
    }
}

@MainActor
protocol AutoInputApplicationProviding {
    var frontmostApplication: NSRunningApplication? { get }
    var runningApplications: [NSRunningApplication] { get }
}

extension NSWorkspace: AutoInputApplicationProviding {}

struct AutoInputAccessibilityRegistrationResult {
    var status: AXError
    var observer: AXObserver?
    var applicationElement: AXUIElement?
}

protocol AutoInputAccessibilityRegistering: Sendable {
    var isTrusted: Bool { get }
    func register(processIdentifier: pid_t, callback: AXObserverCallback,
                  context: UnsafeMutableRawPointer) -> AutoInputAccessibilityRegistrationResult
}

struct SystemAutoInputAccessibilityRegistration: AutoInputAccessibilityRegistering {
    var isTrusted: Bool { AXIsProcessTrusted() }

    func register(processIdentifier: pid_t, callback: AXObserverCallback,
                  context: UnsafeMutableRawPointer) -> AutoInputAccessibilityRegistrationResult {
        var observer: AXObserver?
        let status = AXObserverCreate(processIdentifier, callback, &observer)
        guard status == .success, let observer else { return .init(status: status) }
        let element = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        let addStatus = AXObserverAddNotification(observer, element,
            kAXFocusedUIElementChangedNotification as CFString, context)
        return .init(status: addStatus, observer: observer, applicationElement: element)
    }
}

// The main actor invalidates deliveries immediately, even while the worker is
// waiting for an unresponsive app. Focus revisions reject retired app results.
private final class AutoInputFocusSessionValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: Int?
    private var revision = 0
    private var activationRevision = 0

    func set(generation: Int?, revision: Int, isActivation: Bool = false) {
        lock.withLock {
            // Termination retires focus results without superseding the latest
            // queued activation needed to register the current application.
            if self.generation != generation || isActivation { activationRevision = revision }
            self.generation = generation
            self.revision = revision
        }
    }

    func acceptsActivation(_ generation: Int, revision: Int) -> Bool {
        lock.withLock { self.generation == generation && activationRevision == revision }
    }

    func accepts(_ generation: Int, revision: Int? = nil) -> Bool {
        lock.withLock { self.generation == generation && (revision == nil || self.revision == revision) }
    }
}

private struct AutoInputFocusRequest: Sendable {
    let focusedProcessIdentifier: pid_t?
    let preferredProcessIdentifier: pid_t?
    let localFocus: AutoInputEditableFocus?
    let accessibilityInvalidated: Bool
    let screen: CGRect
}

// Each instance belongs to either the main actor (MacTools' own controls) or
// the AX worker (a remote app). AX can invoke same-process AppKit getters inline.
private final class AutoInputAXFocusState {
    let applicationElement: AXUIElement
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let isAccessory: Bool
    var focusedAccessibilityElement: AXUIElement?
    var focusedElementIdentity: AutoInputEditableFocusIdentity?

    init(applicationElement: AXUIElement, processIdentifier: pid_t, bundleIdentifier: String?, isAccessory: Bool) {
        self.applicationElement = applicationElement
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.isAccessory = isAccessory
    }

    func resetFocusedElement() {
        focusedAccessibilityElement = nil
        focusedElementIdentity = nil
    }
}

private struct AutoInputFocusReadResult {
    var focus: AutoInputEditableFocus?
    var accessibilityInvalidated = false
}

@MainActor
final class AccessibilityAutoInputFocusObserver: AutoInputFocusObserving {
    var onEditableFocusChanged: ((AutoInputEditableFocus?) -> Void)?
    var onAccessibilityInvalidated: (() -> Void)?
    private let workspace: any AutoInputApplicationProviding
    private let notificationCenter: NotificationCenter
    private let focusedApplicationProcessIdentifier: @MainActor () -> pid_t?
    private let runLoop: AutoInputAccessibilityRunLoop
    private let session: AutoInputFocusObservationSession
    private let validity = AutoInputFocusSessionValidity()
    private var observers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var lifecycle = AutoInputObservationLifecycle()
    private var focusRevision = 0
    private var refreshScheduled = false
    private var preferredProcessIdentifier: pid_t?
    private lazy var localFocusState = AutoInputAXFocusState(
        applicationElement: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
        processIdentifier: ProcessInfo.processInfo.processIdentifier,
        bundleIdentifier: Bundle.main.bundleIdentifier,
        isAccessory: NSRunningApplication.current.activationPolicy == .accessory
    )

    init(
        workspace: any AutoInputApplicationProviding = NSWorkspace.shared,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        focusedApplicationProcessIdentifier: @escaping @MainActor () -> pid_t? = {
            AutoInputFocusObservationSession.systemFocusedApplicationProcessIdentifier()
        },
        registrationBackend: any AutoInputAccessibilityRegistering = SystemAutoInputAccessibilityRegistration(),
        runLoop: AutoInputAccessibilityRunLoop = AutoInputAccessibilityRunLoop()
    ) {
        self.workspace = workspace
        self.notificationCenter = notificationCenter
        self.runLoop = runLoop
        self.focusedApplicationProcessIdentifier = focusedApplicationProcessIdentifier
        session = AutoInputFocusObservationSession(validity: validity, registrationBackend: registrationBackend)
    }

    func start() {
        guard !lifecycle.isRunning else { refreshFocusedElement(); return }
        let generation = lifecycle.start()
        focusRevision &+= 1
        let revision = focusRevision
        validity.set(generation: generation, revision: revision)
        let screen = primaryScreenFrame
        let frontmost = workspace.frontmostApplication.map(AutoInputObservedApplication.init)
        let session = session
        runLoop.perform(priority: .foreground) { [weak self] in
            session.start(generation: generation, focusRevision: revision, primaryScreenFrame: screen,
                frontmost: frontmost, onFocus: { [weak self] focus, revision in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.lifecycle.accepts(generation),
                              self.validity.accepts(generation, revision: revision) else { return }
                        self.onEditableFocusChanged?(focus)
                    }
                }, onRefresh: { [weak self] preferred in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.lifecycle.accepts(generation) else { return }
                        self.scheduleFocusRefresh(preferredProcessIdentifier: preferred)
                    }
                }, onInvalidation: { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.lifecycle.accepts(generation) else { return }
                        self.onEditableFocusChanged?(nil)
                        self.onAccessibilityInvalidated?()
                    }
                })
        }
        for application in workspace.runningApplications where application.activationPolicy == .accessory {
            let application = AutoInputObservedApplication(application)
            runLoop.perform { session.launch(application, generation: generation) }
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    guard let self, self.lifecycle.accepts(generation) else { return }
                    self.applicationChanged(AutoInputObservedApplication(application), event: name, generation: generation)
                }
            })
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFocusedElement() }
            }
    }

    func stop() {
        lifecycle.stop()
        validity.set(generation: nil, revision: focusRevision)
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        runLoop.perform(priority: .foreground) { [session] in session.stop() }
        onEditableFocusChanged?(nil)
    }

    func refreshFocusedElement() {
        refreshFocusedElement(preferredProcessIdentifier: nil)
    }

    private func scheduleFocusRefresh(preferredProcessIdentifier: pid_t?) {
        guard lifecycle.isRunning else { return }
        self.preferredProcessIdentifier = preferredProcessIdentifier ?? self.preferredProcessIdentifier
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            let preferred = self.preferredProcessIdentifier
            self.preferredProcessIdentifier = nil
            self.refreshFocusedElement(preferredProcessIdentifier: preferred)
        }
    }

    private func refreshFocusedElement(preferredProcessIdentifier: pid_t?) {
        guard lifecycle.isRunning else { return }
        let generation = lifecycle.generation
        let revision = focusRevision
        let screen = primaryScreenFrame
        // A system-wide AX lookup can resolve our own field editor synchronously.
        // Resolve that identity, and all local control attributes, on the main actor.
        let focusedPID = focusedApplicationProcessIdentifier()
        let local = focusedPID == ProcessInfo.processInfo.processIdentifier
            ? AutoInputFocusObservationSession.readEditableFocus(for: localFocusState, screen: screen, allowsLocalAccess: true)
            : AutoInputFocusReadResult(focus: nil)
        let request = AutoInputFocusRequest(focusedProcessIdentifier: focusedPID,
            preferredProcessIdentifier: preferredProcessIdentifier, localFocus: local.focus,
            accessibilityInvalidated: local.accessibilityInvalidated, screen: screen)
        runLoop.perform(priority: .foreground) { [session] in
            session.refresh(generation: generation, revision: revision, request: request)
        }
    }

    private func applicationChanged(_ application: AutoInputObservedApplication, event: Notification.Name, generation: Int) {
        if event == NSWorkspace.didLaunchApplicationNotification {
            runLoop.perform { [session] in session.launch(application, generation: generation) }
        } else {
            focusRevision &+= 1
            let revision = focusRevision
            validity.set(generation: generation, revision: revision,
                isActivation: event == NSWorkspace.didActivateApplicationNotification)
            let screen = primaryScreenFrame
            runLoop.perform(priority: .foreground) { [session] in
                if event == NSWorkspace.didActivateApplicationNotification {
                    session.activate(application, generation: generation, revision: revision, screen: screen)
                } else {
                    session.terminate(processIdentifier: application.processIdentifier, generation: generation, revision: revision)
                }
            }
        }
    }

    private var primaryScreenFrame: CGRect {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame ?? NSScreen.screens.first?.frame ?? .zero
    }

    isolated deinit {
        validity.set(generation: nil, revision: focusRevision)
        observers.forEach(notificationCenter.removeObserver)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        runLoop.shutdown { [session] in session.stop() }
    }
}

// AX objects and mutable observation state are confined to the worker run loop.
private final class AutoInputFocusObservationSession: @unchecked Sendable {
    typealias CallbackContext = PluginCallbackContext<AutoInputFocusObservationSession>

    private final class ApplicationObservation {
        let observer: AXObserver
        let focusState: AutoInputAXFocusState
        var applicationElement: AXUIElement { focusState.applicationElement }
        var processIdentifier: pid_t { focusState.processIdentifier }
        var bundleIdentifier: String? { focusState.bundleIdentifier }
        var isAccessory: Bool { focusState.isAccessory }
        let callbackContext: CallbackContext
        let retainedCallbackPointer: UnsafeMutableRawPointer

        init(
            observer: AXObserver,
            applicationElement: AXUIElement,
            processIdentifier: pid_t,
            bundleIdentifier: String?,
            isAccessory: Bool,
            callbackContext: CallbackContext,
            retainedCallbackPointer: UnsafeMutableRawPointer
        ) {
            self.observer = observer
            focusState = AutoInputAXFocusState(applicationElement: applicationElement,
                processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier, isAccessory: isAccessory)
            self.callbackContext = callbackContext
            self.retainedCallbackPointer = retainedCallbackPointer
        }

        func resetFocusedElement() {
            focusState.resetFocusedElement()
        }
    }

    private var onEditableFocusChanged: (@Sendable (AutoInputEditableFocus?, Int) -> Void)?
    private var onAccessibilityInvalidated: (@Sendable () -> Void)?
    private var onFocusRefreshRequested: (@Sendable (pid_t?) -> Void)?
    private let registrationBackend: any AutoInputAccessibilityRegistering
    private let validity: AutoInputFocusSessionValidity
    private var applicationObservations: [pid_t: ApplicationObservation] = [:]
    private var failedProcessIdentifiers: Set<pid_t> = []
    private var registrationRetryPolicy = AutoInputObservationRegistrationRetryPolicy()
    private var registrationRetryTimers: [pid_t: Timer] = [:]
    private var observationRegistry = AutoInputApplicationObservationRegistry()
    private var focusedObservationProcessIdentifier: pid_t?
    private var generation: Int?
    private var focusRevision = 0
    private var primaryScreenFrame = CGRect.zero

    init(
        validity: AutoInputFocusSessionValidity,
        registrationBackend: any AutoInputAccessibilityRegistering
    ) {
        self.validity = validity
        self.registrationBackend = registrationBackend
    }

    private var isCurrent: Bool {
        generation.map { validity.accepts($0) } ?? false
    }

    func start(
        generation: Int,
        focusRevision: Int,
        primaryScreenFrame: CGRect,
        frontmost: AutoInputObservedApplication?,
        onFocus: @escaping @Sendable (AutoInputEditableFocus?, Int) -> Void,
        onRefresh: @escaping @Sendable (pid_t?) -> Void,
        onInvalidation: @escaping @Sendable () -> Void
    ) {
        stop()
        guard validity.accepts(generation) else { return }
        self.generation = generation
        self.focusRevision = focusRevision
        self.primaryScreenFrame = primaryScreenFrame
        onEditableFocusChanged = onFocus
        onAccessibilityInvalidated = onInvalidation
        onFocusRefreshRequested = onRefresh
        if let frontmost { observeActivatedApplication(frontmost) }
    }

    func stop() {
        generation = nil
        onEditableFocusChanged = nil
        onAccessibilityInvalidated = nil
        onFocusRefreshRequested = nil
        cancelRegistrationRetries()
        stopObservingApplications()
        failedProcessIdentifiers.removeAll()
        observationRegistry = AutoInputApplicationObservationRegistry()
        focusedObservationProcessIdentifier = nil
    }

    func activate(_ application: AutoInputObservedApplication, generation: Int, revision: Int, screen: CGRect) {
        guard self.generation == generation, validity.acceptsActivation(generation, revision: revision) else { return }
        focusRevision = revision
        primaryScreenFrame = screen
        observeActivatedApplication(application)
    }

    func launch(_ application: AutoInputObservedApplication, generation: Int) {
        guard self.generation == generation, isCurrent else { return }
        observeAccessoryApplicationIfNeeded(application)
        requestFocusRefresh()
    }

    func terminate(processIdentifier: pid_t, generation: Int, revision: Int) {
        guard self.generation == generation, isCurrent else { return }
        focusRevision = max(focusRevision, revision)
        removeObservation(processIdentifier: processIdentifier)
        failedProcessIdentifiers.remove(processIdentifier)
        cancelRegistrationRetry(processIdentifier: processIdentifier)
        observationRegistry.terminateApplication(processIdentifier: processIdentifier)
        requestFocusRefresh()
    }

    func refresh(generation: Int, revision: Int, request: AutoInputFocusRequest) {
        guard self.generation == generation, validity.accepts(generation, revision: revision) else { return }
        focusRevision = revision
        primaryScreenFrame = request.screen
        if request.accessibilityInvalidated { accessibilityWasInvalidated(); return }
        if request.focusedProcessIdentifier == ProcessInfo.processInfo.processIdentifier {
            focusedObservationProcessIdentifier = request.localFocus?.applicationProcessIdentifier
            publishFocus(request.localFocus)
            return
        }
        refreshEffectiveFocusedElement(preferredProcessIdentifier: request.preferredProcessIdentifier,
            focusedApplicationProcessIdentifier: request.focusedProcessIdentifier)
    }

    private func requestFocusRefresh(preferredProcessIdentifier: pid_t? = nil) {
        guard isCurrent else { return }
        onFocusRefreshRequested?(preferredProcessIdentifier)
    }

    private func observeActivatedApplication(
        _ application: AutoInputObservedApplication,
        refreshAfterObservation: Bool = true
    ) {
        guard isCurrent else { return }
        if application.isAccessory {
            observeAccessoryApplicationIfNeeded(application)
            if refreshAfterObservation {
                requestFocusRefresh()
            }
            return
        }

        if let previousProcessIdentifier = observationRegistry.activateRegularApplication(
            processIdentifier: application.processIdentifier
        ) {
            if applicationObservations[previousProcessIdentifier]?.isAccessory == false {
                removeObservation(processIdentifier: previousProcessIdentifier)
            }
            cancelRegistrationRetry(processIdentifier: previousProcessIdentifier)
        }
        observe(application, isAccessory: false)
        if refreshAfterObservation {
            requestFocusRefresh(preferredProcessIdentifier: application.processIdentifier)
        }
    }

    private func observeAccessoryApplicationIfNeeded(_ application: AutoInputObservedApplication) {
        guard application.isAccessory else { return }
        observationRegistry.registerAccessoryApplication(
            processIdentifier: application.processIdentifier
        )
        observe(application, isAccessory: true)
    }

    private func observe(_ application: AutoInputObservedApplication, isAccessory: Bool) {
        let processIdentifier = application.processIdentifier
        guard isCurrent,
              applicationObservations[processIdentifier] == nil,
              !failedProcessIdentifiers.contains(processIdentifier) else { return }

        guard registrationBackend.isTrusted else {
            accessibilityWasInvalidated()
            return
        }
        let context = CallbackContext(owner: self)
        let retainedPointer = Unmanaged.passRetained(context).toOpaque()
        let registration = registrationBackend.register(
            processIdentifier: processIdentifier,
            callback: Self.accessibilityCallback,
            context: retainedPointer
        )
        // Registration can outlive stop or a new session. Retire its AX resources
        // here, before attaching a source or publishing anything to the host.
        guard isCurrent else {
            context.invalidate()
            if let observer = registration.observer, let element = registration.applicationElement {
                AXObserverRemoveNotification(observer, element, kAXFocusedUIElementChangedNotification as CFString)
            }
            Unmanaged<CallbackContext>.fromOpaque(retainedPointer).release()
            return
        }
        guard registration.status == .success,
              let observer = registration.observer,
              let applicationElement = registration.applicationElement else {
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(retainedPointer).release()
            handleObservationRegistrationFailure(registration.status, application: application, isAccessory: isAccessory)
            return
        }

        registrationRetryPolicy.reset(processIdentifier: processIdentifier)
        registrationRetryTimers.removeValue(forKey: processIdentifier)?.invalidate()
        applicationObservations[processIdentifier] = ApplicationObservation(
            observer: observer,
            applicationElement: applicationElement,
            processIdentifier: processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            isAccessory: isAccessory,
            callbackContext: context,
            retainedCallbackPointer: retainedPointer
        )
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    private func stopObservingApplications() {
        for processIdentifier in Array(applicationObservations.keys) {
            removeObservation(processIdentifier: processIdentifier)
        }
    }

    private func removeObservation(processIdentifier: pid_t) {
        guard let observation = applicationObservations.removeValue(
            forKey: processIdentifier
        ) else { return }
        observation.callbackContext.invalidate()
        AXObserverRemoveNotification(
            observation.observer,
            observation.applicationElement,
            kAXFocusedUIElementChangedNotification as CFString
        )
        CFRunLoopRemoveSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observation.observer),
            .defaultMode
        )
        Unmanaged<CallbackContext>.fromOpaque(
            observation.retainedCallbackPointer
        ).release()
        if focusedObservationProcessIdentifier == processIdentifier {
            focusedObservationProcessIdentifier = nil
        }
    }

    private func refreshEffectiveFocusedElement(
        preferredProcessIdentifier: pid_t? = nil,
        focusedApplicationProcessIdentifier focusedApplicationOverride: pid_t? = nil
    ) {
        guard isCurrent else { return }
        let revision = focusRevision
        let focusedApplicationProcessIdentifier = focusedApplicationOverride
        let candidates = observationRegistry.focusCandidates(
            focusedApplicationProcessIdentifier: focusedApplicationProcessIdentifier,
            preferredProcessIdentifier: preferredProcessIdentifier
                ?? focusedObservationProcessIdentifier
        )
        for processIdentifier in candidates {
            guard processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let observation = applicationObservations[processIdentifier] else { continue }
            if let focus = editableFocus(for: observation) {
                guard let generation, validity.accepts(generation, revision: revision) else { return }
                focusedObservationProcessIdentifier = processIdentifier
                publishFocus(focus)
                return
            }
        }
        publishNoEditableFocus()
    }

    private func handleFocusedElementNotification(processIdentifier: pid_t) {
        guard isCurrent,
              applicationObservations[processIdentifier] != nil else { return }
        requestFocusRefresh(preferredProcessIdentifier: processIdentifier)
    }

    @MainActor
    static func systemFocusedApplicationProcessIdentifier() -> pid_t? {
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, Self.messagingTimeout)
        var focusedApplicationValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApplicationValue
        ) == .success,
              let focusedApplicationValue,
              CFGetTypeID(focusedApplicationValue) == AXUIElementGetTypeID()
        else { return nil }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(
            focusedApplicationValue as! AXUIElement,
            &processIdentifier
        ) == .success,
              processIdentifier > 0
        else { return nil }
        return processIdentifier
    }

    private func editableFocus(for observation: ApplicationObservation) -> AutoInputEditableFocus? {
        let result = Self.readEditableFocus(for: observation.focusState, screen: primaryScreenFrame, allowsLocalAccess: false)
        if result.accessibilityInvalidated { accessibilityWasInvalidated() }
        return result.focus
    }

    static func readEditableFocus(
        for observation: AutoInputAXFocusState,
        screen primaryScreenFrame: CGRect,
        allowsLocalAccess: Bool
    ) -> AutoInputFocusReadResult {
        guard allowsLocalAccess || observation.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .init(focus: nil)
        }
        var focusedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            observation.applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard status == .success else {
            observation.resetFocusedElement()
            return .init(focus: nil, accessibilityInvalidated: status == .apiDisabled || !AXIsProcessTrusted())
        }
        guard let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            observation.resetFocusedElement()
            return .init(focus: nil)
        }

        let element = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        var elementPID: pid_t = 0
        guard allowsLocalAccess || (AXUIElementGetPid(element, &elementPID) == .success
            && elementPID != ProcessInfo.processInfo.processIdentifier) else {
            observation.resetFocusedElement()
            return .init(focus: nil)
        }
        if observation.isAccessory,
           Self.boolAttribute(kAXFocusedAttribute, from: element) != true {
            observation.resetFocusedElement()
            return .init(focus: nil)
        }
        guard Self.isEditable(
            element,
            applicationBundleIdentifier: observation.bundleIdentifier
        ),
              let elementAccessibilityFrame = Self.elementAccessibilityFrame(of: element) else {
            observation.resetFocusedElement()
            return .init(focus: nil)
        }
        let preferredAccessibilityFrame = Self.preferredAccessibilityFrame(
            elementFrame: elementAccessibilityFrame,
            selectionFrame: Self.selectedTextBounds(of: element)
        )

        return .init(focus: AutoInputEditableFocus(
            frame: Self.appKitFrame(
                fromAccessibilityFrame: preferredAccessibilityFrame,
                primaryScreenFrame: primaryScreenFrame
            ),
            avoidanceFrame: Self.appKitFrame(
                fromAccessibilityFrame: elementAccessibilityFrame,
                primaryScreenFrame: primaryScreenFrame
            ),
            applicationProcessIdentifier: observation.processIdentifier,
            applicationBundleIdentifier: observation.bundleIdentifier,
            isFromAccessoryApplication: observation.isAccessory,
            identity: identity(for: element, observation: observation)
        ))
    }

    private static func identity(
        for element: AXUIElement,
        observation: AutoInputAXFocusState
    ) -> AutoInputEditableFocusIdentity {
        if let focusedAccessibilityElement = observation.focusedAccessibilityElement,
           CFEqual(focusedAccessibilityElement, element),
           let focusedElementIdentity = observation.focusedElementIdentity {
            return focusedElementIdentity
        }

        let identity = AutoInputEditableFocusIdentity()
        observation.focusedAccessibilityElement = element
        observation.focusedElementIdentity = identity
        return identity
    }

    private func publishNoEditableFocus() {
        focusedObservationProcessIdentifier = nil
        publishFocus(nil)
    }

    private func handleObservationRegistrationFailure(
        _ status: AXError,
        application: AutoInputObservedApplication,
        isAccessory: Bool
    ) {
        if status == .apiDisabled || !registrationBackend.isTrusted {
            accessibilityWasInvalidated()
            return
        }
        if status == .notificationUnsupported || status == .notImplemented {
            failedProcessIdentifiers.insert(application.processIdentifier)
            return
        }
        scheduleRegistrationRetry(application: application, isAccessory: isAccessory)
    }

    private func scheduleRegistrationRetry(
        application: AutoInputObservedApplication,
        isAccessory: Bool
    ) {
        let processIdentifier = application.processIdentifier
        guard let generation,
              let delayMilliseconds = registrationRetryPolicy.nextDelayMilliseconds(processIdentifier: processIdentifier)
        else { return }
        registrationRetryTimers.removeValue(forKey: processIdentifier)?.invalidate()
        registrationRetryTimers[processIdentifier] = Timer.scheduledTimer(
            withTimeInterval: Double(delayMilliseconds) / 1_000,
            repeats: false
        ) { [weak self] _ in
            autoreleasepool {
                guard let self, self.generation == generation, self.isCurrent else { return }
                self.registrationRetryTimers.removeValue(forKey: processIdentifier)
                self.observe(application, isAccessory: isAccessory)
                self.requestFocusRefresh(preferredProcessIdentifier: isAccessory ? processIdentifier : nil)
            }
        }
    }

    private func cancelRegistrationRetry(processIdentifier: pid_t) {
        registrationRetryTimers.removeValue(forKey: processIdentifier)?.invalidate()
        registrationRetryPolicy.reset(processIdentifier: processIdentifier)
    }

    private func cancelRegistrationRetries() {
        registrationRetryTimers.values.forEach { $0.invalidate() }
        registrationRetryTimers.removeAll()
        registrationRetryPolicy.reset()
    }

    private func accessibilityWasInvalidated() {
        let invalidation = onAccessibilityInvalidated
        stop()
        invalidation?()
    }

    private func publishFocus(_ focus: AutoInputEditableFocus?) {
        guard let generation, validity.accepts(generation, revision: focusRevision) else { return }
        onEditableFocusChanged?(focus, focusRevision)
    }

    private nonisolated static let accessibilityCallback: AXObserverCallback = {
        _, element, notification, reference in
        guard notification as String == kAXFocusedUIElementChangedNotification as String,
              let reference else { return }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier > 0 else { return }
        let resolvedProcessIdentifier = processIdentifier

        let context = Unmanaged<CallbackContext>.fromOpaque(reference).takeUnretainedValue()
        autoreleasepool {
            context.withOwner { owner in
                owner.handleFocusedElementNotification(processIdentifier: resolvedProcessIdentifier)
            }
        }
    }

    private static let messagingTimeout: Float = 0.25

    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.mitchellh.ghostty",
    ]

    private static func isEditable(
        _ element: AXUIElement,
        applicationBundleIdentifier: String?
    ) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, from: element),
              isEditableRole(role),
              boolAttribute(kAXEnabledAttribute, from: element) != false else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        )
        return acceptsFocusedInput(
            role: role,
            valueIsSettable: status == .success ? isSettable.boolValue : nil,
            applicationBundleIdentifier: applicationBundleIdentifier
        )
    }

    static func isEditableRole(_ role: String) -> Bool {
        role == kAXTextFieldRole as String
            || role == kAXTextAreaRole as String
            || role == kAXComboBoxRole as String
    }

    static func acceptsFocusedInput(
        role: String,
        valueIsSettable: Bool?,
        applicationBundleIdentifier: String?
    ) -> Bool {
        guard isEditableRole(role) else { return false }
        if valueIsSettable == true { return true }
        guard valueIsSettable == false else { return false }

        // Terminal surfaces expose their screen buffer as a focused text area, but intentionally
        // do not allow Accessibility clients to replace that buffer through AXValue. Keep this
        // narrow so read-only text areas in ordinary apps do not trigger the HUD.
        return role == kAXTextAreaRole as String
            && applicationBundleIdentifier.map(terminalBundleIdentifiers.contains) == true
    }

    private static func elementAccessibilityFrame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    static func preferredAccessibilityFrame(
        elementFrame: CGRect,
        selectionFrame: CGRect?
    ) -> CGRect {
        guard var selectionFrame,
              selectionFrame.height > 0,
              selectionFrame.minX.isFinite,
              selectionFrame.minY.isFinite,
              selectionFrame.width.isFinite,
              selectionFrame.height.isFinite,
              !selectionFrame.isNull else {
            return elementFrame
        }
        selectionFrame.size.width = max(selectionFrame.width, 1)
        return selectionFrame
    }

    private static func selectedTextBounds(of element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
        let rangeValue,
        CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success,
        let boundsValue,
        CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }

        let axBounds = boundsValue as! AXValue
        guard AXValueGetType(axBounds) == .cgRect else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(axBounds, .cgRect, &bounds) else { return nil }
        return bounds
    }

    static func appKitFrame(
        fromAccessibilityFrame frame: CGRect,
        primaryScreenFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        guard let value = axValueAttribute(attribute, from: element),
              AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        guard let value = axValueAttribute(attribute, from: element),
              AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func axValueAttribute(_ attribute: String, from element: AXUIElement) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
