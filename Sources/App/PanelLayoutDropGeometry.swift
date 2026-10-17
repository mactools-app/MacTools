import AppKit
import MacToolsPluginKit

struct PanelLayoutDropTarget: Equatable {
    let offset: Int
    let markerFrame: CGRect?
    var isVacancy = false
    var previewFrame: CGRect? = nil
}

/// Resolve the proposed result without mounting plugin views or changing settings.
/// The editor keeps its committed frames as the hit map throughout the drag.
enum PanelLayoutDropFootprint {
    static func frame(source: MenuBarPanelEntry, offset: Int, entries: [MenuBarPanelEntry],
                      components: [PluginPanelWidgetSnapshot], features: [PluginPanelRowSnapshot],
                      width: CGFloat, rightToLeft: Bool = false) -> CGRect? {
        let boundary = min(max(offset, 0), entries.count)
        let sourceIndex = entries.firstIndex { $0.id == source.id }
        var proposed = entries.filter { $0.id != source.id }
        let insertion = sourceIndex.map { boundary > $0 ? boundary - 1 : boundary } ?? boundary
        proposed.insert(source, at: min(insertion, proposed.count))
        let placement = ConfiguredMenuBarPanelLayout.placement(entries: proposed,
            components: components, features: features, width: width)
        guard var frame = PanelLayoutEntryFrame.frames(entries: proposed, placement: placement)
            .first(where: { $0.id == source.id })?.frame else { return nil }
        if rightToLeft { frame.origin.x = width - frame.maxX }
        return frame
    }
}

/// Prepare every legal landing once. With column flow, only the prefix before
/// the source determines its frame, so one measured packing pass is sufficient.
enum PanelLayoutDropCandidates {
    static func targets(source: MenuBarPanelEntry, entries: [MenuBarPanelEntry],
                        components: [PluginPanelWidgetSnapshot], features: [PluginPanelRowSnapshot],
                        width: CGFloat) -> [PanelLayoutDropTarget] {
        let sourceIndex = entries.firstIndex { $0.id == source.id }
        let remaining = entries.filter { $0.id != source.id }
        var targets: [PanelLayoutDropTarget] = []
        if ConfiguredMenuBarPanelLayout.usesColumnFlow(components: components, features: features, width: width) {
            let all = remaining + [source]
            let measured = PanelAdaptiveFlow.measuredItems(order: all.map { ($0.id, $0.kind) },
                components: Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0) }),
                features: Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0) }), width: width)
            let lookup = Dictionary(uniqueKeysWithValues: measured.map { ($0.id, $0) })
            guard let sourceItem = lookup[source.id] else { return [] }
            var state = PanelAdaptiveFlow.State(width: width,
                verticalGap: components.isEmpty && !features.contains(where: \.usesCompactPresentation)
                    ? MenuBarPanelLayout.featureRowSpacing : PanelCompactSwitchLayout.spacing)
            for boundary in 0...remaining.count {
                let offset = boundary + (sourceIndex.map { boundary > $0 ? 1 : 0 } ?? 0)
                targets.append(.init(offset: offset, markerFrame: nil, previewFrame: state.next(sourceItem)))
                if boundary < remaining.count, let item = lookup[remaining[boundary].id] { state.append(item) }
            }
        } else {
            // Balanced compact-only layouts and the original narrow widget grid
            // can depend on the final row composition. Cache their exact results.
            for offset in 0...entries.count {
                if let frame = PanelLayoutDropFootprint.frame(source: source, offset: offset, entries: entries,
                    components: components, features: features, width: width) {
                    targets.append(.init(offset: offset, markerFrame: nil, previewFrame: frame))
                }
            }
        }
        return targets
    }
}

/// The committed geometry remains the hit map until a drop is committed.
struct PanelLayoutEntryFrame: Equatable, Identifiable {
    let entry: MenuBarPanelEntry
    let frame: CGRect
    var isFlowItem = false
    var id: String { entry.id }

    static func frames(entries: [MenuBarPanelEntry], placement: ConfiguredMenuBarPanelLayout.Placement) -> [Self] {
        let components = Dictionary(uniqueKeysWithValues: placement.components.map { ($0.id, $0) })
        return entries.compactMap { entry in
            switch entry.kind {
            case .widget:
                guard let item = components[entry.id] else { return nil }
                return Self(entry: entry, frame: PanelLayoutDestination.frame(item))
            case .row:
                guard let y = placement.featureOffsets[entry.id],
                      let height = placement.featureHeights[entry.id] else { return nil }
                return Self(entry: entry, frame: placement.featureFrames[entry.id]
                    ?? CGRect(x: 0, y: y, width: ComponentPanelLayout.gridWidth, height: height),
                    isFlowItem: placement.flowFeatureIDs.contains(entry.id))
            }
        }
    }
}

/// Build once with the layout snapshot. Pointer updates use allocation-free scans;
/// each occupied edge or vacant footprint supplies its own offset and marker.
struct PanelLayoutDropGeometry {
    private struct Item {
        let frame: CGRect
        let isRow: Bool
        let before: PanelLayoutDropTarget
        let after: PanelLayoutDropTarget
    }

    private let items: [Item]
    private let vacancies: [PanelLayoutDropTarget]
    private let contentHeight: CGFloat
    private let width: CGFloat
    private let candidates: [PanelLayoutDropTarget]

    var maximumPreviewHeight: CGFloat {
        candidates.reduce(contentHeight) { max($0, $1.previewFrame?.maxY ?? 0) }
    }

    init(frames: [PanelLayoutEntryFrame], width: CGFloat = ComponentPanelLayout.gridWidth,
         vacancies: [PanelLayoutDropTarget] = [], candidates: [PanelLayoutDropTarget] = []) {
        self.width = width
        self.vacancies = vacancies
        self.candidates = candidates
        contentHeight = frames.reduce(0) { max($0, $1.frame.maxY) }
        items = frames.enumerated().map { index, item in
            let rect = item.frame
            let isRow = item.entry.kind == .row && !item.isFlowItem
            let before = isRow
                ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 3)
                : CGRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height)
            let after = isRow
                ? CGRect(x: rect.minX, y: rect.maxY - 3, width: rect.width, height: 3)
                : CGRect(x: rect.maxX - 3, y: rect.minY, width: 3, height: rect.height)
            return Item(frame: rect, isRow: isRow,
                        before: .init(offset: index, markerFrame: before),
                        after: .init(offset: index + 1, markerFrame: after))
        }
    }

    func target(at physicalPoint: CGPoint, rightToLeft: Bool, previousOffset: Int? = nil,
                verticalAnchorFraction: CGFloat? = nil) -> PanelLayoutDropTarget {
        let point = CGPoint(x: rightToLeft ? width - physicalPoint.x : physicalPoint.x, y: physicalPoint.y)
        if !candidates.isEmpty {
            // Target the leading column even for multi-column cards. Preserve
            // the grab position vertically; a tall card's center is not its handle.
            func distances(_ target: PanelLayoutDropTarget) -> (CGFloat, CGFloat) {
                guard let frame = target.previewFrame else { return (.infinity, .infinity) }
                let leadingEnd = frame.minX + min(frame.width, MenuBarPanelWidth.columnSlotWidth(forSurfaceWidth: width))
                let anchor = verticalAnchorFraction.map { frame.height * min(1, max(0, $0)) } ?? min(24, frame.height / 2)
                return (max(frame.minX - point.x, 0, point.x - leadingEnd), abs(frame.minY + anchor - point.y))
            }
            var best = candidates[0]
            var distance = distances(best)
            for candidate in candidates.dropFirst() {
                let next = distances(candidate)
                if next.0 < distance.0 - 0.001 || (abs(next.0 - distance.0) < 0.001 && next.1 < distance.1) {
                    best = candidate
                    distance = next
                }
            }
            if let previous = candidates.first(where: { $0.offset == previousOffset }) {
                let prior = distances(previous)
                if prior.0 <= distance.0 + 2 && prior.1 <= distance.1 + 6 { best = previous }
            }
            return mirrored(best, rightToLeft: rightToLeft)
        }
        if !items.contains(where: { $0.frame.contains(point) }),
           let vacancy = vacancies.first(where: { $0.markerFrame?.contains(point) == true }) {
            return mirrored(vacancy, rightToLeft: rightToLeft)
        }
        guard let first = items.first else {
            return .init(offset: 0, markerFrame: CGRect(x: 0, y: 0, width: width, height: 3))
        }
        if point.y < 0 { return mirrored(first.before, rightToLeft: rightToLeft) }
        if point.y >= contentHeight {
            return .init(offset: items.count,
                         markerFrame: CGRect(x: 0, y: contentHeight, width: width, height: 3))
        }

        var nearest = first
        var bestDistance = CGFloat.infinity
        var hasVerticalCandidate = false
        for item in items {
            let rect = item.frame
            let sameBand = point.y >= rect.minY && point.y < rect.maxY
            // Empty space at the end of a short widget row belongs to that row,
            // not to the full-width feature immediately below it.
            if hasVerticalCandidate && !sameBand { continue }
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = dx * dx + dy * dy
            if (sameBand && !hasVerticalCandidate) || distance < bestDistance {
                nearest = item
                bestDistance = distance
                hasVerticalCandidate = sameBand
            }
        }
        let after = nearest.isRow ? point.y >= nearest.frame.midY : point.x >= nearest.frame.midX
        return mirrored(after ? nearest.after : nearest.before, rightToLeft: rightToLeft)
    }

    private func mirrored(_ target: PanelLayoutDropTarget, rightToLeft: Bool) -> PanelLayoutDropTarget {
        guard rightToLeft else { return target }
        func mirror(_ frame: CGRect?) -> CGRect? {
            frame.map { CGRect(x: width - $0.maxX, y: $0.minY, width: $0.width, height: $0.height) }
        }
        return .init(offset: target.offset, markerFrame: mirror(target.markerFrame),
                     isVacancy: target.isVacancy, previewFrame: mirror(target.previewFrame))
    }
}
