import AppKit
import MacToolsPluginKit

/// Flexible host controls share available width; plugin widgets keep their declared sizes.
/// The resulting rectangles are used by the live view, editor, and drop geometry.
enum PanelAdaptiveFlow {
    struct Item {
        let id: String
        let kind: PluginPanelItemKind
        let size: CGSize
        let ownsBand: Bool
        let isCompact: Bool
        let span: PluginPanelWidgetSpan?
    }

    /// Measure native text once per snapshot. Packing and drag candidates then
    /// use only these immutable dimensions, without invoking plugin views.
    static func measuredItems(order: [(String, PluginPanelItemKind)],
                              components: [String: PluginPanelWidgetSnapshot],
                              features: [String: PluginPanelRowSnapshot], width: CGFloat) -> [Item] {
        let columnWidth = MenuBarPanelWidth.columnWidth(forSurfaceWidth: width)
        return order.compactMap { id, kind in
            switch kind {
            case .row:
                guard let item = features[id] else { return nil }
                let itemWidth = item.usesCompactPresentation ? (columnWidth - PanelCompactSwitchLayout.spacing) / 2
                    : PanelItemWidthLayout.resolved(item.width, available: width)
                let height = item.usesCompactPresentation ? PanelCompactSwitchLayout.height(title: item.title, width: itemWidth)
                    : MenuBarPanelLayout.rowHeight(for: item, width: itemWidth)
                return Item(id: id, kind: kind, size: CGSize(width: itemWidth, height: height),
                    ownsBand: !item.usesCompactPresentation && item.width == .fill,
                    isCompact: item.usesCompactPresentation, span: nil)
            case .widget:
                guard let item = components[id] else { return nil }
                return Item(id: id, kind: kind,
                    size: CGSize(width: ComponentPanelLayout.itemWidth(for: item.span), height: ComponentPanelLayout.itemHeight(for: item.span)),
                    ownsBand: MenuBarPanelWidth.columns(forSurfaceWidth: width) == 1 && item.span.width == item.span.grid.rawValue,
                    isCompact: false, span: item.span)
            }
        }
    }

    /// Full host controls start at column boundaries; compact cards share the
    /// halves inside a column. Fixed widgets keep their declared dimensions.
    struct State {
        let width: CGFloat
        let verticalGap: CGFloat
        private var occupied: [CGRect] = []
        private var floorY: CGFloat = 0
        private(set) var height: CGFloat = 0

        init(width: CGFloat, verticalGap: CGFloat) {
            self.width = width
            self.verticalGap = verticalGap
        }

        func next(_ item: Item) -> CGRect {
            let gap = PanelCompactSwitchLayout.spacing
            let columns = MenuBarPanelWidth.columns(forSurfaceWidth: width)
            let slotWidth = MenuBarPanelWidth.columnSlotWidth(forSurfaceWidth: width)
            let inset = MenuBarPanelWidth.columnInset(forSurfaceWidth: width)
            var anchors: [CGFloat] = []
            for column in 0..<columns {
                let origin = MenuBarPanelWidth.columnOrigin(column, surfaceWidth: width)
                if item.isCompact {
                    anchors.append(origin + inset)
                    anchors.append(origin + inset + item.size.width + gap)
                } else {
                    let slotCount = max(1, Int(ceil((item.size.width + MenuBarPanelWidth.allocationSpacing)
                        / (slotWidth + MenuBarPanelWidth.allocationSpacing))))
                    let capacity = CGFloat(slotCount) * (slotWidth + MenuBarPanelWidth.allocationSpacing) - MenuBarPanelWidth.allocationSpacing
                    let padding = item.kind == .row ? min(inset, max(0, (capacity - item.size.width) / 2)) : 0
                    anchors.append(origin + padding)
                    if let span = item.span, span.width < span.grid.rawValue {
                        // Small fixed widgets can use gaps within this column,
                        // while full controls never inherit those partial edges.
                        anchors += occupied.map { $0.maxX + gap }.filter {
                            $0 >= origin && $0 + item.size.width <= origin + slotWidth + 0.001
                        }
                    }
                }
            }
            if item.ownsBand { anchors = [0] }
            var origin = CGPoint(x: 0, y: CGFloat.infinity)
            let floor = item.ownsBand ? occupied.reduce(floorY) { max($0, $1.maxY + verticalGap) } : floorY
            for x in Set(anchors) where x + item.size.width <= width + 0.001 {
                let y = occupied.reduce(floor) { height, rect in
                    guard !item.ownsBand, rect.maxX + gap > x + 0.001,
                          rect.minX < x + item.size.width + gap - 0.001 else { return height }
                    return max(height, rect.maxY + verticalGap)
                }
                if y < origin.y || (y == origin.y && x < origin.x) { origin = CGPoint(x: x, y: y) }
            }
            if !origin.y.isFinite { origin = CGPoint(x: 0, y: floor) }
            return CGRect(origin: origin, size: item.size)
        }

        @discardableResult
        mutating func append(_ item: Item) -> CGRect {
            let frame = next(item)
            height = max(height, frame.maxY)
            if item.ownsBand {
                floorY = frame.maxY + verticalGap
                occupied.removeAll(keepingCapacity: true)
            } else {
                // Later rectangles covering the same horizontal interval replace
                // old obstacles. The active skyline stays small while dragging.
                occupied.removeAll { frame.minX <= $0.minX && frame.maxX >= $0.maxX && frame.maxY >= $0.maxY }
                occupied.append(frame)
            }
            return frame
        }
    }

    static func rows(order: [(String, PluginPanelItemKind)], components: [String: PluginPanelWidgetSnapshot],
                     features: [String: PluginPanelRowSnapshot], width: CGFloat) -> ConfiguredMenuBarPanelLayout.Placement {
        let items = measuredItems(order: order, components: components, features: features, width: width)
        var state = State(width: width, verticalGap: components.isEmpty && !features.values.contains(where: \.usesCompactPresentation)
            ? MenuBarPanelLayout.featureRowSpacing : PanelCompactSwitchLayout.spacing)
        var result = ConfiguredMenuBarPanelLayout.Placement()
        for item in items {
            let frame = state.append(item)
            if item.kind == .row {
                result.featureOffsets[item.id] = frame.minY
                result.featureHeights[item.id] = frame.height
                result.featureFrames[item.id] = frame
                if !item.ownsBand && frame.width < width - 0.001 { result.flowFeatureIDs.insert(item.id) }
            } else if let span = item.span {
                result.components.append(ComponentGridPlacement(id: item.id, row: 0, column: 0,
                    span: span, yOffset: frame.minY, xOffset: frame.minX))
            }
        }
        result.height = state.height
        return result
    }

    static func placements(
        for items: [(id: String, span: PluginPanelWidgetSpan)],
        features: [String: PluginPanelRowSnapshot], width: CGFloat
    ) -> [ComponentGridPlacement] {
        guard !items.isEmpty else { return [] }
        let flexibleIDs = Set(items.compactMap { features[$0.id]?.usesCompactPresentation == true ? $0.id : nil })
        guard !flexibleIDs.isEmpty else { return ComponentGridPlacementEngine.placements(for: items, width: width) }
        if flexibleIDs.count == items.count {
            return balancedSwitches(items: items, features: features, width: width)
        }

        let packed = ComponentGridPlacementEngine.placements(for: items, width: width)
        var result: [ComponentGridPlacement] = []
        var band: [ComponentGridPlacement] = []
        var y: CGFloat = 0
        var previousWasCompact = false

        func flush() {
            guard let first = band.first else { return }
            let isCompact = band.allSatisfy { $0.span.grid == .compact }
            if !result.isEmpty {
                y += previousWasCompact && isCompact ? ComponentPanelLayout.compactRowSpacing : ComponentPanelLayout.verticalSpacing
            }
            let flexibleCount = band.filter { flexibleIDs.contains($0.id) }.count
            func spacing(after item: ComponentGridPlacement) -> CGFloat {
                item.span.grid == .compact
                    ? PluginPanelWidgetLayoutMetrics.compactSpacing : PanelCompactSwitchLayout.spacing
            }
            let totalSpacing = band.dropLast().reduce(CGFloat(0)) { $0 + spacing(after: $1) }
            let fixedWidth = band.filter { !flexibleIDs.contains($0.id) }.reduce(CGFloat(0)) {
                $0 + ComponentPanelLayout.itemWidth(for: $1.span)
            }
            let flexibleWidth = flexibleCount == 0 ? 0 : min(MenuBarPanelLayout.maximumFeatureContentWidth,
                max(1, (width - fixedWidth - totalSpacing) / CGFloat(flexibleCount)))
            let sizes = band.map { item in
                flexibleIDs.contains(item.id)
                    ? CGSize(width: flexibleWidth, height: PanelCompactSwitchLayout.height(
                        title: features[item.id]?.title ?? "", width: flexibleWidth))
                    : CGSize(width: ComponentPanelLayout.itemWidth(for: item.span),
                             height: ComponentPanelLayout.itemHeight(for: item.span))
            }
            let bandHeight = sizes.map(\.height).max() ?? 0
            var x: CGFloat = 0
            for (item, size) in zip(band, sizes) {
                let flexible = flexibleIDs.contains(item.id)
                result.append(ComponentGridPlacement(id: item.id, row: first.row, column: item.column,
                    span: item.span, yOffset: y, gridColumns: item.gridColumns, gridSpacing: item.gridSpacing,
                    xOffset: flexibleCount == 0 ? ComponentPanelLayout.xOffset(for: item) : x,
                    size: flexible ? CGSize(width: size.width, height: bandHeight) : nil))
                x += size.width + spacing(after: item)
            }
            y += bandHeight
            previousWasCompact = isCompact
            band.removeAll(keepingCapacity: true)
        }

        for item in packed {
            if let first = band.first, item.row != first.row { flush() }
            band.append(item)
        }
        flush()
        return result
    }

    private static func balancedSwitches(
        items: [(id: String, span: PluginPanelWidgetSpan)], features: [String: PluginPanelRowSnapshot], width: CGFloat
    ) -> [ComponentGridPlacement] {
        let gap = PanelCompactSwitchLayout.spacing
        let minimumWidth = ComponentPanelLayout.itemWidth(for: PanelCompactSwitchLayout.span)
        let capacity = max(1, min(items.count, Int(floor((width + gap) / (minimumWidth + gap)))))
        // Use the fewest rows that fit, then balance them so four items do not form 3 + 1.
        // The number of columns is derived from width and item count, with no fixed cap.
        let rows = (items.count + capacity - 1) / capacity
        var result: [ComponentGridPlacement] = []
        var offset = 0
        var y: CGFloat = 0
        for row in 0..<rows {
            let count = items.count / rows + (row < items.count % rows ? 1 : 0)
            let rowItems = items[offset..<(offset + count)]
            let itemWidth = min(MenuBarPanelLayout.maximumFeatureContentWidth,
                                (width - CGFloat(count - 1) * gap) / CGFloat(count))
            let itemHeight = rowItems.reduce(CGFloat(0)) {
                max($0, PanelCompactSwitchLayout.height(title: features[$1.id]?.title ?? "", width: itemWidth))
            }
            for (column, item) in rowItems.enumerated() {
                result.append(ComponentGridPlacement(id: item.id, row: row, column: column,
                    span: item.span, yOffset: y, xOffset: CGFloat(column) * (itemWidth + gap),
                    size: CGSize(width: itemWidth, height: itemHeight)))
            }
            y += itemHeight + gap
            offset += count
        }
        return result
    }
}
