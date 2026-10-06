import AppKit
@preconcurrency import IOKit.hid
import SwiftUI
import MacToolsPluginKit

public final class DeviceBatteryPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DeviceBatteryPluginProvider(context: context)
    }
}

@MainActor
private struct DeviceBatteryPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [DeviceBatteryPlugin(context: context, localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

enum DeviceBatteryInputMonitoringAuthorizationStatus {
    case granted
    case denied
    case unknown
}

@MainActor
final class DeviceBatteryPlugin: MacToolsPlugin, PluginApplicationActivityStateHandling {
    var panelItems: [PluginPanelItem] {
        return [
            .widget(id: "widget", initialPlacement: .dashboard,
                    descriptor: descriptor, state: widgetState,
                    content: { [weak self] context in
                        self?.makeView(context: context) ?? AnyView(EmptyView())
                    })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("widget") }
                    else { self?.panelItemDidBecomeHidden("widget") }
                },
        ]
    }

    private enum ControlID {
        static let openInputMonitoring = "open-input-monitoring"
    }

    private enum PermissionID {
        static let inputMonitoring = "input-monitoring"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "device-battery",
            title: localization.string("metadata.title", defaultValue: "设备电量"),
            iconName: "battery.75percent",
            iconTint: Color(nsColor: .systemGreen),
            order: 20,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "查看 Mac、Apple 移动设备、蓝牙外设和雷柏鼠标电量"
            )
        )
    }

    var descriptor: PluginPanelWidgetDescriptor {
        PluginPanelWidgetDescriptor(span: componentSpan)
    }

    private let viewModel: DeviceBatteryViewModel
    private let store: DeviceBatteryStore
    private let localization: PluginLocalization
    private let inputMonitoringAuthorizationStatus: () -> DeviceBatteryInputMonitoringAuthorizationStatus
    private let lowBatteryNotificationController: DeviceBatteryLowBatteryNotificationController

    private var componentSpan: PluginPanelWidgetSpan {
        let visibleItemCount = viewModel.snapshot.visibleItems.count
        return PluginPanelWidgetSpan(
            width: DeviceBatteryComponentLayout.width,
            height: DeviceBatteryComponentLayout.spanHeight(
                mode: store.layoutMode,
                visibleItemCount: visibleItemCount
            )
        )!
    }

    convenience init(
        context: PluginRuntimeContext,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.init(
            context: context,
            viewModel: DeviceBatteryViewModel(
                sampler: DeviceBatterySampler(localization: localization),
                vendorHIDMonitor: VendorHIDBatteryMonitor(localization: localization),
                powerSourceObserver: SystemDeviceBatteryPowerSourceObserver(),
                bluetoothConnectionObserver: SystemDeviceBatteryBluetoothConnectionObserver(),
                localization: localization
            ),
            localization: localization
        )
    }

    convenience init(
        context: PluginRuntimeContext,
        viewModel: DeviceBatteryViewModel,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.init(
            context: context,
            viewModel: viewModel,
            localization: localization,
            inputMonitoringAuthorizationStatus: Self.currentInputMonitoringAuthorizationStatus
        )
    }

    init(
        context: PluginRuntimeContext,
        viewModel: DeviceBatteryViewModel,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        inputMonitoringAuthorizationStatus: @escaping () -> DeviceBatteryInputMonitoringAuthorizationStatus,
        lowBatteryNotifier: any DeviceBatteryLowBatteryNotifying = DeviceBatteryUserNotificationCenterNotifier()
    ) {
        self.viewModel = viewModel
        self.store = DeviceBatteryStore(storage: context.storage)
        self.localization = localization
        self.inputMonitoringAuthorizationStatus = inputMonitoringAuthorizationStatus
        self.lowBatteryNotificationController = DeviceBatteryLowBatteryNotificationController(notifier: lowBatteryNotifier)
        viewModel.setLowBatteryMonitoringEnabled(store.lowBatteryNotificationEnabled)
        viewModel.onSnapshotChange = { [weak self] in
            self?.handleSnapshotChange()
        }
    }

    var onStateChange: (() -> Void)? {
        didSet {
            viewModel.onSnapshotChange = { [weak self] in
                self?.handleSnapshotChange()
            }
        }
    }
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(
            subtitle: viewModel.snapshot.subtitle(localization: localization),
            isActive: !viewModel.snapshot.visibleItems.isEmpty,
            isEnabled: true,
            isAvailable: true,
            errorMessage: viewModel.snapshot.errorMessage(localization: localization)
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.inputMonitoring,
                kind: .inputMonitoring,
                title: localization.string("permission.inputMonitoring.title", defaultValue: "输入监控授权"),
                description: localization.string(
                    "permission.inputMonitoring.description",
                    defaultValue: "用于读取已适配厂商 HID 鼠标的电量、充电状态、设备型号和名称。"
                )
            )
        ]
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: localization.string(
                "configuration.description",
                defaultValue: "选择组件面板布局和显示内容。"
            ),
            sections: [
                PluginSettingsSection(
                    id: "layout",
                    title: localization.string("settings.layout.title", defaultValue: "组件布局"),
                    systemImage: "rectangle.grid.2x2",
                    presentation: .edgeToEdge
                ) { [store, localization, weak self] _ in
                    DeviceBatterySettingsView(
                        store: store,
                        localization: localization,
                        onChange: {
                            self?.onStateChange?()
                        },
                        section: .layout
                    )
                },
                PluginSettingsSection(
                    id: "sources",
                    title: localization.string("settings.sources.title", defaultValue: "显示内容"),
                    systemImage: "bolt.horizontal.circle",
                    presentation: .edgeToEdge
                ) { [store, viewModel, localization, weak self] _ in
                    DeviceBatterySettingsView(
                        store: store,
                        localization: localization,
                        onChange: {
                            viewModel.updateSources(
                                includeInternalBattery: store.showInternalBattery,
                                includeBluetoothDevices: store.showBluetoothDevices,
                                includeAppleMobileDevices: store.showAppleMobileDevices,
                                includeVendorHIDDevices: store.showVendorHIDDevices
                            )
                            self?.onStateChange?()
                        },
                        section: .sources
                    )
                },
                PluginSettingsSection(
                    id: "notifications",
                    title: localization.string("settings.notification.title", defaultValue: "低电量通知"),
                    systemImage: "bell.badge",
                    presentation: .edgeToEdge
                ) { [store, viewModel, localization, lowBatteryNotificationController] _ in
                    DeviceBatterySettingsView(
                        store: store,
                        localization: localization,
                        onChange: {},
                        onNotificationSettingsChange: {
                            viewModel.setLowBatteryMonitoringEnabled(
                                store.lowBatteryNotificationEnabled
                            )
                            lowBatteryNotificationController.evaluate(
                                snapshot: viewModel.snapshot,
                                isEnabled: store.lowBatteryNotificationEnabled,
                                threshold: store.lowBatteryNotificationThreshold,
                                localization: localization
                            )
                        },
                        section: .notifications
                    )
                }
            ]
        )
    }

    func activate(context: PluginRuntimeContext) {
        viewModel.start(
            includeInternalBattery: store.showInternalBattery,
            includeBluetoothDevices: store.showBluetoothDevices,
            includeAppleMobileDevices: store.showAppleMobileDevices,
            includeVendorHIDDevices: store.showVendorHIDDevices
        )
        onStateChange?()
    }

    func deactivate(reason: PluginDeactivationReason) {
        viewModel.stop()
        onStateChange?()
    }

    func refresh() {
        viewModel.refresh(
            includeInternalBattery: store.showInternalBattery,
            includeBluetoothDevices: store.showBluetoothDevices,
            includeAppleMobileDevices: store.showAppleMobileDevices,
            includeVendorHIDDevices: store.showVendorHIDDevices
        )
        onStateChange?()
    }

    func panelItemDidBecomeVisible(_ surface: String) {
        guard surface == "widget" else {
            return
        }

        viewModel.setComponentPanelVisible(true)
    }

    func panelItemDidBecomeHidden(_ surface: String) {
        guard surface == "widget" else {
            return
        }

        viewModel.setComponentPanelVisible(false)
    }

    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        viewModel.setApplicationActivityState(state)
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
        AnyView(
            DeviceBatteryComponentView(
                viewModel: viewModel,
                store: store,
                localization: localization,
                openSettings: openInputMonitoringSettings
            )
        )
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        switch permissionID {
        case PermissionID.inputMonitoring:
            return inputMonitoringPermissionState
        default:
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.inputMonitoring else {
            return
        }

        openInputMonitoringSettings()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        if case let .invoke(controlID) = action,
           controlID == ControlID.openInputMonitoring {
            openInputMonitoringSettings()
        }
    }

    func handleShortcutAction(id: String) {}

    private func handleSnapshotChange() {
        lowBatteryNotificationController.evaluate(
            snapshot: viewModel.snapshot,
            isEnabled: store.lowBatteryNotificationEnabled,
            threshold: store.lowBatteryNotificationThreshold,
            localization: localization
        )
        onStateChange?()
    }

    private var inputMonitoringPermissionState: PluginPermissionState {
        let authorizationStatus = inputMonitoringAuthorizationStatus()
        if viewModel.snapshot.vendorHIDState == .permissionDenied,
           authorizationStatus != .granted {
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.inputMonitoring.openSettingsFootnote",
                    defaultValue: "前往系统设置 → 隐私与安全性 → 输入监控，允许 MacTools。"
                )
            )
        }

        switch authorizationStatus {
        case .granted:
            return PluginPermissionState(
                isGranted: true,
                footnote: inputMonitoringGrantedFootnote
            )
        case .denied, .unknown:
            return PluginPermissionState(
                isGranted: false,
                footnote: inputMonitoringUnauthorizedFootnote
            )
        }
    }

    private var inputMonitoringGrantedFootnote: String {
        switch viewModel.snapshot.vendorHIDState {
        case .connected:
            return localization.string(
                "permission.inputMonitoring.granted.connected",
                defaultValue: "已允许 MacTools 使用输入监控，并已读取到厂商 HID 鼠标信息。"
            )
        case .failed(let message):
            return localization.format(
                "permission.inputMonitoring.granted.failed",
                defaultValue: "已允许 MacTools 使用输入监控。最近读取厂商 HID 鼠标失败：%@",
                message
            )
        case .idle, .scanning, .waitingForReport, .noDevice, .permissionDenied:
            return localization.string(
                "permission.inputMonitoring.granted.default",
                defaultValue: "已允许 MacTools 使用输入监控，可读取已适配厂商 HID 鼠标信息。"
            )
        }
    }

    private var inputMonitoringUnauthorizedFootnote: String {
        switch viewModel.snapshot.vendorHIDState {
        case .permissionDenied:
            return localization.string(
                "permission.inputMonitoring.openSettingsFootnote",
                defaultValue: "前往系统设置 → 隐私与安全性 → 输入监控，允许 MacTools。"
            )
        case .failed(let message):
            return localization.format(
                "permission.inputMonitoring.unauthorized.failed",
                defaultValue: "授权后可读取厂商 HID 鼠标信息。最近读取失败：%@",
                message
            )
        case .idle, .scanning, .waitingForReport, .connected, .noDevice:
            return localization.string(
                "permission.inputMonitoring.unauthorized.default",
                defaultValue: "授权后可读取厂商 HID 鼠标信息；未授权不影响 Mac 内置电池、系统蓝牙设备和 Apple 外设电量。"
            )
        }
    }

    private static func currentInputMonitoringAuthorizationStatus() -> DeviceBatteryInputMonitoringAuthorizationStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        case kIOHIDAccessTypeUnknown:
            return .unknown
        default:
            return .unknown
        }
    }

    private func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
