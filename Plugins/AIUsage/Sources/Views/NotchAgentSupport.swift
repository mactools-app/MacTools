// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Vorssaint (github.com/vorssaint/vorssaint-utils), GPL-3.0-or-later.
// Copyright (C) 2026 Vorssaint; MacTools adaptation (C) 2026 MacTools contributors.

import CoreGraphics
import Foundation

/// The cards the AI page can show, in the order a person arranges them. Raw
/// values are stored in the saved order, so cases are never renamed.
enum NotchAgentCard: String, CaseIterable, Identifiable {
    case limits, spend, live, trend, models, projects, activity, resets

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .limits: return "gauge.with.dots.needle.33percent"
        case .spend: return "dollarsign.circle"
        case .live: return "waveform.path.ecg"
        case .trend: return "chart.bar.xaxis"
        case .models: return "cpu"
        case .projects: return "folder"
        case .activity: return "square.grid.3x3.fill"
        case .resets: return "arrow.counterclockwise.circle"
        }
    }

    /// Charts need the island's width; everything else pairs up.
    var fullWidth: Bool { self == .trend || self == .activity }

    /// Cards that cover the period chosen in the island's top row.
    var followsPeriod: Bool { self == .spend || self == .trend || self == .models || self == .projects }
}

/// What the closed island shows beside the camera while an agent works.
enum NotchAgentReadout: String, CaseIterable, Identifiable {
    case elapsed, tokens, cost, limit
    var id: String { rawValue }

    /// Tokens and cost change only with a new snapshot. Limits still need
    /// the clock: an allowance can renew, or show elapsed time while unknown.
    var advancesWithClock: Bool { self == .elapsed || self == .limit }
}

enum NotchAgentLimitDisplay: String, CaseIterable, Identifiable {
    case remaining, used
    var id: String { rawValue }
}

/// Which allowance the closed island shows.
enum NotchAgentLimitFocus: String, CaseIterable, Identifiable {
    case mostUsed, session, weekly
    var id: String { rawValue }
}

struct NotchAgentTile: Identifiable, Equatable {
    let card: NotchAgentCard
    /// The account a limits card belongs to.
    let provider: AgentProvider?
    /// An explicitly chosen account's card; nil for the default reading.
    var accountID: String? = nil
    /// The Resets card beside added Codex homes, which says whose resets they are.
    var namesDefaultAccount = false
    var id: String { card.rawValue + (provider.map { "." + $0.rawValue } ?? "") + (accountID.map { "." + $0 } ?? "") }
}

enum NotchAgentSupport {
    static let defaultFinishMinimum: TimeInterval = 60
    static let finishMinimums: [TimeInterval] = [0, 30, 60, 120, 300]
    static let defaultLimitThreshold = 80.0
    static let limitThresholds = [50.0, 75.0, 80.0, 90.0, 95.0]
    static let budgets = [0.0, 5, 10, 25, 50, 100, 250]
    /// A turn silent for this long is not shown as working.
    static let idleTurn: TimeInterval = 10 * 60

    /// The page is read while the plugin is active. MacTools has no
    /// separate on switch for it.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        AgentPluginEnvironment.active
    }

    static func providers(in defaults: UserDefaults = .standard) -> [AgentProvider] {
        AgentProvider.allCases.filter {
            defaults.object(forKey: key(for: $0)) as? Bool ?? true
        }
    }

    static func key(for provider: AgentProvider) -> String {
        switch provider {
        case .claude: return DefaultsKey.notchAgentsClaude
        case .codex: return DefaultsKey.notchAgentsCodex
        case .opencode: return DefaultsKey.notchAgentsOpenCode
        case .copilot: return DefaultsKey.notchAgentsCopilot
        }
    }

    /// Every card in the saved order; cards added later join at the end.
    static func orderedCards(in defaults: UserDefaults = .standard) -> [NotchAgentCard] {
        let stored = (defaults.string(forKey: DefaultsKey.notchAgentsCardOrder) ?? "")
            .split(separator: ",").compactMap { NotchAgentCard(rawValue: String($0)) }
        var seen = Set<NotchAgentCard>()
        return (stored + NotchAgentCard.allCases).filter { seen.insert($0).inserted }
    }

    static func hiddenCards(in defaults: UserDefaults = .standard) -> Set<NotchAgentCard> {
        Set((defaults.string(forKey: DefaultsKey.notchAgentsHiddenCards) ?? "")
            .split(separator: ",").compactMap { NotchAgentCard(rawValue: String($0)) })
    }

    static func cards(in defaults: UserDefaults = .standard) -> [NotchAgentCard] {
        let hidden = hiddenCards(in: defaults)
        return orderedCards(in: defaults).filter { !hidden.contains($0) }
    }

    /// Added Codex accounts have cards only in the Limits card's place.
    static func showsCodexAccounts(in defaults: UserDefaults = .standard) -> Bool { false }

    static func period(in defaults: UserDefaults = .standard) -> AgentPeriod {
        AgentPeriod(rawValue: defaults.string(forKey: DefaultsKey.notchAgentsPeriod) ?? "") ?? .today
    }

    static func limitDisplay(in defaults: UserDefaults = .standard) -> NotchAgentLimitDisplay {
        NotchAgentLimitDisplay(rawValue: defaults.string(forKey: DefaultsKey.notchAgentsLimitDisplay) ?? "") ?? .remaining
    }

    /// MacTools shows no agent strip, turn alerts, limit warnings or daily
    /// budget at the island; the readings below say so to the service.
    static func showsLiveActivity(in defaults: UserDefaults = .standard) -> Bool { false }
    static func finishMinimum(in defaults: UserDefaults = .standard) -> TimeInterval? { nil }
    static func limitThreshold(in defaults: UserDefaults = .standard) -> Double? { nil }
    static func dailyBudget(in defaults: UserDefaults = .standard) -> Double? { nil }

    /// Whether the public price list may be downloaded once a day.
    static func updatesPrices(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: DefaultsKey.notchAgentsPriceUpdates) as? Bool ?? true
    }

    /// Only the page's Limits card asks for the plan limits, and only
    /// while the page shows.
    static func limitsInUse(pageShown: Bool, in defaults: UserDefaults = .standard) -> Bool {
        pageShown && !hiddenCards(in: defaults).contains(.limits)
    }

    /// A limit's share on the page's card. It names which share it is:
    /// a bare 99% left reads as 99% spent.
    static func limitShare(_ window: AgentLimitWindow, display: NotchAgentLimitDisplay,
                           text: NotchAgentStrings) -> String {
        display == .remaining ? text.left(AgentFormat.percent(window.remainingFraction))
            : text.usedShare(AgentFormat.percent(window.usedFraction))
    }

    // MARK: Layout

    static let spacing: CGFloat = 10
    static let cardHeight: CGFloat = 96
    static let chartHeight: CGFloat = 118
    /// An account card also says when it was checked, and the Resets card
    /// beside account cards names the account its resets belong to.
    static let accountCardHeight: CGFloat = 116
    /// An account card's reading, checked every five minutes, has missed two.
    static let accountStaleness: TimeInterval = 10 * 60
    /// Below this width every card takes a row of its own.
    static let pairWidth: CGFloat = 390

    /// Codex homes the person added take the place of Codex's one limits
    /// card, the usual home among them when they add it.
    static func tiles(cards: [NotchAgentCard], providers: [AgentProvider],
                      codexAccounts: [String] = [], claudeAccount: String? = nil) -> [NotchAgentTile] {
        cards.flatMap { card -> [NotchAgentTile] in
            switch card {
            case .limits: return providers.filter(\.reportsLimits).flatMap { provider -> [NotchAgentTile] in
                if provider == .claude, let claudeAccount {
                    return [NotchAgentTile(card: .limits, provider: provider, accountID: claudeAccount)]
                }
                guard provider == .codex, !codexAccounts.isEmpty else { return [NotchAgentTile(card: .limits, provider: provider)] }
                return codexAccounts.map { NotchAgentTile(card: .limits, provider: provider, accountID: $0) }
            }
            // Banked resets belong to a Codex account: the default one, which
            // the card names once others have cards.
            case .resets: return providers.contains(.codex)
                ? [NotchAgentTile(card: .resets, provider: .codex, namesDefaultAccount: !codexAccounts.isEmpty)] : []
            default: return [NotchAgentTile(card: card, provider: nil)]
            }
        }
    }

    /// Cards pair up in reading order; a chart, or a card left without a
    /// partner, takes the whole row.
    static func rows(_ tiles: [NotchAgentTile], width: CGFloat) -> [[NotchAgentTile]] {
        let pairs = width >= pairWidth
        var rows: [[NotchAgentTile]] = []
        var waiting: NotchAgentTile?
        for tile in tiles {
            if tile.card.fullWidth || !pairs {
                if let waiting { rows.append([waiting]) }
                waiting = nil
                rows.append([tile])
            } else if let partner = waiting {
                rows.append([partner, tile])
                waiting = nil
            } else {
                waiting = tile
            }
        }
        if let waiting { rows.append([waiting]) }
        return rows
    }

    static func height(of row: [NotchAgentTile]) -> CGFloat {
        if row.contains(where: \.card.fullWidth) { return chartHeight }
        return row.contains { $0.accountID != nil || $0.namesDefaultAccount } ? accountCardHeight : cardHeight
    }

    /// An account card's line in place of its windows while it has none, or
    /// under them: a failure takes one of the two, never both.
    static func accountNotes(hasWindows: Bool, checking: Bool, failure: String?, hint: String, loading: String,
                             updated: String?) -> (placeholder: String?, caption: String?) {
        guard hasWindows else { return (checking ? loading : failure ?? hint, nil) }
        return (nil, failure ?? updated)
    }

    /// A reading old enough to have missed use elsewhere shows quieter: an
    /// account card's after missed checks, and among the others only
    /// Claude's, which the Claude app or Claude Code took a while ago.
    static func limitsAreStale(_ limits: AgentLimits?, provider: AgentProvider, account: Bool, now: Date) -> Bool {
        guard let limits else { return false }
        let age = now.timeIntervalSince(limits.observedAt)
        if account { return age >= accountStaleness }
        return provider == .claude && age >= AgentClaudeAppUsage.freshness
    }

    static func contentHeight(_ rows: [[NotchAgentTile]]) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        return rows.map(height).reduce(0, +) + spacing * CGFloat(rows.count - 1)
    }
}

/// Numbers in the reader's region; costs in US dollars, the currency both
/// providers list their prices in.
enum AgentFormat {
    static func cost(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard value.isFinite else { return "$0" }
        let magnitude = abs(value)
        if magnitude >= 10_000 { return "$" + scaled(magnitude / 1000, locale: locale) + "K" }
        let digits = magnitude >= 100 ? 0 : 2
        return "$" + value.formatted(.number.precision(.fractionLength(digits)).grouping(.automatic).locale(locale))
    }

    static func tokens(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let magnitude = Double(max(0, value))
        switch magnitude {
        case ..<1000: return Int(magnitude).formatted(.number.locale(locale))
        case ..<1_000_000: return scaled(magnitude / 1000, locale: locale) + "K"
        case ..<1_000_000_000: return scaled(magnitude / 1_000_000, locale: locale) + "M"
        default: return scaled(magnitude / 1_000_000_000, locale: locale) + "B"
        }
    }

    /// One decimal below ten, none above: "4.2", "48", "120".
    private static func scaled(_ value: Double, locale: Locale) -> String {
        let digits = value < 10 ? 1 : 0
        let rounded = (value * (digits == 1 ? 10 : 1)).rounded(.down) / (digits == 1 ? 10 : 1)
        return rounded.formatted(.number.precision(.fractionLength(0...digits)).locale(locale))
    }

    static func percent(_ fraction: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let value = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// "4m 12s", "1h 05m", "2d 3h", in the app's language.
    static func duration(_ seconds: TimeInterval, locale: Locale, units: Int = 2,
                         style: DateComponentsFormatter.UnitsStyle = .abbreviated) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = style
        formatter.maximumUnitCount = units
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: max(0, seconds.isFinite ? seconds : 0)) ?? ""
    }

    /// "13 weeks" or "30 days", spelled out in the app's language.
    static func span(days: Int, locale: Locale) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        let weeks = days % 7 == 0
        formatter.allowedUnits = weeks ? [.weekOfMonth] : [.day]
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        // Components, not an interval: an interval is measured from today and
        // can lose a week across a month.
        let count = max(0, days)
        return formatter.string(from: weeks ? DateComponents(weekOfMonth: count / 7) : DateComponents(day: count)) ?? ""
    }

    /// A running stopwatch: "0:42", "12:05", "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A calendar day kept in UTC, like the price list's, read as that same
    /// day wherever the Mac is.
    static func day(_ date: Date, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        style.timeZone = .gmt
        return date.formatted(style)
    }
}
