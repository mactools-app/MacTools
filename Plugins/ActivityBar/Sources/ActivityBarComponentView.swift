import AppKit
import Charts
import SwiftUI
import MacToolsPluginKit

private enum ActivityBarComponentLayout {
    static let cardCornerRadius = PluginPanelWidgetLayoutMetrics.cardCornerRadius
}

private struct ActivityBarContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum ActivityBarTrendMode: String, CaseIterable {
    case codingTools = "Coding Tools"
    case input = "Input"

    func label(localization: PluginLocalization) -> String {
        switch self {
        case .codingTools:
            localization.string("component.trendMode.codingTools", defaultValue: "Coding Tools")
        case .input:
            localization.string("component.trendMode.input", defaultValue: "Input")
        }
    }
}

private enum ActivityBarChartRange: String, CaseIterable {
    case oneDay = "1d"
    case sevenDays = "7d"
    case fourteenDays = "14d"
    case thirtyDays = "30d"

    var dayCount: Int {
        switch self {
        case .oneDay:
            return 1
        case .sevenDays:
            return 7
        case .fourteenDays:
            return 14
        case .thirtyDays:
            return 30
        }
    }

    var label: String { rawValue }
}

/// Each placement retains its own selections across viewport unmounts.
@MainActor
final class ActivityBarComponentPresentation: ObservableObject {
    @Published var expandedAppName: String?
    @Published var selectedDateOffset = 0
    @Published var trendMode: ActivityBarTrendMode = .input
    private var didSelectInitialTrend = false
    private var didSelectInitialApp = false

    func selectInitialTrend(hasCodingToolsData: Bool) {
        guard !didSelectInitialTrend else { return }
        didSelectInitialTrend = true
        trendMode = hasCodingToolsData ? .codingTools : .input
    }

    func selectInitialApp(_ name: String?) {
        guard !didSelectInitialApp, let name else { return }
        didSelectInitialApp = true
        expandedAppName = name
    }
}

private enum ActivityBarFunFact {
    static let secondsPerClick = 0.50
    static let keysPerPage = 550

    static func forDay(_ stats: ActivityBarDailyStats, localization: PluginLocalization) -> String? {
        var facts: [String] = []

        if stats.keystrokes > 0 {
            let pages = Double(stats.keystrokes) / Double(keysPerPage)
            if pages >= 1 {
                let formatted = ActivityBarFormatting.decimal(stats.keystrokes)
                let fullPages = Int(pages.rounded())
                facts.append(
                    localization.format(
                        "component.funFact.typedPages",
                        defaultValue: "You typed %@ keys today. That's about writing %d full pages.",
                        formatted,
                        fullPages
                    )
                )
            }
        }

        if stats.pointerClicks > 0 {
            let clickMins = (Double(stats.pointerClicks) * secondsPerClick) / 60
            if clickMins >= 1 {
                let formatted = ActivityBarFormatting.decimal(stats.pointerClicks)
                let minutes = Int(clickMins.rounded())
                facts.append(
                    localization.format(
                        "component.funFact.clickMinutes",
                        defaultValue: "You clicked %@ times. That's like tapping your desk for about %d minutes.",
                        formatted,
                        minutes
                    )
                )
            }
        }

        guard !facts.isEmpty else {
            return nil
        }

        let hash = stats.date.utf8.reduce(5381) { (($0 << 5) &+ $0) &+ Int($1) }
        return facts[abs(hash) % facts.count]
    }
}

struct ActivityBarComponentView: View {
    private static let claudeColor = Color(red: 0xCB / 255.0, green: 0x64 / 255.0, blue: 0x41 / 255.0)
    private static let codexColor = Color(red: 0x10 / 255.0, green: 0xA3 / 255.0, blue: 0x7F / 255.0)
    static let visibleCodingTools: [ActivityBarCodingTool] = [.claudeCode, .cursor, .codex]

    private func codingToolColor(_ tool: ActivityBarCodingTool) -> Color {
        switch tool {
        case .claudeCode:
            return Self.claudeColor
        case .cursor:
            return theme.text.primary
        case .codex:
            return Self.codexColor
        }
    }

    private static func codingToolLegendLabel(_ tool: ActivityBarCodingTool) -> String {
        switch tool {
        case .claudeCode:
            return "Claude"
        case .cursor:
            return "Cursor"
        case .codex:
            return "Codex"
        }
    }

    let controller: ActivityBarController
    @ObservedObject private var presentation: ActivityBarComponentPresentation
    let localization: PluginLocalization
    let onContentHeightChange: (CGFloat) -> Void

    @Environment(\.pluginComponentTheme) private var theme

    @State private var hoveredDate: String?
    @State private var hoveredScreenTimeDate: String?
    @AppStorage("activity-bar.stats-expanded") private var statsExpanded = true
    @AppStorage("activity-bar.chart-range") private var chartRange = ActivityBarChartRange.sevenDays

    init(
        controller: ActivityBarController,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        presentation: ActivityBarComponentPresentation = ActivityBarComponentPresentation(),
        onContentHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.controller = controller
        self.localization = localization
        self.presentation = presentation
        self.onContentHeightChange = onContentHeightChange
    }

    private var selectedDate: Date {
        Calendar.current.date(byAdding: .day, value: presentation.selectedDateOffset, to: Date()) ?? Date()
    }

    private var selectedDateKey: String {
        dateKey(for: selectedDate)
    }

    private var selectedInputStats: ActivityBarDailyStats {
        controller.inputStats.stats(for: selectedDateKey)
    }

    private var selectedCodingStats: ActivityBarCodingDailyStats {
        controller.codingStats.stats(for: selectedDateKey)
    }

    private var isViewingToday: Bool {
        presentation.selectedDateOffset == 0
    }

    private var canGoBack: Bool {
        let keys = Set(controller.inputStats.sortedDateKeys + controller.codingStats.sortedDateKeys)
        guard let earliest = keys.sorted().first else {
            return false
        }

        return selectedDateKey > earliest
    }

    private var hasCodingToolsData: Bool {
        controller.codingStats.days.values.contains { day in
            hasCodingStats(visibleCodingAggregateStats(in: day))
        }
    }

    var body: some View {
        PluginObservedContent(controller) { _ in
            activityContent
        }
    }

    private var activityContent: some View {
        VStack(spacing: 0) {
            headerBar
            todayStats

            if showsAISection {
                divider
                aiSection
            }

            divider
            topAppsSection

            divider
            statsDisclosure
            if statsExpanded {
                if presentation.trendMode == .codingTools {
                    codingToolsChart
                } else {
                    weeklyChart
                    divider
                    screenTimeSection
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ActivityBarContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        }
        .onPreferenceChange(ActivityBarContentHeightPreferenceKey.self) { height in
            onContentHeightChange(height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            PluginComponentCardBackground(
                cornerRadius: ActivityBarComponentLayout.cardCornerRadius
            )
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: ActivityBarComponentLayout.cardCornerRadius,
                style: .continuous
            )
        )
        .animation(.easeInOut(duration: 0.2), value: statsExpanded)
        .animation(.easeInOut(duration: 0.2), value: chartRange)
        .animation(.easeInOut(duration: 0.2), value: presentation.trendMode)
        .animation(.easeInOut(duration: 0.15), value: presentation.selectedDateOffset)
        .onAppear {
            presentation.selectInitialTrend(hasCodingToolsData: hasCodingToolsData)
        }
    }

    private var headerBar: some View {
        HStack {
                Text(localization.string("component.title", defaultValue: "Activity Bar"))
                .font(PluginTypography.sectionTitle.font)
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        presentation.selectedDateOffset -= 1
                        presentation.expandedAppName = nil
                    }
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(canGoBack ? theme.text.secondary : theme.text.disabled)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canGoBack)

                Text(displayDateString)
                    .font(.body)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        presentation.selectedDateOffset += 1
                        presentation.expandedAppName = nil
                    }
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isViewingToday ? theme.text.disabled : theme.text.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isViewingToday)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var todayStats: some View {
        let day = selectedInputStats

        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                statCell(
                    icon: "keyboard",
                    value: ActivityBarFormatting.decimal(day.keystrokes),
                    label: localization.string("component.metric.keystrokes", defaultValue: "Keystrokes")
                )
                statCell(
                    icon: "cursorarrow.click.2",
                    value: ActivityBarFormatting.decimal(day.pointerClicks),
                    label: localization.string("component.metric.clicks", defaultValue: "Clicks")
                )
            }

            HStack(spacing: 10) {
                statCell(
                    icon: "scroll",
                    value: ActivityBarFormatting.decimal(day.scrollEvents),
                    label: localization.string("component.metric.scrolls", defaultValue: "Scrolls")
                )
                statCell(
                    icon: "macwindow.on.rectangle",
                    value: ActivityBarFormatting.duration(day.screenTimeSeconds),
                    label: localization.string("component.metric.screenTime", defaultValue: "Screen Time")
                )
            }

            if let fact = inputInsightText {
                Text(fact)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.text.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        theme.interaction.subtleTint(theme.dataSeries.primary),
                        in: RoundedRectangle(
                            cornerRadius: ActivityBarComponentLayout.cardCornerRadius,
                            style: .continuous
                        )
                    )
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func statCell(icon: String, value: String, label: String, tint: Color? = nil) -> some View {
        let resolvedTint = tint ?? theme.dataSeries.primary

        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(resolvedTint)
                .frame(width: 26, height: 26)
                .background(theme.interaction.selection(resolvedTint), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(PluginTypography.metric.font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(label)
                    .font(PluginTypography.detail.font)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.surfaces.nested,
            in: RoundedRectangle(
                cornerRadius: ActivityBarComponentLayout.cardCornerRadius,
                style: .continuous
            )
        )
    }

    private var inputInsightText: String? {
        if let fact = ActivityBarFunFact.forDay(selectedInputStats, localization: localization) {
            return fact
        }

        if isViewingToday, !controller.isTrackingEnabled {
            return localization.string(
                "component.inputInsight.enableTracking",
                defaultValue: "Grant Input Monitoring and turn this on to start collecting local stats."
            )
        }

        return nil
    }

    private var showsAISection: Bool {
        !codingToolRows(for: selectedCodingStats).isEmpty
            || (isViewingToday && controller.codingStats.activeSessionCount > 0)
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localization.string("component.ai.title", defaultValue: "Time AI Worked for You"))
                .font(PluginTypography.sectionTitle.font)
                .padding(.horizontal, 22)
                .padding(.bottom, 2)

            let rows = codingToolRows(for: selectedCodingStats)
            if rows.isEmpty {
                codingToolRow(
                    row: CodingToolDisplayRow(
                        id: "active-ai",
                        name: "Claude / Codex",
                        duration: 0,
                        detail: localization.format(
                            "component.ai.activeSessions",
                            defaultValue: "%d active",
                            controller.codingStats.activeSessionCount
                        ),
                        tint: Self.codexColor,
                        systemImage: "terminal",
                        iconSize: 13
                    )
                )
            } else {
                ForEach(rows) { row in
                    codingToolRow(row: row)
                }
            }

            if isViewingToday {
                aiWeeklyComparison
            }
        }
        .padding(.vertical, 8)
    }

    private func codingToolRow(row: CodingToolDisplayRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: PluginSystemImage.resolvedName(row.systemImage))
                .font(.system(size: row.iconSize, weight: .semibold))
                .foregroundStyle(row.tint)
                .frame(width: 26, height: 26)
                .background(theme.interaction.selection(row.tint), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.body)
                    .lineLimit(1)

                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.text.secondary)
                        .lineLimit(1)
                        .help(detail)
                }
            }

            Spacer(minLength: 8)

            Text(ActivityBarFormatting.duration(row.duration))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(theme.text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            theme.surfaces.nested,
            in: RoundedRectangle(
                cornerRadius: ActivityBarComponentLayout.cardCornerRadius,
                style: .continuous
            )
        )
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var aiWeeklyComparison: some View {
        let avg = aiDailyAvgLastWeek
        if avg > 0 {
            let today = visibleCodingAggregateStats(in: controller.codingStats.today).durationSeconds
            let ratio = today / avg
            let aboveAvg = ratio >= 1
            let pct = Int(((ratio - 1) * 100).rounded())

            HStack(spacing: 6) {
                Image(systemName: aboveAvg ? "arrow.up.right" : "arrow.down.right")
                    .font(PluginTypography.caption.font.weight(.semibold))
                    .foregroundStyle(aboveAvg ? theme.status.success : theme.text.tertiary)

                if pct == 0 {
                    Text(
                        localization.format(
                            "component.ai.dailyAverage.same",
                            defaultValue: "On par with your daily avg (%@)",
                            shortDuration(avg)
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(theme.text.secondary)
                } else {
                    let comparison = aboveAvg
                        ? localization.format(
                            "component.ai.dailyAverage.above",
                            defaultValue: "%d%% above your daily avg (%@)",
                            abs(pct),
                            shortDuration(avg)
                        )
                        : localization.format(
                            "component.ai.dailyAverage.below",
                            defaultValue: "%d%% below your daily avg (%@)",
                            abs(pct),
                            shortDuration(avg)
                        )
                    Text(comparison)
                        .font(.caption)
                        .foregroundStyle(theme.text.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
        }
    }

    private var aiDailyAvgLastWeek: TimeInterval {
        let today = dateKey(for: Date())
        let days = controller.codingStats
            .recentDays(count: 8)
            .filter { $0.date != today && visibleCodingAggregateStats(in: $0).durationSeconds > 0 }

        guard !days.isEmpty else {
            return 0
        }

        return days
            .map { visibleCodingAggregateStats(in: $0).durationSeconds }
            .reduce(0, +) / Double(days.count)
    }

    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localization.string("component.topApps.title", defaultValue: "Top Apps by Screen Time"))
                .font(PluginTypography.sectionTitle.font)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

            let apps = Array(selectedInputStats.topApps.prefix(5))
            if apps.isEmpty {
                Text(
                    controller.isTrackingEnabled
                        ? localization.string("component.topApps.empty", defaultValue: "No activity yet")
                        : localization.string("component.topApps.enableTracking", defaultValue: "Turn on tracking to rank your apps")
                )
                    .font(.subheadline)
                    .foregroundStyle(theme.text.secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
            } else {
                let maxTime = apps.first?.stats.screenTimeSeconds ?? 1
                ForEach(apps, id: \.name) { app in
                    appRow(name: app.name, stats: app.stats, maxScreenTime: maxTime)
                }
                .onAppear {
                    presentation.selectInitialApp(apps.first?.name)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func appRow(name: String, stats: ActivityBarAppStats, maxScreenTime: Double) -> some View {
        let isExpanded = presentation.expandedAppName == name

        return VStack(spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    presentation.expandedAppName = isExpanded ? nil : name
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.text.secondary)

                    Text(name)
                        .font(.body)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(ActivityBarFormatting.duration(stats.screenTimeSeconds))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(theme.text.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                let ratio = CGFloat(stats.screenTimeSeconds) / CGFloat(Swift.max(maxScreenTime, 1))
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.interaction.selection(theme.dataSeries.primary))
                    .frame(width: geo.size.width * ratio, height: 3)
            }
            .frame(height: 3)

            if isExpanded {
                HStack(spacing: 16) {
                    appDetailItem(icon: "keyboard", value: ActivityBarFormatting.decimal(stats.keystrokes))
                    appDetailItem(icon: "cursorarrow.click.2", value: ActivityBarFormatting.decimal(stats.pointerClicks))
                    appDetailItem(icon: "scroll", value: ActivityBarFormatting.decimal(stats.scrollEvents))
                }
                .padding(.top, 4)
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private func appDetailItem(icon: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(PluginTypography.caption.font)
                .foregroundStyle(theme.text.secondary)

            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.text.secondary)
                .lineLimit(1)
        }
    }

    private var statsDisclosure: some View {
        HStack {
            Button {
                statsExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(localization.string("component.trends.title", defaultValue: "Trends"))
                        .font(PluginTypography.sectionTitle.font)

                    Image(systemName: statsExpanded ? "chevron.down" : "chevron.forward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.text.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if statsExpanded {
                Spacer(minLength: 8)

                ForEach(ActivityBarTrendMode.allCases, id: \.self) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            presentation.trendMode = mode
                            hoveredDate = nil
                        }
                    } label: {
                        Text(mode.label(localization: localization))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(presentation.trendMode == mode ? theme.text.primary : theme.text.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var codingToolsChart: some View {
        let days = controller.codingStats.recentDays(count: chartRange.dayCount, endingAt: selectedDate)
        let compactMode = chartRange.dayCount > 7
        let dateLabels = days.map { chartLabel($0.date) }
        let hasData = days.contains { hasCodingStats(visibleCodingAggregateStats(in: $0)) }
        let maxMinutes = days
            .flatMap { day in
                Self.visibleCodingTools.map { tool in
                    toolStats(tool, in: day).durationSeconds / 60
                }
            }
            .max() ?? 0
        let yUpperBound = Swift.max(maxMinutes * 1.15, 1)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                rangePickerBar
                Spacer(minLength: 8)
                ForEach(Self.visibleCodingTools, id: \.rawValue) { tool in
                    legendDot(color: codingToolColor(tool), label: Self.codingToolLegendLabel(tool))
                }
            }
            .padding(.horizontal, 6)

            ZStack {
                Chart {
                    // `hasData ? days : []` keeps the content a plain ForEach (no
                    // `_ConditionalContent`, whose ChartContent conformance is macOS 27-only);
                    // an empty range draws nothing, exactly as the old `if hasData` did.
                    ForEach(hasData ? days : []) { day in
                        let d = chartLabel(day.date)
                        let isHovered = hoveredDate == d

                        ForEach(Self.visibleCodingTools, id: \.rawValue) { tool in
                            let label = Self.codingToolLegendLabel(tool)
                            let minutes = toolStats(tool, in: day).durationSeconds / 60

                            LineMark(x: .value("Date", d), y: .value("Minutes", minutes), series: .value("Tool", label))
                                .foregroundStyle(by: .value("Tool", label))
                                .interpolationMethod(.catmullRom)
                        }

                        // Unconditional marks; opacity/symbol size carry the hover state (the old
                        // if/else-if produced _ConditionalContent). The annotation body is a plain
                        // View, so its `if isHovered` is fine.
                        RuleMark(x: .value("Date", d))
                            .foregroundStyle(theme.text.tertiary.opacity(isHovered ? 0.45 : 0))
                            .lineStyle(StrokeStyle(dash: [4, 4]))
                            .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                if isHovered {
                                    VStack(spacing: 2) {
                                        Text(shortDate(day.date))
                                            .font(PluginTypography.caption.font)
                                            .foregroundStyle(theme.text.secondary)
                                        HStack(spacing: 6) {
                                            ForEach(Self.visibleCodingTools, id: \.rawValue) { tool in
                                                let minutes = toolStats(tool, in: day).durationSeconds / 60
                                                Text(shortDuration(minutes * 60))
                                                    .foregroundStyle(codingToolColor(tool))
                                            }
                                        }
                                        .font(PluginTypography.caption.font.weight(.semibold).monospacedDigit())
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(theme.surfaces.backplate, in: RoundedRectangle(cornerRadius: 4))
                                    .offset(y: 30)
                                }
                            }

                        ForEach(Self.visibleCodingTools, id: \.rawValue) { tool in
                            let minutes = toolStats(tool, in: day).durationSeconds / 60
                            chartPoint(
                                x: d,
                                y: minutes,
                                color: codingToolColor(tool),
                                size: hoverPointSize(isHovered: isHovered, compactMode: compactMode)
                            )
                        }
                    }
                }
                .chartForegroundStyleScale([
                    "Claude": Self.claudeColor,
                    "Cursor": codingToolColor(.cursor),
                    "Codex": Self.codexColor,
                ])
                .chartLegend(.hidden)
                .chartYScale(domain: 0...yUpperBound)
                .chartYAxis {
                    if hasData {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine()
                                .foregroundStyle(theme.surfaces.track)
                            AxisValueLabel {
                                if let minutes = value.as(Double.self) {
                                    Text(talkAxisLabel(minutes))
                                        .font(PluginTypography.caption.font)
                                        .foregroundStyle(theme.text.secondary)
                                }
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        AxisValueLabel {
                            if let label = value.as(String.self), !compactMode || shouldShowXLabel(label, in: dateLabels) {
                                Text(label)
                                    .font(PluginTypography.caption.font)
                                    .foregroundStyle(theme.text.secondary)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    if hasData {
                        chartHoverOverlay(proxy: proxy, labels: dateLabels, hoveredLabel: $hoveredDate)
                    }
                }

                if !hasData {
                    emptyChartMessage(localization.string("component.chart.emptyCoding", defaultValue: "No coding activity"))
                }
            }
            .frame(height: 120)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var weeklyChart: some View {
        let days = controller.inputStats.recentDays(count: chartRange.dayCount, endingAt: selectedDate)
        let compactMode = chartRange.dayCount > 7
        let dateLabels = days.map { chartLabel($0.date) }
        let hasData = days.contains { $0.totalInputs > 0 }
        let maxInputCount = days
            .map { day in
                Swift.max(day.keystrokes, Swift.max(day.pointerClicks, day.scrollEvents))
            }
            .max() ?? 0
        let yUpperBound = Swift.max(Double(maxInputCount) * 1.15, 1)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                rangePickerBar
                Spacer(minLength: 8)
                legendDot(color: theme.dataSeries.primary, label: localization.string("component.legend.keys", defaultValue: "Keys"))
                legendDot(color: theme.dataSeries.secondary, label: localization.string("component.legend.clicks", defaultValue: "Clicks"))
                legendDot(color: theme.dataSeries.tertiary, label: localization.string("component.legend.scrolls", defaultValue: "Scrolls"))
            }
            .padding(.horizontal, 6)

            ZStack {
                Chart {
                    // See codingToolsChart: `hasData ? days : []` avoids _ConditionalContent.
                    ForEach(hasData ? days : []) { day in
                        let d = chartLabel(day.date)
                        let isHovered = hoveredDate == d

                        LineMark(x: .value("Date", d), y: .value("Count", day.keystrokes), series: .value("Metric", "Keystrokes"))
                            .foregroundStyle(by: .value("Metric", "Keystrokes"))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Date", d), y: .value("Count", day.pointerClicks), series: .value("Metric", "Clicks"))
                            .foregroundStyle(by: .value("Metric", "Clicks"))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Date", d), y: .value("Count", day.scrollEvents), series: .value("Metric", "Scrolls"))
                            .foregroundStyle(by: .value("Metric", "Scrolls"))
                            .interpolationMethod(.catmullRom)

                        RuleMark(x: .value("Date", d))
                            .foregroundStyle(theme.text.tertiary.opacity(isHovered ? 0.45 : 0))
                            .lineStyle(StrokeStyle(dash: [4, 4]))
                            .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                if isHovered {
                                    VStack(spacing: 2) {
                                        Text(shortDate(day.date))
                                            .font(PluginTypography.caption.font)
                                            .foregroundStyle(theme.text.secondary)
                                        HStack(spacing: 6) {
                                            Text("\(day.keystrokes)").foregroundStyle(theme.dataSeries.primary)
                                            Text("\(day.pointerClicks)").foregroundStyle(theme.dataSeries.secondary)
                                            Text("\(day.scrollEvents)").foregroundStyle(theme.dataSeries.tertiary)
                                        }
                                        .font(PluginTypography.caption.font.weight(.semibold).monospacedDigit())
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(theme.surfaces.backplate, in: RoundedRectangle(cornerRadius: 4))
                                    .offset(y: 30)
                                }
                            }

                        chartPoint(x: d, y: Double(day.keystrokes), color: theme.dataSeries.primary, size: hoverPointSize(isHovered: isHovered, compactMode: compactMode))
                        chartPoint(x: d, y: Double(day.pointerClicks), color: theme.dataSeries.secondary, size: hoverPointSize(isHovered: isHovered, compactMode: compactMode))
                        chartPoint(x: d, y: Double(day.scrollEvents), color: theme.dataSeries.tertiary, size: hoverPointSize(isHovered: isHovered, compactMode: compactMode))
                    }
                }
                .chartForegroundStyleScale([
                    "Keystrokes": theme.dataSeries.primary,
                    "Clicks": theme.dataSeries.secondary,
                    "Scrolls": theme.dataSeries.tertiary,
                ])
                .chartLegend(.hidden)
                .chartYScale(domain: 0...yUpperBound)
                .chartYAxis {
                    if hasData {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine()
                                .foregroundStyle(theme.surfaces.track)
                            AxisValueLabel {
                                if let count = value.as(Double.self) {
                                    Text(ActivityBarFormatting.count(Int(count)))
                                        .font(PluginTypography.caption.font)
                                        .foregroundStyle(theme.text.secondary)
                                }
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        AxisValueLabel {
                            if let label = value.as(String.self), !compactMode || shouldShowXLabel(label, in: dateLabels) {
                                Text(label)
                                    .font(PluginTypography.caption.font)
                                    .foregroundStyle(theme.text.secondary)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    if hasData {
                        chartHoverOverlay(proxy: proxy, labels: dateLabels, hoveredLabel: $hoveredDate)
                    }
                }

                if !hasData {
                    emptyChartMessage(localization.string("component.chart.emptyInput", defaultValue: "No input activity"))
                }
            }
            .frame(height: 120)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var screenTimeSection: some View {
        let days = controller.inputStats.recentDays(count: chartRange.dayCount, endingAt: selectedDate)
        let compactMode = chartRange.dayCount > 7
        let labels = days.map { chartLabel($0.date) }

        return VStack(alignment: .leading, spacing: 6) {
            Text(localization.string("component.screenTime.title", defaultValue: "Screen Time"))
                .font(PluginTypography.sectionTitle.font)

            Chart {
                ForEach(days) { day in
                    let d = chartLabel(day.date)
                    let isHovered = hoveredScreenTimeDate == d
                    BarMark(
                        x: .value("Date", d),
                        y: .value("Duration", day.screenTimeSeconds / 60)
                    )
                    .foregroundStyle(theme.dataSeries.primary)
                    .cornerRadius(2)
                    .annotation(position: .top, spacing: 2) {
                        if isHovered, day.screenTimeSeconds > 0 {
                            Text(shortDuration(day.screenTimeSeconds))
                                .font(PluginTypography.caption.font.weight(.semibold).monospacedDigit())
                                .foregroundStyle(theme.text.primary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(theme.surfaces.backplate, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                        .foregroundStyle(theme.surfaces.track)
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) {
                            Text(talkAxisLabel(minutes))
                                .font(PluginTypography.caption.font)
                                .foregroundStyle(theme.text.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    AxisGridLine()
                        .foregroundStyle(theme.surfaces.track)
                    AxisValueLabel {
                        if let label = value.as(String.self), !compactMode || shouldShowXLabel(label, in: labels) {
                            Text(label)
                                .font(PluginTypography.caption.font)
                                .foregroundStyle(theme.text.secondary)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                chartHoverOverlay(proxy: proxy, labels: labels, hoveredLabel: $hoveredScreenTimeDate)
            }
            .frame(height: 60)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var rangePickerBar: some View {
        HStack(spacing: 0) {
            ForEach(ActivityBarChartRange.allCases, id: \.self) { range in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        chartRange = range
                        hoveredDate = nil
                        hoveredScreenTimeDate = nil
                    }
                } label: {
                    Text(range.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .foregroundStyle(chartRange == range ? theme.text.primary : theme.text.secondary)
                        .background(
                            chartRange == range ? theme.surfaces.controlHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            Text(label)
                .font(.caption)
                .foregroundStyle(theme.text.secondary)
                .lineLimit(1)
        }
    }

    private func emptyChartMessage(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(theme.text.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func chartPoint(x: String, y: Double, color: Color, size: CGFloat) -> some ChartContent {
        PointMark(x: .value("Date", x), y: .value("Value", y))
            .foregroundStyle(color)
            .symbolSize(size)
    }

    /// Hover-driven point size, kept unconditional (0 hides the mark on compact
    /// non-hovered days) so the Chart body has no `_ConditionalContent` — whose
    /// `ChartContent` conformance is macOS 27-only and fails the 27-SDK build at
    /// a 14.0 deployment target.
    private func hoverPointSize(isHovered: Bool, compactMode: Bool) -> CGFloat {
        if isHovered { return 30 }
        return compactMode ? 0 : 12
    }

    private func chartHoverOverlay(proxy: ChartProxy, labels: [String], hoveredLabel: Binding<String?>) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let plotFrame = proxy.plotFrame else {
                            return
                        }

                        let frame = geo[plotFrame]
                        let x = location.x - frame.origin.x
                        var closest: String?
                        var closestDist: CGFloat = .infinity

                        for label in labels {
                            if let position = proxy.position(forX: label) {
                                let distance = abs(position - x)
                                if distance < closestDist {
                                    closestDist = distance
                                    closest = label
                                }
                            }
                        }

                        hoveredLabel.wrappedValue = closest
                    case .ended:
                        hoveredLabel.wrappedValue = nil
                    }
                }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.surfaces.track)
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    private func codingToolRows(for day: ActivityBarCodingDailyStats) -> [CodingToolDisplayRow] {
        let knownRows = Self.visibleCodingTools.compactMap { tool -> CodingToolDisplayRow? in
            let stats = toolStats(tool, in: day)
            guard hasCodingStats(stats) else {
                return nil
            }

            return displayRow(for: tool, stats: stats)
        }

        if !knownRows.isEmpty {
            return knownRows
        }

        let aggregateStats = ActivityBarProjectStats(
            durationSeconds: day.durationSeconds,
            wordCount: day.wordCount,
            toolCallCount: day.toolCallCount
        )
        guard hasCodingStats(aggregateStats) else {
            return []
        }

        return [
            CodingToolDisplayRow(
                id: "ai-tools",
                name: "AI Tools",
                duration: aggregateStats.durationSeconds,
                detail: codingDetailText(for: aggregateStats),
                tint: Self.codexColor,
                systemImage: "terminal",
                iconSize: 13
            )
        ]
    }

    private func displayRow(for tool: ActivityBarCodingTool, stats: ActivityBarProjectStats) -> CodingToolDisplayRow {
        switch tool {
        case .claudeCode:
            return CodingToolDisplayRow(
                id: tool.rawValue,
                name: tool.rawValue,
                duration: stats.durationSeconds,
                detail: codingDetailText(for: stats),
                tint: Self.claudeColor,
                systemImage: "sparkles",
                iconSize: 12
            )
        case .cursor:
            return CodingToolDisplayRow(
                id: tool.rawValue,
                name: tool.rawValue,
                duration: stats.durationSeconds,
                detail: codingDetailText(for: stats),
                tint: codingToolColor(.cursor),
                systemImage: "cube.fill",
                iconSize: 13
            )
        case .codex:
            return CodingToolDisplayRow(
                id: tool.rawValue,
                name: tool.rawValue,
                duration: stats.durationSeconds,
                detail: codingDetailText(for: stats),
                tint: Self.codexColor,
                systemImage: "terminal",
                iconSize: 13
            )
        }
    }

    private func toolStats(_ tool: ActivityBarCodingTool, in day: ActivityBarCodingDailyStats) -> ActivityBarProjectStats {
        if let stats = day.perTool[tool.rawValue] {
            return stats
        }

        if day.perTool.isEmpty, tool == .claudeCode {
            return ActivityBarProjectStats(
                durationSeconds: day.durationSeconds,
                wordCount: day.wordCount,
                toolCallCount: day.toolCallCount
            )
        }

        return ActivityBarProjectStats()
    }

    private func visibleCodingAggregateStats(in day: ActivityBarCodingDailyStats) -> ActivityBarProjectStats {
        let visibleToolStats = Self.visibleCodingTools.map { toolStats($0, in: day) }
        if visibleToolStats.contains(where: { hasCodingStats($0) }) {
            let counts = visibleToolStats.reduce(ActivityBarProjectStats()) { result, stats in
                ActivityBarProjectStats(
                    wordCount: result.wordCount + stats.wordCount,
                    toolCallCount: result.toolCallCount + stats.toolCallCount
                )
            }
            return ActivityBarProjectStats(
                durationSeconds: day.durationSeconds,
                wordCount: counts.wordCount,
                toolCallCount: counts.toolCallCount
            )
        }

        guard day.perTool.isEmpty else {
            return ActivityBarProjectStats()
        }

        return ActivityBarProjectStats(
            durationSeconds: day.durationSeconds,
            wordCount: day.wordCount,
            toolCallCount: day.toolCallCount
        )
    }

    private func hasCodingStats(_ stats: ActivityBarProjectStats) -> Bool {
        stats.durationSeconds > 0 || stats.wordCount > 0 || stats.toolCallCount > 0
    }

    private func codingDetailText(for stats: ActivityBarProjectStats) -> String {
        localization.format(
            "component.ai.detail",
            defaultValue: "%@ words · %@ tools",
            ActivityBarFormatting.decimal(stats.wordCount),
            ActivityBarFormatting.decimal(stats.toolCallCount)
        )
    }

    private var displayDateString: String {
        if isViewingToday {
            return localization.string("component.date.today", defaultValue: "Today")
        }

        if presentation.selectedDateOffset == -1 {
            return localization.string("component.date.yesterday", defaultValue: "Yesterday")
        }

        return ActivityBarFormatting.monthDay(selectedDate)
    }

    private func shortDate(_ dateString: String) -> String {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
        else {
            return dateString
        }

        return ActivityBarFormatting.monthDay(date)
    }

    private func chartLabel(_ dateString: String) -> String {
        if chartRange.dayCount <= 7 {
            return shortDate(dateString)
        }

        let parts = dateString.split(separator: "-")
        guard parts.count == 3 else {
            return dateString
        }

        let day = Int(parts[2]) ?? 0
        if day == 1 {
            return shortDate(dateString)
        }

        return "\(day)"
    }

    private func shouldShowXLabel(_ label: String, in allLabels: [String]) -> Bool {
        guard let index = allLabels.firstIndex(of: label) else {
            return false
        }

        let step = chartRange.dayCount <= 14 ? 2 : 5
        return index % step == 0 || index == allLabels.count - 1
    }

    private func talkAxisLabel(_ minutes: Double) -> String {
        if minutes >= 60 {
            return "\(Int(minutes / 60))h"
        }

        return "\(Int(minutes))m"
    }

    private func shortDuration(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }

        return "\(secs)s"
    }

    private func dateKey(for date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private struct CodingToolDisplayRow: Identifiable {
        let id: String
        let name: String
        let duration: TimeInterval
        let detail: String?
        let tint: Color
        let systemImage: String
        let iconSize: CGFloat
    }
}
