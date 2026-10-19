import AppKit
import MacToolsPluginKit

/// Vacancy targets are real insertion results, not inferred neighbor edges.
/// Each prefix is packed once; asking for its next placement does not mutate it.
enum PanelLayoutWidgetDropTargets {
    static func targets(
        source: PluginPanelWidgetSnapshot, entries: [MenuBarPanelEntry],
        components: [PluginPanelWidgetSnapshot], features: [PluginPanelRowSnapshot],
        frames: [PanelLayoutEntryFrame], width: CGFloat = ComponentPanelLayout.gridWidth, sourceIsFlexible: Bool = false
    ) -> [PanelLayoutDropTarget] {
        // Flexible cards can change width and row count when inserted. Use their
        // actual item edges instead of promising a fixed vacant footprint.
        guard !sourceIsFlexible, features.isEmpty else { return [] }
        let sourceIndex = entries.firstIndex { $0.id == source.id }
        let remaining = entries.filter { $0.id != source.id }
        let spans = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0.span) })
        let baseline = ConfiguredMenuBarPanelLayout.placement(
            entries: remaining, components: components, features: features, width: width)
        let obstacles = ObstacleIndex(frames: frames.filter { $0.id != source.id }.map(\.frame))
        var targets: [PanelLayoutDropTarget] = []
        var start = 0

        while true {
            var end = start
            while end < remaining.count, spans[remaining[end].id] != nil { end += 1 }
            let originY: CGFloat
            if start == 0 {
                originY = 0
            } else {
                let rowID = remaining[start - 1].id
                originY = baseline.featureOffsets[rowID, default: 0]
                    + baseline.featureHeights[rowID, default: 0] + ConfiguredMenuBarPanelLayout.itemSpacing
            }
            var state = ComponentGridPlacementEngine.State(hasCompactItems: source.span.grid == .compact
                || remaining[start..<end].contains { spans[$0.id]?.grid == .compact }, width: width)
            for boundary in start...end {
                let placement = state.next(id: source.id, span: source.span)
                let frame = PanelLayoutDestination.frame(placement).offsetBy(dx: 0, dy: originY)
                // Reject gaps too small for this widget, including the normal gutters.
                let clearance = frame.insetBy(dx: -ComponentPanelLayout.horizontalSpacing + 0.001,
                                               dy: -ComponentPanelLayout.verticalSpacing + 0.001)
                if !obstacles.intersects(clearance) {
                    let offset = boundary + (sourceIndex.map { boundary > $0 ? 1 : 0 } ?? 0)
                    let target = PanelLayoutDropTarget(offset: offset, markerFrame: frame, isVacancy: true)
                    if targets.last?.markerFrame != frame { targets.append(target) }
                }
                if boundary < end, let span = spans[remaining[boundary].id] {
                    state.append(id: remaining[boundary].id, span: span)
                }
            }
            guard end < remaining.count else { break }
            start = end + 1
        }
        return targets
    }

    /// Most candidates only need to check the few cards at their vertical level.
    /// Prefix maxima also retain tall cards that started above that level.
    private struct ObstacleIndex {
        let frames: [CGRect]
        let maximumBottoms: [CGFloat]

        init(frames: [CGRect]) {
            self.frames = frames.sorted { $0.minY < $1.minY }
            var bottom: CGFloat = 0
            maximumBottoms = self.frames.map { frame in
                bottom = max(bottom, frame.maxY)
                return bottom
            }
        }

        func intersects(_ candidate: CGRect) -> Bool {
            var lower = 0
            var upper = frames.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if frames[middle].minY < candidate.maxY { lower = middle + 1 }
                else { upper = middle }
            }
            var index = lower - 1
            while index >= 0, maximumBottoms[index] > candidate.minY {
                if frames[index].intersects(candidate) { return true }
                index -= 1
            }
            return false
        }
    }
}

/// Keep candidate construction out of pointer updates and unrelated plugin updates.
@MainActor
final class PanelLayoutDropGeometryCache: ObservableObject {
    private struct Source: Equatable {
        let entry: MenuBarPanelEntry?
        let id: String?
        let span: PluginPanelWidgetSpan?
        let isFlexible: Bool
        let size: CGSize?
        let title: String?
    }

    private var frames: [PanelLayoutEntryFrame] = []
    private var spans: [PluginPanelWidgetSpan] = []
    private var source: Source?
    private var titles: [String] = []
    private var cached: PanelLayoutDropGeometry?
    private var width: CGFloat?

    func geometry(
        entries: [MenuBarPanelEntry], components: [PluginPanelWidgetSnapshot], features: [PluginPanelRowSnapshot],
        frames: [PanelLayoutEntryFrame], source: PluginPanelWidgetSnapshot?,
        width: CGFloat = ComponentPanelLayout.gridWidth, sourceIsFlexible: Bool = false,
        sourceEntry: MenuBarPanelEntry? = nil, sourceFeature: PluginPanelRowSnapshot? = nil
    ) -> PanelLayoutDropGeometry {
        let sourceSize = sourceEntry.flatMap { entry in frames.first { $0.id == entry.id }?.frame.size }
            ?? sourceFeature.map { row in
                let width = row.usesCompactPresentation
                    ? (MenuBarPanelWidth.columnWidth(forSurfaceWidth: width) - PanelCompactSwitchLayout.spacing) / 2
                    : PanelItemWidthLayout.resolved(row.width, available: width)
                return CGSize(width: width, height: row.usesCompactPresentation
                    ? PanelCompactSwitchLayout.height(title: row.title, width: width)
                    : MenuBarPanelLayout.rowHeight(for: row, width: width))
            }
        let sourceKey = Source(entry: sourceEntry, id: source?.id, span: source?.span,
                               isFlexible: sourceIsFlexible, size: sourceSize, title: sourceFeature?.title)
        let spans = components.map(\.span)
        let titles = features.map(\.title)
        if let cached, self.frames == frames, self.spans == spans, self.source == sourceKey,
           self.width == width, self.titles == titles { return cached }
        let candidates = sourceEntry.map {
            PanelLayoutDropCandidates.targets(source: $0, entries: entries, components: components, features: features, width: width)
        } ?? []
        let targets = candidates.isEmpty ? source.map {
            PanelLayoutWidgetDropTargets.targets(source: $0, entries: entries, components: components,
                                                features: features, frames: frames, width: width, sourceIsFlexible: sourceIsFlexible)
        } ?? [] : []
        let geometry = PanelLayoutDropGeometry(frames: frames, width: width, vacancies: targets, candidates: candidates)
        self.width = width
        self.frames = frames
        self.spans = spans
        self.source = sourceKey
        self.titles = titles
        cached = geometry
        return geometry
    }
}
