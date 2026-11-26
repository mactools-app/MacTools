// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Vorssaint (github.com/vorssaint/vorssaint-utils), GPL-3.0-or-later.
// Copyright (C) 2026 Vorssaint; MacTools adaptation (C) 2026 MacTools contributors.

import AppKit
import MacToolsPluginKit
import SwiftUI
import UniformTypeIdentifiers

/// The AI page's options from Vorssaint's AI settings: the agents, the
/// cards and their order, how limits read, the price list and where Claude's
/// plan limits come from. The island strip, turn alerts, limit warnings and
/// the daily budget belong to Vorssaint's island and are not part of MacTools.
extension AIUsagePlugin {
    var settingsPage: PluginSettingsPage? {
        let text = NotchAgentStrings.current
        let changed: () -> Void = { [weak self] in self?.preferencesChanged() }
        return .form(description: text.settingsDescription, sections: [
            PluginSettingsSection(id: "agents", title: text.agents, systemImage: "sparkles",
                                  presentation: .edgeToEdge) { _ in
                AgentProvidersSettings(changed: changed)
            },
            PluginSettingsSection(id: "cards", title: text.cardsTitle, systemImage: "square.grid.2x2",
                                  footer: text.cardsHintInSettings) { _ in
                AgentCardsSettings(changed: changed)
            },
            PluginSettingsSection(id: "readings", title: text.limitsCard, systemImage: NotchAgentCard.limits.symbol,
                                  footer: text.valueNote) { _ in
                AgentReadingSettings(changed: changed)
            },
            PluginSettingsSection(id: "claude-limits", title: text.claudeLimitsTitle, systemImage: "checkmark.shield",
                                  footer: text.claudeLimitsPrivacy) { _ in
                AgentClaudeLimitsSettings()
            },
        ])
    }
}

/// One row per agent, with its own mark, whether its logs are on this Mac
/// and a switch. One agent stays on.
private struct AgentProvidersSettings: View {
    let changed: () -> Void
    @AppStorage(DefaultsKey.notchAgentsClaude) private var claude = true
    @AppStorage(DefaultsKey.notchAgentsCodex) private var codex = true
    @AppStorage(DefaultsKey.notchAgentsOpenCode) private var opencode = true
    @AppStorage(DefaultsKey.notchAgentsCopilot) private var copilot = true
    @State private var roots: [AgentProvider: Bool] = [:]

    private var text: NotchAgentStrings { NotchAgentStrings.current }

    var body: some View {
        VStack(spacing: 0) {
            row(.claude, isOn: $claude)
            Divider()
            row(.codex, isOn: $codex)
            Divider()
            row(.opencode, isOn: $opencode)
            Divider()
            row(.copilot, isOn: $copilot)
        }
        .onAppear(perform: findRoots)
        .onChange(of: [claude, codex, opencode, copilot]) { changed() }
    }

    private func row(_ provider: AgentProvider, isOn: Binding<Bool>) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            NotchAgentMark(provider: provider, size: 13)
                .frame(width: 26, height: 26)
                .background(provider.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(provider.displayName).font(PluginSettingsTheme.Typography.rowTitle)
                Text(roots[provider] == true ? text.found : text.notFound)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle(provider.displayName, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(isOn.wrappedValue && [claude, codex, opencode, copilot].filter { $0 }.count <= 1)
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }

    /// Where the logs live is checked when the page opens, not on every draw.
    private func findRoots() {
        let found = AgentLogRoot.all(claudeProfile: ClaudeAccountProfile()).filter(\.exists).map(\.provider)
        roots = Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { ($0, found.contains($0)) })
    }
}

/// The cards, in the page's order: a click shows or hides one, a drag
/// moves it.
private struct AgentCardsSettings: View {
    let changed: () -> Void
    @AppStorage(DefaultsKey.notchAgentsCardOrder) private var cardOrder = ""
    @AppStorage(DefaultsKey.notchAgentsHiddenCards) private var hiddenCards = ""
    @State private var dragging: NotchAgentCard?

    private var text: NotchAgentStrings { NotchAgentStrings.current }

    private var orderedCards: [NotchAgentCard] {
        let stored = cardOrder.split(separator: ",").compactMap { NotchAgentCard(rawValue: String($0)) }
        var seen = Set<NotchAgentCard>()
        return (stored + NotchAgentCard.allCases).filter { seen.insert($0).inserted }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
            ForEach(orderedCards) { card in
                chip(card)
                    .onDrag {
                        dragging = card
                        return NSItemProvider(object: card.rawValue as NSString)
                    }
                    .onDrop(of: [UTType.text], delegate: AgentCardDrop(card: card, order: orderBinding, dragging: $dragging))
                    .accessibilityAction(named: Text(verbatim: "↑")) { move(card, by: -1) }
                    .accessibilityAction(named: Text(verbatim: "↓")) { move(card, by: 1) }
            }
        }
        .padding(.vertical, 2)
        .onChange(of: [cardOrder, hiddenCards]) { changed() }
    }

    private func chip(_ card: NotchAgentCard) -> some View {
        let included = !hiddenCards.split(separator: ",").contains(Substring(card.rawValue))
        return Button {
            setIncluded(card, !included)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: card.symbol).frame(width: 14)
                Text(text.card(card)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(included ? Color.accentColor : Color.secondary)
            }
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(included ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.primary.opacity(included ? 0.07 : 0.03),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(dragging == card ? 0.4 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(included ? Text(verbatim: "✓") : Text(verbatim: ""))
    }

    private var orderBinding: Binding<[NotchAgentCard]> {
        Binding(get: { orderedCards }, set: { cardOrder = $0.map(\.rawValue).joined(separator: ",") })
    }

    private func setIncluded(_ card: NotchAgentCard, _ shown: Bool) {
        var hidden = Set(hiddenCards.split(separator: ",").map(String.init))
        if shown { hidden.remove(card.rawValue) } else { hidden.insert(card.rawValue) }
        hiddenCards = hidden.sorted().joined(separator: ",")
    }

    /// VoiceOver's way to reorder the cards, which otherwise only drag.
    private func move(_ card: NotchAgentCard, by offset: Int) {
        var order = orderedCards
        guard let index = order.firstIndex(of: card), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        cardOrder = order.map(\.rawValue).joined(separator: ",")
    }
}

private struct AgentCardDrop: DropDelegate {
    let card: NotchAgentCard
    @Binding var order: [NotchAgentCard]
    @Binding var dragging: NotchAgentCard?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != card, let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: card) else { return }
        var next = order
        next.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        order = next
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct AgentReadingSettings: View {
    let changed: () -> Void
    @AppStorage(DefaultsKey.notchAgentsLimitDisplay) private var limitDisplay = NotchAgentLimitDisplay.remaining.rawValue
    @AppStorage(DefaultsKey.notchAgentsPriceUpdates) private var priceUpdates = true
    @ObservedObject private var usage = AgentUsageService.shared

    private var text: NotchAgentStrings { NotchAgentStrings.current }

    var body: some View {
        VStack(spacing: PluginSettingsTheme.Spacing.rowVertical * 2) {
            PluginSettingsItem(title: text.limitsAs) {
                Picker(text.limitsAs, selection: $limitDisplay) {
                    Text(text.remaining).tag(NotchAgentLimitDisplay.remaining.rawValue)
                    Text(text.used).tag(NotchAgentLimitDisplay.used.rawValue)
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            Divider()
            PluginSettingsItem(title: text.priceUpdates, description: priceCaption) {
                Toggle(text.priceUpdates, isOn: $priceUpdates).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        .onChange(of: priceUpdates) { changed() }
    }

    private var priceCaption: String {
        guard let day = usage.pricesUpdated else { return text.priceUpdatesHint }
        return text.priceUpdatesHint + " " + text.pricesFrom(AgentFormat.day(day, locale: PluginRuntimeLocalization.locale))
    }
}

/// Where Claude's plan limits stand, and the one step that brings them
/// here when they are missing or old. Without a recent reading from
/// Claude Code, why its last check failed shows beneath.
private struct AgentClaudeLimitsSettings: View {
    @ObservedObject private var usage = AgentUsageService.shared
    @State private var claudeApp: URL?
    /// Read from the file while the service is paused.
    @State private var claudeAppFileCheck: Date?

    private var text: NotchAgentStrings { NotchAgentStrings.current }
    private var locale: Locale { PluginRuntimeLocalization.locale }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            status(now: context.date)
        }
        .onAppear(perform: findClaudeApp)
    }

    @ViewBuilder private func status(now: Date) -> some View {
        let account = usage.snapshot.limits[.claude].flatMap { $0.source == .account ? $0.observedAt : nil }
        let checked = account ?? usage.claudeAppChecked ?? claudeAppFileCheck
        let failure = account.map { now.timeIntervalSince($0) < AgentClaudeAppUsage.freshness } == true ? nil
            : usage.claudeAccountFailure.map { text.claudeCode($0) }
        HStack(alignment: .top, spacing: 10) {
            if let account {
                Image(systemName: now.timeIntervalSince(account) < AgentClaudeAppUsage.freshness
                      ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(now.timeIntervalSince(account) < AgentClaudeAppUsage.freshness ? .green : .orange)
                explained(failure) { Text("Claude Code · " + text.updated(relative(account, now: now))) }
                Spacer(minLength: 0)
            } else if let checked, now.timeIntervalSince(checked) < AgentClaudeAppUsage.freshness {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                explained(failure) { Text(text.claudeLimitsCurrent(relative(checked, now: now))) }
                Spacer(minLength: 0)
            } else if claudeApp == nil, checked == nil {
                Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                explained(failure) { Text(text.claudeLimitsNoApp) }
                Spacer(minLength: 8)
                Button(text.getClaude) { NSWorkspace.shared.open(AgentClaudeAppUsage.downloadURL) }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                explained(failure) {
                    if let checked { Text(text.claudeLimitsStale(relative(checked, now: now))) }
                    Text(text.claudeLimitsMenuBar)
                }
                Spacer(minLength: 8)
                if let claudeApp {
                    Button(text.openClaude) {
                        NSWorkspace.shared.openApplication(at: claudeApp, configuration: NSWorkspace.OpenConfiguration())
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .font(PluginSettingsTheme.Typography.rowTitle)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }

    private func explained<Content: View>(_ failure: String?, @ViewBuilder _ status: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            status()
            if let failure { Text(failure).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary) }
        }
    }

    private func relative(_ date: Date, now: Date) -> String {
        min(date, now).formatted(.relative(presentation: .named).locale(locale))
    }

    /// The app and the file are looked up when the page opens, off the main
    /// thread for the file, never on every draw.
    private func findClaudeApp() {
        claudeApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentClaudeAppUsage.bundleIdentifier)
        DispatchQueue.global(qos: .utility).async {
            let checked = AgentClaudeAppUsage.lastCheck()
            DispatchQueue.main.async { claudeAppFileCheck = checked }
        }
    }
}
