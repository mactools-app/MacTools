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
    static let agentInk = Color(nsColor: NSColor(name: "AIUsageAgentInk") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    })
}

extension ShapeStyle where Self == Color {
    static var agentInk: Color { Color.agentInk }
}

private struct AgentOpenSettingsKey: EnvironmentKey {
    static var defaultValue: () -> Void { {} }
}

extension EnvironmentValues {
    /// Opens the plugin's settings page, where the island opened its own.
    var agentOpenSettings: () -> Void {
        get { self[AgentOpenSettingsKey.self] }
        set { self[AgentOpenSettingsKey.self] = newValue }
    }
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

/// Words the page needs from the rest of Vorssaint's string tables, and the
/// two that pointed at the island's settings.
extension NotchAgentStrings {
    private static var language: String {
        let code = (PluginRuntimeLocalization.preferredLanguages.first ?? "en").lowercased()
        if code.hasPrefix("zh-hant") || code.hasPrefix("zh-tw") || code.hasPrefix("zh-hk") { return "zh-Hant" }
        if code.hasPrefix("zh") { return "zh-Hans" }
        return String(code.prefix(2))
    }

    private static func pick(_ table: [String: String]) -> String {
        table[language] ?? table["en"] ?? ""
    }

    var cancel: String {
        Self.pick(["en": "Cancel", "uk": "Скасувати", "pt": "Cancelar", "es": "Cancelar", "sk": "Zrušiť",
                   "de": "Abbrechen", "fr": "Annuler", "it": "Annulla", "ru": "Отменить", "tr": "Vazgeç",
                   "ja": "キャンセル", "ko": "취소", "zh-Hans": "取消", "zh-Hant": "取消"])
    }

    var retry: String {
        Self.pick(["en": "Try Again", "uk": "Спробувати ще", "pt": "Tentar novamente", "es": "Reintentar",
                   "sk": "Skúsiť znova", "de": "Erneut versuchen", "fr": "Réessayer", "it": "Riprova",
                   "ru": "Повторить", "tr": "Yeniden dene", "ja": "再試行", "ko": "다시 시도",
                   "zh-Hans": "重试", "zh-Hant": "重試"])
    }

    var openSettings: String {
        Self.pick(["en": "Open Settings", "uk": "Відкрити параметри", "pt": "Abrir Ajustes", "es": "Abrir Ajustes",
                   "sk": "Otvoriť nastavenia", "de": "Einstellungen öffnen", "fr": "Ouvrir les réglages",
                   "it": "Apri Impostazioni", "ru": "Открыть настройки", "tr": "Ayarları Aç", "ja": "設定を開く",
                   "ko": "설정 열기", "zh-Hans": "打开设置", "zh-Hant": "打開設定"])
    }

    /// Vorssaint points at its island settings; MacTools keeps the cards in
    /// this plugin's settings.
    var noCardsInSettings: String {
        Self.pick(["en": "Choose what this page shows in AI Usage settings.",
                   "zh-Hans": "在“AI 用量”设置中选择此页面显示的内容。",
                   "zh-Hant": "在「AI 用量」設定中選擇此頁面顯示的內容。"])
    }

    var cardsHintInSettings: String {
        Self.pick(["en": "Drag to reorder. The page shows its cards from top to bottom.",
                   "zh-Hans": "拖移以重新排序。页面从上到下显示这些卡片。",
                   "zh-Hant": "拖移以重新排序。頁面從上到下顯示這些卡片。"])
    }
}
