import SwiftUI
import MacToolsPluginKit

struct PowerStatusComponentView: View {
    @ObservedObject var viewModel: PowerStatusViewModel
    let localization: PluginLocalization
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        PluginObservedContent(viewModel) { _ in
            content
        }
    }

    private var content: some View {
        card
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PowerStatusContentHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(PowerStatusContentHeightPreferenceKey.self) { height in
                onContentHeightChange(height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var card: some View {
        Group {
            if !viewModel.snapshot.isDataAvailable {
                emptyState
            } else {
                mainContent
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash.circle")
                .font(.system(size: 24, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.text.secondary)

            Text(localization.string("empty.title", defaultValue: "暂无电源数据"))
                .font(PluginTypography.sectionTitle.font)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(localization.string("empty.subtitle", defaultValue: "无法读取电池信息，请确认设备支持。"))
                .font(PluginTypography.detail.font)
                .foregroundStyle(theme.text.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(PluginComponentCardBackground(cornerRadius: PowerStatusLayout.cornerRadius))
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Header: power source + main wattage
            headerSection

            // Animated power flow diagram
            flowDiagramSection

            // Power flow metrics
            powerFlowSection

            // Battery and electrical telemetry, grouped
            telemetrySection

            // Collapsible temperatures and component power
            sensorSection

            // Applications drawing the most power
            energyAppsSection
        }
        .padding(.vertical, PowerStatusLayout.cardVerticalPadding)
        .frame(maxWidth: .infinity)
        .background(PluginComponentCardBackground(cornerRadius: PowerStatusLayout.cornerRadius))
    }

    // MARK: - Power flow diagram

    private var flowDiagramSection: some View {
        PowerFlowDiagramSection(
            snapshot: viewModel.snapshot,
            localization: localization
        )
        .padding(.horizontal, PowerStatusLayout.horizontalPadding)
        .padding(.bottom, PowerStatusLayout.section)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: headerIconName)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(headerIconTint)

            Text(viewModel.snapshot.powerSourceText(localization))
                .font(PluginTypography.detail.font.weight(.medium))
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, PowerStatusLayout.horizontalPadding)
        .padding(.bottom, PowerStatusLayout.sectionHeaderContent)
    }

    private var headerIconName: String {
        switch viewModel.snapshot.flowState {
        case .onAC:
            return "powerplug.fill"
        case .idle, .discharging, .supplementalDischarge:
            return "battery.50percent"
        case .charging:
            return "bolt.fill"
        }
    }

    private var headerIconTint: Color {
        switch viewModel.snapshot.flowState {
        case .onAC:
            return theme.status.informational
        case .charging:
            return theme.status.success
        case .idle, .discharging, .supplementalDischarge:
            return theme.status.warning
        }
    }

    // MARK: - Power flow

    private var powerFlowSection: some View {
        VStack(spacing: PowerStatusLayout.rowVertical) {
            PowerStatusMetricRow(
                icon: "cpu",
                iconTint: theme.status.informational,
                title: localization.string("metric.systemPower", defaultValue: "系统功耗"),
                value: PowerStatusValueText.watts(viewModel.snapshot.systemPowerW),
                valueTint: viewModel.snapshot.systemPowerW == nil ? theme.text.tertiary : theme.text.primary
            )

            if viewModel.snapshot.isOnAC {
                PowerStatusMetricRow(
                    icon: "powerplug.fill",
                    iconTint: theme.status.informational,
                    title: localization.string("metric.acInput", defaultValue: "交流输入"),
                    value: PowerStatusValueText.watts(viewModel.snapshot.acInputW),
                    valueTint: (viewModel.snapshot.acInputW ?? 0) > 0 ? theme.text.primary : theme.text.tertiary
                )
            }

            if viewModel.snapshot.batteryChargeRateW > 0 {
                PowerStatusMetricRow(
                    icon: "arrow.down.right.circle.fill",
                    iconTint: theme.status.success,
                    title: localization.string("metric.batteryCharging", defaultValue: "电池充电"),
                    value: String(format: "%.1f W", viewModel.snapshot.batteryChargeRateW),
                    valueTint: theme.status.success
                )
            }

            if viewModel.snapshot.batteryDischargeRateW > 0 {
                PowerStatusMetricRow(
                    icon: "arrow.up.right.circle.fill",
                    iconTint: theme.status.warning,
                    title: localization.string("metric.batteryDischarging", defaultValue: "电池放电"),
                    value: String(format: "%.1f W", viewModel.snapshot.batteryDischargeRateW),
                    valueTint: theme.status.warning
                )
            }

            if viewModel.snapshot.acAdapterWattage > 0 {
                PowerStatusMetricRow(
                    icon: "bolt.horizontal.circle",
                    iconTint: theme.text.secondary,
                    title: localization.string("metric.adapter", defaultValue: "适配器"),
                    value: "\(viewModel.snapshot.acAdapterWattage) W",
                    valueTint: theme.text.secondary
                )
            }
        }
        .padding(.horizontal, PowerStatusLayout.horizontalPadding)
        .padding(.bottom, PowerStatusLayout.section)
    }

    // MARK: - Component sensors

    /// Temperatures and component power for the whole machine. The table is
    /// collapsed by default and sampled only while it is open.
    private var sensorSection: some View {
        PowerStatusSensorSection(
            isExpanded: viewModel.isSensorsExpanded,
            readings: viewModel.sensorSnapshot.components,
            isSampled: viewModel.sensorSnapshot.isSampled,
            localization: localization,
            onToggle: {
                viewModel.setSensorsExpanded(!viewModel.isSensorsExpanded)
            }
        )
        .padding(.horizontal, PowerStatusLayout.horizontalPadding)
        .padding(.top, PowerStatusLayout.section)
    }

    // MARK: - Energy-consuming apps

    /// The five heaviest applications in the current sampling window. The
    /// section stays collapsed by default and only samples while expanded.
    private var energyAppsSection: some View {
        PowerStatusEnergyAppsSection(
            isExpanded: viewModel.isEnergyAppsExpanded,
            apps: viewModel.snapshot.topEnergyApps,
            isSampled: viewModel.isEnergyAppsSampled,
            localization: localization,
            onToggle: {
                viewModel.setEnergyAppsExpanded(!viewModel.isEnergyAppsExpanded)
            }
        )
        .padding(.horizontal, PowerStatusLayout.horizontalPadding)
        .padding(.top, PowerStatusLayout.section)
    }

    // MARK: - Telemetry

    /// Every reading the power rows above do not already show, split into two
    /// groups so nothing is repeated and nothing is hidden.
    @ViewBuilder
    private var telemetrySection: some View {
        if viewModel.snapshot.isDataAvailable {
            VStack(alignment: .leading, spacing: PowerStatusLayout.section) {
                capacityGroup

                if viewModel.snapshot.hasVoltageCurrentDetail {
                    voltageCurrentGroup
                }
            }
            .padding(.horizontal, PowerStatusLayout.horizontalPadding)
            .padding(.top, PowerStatusLayout.section)
        }
    }

    /// The pack itself: level, charge beside the time it buys, then the
    /// full-charge over design capacity reading that health is derived from,
    /// followed by health, cycles, and temperature.
    private var capacityGroup: some View {
        let snapshot = viewModel.snapshot
        return detailGroup(title: localization.string("detail.group.capacity", defaultValue: "电池容量")) {
            VStack(alignment: .leading, spacing: PowerStatusLayout.rowVertical) {
                batteryLevelBar

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: PowerStatusLayout.rowVertical
                ) {
                    if let remaining = snapshot.remainingCapacityMAH {
                        PowerStatusMiniMetric(
                            icon: "gauge.with.needle",
                            iconTint: theme.status.informational,
                            title: localization.string("detail.remainingCapacity", defaultValue: "剩余容量"),
                            value: "\(remaining) mAh"
                        )
                    }

                    // The remaining charge and the time it lasts belong together.
                    if snapshot.showFullyCharged {
                        PowerStatusMiniMetric(
                            icon: "checkmark.circle.fill",
                            iconTint: theme.status.success,
                            title: localization.string("metric.timeToFull", defaultValue: "预计充满时间"),
                            value: localization.string("metric.fullyCharged", defaultValue: "已充满")
                        )
                    } else if let timeText = snapshot.estimatedTimeRemainingText {
                        PowerStatusMiniMetric(
                            icon: "clock",
                            iconTint: theme.status.informational,
                            title: snapshot.estimatedTimeLabelText(localization) ?? "",
                            value: timeText,
                            help: snapshot.estimatedTimeIsComputed
                                ? localization.string(
                                    "metric.timeEstimate.help",
                                    defaultValue: "基于剩余电量与近期平均功耗估算"
                                )
                                : nil
                        )
                    }

                    // Full-charge and design capacity are the two readings the
                    // health ratio is made of, so they share one tile.
                    if let fullCharge = snapshot.fullChargeCapacityMAH {
                        PowerStatusMiniMetric(
                            icon: "checkmark.shield",
                            iconTint: theme.status.success,
                            title: localization.string("detail.fullChargeCapacity", defaultValue: "满电容量"),
                            value: snapshot.designCapacityMAH.map { "\(fullCharge)/\($0) mAh" }
                                ?? "\(fullCharge) mAh"
                        )
                    } else if let design = snapshot.designCapacityMAH {
                        PowerStatusMiniMetric(
                            icon: "cube",
                            iconTint: theme.text.secondary,
                            title: localization.string("detail.designCapacity", defaultValue: "设计容量"),
                            value: "\(design) mAh"
                        )
                    }

                    if let health = snapshot.healthText {
                        PowerStatusMiniMetric(
                            icon: "heart.fill",
                            iconTint: theme.status.success,
                            title: localization.string("metric.health", defaultValue: "健康度"),
                            value: health
                        )
                    }

                    if let cycles = snapshot.cycleCount {
                        PowerStatusMiniMetric(
                            icon: "arrow.triangle.2.circlepath",
                            iconTint: theme.text.secondary,
                            title: localization.string("metric.cycles", defaultValue: "循环次数"),
                            value: "\(cycles)"
                        )
                    }

                    if let temp = snapshot.temperatureText {
                        PowerStatusMiniMetric(
                            icon: "thermometer.medium",
                            iconTint: tempTint,
                            title: localization.string("metric.temperature", defaultValue: "温度"),
                            value: temp
                        )
                    }
                }
            }
        }
    }

    /// Raw electrical telemetry reported by the pack.
    private var voltageCurrentGroup: some View {
        let snapshot = viewModel.snapshot
        return detailGroup(title: localization.string("detail.group.voltage", defaultValue: "电压与电流")) {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: PowerStatusLayout.rowVertical
            ) {
                if let voltage = snapshot.batteryVoltageMV {
                    PowerStatusMiniMetric(
                        icon: "bolt.horizontal",
                        iconTint: theme.status.informational,
                        title: localization.string("detail.voltage", defaultValue: "电压"),
                        value: "\(voltage) mV"
                    )
                }

                if let amperage = snapshot.batteryAmperageMA {
                    // IOKit signs Amperage by direction (negative while
                    // discharging). The charge and discharge rows above already
                    // carry that, so show magnitude.
                    PowerStatusMiniMetric(
                        icon: "arrow.left.arrow.right",
                        iconTint: theme.status.warning,
                        title: localization.string("detail.current", defaultValue: "电流"),
                        value: "\(abs(amperage)) mA"
                    )
                }

                if let chargingVoltage = snapshot.chargingVoltageMV {
                    PowerStatusMiniMetric(
                        icon: "bolt.badge.checkmark",
                        iconTint: theme.status.success,
                        title: localization.string("detail.chargingVoltage", defaultValue: "充电电压"),
                        value: "\(chargingVoltage) mV"
                    )
                }

                if let chargingCurrent = snapshot.chargingCurrentMA {
                    PowerStatusMiniMetric(
                        icon: "arrow.down.circle",
                        iconTint: theme.status.success,
                        title: localization.string("detail.chargingCurrent", defaultValue: "充电电流"),
                        value: "\(chargingCurrent) mA"
                    )
                }
            }
        }
    }

    private func detailGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PowerStatusLayout.sectionHeaderContent) {
            Text(title)
                .font(PluginTypography.caption.font.weight(.semibold))
                .foregroundStyle(theme.text.secondary)
                .lineLimit(1)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var batteryLevelBar: some View {
        VStack(alignment: .leading, spacing: PowerStatusLayout.batteryBarLabelSpacing) {
            HStack {
                Image(systemName: batteryIconName)
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(batteryIconTint)

                Text(localization.string("metric.battery", defaultValue: "电池"))
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(theme.text.secondary)

                Spacer()

                Text("\(viewModel.snapshot.batteryPercent)%")
                    .font(PluginTypography.detail.font.weight(.semibold))
                    .foregroundStyle(batteryTint)
                    .monospacedDigit()
            }

            batteryLevelTrack
        }
    }

    /// A recessed capsule track with a tinted, gradient-filled level and a
    /// bright edge marker at the current level.
    private var batteryLevelTrack: some View {
        let progress = min(max(CGFloat(viewModel.snapshot.batteryPercent) / 100, 0), 1)
        let height = PowerStatusLayout.batteryTrackHeight

        return GeometryReader { geo in
            let fillWidth = geo.size.width * progress
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(theme.surfaces.track)

                Capsule(style: .continuous)
                    .fill(batteryTint.opacity(0.14))

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                batteryTint.opacity(0.45),
                                batteryTint.opacity(0.95)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.24),
                                        Color.white.opacity(0.02)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    .frame(width: fillWidth)

                if progress > 0.005, progress < 0.995 {
                    Capsule(style: .continuous)
                        .fill(batteryTint.opacity(0.45))
                        .frame(width: 6)
                        .blur(radius: 2)
                        .offset(x: fillWidth - 3)

                    Capsule(style: .continuous)
                        .fill(batteryTint)
                        .frame(width: 2, height: height - 2)
                        .brightness(0.3)
                        .offset(x: fillWidth - 1)
                }
            }
            .frame(height: height)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var batteryTint: Color {
        let pct = viewModel.snapshot.batteryPercent
        if pct <= 20 { return theme.status.critical }
        if pct <= 40 { return theme.status.warning }
        return theme.status.success
    }

    private var batteryIconName: String {
        if viewModel.snapshot.isCharging || viewModel.snapshot.fullyCharged {
            return "battery.100percent.bolt"
        }
        switch viewModel.snapshot.batteryPercent {
        case 76...100: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        case 11...25: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var batteryIconTint: Color {
        if viewModel.snapshot.isCharging || viewModel.snapshot.fullyCharged {
            return theme.status.success
        }
        return batteryTint
    }

    private var tempTint: Color {
        guard let temp = viewModel.snapshot.batteryTemperatureC else { return theme.text.secondary }
        if temp >= 40 { return theme.status.critical }
        if temp >= 35 { return theme.status.warning }
        return theme.status.success
    }
}

// MARK: - Layout

enum PowerStatusLayout {
    static let cornerRadius: CGFloat = PluginPanelWidgetLayoutMetrics.cardCornerRadius
    static let horizontalPadding: CGFloat = 12
    static let cardVerticalPadding: CGFloat = 10
    static let section: CGFloat = 12
    static let sectionHeaderContent: CGFloat = 6
    static let rowVertical: CGFloat = 6

    static let headerRowHeight: CGFloat = 22
    static let metricRowHeight: CGFloat = 17
    /// Label row, spacing, and the level track inside the battery group.
    static let batteryBarLabelSpacing: CGFloat = 6
    static let batteryTrackHeight: CGFloat = 14
    static let batteryBarHeight: CGFloat = 36
    static let miniMetricRowHeight: CGFloat = 31
    static let appEnergyRowHeight: CGFloat = 20
    static let appEnergyHeaderHeight: CGFloat = 22
    static let sensorHeaderHeight: CGFloat = 22
    static let sensorTableHeaderHeight: CGFloat = 14
    static let sensorRowHeight: CGFloat = 18
    static let sensorRowSpacing: CGFloat = 4
    static let detailGroupHeaderHeight: CGFloat = 15
    static let emptyContentHeight: CGFloat = 122

    // Animated power-flow diagram
    static let flowRowHeight: CGFloat = 40
    static let flowRowSpacing: CGFloat = 6
    static let flowLineHeight: CGFloat = 20
    static let flowNodeSpacing: CGFloat = 8
    static let flowNodeWidth: CGFloat = 84
    /// Two diagram rows plus their spacing; the fork canvas spans both rows.
    static let forkHeight: CGFloat = flowRowHeight * 2 + flowRowSpacing

    /// Estimated intrinsic content height, used for the declared widget span.
    /// The host refines the span from the measured height reported by the view.
    static func contentHeight(
        flowRowCount: Int,
        diagramRowCount: Int,
        capacityTileCount: Int,
        voltageCurrentTileCount: Int,
        energyAppCount: Int = 0,
        isEnergyAppsExpanded: Bool = false,
        sensorRowCount: Int = 0,
        isSensorsExpanded: Bool = false,
        isDataAvailable: Bool
    ) -> CGFloat {
        guard isDataAvailable else {
            return emptyContentHeight
        }

        let rows = max(flowRowCount, 1)
        let header = headerRowHeight + sectionHeaderContent
        let diagram = diagramHeight(diagramRowCount: diagramRowCount)
        let powerFlow = CGFloat(rows) * metricRowHeight
            + CGFloat(max(rows - 1, 0)) * rowVertical
            + section
        let energyApps = energyAppsHeight(
            rowCount: energyAppCount,
            isExpanded: isEnergyAppsExpanded
        )
        let sensors = sensorsHeight(rowCount: sensorRowCount, isExpanded: isSensorsExpanded)
        // The capacity group always renders; it carries the battery level bar.
        let capacity = groupHeight(
            barHeight: batteryBarHeight + rowVertical,
            tileCount: capacityTileCount
        )
        let voltageCurrent = groupHeight(barHeight: 0, tileCount: voltageCurrentTileCount)
        let padding = cardVerticalPadding * 2
        return header + diagram + powerFlow + energyApps + sensors + capacity + voltageCurrent + padding
    }

    /// The collapsible header always renders; the table adds one header row and
    /// one row per component. Before the first sample completes the view shows
    /// a single placeholder row, which is mirrored here.
    private static func sensorsHeight(rowCount: Int, isExpanded: Bool) -> CGFloat {
        let header = section + sensorHeaderHeight
        guard isExpanded else { return header }

        let rows = max(rowCount, 1)
        let table = sensorTableHeaderHeight + sensorRowSpacing
            + CGFloat(rows) * sensorRowHeight
            + CGFloat(max(rows - 1, 0)) * sensorRowSpacing
        return header + sectionHeaderContent + table
    }

    /// The collapsible header always renders; the list adds one row per app,
    /// or one placeholder row before the first sample completes.
    private static func energyAppsHeight(rowCount: Int, isExpanded: Bool) -> CGFloat {
        let header = section + appEnergyHeaderHeight
        guard isExpanded else { return header }

        let rows = max(rowCount, 1)
        return header + sectionHeaderContent
            + CGFloat(rows) * appEnergyRowHeight
            + CGFloat(max(rows - 1, 0)) * rowVertical
    }

    /// One telemetry group: its own leading spacing, header, an optional
    /// leading bar, and a two-column tile grid.
    private static func groupHeight(barHeight: CGFloat, tileCount: Int) -> CGFloat {
        guard tileCount > 0 || barHeight > 0 else { return 0 }
        let rows = (tileCount + 1) / 2
        let grid = CGFloat(rows) * miniMetricRowHeight
            + CGFloat(max(rows - 1, 0)) * rowVertical
        return section + detailGroupHeaderHeight + sectionHeaderContent + barHeight + grid
    }

    private static func diagramHeight(diagramRowCount: Int) -> CGFloat {
        guard diagramRowCount > 0 else { return 0 }
        return CGFloat(diagramRowCount) * flowRowHeight
            + CGFloat(max(diagramRowCount - 1, 0)) * flowRowSpacing
            + section
    }

    /// Mirrors the rows rendered by the animated power-flow diagram.
    static func flowDiagramRowCount(for snapshot: PowerStatusSnapshot) -> Int {
        guard snapshot.isDataAvailable else { return 0 }
        switch snapshot.flowState {
        case .charging, .supplementalDischarge:
            return 2
        case .onAC, .discharging, .idle:
            return 1
        }
    }

    /// Mirrors the rows rendered by `PowerStatusComponentView`. The AC input
    /// row is only rendered while the machine is on power.
    static func flowRowCount(for snapshot: PowerStatusSnapshot) -> Int {
        guard snapshot.isDataAvailable else { return 0 }
        var count = snapshot.isOnAC ? 2 : 1 // system power, plus AC input on power
        if snapshot.batteryChargeRateW > 0 || snapshot.batteryDischargeRateW > 0 {
            count += 1
        }
        if snapshot.acAdapterWattage > 0 {
            count += 1
        }
        return count
    }

    /// Mirrors the tiles rendered by the battery-capacity group. The group also
    /// carries the battery level bar, so it always renders when data exists.
    /// Full-charge and design capacity share one tile, so they count once.
    static func capacityTileCount(for snapshot: PowerStatusSnapshot) -> Int {
        guard snapshot.isDataAvailable else { return 0 }
        return (snapshot.remainingCapacityMAH != nil ? 1 : 0)
            + (snapshot.fullChargeCapacityMAH != nil || snapshot.designCapacityMAH != nil ? 1 : 0)
            + (snapshot.batteryHealthPercent != nil ? 1 : 0)
            + (snapshot.cycleCount != nil ? 1 : 0)
            + (snapshot.estimatedTimeRemainingMinutes != nil || snapshot.showFullyCharged ? 1 : 0)
            + (snapshot.batteryTemperatureC != nil ? 1 : 0)
    }

    /// Mirrors the tiles rendered by the voltage and current group.
    static func voltageCurrentTileCount(for snapshot: PowerStatusSnapshot) -> Int {
        guard snapshot.isDataAvailable else { return 0 }
        return (snapshot.batteryVoltageMV != nil ? 1 : 0)
            + (snapshot.batteryAmperageMA != nil ? 1 : 0)
            + (snapshot.chargingVoltageMV != nil ? 1 : 0)
            + (snapshot.chargingCurrentMA != nil ? 1 : 0)
    }
}

private struct PowerStatusContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Power flow diagram

/// Animated diagram showing how power flows between the AC adapter,
/// the system, and the battery for the current flow state.
private struct PowerFlowDiagramSection: View {
    let snapshot: PowerStatusSnapshot
    let localization: PluginLocalization

    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        VStack(spacing: PowerStatusLayout.flowRowSpacing) {
            switch snapshot.flowState {
            case .onAC:
                flowRow(
                    source: acNode(value: snapshot.effectiveACOutputW),
                    destination: systemNode,
                    color: theme.status.informational
                )
            case .charging:
                chargingForkRow
            case .discharging, .idle:
                // `.idle` only resolves off power, so the pack is the source.
                flowRow(
                    source: batteryNode,
                    destination: systemNode,
                    color: theme.status.warning
                )
            case .supplementalDischarge:
                supplementalMergeRow
            }
        }
    }

    private func flowRow(
        source: PowerFlowNodeModel,
        destination: PowerFlowNodeModel,
        color: Color
    ) -> some View {
        HStack(spacing: PowerStatusLayout.flowNodeSpacing) {
            PowerFlowNode(model: source)

            PowerFlowLine(color: color, powerW: source.powerW)
                .frame(height: PowerStatusLayout.flowLineHeight)

            PowerFlowNode(model: destination)
        }
    }

    private func acNode(value: Double?) -> PowerFlowNodeModel {
        PowerFlowNodeModel(
            icon: "powerplug.fill",
            title: localization.string("flow.ac", defaultValue: "交流电"),
            value: PowerStatusValueText.watts(value),
            tint: theme.status.informational,
            powerW: value ?? 0
        )
    }

    private var systemNode: PowerFlowNodeModel {
        PowerFlowNodeModel(
            icon: "desktopcomputer",
            title: localization.string("flow.system", defaultValue: "系统"),
            value: PowerStatusValueText.watts(snapshot.systemPowerW),
            tint: theme.text.primary,
            powerW: snapshot.systemPowerW ?? 0
        )
    }

    private var batteryNode: PowerFlowNodeModel {
        PowerFlowNodeModel(
            icon: "battery.50percent",
            title: localization.string("flow.battery", defaultValue: "电池"),
            value: PowerStatusValueText.watts(snapshot.batteryDischargeRateW),
            tint: theme.status.warning,
            powerW: snapshot.batteryDischargeRateW
        )
    }

    private var chargingNode: PowerFlowNodeModel {
        PowerFlowNodeModel(
            icon: "battery.100percent.bolt",
            title: localization.string("flow.charging", defaultValue: "充电"),
            value: PowerStatusValueText.watts(snapshot.batteryChargeRateW),
            tint: theme.status.success,
            powerW: snapshot.batteryChargeRateW
        )
    }

    /// A single AC source forking into the system and the battery charger.
    private var chargingForkRow: some View {
        HStack(spacing: PowerStatusLayout.flowNodeSpacing) {
            PowerFlowNode(model: acNode(value: snapshot.effectiveACOutputW))

            PowerFlowJunctionLine(
                mode: .fork,
                trunkColor: theme.status.informational,
                trunkPowerW: snapshot.effectiveACOutputW ?? 0,
                topColor: theme.status.informational,
                topPowerW: snapshot.systemPowerW ?? 0,
                bottomColor: theme.status.success,
                bottomPowerW: snapshot.batteryChargeRateW
            )
            .frame(height: PowerStatusLayout.forkHeight)

            VStack(spacing: PowerStatusLayout.flowRowSpacing) {
                PowerFlowNode(model: systemNode)
                PowerFlowNode(model: chargingNode)
            }
        }
    }

    /// AC and battery sources merging into a single system feed.
    private var supplementalMergeRow: some View {
        HStack(spacing: PowerStatusLayout.flowNodeSpacing) {
            VStack(spacing: PowerStatusLayout.flowRowSpacing) {
                PowerFlowNode(model: acNode(value: snapshot.acInputW))
                PowerFlowNode(model: batteryNode)
            }

            PowerFlowJunctionLine(
                mode: .merge,
                trunkColor: theme.status.informational,
                trunkPowerW: snapshot.systemPowerW ?? 0,
                topColor: theme.status.informational,
                topPowerW: snapshot.acInputW ?? 0,
                bottomColor: theme.status.warning,
                bottomPowerW: snapshot.batteryDischargeRateW
            )
            .frame(height: PowerStatusLayout.forkHeight)

            PowerFlowNode(model: systemNode)
        }
    }
}

private struct PowerFlowNodeModel {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    /// Watts behind this node; drives the flow line thickness.
    let powerW: Double
}

private struct PowerFlowNode: View {
    let model: PowerFlowNodeModel

    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.icon)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(model.title)
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(model.value)
                    .font(PluginTypography.detail.font.weight(.semibold))
                    .foregroundStyle(theme.text.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(
            width: PowerStatusLayout.flowNodeWidth,
            height: PowerStatusLayout.flowRowHeight,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.surfaces.backplate)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.title) \(model.value)")
    }
}

/// A horizontal flow line with dashes animating toward the destination,
/// so the direction and share of power are visible at a glance.
private struct PowerFlowLine: View {
    let color: Color
    let powerW: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dashPattern: [CGFloat] = [3, 5]
    private static let dashPeriod: CGFloat = 8
    private static let dashDuration: TimeInterval = 0.9

    var body: some View {
        // Canvas closures are not re-evaluated per animation frame, so the
        // dash phase is derived from the timeline instead of animated state.
        // One dash period per cycle loops seamlessly; reduced motion pauses.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let midY = size.height / 2
                let endX = max(6, size.width - 9)
                var path = Path()
                path.move(to: CGPoint(x: 1, y: midY))
                path.addLine(to: CGPoint(x: endX, y: midY))

                let lineWidth = 2.5 + min(max(powerW, 0) / 60, 1) * 2

                // Base track.
                context.stroke(
                    path,
                    with: .color(color.opacity(0.22)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )

                // Animated flow dashes.
                context.stroke(
                    path,
                    with: .color(color.opacity(0.9)),
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        dash: Self.dashPattern,
                        dashPhase: Self.dashPhase(at: timeline.date)
                    )
                )

                // Arrow head pointing at the destination.
                var arrow = Path()
                arrow.move(to: CGPoint(x: endX - 6, y: midY - 4.5))
                arrow.addLine(to: CGPoint(x: endX + 1, y: midY))
                arrow.addLine(to: CGPoint(x: endX - 6, y: midY + 4.5))
                context.stroke(
                    arrow,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .accessibilityHidden(true)
    }

    /// Phase for the given time; decreasing the phase moves dashes toward
    /// the destination, and one full period per cycle loops seamlessly.
    private static func dashPhase(at date: Date) -> CGFloat {
        let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: dashDuration)
        return -dashPeriod * CGFloat(cycle / dashDuration)
    }
}

/// A junction connector spanning two diagram rows: one trunk forking into
/// two branches, or two branches merging into one trunk. Dashes animate
/// along the flow direction on every segment.
private struct PowerFlowJunctionLine: View {
    enum Mode {
        /// Trunk on the left splits into top and bottom branches on the right.
        case fork
        /// Top and bottom branches on the left merge into a trunk on the right.
        case merge
    }

    let mode: Mode
    let trunkColor: Color
    let trunkPowerW: Double
    let topColor: Color
    let topPowerW: Double
    let bottomColor: Color
    let bottomPowerW: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dashPattern: [CGFloat] = [3, 5]
    private static let dashPeriod: CGFloat = 8
    private static let dashDuration: TimeInterval = 0.9
    private static let cornerRadius: CGFloat = 6

    var body: some View {
        // Canvas closures are not re-evaluated per animation frame, so the
        // dash phase is derived from the timeline instead of animated state.
        // One dash period per cycle loops seamlessly; reduced motion pauses.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let dashPhase = Self.dashPhase(at: timeline.date)
                let trunkY = size.height / 2
                let topY = PowerStatusLayout.flowRowHeight / 2
                let bottomY = size.height - PowerStatusLayout.flowRowHeight / 2
                let endX = max(8, size.width - 9)
                let splitX: CGFloat
                switch mode {
                case .fork:
                    splitX = min(max(10, size.width * 0.35), max(10, endX - 16))
                case .merge:
                    splitX = min(max(16, size.width * 0.55), max(16, endX))
                }
                let r = Self.cornerRadius

                switch mode {
                case .fork:
                    var trunk = Path()
                    trunk.move(to: CGPoint(x: 1, y: trunkY))
                    trunk.addLine(to: CGPoint(x: splitX, y: trunkY))
                    stroke(context, path: trunk, color: trunkColor, powerW: trunkPowerW, dashPhase: dashPhase)

                    stroke(context, path: branch(from: .init(x: splitX, y: trunkY),
                                                 to: topY, exitingRight: true, splitX: splitX, endX: endX, r: r),
                           color: topColor, powerW: topPowerW, dashPhase: dashPhase)
                    stroke(context, path: branch(from: .init(x: splitX, y: trunkY),
                                                 to: bottomY, exitingRight: true, splitX: splitX, endX: endX, r: r),
                           color: bottomColor, powerW: bottomPowerW, dashPhase: dashPhase)

                    drawArrow(context, at: CGPoint(x: endX, y: topY), color: topColor)
                    drawArrow(context, at: CGPoint(x: endX, y: bottomY), color: bottomColor)

                case .merge:
                    stroke(context, path: branch(from: CGPoint(x: 1, y: topY),
                                                 to: trunkY, exitingRight: false, splitX: splitX, endX: endX, r: r),
                           color: topColor, powerW: topPowerW, dashPhase: dashPhase)
                    stroke(context, path: branch(from: CGPoint(x: 1, y: bottomY),
                                                 to: trunkY, exitingRight: false, splitX: splitX, endX: endX, r: r),
                           color: bottomColor, powerW: bottomPowerW, dashPhase: dashPhase)

                    var trunk = Path()
                    trunk.move(to: CGPoint(x: splitX, y: trunkY))
                    trunk.addLine(to: CGPoint(x: endX, y: trunkY))
                    stroke(context, path: trunk, color: trunkColor, powerW: trunkPowerW, dashPhase: dashPhase)

                    drawArrow(context, at: CGPoint(x: endX, y: trunkY), color: trunkColor)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Phase for the given time; decreasing the phase moves dashes toward
    /// the destination, and one full period per cycle loops seamlessly.
    private static func dashPhase(at date: Date) -> CGFloat {
        let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: dashDuration)
        return -dashPeriod * CGFloat(cycle / dashDuration)
    }

    /// Builds one branch: horizontal run, rounded corner, vertical run to the
    /// trunk line, either entering from the left or exiting to the right.
    private func branch(
        from start: CGPoint,
        to endY: CGFloat,
        exitingRight: Bool,
        splitX: CGFloat,
        endX: CGFloat,
        r: CGFloat
    ) -> Path {
        var path = Path()
        path.move(to: start)
        if exitingRight {
            path.addLine(to: CGPoint(x: splitX, y: endY + (endY < start.y ? r : -r)))
            path.addQuadCurve(
                to: CGPoint(x: splitX + r, y: endY),
                control: CGPoint(x: splitX, y: endY)
            )
            path.addLine(to: CGPoint(x: endX, y: endY))
        } else {
            let cornerX = min(max(splitX - r, start.x + r), endX - r)
            path.addLine(to: CGPoint(x: cornerX, y: start.y))
            path.addQuadCurve(
                to: CGPoint(x: cornerX + r, y: start.y + (endY > start.y ? r : -r)),
                control: CGPoint(x: cornerX + r, y: start.y)
            )
            path.addLine(to: CGPoint(x: cornerX + r, y: endY))
        }
        return path
    }

    private func stroke(
        _ context: GraphicsContext,
        path: Path,
        color: Color,
        powerW: Double,
        dashPhase: CGFloat
    ) {
        let lineWidth = 2.5 + min(max(powerW, 0) / 60, 1) * 2
        context.stroke(
            path,
            with: .color(color.opacity(0.22)),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(color.opacity(0.9)),
            style: StrokeStyle(
                lineWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round,
                dash: Self.dashPattern,
                dashPhase: dashPhase
            )
        )
    }

    private func drawArrow(_ context: GraphicsContext, at tip: CGPoint, color: Color) {
        var arrow = Path()
        arrow.move(to: CGPoint(x: tip.x - 6, y: tip.y - 4.5))
        arrow.addLine(to: CGPoint(x: tip.x + 1, y: tip.y))
        arrow.addLine(to: CGPoint(x: tip.x - 6, y: tip.y + 4.5))
        context.stroke(
            arrow,
            with: .color(color),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        )
    }
}

// MARK: - Component sensors

private struct PowerStatusSensorSection: View {
    let isExpanded: Bool
    let readings: [PowerStatusComponentReading]
    let isSampled: Bool
    let localization: PluginLocalization
    let onToggle: () -> Void

    @Environment(\.pluginComponentTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let temperatureColumnWidth: CGFloat = 58
    private static let powerColumnWidth: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                table
                    .padding(.top, PowerStatusLayout.sectionHeaderContent)
            }
        }
    }

    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.text.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)

                Image(systemName: "thermometer.medium")
                    .font(.system(size: 11, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.status.warning)
                    .frame(width: 16)

                Text(localization.string("sensors.title", defaultValue: "温度与功耗"))
                    .font(PluginTypography.caption.font.weight(.semibold))
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .frame(height: PowerStatusLayout.sensorHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(localization.string("sensors.title", defaultValue: "温度与功耗"))
        .accessibilityHint(isExpanded ? collapseHint : expandHint)
    }

    private var table: some View {
        VStack(spacing: PowerStatusLayout.sensorRowSpacing) {
            tableHeader

            if readings.isEmpty {
                placeholderRow
            } else {
                ForEach(readings) { reading in
                    row(reading)
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 6) {
            Color.clear
                .frame(width: 16)

            Text(localization.string("sensors.component", defaultValue: "组件"))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(localization.string("sensors.temperature", defaultValue: "温度"))
                .frame(width: Self.temperatureColumnWidth, alignment: .trailing)

            Text(localization.string("sensors.power", defaultValue: "功耗"))
                .frame(width: Self.powerColumnWidth, alignment: .trailing)
        }
        .font(PluginTypography.caption.font)
        .foregroundStyle(theme.text.tertiary)
        .frame(height: PowerStatusLayout.sensorTableHeaderHeight)
        .accessibilityHidden(true)
    }

    private func row(_ reading: PowerStatusComponentReading) -> some View {
        HStack(spacing: 6) {
            Image(systemName: reading.component.iconName)
                .font(.system(size: 11, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.text.secondary)
                .frame(width: 16)

            Text(componentTitle(reading.component))
                .font(PluginTypography.detail.font)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 4)

            valueText(
                reading.temperatureC.map(Self.temperatureText),
                width: Self.temperatureColumnWidth
            )

            valueText(
                reading.powerW.map(PowerStatusValueText.energyWatts),
                width: Self.powerColumnWidth
            )
        }
        .frame(height: PowerStatusLayout.sensorRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: reading))
    }

    private var placeholderRow: some View {
        HStack(spacing: 6) {
            Text(
                localization.string(
                    isSampled ? "sensors.empty" : "sensors.loading",
                    defaultValue: isSampled ? "未发现传感器" : "正在读取传感器…"
                )
            )
            .font(PluginTypography.detail.font)
            .foregroundStyle(theme.text.tertiary)
            .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, 22)
        .frame(height: PowerStatusLayout.sensorRowHeight)
    }

    private func valueText(_ text: String?, width: CGFloat) -> some View {
        Text(text ?? PowerStatusValueText.unavailable)
            .font(PluginTypography.detail.font.weight(.medium))
            .foregroundStyle(text == nil ? theme.text.tertiary : theme.text.primary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: width, alignment: .trailing)
    }

    private func componentTitle(_ component: PowerStatusSensorComponent) -> String {
        localization.string(component.titleKey, defaultValue: component.defaultTitle)
    }

    private func accessibilityLabel(for reading: PowerStatusComponentReading) -> String {
        var parts = [componentTitle(reading.component)]
        if let temperature = reading.temperatureC {
            parts.append(
                "\(localization.string("sensors.temperature", defaultValue: "温度")) "
                    + Self.temperatureText(temperature)
            )
        }
        if let power = reading.powerW {
            parts.append(
                "\(localization.string("sensors.power", defaultValue: "功耗")) "
                    + PowerStatusValueText.energyWatts(power)
            )
        }
        return parts.joined(separator: ", ")
    }

    private func toggle() {
        if reduceMotion {
            onToggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                onToggle()
            }
        }
    }

    private var helpText: String {
        localization.string(
            "sensors.help",
            defaultValue: "温度取组件内最高读数，功耗来自硬件能耗计数器"
        )
    }

    private var expandHint: String {
        localization.string(
            "sensors.expandHint",
            defaultValue: "展开查看所有组件的温度与功耗"
        )
    }

    private var collapseHint: String {
        localization.string(
            "sensors.collapseHint",
            defaultValue: "收起温度与功耗"
        )
    }

    private static func temperatureText(_ value: Double) -> String {
        String(format: "%.1f°C", value)
    }
}

// MARK: - High energy apps

private struct PowerStatusEnergyAppsSection: View {
    let isExpanded: Bool
    let apps: [PowerStatusAppEnergy]
    let isSampled: Bool
    let localization: PluginLocalization
    let onToggle: () -> Void

    @Environment(\.pluginComponentTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                content
                    .padding(.top, PowerStatusLayout.sectionHeaderContent)
            }
        }
    }

    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.text.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)

                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.status.warning)
                    .frame(width: 16)

                Text(localization.string("energyApps.title", defaultValue: "高耗电应用"))
                    .font(PluginTypography.caption.font.weight(.semibold))
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .frame(height: PowerStatusLayout.appEnergyHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(localization.string("energyApps.help", defaultValue: "最近一次采样间隔内的平均功耗"))
        .accessibilityLabel(localization.string("energyApps.title", defaultValue: "高耗电应用"))
        .accessibilityHint(isExpanded ? collapseHint : expandHint)
    }

    @ViewBuilder
    private var content: some View {
        if apps.isEmpty {
            placeholderRow
        } else {
            VStack(spacing: PowerStatusLayout.rowVertical) {
                ForEach(apps) { app in
                    PowerStatusAppEnergyRow(app: app)
                }
            }
        }
    }

    private var placeholderRow: some View {
        Text(
            localization.string(
                isSampled ? "energyApps.empty" : "energyApps.loading",
                defaultValue: isSampled ? "未发现高耗电应用" : "正在采集应用功耗…"
            )
        )
        .font(PluginTypography.detail.font)
        .foregroundStyle(theme.text.tertiary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 22)
        .frame(height: PowerStatusLayout.appEnergyRowHeight)
    }

    private func toggle() {
        if reduceMotion {
            onToggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                onToggle()
            }
        }
    }

    private var expandHint: String {
        localization.string(
            "energyApps.expandHint",
            defaultValue: "展开查看高耗电应用"
        )
    }

    private var collapseHint: String {
        localization.string(
            "energyApps.collapseHint",
            defaultValue: "收起高耗电应用"
        )
    }
}

private struct PowerStatusAppEnergyRow: View {
    let app: PowerStatusAppEnergy

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.text.tertiary)
                }
            }
            .frame(width: 16, height: 16)

            Text(app.name)
                .font(PluginTypography.detail.font)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(PowerStatusValueText.energyWatts(app.watts))
                .font(PluginTypography.detail.font.weight(.medium))
                .foregroundStyle(theme.text.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name) \(PowerStatusValueText.energyWatts(app.watts))")
    }

    @Environment(\.pluginComponentTheme) private var theme
}

private struct PowerStatusMetricRow: View {
    let icon: String
    let iconTint: Color
    let title: String
    let value: String
    let valueTint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconTint)
                .frame(width: 18)

            Text(title)
                .font(PluginTypography.detail.font)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(value)
                .font(PluginTypography.detail.font.weight(.medium))
                .foregroundStyle(valueTint)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    @Environment(\.pluginComponentTheme) private var theme
}

private struct PowerStatusMiniMetric: View {
    let icon: String
    let iconTint: Color
    let title: String
    let value: String
    var help: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconTint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)

                Text(value)
                    .font(PluginTypography.detail.font.weight(.medium))
                    .foregroundStyle(theme.text.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    // The merged capacity reading is the longest value here;
                    // shrink it before lineLimit would clip it instead.
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)
        }
        .help(help ?? "")
    }

    @Environment(\.pluginComponentTheme) private var theme
}
