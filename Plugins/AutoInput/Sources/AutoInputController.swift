import AppKit
import Foundation
import OSLog

struct AutoInputHUDPresentationID: Hashable, Sendable {
    private let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

enum AutoInputHUDTriggerReason: Int, Sendable {
    case editableFocus
    case applicationActivation
    case inputSourceChange
}

struct AutoInputHUDPresentationRequest: Sendable {
    let id: AutoInputHUDPresentationID
    let reason: AutoInputHUDTriggerReason
}

struct AutoInputHUDTriggerPolicy {
    private var applicationID: String?
    private var sourceID: String?
    private var focusedElementID: AutoInputEditableFocusIdentity?
    private var pendingPresentation: AutoInputHUDPresentationRequest?

    init(currentSourceID: String?) {
        sourceID = currentSourceID
    }

    mutating func applicationDidActivate(_ applicationID: String) -> Bool {
        guard self.applicationID != applicationID else { return false }
        self.applicationID = applicationID
        schedulePresentation(reason: .applicationActivation)
        return true
    }

    mutating func inputSourceDidChange(to sourceID: String?) -> Bool {
        guard self.sourceID != sourceID else { return false }
        self.sourceID = sourceID
        schedulePresentation(reason: .inputSourceChange)
        return true
    }

    mutating func editableFocusDidChange(
        to focusedElementID: AutoInputEditableFocusIdentity?
    ) {
        guard let focusedElementID else {
            self.focusedElementID = nil
            if pendingPresentation?.reason == .editableFocus {
                pendingPresentation = nil
            }
            return
        }
        guard self.focusedElementID != focusedElementID else { return }
        self.focusedElementID = focusedElementID
        schedulePresentation(reason: .editableFocus)
    }

    mutating func consumePresentation() -> AutoInputHUDPresentationRequest? {
        defer { pendingPresentation = nil }
        return pendingPresentation
    }

    mutating func reset(currentSourceID: String?) {
        applicationID = nil
        sourceID = currentSourceID
        focusedElementID = nil
        pendingPresentation = nil
    }

    private mutating func schedulePresentation(reason: AutoInputHUDTriggerReason) {
        if let pendingPresentation,
           pendingPresentation.reason.rawValue > reason.rawValue {
            return
        }
        pendingPresentation = AutoInputHUDPresentationRequest(
            id: AutoInputHUDPresentationID(),
            reason: reason
        )
    }
}

struct AutoInputHUDFrequencyPolicy {
    private var wasReducingFrequentPresentations = false
    private var lastPresentedSourceID: String?
    private var lastPresentationTime: TimeInterval?
    private var lastObservedApplicationID: String?
    private var appSwitchCount = 0

    mutating func applicationDidChange(to applicationID: String) {
        guard let lastObservedApplicationID else {
            self.lastObservedApplicationID = applicationID
            return
        }
        guard lastObservedApplicationID != applicationID else { return }
        self.lastObservedApplicationID = applicationID
        appSwitchCount += 1
    }

    mutating func shouldPresent(
        sourceID: String,
        reducesFrequentPresentations: Bool,
        reminderInterval: TimeInterval,
        appSwitchThreshold: Int,
        at presentationTime: TimeInterval
    ) -> Bool {
        guard reducesFrequentPresentations else {
            wasReducingFrequentPresentations = false
            recordPresentation(sourceID: sourceID, at: presentationTime)
            return true
        }

        if !wasReducingFrequentPresentations {
            wasReducingFrequentPresentations = true
            recordPresentation(sourceID: sourceID, at: presentationTime)
            return true
        }

        if lastPresentedSourceID != sourceID {
            recordPresentation(sourceID: sourceID, at: presentationTime)
            return true
        }

        if appSwitchCount >= max(appSwitchThreshold, 1) {
            recordPresentation(sourceID: sourceID, at: presentationTime)
            return true
        }

        if let lastPresentationTime,
           presentationTime >= lastPresentationTime,
           presentationTime - lastPresentationTime < reminderInterval {
            return false
        }

        recordPresentation(sourceID: sourceID, at: presentationTime)
        return true
    }

    mutating func reset(currentApplicationID: String? = nil) {
        wasReducingFrequentPresentations = false
        lastPresentedSourceID = nil
        lastPresentationTime = nil
        lastObservedApplicationID = currentApplicationID
        appSwitchCount = 0
    }

    private mutating func recordPresentation(
        sourceID: String,
        at presentationTime: TimeInterval
    ) {
        lastPresentedSourceID = sourceID
        lastPresentationTime = presentationTime
        appSwitchCount = 0
    }
}

private struct AutoInputHUDReminderPreferences: Equatable {
    let reducesFrequency: Bool
    let intervalSeconds: Int
    let appSwitchCount: Int
}

@MainActor
final class AutoInputController: ObservableObject {
    @Published private(set) var sources: [AutoInputSource] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isAccessibilityGranted: Bool

    var onStateChange: (() -> Void)?

    private let store: AutoInputStore
    private let sourceController: AutoInputSourceControlling
    private let applicationMonitor: AutoInputApplicationMonitoring
    private let focusObserver: AutoInputFocusObserving
    private let hudPresenter: InputSourceHUDPresenting
    private let hudLabelResolver: InputSourceHUDLabelResolving
    private let accessibilityCheck: AutoInputAccessibilityChecking
    private let functionKeyController: AutoInputFunctionKeyControlling
    private let applicationNotificationCenter: NotificationCenter
    private let switchErrorMessage: () -> String
    private let now: () -> TimeInterval
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "AutoInputPlugin"
    )

    private var currentApplication: AutoInputApplication?
    private var focusedElement: AutoInputEditableFocus?
    private var isStarted = false
    private var isInteractive = true
    private var isSourceMonitoringActive = false
    private var isApplicationMonitoringActive = false
    private var isFocusMonitoringActive = false
    private var applicationActivationObserver: NSObjectProtocol?
    private var operationGeneration = 0
    private var inputSourceOwnerBundleIdentifier: String?
    private var hudTriggerPolicy: AutoInputHUDTriggerPolicy
    private var hudFrequencyPolicy = AutoInputHUDFrequencyPolicy()
    private var appliedHUDReminderPreferences: AutoInputHUDReminderPreferences
    private var restoreStandardFunctionKeys: Bool?
    private var appliedStandardFunctionKeys: Bool?

    var currentSourceID: String? {
        sourceController.currentSourceID
    }

    init(
        store: AutoInputStore,
        sourceController: AutoInputSourceControlling,
        applicationMonitor: AutoInputApplicationMonitoring,
        focusObserver: AutoInputFocusObserving = AccessibilityAutoInputFocusObserver(),
        hudPresenter: InputSourceHUDPresenting = InputSourceHUDController(),
        hudLabelResolver: InputSourceHUDLabelResolving = StandardInputSourceHUDLabelResolver(),
        accessibilityCheck: AutoInputAccessibilityChecking = SystemAutoInputAccessibilityCheck(),
        functionKeyController: AutoInputFunctionKeyControlling = SystemAutoInputFunctionKeyController(),
        applicationNotificationCenter: NotificationCenter = .default,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        switchErrorMessage: @escaping () -> String = { "无法切换输入法" }
    ) {
        self.store = store
        self.sourceController = sourceController
        self.applicationMonitor = applicationMonitor
        self.focusObserver = focusObserver
        self.hudPresenter = hudPresenter
        self.hudLabelResolver = hudLabelResolver
        self.accessibilityCheck = accessibilityCheck
        self.functionKeyController = functionKeyController
        self.applicationNotificationCenter = applicationNotificationCenter
        self.now = now
        self.switchErrorMessage = switchErrorMessage
        self.sources = sourceController.sources
        self.isAccessibilityGranted = accessibilityCheck.isTrusted
        self.appliedHUDReminderPreferences = AutoInputHUDReminderPreferences(
            reducesFrequency: store.reducesFrequentHUDPresentations,
            intervalSeconds: store.inputHUDReminderIntervalSeconds,
            appSwitchCount: store.inputHUDAppSwitchReminderCount
        )
        self.hudTriggerPolicy = AutoInputHUDTriggerPolicy(
            currentSourceID: sourceController.currentSourceID
        )
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        sourceController.onSourcesChanged = { [weak self] in
            self?.handleSourcesChanged()
        }
        applicationMonitor.onApplicationActivated = { [weak self] application in
            self?.handleApplicationActivated(application)
        }
        focusObserver.onEditableFocusChanged = { [weak self] focus in
            self?.handleEditableFocusChanged(focus)
        }
        focusObserver.onAccessibilityInvalidated = { [weak self] in
            self?.handleAccessibilityInvalidated()
        }
        synchronizeHUDReminderPreferences()
        refreshAccessibilityPermission(prompt: false)
        reconcilePermissionObservation()
        reconcileActiveServices()
    }

    func stop() {
        guard isStarted else { return }
        operationGeneration += 1
        restoreStandardFunctionKeysIfNeeded()
        restoreStandardFunctionKeys = nil
        stopFocusMonitoring()
        stopApplicationMonitoring()
        stopSourceMonitoring()
        hudPresenter.dismiss()
        hudTriggerPolicy.reset(currentSourceID: sourceController.currentSourceID)
        hudFrequencyPolicy.reset()
        inputSourceOwnerBundleIdentifier = nil
        sourceController.onSourcesChanged = nil
        applicationMonitor.onApplicationActivated = nil
        focusObserver.onEditableFocusChanged = nil
        focusObserver.onAccessibilityInvalidated = nil
        removeApplicationActivationObserver()
        isStarted = false
    }

    func setInteractive(_ value: Bool) {
        guard isInteractive != value else { return }
        isInteractive = value
        reconcilePermissionObservation()
        if value {
            reconcileActiveServices()
        } else {
            operationGeneration += 1
            reconcileActiveServices()
        }
    }

    func configurationDidChange(promptForAccessibility: Bool = false) {
        if !store.isAutoSwitchEnabled {
            operationGeneration += 1
            errorMessage = nil
        }

        synchronizeHUDReminderPreferences()
        refreshAccessibilityPermission(prompt: promptForAccessibility && store.isInputHUDEnabled)
        reconcilePermissionObservation()
        reconcileActiveServices()
        onStateChange?()
    }

    func refresh() {
        refreshAccessibilityPermission(prompt: false)
        reconcilePermissionObservation()
        sourceController.refresh()
        sources = sourceController.sources
        reconcileActiveServices()
        onStateChange?()
    }

    func refreshAccessibilityPermissionState() {
        refreshAccessibilityPermission(prompt: false)
        reconcilePermissionObservation()
        reconcileActiveServices()
        onStateChange?()
    }

    func settingsVisibilityDidChange(_ isVisible: Bool) {
        guard isVisible else { return }
        sourceController.refresh()
        sources = sourceController.sources
        onStateChange?()
    }

    func selectSource(id: String) throws {
        guard sourceController.currentSourceID != id else { return }

        sourceController.refresh()
        sources = sourceController.sources
        guard sources.contains(where: { $0.id == id }) else {
            throw AutoInputSourceError.sourceUnavailable
        }

        try sourceController.selectSource(id: id)
        handleSourcesChanged()
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        refreshAccessibilityPermission(prompt: true)
        reconcileActiveServices()
        onStateChange?()
        return isAccessibilityGranted
    }

    func target(for bundleIdentifier: String) -> AutoInputTarget? {
        let availableSources = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        if let rule = store.rule(for: bundleIdentifier),
           let source = availableSources[rule.inputSourceID] {
            return AutoInputTarget(source: source, reason: .fixedRule)
        }
        if store.remembersLastInputSource,
           let rememberedID = store.rememberedInputSourceID(for: bundleIdentifier),
           let source = availableSources[rememberedID] {
            return AutoInputTarget(source: source, reason: .remembered)
        }
        return nil
    }

    private func handleSourcesChanged() {
        sources = sourceController.sources
        rememberCurrentSourceIfNeeded()
        let sourceChanged = hudTriggerPolicy.inputSourceDidChange(
            to: sourceController.currentSourceID
        )
        if store.isInputHUDEnabled && !accessibilityCheck.isTrusted {
            handleAccessibilityInvalidated()
            return
        }
        if sourceChanged {
            refreshPendingHUDFromAccessibility()
        }
        onStateChange?()
    }

    private func handleApplicationActivated(_ application: AutoInputApplication) {
        applyKeyboardMode(for: application.bundleIdentifier)
        let applicationIdentifier = hudApplicationIdentifier(
            processIdentifier: application.processIdentifier,
            fallback: application.bundleIdentifier
        )
        let inputSourceOwnerBeforeActivation = inputSourceOwnerBundleIdentifier
        let applicationChanged = hudTriggerPolicy.applicationDidActivate(applicationIdentifier)
        if applicationChanged {
            hudFrequencyPolicy.applicationDidChange(to: applicationIdentifier)
        }
        if hudPermissionObservationActive && !isAccessibilityGranted {
            let wasGranted = isAccessibilityGranted
            refreshAccessibilityPermission(prompt: false)
            if !wasGranted && isAccessibilityGranted {
                setSourceMonitoring(active: autoSwitchActive || hudActive)
                setFocusMonitoring(active: hudActive)
            }
        }
        if applicationChanged && hudActive {
            hudPresenter.dismiss()
            if !focusBelongs(to: application) {
                focusedElement = nil
                hudTriggerPolicy.editableFocusDidChange(to: nil)
            }
        }
        if let inputSourceOwnerBeforeActivation,
           inputSourceOwnerBeforeActivation != application.bundleIdentifier {
            rememberCurrentSourceIfNeeded(for: inputSourceOwnerBeforeActivation)
        } else if inputSourceOwnerBeforeActivation == nil,
                  let previousApplication = currentApplication,
                  previousApplication.bundleIdentifier != application.bundleIdentifier {
            rememberCurrentSourceIfNeeded(for: previousApplication.bundleIdentifier)
        }
        currentApplication = application
        inputSourceOwnerBundleIdentifier = application.bundleIdentifier
        operationGeneration += 1
        let generation = operationGeneration
        var shouldRefreshHUD = applicationChanged
        defer {
            if shouldRefreshHUD {
                refreshPendingHUDFromAccessibility()
            }
        }

        guard autoSwitchActive else { return }
        guard let target = target(for: application.bundleIdentifier) else {
            clearErrorIfNeeded()
            return
        }
        guard target.source.id != sourceController.currentSourceID else {
            clearErrorIfNeeded()
            return
        }

        do {
            try sourceController.selectSource(id: target.source.id)
            guard generation == operationGeneration,
                  currentApplication?.bundleIdentifier == application.bundleIdentifier
            else { return }

            shouldRefreshHUD = hudTriggerPolicy.inputSourceDidChange(to: target.source.id)
                || shouldRefreshHUD
            errorMessage = nil
            if store.remembersLastInputSource {
                store.remember(inputSourceID: target.source.id, for: application.bundleIdentifier)
            }
            onStateChange?()
        } catch {
            guard generation == operationGeneration else { return }
            logger.error("Failed to select input source: \(error.localizedDescription, privacy: .public)")
            errorMessage = switchErrorMessage()
            onStateChange?()
        }
    }

    private func rememberCurrentSourceIfNeeded() {
        guard autoSwitchActive, store.remembersLastInputSource,
              let bundleIdentifier = inputSourceOwnerBundleIdentifier
                ?? focusedApplicationBundleIdentifier
                ?? currentApplication?.bundleIdentifier
                ?? applicationMonitor.frontmostApplication?.bundleIdentifier,
              let sourceID = validCurrentSourceID
        else { return }

        store.remember(inputSourceID: sourceID, for: bundleIdentifier)
    }

    private func rememberCurrentSourceIfNeeded(for bundleIdentifier: String) {
        guard autoSwitchActive, store.remembersLastInputSource,
              let sourceID = validCurrentSourceID
        else { return }

        store.remember(inputSourceID: sourceID, for: bundleIdentifier)
    }

    private var validCurrentSourceID: String? {
        guard let sourceID = sourceController.currentSourceID,
              sources.contains(where: { $0.id == sourceID })
        else { return nil }
        return sourceID
    }

    private func clearErrorIfNeeded() {
        guard errorMessage != nil else { return }
        errorMessage = nil
        onStateChange?()
    }

    private var autoSwitchActive: Bool {
        isStarted && isInteractive && store.isAutoSwitchEnabled
    }

    private var hudActive: Bool {
        isStarted && isInteractive && store.isInputHUDEnabled && isAccessibilityGranted
    }

    private var hudPermissionObservationActive: Bool {
        isStarted && isInteractive && store.isInputHUDEnabled
    }

    private var keyboardModeActive: Bool {
        isStarted && isInteractive && store.hasKeyboardModeRules
    }

    private func reconcileActiveServices() {
        // Canonical input-source actions remain available even when automatic
        // switching and the optional HUD are both off.
        let shouldMonitorSources = isStarted && isInteractive
        let shouldMonitorApplications = autoSwitchActive
            || hudPermissionObservationActive
            || keyboardModeActive
        setSourceMonitoring(active: shouldMonitorSources)
        setApplicationMonitoring(active: shouldMonitorApplications)

        if shouldMonitorApplications,
           let application = applicationMonitor.frontmostApplication {
            handleApplicationActivated(application)
        }
        if !keyboardModeActive {
            restoreStandardFunctionKeysIfNeeded()
        }
        setFocusMonitoring(active: hudActive)
        if !hudActive {
            focusedElement = nil
            hudPresenter.dismiss()
            hudTriggerPolicy.reset(currentSourceID: sourceController.currentSourceID)
            hudFrequencyPolicy.reset()
        }
    }

    private func setSourceMonitoring(active: Bool) {
        guard active != isSourceMonitoringActive else { return }
        isSourceMonitoringActive = active
        if active {
            sourceController.start()
            sourceController.refresh()
            sources = sourceController.sources
        } else {
            sourceController.stop()
        }
    }

    private func setApplicationMonitoring(active: Bool) {
        guard active != isApplicationMonitoringActive else { return }
        isApplicationMonitoringActive = active
        if active {
            applicationMonitor.start()
        } else {
            applicationMonitor.stop()
            currentApplication = nil
            inputSourceOwnerBundleIdentifier = nil
        }
    }

    private func setFocusMonitoring(active: Bool) {
        guard active != isFocusMonitoringActive else { return }
        if active {
            isFocusMonitoringActive = true
            focusObserver.start()
        } else {
            stopFocusMonitoring()
        }
    }

    private func stopSourceMonitoring() {
        guard isSourceMonitoringActive else { return }
        sourceController.stop()
        isSourceMonitoringActive = false
    }

    private func stopApplicationMonitoring() {
        guard isApplicationMonitoringActive else { return }
        applicationMonitor.stop()
        isApplicationMonitoringActive = false
        currentApplication = nil
    }

    private func stopFocusMonitoring() {
        guard isFocusMonitoringActive else { return }
        focusObserver.stop()
        isFocusMonitoringActive = false
        focusedElement = nil
        hudPresenter.dismiss()
    }

    private func applyKeyboardMode(for bundleIdentifier: String) {
        guard isStarted, isInteractive, store.hasKeyboardModeRules else { return }
        applyKeyboardMode(store.rule(for: bundleIdentifier)?.keyboardMode ?? .system)
    }

    private func applyKeyboardMode(_ mode: AutoInputKeyboardMode) {
        switch mode {
        case .system:
            restoreStandardFunctionKeysIfNeeded()
        case .standardFunctionKeys:
            setStandardFunctionKeys(true)
        case .mediaShortcuts:
            setStandardFunctionKeys(false)
        }
    }

    private func setStandardFunctionKeys(_ isEnabled: Bool) {
        if restoreStandardFunctionKeys == nil {
            restoreStandardFunctionKeys = functionKeyController.isStandardFunctionKeysEnabled
        }
        guard appliedStandardFunctionKeys != isEnabled else { return }
        appliedStandardFunctionKeys = isEnabled
        if !functionKeyController.setStandardFunctionKeysEnabled(isEnabled) {
            logger.error("Failed to update the standard function key preference")
        }
    }

    /// Returns the top row to the value it had before the plugin started managing it.
    private func restoreStandardFunctionKeysIfNeeded() {
        if appliedStandardFunctionKeys != nil {
            appliedStandardFunctionKeys = nil
            if let restoreStandardFunctionKeys,
               functionKeyController.isStandardFunctionKeysEnabled != restoreStandardFunctionKeys,
               !functionKeyController.setStandardFunctionKeysEnabled(restoreStandardFunctionKeys) {
                logger.error("Failed to restore the standard function key preference")
            }
        }
        // While unmanaged, keep returning to the user's current System Settings choice.
        restoreStandardFunctionKeys = functionKeyController.isStandardFunctionKeysEnabled
    }

    private func handleEditableFocusChanged(_ focus: AutoInputEditableFocus?) {
        guard hudActive else {
            focusedElement = nil
            hudPresenter.dismiss()
            return
        }
        guard accessibilityCheck.isTrusted else {
            handleAccessibilityInvalidated()
            return
        }

        guard let focus else {
            focusedElement = nil
            hudTriggerPolicy.editableFocusDidChange(to: nil)
            hudPresenter.dismiss()
            return
        }
        guard focus.isFromAccessoryApplication || focusBelongsToCurrentApplication(focus) else {
            focusedElement = focus
            return
        }

        focusedElement = focus
        if let bundleIdentifier = focus.applicationBundleIdentifier
            ?? (focus.isFromAccessoryApplication ? nil : currentApplication?.bundleIdentifier) {
            transitionInputSourceOwnerIfNeeded(to: bundleIdentifier)
        }
        let applicationIdentifier = hudApplicationIdentifier(for: focus)
        if hudTriggerPolicy.applicationDidActivate(applicationIdentifier) {
            hudFrequencyPolicy.applicationDidChange(to: applicationIdentifier)
            hudPresenter.dismiss()
        }
        hudTriggerPolicy.editableFocusDidChange(to: focus.identity)
        showPendingHUDForCurrentFocus()
    }

    private func transitionInputSourceOwnerIfNeeded(to bundleIdentifier: String) {
        guard inputSourceOwnerBundleIdentifier != bundleIdentifier else { return }
        if let previousBundleIdentifier = inputSourceOwnerBundleIdentifier {
            rememberCurrentSourceIfNeeded(for: previousBundleIdentifier)
        }
        inputSourceOwnerBundleIdentifier = bundleIdentifier

        guard autoSwitchActive,
              let target = target(for: bundleIdentifier),
              target.source.id != sourceController.currentSourceID else {
            clearErrorIfNeeded()
            return
        }

        do {
            try sourceController.selectSource(id: target.source.id)
            _ = hudTriggerPolicy.inputSourceDidChange(to: target.source.id)
            errorMessage = nil
            if store.remembersLastInputSource {
                store.remember(inputSourceID: target.source.id, for: bundleIdentifier)
            }
            onStateChange?()
        } catch {
            logger.error(
                "Failed to select input source for focused application: \(error.localizedDescription, privacy: .public)"
            )
            errorMessage = switchErrorMessage()
            onStateChange?()
        }
    }

    private func showPendingHUDForCurrentFocus() {
        guard hudActive,
              let focusedElement,
              let sourceID = sourceController.currentSourceID,
              let source = sources.first(where: { $0.id == sourceID }),
              let presentation = hudTriggerPolicy.consumePresentation()
        else { return }
        guard hudFrequencyPolicy.shouldPresent(
            sourceID: source.id,
            reducesFrequentPresentations: store.reducesFrequentHUDPresentations,
            reminderInterval: TimeInterval(store.inputHUDReminderIntervalSeconds),
            appSwitchThreshold: store.inputHUDAppSwitchReminderCount,
            at: now()
        ) else { return }
        presentHUD(for: source, near: focusedElement, presentationID: presentation.id)
    }

    private func presentHUD(
        for source: AutoInputSource,
        near focus: AutoInputEditableFocus,
        presentationID: AutoInputHUDPresentationID
    ) {
        hudPresenter.show(
            label: hudLabelResolver.displayLabel(for: source),
            near: focus.frame,
            avoiding: focus.avoidanceFrame,
            configuration: AutoInputHUDConfiguration(
                size: store.inputHUDSize,
                position: store.inputHUDPosition,
                isInteractive: store.isInteractiveHUDEnabled
            ),
            presentationID: presentationID,
            onActivate: store.isInteractiveHUDEnabled ? { [weak self] in
                self?.cycleToNextInputSourceFromHUD()
            } : nil
        )
    }

    private func cycleToNextInputSourceFromHUD() {
        sourceController.refresh()
        sources = sourceController.sources
        guard sources.count > 1,
              let currentSourceID = validCurrentSourceID,
              let currentIndex = sources.firstIndex(where: { $0.id == currentSourceID })
        else { return }

        let target = sources[(currentIndex + 1) % sources.count]

        do {
            try sourceController.selectSource(id: target.id)
            _ = hudTriggerPolicy.inputSourceDidChange(to: target.id)
            let presentationID = hudTriggerPolicy.consumePresentation()?.id
                ?? AutoInputHUDPresentationID()
            rememberCurrentSourceIfNeeded()
            errorMessage = nil
            onStateChange?()
            if hudActive,
               let focusedElement,
               hudFrequencyPolicy.shouldPresent(
                   sourceID: target.id,
                   reducesFrequentPresentations: store.reducesFrequentHUDPresentations,
                   reminderInterval: TimeInterval(store.inputHUDReminderIntervalSeconds),
                   appSwitchThreshold: store.inputHUDAppSwitchReminderCount,
                   at: now()
               ) {
                presentHUD(
                    for: target,
                    near: focusedElement,
                    presentationID: presentationID
                )
            }
        } catch {
            logger.error("Failed to select input source from HUD: \(error.localizedDescription, privacy: .public)")
            errorMessage = switchErrorMessage()
            onStateChange?()
        }
    }

    private func refreshPendingHUDFromAccessibility() {
        guard hudActive, isFocusMonitoringActive else { return }
        focusObserver.refreshFocusedElement()
    }

    private func focusBelongs(to application: AutoInputApplication) -> Bool {
        guard let focusedElement else { return false }
        guard let focusProcessIdentifier = focusedElement.applicationProcessIdentifier,
              let applicationProcessIdentifier = application.processIdentifier else {
            return true
        }
        return focusProcessIdentifier == applicationProcessIdentifier
    }

    private func focusBelongsToCurrentApplication(_ focus: AutoInputEditableFocus) -> Bool {
        guard let currentApplication else { return false }
        guard let focusProcessIdentifier = focus.applicationProcessIdentifier,
              let applicationProcessIdentifier = currentApplication.processIdentifier else {
            return true
        }
        return focusProcessIdentifier == applicationProcessIdentifier
    }

    private func hudApplicationIdentifier(for focus: AutoInputEditableFocus) -> String {
        hudApplicationIdentifier(
            processIdentifier: focus.applicationProcessIdentifier,
            fallback: focus.applicationBundleIdentifier
                ?? currentApplication?.bundleIdentifier
                ?? "unknown"
        )
    }

    private var focusedApplicationBundleIdentifier: String? {
        guard let focusedElement,
              let bundleIdentifier = focusedElement.applicationBundleIdentifier,
              focusedElement.isFromAccessoryApplication
                || focusBelongsToCurrentApplication(focusedElement)
        else { return nil }
        return bundleIdentifier
    }

    private func hudApplicationIdentifier(
        processIdentifier: pid_t?,
        fallback: String
    ) -> String {
        processIdentifier.map { "pid:\($0)" } ?? fallback
    }

    private func refreshAccessibilityPermission(prompt: Bool) {
        let previous = isAccessibilityGranted
        isAccessibilityGranted = prompt
            ? accessibilityCheck.requestTrust(prompt: true)
            : accessibilityCheck.isTrusted
        if previous != isAccessibilityGranted {
            onStateChange?()
        }
    }

    private func handleAccessibilityInvalidated() {
        isAccessibilityGranted = false
        hudPresenter.dismiss()
        hudTriggerPolicy.reset(currentSourceID: sourceController.currentSourceID)
        hudFrequencyPolicy.reset()
        reconcileActiveServices()
        onStateChange?()
    }

    private func reconcilePermissionObservation() {
        if hudPermissionObservationActive {
            observeApplicationActivation()
        } else {
            removeApplicationActivationObserver()
        }
    }

    private func observeApplicationActivation() {
        guard applicationActivationObserver == nil else { return }
        applicationActivationObserver = applicationNotificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshAccessibilityPermission(prompt: false)
                self.reconcileActiveServices()
            }
        }
    }

    private func removeApplicationActivationObserver() {
        guard let applicationActivationObserver else { return }
        applicationNotificationCenter.removeObserver(applicationActivationObserver)
        self.applicationActivationObserver = nil
    }

    private func synchronizeHUDReminderPreferences() {
        let preferences = AutoInputHUDReminderPreferences(
            reducesFrequency: store.reducesFrequentHUDPresentations,
            intervalSeconds: store.inputHUDReminderIntervalSeconds,
            appSwitchCount: store.inputHUDAppSwitchReminderCount
        )
        guard preferences != appliedHUDReminderPreferences else { return }
        appliedHUDReminderPreferences = preferences
        hudFrequencyPolicy.reset(currentApplicationID: currentHUDApplicationIdentifier)
    }

    private var currentHUDApplicationIdentifier: String? {
        if let focusedElement {
            return hudApplicationIdentifier(for: focusedElement)
        }
        guard let currentApplication else { return nil }
        return hudApplicationIdentifier(
            processIdentifier: currentApplication.processIdentifier,
            fallback: currentApplication.bundleIdentifier
        )
    }
}
