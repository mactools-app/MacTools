import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import MacToolsPluginKit

private enum DisplayVolumeSettingsSearchEntryID {
    static let shortcutTarget = "shortcut-target"
}

public final class DisplayVolumePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DisplayVolumePluginProvider(context: context)
    }
}

@MainActor
private struct DisplayVolumePluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            DisplayVolumePlugin(
                localization: PluginLocalization(bundle: context.resourceBundle),
                shortcutPreferences: DisplayVolumeShortcutPreferences(storage: context.storage)
            )
        ]
    }
}

enum DisplayVolumeShortcutDirection: Equatable {
    case decrease
    case increase

    var actionID: String {
        switch self {
        case .decrease:
            return "display-volume.decrease"
        case .increase:
            return "display-volume.increase"
        }
    }

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .decrease:
            return localization.string("shortcut.direction.decrease", defaultValue: "降低")
        case .increase:
            return localization.string("shortcut.direction.increase", defaultValue: "增加")
        }
    }

    var systemImage: String {
        switch self {
        case .decrease:
            return "speaker.wave.1.fill"
        case .increase:
            return "speaker.wave.3.fill"
        }
    }

    var multiplier: Double {
        switch self {
        case .decrease:
            return -1
        case .increase:
            return 1
        }
    }
}

struct DisplayVolumeShortcutAction: Equatable {
    let id: String
    let direction: DisplayVolumeShortcutDirection
    let targetDisplayIDs: [CGDirectDisplayID]
    private let identifiers: [CGDirectDisplayID: String]
    private let generation: UInt64

    init(id: String, direction: DisplayVolumeShortcutDirection, targetDisplayIDs: [CGDirectDisplayID],
         identifier: (CGDirectDisplayID) -> String?) {
        self.id = id
        self.direction = direction
        self.targetDisplayIDs = targetDisplayIDs
        generation = DisplayDDCIdentity.bindingGeneration
        identifiers = Dictionary(uniqueKeysWithValues: targetDisplayIDs.compactMap { id in
            identifier(id).map { (id, $0) }
        })
    }

    func matches(_ displayID: CGDirectDisplayID, identifier: String?) -> Bool {
        generation == DisplayDDCIdentity.bindingGeneration && identifiers[displayID] == identifier
    }
}

struct DisplayVolumeShortcutAcceleration {
    private var lastPressDateByActionID: [String: Date] = [:]
    private var quickPressCountByActionID: [String: Int] = [:]

    mutating func stepForPress(actionID: String, now: Date, fastTapWindow: TimeInterval = 0.48) -> Int {
        let quickPressCount: Int
        if let lastPressDate = lastPressDateByActionID[actionID],
           now.timeIntervalSince(lastPressDate) <= fastTapWindow {
            quickPressCount = min((quickPressCountByActionID[actionID] ?? 0) + 1, 9)
        } else {
            quickPressCount = 0
        }

        quickPressCountByActionID[actionID] = quickPressCount
        lastPressDateByActionID[actionID] = now
        return min(10, 1 + quickPressCount)
    }

    static func stepForHold(elapsed: TimeInterval, baseline: Int) -> Int {
        let elapsedStep: Int
        switch elapsed {
        case ..<0.45:
            elapsedStep = 1
        case ..<0.9:
            elapsedStep = 2
        case ..<1.35:
            elapsedStep = 3
        case ..<1.8:
            elapsedStep = 4
        case ..<2.4:
            elapsedStep = 6
        case ..<3.2:
            elapsedStep = 8
        default:
            elapsedStep = 10
        }

        return min(10, max(baseline, elapsedStep))
    }
}

private struct DisplayVolumeShortcutSession {
    let id: UUID
    let action: DisplayVolumeShortcutAction
    let task: Task<Void, Never>
}

@MainActor
final class DisplayVolumePlugin:
    MacToolsPlugin,
    PluginShortcutEventHandling,
    DisplayTopologyRefreshing,
    PluginSettingsSearchProviding,
    PluginActionProviding
{
    private enum Constants {
        static let panelItemID = "control"
        static let displayControlPrefix = "display."
        static let volumeControlSuffix = ".volume"
        static let shortcutGroupID = "display-volume.shortcuts"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "display-volume",
            title: localization.string("metadata.title", defaultValue: "显示器音量"),
            iconName: "speaker.wave.2",
            iconTint: Color(nsColor: .systemBlue),
            order: 30,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "快速调节每个显示器的音量"
            )
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let controller: DisplayVolumeControlling
    private let shortcutPreferences: DisplayVolumeShortcutPreferences
    private let mouseDisplayIDProvider: @MainActor () -> CGDirectDisplayID?
    private let localization: PluginLocalization
    private var isDetailRequested = false
    private var displayTopologyTask: Task<Void, Never>?
    private var shortcutAcceleration = DisplayVolumeShortcutAcceleration()
    private var shortcutSessions: [String: DisplayVolumeShortcutSession] = [:]

    init(
        controller: DisplayVolumeControlling? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        shortcutPreferences: DisplayVolumeShortcutPreferences? = nil,
        mouseDisplayIDProvider: @escaping @MainActor () -> CGDirectDisplayID? = DisplayVolumePlugin.currentMouseDisplayID
    ) {
        self.localization = localization
        self.controller = controller ?? DisplayVolumeController(localization: localization)
        self.shortcutPreferences = shortcutPreferences ?? DisplayVolumeShortcutPreferences(
            storage: UserDefaultsPluginStorage(pluginID: "display-volume")
        )
        self.mouseDisplayIDProvider = mouseDisplayIDProvider
        self.controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    var panelItems: [PluginPanelItem] {
        [
            .row(
                id: Constants.panelItemID,
                initialPlacement: .featurePanel,
                descriptor: rowDescriptor,
                state: rowState,
                action: { [weak self] in self?.handleAction($0) }
            )
        ]
    }

    var rowState: PluginPanelRowState {
        let snapshot = controller.snapshot()

        guard !snapshot.displays.isEmpty else {
            return PluginPanelRowState(
                subtitle: localization.string(
                    "panel.subtitle.noDisplays",
                    defaultValue: "未检测到可调节音量的显示器"
                ),
                isOn: false,
                isEnabled: false,
                isAvailable: true,
                detail: nil,
                errorMessage: snapshot.errorMessage
            )
        }

        return PluginPanelRowState(
            subtitle: subtitle(for: snapshot.displays),
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: isDetailRequested ? buildDetail(for: snapshot.displays) : nil,
            errorMessage: snapshot.errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "shortcut-target",
                    title: localization.string("settings.shortcutTarget.sectionTitle", defaultValue: "作用范围"),
                    systemImage: "display.2",
                    rows: [
                        PluginSettingsRow(
                            id: DisplayVolumeSettingsSearchEntryID.shortcutTarget,
                            title: localization.string("settings.shortcutTarget.title", defaultValue: "快捷键目标"),
                            description: shortcutPreferences.targetMode.description(localization: localization),
                            systemImage: "cursorarrow.motionlines",
                            control: .picker(
                                selectionID: shortcutPreferences.targetMode.rawValue,
                                options: DisplayVolumeShortcutPreferences.TargetMode.allCases.map {
                                    PluginSettingsOption(
                                        id: $0.rawValue,
                                        title: $0.title(localization: localization)
                                    )
                                },
                                style: .segmented
                            )
                        )
                    ]
                )
            ]
        )
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            shortcutDefinition(direction: .decrease),
            shortcutDefinition(direction: .increase)
        ]
    }

    private static let setDisplayVolumeActionID = "set-display-volume"

    var actionDefinitions: [ActionDefinition] {
        let relativeActions = [DisplayVolumeShortcutDirection.decrease, .increase].map { direction in
            let title = localization.format(
                "shortcut.titleFormat",
                defaultValue: "%@音量",
                direction.title(localization: localization)
            )
            return ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: direction.actionID),
                title: title,
                description: localization.format(
                    "shortcut.descriptionFormat",
                    defaultValue: "%@显示器音量。",
                    direction.title(localization: localization)
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "显示器音量"),
                    direction.title(localization: localization),
                ],
                systemImage: direction.systemImage,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive, .cancellable]
            )
        }
        return relativeActions + [setDisplayVolumeDefinition]
    }

    private var setDisplayVolumeDefinition: ActionDefinition {
        ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: Self.setDisplayVolumeActionID),
            title: localization.string("action.set.title", defaultValue: "设置显示器音量"),
            description: localization.string("action.set.description", defaultValue: "将指定显示器的音量调节到目标百分比"),
            systemImage: "speaker.wave.2",
            parameters: [
                ActionParameterDefinition(id: DisplayActionTarget.parameterID, title: metadata.title, kind: .string, portability: .localOnly),
                ActionPercentage.parameter,
            ],
            capabilities: [.automatic, .background, .foregroundInteractive, .cancellable]
        )
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        actionDefinitions.filter { $0.parameters.isEmpty }.map {
            ActionCatalogEntry(reference: ActionReference(key: $0.key), title: $0.title)
        } + DisplayActionTarget.catalogEntries(
            for: controller.snapshot().displays.map(\.display),
            definition: setDisplayVolumeDefinition,
            identifier: controller.actionIdentifier(for:)
        )
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        if reference.key.actionID == Self.setDisplayVolumeActionID {
            guard let target = DisplayActionTarget.resolve(
                reference,
                in: controller.snapshot().displays.map(\.display),
                identifier: controller.actionIdentifier(for:)
            ) else { return .unavailable(PluginKitLocalization.actionUnavailable) }
            return controller.exactVolumeAvailability(for: target.display.id)
        }
        guard Self.shortcutDirection(for: reference.key.actionID) != nil else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        let targets = shortcutTargets(in: controller.snapshot())
        if let reason = relativeVolumeUnavailableReason(for: targets) {
            return .unavailable(reason)
        }
        return .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        if invocation.reference.key.actionID == Self.setDisplayVolumeActionID {
            let reference = invocation.reference
            let controller = controller
            return ActionExecutionHandle {
                guard !Task.isCancelled else { return .cancelled }
                guard let target = DisplayActionTarget.resolve(
                    reference,
                    in: controller.snapshot().displays.map(\.display),
                    identifier: controller.actionIdentifier(for:)
                ) else { return .failed(message: PluginKitLocalization.actionUnavailable) }
                switch await controller.setExactVolumeAndWait(
                    Double(target.percent) / 100, for: target.display.id, identifier: target.identifier
                ) {
                case .succeeded: return .succeeded()
                case let .failed(message): return .failed(message: message)
                }
            }
        }
        guard let direction = Self.shortcutDirection(for: invocation.reference.key.actionID) else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionUnavailable) }
        }
        let targets = shortcutTargets(in: controller.snapshot())
        if let reason = relativeVolumeUnavailableReason(for: targets) {
            return ActionExecutionHandle { .failed(message: reason) }
        }
        let action = DisplayVolumeShortcutAction(
            id: invocation.reference.key.actionID,
            direction: direction,
            targetDisplayIDs: targets.map(\.id),
            identifier: controller.actionIdentifier(for:)
        )
        let delta = action.direction.multiplier / 100
        return ActionExecutionHandle { [self] in
            let displays = displays(for: action)
            guard displays.count == action.targetDisplayIDs.count else {
                return .failed(message: PluginKitLocalization.actionUnavailable)
            }
            if let reason = relativeVolumeUnavailableReason(for: displays) {
                return .failed(message: reason)
            }
            var failures: [String] = []
            for displayID in action.targetDisplayIDs {
                guard action.matches(displayID, identifier: controller.actionIdentifier(for: displayID)) else {
                    failures.append(PluginKitLocalization.actionUnavailable)
                    continue
                }
                switch await controller.adjustVolumeAndWait(by: delta, for: displayID) {
                case .succeeded:
                    continue
                case let .failed(message):
                    failures.append(message)
                }
            }
            return failures.isEmpty
                ? .succeeded()
                : .failed(message: failures.joined(separator: "；"))
        }
    }

    var settingsSearchEntries: [PluginSettingsSearchEntry] {
        [
            PluginSettingsSearchEntry(
                id: DisplayVolumeSettingsSearchEntryID.shortcutTarget,
                title: localization.string(
                    "settings.shortcutTarget.title",
                    defaultValue: "快捷键目标"
                ),
                description: localization.string(
                    "settings.shortcutTarget.searchDescription",
                    defaultValue: "选择音量快捷键控制的显示器范围。"
                ),
                keywords: [
                    localization.string(
                        "settings.shortcutTarget.sectionTitle",
                        defaultValue: "作用范围"
                    ),
                    localization.string(
                        "settings.shortcutTarget.searchKeyword",
                        defaultValue: "屏幕"
                    )
                ],
                systemImage: "display.2"
            )
        ]
    }

    func refresh() {
        controller.refresh()
    }

    func refreshDisplayTopology() {
        controller.refreshDisplayTopology()
        displayTopologyTask?.cancel()
        displayTopologyTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.controller.refresh()
            self?.onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(value):
            isDetailRequested = value
            onStateChange?()
        case let .setSlider(controlID, value, phase):
            guard let displayID = controller.snapshot().displays.first(where: {
                sliderControlID(for: $0.id) == controlID
            })?.id else { return }

            controller.setVolume(value, for: displayID, phase: phase)
            onStateChange?()
        case .invokeAction:
            return
        case .setSwitch,
             .setSelection,
             .setNavigationSelection,
             .clearNavigationSelection,
             .setDate:
            return
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard case let .setSelection(controlID, optionID) = action,
              controlID == DisplayVolumeSettingsSearchEntryID.shortcutTarget,
              let mode = DisplayVolumeShortcutPreferences.TargetMode(rawValue: optionID)
        else { return }
        shortcutPreferences.targetMode = mode
        onStateChange?()
    }
    func handleShortcutAction(id: String) {
        handleShortcutEvent(id: id, phase: .pressed)
    }

    func handleShortcutEvent(id: String, phase: PluginShortcutEventPhase) {
        switch phase {
        case .pressed:
            startShortcutAction(id: id)
        case .released:
            stopShortcutAction(id: id)
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        displayTopologyTask?.cancel()
        stopAllShortcutActions()
        controller.cancelOutstandingWrites()
    }

    private func sliderControlID(for displayID: CGDirectDisplayID) -> String {
        // SwiftUI retains the gesture's local value for the lifetime of this ID.
        let identity = controller.actionIdentifier(for: displayID)?.hashValue ?? 0
        let binding = DisplayDDCIdentity.bindingGeneration
        return "\(Constants.displayControlPrefix)\(displayID).\(binding).\(identity)\(Constants.volumeControlSuffix)"
    }

    private func subtitle(for displays: [DisplayVolumeDisplay]) -> String {
        if displays.count == 1, let display = displays.first {
            return display.isReady ? "\(display.display.name) \(Self.percentText(for: display.volume))" : display.display.name
        }

        return localization.format("panel.subtitle.displayCountFormat", defaultValue: "%d 个显示器", displays.count)
    }

    private func buildDetail(for displays: [DisplayVolumeDisplay]) -> PluginPanelDetail {
        let volumeControls = displays.map { display in
            PluginPanelControl(
                id: sliderControlID(for: display.id),
                kind: .slider,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: display.display.name,
                sliderValue: display.volume,
                sliderBounds: 0...1,
                sliderStep: 0.01,
                valueLabel: display.isReady ? Self.percentText(for: display.volume) : nil,
                isEnabled: true
            )
        }

        return PluginPanelDetail(
            primaryControls: volumeControls,
            secondaryPanel: nil
        )
    }

    private static func percentText(for volume: Double) -> String {
        "\(Int((volume * 100).rounded()))%"
    }

    private func shortcutDefinition(direction: DisplayVolumeShortcutDirection) -> PluginShortcutDefinition {
        let actionID = direction.actionID
        let directionTitle = direction.title(localization: localization)

        return PluginShortcutDefinition(
            id: actionID,
            title: localization.format("shortcut.titleFormat", defaultValue: "%@音量", directionTitle),
            description: localization.format("shortcut.descriptionFormat", defaultValue: "%@显示器音量。", directionTitle),
            actionID: actionID,
            scope: .global,
            defaultBinding: nil,
            isRequired: false,
            settingsGroupID: Constants.shortcutGroupID,
            settingsGroupTitle: localization.string(
                "shortcut.settingsGroupTitle",
                defaultValue: "音量快捷键"
            ),
            settingsGroupDescription: localization.string(
                "shortcut.settingsGroupDescription",
                defaultValue: "按所选作用范围调整显示器音量。"
            ),
            settingsControlSystemImage: direction.systemImage
        )
    }

    private func startShortcutAction(id: String) {
        guard shortcutSessions[id] == nil,
              let direction = Self.shortcutDirection(for: id)
        else {
            return
        }

        var snapshot = controller.snapshot()
        if snapshot.displays.isEmpty {
            controller.refresh()
            snapshot = controller.snapshot()
        }

        let targetDisplayIDs = shortcutTargetDisplayIDs(in: snapshot)
        guard !targetDisplayIDs.isEmpty else {
            return
        }

        let action = DisplayVolumeShortcutAction(
            id: id,
            direction: direction,
            targetDisplayIDs: targetDisplayIDs,
            identifier: controller.actionIdentifier(for:)
        )
        let now = Date()
        let initialStep = shortcutAcceleration.stepForPress(actionID: id, now: now)
        applyShortcutAction(action, step: initialStep, phase: .changed)
        scheduleShortcutRepeats(for: action, initialStep: initialStep, startDate: now)
    }

    private func stopShortcutAction(id: String) {
        guard let session = shortcutSessions.removeValue(forKey: id) else {
            return
        }

        session.task.cancel()
        commitShortcutAction(session.action)
    }

    private func stopAllShortcutActions() {
        for session in shortcutSessions.values {
            session.task.cancel()
        }
        shortcutSessions.removeAll()
    }

    private func scheduleShortcutRepeats(
        for action: DisplayVolumeShortcutAction,
        initialStep: Int,
        startDate: Date
    ) {
        let sessionID = UUID()
        let task = Task { @MainActor [weak self] in
            await Self.sleep(seconds: Self.initialHoldDelay)
            var repeatCount = 0

            while !Task.isCancelled {
                guard let self,
                      self.shortcutSessions[action.id]?.id == sessionID
                else {
                    return
                }

                guard repeatCount < Self.maximumHoldRepeatCount else {
                    self.stopShortcutAction(id: action.id)
                    return
                }

                let elapsed = Date().timeIntervalSince(startDate)
                let step = DisplayVolumeShortcutAcceleration.stepForHold(
                    elapsed: elapsed,
                    baseline: initialStep
                )
                self.applyShortcutAction(action, step: step, phase: .changed)
                repeatCount += 1
                await Self.sleep(seconds: Self.repeatDelay)
            }
        }

        shortcutSessions[action.id] = DisplayVolumeShortcutSession(
            id: sessionID,
            action: action,
            task: task
        )
    }

    private func applyShortcutAction(
        _ action: DisplayVolumeShortcutAction,
        step: Int,
        phase: PluginPanelAction.SliderPhase
    ) {
        let displays = displays(for: action)
        guard displays.count == action.targetDisplayIDs.count,
              relativeVolumeUnavailableReason(for: displays) == nil else { return }
        let delta = Double(step) / 100 * action.direction.multiplier
        for display in displays {
            controller.adjustVolume(by: delta, for: display.id, phase: phase)
        }
    }

    private func commitShortcutAction(_ action: DisplayVolumeShortcutAction) {
        applyShortcutAction(action, step: 0, phase: .ended)
    }

    private func displays(for action: DisplayVolumeShortcutAction) -> [DisplayVolumeDisplay] {
        let displaysByID = Dictionary(uniqueKeysWithValues: controller.snapshot().displays.map { ($0.id, $0) })
        return action.targetDisplayIDs.compactMap { id in
            guard action.matches(id, identifier: controller.actionIdentifier(for: id)) else { return nil }
            return displaysByID[id]
        }
    }

    private func shortcutTargetDisplayIDs(in snapshot: DisplayVolumeSnapshot) -> [CGDirectDisplayID] {
        let targets = shortcutTargets(in: snapshot)
        guard relativeVolumeUnavailableReason(for: targets) == nil else { return [] }
        return targets.map(\.id)
    }

    private func shortcutTargets(in snapshot: DisplayVolumeSnapshot) -> [DisplayVolumeDisplay] {
        switch shortcutPreferences.targetMode {
        case .followsMouse:
            if let mouseDisplayID = mouseDisplayIDProvider(),
               let mouseDisplay = snapshot.displays.first(where: { $0.id == mouseDisplayID }) {
                return [mouseDisplay]
            }
            if let display = snapshot.displays.first(where: { $0.display.isMain }) ?? snapshot.displays.first {
                return [display]
            }
            return []
        case .allDisplays:
            return snapshot.displays
        }
    }

    private func relativeVolumeUnavailableReason(for targets: [DisplayVolumeDisplay]) -> String? {
        if targets.isEmpty {
            return localization.string(
                "action.unavailable.noDisplays",
                defaultValue: "未检测到可调节音量的显示器。"
            )
        }
        guard let unavailable = targets.first(where: { !$0.canAdjustRelative }) else { return nil }
        return DisplayVolumeControllerError.volumeUnavailable(displayName: unavailable.display.name)
            .localizedDescription(localization: localization)
    }

    private static var initialHoldDelay: TimeInterval {
        systemKeyboardTiming(
            key: "InitialKeyRepeat",
            fallback: 25,
            minimum: 0.22,
            maximum: 0.55
        )
    }

    private static var repeatDelay: TimeInterval {
        systemKeyboardTiming(
            key: "KeyRepeat",
            fallback: 6,
            minimum: 0.075,
            maximum: 0.16
        )
    }

    private static var maximumHoldRepeatCount: Int { 100 }

    private static func systemKeyboardTiming(
        key: String,
        fallback: Double,
        minimum: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        let rawValue = UserDefaults.standard.object(forKey: key) as? Double ?? fallback
        return min(max(rawValue * 0.014, minimum), maximum)
    }

    private static func sleep(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    static func shortcutDirection(for actionID: String) -> DisplayVolumeShortcutDirection? {
        switch actionID {
        case DisplayVolumeShortcutDirection.decrease.actionID:
            return .decrease
        case DisplayVolumeShortcutDirection.increase.actionID:
            return .increase
        default:
            return nil
        }
    }

    private static func currentMouseDisplayID() -> CGDirectDisplayID? {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else {
            return nil
        }

        return displayID(for: screen)
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return screenNumber.uint32Value
    }
}


extension DisplayVolumePlugin: PluginPortablePreferencesProviding,
    PluginPortablePreferencesRestorationReporting, PluginPersistentPreferencesChangeSignaling {
    var onPersistentPreferencesChange: (() -> Void)? {
        get { shortcutPreferences.onPersistentPreferencesChange }
        set { shortcutPreferences.onPersistentPreferencesChange = newValue }
    }

    func makePortablePreferencesBackup() -> Data? { shortcutPreferences.portableBackup() }
    func restorePortablePreferences(from data: Data) { _ = restorePortablePreferencesReportingResult(from: data) }
    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard shortcutPreferences.restorePortableBackup(data) else { return false }
        onStateChange?()
        return true
    }
}

extension DisplayVolumePlugin: PluginActionExposureProviding {
    func exposurePolicy(for reference: ActionReference, on surface: ActionExposureSurface) -> ActionExposurePolicy {
        if surface.rawValue == "voice-control",
           reference.key.actionID == Self.setDisplayVolumeActionID { return .excluded }
        return .automatic
    }
}
