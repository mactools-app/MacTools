import AppKit
import MacToolsPluginKit
import SwiftUI

@MainActor
struct PanelComponentLibraryItem: Identifiable {
    let id: String
    let title: String
    let description: String
    let iconName: String
    let iconTint: Color
    let items: [PanelCatalogItem]

    var previewItems: [PanelCatalogItem] {
        items.filter { $0.kind == .widget } + items.filter { $0.kind == .row }
    }

    static func catalog(in host: PluginHost, matching query: String = "") -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = host.availablePanelItems
        let groups = Dictionary(grouping: catalog, by: \.key.pluginID)
        var seen: Set<String> = []
        return catalog.compactMap { first in
            let pluginID = first.key.pluginID
            guard seen.insert(pluginID).inserted, let items = groups[pluginID] else { return nil }
            let metadataMatches = [first.pluginTitle, first.metadata.defaultDescription].contains {
                $0.localizedStandardContains(query)
            }
            let matching = query.isEmpty || metadataMatches ? items : items.filter {
                [$0.title, $0.description].contains { $0.localizedStandardContains(query) }
            }
            guard !matching.isEmpty else { return nil }
            return Self(id: pluginID, title: first.pluginTitle, description: first.metadata.defaultDescription,
                        iconName: first.metadata.iconName, iconTint: first.metadata.iconTint, items: matching)
        }
    }
}

@MainActor
private struct PanelComponentLibraryPreviewItem: Identifiable {
    let item: PanelCatalogItem
    let component: PluginPanelWidgetSnapshot?
    let feature: PluginPanelRowSnapshot?

    init(item: PanelCatalogItem, host: PluginHost) {
        self.item = item
        component = host.panelCoordinator.widgetSnapshot(item)
        feature = host.panelCoordinator.rowSnapshot(item)
    }

    nonisolated var id: String { item.id }
    var key: PluginPanelItemKey { item.key }
    var title: String { item.title }

    var sourceSize: CGSize {
        if let component {
            return CGSize(width: ComponentPanelLayout.itemWidth(for: component.span),
                          height: ComponentPanelLayout.itemHeight(for: component.span))
        }
        return CGSize(width: ComponentPanelLayout.gridWidth,
                      height: feature.map { MenuBarPanelLayout.rowHeight(for: $0) } ?? 0)
    }
}

/// Only the selected plugin mounts previews; browsing never enables a panel or invokes a control.
struct PanelComponentLibrary: View {
    @ObservedObject var pluginHost: PluginHost
    let panelID: String
    let onAdd: (PluginPanelItemKey) -> Bool
    @State private var query = ""
    @State private var selection: String?
    @State private var errorMessage: String?
    @State private var presentationFocus = MenuBarPanelPopoverFocus()
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let items = PanelComponentLibraryItem.catalog(in: pluginHost, matching: query)
        let selected = items.first { $0.id == selection } ?? items.first
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(FeatureL10n.string("搜索组件"), text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityIdentifier("panel.library.search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(FeatureL10n.string("清除搜索"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .modifier(PanelComponentLibrarySearchFieldStyle())
                .padding([.top, .horizontal], 12)

                List(selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
                    ForEach(items) { item in
                        HStack(spacing: 9) {
                            Image(systemName: PluginSystemImage.resolvedName(item.iconName))
                                .font(.system(size: 17)).foregroundStyle(item.iconTint)
                                .frame(width: 23, height: 28)
                            Text(item.title).lineLimit(1)
                        }
                        .tag(item.id)
                        .help(item.title)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("panel.library.list")
            }
            .frame(width: 184)
            .background(.bar)

            Divider()

            Group {
                if let selected {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(selected.title).font(.title2.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 12)
                                if let panel = pluginHost.menuBarPanels.first(where: { $0.id == panelID }) {
                                    Label(panel.title, systemImage: PluginSystemImage.resolvedName(panel.systemImage))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Text(FeatureL10n.string("点击预览，添加到当前面板"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.trailing, 36)
                        .padding(20)

                        PanelComponentLibraryPreviews(pluginHost: pluginHost, items: selected.previewItems) { key in
                            guard onAdd(key) else {
                                errorMessage = FeatureL10n.string("组件暂不可用，请稍后重试。")
                                return
                            }
                            errorMessage = nil
                            close()
                        }
                        if let errorMessage {
                            Text(errorMessage).font(.caption).foregroundStyle(.red)
                                .padding([.horizontal, .bottom], 20)
                        }
                    }
                    .id(selected.id)
                } else if query.isEmpty {
                    ContentUnavailableView(FeatureL10n.string("暂无可添加的组件"), systemImage: "square.grid.2x2",
                        description: Text(FeatureL10n.string("支持面板的已安装插件会显示在这里。")))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 660, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(MenuBarPanelPopoverFocusLifecycle(focus: presentationFocus).allowsHitTesting(false))
        .overlay(alignment: .topTrailing) {
            closeButton.padding(16)
        }
        .accessibilityIdentifier("panel.library")
        .onAppear { selection = selected?.id; searchFocused = true }
        .onExitCommand(perform: close)
        .onChange(of: items.map(\.id)) { _, ids in
            if !ids.contains(selection ?? "") { selection = ids.first }
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(PanelComponentLibraryCloseButtonStyle())
        .help(AppL10n.settings("panelTheme.close", defaultValue: "关闭"))
        .accessibilityLabel(AppL10n.settings("panelTheme.close", defaultValue: "关闭"))
        .accessibilityIdentifier("panel.library.close")
    }

    private func close() {
        searchFocused = false
        presentationFocus.end()
        dismiss()
    }
}

private struct PanelComponentLibraryPreviews: View {
    @ObservedObject var pluginHost: PluginHost
    let items: [PanelCatalogItem]
    let onAdd: (PluginPanelItemKey) -> Void
    @State private var measuredPreviewSizes: [String: CGSize] = [:]
    @State private var cache = PanelComponentLibraryPreviewCache()
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        GeometryReader { geometry in
            let previews = items.map { PanelComponentLibraryPreviewItem(item: $0, host: pluginHost) }
            let layout = PanelComponentLibraryLayout(sourceSizes: previews.map(previewSourceSize),
                availableWidth: geometry.size.width - PanelComponentLibraryLayout.horizontalPadding * 2)
            let frames = zip(previews, layout.frames).map { PanelItemFrame(id: $0.id, frame: $1) }
            let byID = Dictionary(uniqueKeysWithValues: previews.map { ($0.id, $0) })
            ScrollView {
                PanelViewportStack(frames: frames, width: layout.width, height: layout.height) { id in
                    if let item = byID[id] {
                        preview(item, scale: layout.scale)
                            .environment(\.layoutDirection, layoutDirection)
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
                .padding(.horizontal, PanelComponentLibraryLayout.horizontalPadding)
                .padding(.top, 8).padding(.bottom, 20)
            }
        }
    }

    private func preview(_ item: PanelComponentLibraryPreviewItem, scale: CGFloat) -> some View {
        let sourceSize = previewSourceSize(item)
        return Button {
            onAdd(item.key)
        } label: {
            PanelComponentLibraryPreview(id: item.id, size: sourceSize, cache: cache,
                                         onSizeChange: { measuredPreviewSizes[item.id] = $0 }) { reportHeight in
                if let component = item.component {
                    return pluginHost.componentPreviewView(for: component.id, reportContentHeight: reportHeight)
                } else if let feature = item.feature {
                    return AnyView(PanelComponentLibraryFeaturePreview(pluginHost: pluginHost, item: feature))
                }
                return nil
            }
            .frame(width: sourceSize.width * scale, height: sourceSize.height * scale)
            .padding(PanelComponentLibraryLayout.previewPadding)
            .allowsHitTesting(false).accessibilityHidden(true)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelComponentLibraryPreviewButtonStyle(
            cornerRadius: MenuBarPanelLayout.cornerRadius * scale + PanelComponentLibraryLayout.previewPadding))
        .help(item.title)
        .accessibilityLabel(item.title + ", " + FeatureL10n.string("添加组件"))
        .accessibilityIdentifier("panel.library.add.\(item.id)")
    }

    private func previewSourceSize(_ item: PanelComponentLibraryPreviewItem) -> CGSize {
        guard let measured = measuredPreviewSizes[item.id], measured.width == item.sourceSize.width else {
            return item.sourceSize
        }
        return measured
    }
}

private struct PanelComponentLibrarySearchFieldStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            } else if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: Capsule())
            } else {
                content.background(.regularMaterial, in: Capsule())
            }
        }
        .overlay {
            if contrast == .increased {
                Capsule().strokeBorder(.primary.opacity(0.5), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct PanelComponentLibraryCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CloseLabel(configuration: configuration)
    }

    private struct CloseLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(Color.secondary)
                .opacity(configuration.isPressed ? 0.8 : (isHovered ? 1 : 0.65))
                .contentShape(Circle())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
                .onHover { isHovered = $0 }
        }
    }
}

private struct PanelComponentLibraryPreviewButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        PreviewLabel(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct PreviewLabel: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @State private var isHovered = false
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .clipShape(shape)
                .overlay {
                    shape.fill(Color.accentColor.opacity(configuration.isPressed ? 0.08 : (isHovered ? 0.035 : 0)))
                        .allowsHitTesting(false)
                }
                .overlay {
                    shape.strokeBorder(borderColor, lineWidth: contrast == .increased ? 1.5 : 1)
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }

        private var borderColor: Color {
            if isHovered || configuration.isPressed {
                return .accentColor.opacity(contrast == .increased ? 0.8 : 0.3)
            }
            return contrast == .increased ? .primary.opacity(0.35) : Color(nsColor: .separatorColor).opacity(0.45)
        }
    }
}

/// Keep only the selected plugin's rendered snapshots when offscreen views unmount.
@MainActor
private final class PanelComponentLibraryPreviewCache {
    enum Snapshot {
        case image(NSImage)
        case unavailable
    }

    var snapshots: [String: Snapshot] = [:]
    private var localeRevision: Int?

    func prepare(for revision: Int) {
        guard localeRevision != revision else { return }
        snapshots.removeAll()
        localeRevision = revision
    }
}

private struct PanelComponentLibraryPreview: View {
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let id: String
    let size: CGSize
    let cache: PanelComponentLibraryPreviewCache
    let onSizeChange: (CGSize) -> Void
    let makeContent: (@escaping (CGFloat) -> Void) -> AnyView?
    @State private var snapshot: PanelComponentLibraryPreviewCache.Snapshot?
    @State private var snapshotRevision: Int?
    @Environment(\.menuBarPanelTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch snapshot {
            case .image(let image): Image(nsImage: image).resizable().scaledToFit()
            case .unavailable: Image(systemName: "square.dashed").foregroundStyle(.secondary)
            case nil: ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: refreshSnapshot)
        .onChange(of: runtimeLocale.revision) { _, _ in refreshSnapshot() }
    }

    @MainActor
    private func refreshSnapshot() {
        let revision = runtimeLocale.revision
        guard snapshotRevision != revision || snapshot == nil else { return }
        cache.prepare(for: revision)
        if let cached = cache.snapshots[id] {
            snapshot = cached
            snapshotRevision = revision
            return
        }
        defer {
            cache.snapshots[id] = snapshot
            snapshotRevision = revision
        }
        var measuredHeight: CGFloat?
        guard let content = makeContent({ height in
            let metrics = PluginPanelWidgetLayoutMetrics.default
            guard height.isFinite, height > 0,
                  let span = Int(exactly: ceil(height / metrics.cellHeight)) else { return }
            measuredHeight = metrics.itemHeight(forSpanHeight: span)
        }) else { snapshot = .unavailable; return }
        // A static bitmap excludes plugin controls from keyboard focus and ongoing preview updates.
        @MainActor
        func rootView(_ size: CGSize) -> AnyView {
            AnyView(RuntimeLocalizedContent(content: content)
                .environment(\.menuBarPanelTheme, theme)
                .environment(\.pluginComponentTheme, theme.componentTheme)
                .tint(theme.accent)
                .environment(\.colorScheme, colorScheme)
                .frame(width: size.width, height: size.height))
        }
        var renderSize = size
        let hosting = NSHostingView(rootView: rootView(renderSize))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        // Preview sizing never changes a live placement or refreshes the plugin.
        if let measuredHeight, measuredHeight != renderSize.height {
            renderSize.height = measuredHeight
            hosting.rootView = rootView(renderSize)
            window.setContentSize(renderSize)
            hosting.layoutSubtreeIfNeeded()
        }
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let result = NSImage(size: renderSize)
            result.addRepresentation(bitmap)
            snapshot = .image(result)
            if renderSize != size { onSizeChange(renderSize) }
        } else {
            snapshot = .unavailable
        }
    }
}

private struct PanelComponentLibraryFeaturePreview: View {
    let pluginHost: PluginHost
    let item: PluginPanelRowSnapshot

    var body: some View {
        FeatureRowView(item: item,
            indicator: pluginHost.rowIndicator(for: item.id),
            compactIndicator: pluginHost.rowCompactIndicator(for: item.id),
            onDisclosureToggle: { _ in }, onSelectionChange: { _, _ in },
            onNavigationSelectionChange: { _, _ in }, onNavigationHoverChange: { _, _, _ in },
            onNavigationRowFrameChange: { _, _, _ in }, onDateChange: { _, _ in },
            onSwitchChange: { _ in false }, onSliderChange: { _, _, _ in }, onActionInvoke: { _, _ in })
    }
}
