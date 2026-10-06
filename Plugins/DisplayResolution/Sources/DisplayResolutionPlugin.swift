import AppKit
import CoreGraphics
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class DisplayResolutionPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DisplayResolutionPluginProvider(context: context)
    }
}

@MainActor
private struct DisplayResolutionPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [DisplayResolutionPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

private enum ControlID {
    static let displayNavigation = "display-navigation"
    static let openSystemSettings = "display-open-system-settings"
}

@MainActor
protocol DisplaySystemSettingsLauncher {
    @discardableResult
    func openDisplaySettings() -> Bool
}

@MainActor
struct WorkspaceDisplaySystemSettingsLauncher: DisplaySystemSettingsLauncher {
    // Opens System Settings > Displays. The URL works for Ventura+ System Settings and the
    // legacy System Preferences app.
    private static let systemDisplaySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.displays")!

    @discardableResult
    func openDisplaySettings() -> Bool {
        NSWorkspace.shared.open(Self.systemDisplaySettingsURL)
    }
}

@MainActor
final class DisplayResolutionPlugin: MacToolsPlugin, DisplayTopologyRefreshing, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    private static let openSystemSettingsIcon = "gearshape"

    private enum ActionID {
        static let setResolution = "set-resolution"
    }

    private enum ActionParameterID {
        static let display = "display"
        static let width = "width"
        static let height = "height"
        static let pixelWidth = "pixel-width"
        static let pixelHeight = "pixel-height"
        static let refreshRate = "refresh-rate"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "display-resolution",
            title: localization.string("metadata.title", defaultValue: "显示器分辨率"),
            iconName: "display",
            iconTint: Color(nsColor: .systemBlue),
            order: 30,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "查看并切换每个显示器的分辨率"
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

    private var isExpanded = false
    private var selectedDisplayID: CGDirectDisplayID?
    private var lastError: DisplayResolutionError?
    private var lastErrorMessage: String? {
        guard let lastError else { return nil }
        return localization.format(
            "error.applyFailedFormat",
            defaultValue: "切换失败：%@",
            lastError.localizedDescription(localization: localization)
        )
    }
    private let controller: DisplayResolutionControlling
    private let systemSettingsLauncher: DisplaySystemSettingsLauncher
    private let displayIdentifier: (DisplayInfo) -> String?
    private let localization: PluginLocalization
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "DisplayResolutionPlugin")
    private var snapshot = DisplayResolutionSnapshot(displays: [])

    init(
        controller: DisplayResolutionControlling = DisplayResolutionController(),
        systemSettingsLauncher: DisplaySystemSettingsLauncher = WorkspaceDisplaySystemSettingsLauncher(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        displayIdentifier: @escaping (DisplayInfo) -> String? = {
            DisplayResolutionPlugin.stableDisplayIdentifier($0)
        }
    ) {
        self.localization = localization
        self.controller = controller
        self.systemSettingsLauncher = systemSettingsLauncher
        self.displayIdentifier = displayIdentifier
        refreshSnapshot()
    }

    var rowState: PluginPanelRowState {
        let displays = snapshot.displays
        let panelDisplays = displays.filter { !$0.modes.isEmpty }

        if !panelDisplays.contains(where: { $0.display.id == selectedDisplayID }) {
            selectedDisplayID = nil
        }

        guard !displays.isEmpty else {
            selectedDisplayID = nil
            return PluginPanelRowState(
                subtitle: localization.string("panel.subtitle.noDisplays", defaultValue: "未检测到可用显示器"),
                isOn: false,
                isEnabled: false,
                isAvailable: true,
                detail: nil,
                errorMessage: nil
            )
        }

        guard !panelDisplays.isEmpty else {
            selectedDisplayID = nil
            return PluginPanelRowState(
                subtitle: localization.string("panel.subtitle.noModes", defaultValue: "未检测到可用分辨率"),
                isOn: false,
                isEnabled: false,
                isAvailable: true,
                detail: nil,
                errorMessage: nil
            )
        }

        return PluginPanelRowState(
            subtitle: subtitleForRowState(panelDisplays),
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: isExpanded ? buildDetail(for: panelDisplays) : nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setResolution),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "resolution", "display"],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: ActionParameterID.display,
                        title: metadata.title,
                        kind: .string,
                        portability: .localOnly
                    ),
                    ActionParameterDefinition(
                        id: ActionParameterID.width,
                        title: localization.string("action.parameter.width", defaultValue: "宽度"),
                        kind: .integer
                    ),
                    ActionParameterDefinition(
                        id: ActionParameterID.height,
                        title: localization.string("action.parameter.height", defaultValue: "高度"),
                        kind: .integer
                    ),
                    ActionParameterDefinition(
                        id: ActionParameterID.pixelWidth,
                        title: localization.string("action.parameter.pixelWidth", defaultValue: "像素宽度"),
                        kind: .integer
                    ),
                    ActionParameterDefinition(
                        id: ActionParameterID.pixelHeight,
                        title: localization.string("action.parameter.pixelHeight", defaultValue: "像素高度"),
                        kind: .integer
                    ),
                    ActionParameterDefinition(
                        id: ActionParameterID.refreshRate,
                        title: localization.string("action.parameter.refreshRate", defaultValue: "刷新率"),
                        kind: .double
                    ),
                ],
                confirmation: ActionConfirmation(
                    title: metadata.title,
                    message: metadata.defaultDescription,
                    confirmButtonTitle: metadata.title
                ),
                externalInvocationPolicy: .confirmAlways,
                capabilities: [.automatic, .background, .foregroundInteractive, .changesDisplayConfiguration]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        snapshot.displays.flatMap { panelDisplay in
            panelDisplay.modes.compactMap { mode in
                guard let reference = resolutionActionReference(
                    display: panelDisplay.display,
                    mode: mode
                ) else {
                    return nil
                }
                return ActionCatalogEntry(
                    reference: reference,
                    title: "\(panelDisplay.display.name) · \(Self.optionTitle(for: mode, localization: localization))",
                    subtitle: metadata.title
                )
            }
        }
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        resolutionTarget(for: reference) == nil
            ? .unavailable(localization.string("error.modeNotFound", defaultValue: "分辨率模式已失效"))
            : .available
    }

    func refresh() {
        refreshSnapshot()
    }

    func refreshDisplayTopology() {
        refreshSnapshot()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(value):
            isExpanded = value
            if !value {
                selectedDisplayID = nil
            }
            lastError = nil
            onStateChange?()
        case let .setNavigationSelection(controlID, optionID):
            guard
                controlID == ControlID.displayNavigation,
                let rawDisplayID = UInt32(optionID)
            else {
                return
            }

            let displayID = CGDirectDisplayID(rawDisplayID)
            selectedDisplayID = displayID
            lastError = nil
            onStateChange?()
        case let .clearNavigationSelection(controlID):
            guard controlID == ControlID.displayNavigation else {
                return
            }

            selectedDisplayID = nil
            lastError = nil
            onStateChange?()
        case let .setSelection(controlID, optionID):
            guard let displayID = Self.parseDisplayID(from: controlID), let modeId = Int32(optionID) else {
                logger.error("invalid selection payload controlID=\(controlID, privacy: .public) optionID=\(optionID, privacy: .public)")
                return
            }

            refreshSnapshot()

            guard snapshot.displays.contains(where: { $0.display.id == displayID }) else {
                handleApplyFailure(.displayUnavailable(displayID: displayID), displayID: displayID, modeId: modeId)
                return
            }

            guard let target = snapshot.displays.first(where: { $0.display.id == displayID })?
                .allModes
                .first(where: { $0.modeId == modeId }) else {
                handleApplyFailure(.modeNotFound(modeId: modeId), displayID: displayID, modeId: modeId)
                return
            }

            logger.info("applying \(target.width)×\(target.height) on display \(displayID)")

            switch controller.applyResolution(target, for: displayID) {
            case .success:
                refreshSnapshot()
                lastError = nil
                logger.info("applied \(target.width)×\(target.height) on display \(displayID)")
                onStateChange?()
            case .failure(let error):
                handleApplyFailure(error, displayID: displayID, modeId: modeId)
            }
        case let .invokeAction(controlID):
            guard controlID == ControlID.openSystemSettings else {
                return
            }

            let opened = systemSettingsLauncher.openDisplaySettings()
            if !opened {
                logger.error("failed to open system display settings via NSWorkspace")
            }
        case .setSwitch, .setDate, .setSlider:
            return
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        refreshSnapshot()
        guard let target = resolutionTarget(for: invocation.reference) else {
            return ActionExecutionHandle {
                .failed(message: self.localization.string(
                    "error.modeNotFound",
                    defaultValue: "分辨率模式已失效"
                ))
            }
        }

        let result = controller.applyResolution(target.mode, for: target.displayID)
        switch result {
        case .success:
            refreshSnapshot()
            lastError = nil
            onStateChange?()
            return ActionExecutionHandle { .succeeded() }
        case let .failure(error):
            handleApplyFailure(error, displayID: target.displayID, modeId: target.mode.modeId)
            let message = lastErrorMessage ?? error.localizedDescription(localization: localization)
            return ActionExecutionHandle { .failed(message: message) }
        }
    }

    nonisolated static func visibleModes(_ modes: [DisplayResolutionInfo]) -> [DisplayResolutionInfo] {
        guard let first = modes.first else { return [] }
        let nativeAspect = modes.first(where: { $0.isNative })?.aspectRatio ?? first.aspectRatio
        return modes.filter { mode in
            abs(mode.aspectRatio - nativeAspect) < 0.005 || mode.isCurrent
        }
    }

    nonisolated static func optionTitle(
        for mode: DisplayResolutionInfo,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> String {
        var title = "\(mode.width)×\(mode.height)"
        if mode.isNative {
            title += localization.string("resolution.badge.native", defaultValue: " (原生)")
        } else if mode.isDefault {
            title += localization.string("resolution.badge.default", defaultValue: " (默认)")
        } else if mode.isHiDPI {
            title += " (HiDPI)"
        } else {
            title += " (LoDPI)"
        }
        return title
    }

    nonisolated static func parseDisplayID(from controlID: String) -> CGDirectDisplayID? {
        let prefix = "display."
        guard controlID.hasPrefix(prefix) else { return nil }
        return CGDirectDisplayID(controlID.dropFirst(prefix.count))
    }

    private func refreshSnapshot() {
        let displays = controller.listConnectedDisplays()
        let panelDisplays = displays.map { display in
            let modes = controller.listAvailableResolutions(for: display.id)
            return PanelDisplay(
                display: display,
                modes: Self.visibleModes(modes),
                allModes: modes
            )
        }

        snapshot = DisplayResolutionSnapshot(displays: panelDisplays)
    }

    private func subtitleForRowState(_ displays: [PanelDisplay]) -> String {
        if displays.count == 1, let display = displays.first {
            let current = display.modes.first(where: { $0.isCurrent })
            return current.map {
                let displayName = display.display.isMain
                    ? localization.string("display.main", defaultValue: "主屏")
                    : display.display.name
                return "\(displayName) \($0.displayTitle)"
            } ?? metadata.defaultDescription
        }
        return localization.format("panel.subtitle.displayCountFormat", defaultValue: "%d 个显示器", displays.count)
    }

    private func buildDetail(for displays: [PanelDisplay]) -> PluginPanelDetail {
        let displayNavigation = PluginPanelControl(
            id: ControlID.displayNavigation,
            kind: .navigationList,
            options: displays.map { display in
                let currentSummary = display.modes.first(where: { $0.isCurrent })?.displayTitle
                    ?? localization.string("display.currentResolution.unknown", defaultValue: "未知")

                return PluginPanelControlOption(
                    id: String(display.display.id),
                    title: display.display.name,
                    subtitle: currentSummary
                )
            },
            selectedOptionID: selectedDisplayID.map(String.init),
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            isEnabled: true
        )

        let openSystemSettings = PluginPanelControl(
            id: ControlID.openSystemSettings,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.openSystemSettings", defaultValue: "打开系统显示器设置"),
            actionIconSystemName: Self.openSystemSettingsIcon,
            actionBehavior: .dismissBeforeHandling,
            showsLeadingDivider: true,
            isEnabled: true
        )

        let navigationSecondaryPanels = displays.map { display in
            PluginPanelNavigationSecondaryPanel(
                controlID: ControlID.displayNavigation,
                optionID: String(display.display.id),
                panel: secondaryPanel(for: display)
            )
        }
        let selectedSecondaryPanel = selectedDisplayID.flatMap { selectedID in
            displays.first(where: { $0.display.id == selectedID }).map(secondaryPanel(for:))
        }

        return PluginPanelDetail(
            primaryControls: [displayNavigation, openSystemSettings],
            secondaryPanel: selectedSecondaryPanel,
            navigationSecondaryPanels: navigationSecondaryPanels
        )
    }

    private func secondaryPanel(for display: PanelDisplay) -> PluginPanelSecondaryPanel {
        let resolutionControl = PluginPanelControl(
            id: "display.\(display.display.id)",
            kind: .selectList,
            options: display.modes.map {
                PluginPanelControlOption(
                    id: String($0.modeId),
                    title: Self.optionTitle(for: $0, localization: localization),
                    subtitle: nil
                )
            },
            selectedOptionID: display.modes.first(where: { $0.isCurrent }).map { String($0.modeId) },
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            isEnabled: true
        )

        return PluginPanelSecondaryPanel(title: display.display.name, controls: [resolutionControl])
    }

    private func handleApplyFailure(
        _ error: DisplayResolutionError,
        displayID: CGDirectDisplayID,
        modeId: Int32
    ) {
        logger.error(
            "apply failed display=\(displayID) modeId=\(modeId) reason=\(error.localizedDescription, privacy: .public)"
        )
        lastError = error
        onStateChange?()
    }

    private func resolutionActionReference(
        display: DisplayInfo,
        mode: DisplayResolutionInfo
    ) -> ActionReference? {
        guard let identifier = displayIdentifier(display) else { return nil }
        return ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setResolution),
            parameters: try! ActionParameterSet([
                ActionParameterID.display: .string(identifier),
                ActionParameterID.width: .integer(Int64(mode.width)),
                ActionParameterID.height: .integer(Int64(mode.height)),
                ActionParameterID.pixelWidth: .integer(Int64(mode.pixelWidth)),
                ActionParameterID.pixelHeight: .integer(Int64(mode.pixelHeight)),
                ActionParameterID.refreshRate: .double(mode.refreshRate),
            ])
        )
    }

    private func resolutionTarget(
        for reference: ActionReference
    ) -> (displayID: CGDirectDisplayID, mode: DisplayResolutionInfo)? {
        guard reference.key.actionID == ActionID.setResolution,
              case let .string(displayIdentifier)? = reference.parameters[ActionParameterID.display],
              case let .integer(width)? = reference.parameters[ActionParameterID.width],
              case let .integer(height)? = reference.parameters[ActionParameterID.height],
              case let .integer(pixelWidth)? = reference.parameters[ActionParameterID.pixelWidth],
              case let .integer(pixelHeight)? = reference.parameters[ActionParameterID.pixelHeight],
              case let .double(refreshRate)? = reference.parameters[ActionParameterID.refreshRate],
              let display = snapshot.displays.first(where: {
                  self.displayIdentifier($0.display) == displayIdentifier
              }),
              let mode = display.allModes.first(where: {
                  $0.width == Int(width)
                      && $0.height == Int(height)
                      && $0.pixelWidth == Int(pixelWidth)
                      && $0.pixelHeight == Int(pixelHeight)
                      && abs($0.refreshRate - refreshRate) < 0.01
              }) else {
            return nil
        }

        return (display.display.id, mode)
    }

    nonisolated static func stableDisplayIdentifier(_ display: DisplayInfo) -> String? {
        if display.isBuiltin {
            return "builtin"
        }
        if let vendor = display.vendorNumber,
           let model = display.modelNumber,
           let serial = display.serialNumber,
           serial > 0 {
            return "display-\(vendor)-\(model)-\(serial)"
        }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue() else {
            return nil
        }
        return "display-uuid-\((CFUUIDCreateString(nil, uuid) as String).uppercased())"
    }
}

private struct PanelDisplay {
    let display: DisplayInfo
    let modes: [DisplayResolutionInfo]
    let allModes: [DisplayResolutionInfo]
}

private struct DisplayResolutionSnapshot {
    let displays: [PanelDisplay]
}
