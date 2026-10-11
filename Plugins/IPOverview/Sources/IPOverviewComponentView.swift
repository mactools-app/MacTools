import SwiftUI
import MacToolsPluginKit

struct IPOverviewComponentView: View {
    private enum Layout {
        static let leakCardMinimumWidth: CGFloat = 240
        static let leakCardMaximumWidth: CGFloat = 360
    }

    @ObservedObject var viewModel: IPOverviewViewModel
    let localization: PluginLocalization
    let startsInDetails: Bool
    let showsBackButton: Bool
    let showsDetailHeader: Bool
    let managesScrolling: Bool
    @State private var customName = ""
    @State private var customURL = ""
    @State private var addError = ""
    @State private var presentedLeakDetails: IPOverviewLeakAssessmentKind?

    init(
        viewModel: IPOverviewViewModel,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        startsInDetails: Bool = false,
        showsBackButton: Bool = true,
        showsDetailHeader: Bool = true,
        managesScrolling: Bool = true
    ) {
        self.viewModel = viewModel
        self.localization = localization
        self.startsInDetails = startsInDetails
        self.showsBackButton = showsBackButton
        self.showsDetailHeader = showsDetailHeader
        self.managesScrolling = managesScrolling
    }

    var body: some View {
        Group {
            if viewModel.isShowingDetails {
                detailPage
            } else {
                landingCard
            }
        }
        .onAppear {
            viewModel.refreshAddresses()
            if startsInDetails {
                viewModel.showDetails()
            }
        }
    }

    private var landingCard: some View {
        Button {
            viewModel.showDetails()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "network")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                        .frame(width: 30, height: 30)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(localization.string("component.title", defaultValue: "IP 检测"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(viewModel.snapshot.preferredGeoInfo?.locationText ?? localization.string(
                            "landing.subtitle",
                            defaultValue: "公网、归属地与连通性"
                        ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 8)

                    if viewModel.snapshot.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 8) {
                    landingMetric(
                        title: localization.string("landing.domestic", defaultValue: "国内出口"),
                        value: landingEgressValue(
                            viewModel.snapshot.domesticIPv4 ?? viewModel.snapshot.domesticIPv6
                        )
                    )
                    landingMetric(
                        title: localization.string("landing.international", defaultValue: "国际出口"),
                        value: landingEgressValue(
                            viewModel.snapshot.internationalIPv4 ?? viewModel.snapshot.internationalIPv6
                        )
                    )
                    landingMetric(
                        title: localization.string("landing.local", defaultValue: "本地"),
                        value: viewModel.snapshot.localAddresses.first.map { displayIP($0.address) }
                            ?? localization.string("common.waiting", defaultValue: "等待")
                    )
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detailPage: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            if showsDetailHeader {
                detailHeader
            } else {
                detailToolbar
            }

            if managesScrolling {
                ScrollView(.vertical, showsIndicators: false) {
                    detailSections
                }
            } else {
                detailSections
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var detailSections: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            networkQualitySection
            publicIPSection
            localAddressSection
            connectivitySection
            webRTCLeakSection
            dnsLeakSection
            privacyFooter
        }
        .padding(.bottom, 2)
    }

    private var detailHeader: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            if showsBackButton {
                Button {
                    viewModel.showSummary()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(.borderless)
                .help(localization.string("detail.back.help", defaultValue: "返回概览"))
            }

            Text(localization.string("detail.title", defaultValue: "IP 详情"))
                .font(PluginSettingsTheme.Typography.sectionTitle)

            Spacer(minLength: 8)

            detailActions
        }
    }

    private var detailToolbar: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Spacer(minLength: 0)
            detailActions
        }
    }

    private var detailActions: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            if viewModel.snapshot.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                viewModel.toggleSensitiveInfoVisibility()
            } label: {
                Image(systemName: viewModel.hidesSensitiveInfo ? "eye.slash" : "eye")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(viewModel.hidesSensitiveInfo
                ? localization.string("privacy.showIP.help", defaultValue: "显示 IP")
                : localization.string("privacy.hideIP.help", defaultValue: "隐藏 IP")
            )

            Button {
                viewModel.refreshAll()
            } label: {
                Label(
                    viewModel.isRefreshingAll
                        ? localization.string("detail.refreshing", defaultValue: "检测中")
                        : localization.string("detail.refresh", defaultValue: "检测"),
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.isRefreshingAll)
            .help(localization.string("detail.refresh.help", defaultValue: "刷新全部检测"))

            Button {
                viewModel.copy(viewModel.snapshot.reportText(localization: localization))
            } label: {
                Label(localization.string("detail.copyReport", defaultValue: "复制结果"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.snapshot.lastUpdated == nil)
            .help(localization.string("detail.copyReport.help", defaultValue: "复制完整检测结果"))
        }
    }

    private var publicIPSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                sectionHeader(
                    title: localization.string("publicIP.title", defaultValue: "公网 IP"),
                    icon: "network"
                )
                Spacer(minLength: 4)
                Button {
                    viewModel.refresh()
                } label: {
                    Label(
                        viewModel.snapshot.isRefreshing
                            ? localization.string("status.checking", defaultValue: "检测中")
                            : localization.string("common.refresh", defaultValue: "刷新"),
                        systemImage: viewModel.snapshot.isRefreshing ? "hourglass" : "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.snapshot.isRefreshing)
                .help(localization.string("publicIP.refresh.help", defaultValue: "刷新公网 IP 和归属地"))
            }

            VStack(spacing: 0) {
                publicIPRow(
                    title: "IPv4",
                    route: .domestic,
                    result: viewModel.snapshot.domesticIPv4
                )
                PluginSettingsListDivider()
                publicIPRow(
                    title: "IPv4",
                    route: .international,
                    result: viewModel.snapshot.internationalIPv4
                )
                PluginSettingsListDivider()
                publicIPRow(
                    title: "IPv6",
                    route: .domestic,
                    result: viewModel.snapshot.domesticIPv6
                )
                PluginSettingsListDivider()
                publicIPRow(
                    title: "IPv6",
                    route: .international,
                    result: viewModel.snapshot.internationalIPv6
                )
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private func publicIPRow(
        title: String,
        route: IPOverviewEgressRoute,
        result: IPOverviewPublicIPResult?
    ) -> some View {
        let geoInfo = result.flatMap { viewModel.snapshot.geoInfoByIP[$0.ip] }

        return PublicIPRowView(
            title: title,
            route: route,
            result: result,
            geoInfo: geoInfo,
            notDetectedText: notDetectedText,
            geoUnavailableText: localization.string("ipCard.geoUnavailable", defaultValue: "归属地不可用"),
            unknownText: unknownText,
            localization: localization,
            displayIP: result.map { displayIP($0.ip) },
            onCopyIP: { viewModel.copy(result?.ip) }
        )
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var localAddressSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(title: localization.string("local.title", defaultValue: "本地局域网 IP"), icon: "wifi.router")

            VStack(spacing: 0) {
                if viewModel.snapshot.localAddresses.isEmpty {
                    Text(localization.string("local.empty", defaultValue: "未检测到可用本地地址"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .pluginSettingsListRowPadding()
                } else {
                    ForEach(Array(viewModel.snapshot.localAddresses.prefix(5).enumerated()), id: \.element.id) { index, address in
                        localAddressRow(address)
                        if index < min(viewModel.snapshot.localAddresses.count, 5) - 1 {
                            PluginSettingsListDivider()
                        }
                    }
                }
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private func localAddressRow(_ address: IPOverviewLocalAddress) -> some View {
        LocalAddressRowView(
            address: address,
            displayAddress: displayIP(address.address),
            localization: localization,
            onCopyIP: { viewModel.copy(address.address) }
        )
        .pluginSettingsListRowPadding()
    }

    private var networkQualitySection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                sectionHeader(
                    title: localization.string("speed.title", defaultValue: "网络测速"),
                    icon: "speedometer"
                )
                Spacer(minLength: 4)
                Button {
                    viewModel.measureNetworkQuality()
                } label: {
                    Label(
                        viewModel.isMeasuringNetworkQuality
                            ? localization.string("speed.running", defaultValue: "测速中")
                            : localization.string("common.refresh", defaultValue: "刷新"),
                        systemImage: viewModel.isMeasuringNetworkQuality ? "hourglass" : "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isMeasuringNetworkQuality)
                .help(localization.string("speed.start.help", defaultValue: "使用 macOS networkQuality 测量当前网络"))
            }

            NetworkQualityCardView(
                state: viewModel.networkQualityState,
                localization: localization
            )
        }
    }

    private var connectivitySection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                sectionHeader(
                    title: localization.string("connectivity.title", defaultValue: "网络连通性"),
                    icon: "point.3.connected.trianglepath.dotted"
                )
                Spacer(minLength: 4)
                Button {
                    viewModel.checkConnectivity()
                } label: {
                    Label(
                        viewModel.isCheckingConnectivity
                            ? localization.string("status.checking", defaultValue: "检测中")
                            : localization.string("common.refresh", defaultValue: "刷新"),
                        systemImage: viewModel.isCheckingConnectivity ? "hourglass" : "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isCheckingConnectivity)
                .help(localization.string("connectivity.refresh.help", defaultValue: "刷新连通性"))
            }

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ForEach(viewModel.connectivityResults) { result in
                        connectivityTile(result)
                    }
                }

                customTargetForm
            }
            .padding(PluginSettingsTheme.Spacing.cardContent)
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var webRTCLeakSection: some View {
        leakSection(
            kind: .webRTC,
            title: localization.string("webrtc.title", defaultValue: "WebRTC 泄露测试"),
            icon: "network.badge.shield.half.filled",
            isRunning: viewModel.isCheckingWebRTC,
            action: { viewModel.checkWebRTCLeak() },
            results: viewModel.webRTCResults,
            showsNAT: true
        )
    }

    private var dnsLeakSection: some View {
        leakSection(
            kind: .dns,
            title: localization.string("dns.title", defaultValue: "DNS 泄露测试"),
            icon: "octagon.fill",
            isRunning: viewModel.isCheckingDNSLeak,
            action: { viewModel.checkDNSLeak() },
            results: viewModel.dnsLeakResults,
            showsNAT: false
        )
    }

    private func leakSection(
        kind: IPOverviewLeakAssessmentKind,
        title: String,
        icon: String,
        isRunning: Bool,
        action: @escaping () -> Void,
        results: [IPOverviewLeakTestResult],
        showsNAT: Bool
    ) -> some View {
        let assessment = IPOverviewLeakAssessment.evaluate(
            kind: kind,
            results: results,
            snapshot: viewModel.snapshot,
            isRunning: isRunning
        )

        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Label(title, systemImage: icon)
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(action: action) {
                    Label(
                        isRunning
                            ? localization.string("status.checking", defaultValue: "检测中")
                            : localization.string("common.refresh", defaultValue: "刷新"),
                        systemImage: isRunning ? "hourglass" : "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRunning)
            }

            leakSummaryCard(assessment, results: results, showsNAT: showsNAT)
        }
    }

    private func leakSummaryCard(
        _ assessment: IPOverviewLeakAssessment,
        results: [IPOverviewLeakTestResult],
        showsNAT: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: leakAssessmentIcon(assessment.state))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(leakAssessmentColor(assessment.state))
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(leakAssessmentTitle(assessment))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    .foregroundStyle(leakAssessmentColor(assessment.state))
                Text(leakAssessmentDetail(assessment))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Text(leakAssessmentBadge(assessment))
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(leakAssessmentColor(assessment.state))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        leakAssessmentColor(assessment.state).opacity(0.12),
                        in: Capsule()
                    )
                    .fixedSize()

                Button {
                    presentedLeakDetails = assessment.kind
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(localization.string("leak.details.help", defaultValue: "查看检测详情"))
                .popover(
                    isPresented: Binding(
                        get: { presentedLeakDetails == assessment.kind },
                        set: { isPresented in
                            presentedLeakDetails = isPresented ? assessment.kind : nil
                        }
                    ),
                    arrowEdge: .trailing
                ) {
                    leakDetailsPopover(
                        assessment: assessment,
                        results: results,
                        showsNAT: showsNAT
                    )
                }
            }
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.standard)
    }

    private func leakDetailsPopover(
        assessment: IPOverviewLeakAssessment,
        results: [IPOverviewLeakTestResult],
        showsNAT: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: leakAssessmentIcon(assessment.state))
                    .foregroundStyle(leakAssessmentColor(assessment.state))
                Text(localization.string("leak.details.title", defaultValue: "检测详情"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Spacer(minLength: 8)
                Text(leakEvidenceCountText(assessment))
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    LeakEvidenceListRowView(
                        result: result,
                        showsNAT: showsNAT,
                        unknownText: unknownText,
                        localization: localization,
                        color: leakColor(result.status),
                        primaryText: leakPrimaryText(result.status),
                        displayIP: result.endpoint.map { displayIP($0.ip) },
                        onCopyIP: { viewModel.copy(result.endpoint?.ip) }
                    )

                    if index < results.count - 1 {
                        Divider()
                    }
                }
            }
            .background(
                PluginSettingsTheme.Palette.recessedControlBackground,
                in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control, style: .continuous)
            )
        }
        .padding(12)
        .frame(width: 380)
    }

    private func leakAssessmentTitle(_ assessment: IPOverviewLeakAssessment) -> String {
        switch assessment.kind {
        case .webRTC:
            switch assessment.state {
            case .waiting:
                return localization.string("webrtc.assessment.waiting", defaultValue: "等待 WebRTC 检测")
            case .checking:
                return localization.string("webrtc.assessment.checking", defaultValue: "正在检测 WebRTC")
            case .clear:
                return localization.string("webrtc.assessment.clear", defaultValue: "未发现 WebRTC 泄露")
            case .warning:
                return localization.string("webrtc.assessment.warning", defaultValue: "可能存在 WebRTC 泄露")
            case .unknown:
                return localization.string("webrtc.assessment.unknown", defaultValue: "WebRTC 结果不完整")
            }
        case .dns:
            switch assessment.state {
            case .waiting:
                return localization.string("dns.assessment.waiting", defaultValue: "等待 DNS 检测")
            case .checking:
                return localization.string("dns.assessment.checking", defaultValue: "正在检测 DNS")
            case .clear:
                return localization.string("dns.assessment.clear", defaultValue: "未发现 DNS 泄露")
            case .warning:
                return localization.string("dns.assessment.warning", defaultValue: "可能存在 DNS 泄露")
            case .unknown:
                return localization.string("dns.assessment.unknown", defaultValue: "DNS 结果不完整")
            }
        }
    }

    private func leakAssessmentDetail(_ assessment: IPOverviewLeakAssessment) -> String {
        switch assessment.reason {
        case .waiting:
            return localization.string("leak.reason.waiting", defaultValue: "点击刷新后会检测出口是否和当前公网信息一致。")
        case .checking:
            return localization.string("leak.reason.checking", defaultValue: "正在收集各节点返回的出口信息。")
        case .noPublicIP:
            return localization.string("leak.reason.noPublicIP", defaultValue: "当前公网 IP 未获取完成，暂时无法建立对照。")
        case .noDNSEndpoint:
            return localization.string("leak.reason.noDNSEndpoint", defaultValue: "没有获取到 DNS 解析器出口，可能被网络或服务拦截。")
        case .webRTCMatchesPublicIP:
            return localization.string("leak.reason.webRTCMatchesPublicIP", defaultValue: "STUN 返回的出口与当前公网 IP 一致。")
        case .webRTCNoVisibleEndpoint:
            return localization.string("leak.reason.webRTCNoVisibleEndpoint", defaultValue: "未检测到 WebRTC 可见出口，通常表示 STUN 被阻断或不可达。")
        case .webRTCDifferentIP:
            return localization.string("leak.reason.webRTCDifferentIP", defaultValue: "STUN 返回了不同于当前公网 IP 的出口。")
        case .dnsMatchesEgressRegion:
            return localization.string("leak.reason.dnsMatchesEgressRegion", defaultValue: "DNS 解析器出口地区与当前公网出口一致。")
        case .dnsDifferentEgressRegion:
            return localization.string("leak.reason.dnsDifferentEgressRegion", defaultValue: "DNS 解析器出口地区与当前公网出口不一致。")
        case .dnsObservedWithoutBaselineRegion:
            return localization.string("leak.reason.dnsObservedWithoutBaselineRegion", defaultValue: "已获取 DNS 出口，但公网归属地不足，暂时无法对照。")
        }
    }

    private func leakAssessmentBadge(_ assessment: IPOverviewLeakAssessment) -> String {
        leakStateBadge(assessment.state)
    }

    private func leakStateBadge(_ state: IPOverviewLeakAssessmentState) -> String {
        switch state {
        case .waiting:
            return localization.string("leak.badge.waiting", defaultValue: "待检测")
        case .checking:
            return localization.string("leak.badge.checking", defaultValue: "检测中")
        case .clear:
            return localization.string("leak.badge.clear", defaultValue: "通过")
        case .warning:
            return localization.string("leak.badge.warning", defaultValue: "注意")
        case .unknown:
            return localization.string("leak.badge.unknown", defaultValue: "无法判断")
        }
    }

    private func leakEvidenceCountText(_ assessment: IPOverviewLeakAssessment) -> String {
        localization.format(
            "leak.evidence.count",
            defaultValue: "%d/%d 个节点有结果",
            assessment.observedCount,
            assessment.totalCount
        )
    }

    private func leakAssessmentColor(_ state: IPOverviewLeakAssessmentState) -> Color {
        switch state {
        case .waiting:
            return .secondary
        case .checking:
            return Color(nsColor: .systemBlue)
        case .clear:
            return Color(nsColor: .systemGreen)
        case .warning:
            return Color(nsColor: .systemRed)
        case .unknown:
            return Color(nsColor: .systemOrange)
        }
    }

    private func leakAssessmentIcon(_ state: IPOverviewLeakAssessmentState) -> String {
        switch state {
        case .waiting:
            return "clock"
        case .checking:
            return "hourglass"
        case .clear:
            return "checkmark.shield"
        case .warning:
            return "exclamationmark.triangle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private func connectivityTile(_ result: IPOverviewConnectivityResult) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connectivityColor(result.status))
                .frame(width: 7, height: 7)
            Text(result.target.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(connectivityText(result.status))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if result.target.isCustom {
                Button {
                    viewModel.removeConnectivityTarget(id: result.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var customTargetForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(localization.string("customTarget.name.placeholder", defaultValue: "名称"), text: $customName)
                    .textFieldStyle(.roundedBorder)
                TextField("https://example.com", text: $customURL)
                    .textFieldStyle(.roundedBorder)
                Button {
                    addCustomTarget()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(customName.isEmpty || customURL.isEmpty)
            }

            if !addError.isEmpty {
                Text(addError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var privacyFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
            Text(localization.string(
                "privacy.footer",
                defaultValue: "公网、归属地和连通性检测会请求外部服务；本地地址仅在本机读取。"
            ))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func landingMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }

    private func addCustomTarget() {
        if let error = viewModel.addConnectivityTarget(name: customName, urlString: customURL) {
            addError = error
            return
        }

        addError = ""
        customName = ""
        customURL = ""
    }

    private func connectivityColor(_ status: IPOverviewConnectivityResult.Status) -> Color {
        switch status {
        case .waiting:
            return .secondary.opacity(0.45)
        case .checking:
            return Color(nsColor: .systemBlue)
        case .reachable(let milliseconds):
            return milliseconds < 250 ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)
        case .unreachable:
            return Color(nsColor: .systemRed)
        }
    }

    private func connectivityText(_ status: IPOverviewConnectivityResult.Status) -> String {
        switch status {
        case .waiting:
            return localization.string("status.waiting", defaultValue: "等待检测")
        case .checking:
            return localization.string("status.checking", defaultValue: "检测中")
        case .reachable(let milliseconds):
            return "\(milliseconds) ms"
        case .unreachable:
            return localization.string("connectivity.unreachable", defaultValue: "不可达")
        }
    }

    private func leakColor(_ status: IPOverviewLeakTestResult.Status) -> Color {
        switch status {
        case .waiting:
            return .secondary.opacity(0.45)
        case .checking:
            return Color(nsColor: .systemBlue)
        case .success:
            return Color(nsColor: .systemBlue)
        case .failure:
            return .secondary.opacity(0.65)
        }
    }

    private func leakPrimaryText(_ status: IPOverviewLeakTestResult.Status) -> String {
        switch status {
        case .waiting:
            return localization.string("status.waiting", defaultValue: "等待检测")
        case .checking:
            return localization.string("status.checking", defaultValue: "检测中")
        case .success(let endpoint):
            return endpoint.ip
        case .failure:
            return localization.string("leak.failed", defaultValue: "获取失败")
        }
    }

    private var unknownText: String {
        localization.string("common.unknown", defaultValue: "未知")
    }

    private var notDetectedText: String {
        localization.string("common.notDetected", defaultValue: "未检测到")
    }

    private func landingEgressValue(_ result: IPOverviewPublicIPResult?) -> String {
        if let result {
            return displayIP(result.ip)
        }

        if viewModel.snapshot.isRefreshing || viewModel.snapshot.lastUpdated == nil {
            return localization.string("common.checking", defaultValue: "检测中")
        }

        return notDetectedText
    }

    private func displayIP(_ value: String) -> String {
        viewModel.hidesSensitiveInfo ? IPOverviewSensitiveValueMask.maskedIP(value) : value
    }
}

private struct PublicIPRowView: View {
    let title: String
    let route: IPOverviewEgressRoute
    let result: IPOverviewPublicIPResult?
    let geoInfo: IPOverviewGeoInfo?
    let notDetectedText: String
    let geoUnavailableText: String
    let unknownText: String
    let localization: PluginLocalization
    let displayIP: String?
    let onCopyIP: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            HStack(alignment: .center, spacing: 4) {
                if let result {
                    Text(displayIP ?? result.ip)
                        .font(PluginTypography.code.font.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .layoutPriority(1)
                } else {
                    Text(notDetectedText)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }

                IPOverviewTagBadge(title: title, style: .addressFamily(title))
                IPOverviewTagBadge(title: route.title(localization: localization), style: .egressRoute(route))

                IPOverviewInlineCopyButton(
                    help: localization.format(
                        "copy.ip.help",
                        defaultValue: "复制 %@ IP",
                        title
                    ),
                    action: onCopyIP
                )
                .opacity(isHovered && result != nil ? 1 : 0)
                .allowsHitTesting(isHovered && result != nil)

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
            }

            if result != nil {
                if geoInfo != nil {
                    publicIPDetails
                        .padding(.top, 2)
                } else {
                    unavailableGeoInfo
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var publicIPDetails: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                publicIPDetailValues
            }

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                publicIPDetailValues
            }
        }
    }

    @ViewBuilder
    private var publicIPDetailValues: some View {
        detailValue(
            title: localization.string("info.location", defaultValue: "位置"),
            value: geoInfo?.locationText ?? geoInfo?.countryDisplayText ?? geoUnavailableText,
            icon: "mappin.and.ellipse"
        )
        detailValue(
            title: localization.string("info.isp", defaultValue: "运营商"),
            value: geoInfo?.organization ?? geoInfo?.isp ?? unknownText,
            icon: "server.rack"
        )
        detailValue(
            title: "ASN",
            value: geoInfo?.asn ?? unknownText,
            icon: "building.2"
        )
    }

    private func detailValue(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(.secondary)

            Text(value)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unavailableGeoInfo: some View {
        Text(geoUnavailableText)
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }
}

private struct LocalAddressRowView: View {
    let address: IPOverviewLocalAddress
    let displayAddress: String
    let localization: PluginLocalization
    let onCopyIP: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(address.interfaceName)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                HStack(alignment: .center, spacing: 4) {
                    Text(displayAddress)
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .layoutPriority(1)

                    IPOverviewTagBadge(title: address.family.rawValue, style: .addressFamily(address.family.rawValue))

                    IPOverviewInlineCopyButton(
                        help: localization.format(
                            "copy.ip.help",
                            defaultValue: "复制 %@ IP",
                            address.family.rawValue
                        ),
                        action: onCopyIP
                    )
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                }
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct NetworkQualityCardView: View {
    let state: IPOverviewNetworkQualityRunState
    let localization: PluginLocalization

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .waiting:
                chartContent(
                    progress: .started(),
                    measurement: nil
                )
            case .running(let progress):
                chartContent(
                    progress: progress,
                    measurement: nil
                )
            case .completed(let measurement, let progress):
                chartContent(
                    progress: progress,
                    measurement: measurement
                )
            case .failed(let message):
                failureContent(message)
            }
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .pluginSettingsCardBackground(.standard)
    }

    private func chartContent(
        progress: IPOverviewNetworkQualityProgress,
        measurement: IPOverviewNetworkQualityMeasurement?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NetworkQualityGraphPanel(
                progress: progress,
                measurement: measurement,
                localization: localization
            )

            if let measurement {
                NetworkQualityResultStrip(measurement: measurement, localization: localization)
                metadataRow(measurement)
            } else {
                Text(localization.string(
                    "speed.waiting.description",
                    defaultValue: "点击刷新后，会顺序测量下载、上传、延迟和响应性。"
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func failureContent(_ message: String) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: "exclamationmark.triangle")
                .pluginSettingsRowIconStyle(Color(nsColor: .systemOrange))
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(localization.string("speed.failed.title", defaultValue: "测速失败"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(message)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataRow(_ measurement: IPOverviewNetworkQualityMeasurement) -> some View {
        HStack(spacing: 8) {
            if let interfaceName = measurement.interfaceName, !interfaceName.isEmpty {
                Label(interfaceName, systemImage: "antenna.radiowaves.left.and.right")
            }
            if let endpoint = measurement.testEndpoint, !endpoint.isEmpty {
                Label(endpoint, systemImage: "server.rack")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let totalDuration = measurement.totalPhaseDuration {
                Label(durationText(totalDuration), systemImage: "clock")
            }
            Spacer(minLength: 0)
        }
        .font(PluginSettingsTheme.Typography.statusBadge)
        .foregroundStyle(.secondary)
    }

    private func durationText(_ value: TimeInterval) -> String {
        localization.format("speed.duration.seconds", defaultValue: "%.1f 秒", value)
    }
}

private struct NetworkQualityGraphPanel: View {
    private enum Layout {
        static let contentSpacing: CGFloat = 16
        static let gaugeSize: CGFloat = 132
        static let sparklineSpacing: CGFloat = 10
        static let minimumHeight: CGFloat = 144
        static let verticalPadding: CGFloat = 2
    }

    let progress: IPOverviewNetworkQualityProgress
    let measurement: IPOverviewNetworkQualityMeasurement?
    let localization: PluginLocalization

    var body: some View {
        HStack(alignment: .center, spacing: Layout.contentSpacing) {
            NetworkQualityGaugeView(
                value: gaugeValue,
                maximumValue: gaugeMaximum,
                subtitle: gaugeSubtitle,
                tint: gaugeTint
            )
            .frame(width: Layout.gaugeSize, height: Layout.gaugeSize)

            VStack(alignment: .leading, spacing: Layout.sparklineSpacing) {
                NetworkQualitySparklineView(
                    title: localization.string("speed.download", defaultValue: "下载"),
                    valueText: valueText(measurement?.downloadMbps ?? progress.latestDownloadMbps, unit: "Mbps"),
                    samples: sparklineSamples(progress.downloadSamples, fallback: measurement?.downloadMbps),
                    tint: Color(nsColor: .systemTeal)
                )
                NetworkQualitySparklineView(
                    title: localization.string("speed.upload", defaultValue: "上传"),
                    valueText: valueText(measurement?.uploadMbps ?? progress.latestUploadMbps, unit: "Mbps"),
                    samples: sparklineSamples(progress.uploadSamples, fallback: measurement?.uploadMbps),
                    tint: Color(nsColor: .systemCyan)
                )
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, Layout.verticalPadding)
        .frame(maxWidth: .infinity, minHeight: Layout.minimumHeight, alignment: .center)
    }

    private var gaugeValue: Double? {
        if let measurement {
            return measurement.downloadMbps
        }

        switch progress.phase {
        case .measuringUpload:
            return progress.latestUploadMbps
        case .measuringDownload:
            return progress.latestDownloadMbps
        case .initializing, .measuringLatency:
            return nil
        }
    }

    private var gaugeSubtitle: String {
        if let value = gaugeValue {
            return valueText(value, unit: "Mbps")
        }

        return "-- Mbps"
    }

    private var gaugeMaximum: Double {
        let value = gaugeValue ?? 0
        switch value {
        case ..<100:
            return 100
        case ..<300:
            return 300
        case ..<1_000:
            return 1_000
        default:
            return (ceil(value / 1_000) * 1_000)
        }
    }

    private var gaugeTint: Color {
        if measurement != nil {
            return Color(nsColor: .systemTeal)
        }

        return progress.phase.tint
    }

    private func sparklineSamples(_ samples: [Double], fallback: Double?) -> [Double] {
        if !samples.isEmpty {
            return samples
        }

        return fallback.map { [$0] } ?? []
    }

    private func valueText(_ value: Double?, unit: String) -> String {
        guard let value else {
            return "-- \(unit)"
        }

        let format = value >= 100 ? "%.0f %@" : value >= 10 ? "%.1f %@" : "%.2f %@"
        return String(format: format, value, unit)
    }
}

private struct NetworkQualityGaugeView: View {
    private enum Layout {
        static let backgroundSize: CGFloat = 104
        static let lineWidth: CGFloat = 9
    }

    let value: Double?
    let maximumValue: Double
    let subtitle: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(PluginSettingsTheme.Surface.raisedControl)
                .opacity(0.66)
                .frame(width: Layout.backgroundSize, height: Layout.backgroundSize)
            GaugeArc(progress: 1)
                .stroke(
                    .secondary.opacity(0.15),
                    style: StrokeStyle(lineWidth: Layout.lineWidth, lineCap: .round)
                )
            GaugeArc(progress: progress)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: Layout.lineWidth, lineCap: .round)
                )
            VStack(spacing: 0) {
                Text(subtitle)
                    .font(PluginTypography.metric.font)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
    }

    private var progress: Double {
        guard let value else {
            return 0.08
        }

        return min(max(value / maximumValue, 0.08), 1)
    }

}

private struct GaugeArc: Shape {
    let progress: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let radius = size / 2 - 10
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = Angle.degrees(135)
        let end = Angle.degrees(135 + 270 * min(max(progress, 0), 1))
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        return path
    }
}

private struct NetworkQualitySparklineView: View {
    private enum Layout {
        static let contentSpacing: CGFloat = 5
        static let headerSpacing: CGFloat = 6
        static let chartHeight: CGFloat = 48
    }

    let title: String
    let valueText: String
    let samples: [Double]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.contentSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.headerSpacing) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(valueText)
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(tint)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if let maximumText {
                    Text(maximumText)
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(PluginSettingsTheme.Surface.raisedControl)
                        .opacity(0.42)
                    NetworkQualityGrid()
                        .stroke(.secondary.opacity(0.11), lineWidth: 0.7)
                    if normalizedSamples.isEmpty {
                        NetworkQualityBaseline()
                            .stroke(
                                .secondary.opacity(0.18),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                            )
                    } else {
                        NetworkQualityArea(samples: normalizedSamples)
                            .fill(tint.opacity(0.14))
                        NetworkQualityLine(samples: normalizedSamples)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .shadow(color: tint.opacity(0.20), radius: 2, x: 0, y: 1)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: Layout.chartHeight)
        }
    }

    private var maximumText: String? {
        guard let maximum = samples.max(), maximum > 0 else {
            return nil
        }

        let format = maximum >= 100 ? "%.0f max" : maximum >= 10 ? "%.1f max" : "%.2f max"
        return String(format: format, maximum)
    }

    private var normalizedSamples: [Double] {
        guard !samples.isEmpty else {
            return []
        }

        let maximum = max(samples.max() ?? 1, 1)
        return samples.map { min(max($0 / maximum, 0.02), 1) }
    }
}

private extension CGRect {
    var networkQualityPlotRect: CGRect {
        insetBy(dx: 6, dy: 5)
    }
}

private struct NetworkQualityGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let plotRect = rect.networkQualityPlotRect
        let columns = 12
        let rows = 4
        for column in 0...columns {
            let x = plotRect.minX + plotRect.width * CGFloat(column) / CGFloat(columns)
            path.move(to: CGPoint(x: x, y: plotRect.minY))
            path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
        }
        for row in 0...rows {
            let y = plotRect.minY + plotRect.height * CGFloat(row) / CGFloat(rows)
            path.move(to: CGPoint(x: plotRect.minX, y: y))
            path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
        }
        return path
    }
}

private struct NetworkQualityLine: Shape {
    let samples: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !samples.isEmpty else {
            return path
        }

        let plotRect = rect.networkQualityPlotRect
        let points = samples.enumerated().map { index, value in
            let x = samples.count == 1
                ? plotRect.midX
                : plotRect.minX + plotRect.width * CGFloat(index) / CGFloat(samples.count - 1)
            let y = plotRect.maxY - plotRect.height * CGFloat(value)
            return CGPoint(x: x, y: y)
        }

        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }
}

private struct NetworkQualityArea: Shape {
    let samples: [Double]

    func path(in rect: CGRect) -> Path {
        guard !samples.isEmpty else {
            return Path()
        }

        let plotRect = rect.networkQualityPlotRect
        var path = NetworkQualityLine(samples: samples).path(in: rect)
        let trailingX = samples.count == 1 ? plotRect.midX : plotRect.maxX
        let leadingX = samples.count == 1 ? plotRect.midX : plotRect.minX
        path.addLine(to: CGPoint(x: trailingX, y: plotRect.maxY))
        path.addLine(to: CGPoint(x: leadingX, y: plotRect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct NetworkQualityBaseline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let plotRect = rect.networkQualityPlotRect
        let y = plotRect.minY + plotRect.height * 0.68
        path.move(to: CGPoint(x: plotRect.minX, y: y))
        path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
        return path
    }
}

private struct NetworkQualityResultStrip: View {
    let measurement: IPOverviewNetworkQualityMeasurement
    let localization: PluginLocalization

    var body: some View {
        HStack(spacing: 0) {
            resultItem(
                title: localization.string("speed.download", defaultValue: "下载"),
                value: speedText(measurement.downloadMbps),
                unit: "Mbps",
                icon: "arrow.down.circle",
                tint: Color(nsColor: .systemTeal)
            )
            Divider().padding(.vertical, 5)
            resultItem(
                title: localization.string("speed.upload", defaultValue: "上传"),
                value: speedText(measurement.uploadMbps),
                unit: "Mbps",
                icon: "arrow.up.circle",
                tint: Color(nsColor: .systemCyan)
            )
            Divider().padding(.vertical, 5)
            resultItem(
                title: localization.string("speed.latency", defaultValue: "延迟"),
                value: integerText(measurement.baseRTTMilliseconds),
                unit: "ms",
                icon: "timer",
                tint: Color(nsColor: .systemOrange)
            )
            Divider().padding(.vertical, 5)
            resultItem(
                title: localization.string("speed.responsiveness", defaultValue: "响应性"),
                value: integerText(measurement.uploadResponsivenessRPM ?? measurement.downloadResponsivenessRPM),
                unit: "RPM",
                icon: "waveform.path.ecg",
                tint: Color(nsColor: .systemPurple)
            )
        }
        .padding(.vertical, 2)
    }

    private func resultItem(
        title: String,
        value: String,
        unit: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(tint)
                .lineLimit(1)
            PluginMetricValue(value, unit: unit)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func speedText(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }

        let format = value >= 100 ? "%.0f" : value >= 10 ? "%.1f" : "%.2f"
        return String(format: format, value)
    }

    private func integerText(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }

        return String(format: "%.0f", value)
    }
}

private extension IPOverviewNetworkQualityPhase {
    var systemImage: String {
        switch self {
        case .initializing:
            return "hourglass"
        case .measuringDownload:
            return "arrow.down.circle"
        case .measuringUpload:
            return "arrow.up.circle"
        case .measuringLatency:
            return "waveform.path.ecg"
        }
    }

    var tint: Color {
        switch self {
        case .initializing, .measuringDownload:
            return Color(nsColor: .systemTeal)
        case .measuringUpload:
            return Color(nsColor: .systemCyan)
        case .measuringLatency:
            return Color(nsColor: .systemPurple)
        }
    }
}

private extension IPOverviewNetworkQualityGrade {
    var systemImage: String {
        switch self {
        case .excellent:
            return "checkmark.seal.fill"
        case .good:
            return "checkmark.circle.fill"
        case .fair:
            return "exclamationmark.circle.fill"
        case .poor:
            return "exclamationmark.triangle.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .excellent:
            return Color(nsColor: .systemGreen)
        case .good:
            return Color(nsColor: .systemTeal)
        case .fair:
            return Color(nsColor: .systemOrange)
        case .poor:
            return Color(nsColor: .systemRed)
        case .unknown:
            return Color(nsColor: .secondaryLabelColor)
        }
    }
}

private struct LeakEvidenceListRowView: View {
    let result: IPOverviewLeakTestResult
    let showsNAT: Bool
    let unknownText: String
    let localization: PluginLocalization
    let color: Color
    let primaryText: String
    let displayIP: String?
    let onCopyIP: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(result.name)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        .lineLimit(1)
                    Text(statusText)
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(.secondary)
                }

                if let endpoint = result.endpoint {
                    HStack(spacing: 6) {
                        IPOverviewCopyableMonospacedValue(
                            value: displayIP ?? endpoint.ip,
                            help: localization.string("copy.leakEndpoint.help", defaultValue: "复制出口 IP"),
                            onCopy: onCopyIP
                        )
                        Text(endpoint.countryDisplayText ?? unknownText)
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text(detailText(endpoint))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(primaryText)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailText(_ endpoint: IPOverviewLeakEndpoint) -> String {
        var parts: [String] = []
        if let organization = endpoint.organization, !organization.isEmpty {
            parts.append(organization)
        }
        if showsNAT, let natType = endpoint.natType, !natType.isEmpty {
            parts.append(natType)
        }
        return parts.isEmpty ? unknownText : parts.joined(separator: " · ")
    }

    private var statusText: String {
        switch result.status {
        case .waiting:
            return localization.string("status.waiting", defaultValue: "等待检测")
        case .checking:
            return localization.string("status.checking", defaultValue: "检测中")
        case .success:
            return localization.string("leak.observed", defaultValue: "已获取")
        case .failure:
            return localization.string("leak.failed", defaultValue: "获取失败")
        }
    }
}

private struct IPOverviewTagBadge: View {
    let title: String
    let style: IPOverviewTagBadgeStyle

    var body: some View {
        Text(title)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(style.foregroundColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(style.backgroundColor)
            )
            .overlay(
                Capsule().stroke(style.strokeColor, lineWidth: 0.5)
            )
            .fixedSize()
    }
}

private enum IPOverviewTagBadgeStyle {
    case ipv4
    case ipv6
    case domestic
    case international

    static func addressFamily(_ title: String) -> IPOverviewTagBadgeStyle {
        title.uppercased() == "IPV6" ? .ipv6 : .ipv4
    }

    static func egressRoute(_ route: IPOverviewEgressRoute) -> IPOverviewTagBadgeStyle {
        switch route {
        case .domestic:
            return .domestic
        case .international:
            return .international
        }
    }

    var tint: Color {
        switch self {
        case .ipv4:
            return Self.adaptiveColor(
                light: NSColor(calibratedRed: 0.05, green: 0.32, blue: 0.72, alpha: 1),
                dark: .systemBlue
            )
        case .ipv6:
            return Self.adaptiveColor(
                light: NSColor(calibratedRed: 0.42, green: 0.20, blue: 0.68, alpha: 1),
                dark: .systemPurple
            )
        case .domestic:
            return Self.adaptiveColor(
                light: NSColor(calibratedRed: 0.08, green: 0.48, blue: 0.24, alpha: 1),
                dark: .systemGreen
            )
        case .international:
            return Self.adaptiveColor(
                light: NSColor(calibratedRed: 0.64, green: 0.34, blue: 0.00, alpha: 1),
                dark: .systemOrange
            )
        }
    }

    var foregroundColor: Color {
        tint
    }

    var backgroundColor: Color {
        tint.opacity(0.12)
    }

    var strokeColor: Color {
        tint.opacity(0.2)
    }

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private struct IPOverviewCopyableMonospacedValue: View {
    let value: String
    let help: String
    let onCopy: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(value)
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .layoutPriority(1)

            IPOverviewInlineCopyButton(help: help, action: onCopy)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct IPOverviewInlineCopyButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
