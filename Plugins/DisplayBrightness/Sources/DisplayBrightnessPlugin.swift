import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import MacToolsPluginKit

private enum DisplayBrightnessSettingsSearchEntryID {
    static let shortcutTarget = "shortcut-target"
}

public final class DisplayBrightnessPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DisplayBrightnessPluginProvider(context: context)
    }
}

@MainActor
private struct DisplayBrightnessPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            DisplayBrightnessPlugin(
                localization: PluginLocalization(bundle: context.resourceBundle),
                shortcutPreferences: DisplayBrightnessShortcutPreferences(storage: context.storage)
            )
        ]
    }
}

enum DisplayBrightnessShortcutDirection: Equatable {
    case decrease
    case increase

    var actionID: String {
        switch self {
        case .decrease:
            return "display-brightness.decrease"
        case .increase:
            return "display-brightness.increase"
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
            return "sun.min.fill"
        case .increase:
            return "sun.max.fill"
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

struct DisplayBrightnessShortcutAction: Equatable {
    let id: String
    let direction: DisplayBrightnessShortcutDirection
    let targetDisplayIDs: [CGDirectDisplayID]
}

struct DisplayBrightnessShortcutAcceleration {
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

private struct DisplayBrightnessShortcutSession {
    let id: UUID
    let action: DisplayBrightnessShortcutAction
    let task: Task<Void, Never>
}

@MainActor
final class DisplayBrightnessPlugin:
    MacToolsPlugin, PluginShortcutEventHandling, DisplayTopologyRefreshing, PluginSettingsSearchProviding, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    private enum Constants {
        static let displayControlPrefix = "display."
        static let brightnessControlSuffix = ".brightness"
        static let disableBuiltInDisplayActionID = "disable-built-in-display"
        static let restoreBuiltInDisplayActionID = "restore-built-in-display"
        static let shortcutGroupID = "display-brightness.shortcuts"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "display-brightness",
            title: localization.string("metadata.title", defaultValue: "显示器亮度"),
            iconName: "sun.max",
            iconTint: Color(nsColor: .systemYellow),
            order: 20,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "快速调节每个显示器的亮度"
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

    private let controller: DisplayBrightnessControlling
    private let displayDisableCoordinator: any DisplayDisableCoordinating
    private let showsDisplayDisableControls: Bool
    private let shortcutPreferences: DisplayBrightnessShortcutPreferences
    private let mouseDisplayIDProvider: @MainActor () -> CGDirectDisplayID?
    private let localization: PluginLocalization
    private var isExpanded = false
    private var displayDisableActionTask: Task<Void, Never>?
    /// Where a display's slider sat, and its brightness, when it was switched off, so its greyed
    /// row keeps that place and value.
    private var offDisplayPlacements: [CGDirectDisplayID: OffDisplayPlacement] = [:]
    private var shortcutAcceleration = DisplayBrightnessShortcutAcceleration()
    private var shortcutSessions: [String: DisplayBrightnessShortcutSession] = [:]

    init(
        controller: DisplayBrightnessControlling? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        displayDisableCoordinator: (any DisplayDisableCoordinating)? = nil,
        showsDisplayDisableControls: Bool = true,
        shortcutPreferences: DisplayBrightnessShortcutPreferences? = nil,
        mouseDisplayIDProvider: @escaping @MainActor () -> CGDirectDisplayID? = DisplayBrightnessPlugin.currentMouseDisplayID
    ) {
        self.localization = localization
        self.controller = controller ?? DisplayBrightnessController(localization: localization)
        self.displayDisableCoordinator = displayDisableCoordinator ?? DisplayDisableCoordinator(
            service: Self.defaultDisplayDisableService(),
            store: UserDefaultsDisplayDisableStateStore(),
            lidObserver: SystemDisplayLidObserver(),
            localization: localization
        )
        self.showsDisplayDisableControls = showsDisplayDisableControls
        self.shortcutPreferences = shortcutPreferences ?? DisplayBrightnessShortcutPreferences(
            storage: UserDefaultsPluginStorage(pluginID: "display-brightness")
        )
        self.mouseDisplayIDProvider = mouseDisplayIDProvider
        self.controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
        self.displayDisableCoordinator.onSnapshotChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    var rowState: PluginPanelRowState {
        let snapshot = controller.snapshot()
        let disableMessage = showsDisplayDisableControls ? displayDisableCoordinator.snapshot.message : nil

        guard !snapshot.displays.isEmpty || hasOffDisplayRows else {
            return PluginPanelRowState(
                subtitle: localization.string(
                    "panel.subtitle.noDisplays",
                    defaultValue: "未检测到可调节亮度的显示器"
                ),
                isOn: false,
                isEnabled: false,
                isAvailable: true,
                detail: nil,
                errorMessage: snapshot.errorMessage ?? disableMessage
            )
        }

        return PluginPanelRowState(
            subtitle: snapshot.displays.isEmpty
                ? localization.string("panel.subtitle.noDisplays", defaultValue: "未检测到可调节亮度的显示器")
                : subtitle(for: snapshot.displays),
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: isExpanded ? buildDetail(for: snapshot.displays) : nil,
            errorMessage: snapshot.errorMessage ?? disableMessage
        )
    }

    /// Whether a display without a brightness slider still needs a row for its power button.
    private var hasOffDisplayRows: Bool {
        let snapshot = displayDisableCoordinator.snapshot
        return snapshot.entries.contains { switchableEntry(for: $0.id, in: snapshot) != nil }
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
                            id: DisplayBrightnessSettingsSearchEntryID.shortcutTarget,
                            title: localization.string("settings.shortcutTarget.title", defaultValue: "快捷键目标"),
                            description: shortcutPreferences.targetMode.description(localization: localization),
                            systemImage: "cursorarrow.motionlines",
                            control: .picker(
                                selectionID: shortcutPreferences.targetMode.rawValue,
                                options: DisplayBrightnessShortcutPreferences.TargetMode.allCases.map {
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

    var actionDefinitions: [ActionDefinition] {
        let brightnessActions = [DisplayBrightnessShortcutDirection.decrease, .increase].map { direction in
            let title = localization.format(
                "shortcut.titleFormat",
                defaultValue: "%@亮度",
                direction.title(localization: localization)
            )
            return ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: direction.actionID),
                title: title,
                description: localization.format(
                    "shortcut.descriptionFormat",
                    defaultValue: "%@显示器亮度。",
                    direction.title(localization: localization)
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "显示器亮度"),
                    direction.title(localization: localization),
                ],
                systemImage: direction.systemImage,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive, .cancellable]
            )
        }
        return brightnessActions + [
            ActionDefinition(
                key: ActionKey(
                    providerID: metadata.id,
                    actionID: Constants.disableBuiltInDisplayActionID
                ),
                title: localization.string(
                    "displayDisable.action.disable",
                    defaultValue: "关闭内建显示屏"
                ),
                description: localization.string(
                    "displayDisable.message.needsExternalDisplay",
                    defaultValue: "连接外接显示器后可关闭内建显示屏"
                ),
                keywords: [metadata.title, "display", "disable"],
                systemImage: "display",
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: localization.string(
                        "displayDisable.action.disable",
                        defaultValue: "关闭内建显示屏"
                    ),
                    message: localization.string(
                        "displayDisable.message.needsExternalDisplay",
                        defaultValue: "连接外接显示器后可关闭内建显示屏"
                    ),
                    confirmButtonTitle: localization.string(
                        "displayDisable.action.disable",
                        defaultValue: "关闭内建显示屏"
                    )
                ),
                externalInvocationPolicy: .unavailable,
                capabilities: [.automatic, .background, .foregroundInteractive, .changesDisplayConfiguration]
            ),
            ActionDefinition(
                key: ActionKey(
                    providerID: metadata.id,
                    actionID: Constants.restoreBuiltInDisplayActionID
                ),
                title: localization.string(
                    "displayDisable.action.restore",
                    defaultValue: "恢复内建显示屏"
                ),
                description: metadata.defaultDescription,
                keywords: [metadata.title, "display", "restore"],
                systemImage: "display",
                externalInvocationPolicy: .unavailable,
                capabilities: [.automatic, .background, .foregroundInteractive, .changesDisplayConfiguration]
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        if Self.shortcutDirection(for: reference.key.actionID) != nil {
            return controller.snapshot().displays.isEmpty
                ? .unavailable(
                    localization.string(
                        "action.unavailable.noDisplays",
                        defaultValue: "未检测到可调节亮度的显示器。"
                    )
                )
                : .available
        }

        displayDisableCoordinator.refreshSnapshot()
        let builtIn = displayDisableCoordinator.snapshot.builtIn
        switch reference.key.actionID {
        case Constants.disableBuiltInDisplayActionID:
            guard let builtIn, !builtIn.isDisabled else {
                return .unavailable(builtIn == nil ? noBuiltInDisplayMessage : PluginKitLocalization.actionUnavailable)
            }
            return builtIn.isDisableAllowed
                ? .available
                : .unavailable(builtIn.unavailableReason ?? PluginKitLocalization.actionUnavailable)
        case Constants.restoreBuiltInDisplayActionID:
            return builtIn?.isDisabled == true
                ? .available
                : .unavailable(PluginKitLocalization.actionUnavailable)
        default:
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        if invocation.reference.key.actionID == Constants.disableBuiltInDisplayActionID {
            let coordinator = displayDisableCoordinator
            let noBuiltInDisplayMessage = noBuiltInDisplayMessage
            return ActionExecutionHandle { [weak self, coordinator] in
                coordinator.refreshSnapshot()
                guard let builtIn = coordinator.snapshot.builtIn, !builtIn.isDisabled else {
                    return .failed(message: noBuiltInDisplayMessage)
                }
                self?.rememberPlacement(of: builtIn.id)
                await coordinator.disableDisplay(builtIn.id)
                self?.onStateChange?()
                let snapshot = coordinator.snapshot
                return snapshot.entry(for: builtIn.id)?.isDisabled == true
                    ? .succeeded()
                    : .failed(message: snapshot.message ?? PluginKitLocalization.actionUnavailable)
            }
        }
        if invocation.reference.key.actionID == Constants.restoreBuiltInDisplayActionID {
            let coordinator = displayDisableCoordinator
            return ActionExecutionHandle { [weak self, coordinator] in
                coordinator.refreshSnapshot()
                guard let builtIn = coordinator.snapshot.builtIn, builtIn.isDisabled else {
                    return .failed(message: PluginKitLocalization.actionUnavailable)
                }
                coordinator.restoreDisplay(builtIn.id)
                self?.onStateChange?()
                let snapshot = coordinator.snapshot
                return snapshot.builtIn?.isDisabled == true
                    ? .failed(message: snapshot.message ?? PluginKitLocalization.actionUnavailable)
                    : .succeeded()
            }
        }

        guard let direction = Self.shortcutDirection(for: invocation.reference.key.actionID) else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionUnavailable) }
        }
        let snapshot = controller.snapshot()
        let targetDisplayIDs = shortcutTargetDisplayIDs(in: snapshot)
        guard !targetDisplayIDs.isEmpty else {
            let failureMessage = localization.string(
                "action.unavailable.noDisplays",
                defaultValue: "未检测到可调节亮度的显示器。"
            )
            return ActionExecutionHandle {
                .failed(message: failureMessage)
            }
        }
        let action = DisplayBrightnessShortcutAction(
            id: invocation.reference.key.actionID,
            direction: direction,
            targetDisplayIDs: targetDisplayIDs
        )
        let targets = displays(for: action.targetDisplayIDs).map { display in
            (
                display.id,
                min(1, max(0, display.brightness + action.direction.multiplier / 100))
            )
        }
        let controller = controller
        return ActionExecutionHandle {
            var failures: [String] = []
            for (displayID, target) in targets {
                switch await controller.setBrightnessAndWait(target, for: displayID) {
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
                id: DisplayBrightnessSettingsSearchEntryID.shortcutTarget,
                title: localization.string(
                    "settings.shortcutTarget.title",
                    defaultValue: "快捷键目标"
                ),
                description: localization.string(
                    "settings.shortcutTarget.searchDescription",
                    defaultValue: "选择亮度快捷键控制的显示器范围。"
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
        displayDisableCoordinator.refreshSnapshot()
    }

    func refreshDisplayTopology() {
        controller.refresh()
        displayDisableCoordinator.reconcileTopology()
        let snapshot = displayDisableCoordinator.snapshot
        offDisplayPlacements = offDisplayPlacements.filter { snapshot.entry(for: $0.key)?.isDisabled == true }
        onStateChange?()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(value):
            isExpanded = value
            onStateChange?()
        case let .setSlider(controlID, value, phase):
            guard let displayID = Self.parseDisplayID(from: controlID) else {
                DisplayBrightnessLog.plugin.error(
                    "invalid slider control id \(controlID, privacy: .public)"
                )
                return
            }

            controller.setBrightness(value, for: displayID, phase: phase)
            onStateChange?()
        case let .invokeAction(controlID):
            handleInvokeAction(controlID: controlID)
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
              controlID == DisplayBrightnessSettingsSearchEntryID.shortcutTarget,
              let mode = DisplayBrightnessShortcutPreferences.TargetMode(rawValue: optionID)
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

    func activate(context: PluginRuntimeContext) {
        // A switch-off lasts only for the process that made it. The window server normally
        // reverts it on exit; restore anything a previous run still left off, in case it did not.
        displayDisableCoordinator.restoreAllDisplays()
    }

    func deactivate(reason: PluginDeactivationReason) {
        displayDisableActionTask?.cancel()
        displayDisableActionTask = nil
        stopAllShortcutActions()
        controller.cancelOutstandingWrites()
        displayDisableCoordinator.deactivate(restoringDisplays: reason.requiresStateCleanup)
    }

    static func parseDisplayID(from controlID: String) -> CGDirectDisplayID? {
        guard
            controlID.hasPrefix(Constants.displayControlPrefix),
            controlID.hasSuffix(Constants.brightnessControlSuffix)
        else {
            return nil
        }

        let startIndex = controlID.index(
            controlID.startIndex,
            offsetBy: Constants.displayControlPrefix.count
        )
        let endIndex = controlID.index(
            controlID.endIndex,
            offsetBy: -Constants.brightnessControlSuffix.count
        )
        guard startIndex <= endIndex else {
            return nil
        }
        return CGDirectDisplayID(controlID[startIndex..<endIndex])
    }

    private func subtitle(for displays: [DisplayBrightnessDisplay]) -> String {
        if displays.count == 1, let display = displays.first {
            return "\(display.display.name) \(Self.percentText(for: display.brightness))"
        }

        return localization.format("panel.subtitle.displayCountFormat", defaultValue: "%d 个显示器", displays.count)
    }

    private func buildDetail(for displays: [DisplayBrightnessDisplay]) -> PluginPanelDetail {
        let disableSnapshot = displayDisableCoordinator.snapshot
        var rows = displays.map { display in
            BrightnessRow(
                id: display.id,
                name: display.display.name,
                brightness: display.brightness,
                isAdjustable: true,
                disableEntry: switchableEntry(for: display.id, in: disableSnapshot)
            )
        }

        // A display switched off by MacTools, or one without a brightness backend, keeps a
        // greyed slider so its power button stays where the person expects it.
        let sliderIDs = Set(displays.map(\.id))
        let extraRows = disableSnapshot.entries
            .filter { !sliderIDs.contains($0.id) }
            .compactMap { entry -> (index: Int, row: BrightnessRow)? in
                guard let disableEntry = switchableEntry(for: entry.id, in: disableSnapshot) else {
                    return nil
                }
                let placement = offDisplayPlacements[entry.id]
                let row = BrightnessRow(
                    id: entry.id,
                    name: entry.name,
                    brightness: placement?.brightness ?? 0,
                    isAdjustable: false,
                    disableEntry: disableEntry
                )
                return (placement?.index ?? Int.max, row)
            }
            .sorted { $0.index < $1.index }
        for extra in extraRows {
            rows.insert(extra.row, at: min(extra.index, rows.count))
        }

        return PluginPanelDetail(
            primaryControls: rows.map(brightnessControl(for:)),
            secondaryPanel: nil
        )
    }

    private struct OffDisplayPlacement {
        let index: Int
        let brightness: Double
    }

    private func rememberPlacement(of displayID: CGDirectDisplayID) {
        let displays = controller.snapshot().displays
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else {
            return
        }
        offDisplayPlacements[displayID] = OffDisplayPlacement(
            index: index,
            brightness: displays[index].brightness
        )
    }

    private struct BrightnessRow {
        let id: CGDirectDisplayID
        let name: String
        let brightness: Double
        let isAdjustable: Bool
        /// Present when the trailing power button can switch this display off or back on.
        let disableEntry: DisplayDisableEntry?
    }

    private func brightnessControl(for row: BrightnessRow) -> PluginPanelControl {
        let isOff = row.disableEntry?.isDisabled == true
        let valueLabel: String?
        if isOff {
            valueLabel = localization.string("displayDisable.status.off", defaultValue: "已关闭")
        } else {
            valueLabel = row.isAdjustable ? Self.percentText(for: row.brightness) : nil
        }

        return PluginPanelControl(
            id: "\(Constants.displayControlPrefix)\(row.id)\(Constants.brightnessControlSuffix)",
            kind: .slider,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: row.name,
            sliderValue: row.brightness,
            sliderBounds: 0...1,
            sliderStep: 0.01,
            valueLabel: valueLabel,
            actionTitle: row.disableEntry.map(displayDisableTitle(for:)),
            actionIconSystemName: row.disableEntry == nil ? nil : "power",
            isEnabled: row.isAdjustable && !isOff
        )
    }

    /// The display-disable entry whose power button can act now: switch off an allowed display,
    /// or switch back on one MacTools turned off.
    private func switchableEntry(
        for displayID: CGDirectDisplayID,
        in snapshot: DisplayDisableSnapshot
    ) -> DisplayDisableEntry? {
        guard showsDisplayDisableControls, snapshot.isSupported,
              let entry = snapshot.entry(for: displayID),
              entry.isDisabled || entry.isDisableAllowed
        else {
            return nil
        }
        return entry
    }

    private func displayDisableTitle(for entry: DisplayDisableEntry) -> String {
        switch (entry.isBuiltin, entry.isDisabled) {
        case (true, false):
            return localization.string("displayDisable.action.disable", defaultValue: "关闭内建显示屏")
        case (true, true):
            return localization.string("displayDisable.action.restore", defaultValue: "恢复内建显示屏")
        case (false, false):
            return localization.format("displayDisable.action.disableFormat", defaultValue: "关闭“%@”", entry.name)
        case (false, true):
            return localization.format("displayDisable.action.restoreFormat", defaultValue: "恢复“%@”", entry.name)
        }
    }

    /// The slider's power button: switch its display off, or back on when MacTools turned it off.
    private func handleInvokeAction(controlID: String) {
        guard let displayID = Self.parseDisplayID(from: controlID),
              let entry = displayDisableCoordinator.snapshot.entry(for: displayID),
              displayDisableActionTask == nil
        else {
            return
        }

        if entry.isDisabled {
            displayDisableCoordinator.restoreDisplay(displayID)
            onStateChange?()
            return
        }

        rememberPlacement(of: displayID)
        let coordinator = displayDisableCoordinator
        displayDisableActionTask = Task { @MainActor [weak self, coordinator] in
            await coordinator.disableDisplay(displayID)
            self?.displayDisableActionTask = nil
            self?.onStateChange?()
        }
        onStateChange?()
    }

    private var noBuiltInDisplayMessage: String {
        localization.string("displayDisable.message.noBuiltInDisplay", defaultValue: "未检测到内建显示屏")
    }

    private static func percentText(for brightness: Double) -> String {
        "\(Int((brightness * 100).rounded()))%"
    }

    private static func defaultDisplayDisableService() -> any DisplayDisableServicing {
        SystemDisplayDisableService()
    }

    private func shortcutDefinition(direction: DisplayBrightnessShortcutDirection) -> PluginShortcutDefinition {
        let actionID = direction.actionID
        let directionTitle = direction.title(localization: localization)

        return PluginShortcutDefinition(
            id: actionID,
            title: localization.format("shortcut.titleFormat", defaultValue: "%@亮度", directionTitle),
            description: localization.format("shortcut.descriptionFormat", defaultValue: "%@显示器亮度。", directionTitle),
            actionID: actionID,
            scope: .global,
            defaultBinding: nil,
            isRequired: false,
            settingsGroupID: Constants.shortcutGroupID,
            settingsGroupTitle: localization.string(
                "shortcut.settingsGroupTitle",
                defaultValue: "亮度快捷键"
            ),
            settingsGroupDescription: localization.string(
                "shortcut.settingsGroupDescription",
                defaultValue: "按所选作用范围调整显示器亮度。"
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

        let action = DisplayBrightnessShortcutAction(
            id: id,
            direction: direction,
            targetDisplayIDs: targetDisplayIDs
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
        for action: DisplayBrightnessShortcutAction,
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
                let step = DisplayBrightnessShortcutAcceleration.stepForHold(
                    elapsed: elapsed,
                    baseline: initialStep
                )
                self.applyShortcutAction(action, step: step, phase: .changed)
                repeatCount += 1
                await Self.sleep(seconds: Self.repeatDelay)
            }
        }

        shortcutSessions[action.id] = DisplayBrightnessShortcutSession(
            id: sessionID,
            action: action,
            task: task
        )
    }

    private func applyShortcutAction(
        _ action: DisplayBrightnessShortcutAction,
        step: Int,
        phase: PluginPanelAction.SliderPhase
    ) {
        let delta = Double(step) / 100 * action.direction.multiplier
        for display in displays(for: action.targetDisplayIDs) {
            controller.setBrightness(display.brightness + delta, for: display.id, phase: phase)
        }
    }

    private func commitShortcutAction(_ action: DisplayBrightnessShortcutAction) {
        for display in displays(for: action.targetDisplayIDs) {
            controller.setBrightness(display.brightness, for: display.id, phase: .ended)
        }
    }

    private func displays(for displayIDs: [CGDirectDisplayID]) -> [DisplayBrightnessDisplay] {
        let displaysByID = Dictionary(uniqueKeysWithValues: controller.snapshot().displays.map { ($0.id, $0) })
        return displayIDs.compactMap { displaysByID[$0] }
    }

    private func shortcutTargetDisplayIDs(in snapshot: DisplayBrightnessSnapshot) -> [CGDirectDisplayID] {
        switch shortcutPreferences.targetMode {
        case .followsMouse:
            if let mouseDisplayID = mouseDisplayIDProvider(),
               snapshot.displays.contains(where: { $0.id == mouseDisplayID }) {
                return [mouseDisplayID]
            }

            if let mainDisplay = snapshot.displays.first(where: { $0.display.isMain }) {
                return [mainDisplay.id]
            }

            return snapshot.displays.first.map { [$0.id] } ?? []
        case .allDisplays:
            return snapshot.displays.map(\.id)
        }
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

    static func shortcutDirection(for actionID: String) -> DisplayBrightnessShortcutDirection? {
        switch actionID {
        case DisplayBrightnessShortcutDirection.decrease.actionID:
            return .decrease
        case DisplayBrightnessShortcutDirection.increase.actionID:
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
