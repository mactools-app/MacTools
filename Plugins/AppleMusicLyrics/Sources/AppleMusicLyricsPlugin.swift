import AppKit
import SwiftUI
import MacToolsPluginKit

public final class AppleMusicLyricsPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AppleMusicLyricsPluginProvider(context: context)
    }
}

@MainActor
private struct AppleMusicLyricsPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            AppleMusicLyricsPlugin(
                storage: context.storage,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class AppleMusicLyricsPlugin: MacToolsPlugin {
    private enum SettingsID {
        static let section = "apple-music-lyrics"
        static let enabled = "enabled"
        static let fontSize = "font-size"
        static let backgroundOpacity = "background-opacity"
        static let textOpacity = "text-opacity"
        static let cornerRadius = "corner-radius"
        static let showsNextLine = "shows-next-line"
        static let textColor = "text-color"
        static let allowsDragging = "allows-dragging"
        static let karaokeEnabled = "karaoke-enabled"
        static let reset = "reset"
        static let status = "status"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "apple-music-lyrics",
            title: localization.string("metadata.title", defaultValue: "Apple Music 歌词"),
            iconName: "music.note.list",
            iconTint: Color(nsColor: .systemPink),
            order: 47,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "在屏幕右上角显示毛玻璃效果的 Apple Music 桌面歌词"
            )
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var panelItems: [PluginPanelItem] {
        [
            .row(
                id: "control",
                initialPlacement: .featurePanel,
                descriptor: rowDescriptor,
                state: rowState,
                action: { [weak self] action in self?.handleRowAction(action) }
            ),
        ]
    }

    var settingsPage: PluginSettingsPage? {
        let snapshot = controller.snapshot
        var rows: [PluginSettingsRow] = [
            PluginSettingsRow(
                id: SettingsID.enabled,
                title: localization.string(
                    "settings.enabled.title",
                    defaultValue: "启用桌面歌词"
                ),
                description: localization.string(
                    "settings.enabled.description",
                    defaultValue: "Apple Music 播放且有歌词时，在屏幕右上角显示毛玻璃效果的桌面歌词。"
                ),
                systemImage: "music.note.list",
                control: .toggle(isOn: snapshot.isEnabled)
            ),
            PluginSettingsRow(
                id: SettingsID.fontSize,
                title: localization.string(
                    "settings.fontSize.title",
                    defaultValue: "歌词字号"
                ),
                description: localization.string(
                    "settings.fontSize.description",
                    defaultValue: "当前歌词行的字体大小。"
                ),
                systemImage: "textformat.size",
                isEnabled: snapshot.isEnabled,
                control: .slider(
                    value: controller.fontSize,
                    range: 14...48,
                    step: 1,
                    valueFormat: PluginSettingsSliderValueFormat(suffix: " pt")
                )
            ),
            PluginSettingsRow(
                id: SettingsID.backgroundOpacity,
                title: localization.string(
                    "settings.backgroundOpacity.title",
                    defaultValue: "背景透明度"
                ),
                description: localization.string(
                    "settings.backgroundOpacity.description",
                    defaultValue: "毛玻璃背景的不透明度，越低越通透。"
                ),
                systemImage: "circle.lefthalf.filled",
                isEnabled: snapshot.isEnabled,
                control: .slider(
                    value: controller.backgroundOpacity,
                    range: 0.1...1.0,
                    step: 0.05,
                    valueFormat: PluginSettingsSliderValueFormat(fractionDigits: 2)
                )
            ),
            PluginSettingsRow(
                id: SettingsID.textOpacity,
                title: localization.string(
                    "settings.textOpacity.title",
                    defaultValue: "字体透明度"
                ),
                description: localization.string(
                    "settings.textOpacity.description",
                    defaultValue: "歌词文字的不透明度，可独立于背景调节。"
                ),
                systemImage: "textformat",
                isEnabled: snapshot.isEnabled,
                control: .slider(
                    value: controller.textOpacity,
                    range: 0.1...1.0,
                    step: 0.05,
                    valueFormat: PluginSettingsSliderValueFormat(fractionDigits: 2)
                )
            ),
            PluginSettingsRow(
                id: SettingsID.cornerRadius,
                title: localization.string(
                    "settings.cornerRadius.title",
                    defaultValue: "圆角半径"
                ),
                description: localization.string(
                    "settings.cornerRadius.description",
                    defaultValue: "歌词窗口的圆角大小。"
                ),
                systemImage: "rectangle.roundedtopright",
                isEnabled: snapshot.isEnabled,
                control: .slider(
                    value: controller.cornerRadius,
                    range: 0...28,
                    step: 1,
                    valueFormat: PluginSettingsSliderValueFormat(suffix: " pt")
                )
            ),
            PluginSettingsRow(
                id: SettingsID.showsNextLine,
                title: localization.string(
                    "settings.showsNextLine.title",
                    defaultValue: "显示下一句歌词"
                ),
                description: localization.string(
                    "settings.showsNextLine.description",
                    defaultValue: "在当前歌词下方同时显示下一句，便于提前准备。"
                ),
                systemImage: "text.line.last.and.arrowtriangle.forward",
                isEnabled: snapshot.isEnabled,
                control: .toggle(isOn: controller.showsNextLine)
            ),
            PluginSettingsRow(
                id: SettingsID.textColor,
                title: localization.string(
                    "settings.textColor.title",
                    defaultValue: "文字颜色"
                ),
                description: localization.string(
                    "settings.textColor.description",
                    defaultValue: "歌词文字的颜色。"
                ),
                systemImage: "textformat",
                isEnabled: snapshot.isEnabled,
                control: .picker(
                    selectionID: controller.textColor.rawValue,
                    options: [
                        PluginSettingsOption(
                            id: LyricsTextColorOption.system.rawValue,
                            title: localization.string(
                                "settings.textColor.system",
                                defaultValue: "跟随系统"
                            )
                        ),
                        PluginSettingsOption(
                            id: LyricsTextColorOption.white.rawValue,
                            title: localization.string(
                                "settings.textColor.white",
                                defaultValue: "白色"
                            )
                        ),
                        PluginSettingsOption(
                            id: LyricsTextColorOption.black.rawValue,
                            title: localization.string(
                                "settings.textColor.black",
                                defaultValue: "黑色"
                            )
                        ),
                    ],
                    style: .segmented
                )
            ),
            PluginSettingsRow(
                id: SettingsID.allowsDragging,
                title: localization.string(
                    "settings.allowsDragging.title",
                    defaultValue: "允许拖动位置"
                ),
                description: localization.string(
                    "settings.allowsDragging.description",
                    defaultValue: "打开后可在屏幕上自由拖动歌词窗口的位置，并记住该位置。"
                ),
                systemImage: "hand.draw",
                isEnabled: snapshot.isEnabled,
                control: .toggle(isOn: controller.allowsDragging)
            ),
            PluginSettingsRow(
                id: SettingsID.karaokeEnabled,
                title: localization.string(
                    "settings.karaokeEnabled.title",
                    defaultValue: "逐字渲染"
                ),
                description: localization.string(
                    "settings.karaokeEnabled.description",
                    defaultValue: "逐字高亮已唱和未唱的部分。歌词的时间数据并不完全精确，逐字效果可能与实际演唱存在偏差。"
                ),
                systemImage: "text.word.spacing",
                isEnabled: snapshot.isEnabled,
                control: .toggle(isOn: controller.karaokeEnabled)
            ),
            PluginSettingsRow(
                id: SettingsID.reset,
                title: localization.string(
                    "settings.reset.title",
                    defaultValue: "恢复默认设置"
                ),
                description: localization.string(
                    "settings.reset.description",
                    defaultValue: "将字体、背景透明度和显示选项恢复为初始状态。"
                ),
                systemImage: "arrow.counterclockwise",
                control: .action(
                    title: localization.string(
                        "settings.reset.action",
                        defaultValue: "恢复默认"
                    ),
                    role: .normal
                )
            ),
        ]

        if snapshot.isEnabled {
            rows.append(statusRow(snapshot: snapshot))
        }

        return .form(
            description: localization.string(
                "settings.description",
                defaultValue: "在 Apple Music 播放且有歌词时，屏幕右上角会显示毛玻璃效果的桌面歌词。"
            ),
            sections: [
                PluginSettingsSection(
                    id: SettingsID.section,
                    title: localization.string(
                        "settings.section",
                        defaultValue: "歌词显示"
                    ),
                    systemImage: "music.note.list",
                    rows: rows
                ),
            ]
        )
    }

    var onStateChange: (() -> Void)? {
        get { controller.onStateChange }
        set { controller.onStateChange = newValue }
    }

    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let controller: any AppleMusicLyricsControlling
    private let localization: PluginLocalization

    init(
        storage: PluginStorage? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        controller: (any AppleMusicLyricsControlling)? = nil
    ) {
        self.localization = localization
        self.controller = controller ?? AppleMusicLyricsController(
            storage: storage ?? UserDefaultsPluginStorage(pluginID: "apple-music-lyrics"),
            localization: localization
        )
    }

    var rowState: PluginPanelRowState {
        let snapshot = controller.snapshot
        let subtitle: String

        if !snapshot.isEnabled {
            subtitle = localization.string("panel.subtitle.disabled", defaultValue: "已关闭")
        } else if !snapshot.isMusicRunning {
            subtitle = localization.string(
                "panel.subtitle.noMusic",
                defaultValue: "等待 Apple Music"
            )
        } else if snapshot.isTrackPlaying, snapshot.hasLyrics {
            subtitle = snapshot.currentLine.isEmpty
                ? snapshot.currentTrackTitle
                : snapshot.currentLine
        } else if snapshot.isTrackPlaying {
            subtitle = localization.string(
                "panel.subtitle.noLyrics",
                defaultValue: "当前歌曲无歌词"
            )
        } else {
            subtitle = localization.string(
                "panel.subtitle.paused",
                defaultValue: "已开启，等待播放"
            )
        }

        return PluginPanelRowState(
            subtitle: subtitle,
            isOn: snapshot.isEnabled,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: snapshot.errorMessage
        )
    }

    func activate(context _: PluginRuntimeContext) {
        controller.activate()
    }

    func deactivate(reason: PluginDeactivationReason) {
        controller.deactivate()
    }

    func refresh() {
        controller.refresh()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setBoolean(controlID, value) where controlID == SettingsID.enabled:
            controller.setEnabled(value)
        case let .setBoolean(controlID, value) where controlID == SettingsID.showsNextLine:
            controller.setShowsNextLine(value)
        case let .setBoolean(controlID, value) where controlID == SettingsID.allowsDragging:
            controller.setAllowsDragging(value)
        case let .setBoolean(controlID, value) where controlID == SettingsID.karaokeEnabled:
            controller.setKaraokeEnabled(value)
        case let .invoke(controlID) where controlID == SettingsID.reset:
            controller.resetToDefaults()
        case let .setSelection(controlID, optionID) where controlID == SettingsID.textColor:
            if let option = LyricsTextColorOption(rawValue: optionID) {
                controller.setTextColor(option)
            }
        case let .setNumber(controlID, value, phase) where phase == .committed:
            switch controlID {
            case SettingsID.fontSize:
                controller.setFontSize(value)
            case SettingsID.backgroundOpacity:
                controller.setBackgroundOpacity(value)
            case SettingsID.textOpacity:
                controller.setTextOpacity(value)
            case SettingsID.cornerRadius:
                controller.setCornerRadius(value)
            default:
                break
            }
        default:
            break
        }
    }

    private func statusRow(snapshot: AppleMusicLyricsSnapshot) -> PluginSettingsRow {
        let statusText: String
        let statusImage: String

        if snapshot.isTrackPlaying, snapshot.hasLyrics {
            statusText = localization.string(
                "settings.status.playing",
                defaultValue: "正在显示歌词"
            )
            statusImage = "play.circle.fill"
        } else if snapshot.isTrackPlaying {
            statusText = localization.string(
                "settings.status.noLyrics",
                defaultValue: "当前歌曲没有可用歌词"
            )
            statusImage = "music.note"
        } else {
            statusText = localization.string(
                "settings.status.idle",
                defaultValue: "等待 Apple Music 播放"
            )
            statusImage = "pause.circle"
        }

        return PluginSettingsRow(
            id: SettingsID.status,
            title: localization.string(
                "settings.status.title",
                defaultValue: "当前状态"
            ),
            description: snapshot.isTrackPlaying
                ? "\(snapshot.currentTrackTitle) — \(snapshot.currentTrackArtist)"
                : nil,
            systemImage: statusImage,
            control: .status(
                text: statusText,
                systemImage: statusImage,
                tone: .positive,
                actionTitle: nil
            )
        )
    }

    private func handleRowAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else { return }
        controller.setEnabled(isEnabled)
    }
}
