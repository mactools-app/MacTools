import SwiftUI
import MacToolsPluginKit

enum SettingsStyle {
    static var windowBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var contentBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var recessedControlBackground: Color {
        PluginSettingsTheme.Palette.recessedControlBackground
    }

    static var fieldBackground: Color {
        PluginSettingsTheme.Palette.fieldBackground
    }

    static var keycapBackground: Color {
        PluginSettingsTheme.Palette.keycapBackground
    }

    static var separator: Color {
        PluginSettingsTheme.Palette.separator
    }

    static var cardBorder: Color {
        PluginSettingsTheme.Palette.cardBorder
    }

    static var activeControlBackground: Color {
        PluginSettingsTheme.Palette.activeControlBackground
    }

    static var recordingBackground: Color {
        PluginSettingsTheme.Palette.recordingBackground
    }
}

/// Gives custom settings links and selection controls the same pointer feedback.
extension View {
    func settingsPointingHandCursor() -> some View {
        modifier(SettingsPointingHandCursor())
    }
}

private struct SettingsPointingHandCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovered = isEnabled
                    if isEnabled { NSCursor.pointingHand.set() }
                case .ended:
                    if isHovered { NSCursor.arrow.set() }
                    isHovered = false
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled, isHovered {
                    NSCursor.arrow.set()
                    isHovered = false
                }
            }
            .onDisappear {
                if isHovered { NSCursor.arrow.set() }
            }
    }
}

/// The complete label is one keyboard-operable target with checkbox semantics.
struct SettingsSelectionToggleStyle: ToggleStyle {
    var card = false
    var cardPadding: CGFloat = PluginSettingsTheme.Spacing.rowHorizontal

    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) {
            Group {
                if card {
                    configuration.label
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .overlay(alignment: .topTrailing) { indicator(isSelected: configuration.isOn) }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                        indicator(isSelected: configuration.isOn)
                        configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(card ? cardPadding : 0)
            .frame(maxWidth: .infinity, maxHeight: card ? .infinity : nil, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .toggleStyle(.button)
        .buttonStyle(SettingsSelectionButtonStyle(isSelected: configuration.isOn, card: card))
    }

    private func indicator(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .font(PluginSettingsTheme.Typography.rowTitle)
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .accessibilityHidden(true)
    }
}

private struct SettingsSelectionButtonStyle: ButtonStyle {
    let isSelected: Bool
    let card: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if card {
                    Color.clear.pluginSettingsCardBackground(.standard)
                        .overlay {
                            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card)
                                .fill(isSelected ? SettingsStyle.activeControlBackground
                                    : isEnabled && (isHovered || configuration.isPressed)
                                        ? PluginSettingsTheme.Palette.sidebarHoverBackground : .clear)
                        }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card)
                    .strokeBorder(card && isSelected ? Color.accentColor
                        : card || isEnabled && (isHovered || configuration.isPressed) ? SettingsStyle.cardBorder : .clear,
                        lineWidth: contrast == .increased || isSelected
                            ? PluginSettingsTheme.Stroke.standard : PluginSettingsTheme.Stroke.hairline)
                    .allowsHitTesting(false)
            }
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isHovered)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isSelected)
            .onHover { isHovered = $0 }
            .settingsPointingHandCursor()
    }
}
