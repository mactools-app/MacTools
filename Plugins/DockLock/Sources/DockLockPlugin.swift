import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

protocol DockLockMonitoring: AnyObject {
    @discardableResult
    func start() -> Bool
    func stop()
}

enum DockLockCursorBoundary {
    static let bottomInset: CGFloat = 4
    private static let adjacentEdgeTolerance: CGFloat = 1

    struct ScreenGeometry: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect

        var hostsBottomDock: Bool {
            visibleFrame.minY - frame.minY > adjacentEdgeTolerance
        }
    }

    static func clampedQuartzLocation(
        for location: CGPoint,
        primaryDisplayHeight: CGFloat,
        screens: [ScreenGeometry]
    ) -> CGPoint? {
        guard primaryDisplayHeight > 0, screens.count > 1 else {
            return nil
        }

        let appKitLocation = CGPoint(x: location.x, y: primaryDisplayHeight - location.y)
        guard let screenIndex = screens.firstIndex(where: { $0.frame.contains(appKitLocation) }) else {
            return nil
        }
        let screenFrame = screens[screenIndex].frame
        guard appKitLocation.y - screenFrame.minY < bottomInset else {
            return nil
        }

        let dockScreenIndices = screens.indices.filter { screens[$0].hostsBottomDock }
        // If macOS does not expose a unique visible Dock edge, preserve native pointer behavior.
        guard !dockScreenIndices.isEmpty, !dockScreenIndices.contains(screenIndex) else {
            return nil
        }

        // A touching display below makes this an internal transition rather than a Dock trigger.
        let hasDisplayBelow = screens.indices.contains { otherIndex in
            guard otherIndex != screenIndex else { return false }
            let otherFrame = screens[otherIndex].frame
            return abs(otherFrame.maxY - screenFrame.minY) <= adjacentEdgeTolerance
                && appKitLocation.x >= otherFrame.minX
                && appKitLocation.x < otherFrame.maxX
        }
        guard !hasDisplayBelow else {
            return nil
        }

        return CGPoint(
            x: location.x,
            y: primaryDisplayHeight - (screenFrame.minY + bottomInset)
        )
    }
}

enum DockLockDockOrientation {
    static func isBottom(preferenceValue: Any?) -> Bool {
        guard let orientation = preferenceValue as? String else {
            return false
        }
        return orientation.caseInsensitiveCompare("bottom") == .orderedSame
    }
}

enum DockLockDockPreferences {
    static func shouldClamp(orientationValue: Any?, autoHideValue: Any?) -> Bool {
        DockLockDockOrientation.isBottom(preferenceValue: orientationValue)
            && (autoHideValue as? Bool != true)
    }
}

final class DockLockMonitor: NSObject, DockLockMonitoring {
    private typealias CallbackContext = PluginCallbackContext<DockLockMonitor>
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "DockLockPlugin"
    )
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapCallbackPointer: UnsafeMutableRawPointer?
    private var dockPositionTimer: Timer?
    private var shouldClampPointer = false

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else {
            return true
        }

        let events: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)

        let callbackContext = CallbackContext(owner: self)
        let callbackPointer = Unmanaged.passRetained(callbackContext).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: events,
            callback: Self.eventTapCallback,
            userInfo: callbackPointer
        ) else {
            callbackContext.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            logger.error("Failed to create Dock Lock event tap")
            return false
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            callbackContext.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            logger.error("Failed to create Dock Lock run loop source")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        eventTapCallbackPointer = callbackPointer
        refreshDockPosition()
        CGEvent.tapEnable(tap: eventTap, enable: true)
        startDockPositionPolling()
        return true
    }

    func stop() {
        guard let eventTap else {
            return
        }

        if let eventTapCallbackPointer {
            let context = Unmanaged<CallbackContext>
                .fromOpaque(eventTapCallbackPointer)
                .takeUnretainedValue()
            context.invalidate()
        }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        runLoopSource = nil
        if let eventTapCallbackPointer {
            Unmanaged<CallbackContext>.fromOpaque(eventTapCallbackPointer).release()
            self.eventTapCallbackPointer = nil
        }
        dockPositionTimer?.invalidate()
        dockPositionTimer = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let context = Unmanaged<CallbackContext>.fromOpaque(userInfo).takeUnretainedValue()
        return context.withOwner { monitor in
            monitor.handle(event: event, type: type)
        } ?? Unmanaged.passUnretained(event)
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Auto-hide needs the real screen edge to reveal the Dock, so protection pauses in that mode.
        guard shouldClampPointer else {
            return Unmanaged.passUnretained(event)
        }

        let screens = NSScreen.screens
        let screenGeometries = screens.map {
            DockLockCursorBoundary.ScreenGeometry(
                frame: $0.frame,
                visibleFrame: $0.visibleFrame
            )
        }
        let primaryDisplayHeight = screens.first(where: { $0.frame.minX == 0 && $0.frame.minY == 0 })?.frame.height ?? 0
        if let clampedLocation = DockLockCursorBoundary.clampedQuartzLocation(
            for: event.location,
            primaryDisplayHeight: primaryDisplayHeight,
            screens: screenGeometries
        ) {
            event.location = clampedLocation
        }
        return Unmanaged.passUnretained(event)
    }

    private func startDockPositionPolling() {
        let timer = Timer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(refreshDockPosition),
            userInfo: nil,
            repeats: true
        )
        dockPositionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func refreshDockPosition() {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        shouldClampPointer = DockLockDockPreferences.shouldClamp(
            orientationValue: dockDefaults?.object(forKey: "orientation"),
            autoHideValue: dockDefaults?.object(forKey: "autohide")
        )
    }
}

public final class DockLockPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DockLockPluginProvider(context: context)
    }
}

@MainActor
private struct DockLockPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [DockLockPlugin(context: context, localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class DockLockPlugin:
    MacToolsPlugin, AccessibilityPermissionRefreshing, PluginActionProviding, PluginActionPermissionProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        let descriptor = rowDescriptor
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: descriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("metadata.title", defaultValue: metadata.title),
                systemImage: metadata.iconName,
                control: .toggle,
                state: state,
                menuActionBehavior: descriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    private enum ActionID {
        static let toggle = "toggle"
        static let setEnabled = "set-enabled"
    }

    private enum PermissionID {
        static let accessibility = "accessibility"
    }

    private enum StorageKey {
        static let isEnabled = "dock-lock.enabled"
    }

    private enum SettingsID {
        static let section = "dock-lock.settings"
        static let isEnabled = "dock-lock.settings.enabled"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "dock-lock",
            title: localization.string("metadata.title", defaultValue: "锁定程序坞"),
            iconName: "lock.rectangle",
            iconTint: Color(nsColor: .systemIndigo),
            order: 46,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "防止程序坞在多显示器之间意外移动"
            )
        )
    }
    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let storage: any PluginStorage
    private let monitor: any DockLockMonitoring
    private let localization: PluginLocalization
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool
    private var isEnabled: Bool
    private var isAccessibilityGranted: Bool
    private enum RuntimeError {
        case accessibilityRevoked
        case accessibilityRequired
        case startFailed
    }

    private var runtimeError: RuntimeError?

    private var lastErrorMessage: String? {
        guard let runtimeError else { return nil }
        switch runtimeError {
        case .accessibilityRevoked:
            return localization.string(
                "error.accessibilityRevoked",
                defaultValue: "辅助功能权限已关闭，Dock 锁定已暂停。"
            )
        case .accessibilityRequired:
            return localization.string(
                "error.accessibilityRequired",
                defaultValue: "Dock 锁定需要辅助功能权限。"
            )
        case .startFailed:
            return localization.string(
                "error.startFailed",
                defaultValue: "无法启动 Dock 锁定，请检查辅助功能权限。"
            )
        }
    }

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "dock-lock"),
        monitor: (any DockLockMonitoring)? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        accessibilityTrusted: @escaping @MainActor () -> Bool = DockLockPlugin.isAccessibilityTrusted,
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = DockLockPlugin.requestAccessibilityTrust
    ) {
        self.storage = context.storage
        self.monitor = monitor ?? DockLockMonitor()
        self.localization = localization
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.isEnabled = context.storage.object(forKey: StorageKey.isEnabled) == nil
            ? false
            : context.storage.bool(forKey: StorageKey.isEnabled)
        self.isAccessibilityGranted = accessibilityTrusted()
    }

    func activate(context: PluginRuntimeContext) {
        applyLockState(promptForPermission: false)
    }

    func deactivate(reason: PluginDeactivationReason) {
        monitor.stop()
    }

    func refresh() {}

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: isEnabled,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于在屏幕底部拦截鼠标移动，防止程序坞跳到其他显示器。"
                )
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "Dock"],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "Dock"],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: "enabled",
                        title: metadata.title,
                        kind: .boolean
                    ),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        guard actionKey.providerID == metadata.id,
              actionKey.actionID == ActionID.toggle || actionKey.actionID == ActionID.setEnabled
        else {
            return []
        }
        return [PermissionID.accessibility]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        [
            ActionCatalogEntry(
                reference: toggleActionReference,
                title: localization.string("action.toggle.title", defaultValue: "切换程序坞锁定"),
                subtitle: panelSubtitle,
                presentationState: isEnabled && isAccessibilityGranted && lastErrorMessage == nil
                    ? .active
                    : .inactive
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: localization.string("action.enable.title", defaultValue: "开启程序坞锁定")
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: localization.string("action.disable.title", defaultValue: "关闭程序坞锁定")
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.providerID == metadata.id else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        let enablesLock: Bool
        switch reference.key.actionID {
        case ActionID.toggle:
            enablesLock = !isEnabled
        case ActionID.setEnabled:
            guard case let .boolean(value)? = reference.parameters["enabled"] else {
                return .unavailable(PluginKitLocalization.actionInvalidParameters)
            }
            enablesLock = value
        default:
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        guard !enablesLock || isAccessibilityGranted else {
            return .unavailable(localization.string(
                "error.accessibilityRequired",
                defaultValue: "Dock 锁定需要辅助功能权限。"
            ))
        }
        return .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let enabled: Bool
        switch invocation.reference.key.actionID {
        case ActionID.toggle:
            enabled = !isEnabled
        case ActionID.setEnabled:
            guard case let .boolean(value)? = invocation.reference.parameters["enabled"] else {
                return ActionExecutionHandle {
                    .failed(message: PluginKitLocalization.actionInvalidParameters)
                }
            }
            enabled = value
        default:
            return ActionExecutionHandle {
                .failed(message: PluginKitLocalization.actionInvalidParameters)
            }
        }

        return ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            return self.setEnabled(enabled, promptForPermission: false)
                ? .succeeded()
                : .failed(message: self.lastErrorMessage ?? PluginKitLocalization.actionFailed)
        }
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: SettingsID.section,
                    title: localization.string("settings.section.title", defaultValue: "设置"),
                    systemImage: "lock.rectangle",
                    rows: [
                        PluginSettingsRow(
                            id: SettingsID.isEnabled,
                            title: localization.string(
                                "settings.enable.title",
                                defaultValue: "启用"
                            ),
                            description: localization.string(
                                "settings.enable.description",
                                defaultValue: "开启后防止程序坞在多显示器之间意外移动。"
                            ),
                            systemImage: "power",
                            error: lastErrorMessage,
                            control: .toggle(isOn: isEnabled)
                        ),
                    ]
                ),
            ]
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }
        _ = setEnabled(isEnabled, promptForPermission: isEnabled)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.accessibility else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
        return PluginPermissionState(
            isGranted: isAccessibilityGranted,
            footnote: isAccessibilityGranted
                ? nil
                : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "在系统设置的“隐私与安全性 > 辅助功能”中允许 MacTools。"
                )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.accessibility else {
            return
        }
        isAccessibilityGranted = requestAccessibilityTrust(true)
        applyLockState(promptForPermission: false)
        onStateChange?()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard case let .setBoolean(controlID, value) = action,
              controlID == SettingsID.isEnabled
        else {
            return
        }

        handleAction(.setSwitch(value))
    }
    func handleShortcutAction(id: String) {}

    func refreshAccessibilityPermission() {
        let wasGranted = isAccessibilityGranted
        isAccessibilityGranted = accessibilityTrusted()
        guard wasGranted != isAccessibilityGranted else {
            return
        }

        if isAccessibilityGranted {
            runtimeError = nil
            applyLockState(promptForPermission: false)
        } else {
            monitor.stop()
            runtimeError = .accessibilityRevoked
        }
        onStateChange?()
    }

    private var panelSubtitle: String {
        if isEnabled && !isAccessibilityGranted {
            return localization.string("panel.subtitle.needsPermission", defaultValue: "需要辅助功能授权")
        }
        return isEnabled
            ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
            : localization.string("panel.subtitle.disabled", defaultValue: "已关闭")
    }

    private var toggleActionReference: ActionReference {
        ActionReference(key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle))
    }

    private func actionReference(enabled: Bool) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
            parameters: try! ActionParameterSet(["enabled": .boolean(enabled)])
        )
    }

    @discardableResult
    private func setEnabled(_ enabled: Bool, promptForPermission: Bool) -> Bool {
        isEnabled = enabled
        storage.set(enabled, forKey: StorageKey.isEnabled)
        applyLockState(promptForPermission: promptForPermission)
        onStateChange?()
        return !enabled || (isAccessibilityGranted && lastErrorMessage == nil)
    }

    private func applyLockState(promptForPermission: Bool) {
        guard isEnabled else {
            monitor.stop()
            runtimeError = nil
            return
        }

        isAccessibilityGranted = accessibilityTrusted()
        if !isAccessibilityGranted, promptForPermission {
            isAccessibilityGranted = requestAccessibilityTrust(true)
        }
        guard isAccessibilityGranted else {
            monitor.stop()
            runtimeError = .accessibilityRequired
            requestPermissionGuidance?(PermissionID.accessibility)
            return
        }

        guard monitor.start() else {
            runtimeError = .startFailed
            return
        }
        runtimeError = nil
    }

    private static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private static func requestAccessibilityTrust(prompt: Bool) -> Bool {
        guard prompt else {
            return AXIsProcessTrusted()
        }
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
