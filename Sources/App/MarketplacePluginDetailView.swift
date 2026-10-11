import SwiftUI
import MacToolsPluginKit

/// Catalog-only Marketplace detail presentation. Runtime enrichment deliberately
/// remains outside this foundation so an uninstalled plugin is never treated as
/// an executable action provider.
struct MarketplacePluginDetailPresentation: Equatable {
    let item: PluginManagementItem
    let highlightedAction: MarketplacePluginActionHighlight?

    init?(item: PluginManagementItem?, target: MarketplacePluginDetailTarget) {
        guard let item, item.id == target.pluginID else { return nil }
        guard let highlight = target.actionHighlight else {
            self.item = item
            highlightedAction = nil
            return
        }
        guard item.productMetadata?.actions?.providers.contains(where: { provider in
            provider.id == highlight.providerID
                && provider.staticActions.contains(where: { $0.id == highlight.actionID })
        }) == true else {
            return nil
        }
        self.item = item
        highlightedAction = highlight
    }

    var metadata: PluginProductMetadata? { item.productMetadata }

    var actionProviders: [PluginProductMetadata.Actions.Provider] {
        metadata?.actions?.providers ?? []
    }

    var relatedPluginIDs: [String] {
        Array(Set(
            (metadata?.discovery?.relatedPluginIDs ?? [])
                + (metadata?.relationships?.relatedPluginIDs ?? [])
        )).sorted()
    }
}

struct MarketplacePluginDetailView: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    let target: MarketplacePluginDetailTarget

    @State private var activeOperation = false
    @State private var errorMessage: String?
    @State private var showUninstallConfirmation = false
    @AccessibilityFocusState private var highlightedActionID: String?

    private var presentation: MarketplacePluginDetailPresentation? {
        MarketplacePluginDetailPresentation(
            item: pluginHost.pluginManagementItems.first { $0.id == target.pluginID },
            target: target
        )
    }

    var body: some View {
        Group {
            if let presentation {
                detail(presentation)
            } else {
                ContentUnavailableView(
                    AppL10n.plugins("plugin.marketplace.detail.unavailable.title", defaultValue: "插件不可用"),
                    systemImage: "shippingbox",
                    description: Text(AppL10n.plugins(
                        "plugin.marketplace.detail.unavailable.description",
                        defaultValue: "这个插件已不在当前目录中。"
                    ))
                )
                .accessibilityIdentifier("mactools.marketplace.detail.unavailable")
            }
        }
        .alert(
            AppL10n.plugins("plugin.marketplace.operationFailed.title", defaultValue: "插件操作失败"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(AppL10n.settings("common.ok", defaultValue: "好"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            AppL10n.plugins("plugin.marketplace.uninstall", defaultValue: "卸载"),
            isPresented: $showUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppL10n.plugins("plugin.marketplace.uninstall", defaultValue: "卸载"), role: .destructive) {
                uninstall()
            }
        } message: {
            Text(AppL10n.plugins(
                "plugin.marketplace.detail.uninstall.confirmation",
                defaultValue: "插件及其已安装版本将从 MacTools 中移除。"
            ))
        }
        .onChange(of: pluginHost.pluginManagementItems) {
            navigationCoordinator.reconcileCurrentDestinationAvailability()
        }
    }

    private func detail(_ presentation: MarketplacePluginDetailPresentation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    header(presentation)
                    overview(presentation)
                    actions(presentation)
                    requirements(presentation)
                    privacy(presentation)
                    setup(presentation)
                    relationships(presentation)
                    provenance(presentation)
                }
                .padding(.horizontal, PluginSettingsTheme.Spacing.section)
                .padding(.vertical, PluginSettingsTheme.Spacing.section)
            }
            .onAppear { revealHighlightedAction(in: proxy, presentation: presentation) }
            .onChange(of: target) { _, _ in
                revealHighlightedAction(in: proxy, presentation: presentation)
            }
        }
        .accessibilityIdentifier("mactools.marketplace.detail.\(presentation.item.id)")
    }

    private func header(_ presentation: MarketplacePluginDetailPresentation) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: headerSymbol(for: presentation.item.state))
                .font(.title2.weight(.semibold))
                .foregroundStyle(headerColor(for: presentation.item.state))
                .frame(width: 44, height: 44)
                .background(headerColor(for: presentation.item.state).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.item.title)
                    .font(PluginSettingsTheme.Typography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                if let summary = presentation.item.summary, !summary.isEmpty {
                    Text(summary)
                        .font(PluginSettingsTheme.Typography.pageDescription)
                        .foregroundStyle(.secondary)
                }
                Text([presentation.item.version, presentation.item.releaseChannel, categoryDisplayName(presentation.item.category)]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            lifecycleControls(for: presentation.item)
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .pluginSettingsCardBackground(.standard)
    }

    private func categoryDisplayName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        return PluginCategory(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())?
            .displayName ?? rawValue
    }

    @ViewBuilder
    private func lifecycleControls(for item: PluginManagementItem) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            if item.canInstall {
                Button(AppL10n.plugins("plugin.marketplace.install", defaultValue: "安装")) { install(item) }
                    .buttonStyle(.borderedProminent)
                    .disabled(activeOperation)
            } else if item.canUpdate {
                Button(AppL10n.plugins("plugin.marketplace.update", defaultValue: "更新")) { update(item) }
                    .buttonStyle(.borderedProminent)
                    .disabled(activeOperation)
            } else if case let .incompatible(reason) = item.state {
                Text(reason)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .trailing)
                    .accessibilityIdentifier("mactools.marketplace.requirement-failure")
                if item.packageURL == nil {
                    Button(AppL10n.plugins("plugin.marketplace.install", defaultValue: "安装")) {}
                        .buttonStyle(.borderedProminent).disabled(true)
                }
                Button(AppL10n.plugins("plugin.requirement.recheck", defaultValue: "重新检查")) {
                    pluginHost.recheckPluginRequirements()
                }
                .buttonStyle(.bordered).disabled(activeOperation)
            } else if pluginHost.hasPluginSettings(pluginID: item.id) {
                Button(AppL10n.plugins("plugin.marketplace.openSettings", defaultValue: "打开设置")) {
                    pluginHost.presentPluginSettings(pluginID: item.id)
                }
                .buttonStyle(.borderedProminent)
            }
            if item.canUninstall {
                Button(AppL10n.plugins("plugin.marketplace.uninstall", defaultValue: "卸载"), role: .destructive) {
                    showUninstallConfirmation = true
                }
                .buttonStyle(.bordered)
                .disabled(activeOperation)
            }
            if item.requiresRestartToFullyUnload {
                Text(AppL10n.plugins("plugin.status.restartRequired", defaultValue: "需重启"))
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func overview(_ presentation: MarketplacePluginDetailPresentation) -> some View {
        let metadata = presentation.metadata
        detailSection("plugin.marketplace.detail.about", defaultValue: "功能介绍", systemImage: "text.alignleft") {
            if let description = metadata?.presentation?.longDescription.localizedValue(), !description.isEmpty {
                Text(description)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(presentation.item.summary ?? AppL10n.plugins(
                    "plugin.marketplace.detail.sparse",
                    defaultValue: "此插件的详细目录信息暂不可用。"
                ))
                .foregroundStyle(.secondary)
            }
            ForEach(metadata?.presentation?.examples ?? [], id: \.id) { example in
                Label(example.text.localizedValue() ?? example.id, systemImage: "checkmark.circle")
                    .font(PluginSettingsTheme.Typography.rowDescription)
            }
            ForEach(metadata?.presentation?.screenshots ?? [], id: \.id) { asset in
                Label(asset.alt.localizedValue() ?? asset.id, systemImage: "photo")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(asset.alt.localizedValue() ?? asset.id)
            }
        }
    }

    @ViewBuilder
    private func actions(_ presentation: MarketplacePluginDetailPresentation) -> some View {
        if !presentation.actionProviders.isEmpty {
            detailSection("plugin.marketplace.detail.actions", defaultValue: "可用操作", systemImage: "command") {
                ForEach(presentation.actionProviders, id: \.id) { provider in
                    ForEach(provider.staticActions, id: \.id) { action in
                        actionRow(action, providerID: provider.id, highlighted: presentation.highlightedAction == .init(providerID: provider.id, actionID: action.id))
                    }
                    ForEach(provider.dynamicTemplates, id: \.id) { template in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(template.title.localizedValue() ?? template.id, systemImage: "sparkles")
                                .font(PluginSettingsTheme.Typography.rowTitle)
                            Text(template.description.localizedValue() ?? template.entrySource)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func actionRow(
        _ action: PluginProductMetadata.Actions.StaticAction,
        providerID: String,
        highlighted: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(action.title.localizedValue() ?? action.id, systemImage: action.systemImage)
                .font(PluginSettingsTheme.Typography.rowTitle)
            Text(action.description.localizedValue() ?? "")
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            Text(([MarketplacePluginDetailCopy.value(action.risk, group: "risk")]
                + action.surfaces.map { MarketplacePluginDetailCopy.value($0, group: "surface") }
                + action.permissionIDs.map { MarketplacePluginDetailCopy.value($0, group: "permission") }).joined(separator: " · "))
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(highlighted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .id(actionScrollID(providerID: providerID, actionID: action.id))
        .accessibilityFocused(
            $highlightedActionID,
            equals: actionScrollID(providerID: providerID, actionID: action.id)
        )
        .accessibilityIdentifier("mactools.marketplace.action.\(providerID).\(action.id)")
    }

    @ViewBuilder
    private func requirements(_ presentation: MarketplacePluginDetailPresentation) -> some View {
        if let requirements = presentation.metadata?.requirements {
            detailSection("plugin.marketplace.detail.requirements", defaultValue: "要求", systemImage: "checklist") {
                metadataLines([
                    requirements.minimumMacOSVersion.map { "macOS \($0)" },
                    requirements.architectures.isEmpty ? nil : FeatureL10n.joined(requirements.architectures),
                    requirements.hardware.isEmpty ? nil : MarketplacePluginDetailCopy.list(requirements.hardware, labels: true),
                    requirements.applications.isEmpty ? nil : FeatureL10n.joined(requirements.applications.map(\.name)),
                    requirements.executables.isEmpty ? nil : FeatureL10n.joined(requirements.executables),
                    requirements.permissionIDs.isEmpty ? nil : MarketplacePluginDetailCopy.list(requirements.permissionIDs, group: "permission"),
                    requirements.requiresRelaunch ? AppL10n.plugins("plugin.status.restartRequired", defaultValue: "需重启") : nil
                ])
            }
        }
    }

    @ViewBuilder
    private func privacy(_ presentation: MarketplacePluginDetailPresentation) -> some View {
        if let privacy = presentation.metadata?.privacy {
            detailSection("plugin.marketplace.detail.privacy", defaultValue: "隐私与安全", systemImage: "hand.raised") {
                metadataLines([
                    AppL10n.pluginsFormat(
                        "plugin.marketplace.data.observedFormat", defaultValue: "访问的数据：%@",
                        privacy.dataObserved.isEmpty
                            ? AppL10n.plugins("plugin.marketplace.data.none", defaultValue: "无")
                            : MarketplacePluginDetailCopy.list(privacy.dataObserved, labels: true)
                    ),
                    AppL10n.pluginsFormat(
                        "plugin.marketplace.data.persistedFormat", defaultValue: "保存的数据：%@",
                        privacy.dataPersisted.isEmpty
                            ? AppL10n.plugins("plugin.marketplace.data.none", defaultValue: "无")
                            : MarketplacePluginDetailCopy.list(privacy.dataPersisted, labels: true)
                    ),
                    MarketplacePluginDetailCopy.value(privacy.networkUse, group: "network"),
                    privacy.networkDomains.isEmpty ? nil : AppL10n.pluginsFormat(
                        "plugin.marketplace.network.domainsFormat", defaultValue: "网络域名：%@",
                        FeatureL10n.joined(privacy.networkDomains)
                    ),
                    MarketplacePluginDetailCopy.value(privacy.telemetry, group: "data.telemetry"),
                    privacy.retention.description?.localizedValue()
                        ?? MarketplacePluginDetailCopy.value(privacy.retention.policy, group: "retention")
                ])
            }
        }
    }

    @ViewBuilder
    private func setup(_ presentation: MarketplacePluginDetailPresentation) -> some View {
        if let setup = presentation.metadata?.setup, !setup.steps.isEmpty {
            detailSection("plugin.marketplace.detail.setup", defaultValue: "设置", systemImage: "slider.horizontal.3") {
                ForEach(setup.steps, id: \.id) { step in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title.localizedValue() ?? step.id).font(PluginSettingsTheme.Typography.rowTitle)
                        Text(step.description.localizedValue() ?? "").font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func relationships(_ presentation: MarketplacePluginDetailPresentation) -> some View {
        if !presentation.relatedPluginIDs.isEmpty {
            detailSection("plugin.marketplace.detail.related", defaultValue: "相关插件", systemImage: "square.stack.3d.up") {
                ForEach(presentation.relatedPluginIDs, id: \.self) { pluginID in
                    if let related = pluginHost.pluginManagementItems.first(where: { $0.id == pluginID }) {
                        Button(related.title) { navigationCoordinator.navigate(to: .marketplaceDetail(.init(pluginID: pluginID))) }
                            .buttonStyle(.link)
                    } else {
                        Text(pluginID).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func provenance(_ presentation: MarketplacePluginDetailPresentation) -> some View {
        let metadata = presentation.metadata?.presentation
        if metadata != nil || presentation.item.releaseNotesURL != nil {
            detailSection("plugin.marketplace.detail.provenance", defaultValue: "发布信息", systemImage: "checkmark.seal") {
                if let metadata {
                    Text([metadata.publisher, metadata.license].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                    if let documentationURL = metadata.documentationURL { Link(AppL10n.plugins("plugin.marketplace.detail.documentation", defaultValue: "文档"), destination: documentationURL) }
                    if let supportURL = metadata.supportURL { Link(AppL10n.plugins("plugin.marketplace.detail.support", defaultValue: "支持"), destination: supportURL) }
                }
                if let releaseNotesURL = presentation.item.releaseNotesURL { Link(AppL10n.plugins("plugin.marketplace.detail.releaseNotes", defaultValue: "发行说明"), destination: releaseNotesURL) }
            }
        }
    }

    private func detailSection<Content: View>(
        _ key: String,
        defaultValue: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(AppL10n.plugins(key, defaultValue: defaultValue), systemImage: systemImage)
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.standard)
    }

    @ViewBuilder
    private func metadataLines(_ values: [String?]) -> some View {
        ForEach(values.compactMap { $0 }.filter { !$0.isEmpty }, id: \.self) { value in
            Label(value, systemImage: "checkmark")
                .font(PluginSettingsTheme.Typography.rowDescription)
        }
    }

    private func install(_ item: PluginManagementItem) {
        runOperation { try await pluginHost.installPluginFromCatalog(pluginID: item.id) }
    }

    private func update(_ item: PluginManagementItem) {
        runOperation { try await pluginHost.updatePluginFromCatalog(pluginID: item.id) }
    }

    private func uninstall() {
        guard !activeOperation else { return }
        do {
            try pluginHost.uninstallDynamicPlugin(pluginID: target.pluginID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runOperation(_ operation: @escaping () async throws -> Void) {
        guard !activeOperation else { return }
        activeOperation = true
        Task {
            do { try await operation() } catch { errorMessage = error.localizedDescription }
            activeOperation = false
        }
    }

    private func actionScrollID(providerID: String, actionID: String) -> String {
        "marketplace-detail-action.\(providerID).\(actionID)"
    }

    private func revealHighlightedAction(
        in proxy: ScrollViewProxy,
        presentation: MarketplacePluginDetailPresentation
    ) {
        guard let highlight = presentation.highlightedAction else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(actionScrollID(providerID: highlight.providerID, actionID: highlight.actionID), anchor: .center)
            }
            highlightedActionID = actionScrollID(
                providerID: highlight.providerID,
                actionID: highlight.actionID
            )
        }
    }

    private func headerColor(for state: PluginManagementItem.State) -> Color {
        switch state {
        case .available, .localDevelopment: .blue
        case .installed: .green
        case .updateAvailable, .restartRequired: .accentColor
        case .failed, .incompatible, .revoked: .orange
        }
    }

    private func headerSymbol(for state: PluginManagementItem.State) -> String {
        switch state {
        case .available: "arrow.down.circle.fill"
        case .localDevelopment: "hammer.circle.fill"
        case .installed: "checkmark.seal.fill"
        case .updateAvailable: "arrow.triangle.2.circlepath.circle.fill"
        case .restartRequired: "restart.circle.fill"
        case .failed, .incompatible, .revoked: "exclamationmark.triangle.fill"
        }
    }
}
