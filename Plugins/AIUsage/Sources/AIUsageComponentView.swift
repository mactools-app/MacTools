import SwiftUI
import MacToolsPluginKit

struct AIUsageComponentView: View {
    @ObservedObject var model: AIUsageViewModel
    let strings: AIUsageStrings
    let assets: AIUsageProviderAssets
    let openSettings: () -> Void
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        if model.panelVisible {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                // Snapshot changes between ticks must use the current observation time.
                content(now: Date())
            }
        } else {
            content(now: Date())
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.preferences.enabledProviders.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3").font(.title2)
                    Text(strings.text("providers.empty", "尚未启用服务")).font(PluginTypography.detail.font)
                    Button(strings.text("open.settings", "打开设置"), action: openSettings)
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .foregroundStyle(theme.text.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(Array(model.preferences.enabledProviders.enumerated()), id: \.element) { index, provider in
                    if index > 0 { Divider() }
                    providerView(provider, now: now)
                }
            }
        }
        .foregroundStyle(theme.text.primary)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PluginComponentCardBackground())
    }

    private func providerView(_ provider: AIUsageProvider, now: Date) -> some View {
        let state = model.states[provider] ?? AIUsageProviderState()
        let stale = state.isStale(at: now, interval: Double(model.preferences.refreshInterval))
        let pace = AIUsagePace.make(state: state, now: now, refreshInterval: Double(model.preferences.refreshInterval))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: assets.image(for: provider)).resizable().scaledToFit()
                    .frame(width: 17, height: 17).padding(5)
                    .foregroundStyle(theme.text.primary)
                    .background(theme.surfaces.chip, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                Text(provider.title).font(PluginTypography.sectionTitle.font).lineLimit(1)
                if let plan = state.snapshot?.plan, !plan.isEmpty {
                    Text(plan.capitalized).font(PluginTypography.caption.font).foregroundStyle(theme.text.secondary)
                        .lineLimit(1).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(theme.surfaces.chip, in: Capsule())
                }
                Spacer(minLength: 0)
                if let pace { paceBadge(pace) }
                if stale, let snapshot = state.snapshot {
                    Circle().fill(theme.status.warning)
                        .frame(width: 5, height: 5)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                        .help(staleDataDescription(snapshot, now: now))
                        .accessibilityLabel(staleDataDescription(snapshot, now: now))
                }
            }
            if let snapshot = state.snapshot {
                Grid(alignment: .center, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(snapshot.windows.enumerated()), id: \.element.id) { index, window in
                        GridRow {
                            percentage(window, provider: provider, stale: stale, primary: index == 0)
                                .frame(width: 76, height: index == 0 ? 40 : 20, alignment: .center)
                            progress(window, provider: provider, stale: stale, height: index == 0 ? 6 : 3)
                                .gridCellUnsizedAxes(.vertical)
                        }
                        GridRow {
                            Text(strings.windowTitle(window))
                                .frame(width: 76, alignment: .center)
                            Text(strings.reset(window.resetsAt, now: now))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .help(resetHelp(window))
                        }
                        .font(PluginTypography.caption.font)
                        .foregroundStyle(theme.text.secondary)
                        .lineLimit(1)
                        if index < snapshot.windows.count - 1 {
                            Color.clear.frame(height: 0).gridCellUnsizedAxes(.horizontal)
                        }
                    }
                }
                if let failure = state.failure {
                    Text(strings.failure(failure, provider: provider)).font(PluginTypography.caption.font)
                        .foregroundStyle(theme.status.warning).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(model.preferences.canReadCredentials(for: provider)
                     ? state.failure.map { strings.failure($0, provider: provider) } ?? strings.text("status.waiting", "正在等待额度数据…")
                     : strings.text("status.accessOff", "请在设置中开启登录文件或钥匙串访问"))
                    .font(PluginTypography.detail.font).foregroundStyle(theme.text.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func paceBadge(_ pace: AIUsagePace) -> some View {
        let color: Color = switch pace.level {
        case .steady: theme.text.secondary
        case .ahead: theme.status.warning
        case .exhausted: theme.status.critical
        }
        return Text(strings.paceTitle(pace))
            .font(PluginTypography.caption.font.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(pace.level == .steady ? theme.surfaces.chip : theme.interaction.subtleTint(color), in: Capsule())
            .help(strings.paceDescription(pace))
            .accessibilityLabel(strings.paceTitle(pace))
            .accessibilityValue(strings.paceDescription(pace))
    }

    private func percentage(_ window: AIUsageWindow, provider: AIUsageProvider, stale: Bool, primary: Bool) -> some View {
        PluginMetricValue(
            window.remainingPercent.formatted(.number.precision(.fractionLength(0)).locale(PluginRuntimeLocalization.locale)),
            unit: "%",
            isProminent: primary,
            unitColor: theme.text.secondary
        )
        .foregroundStyle(tint(window, provider: provider, stale: stale))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings.windowTitle(window))
        .accessibilityValue(AIUsageStrings.percent(window.remainingPercent))
    }

    private func staleDataDescription(_ snapshot: AIUsageSnapshot, now: Date) -> String {
        strings.text("status.dataStale", "当前显示上次额度数据") + "\n" + strings.updated(snapshot.fetchedAt, now: now)
    }

    private func progress(_ window: AIUsageWindow, provider: AIUsageProvider, stale: Bool, height: CGFloat) -> some View {
        GeometryReader { geometry in
            Capsule().fill(theme.surfaces.track)
                .overlay(alignment: .leading) {
                    Capsule().fill(tint(window, provider: provider, stale: stale))
                        .frame(width: geometry.size.width * window.remainingPercent / 100)
                }
        }
        .frame(height: height)
        .accessibilityLabel(strings.text("usage.remaining", "剩余额度"))
        .accessibilityValue(AIUsageStrings.percent(window.remainingPercent))
    }

    private func tint(_ window: AIUsageWindow, provider: AIUsageProvider, stale: Bool) -> Color {
        let color = window.remainingPercent <= 5 ? theme.status.critical
            : window.remainingPercent <= 20 ? theme.status.warning : accent(for: provider)
        return color.opacity(stale ? 0.5 : 1)
    }

    private func accent(for provider: AIUsageProvider) -> Color {
        provider == .codex ? theme.dataSeries.primary : theme.dataSeries.quaternary
    }

    private func resetHelp(_ window: AIUsageWindow) -> String {
        window.resetsAt?.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(PluginRuntimeLocalization.locale)) ?? strings.text("reset.unknown", "重置时间未知")
    }
}
