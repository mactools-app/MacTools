import AppKit
import MacToolsPluginKit
import SwiftUI

// MARK: - Layout

enum ContainerIndicatorWidgetLayout {
    /// Fallback content height used before the first measurement. The host
    /// resizes the span from the intrinsic height the card reports afterwards,
    /// so the list can grow and shrink with the container/machine count.
    static let cardContentHeight: CGFloat = 180
}

private struct ContainerIndicatorContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Widget card

/// The card is the panel surface for this plugin: service status, then the
/// container and machine lists with their start/stop/restart controls inline.
/// There is no detail popup — everything renders directly in the panel.
struct ContainerIndicatorWidgetCard: View {
    let controller: ContainerIndicatorController
    let localization: PluginLocalization
    let pluginTitle: String
    let reportContentHeight: (CGFloat) -> Void
    let openDetails: (ContainerInstance) -> Void

    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        PluginObservedContent(controller) { state in
            VStack(alignment: .leading, spacing: 8) {
                header(state)
                // The host never renders `lastErrorMessage`, so the card shows
                // operation and check failures itself. They stay visible until
                // the next attempt replaces them.
                if let message = state.lastErrorMessage {
                    errorMessage(message)
                }
                if state.isCommandAvailable {
                    containersSection(state)
                    machinesSection(state)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ContainerIndicatorContentHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(ContainerIndicatorContentHeightPreferenceKey.self) { height in
                reportContentHeight(height)
            }
            .background(PluginComponentCardBackground())
        }
    }

    // MARK: Header

    private func header(_ state: ContainerIndicatorController) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // The title owns its own line so it never competes with the
            // service controls for horizontal space.
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                    .font(PluginTypography.caption.font.weight(.semibold))
                    .foregroundStyle(statusColor(state))
                Text(pluginTitle)
                    .font(PluginTypography.sectionTitle.font)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(state.statusText)
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(statusColor(state))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                if state.isCommandAvailable {
                    serviceButton(
                        systemName: "play.fill",
                        title: localization.string("panel.action.start", defaultValue: "启动"),
                        isEnabled: canStartService(state),
                        action: { state.setServiceRunning(true) }
                    )
                    serviceButton(
                        systemName: "stop.fill",
                        title: localization.string("panel.action.stop", defaultValue: "停止"),
                        isEnabled: canStopService(state),
                        action: { state.setServiceRunning(false) }
                    )
                }
            }
        }
    }

    /// Starts are offered only for a known stopped/unregistered service so a
    /// mid-check tap cannot start a service that is already running.
    private func canStartService(_ state: ContainerIndicatorController) -> Bool {
        !state.isPerformingAction && [.stopped, .unregistered].contains(state.snapshot.status)
    }

    private func canStopService(_ state: ContainerIndicatorController) -> Bool {
        !state.isPerformingAction && state.snapshot.status == .running
    }

    private func serviceButton(
        systemName: String,
        title: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(PluginTypography.caption.font)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }

    // MARK: Sections

    private func containersSection(_ state: ContainerIndicatorController) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                localization.string("panel.detail.containers", defaultValue: "容器"),
                systemImage: "shippingbox"
            )
            if let failure = state.snapshot.containersFailure {
                failureText(failure)
            }
            if let failure = state.snapshot.statsFailure {
                failureText(failure)
            }
            if state.snapshot.containers.isEmpty {
                // A failed read reports itself; only a healthy empty list
                // falls back to the empty message.
                if state.snapshot.containersFailure == nil {
                    emptyText(state)
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(state.snapshot.containers) { container in
                        entityRow(
                            state: state,
                            title: container.name,
                            subtitle: container.image,
                            resources: resourcesLine(
                                cpus: container.cpus,
                                memoryBytes: container.memoryBytes,
                                storageBytes: container.imageStorageBytes
                            ),
                            performance: container.performance,
                            isRunning: container.isRunning,
                            startAction: { state.startContainer(id: container.id) },
                            stopAction: { state.stopContainer(id: container.id) },
                            restartAction: { state.restartContainer(id: container.id) },
                            terminalAction: {
                                state.openTerminal(target: .container(id: container.id))
                            },
                            detailsAction: { openDetails(container) }
                        )
                    }
                }
            }
        }
    }

    private func machinesSection(_ state: ContainerIndicatorController) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                localization.string("panel.detail.machines", defaultValue: "虚拟机"),
                systemImage: "internaldrive"
            )
            if let failure = state.snapshot.machinesFailure {
                failureText(failure)
            }
            if state.snapshot.machines.isEmpty {
                // A failed read reports itself; only a healthy empty list
                // falls back to the empty message.
                if state.snapshot.machinesFailure == nil {
                    emptyText(state)
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(state.snapshot.machines) { machine in
                        entityRow(
                            state: state,
                            title: machine.name,
                            subtitle: machine.image,
                            resources: resourcesLine(
                                cpus: machine.cpus,
                                memoryBytes: machine.memoryBytes,
                                storageBytes: machine.diskSizeBytes
                            ),
                            isRunning: machine.isRunning,
                            startAction: { state.startMachine(id: machine.id) },
                            stopAction: { state.stopMachine(id: machine.id) },
                            restartAction: { state.restartMachine(id: machine.id) },
                            terminalAction: {
                                state.openTerminal(target: .machine(id: machine.id))
                            },
                            detailsAction: nil
                        )
                    }
                }
            }
        }
    }

    // MARK: Rows

    private func entityRow(
        state: ContainerIndicatorController,
        title: String,
        subtitle: String?,
        resources: String?,
        performance: ContainerPerformance? = nil,
        isRunning: Bool,
        startAction: @escaping () -> Void,
        stopAction: @escaping () -> Void,
        restartAction: @escaping () -> Void,
        terminalAction: @escaping () -> Void,
        detailsAction: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    // Every line shares one size; hierarchy comes from the
                    // primary/secondary colors instead of type scale.
                    HStack(spacing: 4) {
                        Text(title)
                            .font(PluginTypography.detail.font)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detailsAction {
                            Button(action: detailsAction) {
                                Image(systemName: "info.circle")
                                    .font(PluginTypography.caption.font)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.text.tertiary)
                            .contentShape(Rectangle())
                            .help(localization.string("panel.action.details", defaultValue: "查看配置"))
                            .accessibilityLabel(
                                localization.string("panel.action.details", defaultValue: "查看配置")
                            )
                        }
                    }
                    if let subtitle, !subtitle.isEmpty {
                        ImageReferenceLine(reference: subtitle)
                            .foregroundStyle(theme.text.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                statusBadge(isRunning: isRunning)

                if isRunning {
                    rowButton(
                        systemName: "terminal",
                        help: localization.string("panel.action.terminal", defaultValue: "打开终端"),
                        isEnabled: true,
                        action: terminalAction
                    )
                    rowButton(
                        systemName: "stop.fill",
                        help: localization.string("panel.action.stop", defaultValue: "停止"),
                        isEnabled: !state.isPerformingAction,
                        action: stopAction
                    )
                    rowButton(
                        systemName: "arrow.clockwise",
                        help: localization.string("panel.action.restart", defaultValue: "重启"),
                        isEnabled: !state.isPerformingAction,
                        action: restartAction
                    )
                } else {
                    rowButton(
                        systemName: "play.fill",
                        help: localization.string("panel.action.start", defaultValue: "启动"),
                        isEnabled: !state.isPerformingAction,
                        action: startAction
                    )
                }
            }

            // Full row width so configuration and live numbers never compete
            // with the badge and lifecycle buttons for space.
            if let resources {
                prefixedLine(
                    prefix: localization.string("panel.detail.configPrefix", defaultValue: "配置"),
                    value: resources
                )
            }
            if isRunning, let performance {
                prefixedLine(
                    prefix: localization.string("panel.detail.livePrefix", defaultValue: "实时"),
                    value: liveLine(performance)
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(PluginComponentCardBackground(cornerRadius: 8))
    }

    /// Prefixes a detail line so the configured values and the live readings
    /// are never mistaken for each other.
    private func prefixedLine(prefix: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(prefix)
                .foregroundStyle(theme.text.tertiary)
                .fixedSize()
            Text(value)
                .foregroundStyle(theme.text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(PluginTypography.detail.font)
    }

    /// One-line live summary. Rates are nil until the second sample, so the
    /// first refresh after opening the panel shows a placeholder instead of a
    /// fabricated zero.
    private func liveLine(_ performance: ContainerPerformance) -> String {
        let cpu = performance.cpuPercent.map(ContainerIndicatorFormatting.percent) ?? "—"
        let memory = performance.memoryBytes.map(ContainerIndicatorFormatting.bytes) ?? "—"
        let disk = performance.diskTotalBytesPerSecond.map(ContainerIndicatorFormatting.rate) ?? "—"
        return localization.format(
            "panel.detail.liveFormat",
            defaultValue: "CPU %1$@ · 内存 %2$@ · 磁盘 %3$@",
            cpu,
            memory,
            disk
        )
    }

    /// One-line CPU/memory/storage summary; hidden when the CLI reported no
    /// resource data for the entry at all.
    private func resourcesLine(cpus: Int, memoryBytes: Int, storageBytes: Int?) -> String? {
        guard cpus > 0 || memoryBytes > 0 || (storageBytes ?? 0) > 0 else { return nil }
        return localization.format(
            "panel.detail.resourcesFormat",
            defaultValue: "CPU %1$d 核 · 内存 %2$@ · 存储 %3$@",
            cpus,
            ContainerIndicatorFormatting.bytes(memoryBytes),
            ContainerIndicatorFormatting.bytes(storageBytes ?? 0)
        )
    }

    private func rowButton(
        systemName: String,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(PluginTypography.caption.font)
                .frame(width: 16, height: 12)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func statusBadge(isRunning: Bool) -> some View {
        let text = isRunning
            ? localization.string("panel.status.running", defaultValue: "运行中")
            : localization.string("panel.status.stopped", defaultValue: "已停止")
        let color = isRunning ? theme.status.success : theme.text.secondary
        return Text(text)
            .font(PluginTypography.caption.font.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .fixedSize()
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(PluginTypography.caption.font.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// Empty lists explain the reason: a stopped service names that state,
    /// while a running service with no entries simply reports none.
    private func emptyText(_ state: ContainerIndicatorController) -> some View {
        let text: String
        if [.stopped, .unregistered].contains(state.snapshot.status) {
            text = localization.string(
                "panel.detail.serviceNotStarted",
                defaultValue: "服务未启动"
            )
        } else {
            text = localization.string("panel.detail.empty", defaultValue: "暂无")
        }
        return Text(text)
            .font(PluginTypography.caption.font)
            .foregroundStyle(theme.text.secondary)
    }

    /// A failed read keeps the previous entries; this line marks them as stale
    /// and names the reason instead of leaving the section looking current.
    private func failureText(_ message: String) -> some View {
        Label {
            Text(message)
                .font(PluginTypography.caption.font)
                .lineLimit(2)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .font(PluginTypography.caption.font)
        }
        .foregroundStyle(theme.status.warning)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Operation and check failures stay in the card until the next attempt
    /// replaces them, so a failed start or stop is never silent.
    private func errorMessage(_ message: String) -> some View {
        Label {
            Text(message)
                .font(PluginTypography.caption.font)
                .lineLimit(2)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(PluginTypography.caption.font)
        }
        .foregroundStyle(theme.status.critical)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusColor(_ state: ContainerIndicatorController) -> Color {
        guard state.isCommandAvailable else { return theme.text.secondary }
        return state.snapshot.status == .running ? theme.status.success : theme.text.secondary
    }
}

// MARK: - Image reference line

private struct ContainerIndicatorImageWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Shows the full image reference while it fits the column and falls back to
/// its last path segment when the column is too narrow. Hovering the line
/// always reveals the complete reference, so shortening never hides detail.
private struct ImageReferenceLine: View {
    let reference: String

    @State private var availableWidth: CGFloat?

    var body: some View {
        Text(text)
            .font(PluginTypography.detail.font)
            .lineLimit(1)
            // If even the last segment overflows, keep its tail (the tag).
            .truncationMode(.head)
            .help(reference)
            .accessibilityLabel(reference)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ContainerIndicatorImageWidthPreferenceKey.self,
                        value: geometry.size.width
                    )
                }
            }
            .onPreferenceChange(ContainerIndicatorImageWidthPreferenceKey.self) { width in
                availableWidth = width
            }
    }

    private var text: String {
        ContainerIndicatorFormatting.imageLabel(
            for: reference,
            fits: availableWidth.map { naturalWidth <= $0 } ?? true
        )
    }

    /// Natural single-line width measured with the same font contract used
    /// for AppKit drawing, so the comparison matches what SwiftUI renders.
    private var naturalWidth: CGFloat {
        NSAttributedString(
            string: reference,
            attributes: [.font: PluginTypography.detail.nsFont]
        )
        .size()
        .width
    }
}
