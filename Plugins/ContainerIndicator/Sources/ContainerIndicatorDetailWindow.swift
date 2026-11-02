import AppKit
import Charts
import MacToolsPluginKit
import SwiftUI

// MARK: - Presenter

/// Owns the single configuration window. The window observes the controller, so
/// it keeps showing live numbers while it stays open.
@MainActor
final class ContainerIndicatorDetailPresenter {
    private var window: ContainerIndicatorDetailWindow?

    /// Called when the window appears and when the user closes it, so the
    /// plugin can keep polling while the inspector is on screen.
    var onVisibilityChange: ((Bool) -> Void)?

    var isPresenting: Bool {
        window?.isVisible == true
    }

    func present(
        container: ContainerInstance,
        controller: ContainerIndicatorController,
        localization: PluginLocalization
    ) {
        close()

        let window = ContainerIndicatorDetailWindow(
            containerID: container.id,
            title: container.name,
            controller: controller,
            localization: localization
        )
        window.onDismiss = { [weak self] in
            self?.window = nil
            self?.onVisibilityChange?(false)
        }

        // The card lives in a menu-bar popover, whose window is ordered above
        // ordinary floating panels. Without lifting the inspector above that
        // level it opens behind the popover the user just clicked.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        PluginPresentationSafety.prepareForWindowOrdering(window)
        position(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
        onVisibilityChange?(true)
    }

    /// Programmatic close (plugin deactivation); does not report visibility,
    /// because the caller already owns the monitoring decision.
    func close() {
        guard let window else { return }
        window.onDismiss = nil
        window.orderOut(nil)
        self.window = nil
    }

    private func position(_ window: NSWindow) {
        let pointerLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointerLocation) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        ))
    }
}

// MARK: - Window

@MainActor
final class ContainerIndicatorDetailWindow: NSPanel {
    var onDismiss: (() -> Void)?

    init(
        containerID: String,
        title: String,
        controller: ContainerIndicatorController,
        localization: PluginLocalization
    ) {
        let size = NSSize(width: 520, height: 620)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.title = title
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        titlebarSeparatorStyle = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 440, height: 420)
        setContentSize(size)

        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true

        let hostingView = NSHostingView(
            rootView: ContainerIndicatorDetailView(
                containerID: containerID,
                controller: controller,
                localization: localization
            )
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        contentView = effectView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performClose(_ sender: Any?) {
        orderOut(nil)
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

// MARK: - Content

private struct ContainerIndicatorDetailView: View {
    let containerID: String
    @ObservedObject var controller: ContainerIndicatorController
    let localization: PluginLocalization

    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source

    private var container: ContainerInstance? {
        controller.snapshot.containers.first { $0.id == containerID }
    }

    var body: some View {
        let _ = runtimeLocale.revision
        Group {
            if let container {
                VStack(spacing: 0) {
                    header(container)
                    Divider()
                    Form {
                        overviewSection(container)
                        resourcesSection(container)
                        runtimeSection(container)
                        networkSection(container)
                        processSection(container)
                        if container.isRunning {
                            liveSection(container)
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                }
            } else {
                missingState
            }
        }
        .background(Color.clear)
        .environment(\.locale, runtimeLocale.locale)
        .environment(
            \.layoutDirection,
            runtimeLocale.locale.language.characterDirection == .rightToLeft
                ? .rightToLeft
                : .leftToRight
        )
    }

    // MARK: Header

    private func header(_ container: ContainerInstance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.title3)
                    .foregroundStyle(Color(nsColor: .systemBlue))
                Text(container.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusBadge(container)
                Spacer(minLength: 0)
            }
            if !container.image.isEmpty {
                Text(container.image)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 20)
        // Clear the traffic lights that float over the full-size glass
        // content view.
        .padding(.top, 34)
        .padding(.bottom, 10)
    }

    private func statusBadge(_ container: ContainerInstance) -> some View {
        let text = container.isRunning
            ? localization.string("panel.status.running", defaultValue: "运行中")
            : localization.string("panel.status.stopped", defaultValue: "已停止")
        let color = container.isRunning ? Color(nsColor: .systemGreen) : Color.secondary
        return Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .fixedSize()
    }

    // MARK: Sections

    private func overviewSection(_ container: ContainerInstance) -> some View {
        Section {
            field(
                localization.string("detail.field.status", defaultValue: "状态"),
                container.isRunning
                    ? localization.string("panel.status.running", defaultValue: "运行中")
                    : localization.string("panel.status.stopped", defaultValue: "已停止")
            )
            field(
                localization.string("detail.field.containerID", defaultValue: "容器 ID"),
                container.id
            )
            field(
                localization.string("detail.field.imageDigest", defaultValue: "镜像摘要"),
                container.configuration.imageDigest.isEmpty
                    ? none
                    : container.configuration.imageDigest
            )
            field(
                localization.string("detail.field.createdAt", defaultValue: "创建时间"),
                formattedDate(container.configuration.createdAt)
            )
        } header: {
            sectionTitle(localization.string("detail.section.overview", defaultValue: "概览"))
        }
    }

    private func resourcesSection(_ container: ContainerInstance) -> some View {
        Section {
            field(
                localization.string("detail.field.cpu", defaultValue: "CPU"),
                container.cpus > 0
                    ? localization.format("detail.value.coresFormat", defaultValue: "%d 核", container.cpus)
                    : none
            )
            field(
                localization.string("detail.field.memory", defaultValue: "内存"),
                container.memoryBytes > 0
                    ? ContainerIndicatorFormatting.bytes(container.memoryBytes)
                    : none
            )
            field(
                localization.string("detail.field.storageQuota", defaultValue: "存储配额"),
                container.configuration.storageQuotaBytes.map(ContainerIndicatorFormatting.bytes)
                    ?? localization.string("detail.value.notSet", defaultValue: "未设置")
            )
            field(
                localization.string("detail.field.imageSize", defaultValue: "镜像大小"),
                container.imageStorageBytes.map(ContainerIndicatorFormatting.bytes) ?? none
            )
        } header: {
            sectionTitle(localization.string("detail.section.resources", defaultValue: "资源"))
        }
    }

    private func runtimeSection(_ container: ContainerInstance) -> some View {
        let configuration = container.configuration
        return Section {
            field(
                localization.string("detail.field.platform", defaultValue: "平台"),
                configuration.platform.isEmpty ? none : configuration.platform
            )
            field(
                localization.string("detail.field.runtime", defaultValue: "运行时"),
                configuration.runtimeHandler.isEmpty ? none : configuration.runtimeHandler
            )
            field(
                localization.string("detail.field.readOnly", defaultValue: "只读"),
                boolean(configuration.readOnly)
            )
            field(
                localization.string("detail.field.rosetta", defaultValue: "Rosetta"),
                boolean(configuration.rosetta)
            )
            field(
                localization.string("detail.field.ssh", defaultValue: "SSH"),
                boolean(configuration.ssh)
            )
        } header: {
            sectionTitle(localization.string("detail.section.runtime", defaultValue: "运行时"))
        }
    }

    private func networkSection(_ container: ContainerInstance) -> some View {
        let configuration = container.configuration
        return Section {
            field(
                localization.string("detail.field.network", defaultValue: "网络"),
                configuration.networks.isEmpty ? none : configuration.networks.joined(separator: ", ")
            )
            field(
                localization.string("detail.field.hostname", defaultValue: "主机名"),
                configuration.hostname.isEmpty ? none : configuration.hostname
            )
            field(
                localization.string("detail.field.ports", defaultValue: "端口"),
                configuration.ports.isEmpty ? none : configuration.ports.joined(separator: "\n")
            )
            field(
                localization.string("detail.field.dnsDomain", defaultValue: "DNS 域"),
                configuration.dnsDomain.isEmpty ? none : configuration.dnsDomain
            )
            field(
                localization.string("detail.field.dnsServers", defaultValue: "DNS 服务器"),
                configuration.dnsServers.isEmpty ? none : configuration.dnsServers.joined(separator: ", ")
            )
        } header: {
            sectionTitle(localization.string("detail.section.network", defaultValue: "网络"))
        }
    }

    private func processSection(_ container: ContainerInstance) -> some View {
        let configuration = container.configuration
        return Section {
            field(
                localization.string("detail.field.command", defaultValue: "命令"),
                configuration.command.isEmpty ? none : configuration.command
            )
            field(
                localization.string("detail.field.workdir", defaultValue: "工作目录"),
                configuration.workingDirectory.isEmpty ? none : configuration.workingDirectory
            )
            field(
                localization.string("detail.field.user", defaultValue: "用户"),
                configuration.user.isEmpty ? none : configuration.user
            )
            field(
                localization.string("detail.field.environment", defaultValue: "环境变量"),
                configuration.environmentKeys.isEmpty
                    ? none
                    : localization.format(
                        "detail.value.environmentCountFormat",
                        defaultValue: "%d 项（值已隐藏）",
                        configuration.environmentKeys.count
                    )
            )
            if !configuration.environmentKeys.isEmpty {
                field(
                    localization.string("detail.field.environmentKeys", defaultValue: "变量名"),
                    configuration.environmentKeys.joined(separator: "\n")
                )
            }
        } header: {
            sectionTitle(localization.string("detail.section.process", defaultValue: "进程"))
        }
    }

    private func liveSection(_ container: ContainerInstance) -> some View {
        let history = controller.performanceHistory[container.id] ?? []
        return Section {
            VStack(spacing: 10) {
                if let failure = controller.retainedDataWarning {
                    staleBanner(
                        failure: failure,
                        sampledAt: container.performance?.sampledAt
                    )
                }
                ContainerIndicatorLiveMetricCard(
                    title: localization.string("detail.field.cpu", defaultValue: "CPU"),
                    value: container.performance?.cpuPercent
                        .map(ContainerIndicatorFormatting.percent) ?? placeholder,
                    points: ContainerIndicatorMetricSeries.cpu(history),
                    color: Color(nsColor: .systemBlue),
                    locale: runtimeLocale.locale,
                    collectingText: localization.string(
                        "detail.live.collecting",
                        defaultValue: "采集中…"
                    ),
                    format: ContainerIndicatorFormatting.percent
                )
                ContainerIndicatorLiveMetricCard(
                    title: localization.string("detail.field.memory", defaultValue: "内存"),
                    value: memoryUsage(container.performance),
                    points: ContainerIndicatorMetricSeries.memoryMegabytes(history),
                    color: Color(nsColor: .systemPurple),
                    locale: runtimeLocale.locale,
                    collectingText: localization.string(
                        "detail.live.collecting",
                        defaultValue: "采集中…"
                    ),
                    format: { ContainerIndicatorFormatting.bytes(Int($0 * 1_048_576)) }
                )
                ContainerIndicatorLiveMetricCard(
                    title: localization.string("detail.field.disk", defaultValue: "磁盘"),
                    value: diskUsage(container.performance),
                    points: ContainerIndicatorMetricSeries.diskKilobytesPerSecond(history),
                    color: Color(nsColor: .systemOrange),
                    locale: runtimeLocale.locale,
                    collectingText: localization.string(
                        "detail.live.collecting",
                        defaultValue: "采集中…"
                    ),
                    format: { ContainerIndicatorFormatting.rate($0 * 1024) }
                )
            }
            .padding(.vertical, 2)
        } header: {
            sectionTitle(localization.string("detail.section.live", defaultValue: "实时"))
        }
    }

    /// A failed stats read keeps the last numbers and chart visible, so the
    /// window has to say that they are retained rather than live.
    private func staleBanner(failure: String, sampledAt: Date?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.string("detail.live.stale", defaultValue: "数据已过期"))
                    .font(PluginTypography.caption.font.weight(.semibold))
                Text(failure)
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let sampledAt {
                    Text(
                        localization.format(
                            "detail.live.lastSampleFormat",
                            defaultValue: "最后采样 %@",
                            formattedTime(sampledAt)
                        )
                    )
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .systemOrange).opacity(0.12))
        )
    }

    // MARK: Rows

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var missingState: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(localization.string("detail.containerMissing", defaultValue: "容器已不存在"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Values

    private var none: String {
        localization.string("detail.value.none", defaultValue: "无")
    }

    private var placeholder: String {
        "—"
    }

    private func boolean(_ value: Bool) -> String {
        value
            ? localization.string("detail.value.yes", defaultValue: "是")
            : localization.string("detail.value.no", defaultValue: "否")
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return none }
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(runtimeLocale.locale)
        )
    }

    private func formattedTime(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .standard)
                .locale(runtimeLocale.locale)
        )
    }

    private func memoryUsage(_ performance: ContainerPerformance?) -> String {
        guard let performance, let usage = performance.memoryBytes else {
            return placeholder
        }
        let used = ContainerIndicatorFormatting.bytes(usage)
        guard let limit = performance.memoryLimitBytes, limit > 0 else {
            return used
        }
        return localization.format(
            "detail.value.memoryUsageFormat",
            defaultValue: "%1$@ / %2$@",
            used,
            ContainerIndicatorFormatting.bytes(limit)
        )
    }

    private func diskUsage(_ performance: ContainerPerformance?) -> String {
        guard let performance,
              let read = performance.diskReadBytesPerSecond,
              let write = performance.diskWriteBytesPerSecond else {
            return placeholder
        }
        return localization.format(
            "detail.value.diskUsageFormat",
            defaultValue: "读 %1$@ · 写 %2$@",
            ContainerIndicatorFormatting.rate(read),
            ContainerIndicatorFormatting.rate(write)
        )
    }
}

// MARK: - Live metric card

/// One live metric: the latest reading next to a sparkline of the retained
/// samples. The axes stay hidden because the value above carries the number
/// and the shape carries the trend. Hovering a chart replaces the reading with
/// the hovered sample's time and value.
private struct ContainerIndicatorLiveMetricCard: View {
    let title: String
    let value: String
    let points: [ContainerIndicatorMetricPoint]
    let color: Color
    let locale: Locale
    let collectingText: String
    let format: (Double) -> String

    @State private var hoveredIndex: Int?

    private var hoveredPoint: ContainerIndicatorMetricPoint? {
        guard let hoveredIndex, points.indices.contains(hoveredIndex) else {
            return nil
        }
        return points[hoveredIndex]
    }

    private var displayValue: String {
        guard let hoveredPoint else { return value }
        let time = hoveredPoint.timestamp.formatted(
            Date.FormatStyle(date: .omitted, time: .standard).locale(locale)
        )
        return "\(time) · \(format(hoveredPoint.value))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(displayValue)
                    .font(PluginTypography.value.font)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            chart
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var chart: some View {
        if points.count >= 2 {
            Chart {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Sample", point.index),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(color.opacity(0.15))
                    LineMark(
                        x: .value("Sample", point.index),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
                }
                if let hoveredPoint {
                    RuleMark(x: .value("Sample", hoveredPoint.index))
                        .foregroundStyle(color.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    PointMark(
                        x: .value("Sample", hoveredPoint.index),
                        y: .value("Value", hoveredPoint.value)
                    )
                    .foregroundStyle(color)
                    .symbolSize(28)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            // Zero-anchored areas turn a nearly constant series into a solid
            // block; the padded range keeps the line's shape visible.
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 46)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            updateHover(phase, proxy: proxy, geometry: geometry)
                        }
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(color.opacity(0.08))
                .frame(height: 46)
                .overlay {
                    Text(collectingText)
                        .font(PluginTypography.caption.font)
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private func updateHover(
        _ phase: HoverPhase,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        switch phase {
        case .active(let location):
            guard let plotFrame = proxy.plotFrame else {
                hoveredIndex = nil
                return
            }
            let frame = geometry[plotFrame]
            guard frame.contains(location) else {
                hoveredIndex = nil
                return
            }
            let sample: Double? = proxy.value(atX: location.x - frame.origin.x)
            guard let sample else { return }
            hoveredIndex = min(max(Int(sample.rounded()), 0), points.count - 1)
        case .ended:
            hoveredIndex = nil
        @unknown default:
            hoveredIndex = nil
        }
    }
}
