import AppKit
import MacToolsPluginKit
import SwiftUI

enum ConfiguredMenuBarPanelLayout {
    static let itemSpacing = ComponentPanelLayout.verticalSpacing

    struct Placement: Equatable {
        var components: [ComponentGridPlacement] = []
        var featureOffsets: [String: CGFloat] = [:]
        var featureHeights: [String: CGFloat] = [:]
        var featureFrames: [String: CGRect] = [:]
        var flowFeatureIDs: Set<String> = []
        var height: CGFloat = 0

        var itemFrames: [CGRect] {
            Array(featureFrames.values) + components.map(PanelLayoutDestination.frame)
        }
    }

    static func componentHeight(_ items: [PluginPanelWidgetSnapshot]) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        return ComponentPanelLayout.gridContentHeight(for: ComponentGridPlacementEngine.placements(for: items))
    }

    static func placement(
        entries: [MenuBarPanelEntry], components: [PluginPanelWidgetSnapshot], features: [PluginPanelRowSnapshot],
        width: CGFloat = MenuBarPanelLayout.surfaceWidth
    ) -> Placement {
        placement(order: entries.map { ($0.id, $0.kind) }, components: components, features: features, width: width)
    }

    static func placement(features: [PluginPanelRowSnapshot], width: CGFloat = MenuBarPanelLayout.surfaceWidth) -> Placement {
        placement(order: features.map { ($0.id, .row) }, components: [], features: features, width: width)
    }

    private static func placement(
        order: [(String, PluginPanelItemKind)], components: [PluginPanelWidgetSnapshot],
        features: [PluginPanelRowSnapshot], width: CGFloat
    ) -> Placement {
        let componentLookup = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0) })
        let featureLookup = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0) })
        if usesColumnFlow(components: components, features: features, width: width) {
            return PanelAdaptiveFlow.rows(order: order, components: componentLookup, features: featureLookup, width: width)
        }
        let items: [(id: String, span: PluginPanelWidgetSpan)] = order.compactMap { id, kind in
            switch kind {
            case .widget:
                return componentLookup[id].map { (id, $0.span) }
            case .row:
                return featureLookup[id].map { _ in (id, PanelCompactSwitchLayout.span) }
            }
        }
        let placements = PanelAdaptiveFlow.placements(for: items, features: featureLookup, width: width)
        var result = Placement()
        for item in placements {
            let frame = PanelLayoutDestination.frame(item)
            if featureLookup[item.id] != nil {
                result.flowFeatureIDs.insert(item.id)
                result.featureOffsets[item.id] = frame.minY
                result.featureHeights[item.id] = frame.height
                result.featureFrames[item.id] = frame
            } else {
                result.components.append(item)
            }
        }
        result.height = placements.isEmpty ? 0 : ComponentPanelLayout.gridContentHeight(for: placements)
        return result
    }

    static func usesColumnFlow(components: [PluginPanelWidgetSnapshot], features: [PluginPanelRowSnapshot], width: CGFloat) -> Bool {
        features.contains(where: { !$0.usesCompactPresentation })
            || (!components.isEmpty && MenuBarPanelWidth.columns(forSurfaceWidth: width) > 1)
    }

    static func contentHeight(
        components: [PluginPanelWidgetSnapshot], features: [PluginPanelRowSnapshot], screen: NSScreen?,
        entries: [MenuBarPanelEntry]? = nil, width: CGFloat = MenuBarPanelLayout.surfaceWidth
    ) -> CGFloat {
        if entries == nil && width == MenuBarPanelLayout.surfaceWidth && !features.contains(where: \.usesCompactPresentation) {
            if components.isEmpty { return MenuBarPanelLayout.preferredFeatureContentHeight(for: features, screen: screen) }
            if features.isEmpty { return ComponentPanelLayout.preferredContentHeight(for: components, screen: screen) }
        }
        let order = entries.map { $0.map { ($0.id, $0.kind) } }
            ?? components.map { ($0.id, PluginPanelItemKind.widget) } + features.map { ($0.id, PluginPanelItemKind.row) }
        let height = placement(order: order, components: components, features: features, width: width).height
        if components.isEmpty {
            return MenuBarPanelLayout.preferredFeatureContentHeight(featureContentHeight: height,
                maximumFeatureListHeight: MenuBarPanelLayout.maximumFeatureListHeight(for: screen))
        }
        let raw = height + MenuBarPanelLayout.contentVerticalPadding
        let minimum = features.isEmpty ? raw : MenuBarPanelLayout.minimumContentHeight
        return min(max(raw, minimum), MenuBarPanelLayout.maximumContentHeight(for: screen))
    }
}

struct ConfiguredMenuBarPanelsContent: View {
    let pluginHost: PluginHost
    @EnvironmentObject private var presentation: MenuBarPanelPresentationModel
    @ObservedObject var model: MenuBarUnifiedPanelModel
    let contentBodyHeight: CGFloat
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    let onPresentDiskCleanConfiguration: () -> Void
    let onPresentLaunchControlConfiguration: () -> Void
    @State private var visited: Set<String> = []

    var body: some View {
        let _ = presentation.revision
        ZStack(alignment: .topLeading) {
            ForEach(pluginHost.menuBarPanels.filter { visited.contains($0.id) || $0.id == model.selectedTab.id }) {
                panel in
                ConfiguredMenuBarPanelContent(
                    pluginHost: pluginHost, panelID: panel.id,
                    availableBodyHeight: contentBodyHeight,
                    maximumFeatureListHeight: model.maximumFeatureListHeight,
                    isVisible: model.isPanelVisible && panel.id == model.selectedTab.id,
                    onDismiss: onDismiss, onOpenSettings: onOpenSettings,
                    onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
                    onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration
                )
                .opacity(panel.id == model.selectedTab.id ? 1 : 0)
                .allowsHitTesting(model.isPanelVisible && panel.id == model.selectedTab.id)
                .accessibilityHidden(panel.id != model.selectedTab.id)
            }
        }
        .onAppear { visited.insert(model.selectedTab.id) }
        .onChange(of: model.selectedTab) { old, new in
            visited.insert(old.id)
            visited.insert(new.id)
        }
        .onChange(of: pluginHost.menuBarPanels.map(\.id)) { _, ids in visited.formIntersection(ids) }
    }
}

private struct ConfiguredMenuBarPanelContent: View {
    @Environment(\.menuBarPanelSurfaceWidth) private var surfaceWidth
    let pluginHost: PluginHost
    @EnvironmentObject private var presentation: MenuBarPanelPresentationModel
    let panelID: String
    let availableBodyHeight: CGFloat
    let maximumFeatureListHeight: CGFloat
    let isVisible: Bool
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    let onPresentDiskCleanConfiguration: () -> Void
    let onPresentLaunchControlConfiguration: () -> Void

    @State private var scrollCoordinateSpace = UUID()
    @State private var retainedBodyHeight: CGFloat?
    @State private var isComponentDetailInline = false
    @State private var isFeatureDetailInline = false
    private var contentBodyHeight: CGFloat {
        isVisible ? availableBodyHeight : (retainedBodyHeight ?? availableBodyHeight)
    }

    var body: some View {
        let _ = presentation.revision
        let components = pluginHost.componentItems(in: panelID)
        let features = pluginHost.panelItems(in: panelID)
        Group {
            if !features.isEmpty {
                let placement = ConfiguredMenuBarPanelLayout.placement(
                    entries: pluginHost.panelEntries(in: panelID), components: components, features: features, width: surfaceWidth
                )
                ScrollView(.vertical, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        if !components.isEmpty {
                            componentContent(components, height: placement.height, embedded: true,
                                             placements: placement.components)
                                .opacity(isFeatureDetailInline ? 0 : 1)
                                .allowsHitTesting(!isFeatureDetailInline)
                        }
                        featureContent(features, height: placement.height, embedded: true,
                                       rowFrames: placement.featureFrames)
                            .opacity(isComponentDetailInline ? 0 : 1)
                            .allowsHitTesting(!isComponentDetailInline)
                    }
                    .frame(width: surfaceWidth, height: placement.height, alignment: .topLeading)
                    .background {
                        if !isComponentDetailInline && !isFeatureDetailInline {
                            PanelColumnGuides(frames: placement.itemFrames, width: surfaceWidth, height: placement.height)
                        }
                    }
                }
                .background(ScrollViewScrollerVisibilityConfigurator())
                .coordinateSpace(name: scrollCoordinateSpace)
                .environment(\.panelInlineDetailViewport, PanelInlineDetailViewport(
                    coordinateSpace: scrollCoordinateSpace, height: contentBodyHeight
                ))
            } else if !components.isEmpty {
                let placement = ConfiguredMenuBarPanelLayout.placement(
                    entries: pluginHost.panelEntries(in: panelID), components: components, features: [], width: surfaceWidth
                )
                componentContent(components, height: contentBodyHeight, placements: placement.components,
                                 gridHeight: placement.height)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(FeatureL10n.string("此面板暂无内容"))
                        .font(.subheadline)
                    Text(FeatureL10n.string("在编辑面板中添加内容"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(FeatureL10n.string("工具组合…")) { pluginHost.presentStarterPacks() }
                        .buttonStyle(.link)
                        .font(PluginTypography.control.font)
                        .accessibilityIdentifier("panel.empty.starter-packs")
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: surfaceWidth, height: contentBodyHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: ComponentPanelLayout.scrollClipCornerRadius, style: .continuous))
        .onAppear { if isVisible { retainedBodyHeight = availableBodyHeight } }
        .onChange(of: isVisible) { _, visible in if visible { retainedBodyHeight = availableBodyHeight } }
        .onChange(of: availableBodyHeight) { _, height in if isVisible { retainedBodyHeight = height } }
    }

    private func componentContent(
        _ items: [PluginPanelWidgetSnapshot], height: CGFloat, embedded: Bool = false,
        placements: [ComponentGridPlacement]? = nil, gridHeight: CGFloat? = nil
    ) -> some View {
        ComponentPanelContent(
            pluginHost: pluginHost, contentBodyHeight: height, isPanelVisible: isVisible && !isFeatureDetailInline,
            onDismiss: onDismiss, panelID: panelID, suppliedItems: items,
            embedded: embedded,
            suppliedPlacements: placements, suppliedGridHeight: gridHeight ?? (placements == nil ? nil : height),
            onInlinePresentationChange: { isComponentDetailInline = $0 }
        )
    }

    private func featureContent(
        _ items: [PluginPanelRowSnapshot], height: CGFloat, embedded: Bool = false,
        rowFrames: [String: CGRect]? = nil
    ) -> some View {
        MenuBarContent(
            pluginHost: pluginHost, contentBodyHeight: height,
            maximumFeatureListHeight: embedded ? height : maximumFeatureListHeight,
            isPanelVisible: isVisible, onDismiss: onDismiss, onOpenSettings: onOpenSettings,
            onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
            onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration,
            suppliedItems: items,
            embedded: embedded, suppliedRowOffsets: rowFrames?.mapValues(\.minY), suppliedRowFrames: rowFrames,
            onInlinePresentationChange: { isFeatureDetailInline = $0 }
        )
    }
}
