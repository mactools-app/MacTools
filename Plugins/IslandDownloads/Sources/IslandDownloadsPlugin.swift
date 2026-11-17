import AppKit
@preconcurrency import ApplicationServices
import Combine
import MacToolsPluginKit
import SwiftUI

public final class IslandDownloadsPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        IslandDownloadsPluginProvider(context: context)
    }
}

@MainActor
private struct IslandDownloadsPluginProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] { [IslandDownloadsPlugin(context: context)] }
}

/// Preference keys for the downloads folder, under the plugin's own namespace.
enum DefaultsKey {
    private static let prefix = "plugin.island-downloads."
    static let folderBookmark = prefix + "folderBookmark"
    static let folderForgotten = prefix + "folderForgotten"
}

/// Vorssaint's Downloads, ported to the macOS island: progress beside the island while a file
/// downloads, a Downloads page in the island's hover panel, and a "Download complete" notice.
///
/// Watching is event-driven: the folder's file events and the downloads that apps publish through
/// `Progress`. Nothing polls; the island activity measures the menu bar only while a download runs.
@MainActor
final class IslandDownloadsPlugin: MacToolsPlugin, PluginSettingsPresenting {
    private enum ID {
        static let widget = "downloads"
        static let liveProgress = "liveProgress"
        static let notify = "notify"
        static let chooseFolder = "chooseFolder"
        static let forgetFolder = "forgetFolder"
        static let accessibility = "accessibility"
    }

    let localization: PluginLocalization
    private let storage: any PluginStorage
    private let service = NotchDownloadService.shared
    private let island = DownloadIslandController()
    private var active = false
    private var observation: AnyCancellable?
    private var trusted = AXIsProcessTrusted()

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    init(context: PluginRuntimeContext) {
        localization = PluginLocalization(bundle: context.resourceBundle)
        storage = context.storage
    }

    private var liveProgress: Bool { storage.object(forKey: ID.liveProgress) as? Bool ?? true }
    private var notify: Bool { storage.object(forKey: ID.notify) as? Bool ?? true }

    var metadata: PluginMetadata {
        PluginMetadata(id: "island-downloads",
                       title: localization.string("metadata.title", defaultValue: "灵动岛下载"),
                       iconName: "arrow.down.circle.fill", iconTint: .blue, order: 43,
                       defaultDescription: localization.string(
                           "metadata.description", defaultValue: "在灵动岛旁显示下载进度，并在下载完成时通知。"))
    }

    var panelItems: [PluginPanelItem] {
        [
            .widget(id: ID.widget, initialPlacement: .dashboard,
                    descriptor: PluginPanelWidgetDescriptor(span: PluginPanelWidgetSpan(
                        width: PluginPanelWidgetSpan.maximumWidth,
                        height: PluginPanelWidgetLayoutMetrics.default.heightSpan(
                            fittingContentHeight: NotchDownloadsLayout.contentHeight))!),
                    state: PluginPanelWidgetState(subtitle: metadata.defaultDescription,
                                                  isActive: service.items.contains { $0.active && !$0.completed },
                                                  isEnabled: true, isAvailable: true, errorMessage: nil),
                    content: { _ in
                        AnyView(GeometryReader { proxy in NotchDownloadsView(size: proxy.size) })
                    }),
        ]
    }

    var settingsPage: PluginSettingsPage? {
        let text = NotchDownloadStrings.current
        let folder = service.folderUnavailable ? text.folderUnavailable : (service.folderName ?? text.downloadsHint)
        var folderRows = [
            PluginSettingsRow(id: ID.chooseFolder, title: text.downloadsTitle, description: folder,
                              systemImage: "folder", control: .action(title: text.chooseFolder, role: .normal)),
        ]
        if service.folderName != nil || service.folderUnavailable {
            folderRows.append(PluginSettingsRow(id: ID.forgetFolder, title: text.clearFolder, description: nil,
                                                systemImage: "folder.badge.minus",
                                                control: .action(title: text.clearFolder, role: .normal)))
        }
        return .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(id: "folder", title: text.downloadsTitle, systemImage: "arrow.down.circle",
                                  rows: folderRows),
            PluginSettingsSection(id: "island", title: localization.string("settings.island", defaultValue: "灵动岛"),
                                  systemImage: "capsule.fill", rows: [
                PluginSettingsRow(id: ID.liveProgress,
                                  title: localization.string("settings.liveProgress", defaultValue: "在灵动岛旁显示进度"),
                                  description: localization.string("settings.liveProgress.description",
                                                                   defaultValue: "下载时在灵动岛两侧显示箭头和百分比，不会遮挡菜单或状态栏图标。"),
                                  systemImage: "capsule.fill", control: .toggle(isOn: liveProgress)),
                PluginSettingsRow(id: ID.notify,
                                  title: localization.string("settings.notify", defaultValue: "下载完成时通知"),
                                  description: localization.string("settings.notify.description",
                                                                   defaultValue: "显示为灵动岛卡片，并保留在通知中心。点按可在访达中显示文件。"),
                                  systemImage: "bell.badge", control: .toggle(isOn: notify)),
            ]),
        ])
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [PluginPermissionRequirement(id: ID.accessibility, kind: .accessibility,
                                     title: localization.string("permission.title", defaultValue: "辅助功能授权"),
                                     description: localization.string("permission.description",
                                                                      defaultValue: "用于测量菜单栏的空余位置，让进度不遮挡菜单和状态栏图标。"))]
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: trusted, footnote: nil)
    }

    func handlePermissionAction(id: String) {
        guard id == ID.accessibility else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setBoolean(id, value) where id == ID.liveProgress:
            storage.set(value, forKey: ID.liveProgress)
            island.enabled = value
            if value, !trusted { requestPermissionGuidance?(ID.accessibility) }
        case let .setBoolean(id, value) where id == ID.notify:
            storage.set(value, forKey: ID.notify)
            if value { DownloadNotifier.requestAuthorizationIfNeeded() }
        case .invoke(controlID: ID.chooseFolder):
            service.chooseFolder()
        case .invoke(controlID: ID.forgetFolder):
            service.forgetFolder()
        default:
            return
        }
        onStateChange?()
    }

    func activate(context: PluginRuntimeContext) {
        active = true
        trusted = AXIsProcessTrusted()
        service.onArrival = { [weak self] item in
            guard let self, self.active, self.notify else { return }
            DownloadNotifier.post(item)
        }
        // The widget's state follows the folder and whether something downloads.
        observation = service.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.onStateChange?() }
        service.enabled = true
        service.syncWithPreferences()
        island.enabled = liveProgress
        island.start()
        if notify { DownloadNotifier.requestAuthorizationIfNeeded() }
    }

    func deactivate(reason: PluginDeactivationReason) {
        active = false
        observation = nil
        island.stop()
        service.onArrival = nil
        service.enabled = false
        service.stop()
    }

    func refresh() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        trusted = now
        island.enabled = liveProgress
        onStateChange?()
    }
}
