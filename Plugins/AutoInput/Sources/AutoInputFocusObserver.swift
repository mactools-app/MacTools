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

@MainActor
final class AccessibilityAutoInputFocusObserver: AutoInputFocusObserving {
    typealias CallbackContext = PluginCallbackContext<AccessibilityAutoInputFocusObserver>

    private final class ApplicationObservation {
        let observer: AXObserver
        let applicationElement: AXUIElement
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let isAccessory: Bool
        let callbackContext: CallbackContext
        let retainedCallbackPointer: UnsafeMutableRawPointer
        var focusedAccessibilityElement: AXUIElement?
        var focusedElementIdentity: AutoInputEditableFocusIdentity?

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
            self.applicationElement = applicationElement
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.isAccessory = isAccessory
            self.callbackContext = callbackContext
            self.retainedCallbackPointer = retainedCallbackPointer
        }

        func resetFocusedElement() {
            focusedAccessibilityElement = nil
            focusedElementIdentity = nil
        }
    }

    var onEditableFocusChanged: ((AutoInputEditableFocus?) -> Void)?
    var onAccessibilityInvalidated: (() -> Void)?

    private let workspace: NSWorkspace
    private let notificationCenter: NotificationCenter
    private let focusedApplicationProcessIdentifier: () -> pid_t?

    private var activationObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var applicationObservations: [pid_t: ApplicationObservation] = [:]
    private var failedProcessIdentifiers: Set<pid_t> = []
    private var registrationRetryPolicy = AutoInputObservationRegistrationRetryPolicy()
    private var registrationRetryTasks: [pid_t: Task<Void, Never>] = [:]
    private var observationRegistry = AutoInputApplicationObservationRegistry()
    private var focusedObservationProcessIdentifier: pid_t?
    private var lifecycle = AutoInputObservationLifecycle()

    init(
        workspace: NSWorkspace = .shared,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        focusedApplicationProcessIdentifier: @escaping () -> pid_t? = {
            AccessibilityAutoInputFocusObserver.systemFocusedApplicationProcessIdentifier()
        }
    ) {
        self.workspace = workspace
        self.notificationCenter = notificationCenter
        self.focusedApplicationProcessIdentifier = focusedApplicationProcessIdentifier
    }

    func start() {
        guard !lifecycle.isRunning else {
            refreshFocusedElement()
            return
        }

        let generation = lifecycle.start()
        failedProcessIdentifiers.removeAll()
        cancelRegistrationRetries()
        observationRegistry = AutoInputApplicationObservationRegistry()

        activationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lifecycle.accepts(generation) else { return }
                self.observeActivatedApplication(application, generation: generation)
            }
        }
        launchObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lifecycle.accepts(generation) else { return }
                self.observeAccessoryApplicationIfNeeded(application)
                self.refreshEffectiveFocusedElement()
            }
        }
        terminationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lifecycle.accepts(generation) else { return }
                self.removeObservation(processIdentifier: application.processIdentifier)
                self.failedProcessIdentifiers.remove(application.processIdentifier)
                self.cancelRegistrationRetry(
                    processIdentifier: application.processIdentifier
                )
                self.observationRegistry.terminateApplication(
                    processIdentifier: application.processIdentifier
                )
                self.refreshEffectiveFocusedElement()
            }
        }

        if let application = workspace.frontmostApplication {
            observeActivatedApplication(
                application,
                generation: generation,
                refreshAfterObservation: false
            )
        }
        for application in workspace.runningApplications {
            observeAccessoryApplicationIfNeeded(application)
        }
        refreshEffectiveFocusedElement()
    }

    func stop() {
        lifecycle.stop()
        [activationObserver, launchObserver, terminationObserver]
            .compactMap { $0 }
            .forEach(notificationCenter.removeObserver)
        activationObserver = nil
        launchObserver = nil
        terminationObserver = nil
        failedProcessIdentifiers.removeAll()
        cancelRegistrationRetries()
        observationRegistry = AutoInputApplicationObservationRegistry()
        stopObservingApplications()
        publishNoEditableFocus()
    }

    func refreshFocusedElement() {
        guard lifecycle.isRunning else { return }
        refreshEffectiveFocusedElement()
    }

    private func observeActivatedApplication(
        _ application: NSRunningApplication,
        generation: Int,
        refreshAfterObservation: Bool = true
    ) {
        guard lifecycle.accepts(generation) else { return }
        if application.activationPolicy == .accessory {
            observeAccessoryApplicationIfNeeded(application)
            if refreshAfterObservation {
                refreshEffectiveFocusedElement()
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
            refreshEffectiveFocusedElement(
                focusedApplicationProcessIdentifier: application.processIdentifier
            )
        }
    }

    private func observeAccessoryApplicationIfNeeded(_ application: NSRunningApplication) {
        guard application.activationPolicy == .accessory else { return }
        observationRegistry.registerAccessoryApplication(
            processIdentifier: application.processIdentifier
        )
        observe(application, isAccessory: true)
    }

    private func observe(_ application: NSRunningApplication, isAccessory: Bool) {
        let processIdentifier = application.processIdentifier
        guard lifecycle.isRunning,
              applicationObservations[processIdentifier] == nil,
              !failedProcessIdentifiers.contains(processIdentifier) else { return }

        guard AXIsProcessTrusted() else {
            accessibilityWasInvalidated()
            return
        }
        var observer: AXObserver?
        let createStatus = AXObserverCreate(
            application.processIdentifier,
            Self.accessibilityCallback,
            &observer
        )
        guard createStatus == .success, let observer else {
            handleObservationRegistrationFailure(
                createStatus,
                application: application,
                isAccessory: isAccessory
            )
            return
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        // Keep an unresponsive app from holding the host's UI during registration
        // or focus queries. Apply this per element, without changing other plugins.
        AXUIElementSetMessagingTimeout(applicationElement, Self.messagingTimeout)
        let context = CallbackContext(owner: self)
        let retainedPointer = Unmanaged.passRetained(context).toOpaque()
        let addStatus = AXObserverAddNotification(
            observer,
            applicationElement,
            kAXFocusedUIElementChangedNotification as CFString,
            retainedPointer
        )
        guard addStatus == .success else {
            Unmanaged<CallbackContext>.fromOpaque(retainedPointer).release()
            handleObservationRegistrationFailure(
                addStatus,
                application: application,
                isAccessory: isAccessory
            )
            return
        }

        registrationRetryPolicy.reset(processIdentifier: processIdentifier)
        registrationRetryTasks.removeValue(forKey: processIdentifier)?.cancel()
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
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
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
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observation.observer),
            .commonModes
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
        guard lifecycle.isRunning else { return }
        let focusedApplicationProcessIdentifier = focusedApplicationOverride
            ?? self.focusedApplicationProcessIdentifier()
        let candidates = observationRegistry.focusCandidates(
            focusedApplicationProcessIdentifier: focusedApplicationProcessIdentifier,
            preferredProcessIdentifier: preferredProcessIdentifier
                ?? focusedObservationProcessIdentifier
        )
        for processIdentifier in candidates {
            guard let observation = applicationObservations[processIdentifier] else { continue }
            if let focus = editableFocus(
                for: observation,
                requiresFocusedElement: observation.isAccessory
            ) {
                focusedObservationProcessIdentifier = processIdentifier
                onEditableFocusChanged?(focus)
                return
            }
        }
        publishNoEditableFocus()
    }

    private func handleFocusedElementNotification(processIdentifier: pid_t) {
        guard lifecycle.isRunning,
              applicationObservations[processIdentifier] != nil else { return }
        refreshEffectiveFocusedElement(preferredProcessIdentifier: processIdentifier)
    }

    private nonisolated static func systemFocusedApplicationProcessIdentifier() -> pid_t? {
        let systemWideElement = AXUIElementCreateSystemWide()
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

    private func editableFocus(
        for observation: ApplicationObservation,
        requiresFocusedElement: Bool
    ) -> AutoInputEditableFocus? {

        var focusedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            observation.applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard status == .success else {
            observation.resetFocusedElement()
            if status == .apiDisabled || !AXIsProcessTrusted() {
                accessibilityWasInvalidated()
            }
            return nil
        }
        guard let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            observation.resetFocusedElement()
            return nil
        }

        let element = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        if requiresFocusedElement,
           Self.boolAttribute(kAXFocusedAttribute, from: element) != true {
            observation.resetFocusedElement()
            return nil
        }
        guard Self.isEditable(
            element,
            applicationBundleIdentifier: observation.bundleIdentifier
        ),
              let elementAccessibilityFrame = Self.elementAccessibilityFrame(of: element) else {
            observation.resetFocusedElement()
            return nil
        }
        let preferredAccessibilityFrame = Self.preferredAccessibilityFrame(
            elementFrame: elementAccessibilityFrame,
            selectionFrame: Self.selectedTextBounds(of: element)
        )

        return AutoInputEditableFocus(
            frame: Self.appKitFrame(
                fromAccessibilityFrame: preferredAccessibilityFrame,
                primaryScreenFrame: Self.primaryScreenFrame
            ),
            avoidanceFrame: Self.appKitFrame(
                fromAccessibilityFrame: elementAccessibilityFrame,
                primaryScreenFrame: Self.primaryScreenFrame
            ),
            applicationProcessIdentifier: observation.processIdentifier,
            applicationBundleIdentifier: observation.bundleIdentifier,
            isFromAccessoryApplication: observation.isAccessory,
            identity: identity(for: element, observation: observation)
        )
    }

    private func identity(
        for element: AXUIElement,
        observation: ApplicationObservation
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
        onEditableFocusChanged?(nil)
    }

    private func handleObservationRegistrationFailure(
        _ status: AXError,
        application: NSRunningApplication,
        isAccessory: Bool
    ) {
        if status == .apiDisabled || !AXIsProcessTrusted() {
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
        application: NSRunningApplication,
        isAccessory: Bool
    ) {
        let processIdentifier = application.processIdentifier
        guard let delayMilliseconds = registrationRetryPolicy.nextDelayMilliseconds(
            processIdentifier: processIdentifier
        ) else { return }
        registrationRetryTasks[processIdentifier]?.cancel()
        let generation = lifecycle.generation
        let delay = Duration.milliseconds(delayMilliseconds)
        registrationRetryTasks[processIdentifier] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  let self,
                  self.lifecycle.accepts(generation) else { return }
            self.registrationRetryTasks.removeValue(forKey: processIdentifier)
            self.observe(application, isAccessory: isAccessory)
            self.refreshEffectiveFocusedElement(
                preferredProcessIdentifier: isAccessory ? processIdentifier : nil
            )
        }
    }

    private func cancelRegistrationRetry(processIdentifier: pid_t) {
        registrationRetryTasks.removeValue(forKey: processIdentifier)?.cancel()
        registrationRetryPolicy.reset(processIdentifier: processIdentifier)
    }

    private func cancelRegistrationRetries() {
        registrationRetryTasks.values.forEach { $0.cancel() }
        registrationRetryTasks.removeAll()
        registrationRetryPolicy.reset()
    }

    private func accessibilityWasInvalidated() {
        stopObservingApplications()
        publishNoEditableFocus()
        onAccessibilityInvalidated?()
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
        context.withOwner { owner in
            DispatchQueue.main.async { [weak owner] in
                owner?.handleFocusedElementNotification(
                    processIdentifier: resolvedProcessIdentifier
                )
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

    private static var primaryScreenFrame: CGRect {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame
            ?? NSScreen.screens.first?.frame
            ?? .zero
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
