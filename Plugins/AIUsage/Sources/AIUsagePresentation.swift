import Foundation
import MacToolsPluginKit

struct AIUsageStrings {
    let localization: PluginLocalization

    func text(_ key: String, _ fallback: String) -> String {
        localization.string(key, defaultValue: fallback)
    }

    func failure(_ error: AIUsageFailure, provider: AIUsageProvider) -> String {
        switch error {
        case .signInRequired:
            text("status.signIn", "请先在客户端登录，再刷新")
        case .unsupportedLogin:
            text("status.unsupported", "需要订阅账号登录，API Key 不支持额度查询")
        case .credentialUnreadable:
            text("status.unreadable", "无法读取登录文件，请检查客户端配置")
        case .keychainPermission:
            text("status.keychain", "请在设置中授权读取 Claude 钥匙串")
        case .expired:
            text("status.expired", "登录已过期或无访问权限，请在客户端重新登录")
        case .network:
            text("status.network", "连接失败，稍后自动重试")
        case .rateLimited:
            text("status.rateLimited", "请求受限，已暂停并等待重试")
        case .server:
            text("status.server", "服务暂不可用，稍后自动重试")
        case .invalidResponse:
            text("status.invalid", "服务未返回可用额度")
        }
    }

    func windowTitle(_ window: AIUsageWindow) -> String {
        if let duration = window.duration, duration > 0 {
            if duration == 604_800 { return text("window.weekly", "周剩余额度") }
            let hours = duration / 3600
            return localization.format("window.hours", defaultValue: "剩余额度（%@ 小时周期）", hours.formatted(.number.precision(.fractionLength(0...1)).locale(PluginRuntimeLocalization.locale)))
        }
        return window.id == "weekly" ? text("window.weekly", "周剩余额度") : text("window.primary", "剩余额度")
    }

    func reset(_ date: Date?, now: Date, compact: Bool = false) -> String {
        guard let date else { return text("reset.unknown", "重置时间未知") }
        guard date > now else { return text("reset.pending", "等待额度更新") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = date.timeIntervalSince(now) >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        var calendar = Calendar.current
        calendar.locale = PluginRuntimeLocalization.locale
        formatter.calendar = calendar
        let duration = formatter.string(from: max(60, date.timeIntervalSince(now))) ?? "—"
        if compact { return duration }
        return localization.format("reset.countdown", defaultValue: "%@ 后重置", duration)
    }

    func updated(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return text("updated.now", "刚刚更新") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = PluginRuntimeLocalization.locale
        formatter.unitsStyle = .short
        return localization.format("updated.relative", defaultValue: "更新于 %@", formatter.localizedString(for: date, relativeTo: now))
    }

    func paceTitle(_ pace: AIUsagePace) -> String {
        switch (pace.period, pace.level) {
        case (.weekly, .steady): text("pace.steady", "周用量平稳")
        case (.weekly, .ahead): text("pace.ahead", "周用量偏快")
        case (.weekly, .exhausted): text("pace.exhausted", "周额度用尽")
        case (.fiveHour, .steady): text("pace.fiveHour.steady", "5 小时额度消耗平稳")
        case (.fiveHour, .ahead): text("pace.fiveHour.ahead", "5 小时额度消耗偏快")
        case (.fiveHour, .exhausted): text("pace.fiveHour.exhausted", "5 小时额度用尽")
        }
    }

    func paceDescription(_ pace: AIUsagePace) -> String {
        switch (pace.period, pace.level) {
        case (.weekly, .steady):
            text("pace.steady.description", "本周额度消耗处于正常节奏。")
        case (.weekly, .ahead):
            text("pace.ahead.description", "本周额度消耗偏快，照此节奏可能在重置前用完。")
        case (.weekly, .exhausted):
            text("pace.exhausted.description", "本周额度已用完，请等待重置。")
        case (.fiveHour, .steady):
            text("pace.fiveHour.steady.description", "当前 5 小时周期内，额度消耗处于正常节奏。")
        case (.fiveHour, .ahead):
            text("pace.fiveHour.ahead.description", "当前 5 小时周期内，额度消耗偏快，照此节奏可能在重置前用完。")
        case (.fiveHour, .exhausted):
            text("pace.fiveHour.exhausted.description", "当前 5 小时周期的额度已用完，请等待重置。")
        }
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.scale(1).precision(.fractionLength(0)).locale(PluginRuntimeLocalization.locale))
    }
}

struct AIUsageMenuBarPresentation: Equatable {
    struct Segment: Equatable {
        let provider: AIUsageProvider
        let value: String
        let isStale: Bool
    }
    let segments: [Segment]
    let tooltip: String

    static func make(providers: [AIUsageProvider], states: [AIUsageProvider: AIUsageProviderState], interval: TimeInterval,
                     now: Date, strings: AIUsageStrings) -> Self {
        let segments = providers.map { provider in
            let state = states[provider]
            return Segment(provider: provider,
                           value: state?.snapshot?.windows.first.map { AIUsageStrings.percent($0.remainingPercent) } ?? "—",
                           isStale: state?.isStale(at: now, interval: interval) == true)
        }
        let tooltip = segments.map { segment in
            let state = states[segment.provider]
            let status = state?.failure.map { strings.failure($0, provider: segment.provider) }
                ?? (segment.isStale ? strings.text("status.stale", "上次数据") : strings.text("usage.remaining", "剩余额度"))
            return "\(segment.provider.title) · \(segment.value) · \(status)"
        }.joined(separator: "\n")
        return Self(segments: segments, tooltip: tooltip)
    }
}
