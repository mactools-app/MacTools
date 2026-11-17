// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Vorssaint (github.com/vorssaint/vorssaint-utils), GPL-3.0-or-later.
// Copyright (C) 2026 Vorssaint; MacTools adaptation (C) 2026 MacTools contributors.

import AppKit
import MacToolsPluginKit
import SwiftUI

extension Color {
    /// The island draws its page in white on black. In the MacTools panel the
    /// same shares of one ink follow the panel's appearance: white in dark
    /// mode, black in light mode, so every fill and label keeps its weight.
    static let agentInk = Color(nsColor: NSColor(name: "IslandDownloadsInk") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    })
}

extension ShapeStyle where Self == Color {
    static var agentInk: Color { Color.agentInk }
}

/// A card's surface: the fill the panel gives its own cards, with the
/// outline Increase Contrast asks for.
struct NotchAgentCardSurface: ViewModifier {
    @Environment(\.pluginComponentTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PluginPanelWidgetLayoutMetrics.cardCornerRadius, style: .continuous)
        content
            .background(theme.surfaces.card, in: shape)
            .overlay {
                shape.strokeBorder(Color.agentInk.opacity(contrast == .increased ? 0.5 : 0), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
    }
}

/// The pointer lifts a control slightly and a press settles it back, which is
/// what makes the panel feel physical rather than painted on.
struct NotchButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    var lifts = true
    /// A light wash under the pointer.
    var highlights = true
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let active = enabled && hovered
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.agentInk.opacity(active && highlights ? 0.09 : 0))
                    .allowsHitTesting(false)
            }
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(reduceMotion || !lifts ? 1
                         : configuration.isPressed ? 0.965 : (active ? 1.022 : 1))
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7),
                       value: configuration.isPressed)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.75), value: hovered)
            .onHover { hovered = $0 }
    }
}

/// What a menu in the page's top row reads: its current choice, cut to the
/// room its side leaves, with the chevron that says a list opens from it.
struct NotchBandMenuLabel: View {
    let title: String
    var symbol: String? = nil
    var truncation: Text.TruncationMode = .tail

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(Color.agentInk.opacity(0.55))
            }
            Text(title).lineLimit(1).truncationMode(truncation)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.agentInk.opacity(0.85))
        .padding(.horizontal, 7)
        .frame(height: 28)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// A short page puts the glyph beside its message; taller ones stack them.
/// Actions, when a page has a next step to offer, follow the message.
struct NotchEmptyView<Actions: View>: View {
    let symbol: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 12) {
                glyph
                label.multilineTextAlignment(.center).frame(maxWidth: 250)
                actions()
            }
            HStack(spacing: 14) {
                glyph
                VStack(alignment: .leading, spacing: 10) {
                    label.frame(maxWidth: 260, alignment: .leading)
                    actions()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .light))
            .foregroundStyle(Color.agentInk.opacity(0.65))
            .frame(width: 56, height: 56)
            .background(Color.agentInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityHidden(true)
    }

    private var label: some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension NotchEmptyView where Actions == EmptyView {
    init(symbol: String, message: String) {
        self.init(symbol: symbol, message: message) { EmptyView() }
    }
}

/// An empty page's next step, as a word on a pill.
struct NotchPillButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: prominent ? .semibold : .medium))
                .foregroundStyle(Color.agentInk.opacity(prominent ? 1 : 0.7))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Color.agentInk.opacity(prominent ? 0.14 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 14))
    }
}

/// A level bar: the share done, drawn in the panel's ink.
struct NotchMeter: View {
    let value: Double
    var height: CGFloat = 5
    var tint: Color = .agentInk

    var body: some View {
        let fraction = value.isFinite ? min(1, max(0, value)) : 0
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Color.agentInk.opacity(0.14))
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.9))
                    .frame(width: max(fraction > 0 ? height : 0, proxy.size.width * fraction))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct NotchIconButton: View {
    let symbol: String
    let title: String
    var selected = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.agentInk.opacity(selected ? 1 : 0.55))
                .contentTransition(.symbolEffect(.replace))
                .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: symbol)
                .frame(width: 28, height: 28)
                .background(Color.agentInk.opacity(selected ? 0.12 : 0),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 9))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
