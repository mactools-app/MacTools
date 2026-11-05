import Combine
import Foundation
import MacToolsPluginKit
import SwiftUI

struct ClipboardHistoryFilterState: Codable, Equatable, Sendable {
    var scope: ClipboardPanelMode = .all
    var type: ClipboardHistoryContentFilter = .all
    var contains: ClipboardHistorySemanticFilter = .any
    var savedOnly = false

    static let defaults = Self()

    var normalized: Self {
        var result = self
        if scope == .saved { result.scope = .all; result.savedOnly = true }
        return result
    }

    var hasSecondaryFilters: Bool { type != .all || contains != .any || savedOnly }

    func applying(_ action: ClipboardHistoryFilterAction) -> Self {
        var result = normalized
        switch action {
        case let .scope(scope): result.scope = scope
        case let .type(type): result.type = type
        case let .contains(contains): result.contains = contains
        case let .savedOnly(savedOnly): result.savedOnly = savedOnly
        case .clear: result = Self(scope: result.scope)
        }
        return result.normalized
    }
}

enum ClipboardHistoryFilterAction: Hashable, Sendable {
    case scope(ClipboardPanelMode)
    case type(ClipboardHistoryContentFilter)
    case contains(ClipboardHistorySemanticFilter)
    case savedOnly(Bool)
    case clear
}

enum ClipboardHistoryFilterShortcuts {
    struct Definition {
        let id: String
        let action: ClipboardHistoryFilterAction
        let keyCode: UInt16
        var modifiers: ShortcutModifiers = [.option, .command]

        var binding: ShortcutBinding { ShortcutBinding(keyCode: keyCode, modifiers: modifiers) }
    }

    static let definitions: [Definition] = [
        .init(id: "panel-filter-all-types", action: .type(.all), keyCode: 18),
        .init(id: "panel-filter-text", action: .type(.text), keyCode: 19),
        .init(id: "panel-filter-image", action: .type(.image), keyCode: 20),
        .init(id: "panel-filter-files", action: .type(.files), keyCode: 21),
        .init(id: "panel-filter-pdf", action: .type(.pdf), keyCode: 23),
        .init(id: "panel-filter-media", action: .type(.media), keyCode: 22),
        .init(id: "panel-filter-color", action: .type(.color), keyCode: 26),
        .init(id: "panel-filter-any-content", action: .contains(.any), keyCode: 18, modifiers: [.option, .shift, .command]),
        .init(id: "panel-filter-links", action: .contains(.link), keyCode: 19, modifiers: [.option, .shift, .command]),
        .init(id: "panel-filter-email", action: .contains(.email), keyCode: 20, modifiers: [.option, .shift, .command]),
        .init(id: "panel-filter-recognized-text", action: .contains(.recognizedText), keyCode: 21, modifiers: [.option, .shift, .command]),
        .init(id: "panel-filter-clear", action: .clear, keyCode: 29),
    ]

    static func id(for action: ClipboardHistoryFilterAction) -> String? {
        definitions.first { $0.action == action }?.id
    }
}

/// Host deliveries keep rendering and key handling on one effective binding snapshot.
@MainActor
final class ClipboardHistoryPanelShortcuts: ObservableObject {
    @Published private(set) var bindings: [String: ShortcutBinding] = [:]
    @Published private(set) var isHostManaged = false

    func receiveHostBinding(id: String, binding: ShortcutBinding?) {
        guard ClipboardHistoryPlugin.panelShortcutDefinitionIDs.contains(id) else { return }
        if !isHostManaged { isHostManaged = true }
        if bindings[id] != binding { bindings[id] = binding }
    }

    func reset() {
        isHostManaged = false
        bindings = [:]
    }
}

struct ClipboardHistoryFilterLabels {
    let localization: PluginLocalization

    func type(_ type: ClipboardHistoryContentFilter) -> String {
        switch type {
        case .all: localization.string("panel.filter.all", defaultValue: "所有类型")
        case .text: localization.string("content.kind.text", defaultValue: "文本")
        case .image: localization.string("content.kind.image", defaultValue: "图片")
        case .pdf: localization.string("content.kind.pdf", defaultValue: "PDF")
        case .files: localization.string("content.kind.files", defaultValue: "文件")
        case .color: localization.string("content.kind.color", defaultValue: "颜色")
        case .media: localization.string("content.kind.media", defaultValue: "音频与视频")
        }
    }

    func scope(_ scope: ClipboardPanelMode) -> String {
        switch scope {
        case .all: localization.string("panel.mode.all", defaultValue: "All")
        case .history: localization.string("panel.mode.history", defaultValue: "History")
        case .snippets: localization.string("saved.kind.snippet", defaultValue: "Snippets")
        case .saved: localization.string("panel.mode.saved", defaultValue: "Saved")
        }
    }

    func contains(_ contains: ClipboardHistorySemanticFilter) -> String {
        switch contains {
        case .any: localization.string("panel.filter.anyContent", defaultValue: "任何内容")
        case .link: localization.string("content.kind.link", defaultValue: "链接")
        case .email: localization.string("content.kind.email", defaultValue: "电子邮件")
        case .recognizedText: localization.string("content.kind.recognizedText", defaultValue: "识别文字")
        }
    }

    var clear: String { localization.string("panel.filter.clear", defaultValue: "Clear Filters") }
    var typeTitle: String { localization.string("panel.filter.family.type", defaultValue: "类型") }
    var containsTitle: String { localization.string("panel.filter.family.contains", defaultValue: "包含") }
    var savedOnly: String { localization.string("panel.filter.savedOnly", defaultValue: "Saved Only") }
    var remember: String { localization.string("panel.filter.remember", defaultValue: "Remember Filters on Reopen") }

    func action(_ action: ClipboardHistoryFilterAction) -> String {
        switch action {
        case let .type(value): localization.format("panel.filter.action.type", defaultValue: "Type: %@", type(value))
        case let .scope(value): localization.format("panel.filter.action.scope", defaultValue: "Scope: %@", scope(value))
        case let .contains(value): localization.format("panel.filter.action.contains", defaultValue: "Contains: %@", contains(value))
        case .savedOnly: savedOnly
        case .clear: clear
        }
    }
}

struct ClipboardHistoryFilterBar: View {
    let filters: ClipboardHistoryFilterState
    let remembersFilters: Bool
    let localization: PluginLocalization
    let select: (ClipboardHistoryFilterAction) -> Void
    let setRemember: (Bool) -> Void

    private var labels: ClipboardHistoryFilterLabels { .init(localization: localization) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                scopes
                Spacer(minLength: 16)
                filterControls.fixedSize()
            }
            VStack(alignment: .trailing, spacing: 8) {
                HStack { scopes; Spacer(minLength: 0) }
                filterControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
    }

    private var scopes: some View {
        Picker(localization.string("panel.mode.searchIn", defaultValue: "Scope"), selection: Binding(
            get: { filters.scope.primaryScope }, set: { select(.scope($0)) }
        )) {
            ForEach(Array(ClipboardPanelMode.primaryScopes.enumerated()), id: \.element) { index, scope in
                Text(labels.scope(scope)).tag(scope).help("\(labels.scope(scope)) · ⌃\(index + 1)")
            }
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 270)
        .accessibilityIdentifier("mactools.clipboard.scopes")
    }

    private var filterControls: some View {
        HStack(spacing: 8) {
            // Grow into the flexible space on the leading side of this trailing-aligned group.
            if filters.hasSecondaryFilters { clearButton }
            selectors
            optionsMenu
        }
        .fixedSize()
        .controlSize(.small)
    }

    private var selectors: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(ClipboardHistoryContentFilter.allCases) { type in
                    Toggle(isOn: Binding(
                        get: { filters.type == type }, set: { if $0 { select(.type(type)) } }
                    )) {
                        Label(labels.type(type), systemImage: type.systemImage)
                            .labelStyle(.titleAndIcon)
                            .symbolRenderingMode(.monochrome)
                    }
                }
            } label: {
                Text(filters.type == .all ? labels.typeTitle : labels.type(filters.type))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 56, alignment: .leading)
            }
            .overlay { activeMenuHighlight(filters.type != .all) }
            .accessibilityLabel(labels.action(.type(filters.type)))
            .help(labels.action(.type(filters.type)))
            .accessibilityAddTraits(filters.type == .all ? [] : .isSelected)
            .accessibilityIdentifier("mactools.clipboard.filter.type")
            Menu {
                ForEach(ClipboardHistorySemanticFilter.allCases) { contains in
                    Toggle(isOn: Binding(
                        get: { filters.contains == contains }, set: { if $0 { select(.contains(contains)) } }
                    )) {
                        Label(labels.contains(contains), systemImage: contains.systemImage)
                            .labelStyle(.titleAndIcon)
                            .symbolRenderingMode(.monochrome)
                    }
                }
            } label: {
                Text(filters.contains == .any ? labels.containsTitle : labels.contains(filters.contains))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 74, alignment: .leading)
            }
            .overlay { activeMenuHighlight(filters.contains != .any) }
            .accessibilityLabel(labels.action(.contains(filters.contains)))
            .help(labels.action(.contains(filters.contains)))
            .accessibilityAddTraits(filters.contains == .any ? [] : .isSelected)
            .accessibilityIdentifier("mactools.clipboard.filter.contains")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    private var clearButton: some View {
        Button { select(.clear) } label: {
            Text(localization.string("common.clear", defaultValue: "清除"))
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help(labels.clear)
        .accessibilityLabel(labels.clear)
        .accessibilityIdentifier("mactools.clipboard.filter.clear")
    }

    private var optionsMenu: some View {
        Menu {
            Toggle(isOn: Binding(get: { filters.savedOnly }, set: { select(.savedOnly($0)) })) {
                Label(labels.savedOnly, systemImage: "bookmark")
                    .labelStyle(.titleAndIcon)
                    .symbolRenderingMode(.monochrome)
            }
            Divider()
            Toggle(isOn: Binding(get: { remembersFilters }, set: { setRemember($0) })) {
                Label(labels.remember, systemImage: "pin")
                    .labelStyle(.titleAndIcon)
                    .symbolRenderingMode(.monochrome)
            }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .overlay { activeMenuHighlight(filters.savedOnly) }
        .accessibilityLabel(localization.string("common.more", defaultValue: "More…"))
        .accessibilityValue(filters.savedOnly ? labels.savedOnly : "")
        .accessibilityAddTraits(filters.savedOnly ? .isSelected : [])
        .help(filters.savedOnly ? labels.savedOnly : localization.string("common.more", defaultValue: "More…"))
        .accessibilityIdentifier("mactools.clipboard.filter.options")
    }

    private func activeMenuHighlight(_ isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(PluginSettingsTheme.Palette.activeControlBackground)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
