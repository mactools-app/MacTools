import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class TrackpadScalePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        TrackpadScalePluginProvider(context: context)
    }
}

@MainActor
private struct TrackpadScalePluginProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] { [TrackpadScalePlugin(context: context)] }
}

@MainActor
final class TrackpadScalePlugin: MacToolsPlugin, PluginSettingsPresenting,
    TrackpadInputServiceConsuming, PluginApplicationActivityStateHandling, PluginRuntimeLocalizationRefreshing {
    var metadata: PluginMetadata {
        PluginMetadata(
            id: "trackpad-scale",
            title: localization.string("metadata.title", defaultValue: "触控板称重"),
            iconName: "scalemass", iconTint: .accentColor, order: 215,
            defaultDescription: localization.string("metadata.description", defaultValue: "用内置 Force Touch 触控板估算小物件重量（实验性）")
        )
    }
    let model: TrackpadScaleModel
    private let localization: PluginLocalization
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    init(context: PluginRuntimeContext) {
        localization = PluginLocalization(bundle: context.resourceBundle)
        model = TrackpadScaleModel(storage: context.storage)
    }

    func refreshLocalization() {
        model.objectWillChange.send()
        onStateChange?()
    }

    var panelItems: [PluginPanelItem] {
        [.row(id: "open-scale", initialPlacement: .featurePanel,
              descriptor: PluginPanelRowDescriptor(controlStyle: .button,
                  menuActionBehavior: .dismissBeforeHandling,
                  buttonTitleProvider: { [localization] in localization.string("open", defaultValue: "打开") }),
              state: PluginPanelRowState(subtitle: metadata.defaultDescription, isOn: false,
                  isEnabled: true, isAvailable: true, detail: nil, errorMessage: nil),
              action: { [weak self] _ in self?.requestSettingsPresentation?() })]
    }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(id: "measurement", title: localization.string("measurement", defaultValue: "称重"),
                                 systemImage: "scalemass") { [self] _ in
                TrackpadScaleView(model: model, localization: self.localization)
            },
            PluginSettingsSection(id: "calibration",
                                  footer: localization.string("safeUse", defaultValue: "仅轻放小物件，勿用尖锐或重物。不可用于关键测量。")) { [self] _ in
                TrackpadScaleCalibrationView(model: model, localization: self.localization)
            }
        ]).onVisibilityChange { [weak self] visible in
            if !visible {
                self?.model.stop()
                self?.model.setCalibrationExpanded(false)
            }
        }
    }

    func setTrackpadInputService(_ service: any TrackpadInputService) { model.setService(service) }
    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        if state != .interactive, model.isRunning { model.stop(interrupted: true) }
    }
    func deactivate(reason: PluginDeactivationReason) { model.stop() }
}
