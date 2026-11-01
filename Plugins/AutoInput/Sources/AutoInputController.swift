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
    @Published private(set) var keyboardModeError: String?
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
    private let keyboardModeErrorMessage: () -> String
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
    private var defersAutomaticActionsUntilApplicationActivation = false
    private var inputSourceOwnerBundleIdentifier: String?
    private var hudTriggerPolicy: AutoInputHUDTriggerPolicy
    private var hudFrequencyPolicy = AutoInputHUDFrequencyPolicy()
    private var appliedHUDReminderPreferences: AutoInputHUDReminderPreferences
    private var restoreStandardFunctionKeys: Bool?
    private var appliedStandardFunctionKeys: Bool?
    private var keyboardModeRetryTask: Task<Void, Never>?
    private let keyboardModeRetryDelays: [Duration]

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
        switchErrorMessage: @escaping () -> String = { "无法切换输入法" },
        keyboardModeErrorMessage: @escaping () -> String = { "无法更改顶部按键用途" },
        keyboardModeRetryDelays: [Duration] = [.milliseconds(400), .milliseconds(1_200)]
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
        self.keyboardModeErrorMessage = keyboardModeErrorMessage
        self.keyboardModeRetryDelays = keyboardModeRetryDelays
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
            guard let self else { return }
            let wasDeferred = self.defersAutomaticActionsUntilApplicationActivation
            self.defersAutomaticActionsUntilApplicationActivation = false
            if wasDeferred { self.reconcileActiveServices(processCurrentApplication: false) }
            self.handleApplicationActivated(application)
        }
        applicationMonitor.onSystemDidResume = { [weak self] in
            self?.handleSystemDidResume()
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
        defersAutomaticActionsUntilApplicationActivation = false
        guard isStarted else { return }
        operationGeneration += 1
        cancelKeyboardModeRetry()
        restoreStandardFunctionKeysIfNeeded()
        stopFocusMonitoring()
        stopApplicationMonitoring()
        stopSourceMonitoring()
        hudPresenter.dismiss()
        hudTriggerPolicy.reset(currentSourceID: sourceController.currentSourceID)
        hudFrequencyPolicy.reset()
        inputSourceOwnerBundleIdentifier = nil
        sourceController.onSourcesChanged = nil
        applicationMonitor.onApplicationActivated = nil
        applicationMonitor.onSystemDidResume = nil
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
        defersAutomaticActionsUntilApplicationActivation = false
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

    func configurationDidRestore() {
        operationGeneration += 1
        defersAutomaticActionsUntilApplicationActivation = true
        currentApplication = applicationMonitor.frontmostApplication
        inputSourceOwnerBundleIdentifier = currentApplication?.bundleIdentifier
        focusedElement = nil
        hudPresenter.dismiss()
        hudTriggerPolicy.reset(currentSourceID: sourceController.currentSourceID)
        hudFrequencyPolicy.reset()
        sourceController.refresh()
        sources = sourceController.sources
        synchronizeHUDReminderPreferences()
        refreshAccessibilityPermission(prompt: false)
        reconcilePermissionObservation()
        reconcileActiveServices(processCurrentApplication: false)
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
        // A fresh activation supersedes a pending retry: the desired mode is derived again
        // right below, so the retry would only duplicate this work.
        cancelKeyboardModeRetry()
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
        guard !defersAutomaticActionsUntilApplicationActivation, autoSwitchActive, store.remembersLastInputSource,
              let bundleIdentifier = inputSourceOwnerBundleIdentifier
                ?? focusedApplicationBundleIdentifier
                ?? currentApplication?.bundleIdentifier
                ?? applicationMonitor.frontmostApplication?.bundleIdentifier,
              let sourceID = validCurrentSourceID
        else { return }

        store.remember(inputSourceID: sourceID, for: bundleIdentifier)
    }

    private func rememberCurrentSourceIfNeeded(for bundleIdentifier: String) {
        guard !defersAutomaticActionsUntilApplicationActivation, autoSwitchActive, store.remembersLastInputSource,
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

    private func reconcileActiveServices(processCurrentApplication: Bool = true) {
        // Canonical input-source actions remain available even when automatic
        // switching and the optional HUD are both off.
        let shouldMonitorSources = isStarted && isInteractive
        let shouldMonitorApplications = autoSwitchActive
            || hudPermissionObservationActive
            || keyboardModeActive
            || (isStarted && isInteractive && defersAutomaticActionsUntilApplicationActivation && appliedStandardFunctionKeys != nil)
        setSourceMonitoring(active: shouldMonitorSources)
        setApplicationMonitoring(active: shouldMonitorApplications)

        if processCurrentApplication, !defersAutomaticActionsUntilApplicationActivation, shouldMonitorApplications,
           let application = applicationMonitor.frontmostApplication {
            handleApplicationActivated(application)
        }
        if !defersAutomaticActionsUntilApplicationActivation, !keyboardModeActive {
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
        // Always re-assert the mode instead of trusting an earlier write. The live HID value
        // can drift away from the value applied earlier — sleep, another utility, or a lost
        // preference flush all change it — and a stale comparison would leave the top row on
        // the wrong mode until the plugin is restarted.
        guard functionKeyController.setStandardFunctionKeysEnabled(isEnabled) else {
            logger.error("Failed to apply the standard function key mode")
            if appliedStandardFunctionKeys == nil {
                // Nothing was applied, so the next attempt captures a fresh baseline.
                restoreStandardFunctionKeys = nil
            }
            keyboardModeError = keyboardModeErrorMessage()
            onStateChange?()
            scheduleKeyboardModeRetry()
            return
        }
        appliedStandardFunctionKeys = isEnabled
        clearKeyboardModeErrorIfNeeded()
    }

    /// Returns the top row to the value it had before the plugin started managing it.
    private func restoreStandardFunctionKeysIfNeeded() {
        guard appliedStandardFunctionKeys != nil, let originalValue = restoreStandardFunctionKeys
        else {
            // Nothing is being managed, so any earlier failure is no longer actionable.
            clearKeyboardModeErrorIfNeeded()
            return
        }
        // Restore unconditionally. The persisted preference can already read the original
        // value while the live HID mode still uses the rule's mode, and skipping the write
        // in that case is what leaves the top row on F1–F12 after switching away from a
        // rule that asked for it.
        guard functionKeyController.setStandardFunctionKeysEnabled(originalValue) else {
            // Keep the original value so a later refresh can retry the restore.
            logger.error("Failed to restore the standard function key preference")
            keyboardModeError = keyboardModeErrorMessage()
            onStateChange?()
            scheduleKeyboardModeRetry()
            return
        }
        appliedStandardFunctionKeys = nil
        restoreStandardFunctionKeys = nil
        clearKeyboardModeErrorIfNeeded()
    }

    /// Retries a failed keyboard-mode change a couple of times so a transient HID failure
    /// does not leave the top row in the wrong mode until the next application switch.
    private func scheduleKeyboardModeRetry() {
        guard keyboardModeRetryTask == nil, !keyboardModeRetryDelays.isEmpty else { return }
        let delays = keyboardModeRetryDelays
        keyboardModeRetryTask = Task { @MainActor [weak self] in
            defer { self?.keyboardModeRetryTask = nil }
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.reconcileKeyboardMode()
                guard self.keyboardModeError != nil else { return }
            }
        }
    }

    private func cancelKeyboardModeRetry() {
        keyboardModeRetryTask?.cancel()
        keyboardModeRetryTask = nil
    }

    /// Re-derives the wanted mode from the current configuration and frontmost application.
    /// Retries and resume handling go through this instead of replaying a cached decision,
    /// because the rules or the frontmost application can change while a retry is pending.
    private func reconcileKeyboardMode() {
        guard isStarted, isInteractive, !defersAutomaticActionsUntilApplicationActivation
        else { return }
        guard store.hasKeyboardModeRules else {
            restoreStandardFunctionKeysIfNeeded()
            return
        }
        guard let application = applicationMonitor.frontmostApplication ?? currentApplication
        else { return }
        applyKeyboardMode(for: application.bundleIdentifier)
    }

    /// Waking up or unlocking can reset the top row without an application activation, so
    /// the current rule is applied again to keep the mode the user configured.
    private func handleSystemDidResume() {
        guard keyboardModeActive || appliedStandardFunctionKeys != nil else { return }
        cancelKeyboardModeRetry()
        reconcileKeyboardMode()
    }

    private func clearKeyboardModeErrorIfNeeded() {
        guard keyboardModeError != nil else { return }
        keyboardModeError = nil
        onStateChange?()
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
        guard !defersAutomaticActionsUntilApplicationActivation else { return }
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
