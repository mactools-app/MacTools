import AppKit
import Foundation
import MacToolsPluginKit
import SwiftUI

public final class SystemDataPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        SystemDataPluginProvider(context: context)
    }
}

@MainActor
private struct SystemDataPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let controller = SystemDataController(scanner: SystemDataScanner())
        return [SystemDataPlugin(controller: controller, localization: localization)]
    }
}

@MainActor
public final class SystemDataPlugin: MacToolsPlugin, PluginSettingsPresenting {
    public let metadata: PluginMetadata

    let controller: SystemDataController
    let localization: PluginLocalization
    let preferences = SystemDataDisplayPreferences()

    public var onStateChange: (() -> Void)?
    public var requestPermissionGuidance: ((String) -> Void)?
    public var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    public var requestSettingsPresentation: (() -> Void)?

    private var isExpanded = false

    private enum ControlID {
        static let rescan = "system-data-rescan"
        static let openDetails = "system-data-open-details"
    }

    private enum ItemID {
        static let row = "summary"
        static let widget = "overview"
    }

    init(controller: SystemDataController, localization: PluginLocalization) {
        self.controller = controller
        self.localization = localization
        self.metadata = PluginMetadata(
            id: "system-data",
            title: localization.string("metadata.title", defaultValue: "系统数据"),
            iconName: "externaldrive",
            iconTint: Color(nsColor: .systemOrange),
            order: 56,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "分类汇总 macOS 系统数据的真实占用，在 Finder 中快速定位"
            )
        )
        controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    // MARK: - Panel

    public var panelItems: [PluginPanelItem] {
        [
            .row(
                id: ItemID.row,
                initialPlacement: .featurePanel,
                descriptor: rowDescriptor,
                state: rowState,
                action: { [weak self] in self?.handleAction($0) }
            ),
            .widget(
                id: ItemID.widget,
                initialPlacement: .dashboard,
                descriptor: widgetDescriptor,
                state: widgetState,
                detail: { [weak self] detailID, dismiss in
                    self?.makeWidgetDetail(detailID: detailID, dismiss: dismiss)
                },
                content: { [weak self] context in
                    guard let self else { return AnyView(EmptyView()) }
                    return AnyView(
                        SystemDataWidgetView(
                            controller: controller,
                            localization: localization,
                            pluginTitle: metadata.title,
                            presentDetail: { context.presentDetail(ItemID.widget) }
                        )
                    )
                }
            ),
        ]
    }

    private let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    private var widgetDescriptor: PluginPanelWidgetDescriptor {
        // The host grid allocates `height * 8pt`; size the span from the card's
        // intrinsic content height so the card is neither clipped nor padded.
        PluginPanelWidgetDescriptor(
            span: PluginPanelWidgetSpan(
                width: 4,
                height: PluginPanelWidgetLayoutMetrics.default.heightSpan(
                    fittingContentHeight: SystemDataWidgetLayout.cardContentHeight
                )
            )!
        )
    }

    private var rowState: PluginPanelRowState {
        var state = PluginPanelRowState(
            subtitle: summarySubtitle(),
            isOn: controller.state.isScanning,
            isEnabled: true,
            isAvailable: true,
            detail: isExpanded ? makeRowDetail() : nil,
            errorMessage: controller.state.failureMessage
        )
        if controller.state.isScanning {
            state.indicator = PluginPanelRowIndicator(
                text: localization.string("panel.indicator.scanning", defaultValue: "扫描中"),
                systemImage: "arrow.triangle.2.circlepath"
            )
        }
        return state
    }

    private var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(
            subtitle: summarySubtitle(),
            isActive: controller.state.isScanning,
            isEnabled: true,
            isAvailable: true,
            errorMessage: controller.state.failureMessage
        )
    }

    private func summarySubtitle() -> String {
        switch controller.state {
        case .idle:
            return localization.string("panel.subtitle.idle", defaultValue: "尚未扫描")
        case let .scanning(progress):
            return localization.format(
                "panel.subtitle.progress",
                defaultValue: "%d/%d 项",
                progress.completedItems,
                progress.totalItems
            )
        case .cancelled:
            return localization.string("panel.subtitle.cancelled", defaultValue: "扫描已取消")
        case .failed:
            return localization.string("panel.subtitle.failed", defaultValue: "扫描失败")
        case .completed:
            guard let summary = controller.summary else {
                return localization.string("panel.subtitle.idle", defaultValue: "尚未扫描")
            }
            let total = SystemDataFormatting.bytes(summary.totalBytes)
            let free = summary.availableBytes.map { SystemDataFormatting.bytes($0) }
                ?? localization.string("summary.unavailable", defaultValue: "—")
            return localization.format(
                "panel.subtitle.summary",
                defaultValue: "总计 %@ · 可用 %@",
                total,
                free
            )
        }
    }

    private func makeRowDetail() -> PluginPanelDetail {
        let rescanControl = PluginPanelControl(
            id: ControlID.rescan,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.rescan", defaultValue: "重新扫描"),
            actionIconSystemName: "magnifyingglass",
            isEnabled: !controller.state.isScanning
        )
        let openDetailsControl = PluginPanelControl(
            id: ControlID.openDetails,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string(
                "panel.action.openDetails",
                defaultValue: "打开完整清单"
            ),
            actionIconSystemName: "arrow.up.right.square",
            actionBehavior: .dismissBeforeHandling,
            showsLeadingDivider: true,
            isEnabled: true
        )
        return PluginPanelDetail(controls: [rescanControl, openDetailsControl])
    }

    private func makeWidgetDetail(
        detailID: String,
        dismiss: @escaping () -> Void
    ) -> PluginPanelDetailContent? {
        guard detailID == ItemID.widget else { return nil }
        return PluginPanelDetailContent(
            id: ItemID.widget,
            title: localization.string("widget.detail.title", defaultValue: "分类占用"),
            content: AnyView(
                SystemDataWidgetDetailView(
                    controller: controller,
                    preferences: preferences,
                    localization: localization,
                    openSettings: { [weak self] in
                        dismiss()
                        self?.requestSettingsPresentation?()
                    }
                )
            )
        )
    }

    private func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            isExpanded = expanded
            onStateChange?()
        case let .invokeAction(controlID):
            switch controlID {
            case ControlID.rescan:
                controller.scan()
            case ControlID.openDetails:
                requestSettingsPresentation?()
            default:
                break
            }
        default:
            break
        }
    }

    // MARK: - Settings

    public var settingsPage: PluginSettingsPage? {
        .workspace(description: metadata.defaultDescription, scrolling: .host) { [weak self] _ in
            if let self {
                SystemDataWorkspaceView(
                    controller: controller,
                    preferences: preferences,
                    localization: localization
                )
            }
        }
    }

    // MARK: - Permissions

    public var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: "full-disk-access",
                // PluginKit has no Full Disk Access case; the host recognizes
                // this stable ID and provides the shared FDA presentation.
                kind: .automation,
                title: localization.string(
                    "permission.fullDiskAccess.title",
                    defaultValue: "完全磁盘访问"
                ),
                description: localization.string(
                    "permission.fullDiskAccess.description",
                    defaultValue: "统计受保护的应用容器（如聊天记录）需要此权限；未授权时相关条目显示为无法读取。"
                )
            ),
        ]
    }

    public func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == "full-disk-access" else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
        let isGranted = SystemDataFullDiskAccess.hasFullDiskAccess()
        return PluginPermissionState(
            isGranted: isGranted,
            footnote: isGranted ? nil : localization.string(
                "permission.fullDiskAccess.footnote",
                defaultValue: "授权后重新扫描，受保护的位置才会计入统计。"
            )
        )
    }

    public func handlePermissionAction(id: String) {
        guard id == "full-disk-access" else { return }
        SystemDataFullDiskAccess.openSettings()
    }

    // MARK: - Lifecycle

    public func activate(context: PluginRuntimeContext) {
        preferences.attach(storage: context.storage)
        controller.scan()
    }

    public func deactivate(reason: PluginDeactivationReason) {
        controller.cancel()
    }
}
