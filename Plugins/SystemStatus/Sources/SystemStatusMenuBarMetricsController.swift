import AppKit
import Combine
import MacToolsPluginKit
import SwiftUI

struct SystemStatusMenuBarMetricBlock: Equatable {
    let kind: SystemStatusMetricKind
    let label: String
    let symbolName: String
    let valueKinds: [SystemStatusMenuBarValueKind]
    let values: [String]
    let horizontalValue: String
    let widthReservationValues: [String]
    let style: SystemStatusMenuBarLayout?
    let valueArrangement: SystemStatusMenuBarValueArrangement

    init(
        kind: SystemStatusMetricKind,
        label: String,
        symbolName: String? = nil,
        valueKinds: [SystemStatusMenuBarValueKind]? = nil,
        values: [String],
        horizontalValue: String? = nil,
        widthReservationValues: [String] = [],
        style: SystemStatusMenuBarLayout? = nil,
        valueArrangement: SystemStatusMenuBarValueArrangement = .automatic
    ) {
        self.kind = kind
        self.label = label
        self.symbolName = symbolName ?? kind.symbolName
        self.valueKinds = valueKinds ?? SystemStatusMenuBarValueKind.defaultValues(for: kind)
        self.values = values
        self.horizontalValue = horizontalValue ?? values.joined(separator: " ")
        self.widthReservationValues = widthReservationValues
        self.style = style
        self.valueArrangement = valueArrangement
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind
            && lhs.label == rhs.label
            && lhs.symbolName == rhs.symbolName
            && lhs.valueKinds == rhs.valueKinds
            && lhs.values == rhs.values
            && lhs.horizontalValue == rhs.horizontalValue
            && lhs.style == rhs.style
            && lhs.valueArrangement == rhs.valueArrangement
    }
}

enum SystemStatusMenuBarMinimalIdentity {
    static func identity(
        for kind: SystemStatusMetricKind,
        valueKinds: [SystemStatusMenuBarValueKind]
    ) -> String? {
        switch kind {
        case .cpu:
            return "C"
        case .gpu:
            return "G"
        case .memory:
            return "M"
        case .battery:
            return "B"
        case .network:
            return valueKinds.contains(where: { $0 == .download || $0 == .upload }) ? nil : "N"
        case .disk:
            return valueKinds.contains(.read) || valueKinds.contains(.write) ? nil : "D"
        case .topProcesses:
            return nil
        }
    }
}

enum SystemStatusMenuBarResolvedValueArrangement: Equatable {
    case stacked
    case inline
}

extension SystemStatusMenuBarValueArrangement {
    func resolved(
        for style: SystemStatusMenuBarLayout,
        metric _: SystemStatusMetricKind
    ) -> SystemStatusMenuBarResolvedValueArrangement {
        switch self {
        case .stacked:
            return .stacked
        case .inline:
            return .inline
        case .automatic:
            switch style {
            case .horizontal:
                return .inline
            case .vertical, .minimal:
                return .stacked
            }
        }
    }
}

enum SystemStatusMenuBarMetricsFormatter {
    static func blocks(
        snapshot: SystemStatusSnapshot,
        kinds: [SystemStatusMetricKind],
        localization: PluginLocalization? = nil
    ) -> [SystemStatusMenuBarMetricBlock] {
        blocks(
            snapshot: snapshot,
            items: kinds.map {
                SystemStatusMenuBarMetricPreference(
                    kind: $0,
                    isVisible: true,
                    values: SystemStatusMenuBarValueKind.defaultValues(for: $0)
                )
            },
            localization: localization
        )
    }

    static func blocks(
        snapshot: SystemStatusSnapshot,
        items: [SystemStatusMenuBarMetricPreference],
        localization: PluginLocalization? = nil
    ) -> [SystemStatusMenuBarMetricBlock] {
        items.filter(\.isVisible).compactMap { item in
            block(for: item, snapshot: snapshot, localization: localization)
        }
    }

    static func text(
        snapshot: SystemStatusSnapshot,
        kinds: [SystemStatusMetricKind],
        localization: PluginLocalization? = nil
    ) -> String {
        blocks(snapshot: snapshot, kinds: kinds, localization: localization)
            .map { "\($0.label) \($0.horizontalValue)" }
            .joined(separator: " | ")
    }

    static func tooltip(
        snapshot: SystemStatusSnapshot,
        items: [SystemStatusMenuBarMetricPreference],
        localization: PluginLocalization? = nil
    ) -> String {
        let title = localized(
            "metadata.title",
            defaultValue: "System Status",
            localization: localization
        )
        let details = blocks(snapshot: snapshot, items: items, localization: localization)
            .map { "\($0.label) \($0.horizontalValue)" }
        guard !details.isEmpty else {
            return title
        }

        return ([title] + details).joined(separator: "\n")
    }

    private static func block(
        for item: SystemStatusMenuBarMetricPreference,
        snapshot: SystemStatusSnapshot,
        localization: PluginLocalization?
    ) -> SystemStatusMenuBarMetricBlock? {
        guard item.kind != .topProcesses else {
            return nil
        }

        let availableValues = SystemStatusMenuBarValueKind.availableValues(for: item.kind)
        let valueKinds = item.values
            .filter { availableValues.contains($0) }
            .prefix(2)
        let normalizedValueKinds = Array(valueKinds).isEmpty
            ? SystemStatusMenuBarValueKind.defaultValues(for: item.kind)
            : Array(valueKinds)
        let values = normalizedValueKinds.map {
            value($0, for: item.kind, snapshot: snapshot, localization: localization)
        }

        return SystemStatusMenuBarMetricBlock(
            kind: item.kind,
            label: label(for: item.kind, localization: localization),
            valueKinds: normalizedValueKinds,
            values: values,
            widthReservationValues: normalizedValueKinds.map {
                widthReservationValue(
                    for: $0,
                    metric: item.kind,
                    localization: localization
                )
            },
            style: item.style,
            valueArrangement: item.valueArrangement
        )
    }

    private static func label(
        for kind: SystemStatusMetricKind,
        localization: PluginLocalization?
    ) -> String {
        switch kind {
        case .cpu:
            return localized("menuBar.compact.metric.cpu", defaultValue: "CPU", localization: localization)
        case .gpu:
            return localized("menuBar.compact.metric.gpu", defaultValue: "GPU", localization: localization)
        case .memory:
            return localized("menuBar.compact.metric.memory", defaultValue: "RAM", localization: localization)
        case .disk:
            return localized("menuBar.compact.metric.disk", defaultValue: "DSK", localization: localization)
        case .battery:
            return localized("menuBar.compact.metric.battery", defaultValue: "BAT", localization: localization)
        case .network:
            return localized("menuBar.compact.metric.network", defaultValue: "NET", localization: localization)
        case .topProcesses:
            return ""
        }
    }

    private static func value(
        _ value: SystemStatusMenuBarValueKind,
        for metric: SystemStatusMetricKind,
        snapshot: SystemStatusSnapshot,
        localization: PluginLocalization?
    ) -> String {
        switch (metric, value) {
        case (.cpu, .usage):
            return compactPercent(snapshot.cpu.usage)
        case (.cpu, .temperature):
            return compactTemperature(snapshot.cpu.temperatureCelsius) ?? "—"
        case (.cpu, .power):
            return compactPower(snapshot.cpu.cpuPowerWatts)
        case (.cpu, .load):
            return compactLoad(snapshot.cpu.loadAverage1Minute, localization: localization)
        case (.gpu, .usage):
            return snapshot.gpu.isAvailable ? compactPercent(snapshot.gpu.usage) : "—"
        case (.gpu, .temperature):
            return snapshot.gpu.isAvailable
                ? compactTemperature(snapshot.gpu.temperatureCelsius) ?? "—"
                : "—"
        case (.memory, .usage):
            return compactPercent(snapshot.memory.usage)
        case (.memory, .used):
            return compactAmount(snapshot.memory.usedBytes)
        case (.memory, .swap):
            return prefixed(
                localized("menuBar.compact.prefix.swap", defaultValue: "S", localization: localization),
                amount: snapshot.memory.swapUsedBytes
            )
        case (.disk, .free):
            return compactAmount(freeDiskBytes(snapshot.disk))
        case (.disk, .usage):
            return compactPercent(snapshot.disk.usage)
        case (.disk, .read):
            return prefixed(
                localized("menuBar.compact.prefix.read", defaultValue: "R", localization: localization),
                amount: snapshot.disk.readBytesPerSecond
            )
        case (.disk, .write):
            return prefixed(
                localized("menuBar.compact.prefix.write", defaultValue: "W", localization: localization),
                amount: snapshot.disk.writeBytesPerSecond
            )
        case (.disk, .activity):
            return prefixed("↕", amount: combinedDiskBytesPerSecond(snapshot.disk))
        case (.network, .download):
            return prefixed("↓", amount: snapshot.network.downloadBytesPerSecond)
        case (.network, .upload):
            return prefixed("↑", amount: snapshot.network.uploadBytesPerSecond)
        case (.network, .throughput):
            return prefixed("↕", amount: combinedNetworkBytesPerSecond(snapshot.network))
        case (.battery, .level):
            return snapshot.battery.isAvailable ? compactPercent(snapshot.battery.level) : "—"
        case (.battery, .power):
            return snapshot.battery.isAvailable ? compactBatteryPower(snapshot.battery.batteryPowerWatts) : "—"
        case (.battery, .timeRemaining):
            return snapshot.battery.isAvailable
                ? compactBatteryTime(snapshot.battery, localization: localization)
                : "—"
        case (.battery, .temperature):
            return snapshot.battery.isAvailable
                ? compactTemperature(snapshot.battery.temperatureCelsius) ?? "—"
                : "—"
        case (.battery, .state):
            return snapshot.battery.isAvailable
                ? compactBatteryState(snapshot.battery.state, localization: localization)
                : "—"
        default:
            return "—"
        }
    }

    private static func compactPercent(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "—"
        }

        return "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    private static func compactTemperature(_ celsius: Double?) -> String? {
        guard let celsius, celsius.isFinite else {
            return nil
        }

        return "\(Int(celsius.rounded()))°"
    }

    private static func compactPower(_ watts: Double?) -> String {
        guard let watts, watts.isFinite else {
            return "—"
        }

        let magnitude = abs(watts)
        if magnitude < 0.05 {
            return "0W"
        }
        if magnitude < 10 {
            return "\(localizedDecimal(magnitude))W"
        }
        return "\(Int(magnitude.rounded()))W"
    }

    private static func compactLoad(
        _ load: Double?,
        localization: PluginLocalization?
    ) -> String {
        guard let load, load.isFinite else {
            return "—"
        }
        let prefix = localized(
            "menuBar.compact.prefix.load",
            defaultValue: "L",
            localization: localization
        )
        return load < 10
            ? "\(prefix)\(localizedDecimal(load))"
            : "\(prefix)\(Int(load.rounded()))"
    }

    private static func compactTime(
        _ minutes: Int?,
        localization: PluginLocalization?
    ) -> String {
        guard let minutes, minutes >= 0 else {
            return "—"
        }
        if minutes < 60 {
            return localization?.format(
                "menuBar.compact.time.minutesFormat",
                defaultValue: "%dm",
                minutes
            ) ?? "\(minutes)m"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 {
            return localization?.format(
                "menuBar.compact.time.hoursFormat",
                defaultValue: "%dh",
                hours
            ) ?? "\(hours)h"
        }
        return localization?.format(
            "menuBar.compact.time.hoursMinutesFormat",
            defaultValue: "%dh%dm",
            hours,
            remainder
        ) ?? "\(hours)h\(remainder)m"
    }

    private static func compactBatteryTime(
        _ battery: SystemStatusBatterySnapshot,
        localization: PluginLocalization?
    ) -> String {
        if battery.timeRemainingMinutes != nil {
            return compactTime(battery.timeRemainingMinutes, localization: localization)
        }

        switch battery.state {
        case .acPower, .charged:
            return compactBatteryState(battery.state, localization: localization)
        case .charging, .unplugged:
            return "…"
        case .unavailable, .unknown:
            return "—"
        }
    }

    private static func compactAmount(_ bytes: UInt64?) -> String {
        guard let bytes else {
            return "—"
        }

        let units = ["B", "K", "M", "G", "T", "P", "E"]
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        while true {
            if value < 10, unitIndex > 0 {
                let rounded = (value * 10).rounded() / 10
                if rounded.rounded() == rounded {
                    return "\(Int(rounded))\(units[unitIndex])"
                }
                return "\(localizedDecimal(rounded))\(units[unitIndex])"
            }

            let rounded = value.rounded()
            if rounded >= 100, unitIndex < units.count - 1 {
                value /= 1024
                unitIndex += 1
                continue
            }

            return "\(Int(rounded))\(units[unitIndex])"
        }
    }

    private static func combinedDiskBytesPerSecond(_ disk: SystemStatusDiskSnapshot) -> UInt64? {
        guard disk.readBytesPerSecond != nil || disk.writeBytesPerSecond != nil else {
            return nil
        }

        let (total, overflow) = (disk.readBytesPerSecond ?? 0).addingReportingOverflow(
            disk.writeBytesPerSecond ?? 0
        )
        return overflow ? UInt64.max : total
    }

    private static func combinedNetworkBytesPerSecond(_ network: SystemStatusNetworkSnapshot) -> UInt64? {
        guard network.downloadBytesPerSecond != nil || network.uploadBytesPerSecond != nil else {
            return nil
        }

        let (total, overflow) = (network.downloadBytesPerSecond ?? 0).addingReportingOverflow(
            network.uploadBytesPerSecond ?? 0
        )
        return overflow ? UInt64.max : total
    }

    private static func freeDiskBytes(_ disk: SystemStatusDiskSnapshot) -> UInt64? {
        guard let used = disk.usedBytes, let total = disk.totalBytes else {
            return nil
        }
        return total >= used ? total - used : 0
    }

    private static func prefixed(_ prefix: String, amount: UInt64?) -> String {
        guard let amount else {
            return "—"
        }
        return "\(prefix)\(compactAmount(amount))"
    }

    private static func compactBatteryPower(_ watts: Double?) -> String {
        guard let watts, watts.isFinite else {
            return "—"
        }

        let magnitude = abs(watts)
        if magnitude < 0.05 {
            return "0W"
        }

        let value = Int(magnitude.rounded())
        return watts < 0 ? "+\(value)W" : "−\(value)W"
    }

    private static func compactBatteryState(
        _ state: SystemStatusBatteryState,
        localization: PluginLocalization?
    ) -> String {
        switch state {
        case .charging:
            return localized(
                "menuBar.compact.batteryState.charging",
                defaultValue: "⚡",
                localization: localization
            )
        case .charged:
            return localized(
                "menuBar.compact.batteryState.charged",
                defaultValue: "FULL",
                localization: localization
            )
        case .unplugged:
            return localized(
                "menuBar.compact.batteryState.unplugged",
                defaultValue: "BAT",
                localization: localization
            )
        case .acPower:
            return localized(
                "menuBar.compact.batteryState.acPower",
                defaultValue: "AC",
                localization: localization
            )
        case .unavailable, .unknown:
            return "—"
        }
    }

    private static func localized(
        _ key: String,
        defaultValue: String,
        localization: PluginLocalization?
    ) -> String {
        localization?.string(key, defaultValue: defaultValue) ?? defaultValue
    }

    static func localizedDecimal(
        _ value: Double,
        locale: Locale = PluginRuntimeLocalization.locale
    ) -> String {
        String(
            format: "%.1f",
            locale: locale,
            value
        )
    }

    private static func widthReservationValue(
        for value: SystemStatusMenuBarValueKind,
        metric: SystemStatusMetricKind,
        localization: PluginLocalization?
    ) -> String {
        let decimalSample = localizedDecimal(9.9)
        switch value {
        case .usage, .level:
            return "100%"
        case .temperature:
            return "999°"
        case .power:
            return metric == .battery ? "+999W" : "999W"
        case .load:
            return "\(localized("menuBar.compact.prefix.load", defaultValue: "L", localization: localization))99.9"
        case .used, .free:
            return "\(decimalSample)T"
        case .swap:
            return "\(localized("menuBar.compact.prefix.swap", defaultValue: "S", localization: localization))\(decimalSample)T"
        case .read:
            return "\(localized("menuBar.compact.prefix.read", defaultValue: "R", localization: localization))\(decimalSample)G"
        case .write:
            return "\(localized("menuBar.compact.prefix.write", defaultValue: "W", localization: localization))\(decimalSample)G"
        case .activity, .throughput:
            return "↕\(decimalSample)G"
        case .download:
            return "↓\(decimalSample)G"
        case .upload:
            return "↑\(decimalSample)G"
        case .timeRemaining:
            return localization?.format(
                "menuBar.compact.time.hoursMinutesFormat",
                defaultValue: "%dh%dm",
                99,
                59
            ) ?? "99h59m"
        case .state:
            return [
                compactBatteryState(.charged, localization: localization),
                compactBatteryState(.unplugged, localization: localization),
                compactBatteryState(.acPower, localization: localization),
            ].max { lhs, rhs in lhs.count < rhs.count } ?? "FULL"
        }
    }
}

final class SystemStatusMenuBarMetricsView: NSView {
    private enum Layout {
        static let topInset: CGFloat = 1
        static let bottomInset: CGFloat = 1
        static let horizontalInset: CGFloat = 4
        static let interMetricSpacing: CGFloat = 4
        static let minimumMetricWidth: CGFloat = 24
        static let compactIconValueSpacing: CGFloat = 3
        static let compactIconSize: CGFloat = 10
        static let minimalIdentitySpacing: CGFloat = 3
    }

    var menuBarLayout: SystemStatusMenuBarLayout = .horizontal {
        didSet {
            guard menuBarLayout != oldValue else {
                return
            }

            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var blocks: [SystemStatusMenuBarMetricBlock] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth(for: blocks), height: NSStatusBar.system.thickness)
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let metricWidths = blocks.map(metricWidth)
        var x = Layout.horizontalInset

        for index in blocks.indices {
            let width = metricWidths[index]
            draw(blocks[index], in: NSRect(x: x, y: 0, width: width, height: bounds.height))
            x += width

            guard index < blocks.index(before: blocks.endIndex) else {
                continue
            }

            x += Layout.interMetricSpacing
        }
    }

    private var labelFont: NSFont {
        NSFont.systemFont(ofSize: 7, weight: .regular)
    }

    private var valueFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    }

    private var fullHeightInlineValueFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    }

    private var verticalValueFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
    }

    private var minimalIdentityFont: NSFont {
        NSFont.systemFont(ofSize: 8, weight: .semibold)
    }

    private func draw(_ block: SystemStatusMenuBarMetricBlock, in rect: NSRect) {
        let style = block.style ?? menuBarLayout
        let arrangement = block.valueArrangement.resolved(
            for: style,
            metric: block.kind
        )
        switch (style, arrangement) {
        case (.horizontal, .inline):
            drawStandard(block, in: rect)
        case (.horizontal, .stacked):
            drawLabeledStacked(block, in: rect)
        case (.vertical, .inline):
            drawCompactInline(block, in: rect)
        case (.vertical, .stacked):
            drawVertical(block, in: rect)
        case (.minimal, .inline):
            drawMinimalInline(block, in: rect)
        case (.minimal, .stacked):
            drawMinimal(block, in: rect)
        }
    }

    private func drawStandard(_ block: SystemStatusMenuBarMetricBlock, in rect: NSRect) {
        let label = attributedText(
            block.label,
            font: labelFont,
            color: .labelColor,
            kern: 0.2
        )
        let value = attributedText(
            block.horizontalValue,
            font: valueFont,
            color: .labelColor
        )

        let labelSize = label.size()
        let valueSize = value.size()
        let labelRect = NSRect(
            x: rect.minX + (rect.width - labelSize.width) / 2,
            y: Layout.topInset,
            width: labelSize.width,
            height: labelSize.height
        )
        let valueRect = NSRect(
            x: rect.minX + (rect.width - valueSize.width) / 2,
            y: max(Layout.topInset + labelSize.height - 1, rect.maxY - valueSize.height - Layout.bottomInset),
            width: valueSize.width,
            height: valueSize.height
        )

        label.draw(in: labelRect)
        value.draw(in: valueRect)
    }

    private func drawVertical(_ block: SystemStatusMenuBarMetricBlock, in rect: NSRect) {
        let lines = verticalValues(for: block).map {
            attributedText($0, font: verticalValueFont, color: .labelColor)
        }
        let lineSizes = lines.map { $0.size() }
        let lineHeights = lines.map { $0.size().height }
        let totalHeight = lineHeights.reduce(0, +)
        let contentWidth = Layout.compactIconSize + Layout.compactIconValueSpacing
            + compactStackedValueColumnWidth(for: block)
        let contentX = rect.midX - contentWidth / 2

        if let image = NSImage(systemSymbolName: block.symbolName, accessibilityDescription: block.label) {
            image.isTemplate = true
            image.draw(
                in: NSRect(
                    x: contentX,
                    y: rect.midY - Layout.compactIconSize / 2,
                    width: Layout.compactIconSize,
                    height: Layout.compactIconSize
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }

        var y = rect.midY - totalHeight / 2

        for (line, lineSize) in zip(lines, lineSizes) {
            line.draw(in: NSRect(
                x: contentX + Layout.compactIconSize + Layout.compactIconValueSpacing,
                y: y,
                width: lineSize.width,
                height: lineSize.height
            ))
            y += lineSize.height
        }
    }

    private func drawLabeledStacked(_ block: SystemStatusMenuBarMetricBlock, in rect: NSRect) {
        let label = attributedText(block.label, font: labelFont, color: .labelColor, kern: 0.2)
        let lines = stackedTexts(for: block)
        let lineSizes = lines.map { $0.size() }
        let totalHeight = lineSizes.reduce(CGFloat(0)) { $0 + $1.height }
        let labelSize = label.size()
        let valueWidth = stackedReservationWidth(for: block)
        let contentWidth = labelSize.width + Layout.compactIconValueSpacing + valueWidth
        let contentX = rect.midX - contentWidth / 2

        label.draw(in: NSRect(
            x: contentX,
            y: rect.midY - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        ))

        var y = rect.midY - totalHeight / 2
        for (line, size) in zip(lines, lineSizes) {
            line.draw(in: NSRect(
                x: contentX + labelSize.width + Layout.compactIconValueSpacing,
                y: y,
                width: size.width,
                height: size.height
            ))
            y += size.height
        }
    }

    private func drawCompactInline(_ block: SystemStatusMenuBarMetricBlock, in rect: NSRect) {
        let value = attributedText(
            block.horizontalValue,
            font: fullHeightInlineValueFont,
            color: .labelColor
        )
        let valueSize = value.size()
        let contentWidth = Layout.compactIconSize
            + Layout.compactIconValueSpacing
            + inlineReservationWidth(for: block)
        let contentX = rect.midX - contentWidth / 2

        drawIcon(block, x: contentX, in: rect)
        value.draw(in: NSRect(
            x: contentX + Layout.compactIconSize + Layout.compactIconValueSpacing,
            y: rect.midY - valueSize.height / 2,
            width: valueSize.width,
            height: valueSize.height
        ))
    }

    private func drawMinimalInline(_ block: SystemStatusMenuBarMetricBlock, in rect: NSRect) {
        let identity = minimalIdentityText(for: block)
        let identityWidth = identity?.size().width ?? 0
        let identitySpacing = identity == nil ? 0 : Layout.minimalIdentitySpacing
        let value = attributedText(
            block.horizontalValue,
            font: fullHeightInlineValueFont,
            color: .labelColor
        )
        let valueSize = value.size()
        let contentWidth = identityWidth + identitySpacing + inlineReservationWidth(for: block)
        let contentX = rect.midX - contentWidth / 2

        if let identity {
            let size = identity.size()
            identity.draw(in: NSRect(
                x: contentX,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        }
        value.draw(in: NSRect(
            x: contentX + identityWidth + identitySpacing,
            y: rect.midY - valueSize.height / 2,
            width: valueSize.width,
            height: valueSize.height
        ))
    }

    private func drawMinimal(_ block: SystemStatusMenuBarMetricBlock, in rect: NSRect) {
        let lines = verticalValues(for: block).map {
            attributedText($0, font: verticalValueFont, color: .labelColor)
        }
        let lineSizes = lines.map { $0.size() }
        let totalHeight = lineSizes.reduce(CGFloat(0)) { $0 + $1.height }
        let identity = SystemStatusMenuBarMinimalIdentity.identity(
            for: block.kind,
            valueKinds: block.valueKinds
        )
        let identityText = identity.map {
            attributedText($0, font: minimalIdentityFont, color: .labelColor)
        }
        let identityWidth = identityText?.size().width ?? 0
        let identitySpacing = identity == nil ? 0 : Layout.minimalIdentitySpacing
        let valueWidth = max(
            lineSizes.map(\.width).max() ?? 0,
            minimalReservationWidth(for: block)
        )
        let contentWidth = identityWidth + identitySpacing + valueWidth
        let contentX = rect.midX - contentWidth / 2

        if let identityText {
            let size = identityText.size()
            identityText.draw(in: NSRect(
                x: contentX,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        }

        var y = rect.midY - totalHeight / 2
        for (line, size) in zip(lines, lineSizes) {
            line.draw(in: NSRect(
                x: contentX + identityWidth + identitySpacing,
                y: y,
                width: size.width,
                height: size.height
            ))
            y += size.height
        }
    }

    private func metricWidth(_ block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        let style = block.style ?? menuBarLayout
        let arrangement = block.valueArrangement.resolved(
            for: style,
            metric: block.kind
        )
        switch (style, arrangement) {
        case (.horizontal, .inline):
            return horizontalMetricWidth(block)
        case (.horizontal, .stacked):
            return labeledStackedMetricWidth(block)
        case (.vertical, .inline):
            return compactInlineMetricWidth(block)
        case (.vertical, .stacked):
            return verticalMetricWidth(block)
        case (.minimal, .inline):
            return minimalInlineMetricWidth(block)
        case (.minimal, .stacked):
            return minimalMetricWidth(block)
        }
    }

    private func horizontalMetricWidth(_ block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        let labelWidth = attributedText(
            block.label,
            font: labelFont,
            color: .labelColor
        ).size().width
        let valueWidth = attributedText(
            widthReservationValues(for: block).joined(separator: " "),
            font: valueFont,
            color: .labelColor
        ).size().width
        return ceil(max(Layout.minimumMetricWidth, labelWidth, valueWidth))
    }

    private func verticalMetricWidth(_ block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        return ceil(max(
            Layout.minimumMetricWidth,
            Layout.compactIconSize + Layout.compactIconValueSpacing
                + compactStackedValueColumnWidth(for: block)
        ))
    }

    func compactStackedValueColumnWidth(for block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        max(verticalValueColumnWidth, stackedReservationWidth(for: block))
    }

    private func labeledStackedMetricWidth(_ block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        let labelWidth = attributedText(
            block.label,
            font: labelFont,
            color: .labelColor
        ).size().width
        return ceil(max(
            Layout.minimumMetricWidth,
            labelWidth + Layout.compactIconValueSpacing + stackedReservationWidth(for: block)
        ))
    }

    private func compactInlineMetricWidth(_ block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        ceil(max(
            Layout.minimumMetricWidth,
            Layout.compactIconSize + Layout.compactIconValueSpacing
                + inlineReservationWidth(for: block)
        ))
    }

    private func minimalMetricWidth(_ block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        let identityWidth = SystemStatusMenuBarMinimalIdentity.identity(
            for: block.kind,
            valueKinds: block.valueKinds
        ).map {
            attributedText($0, font: minimalIdentityFont, color: .labelColor).size().width
                + Layout.minimalIdentitySpacing
        } ?? 0
        return ceil(max(
            Layout.minimumMetricWidth,
            identityWidth + minimalReservationWidth(for: block)
        ))
    }

    private func minimalInlineMetricWidth(_ block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        let identityWidth = minimalIdentityText(for: block).map {
            $0.size().width + Layout.minimalIdentitySpacing
        } ?? 0
        return ceil(max(
            Layout.minimumMetricWidth,
            identityWidth + inlineReservationWidth(for: block)
        ))
    }

    private func minimalReservationWidth(for block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        widthReservationValues(for: block).reduce(CGFloat(0)) { width, value in
            max(
                width,
                attributedText(value, font: verticalValueFont, color: .labelColor).size().width
            )
        }
    }

    private var verticalValueColumnWidth: CGFloat {
        ["100%", "999°", "↓9.9M", "↑9.9M", "↕9.9M", "+999W"].reduce(CGFloat(0)) { width, value in
            max(
                width,
                attributedText(value, font: verticalValueFont, color: .labelColor).size().width
            )
        }
    }

    private func widthReservationValues(for block: SystemStatusMenuBarMetricBlock) -> [String] {
        if block.widthReservationValues.count == block.valueKinds.count {
            return block.widthReservationValues
        }
        return block.valueKinds.map { kind in
            switch kind {
            case .usage, .level:
                return "100%"
            case .temperature:
                return "999°"
            case .power:
                return block.kind == .battery ? "+999W" : "999W"
            case .load:
                return "L99.9"
            case .used, .free:
                return "9.9T"
            case .swap:
                return "S9.9T"
            case .read:
                return "R9.9G"
            case .write:
                return "W9.9G"
            case .activity, .throughput:
                return "↕9.9G"
            case .download:
                return "↓9.9G"
            case .upload:
                return "↑9.9G"
            case .timeRemaining:
                return "99h59m"
            case .state:
                return "FULL"
            }
        }
    }

    private func drawIcon(
        _ block: SystemStatusMenuBarMetricBlock,
        x: CGFloat,
        in rect: NSRect
    ) {
        guard let image = NSImage(
            systemSymbolName: block.symbolName,
            accessibilityDescription: block.label
        ) else {
            return
        }
        image.isTemplate = true
        image.draw(
            in: NSRect(
                x: x,
                y: rect.midY - Layout.compactIconSize / 2,
                width: Layout.compactIconSize,
                height: Layout.compactIconSize
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func minimalIdentityText(
        for block: SystemStatusMenuBarMetricBlock
    ) -> NSAttributedString? {
        SystemStatusMenuBarMinimalIdentity.identity(
            for: block.kind,
            valueKinds: block.valueKinds
        ).map {
            attributedText($0, font: minimalIdentityFont, color: .labelColor)
        }
    }

    private func stackedTexts(
        for block: SystemStatusMenuBarMetricBlock
    ) -> [NSAttributedString] {
        verticalValues(for: block).map {
            attributedText($0, font: verticalValueFont, color: .labelColor)
        }
    }

    private func inlineReservationWidth(for block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        attributedText(
            widthReservationValues(for: block).joined(separator: " "),
            font: fullHeightInlineValueFont,
            color: .labelColor
        ).size().width
    }

    private func stackedReservationWidth(for block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        widthReservationValues(for: block).reduce(CGFloat(0)) { width, value in
            max(
                width,
                attributedText(value, font: verticalValueFont, color: .labelColor).size().width
            )
        }
    }

    private func verticalValues(for block: SystemStatusMenuBarMetricBlock) -> [String] {
        let values = Array(block.values.prefix(2))
        return values.isEmpty ? ["—"] : values
    }

    private func preferredWidth(for blocks: [SystemStatusMenuBarMetricBlock]) -> CGFloat {
        guard !blocks.isEmpty else {
            return 0
        }

        let metricsWidth = blocks.reduce(CGFloat(0)) { partialResult, block in
            partialResult + metricWidth(block)
        }
        let spacingCount = CGFloat(max(blocks.count - 1, 0))
        let spacingWidth = spacingCount * Layout.interMetricSpacing
        return ceil(metricsWidth + spacingWidth + Layout.horizontalInset * 2)
    }

    private func attributedText(
        _ string: String,
        font: NSFont,
        color: NSColor,
        kern: CGFloat = 0
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .kern: kern
            ]
        )
    }
}

@MainActor
final class SystemStatusMenuBarMetricsController: NSObject {
    private static let autosaveName = "MacTools.SystemStatus.MenuBarMetrics"

    private let viewModel: SystemStatusViewModel
    private let settingsController: SystemStatusSettingsController
    private let localization: PluginLocalization
    var requestConfigurationPresentation: (() -> Void)?
    var requestDashboardPresentation: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private var statusItem: NSStatusItem?
    private var metricsView: SystemStatusMenuBarMetricsView?
    private var isActive = false
    private lazy var localPopoverController = SystemStatusMenuBarPopoverController(
        viewModel: viewModel,
        settingsController: settingsController,
        localization: localization,
        onConfigure: { [weak self] in
            self?.requestConfigurationPresentation?()
        }
    )

    init(
        viewModel: SystemStatusViewModel,
        settingsController: SystemStatusSettingsController,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.viewModel = viewModel
        self.settingsController = settingsController
        self.localization = localization
        super.init()
        observeState()
    }

    func activate() {
        isActive = true
        render(
            configuration: settingsController.configuration,
            snapshot: viewModel.snapshot
        )
    }

    func stop() {
        isActive = false
        viewModel.stopMenuBar()
        removeStatusItem()
    }

    func presentSystemStatus() {
        let button = statusItem?.button
        switch SystemStatusShortcutPresentationPolicy.destination(
            hasMenuBarButton: button != nil
        ) {
        case .menuBarOverview:
            guard let button else { return }
            localPopoverController.toggle(relativeTo: button)
        case .dashboard:
            requestDashboardPresentation?()
        }
    }

    private func observeState() {
        PluginRuntimeLocalization.source.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewModel.objectWillChange.send()
                self.render(configuration: self.settingsController.configuration, snapshot: self.viewModel.snapshot)
            }
        }.store(in: &cancellables)
        settingsController.$configuration
            .removeDuplicates()
            .combineLatest(viewModel.$snapshot.removeDuplicates())
            .sink { [weak self] configuration, snapshot in
                self?.render(configuration: configuration, snapshot: snapshot)
            }
            .store(in: &cancellables)
    }

    private func render(
        configuration: SystemStatusConfiguration,
        snapshot: SystemStatusSnapshot
    ) {
        guard isActive else {
            removeStatusItem()
            return
        }

        let items = configuration.menuBarItems.filter(\.isVisible)
        guard !items.isEmpty else {
            viewModel.stopMenuBar()
            removeStatusItem()
            return
        }

        viewModel.startMenuBar()
        let blocks = SystemStatusMenuBarMetricsFormatter.blocks(
            snapshot: snapshot,
            items: items,
            localization: localization
        )
        guard !blocks.isEmpty else {
            viewModel.stopMenuBar()
            removeStatusItem()
            return
        }

        let statusItem = ensureStatusItem()

        guard let button = statusItem.button else {
            return
        }

        let metricsView = ensureMetricsView(in: button)
        metricsView.blocks = blocks
        statusItem.length = metricsView.intrinsicContentSize.width
        metricsView.frame = button.bounds
        button.toolTip = SystemStatusMenuBarMetricsFormatter.tooltip(
            snapshot: snapshot,
            items: items,
            localization: localization
        )
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem {
            return statusItem
        }

        PluginPresentationSafety.prepareForWindowOrdering()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        if let button = item.button {
            button.image = nil
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusItem = item
        return item
    }

    private func ensureMetricsView(in button: NSStatusBarButton) -> SystemStatusMenuBarMetricsView {
        if let metricsView {
            return metricsView
        }

        let view = SystemStatusMenuBarMetricsView()
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            view.topAnchor.constraint(equalTo: button.topAnchor),
            view.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        metricsView = view
        return view
    }

    private func removeStatusItem() {
        guard let statusItem else {
            return
        }

        localPopoverController.hide()
        PluginPresentationSafety.prepareForWindowOrdering()
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        metricsView = nil
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApplication.shared.currentEvent
        let isContextMenu = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.option) == true)

        if isContextMenu, let event {
            NSMenu.popUpContextMenu(contextMenu(), with: event, for: sender)
            return
        }

        localPopoverController.toggle(relativeTo: sender)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: localization.string("menuBar.action.openDashboard", defaultValue: "打开仪表盘"),
            action: #selector(openDashboard),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: localization.string("menuBar.action.customize", defaultValue: "自定义指标…"),
            action: #selector(openConfiguration),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: localization.string(
                "topProcesses.openActivityMonitor",
                defaultValue: "打开“活动监视器”"
            ),
            action: #selector(openActivityMonitor),
            keyEquivalent: ""
        ).target = self
        return menu
    }

    @objc
    private func openDashboard() {
        requestDashboardPresentation?()
    }

    @objc
    private func openConfiguration() {
        requestConfigurationPresentation?()
    }

    @objc
    private func openActivityMonitor() {
        SystemStatusProcessActions.openActivityMonitor()
    }
}

enum SystemStatusShortcutPresentationPolicy {
    enum Destination: Equatable {
        case menuBarOverview
        case dashboard
    }

    static func destination(hasMenuBarButton: Bool) -> Destination {
        hasMenuBarButton ? .menuBarOverview : .dashboard
    }
}

@MainActor
enum SystemStatusMenuBarPopoverPresentationPolicy {
    static let behavior: NSPopover.Behavior = .applicationDefined

    static func containsPresentedWindow(
        _ window: NSWindow,
        popoverWindow: NSWindow?,
        detailWindow: NSWindow?
    ) -> Bool {
        window === popoverWindow || window === detailWindow
    }
}

enum SystemStatusMenuBarPopoverLifecyclePolicy {
    enum ToggleAction: Equatable {
        case present
        case dismiss
    }

    static func toggleAction(hasTrackedPopover: Bool) -> ToggleAction {
        hasTrackedPopover ? .dismiss : .present
    }

    static func shouldFinishDismissal(
        trackedPopoverIdentifier: ObjectIdentifier?,
        closedPopoverIdentifier: ObjectIdentifier
    ) -> Bool {
        trackedPopoverIdentifier == closedPopoverIdentifier
    }
}

enum SystemStatusMenuBarPopoverLayout {
    static let width: CGFloat = 430
    static let padding: CGFloat = 12
    static let headerHeight: CGFloat = 30
    static let spacing: CGFloat = 10

    // AppKit replaces this first-frame fallback with the live safe-area insets.
    static let fallbackInsets = NSEdgeInsets(top: 13, left: 13, bottom: 13, right: 13)

    static func contentSize(for configuration: SystemStatusConfiguration) -> NSSize {
        NSSize(
            width: width,
            height: padding * 2 + headerHeight + spacing + SystemStatusComponentLayout.contentHeight(
                for: configuration.visiblePanelMetricKinds,
                processLimit: configuration.processLimit
            )
        )
    }
}

@MainActor
final class SystemStatusMenuBarPopoverContentController<Content: View>: NSViewController {
    private let hostingController: NSHostingController<SystemStatusLocalizedRoot<Content>>

    init(rootView: Content) {
        hostingController = NSHostingController(rootView: SystemStatusLocalizedRoot(content: rootView))
        // The popover owns its size before positioning; SwiftUI must not resize it afterward.
        hostingController.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = SystemStatusMenuBarPopoverBackgroundView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hostingController)
        let content = hostingController.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            content.topAnchor.constraint(equalTo: safeArea.topAnchor),
            content.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor)
        ])
    }
}

private struct SystemStatusLocalizedRoot<Content: View>: View {
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let content: Content

    init(content: Content) { self.content = content }

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        content
            .environment(\.locale, locale)
            .environment(\.layoutDirection, locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }
}

private final class SystemStatusMenuBarPopoverBackgroundView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // This is the system component theme's panel surface, including the native arrow.
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath.fill(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class SystemStatusMenuBarPopoverController: NSObject, NSPopoverDelegate {
    private enum DetailLayout {
        static let width: CGFloat = 360
        static let minimumHeight: CGFloat = 330
        static let panelSpacing: CGFloat = 8
        static let screenMargin: CGFloat = 8
    }

    private let viewModel: SystemStatusViewModel
    private let settingsController: SystemStatusSettingsController
    private let localization: PluginLocalization
    private let onConfigure: () -> Void
    private var popover: NSPopover?
    private weak var statusItemButton: NSStatusBarButton?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?
    private var anchorFrameObserver: NSObjectProtocol?
    private var contentSizeObservation: AnyCancellable?
    private var localeSubscription: AnyCancellable?
    private var contentSize = NSSize.zero
    private var safeAreaInsets = SystemStatusMenuBarPopoverLayout.fallbackInsets
    private lazy var detailPanelController = SystemStatusMenuBarDetailPanelController(
        viewModel: viewModel,
        settingsController: settingsController,
        localization: localization,
        width: DetailLayout.width,
        minimumHeight: DetailLayout.minimumHeight,
        panelSpacing: DetailLayout.panelSpacing,
        screenMargin: DetailLayout.screenMargin
    )

    init(
        viewModel: SystemStatusViewModel,
        settingsController: SystemStatusSettingsController,
        localization: PluginLocalization,
        onConfigure: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.settingsController = settingsController
        self.localization = localization
        self.onConfigure = onConfigure
        super.init()
        localeSubscription = PluginRuntimeLocalization.source.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshPopoverLocalization() }
        }
    }

    isolated deinit {
        removeDismissMonitors()
        viewModel.returnToBackground(from: .menuBarPopover)
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if SystemStatusMenuBarPopoverLifecyclePolicy.toggleAction(
            hasTrackedPopover: popover != nil
        ) == .dismiss {
            hide()
            return
        }

        let popover = NSPopover()
        popover.behavior = SystemStatusMenuBarPopoverPresentationPolicy.behavior
        popover.animates = true
        popover.delegate = self
        popover.hasFullSizeContent = true
        popover.contentViewController = SystemStatusMenuBarPopoverContentController(
            rootView: SystemStatusMenuBarPopoverView(
                viewModel: viewModel,
                settingsController: settingsController,
                localization: localization,
                onMetricDetail: { [weak self] kind in
                    guard let self else { return }
                    self.detailPanelController.toggle(
                        kind: kind,
                        relativeTo: self.popover?.contentViewController?.view.window
                    )
                },
                onConfigure: { [weak self] in
                    self?.hide()
                    self?.onConfigure()
                }
            )
        )
        self.popover = popover
        statusItemButton = button
        safeAreaInsets = SystemStatusMenuBarPopoverLayout.fallbackInsets
        contentSizeObservation = settingsController.$configuration
            .map { SystemStatusMenuBarPopoverLayout.contentSize(for: $0) }
            .removeDuplicates()
            .sink { [weak self] size in
                self?.contentSize = size
                self?.applyContentSize()
            }
        // Seed both frames before show() so AppKit centers using the final width.
        popover.contentViewController?.view.setFrameSize(popover.contentSize)
        viewModel.startForeground(for: .menuBarPopover)
        PluginPresentationSafety.prepareForWindowOrdering()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        refreshPopoverLocalization()
        detailPanelController.setHostWindow(popover.contentViewController?.view.window)
        installDismissMonitors()
    }

    func hide() {
        viewModel.returnToBackground(from: .menuBarPopover)
        detailPanelController.hide()
        popover?.performClose(nil)
        removeDismissMonitors()
    }

    func popoverDidShow(_ notification: Notification) {
        guard let shownPopover = notification.object as? NSPopover, shownPopover === popover,
              let view = shownPopover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let insets = view.safeAreaInsets
        if insets.top > 0 || insets.left > 0 || insets.bottom > 0 || insets.right > 0 {
            safeAreaInsets = insets
            applyContentSize()
        }
    }

    private func applyContentSize() {
        guard let popover else { return }
        let size = NSSize(
            width: contentSize.width + safeAreaInsets.left + safeAreaInsets.right,
            height: contentSize.height + safeAreaInsets.top + safeAreaInsets.bottom
        )
        guard popover.contentSize != size else { return }
        popover.contentSize = size
    }

    private func refreshPopoverLocalization() {
        guard let window = popover?.contentViewController?.view.window else { return }
        window.title = localization.string("metadata.title", defaultValue: "系统状态")
        window.setAccessibilityTitle(window.title)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover else {
            return
        }
        let closedPopoverIdentifier = ObjectIdentifier(closedPopover)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard SystemStatusMenuBarPopoverLifecyclePolicy.shouldFinishDismissal(
                trackedPopoverIdentifier: self.popover.map(ObjectIdentifier.init),
                closedPopoverIdentifier: closedPopoverIdentifier
            ) else {
                return
            }
            self.detailPanelController.hide()
            self.viewModel.returnToBackground(from: .menuBarPopover)
            self.popover = nil
            self.statusItemButton = nil
            self.removeDismissMonitors()
        }
    }

    private func installDismissMonitors() {
        if anchorFrameObserver == nil, let button = statusItemButton {
            button.postsFrameChangedNotifications = true
            anchorFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let button = self.statusItemButton,
                          let popover = self.popover, popover.isShown else { return }
                    popover.positioningRect = button.bounds
                }
            }
        }
        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]

        if localEventMonitor == nil {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) {
                [weak self] event in
                self?.handleLocalMouseEvent(event) ?? event
            }
        }

        if globalEventMonitor == nil {
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) {
                [weak self] event in
                let location = event.locationInWindow
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.statusItemButtonScreenFrame?.contains(location) == true {
                        return
                    }
                    self.hide()
                }
            }
        }

        if appActivationObserver == nil {
            appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard !Self.isCurrentApplicationActivationNotification(notification) else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.hide()
                }
            }
        }
    }

    private func removeDismissMonitors() {
        contentSizeObservation = nil
        if let anchorFrameObserver {
            NotificationCenter.default.removeObserver(anchorFrameObserver)
            self.anchorFrameObserver = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    private func handleLocalMouseEvent(_ event: NSEvent) -> NSEvent {
        guard popover?.isShown == true else {
            removeDismissMonitors()
            return event
        }

        if let eventWindow = event.window,
           SystemStatusMenuBarPopoverPresentationPolicy.containsPresentedWindow(
               eventWindow,
               popoverWindow: popover?.contentViewController?.view.window,
               detailWindow: detailPanelController.presentedWindow
           ) {
            return event
        }

        if isEventInsideStatusItemButton(event) {
            return event
        }

        hide()
        return event
    }

    private func isEventInsideStatusItemButton(_ event: NSEvent) -> Bool {
        guard
            let statusItemButton,
            event.window === statusItemButton.window
        else {
            return false
        }
        let point = statusItemButton.convert(event.locationInWindow, from: nil)
        return statusItemButton.bounds.contains(point)
    }

    private var statusItemButtonScreenFrame: NSRect? {
        guard let statusItemButton, let window = statusItemButton.window else {
            return nil
        }
        let frameInWindow = statusItemButton.convert(statusItemButton.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    nonisolated private static func isCurrentApplicationActivationNotification(
        _ notification: Notification
    ) -> Bool {
        guard
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else {
            return false
        }
        return application.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}

private struct SystemStatusMenuBarPopoverView: View {
    private typealias Layout = SystemStatusMenuBarPopoverLayout

    @ObservedObject var viewModel: SystemStatusViewModel
    @ObservedObject var settingsController: SystemStatusSettingsController
    let localization: PluginLocalization
    let onMetricDetail: (SystemStatusMetricKind) -> Void
    let onConfigure: () -> Void

    @Environment(\.pluginComponentTheme) private var theme
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale
        VStack(alignment: .leading, spacing: Layout.spacing) {
            header

            SystemStatusComponentView(
                viewModel: viewModel,
                settingsController: settingsController,
                localization: localization,
                onMetricDetail: onMetricDetail
            )
        }
        .padding(Layout.padding)
        .frame(width: Layout.width, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(localization.string("metadata.title", defaultValue: "系统状态"))
            .font(PluginTypography.sectionTitle.font)
            .foregroundStyle(theme.text.primary)

            Spacer(minLength: 8)

            Button(action: onConfigure) {
                Image(systemName: "slider.horizontal.3")
                    .font(PluginTypography.detail.font.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help(localization.string("menuBar.action.customize", defaultValue: "自定义指标…"))
            .accessibilityLabel(
                localization.string("menuBar.action.customize", defaultValue: "自定义指标…")
            )
        }
        .frame(height: Layout.headerHeight)
    }
}

private final class SystemStatusMenuBarDetailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SystemStatusMenuBarDetailPanelController {
    private let viewModel: SystemStatusViewModel
    private let settingsController: SystemStatusSettingsController
    private let localization: PluginLocalization
    private let width: CGFloat
    private let minimumHeight: CGFloat
    private let panelSpacing: CGFloat
    private let screenMargin: CGFloat
    private weak var hostWindow: NSWindow?
    private var panelWindow: SystemStatusMenuBarDetailPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var localeSubscription: AnyCancellable?
    private(set) var selectedKind: SystemStatusMetricKind?

    var presentedWindow: NSWindow? {
        panelWindow
    }

    init(
        viewModel: SystemStatusViewModel,
        settingsController: SystemStatusSettingsController,
        localization: PluginLocalization,
        width: CGFloat,
        minimumHeight: CGFloat,
        panelSpacing: CGFloat,
        screenMargin: CGFloat
    ) {
        self.viewModel = viewModel
        self.settingsController = settingsController
        self.localization = localization
        self.width = width
        self.minimumHeight = minimumHeight
        self.panelSpacing = panelSpacing
        self.screenMargin = screenMargin
        localeSubscription = PluginRuntimeLocalization.source.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshPanelLocalization() }
        }
    }

    func setHostWindow(_ window: NSWindow?) {
        hostWindow = window
    }

    func toggle(kind: SystemStatusMetricKind, relativeTo window: NSWindow?) {
        if selectedKind == kind, panelWindow?.isVisible == true {
            hide()
            return
        }

        hostWindow = window ?? hostWindow
        show(kind: kind)
    }

    func hide() {
        panelWindow?.orderOut(nil)
        panelWindow = nil
        hostingView = nil
        selectedKind = nil
    }

    private func show(kind: SystemStatusMetricKind) {
        guard let hostWindow, hostWindow.isVisible else {
            return
        }

        let rootView = AnyView(
            SystemStatusLocalizedRoot(content: SystemStatusMenuBarDetailPanelView(
                viewModel: viewModel,
                settingsController: settingsController,
                kind: kind,
                localization: localization,
                onDismiss: { [weak self] in self?.hide() }
            )
            .frame(width: width))
        )
        let panel = panelWindow ?? makePanel()
        let hostedView: NSHostingView<AnyView>
        if let existing = hostingView, panel.contentView === existing {
            existing.rootView = rootView
            hostedView = existing
        } else {
            let newHostingView = NSHostingView(rootView: rootView)
            panel.contentView = newHostingView
            hostingView = newHostingView
            hostedView = newHostingView
        }

        let fittingHeight = max(hostedView.fittingSize.height, minimumHeight)
        let visibleFrame = hostWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? hostWindow.frame
        let availableFrame = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        let height = min(fittingHeight, availableFrame.height)
        let frame = detailFrame(
            hostFrame: hostWindow.frame,
            size: CGSize(width: width, height: height),
            availableFrame: availableFrame
        )

        panel.setFrame(frame, display: true)
        panel.title = kind.title(localization: localization)
        panel.setAccessibilityTitle(panel.title)
        panel.level = NSWindow.Level(rawValue: hostWindow.level.rawValue + 1)
        panel.appearance = hostWindow.effectiveAppearance
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.orderFrontRegardless()
        panelWindow = panel
        selectedKind = kind
    }

    private func refreshPanelLocalization() {
        guard let panelWindow, let selectedKind else { return }
        panelWindow.title = selectedKind.title(localization: localization)
        panelWindow.setAccessibilityTitle(panelWindow.title)
    }

    private func detailFrame(
        hostFrame: CGRect,
        size: CGSize,
        availableFrame: CGRect
    ) -> CGRect {
        let y = min(
            max(hostFrame.maxY - size.height, availableFrame.minY),
            availableFrame.maxY - size.height
        )
        let leftX = hostFrame.minX - panelSpacing - size.width
        if leftX >= availableFrame.minX {
            return CGRect(x: leftX, y: y, width: size.width, height: size.height)
        }

        let rightX = hostFrame.maxX + panelSpacing
        if rightX + size.width <= availableFrame.maxX {
            return CGRect(x: rightX, y: y, width: size.width, height: size.height)
        }

        return CGRect(
            x: min(max(leftX, availableFrame.minX), availableFrame.maxX - size.width),
            y: y,
            width: size.width,
            height: size.height
        )
    }

    private func makePanel() -> SystemStatusMenuBarDetailPanel {
        let panel = SystemStatusMenuBarDetailPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct SystemStatusMenuBarDetailPanelView: View {
    @ObservedObject var viewModel: SystemStatusViewModel
    @ObservedObject var settingsController: SystemStatusSettingsController
    let kind: SystemStatusMetricKind
    let localization: PluginLocalization
    let onDismiss: () -> Void

    @Environment(\.pluginComponentTheme) private var theme
    @Environment(\.locale) private var locale
    @State private var isCloseHovered = false

    var body: some View {
        let _ = locale
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(kind.title(localization: localization))
                    .font(PluginTypography.control.font.weight(.semibold))
                    .foregroundStyle(theme.text.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(PluginTypography.detail.font.weight(.semibold))
                        .foregroundStyle(isCloseHovered ? theme.text.primary : theme.text.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(
                                isCloseHovered ? theme.surfaces.chip.opacity(0.95) : Color.clear
                            )
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onHover { isCloseHovered = $0 }
                .keyboardShortcut(.cancelAction)
                .help(localization.string("detail.close", defaultValue: "关闭"))
                .accessibilityLabel(localization.string("detail.close", defaultValue: "关闭"))
            }

            SystemStatusMetricDetailView(
                viewModel: viewModel,
                settingsController: settingsController,
                kind: kind,
                localization: localization
            )
        }
        .padding(10)
        .background(theme.surfaces.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
