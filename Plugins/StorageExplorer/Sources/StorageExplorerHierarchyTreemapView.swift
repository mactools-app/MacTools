import SwiftUI
import MacToolsPluginKit

struct StorageExplorerTreemapHoverSummary: Equatable {
    enum Tone: Equatable {
        case normal
        case warning
        case blocked
        case selected
    }

    let title: String
    let detail: String
    let path: String
    let systemImage: String
    let tone: Tone
}

struct StorageExplorerReviewEligibilityCopy {
    let addToReview: String
    let removeFromReview: String
    let selected: String
    let includedByParentFormat: String
    let busy: String
    let incompleteFormat: String
    let symlink: String
    let aggregate: String
    let cachedPreview: String
    let scanRoot: String
    let protectedLocation: String
    let unavailable: String

    func message(for eligibility: StorageExplorerReviewEligibility) -> String {
        switch eligibility {
        case .eligible:
            addToReview
        case .selected:
            selected
        case let .includedBySelectedParent(name):
            String(format: includedByParentFormat, locale: PluginRuntimeLocalization.locale, name)
        case .busy:
            busy
        case let .incomplete(skippedCount):
            String(format: incompleteFormat, locale: PluginRuntimeLocalization.locale, skippedCount)
        case .symlink:
            symlink
        case .aggregate:
            aggregate
        case .cachedPreview:
            cachedPreview
        case .scanRoot:
            scanRoot
        case .protectedLocation:
            protectedLocation
        case .unavailable:
            unavailable
        }
    }

    func icon(for eligibility: StorageExplorerReviewEligibility) -> String {
        switch eligibility {
        case .eligible: "plus.circle.fill"
        case .selected: "checkmark.circle.fill"
        case .includedBySelectedParent: "checkmark.circle"
        case .busy: "clock"
        case .incomplete: "plus.circle.fill"
        case .symlink: "link"
        case .aggregate: "square.stack.3d.up.slash"
        case .cachedPreview: "clock.arrow.circlepath"
        case .scanRoot: "scope"
        case .protectedLocation: "lock.shield.fill"
        case .unavailable: "exclamationmark.circle"
        }
    }
}

struct StorageExplorerHierarchyTreemapView: View {
    let nodes: [StorageExplorerHierarchyNode]
    let layoutRevision: Int
    @Binding var selection: String?
    @Binding var hoveredListRowID: String?
    @Binding var hoveredSummary: StorageExplorerTreemapHoverSummary?
    let emptyLabel: String
    let reviewCopy: StorageExplorerReviewEligibilityCopy
    let revealInFinderLabel: String
    let open: (StorageItem) -> Void
    let preview: (StorageItem) -> Bool
    let toggleReview: (StorageItem) -> Void
    let reviewEligibility: (StorageItem) -> StorageExplorerReviewEligibility
    let revealInFinder: (StorageItem) -> Void
    let layoutReady: (Int) -> Void

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rectangles: [StorageExplorerHierarchyRect] = []
    @State private var previousRectangles: [StorageExplorerHierarchyRect] = []
    @State private var previousLayoutRevision = -1
    @State private var showCurrentLayout = true
    @State private var layoutTransitionRevision = 0
    @State private var pointerState = StorageExplorerTreemapPointerState()
    @FocusState private var focusedID: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())

                if !previousRectangles.isEmpty {
                StorageExplorerTreemapBaseLayer(
                    rectangles: previousRectangles,
                    reviewEligibility: eligibilityMap(for: previousRectangles),
                    selectedID: nil,
                    focusedID: nil
                    )
                    .equatable()
                    .opacity(showCurrentLayout ? 0 : 1)
                    .allowsHitTesting(false)
                }

                StorageExplorerTreemapBaseLayer(
                    rectangles: rectangles,
                    reviewEligibility: eligibilityMap(for: rectangles),
                    selectedID: selection,
                    focusedID: focusedID
                )
                .equatable()
                .opacity(showCurrentLayout ? 1 : 0)

                ForEach(interactiveRectangles) { entry in
                    interactiveRegion(entry)
                }

                StorageExplorerTreemapPointerLayer(
                    rectangles: rectangles,
                    pointerState: pointerState,
                    selection: $selection,
                    reviewCopy: reviewCopy,
                    revealInFinderLabel: revealInFinderLabel,
                    open: open,
                    toggleReview: toggleReview,
                    reviewEligibility: reviewEligibility,
                    revealInFinder: revealInFinder
                )

                if rectangles.isEmpty {
                    Text(emptyLabel)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onContinuousHover { phase in
                let update = pointerState.update(phase, rectangles: rectangles)
                if update.listRowChanged, hoveredListRowID != update.listRowID {
                    hoveredListRowID = update.listRowID
                }
                let summary = currentHoverSummary
                if hoveredSummary != summary {
                    hoveredSummary = summary
                }
            }
            .onAppear { updateLayout(size: geometry.size, revision: layoutRevision) }
            .onChange(of: geometry.size) { _, newSize in
                updateLayout(size: newSize, revision: layoutRevision)
            }
            .onChange(of: layoutRevision) { _, revision in
                updateLayout(size: geometry.size, revision: revision)
            }
            .task(id: layoutTransitionRevision) {
                guard !previousRectangles.isEmpty, !reduceMotion else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    showCurrentLayout = true
                }
                try? await Task.sleep(for: .milliseconds(190))
                guard !Task.isCancelled else { return }
                previousRectangles = []
                layoutReady(previousLayoutRevision)
            }
        }
    }

    private func interactiveRegion(_ entry: StorageExplorerHierarchyRect) -> some View {
        let inset = interactionRect(for: entry.rect)
        let eligibility = eligibility(for: entry)
        return Color.clear
            .contentShape(Rectangle())
            .frame(width: max(0, inset.width), height: max(0, inset.height))
            .onTapGesture {
                guard !entry.node.isAggregate else { return }
                if entry.node.item.isDirectory && !entry.node.item.isPackage {
                    open(entry.node.item)
                } else {
                    selection = entry.id
                }
            }
            .contextMenu {
                if !entry.node.isAggregate {
                    if eligibility.canToggle {
                        Button(eligibility == .selected ? reviewCopy.removeFromReview : reviewCopy.addToReview) {
                            toggleReview(entry.node.item)
                        }
                    } else {
                        Label(
                            reviewCopy.message(for: eligibility),
                            systemImage: reviewCopy.icon(for: eligibility)
                        )
                    }
                    Divider()
                    Button {
                        revealInFinder(entry.node.item)
                    } label: {
                        Label(revealInFinderLabel, systemImage: "folder")
                    }
                }
            }
            .focusable(!entry.node.isAggregate, interactions: .activate)
            .focused($focusedID, equals: entry.id)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard !entry.node.isAggregate else { return .ignored }
                activate(entry)
                return .handled
            }
            .onKeyPress(.space) {
                guard !entry.node.isAggregate else { return .ignored }
                return preview(entry.node.item) ? .handled : .ignored
            }
            .modifier(StorageExplorerTreemapAccessibilityModifier(
                label: entry.node.item.name,
                value: StorageExplorerFormatting.bytes(entry.node.bytes),
                hint: helpText(for: entry.node) + helpSuffix(for: entry.node),
                enabled: !entry.node.isAggregate,
                reviewAvailable: eligibility.canToggle,
                addReviewLabel: eligibility == .selected ? reviewCopy.removeFromReview : reviewCopy.addToReview,
                activate: { activate(entry) },
                addToReview: { toggleReview(entry.node.item) }
            ))
            // Keep positioning last so drag previews and hit targets use the tile's
            // local bounds instead of the full treemap coordinate space.
            .position(x: inset.midX, y: inset.midY)
    }

    private func activate(_ entry: StorageExplorerHierarchyRect) {
        if entry.node.item.isDirectory && !entry.node.item.isPackage {
            open(entry.node.item)
        } else {
            selection = entry.id
        }
    }

    private var interactiveRectangles: [StorageExplorerHierarchyRect] {
        rectangles.filter {
            !$0.node.isAggregate && $0.rect.width >= 22 && $0.rect.height >= 20
        }
    }

    private func updateLayout(size: CGSize, revision: Int) {
        pointerState.reset()
        hoveredListRowID = nil
        hoveredSummary = nil
        let nextRectangles = StorageExplorerHierarchyRectLayout.make(
            nodes: nodes,
            in: CGRect(origin: .zero, size: size),
            locale: locale
        )
        let contentChanged = !rectangles.isEmpty && previousLayoutRevision != revision
        previousLayoutRevision = revision
        layoutTransitionRevision += 1
        if contentChanged && !reduceMotion {
            previousRectangles = rectangles
            rectangles = nextRectangles
            showCurrentLayout = false
        } else {
            previousRectangles = []
            rectangles = nextRectangles
            showCurrentLayout = true
            Task { @MainActor in
                await Task.yield()
                layoutReady(revision)
            }
        }
    }

    private func interactionRect(for rect: CGRect) -> CGRect {
        rect.insetBy(
            dx: min(2, max(0, rect.width / 2)),
            dy: min(2, max(0, rect.height / 2))
        )
    }

    private func helpText(for node: StorageExplorerHierarchyNode) -> String {
        let size = StorageExplorerFormatting.bytes(node.bytes)
        return node.isAggregate ? "\(node.item.name) · \(size)" : "\(node.item.name) · \(size)\n\(node.item.path)"
    }

    private func helpSuffix(for node: StorageExplorerHierarchyNode) -> String {
        let state = node.isAggregate ? StorageExplorerReviewEligibility.aggregate : reviewEligibility(node.item)
        return state == .eligible ? "" : "\n" + reviewCopy.message(for: state)
    }

    private func eligibility(for entry: StorageExplorerHierarchyRect) -> StorageExplorerReviewEligibility {
        entry.node.isAggregate ? .aggregate : reviewEligibility(entry.node.item)
    }

    private func eligibilityMap(
        for entries: [StorageExplorerHierarchyRect]
    ) -> [String: StorageExplorerReviewEligibility] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.id, eligibility(for: $0)) })
    }

    private var currentHoverSummary: StorageExplorerTreemapHoverSummary? {
        guard let hoveredIndex = pointerState.hoveredIndex,
              rectangles.indices.contains(hoveredIndex)
        else { return nil }
        let entry = rectangles[hoveredIndex]
        let size = StorageExplorerFormatting.bytes(entry.node.bytes)
        if entry.node.isAggregate {
            return StorageExplorerTreemapHoverSummary(
                title: "\(entry.node.item.name) · \(size)",
                detail: reviewCopy.message(for: .aggregate),
                path: entry.node.item.path,
                systemImage: reviewCopy.icon(for: .aggregate),
                tone: .normal
            )
        }

        let state = reviewEligibility(entry.node.item)
        let detail = state == .eligible ? entry.node.item.path : reviewCopy.message(for: state)
        let icon: String
        let tone: StorageExplorerTreemapHoverSummary.Tone
        switch state {
        case .eligible:
            icon = entry.node.item.iconSystemName
            tone = .normal
        case .selected, .includedBySelectedParent:
            icon = "checkmark.circle.fill"
            tone = .selected
        case .incomplete:
            icon = "exclamationmark.triangle.fill"
            tone = .warning
        case .scanRoot, .protectedLocation:
            icon = reviewCopy.icon(for: state)
            tone = .blocked
        case .busy, .symlink, .aggregate, .cachedPreview, .unavailable:
            icon = reviewCopy.icon(for: state)
            tone = .normal
        }
        return StorageExplorerTreemapHoverSummary(
            title: "\(entry.node.item.name) · \(size)",
            detail: detail,
            path: entry.node.item.path,
            systemImage: icon,
            tone: tone
        )
    }
}

@MainActor
private final class StorageExplorerTreemapPointerState: ObservableObject {
    private(set) var hoveredIndex: Int?
    private(set) var hoverLocation: CGPoint?

    func update(
        _ phase: HoverPhase,
        rectangles: [StorageExplorerHierarchyRect]
    ) -> (listRowChanged: Bool, listRowID: String?) {
        switch phase {
        case let .active(location):
            // Parent and child rectangles overlap by design. Resolve hover once so the deepest
            // visible tile wins without hundreds of competing hover gestures.
            let nextIndex = rectangles.lastIndex(where: { $0.rect.contains(location) })
            let indexChanged = hoveredIndex != nextIndex
            let locationChanged: Bool
            if let previous = hoverLocation {
                let deltaX = previous.x - location.x
                let deltaY = previous.y - location.y
                locationChanged = deltaX * deltaX + deltaY * deltaY >= 9
            } else {
                locationChanged = true
            }
            if indexChanged || locationChanged {
                objectWillChange.send()
                hoveredIndex = nextIndex
                if locationChanged { hoverLocation = location }
            }
            let rowID = nextIndex.flatMap {
                rectangles[$0].node.isAggregate ? nil : rectangles[$0].rootID
            }
            return (indexChanged, rowID)
        case .ended:
            let hadHover = hoveredIndex != nil || hoverLocation != nil
            if hadHover {
                objectWillChange.send()
                hoveredIndex = nil
                hoverLocation = nil
            }
            return (hadHover, nil)
        }
    }

    func reset() {
        guard hoveredIndex != nil || hoverLocation != nil else { return }
        objectWillChange.send()
        hoveredIndex = nil
        hoverLocation = nil
    }
}

/// Only this lightweight overlay observes pointer-state changes. It has no full-size hit target,
/// so the static tile regions remain clickable even if tracking resets during a layout change.
private struct StorageExplorerTreemapPointerLayer: View {
    let rectangles: [StorageExplorerHierarchyRect]
    @ObservedObject var pointerState: StorageExplorerTreemapPointerState
    @Binding var selection: String?
    let reviewCopy: StorageExplorerReviewEligibilityCopy
    let revealInFinderLabel: String
    let open: (StorageItem) -> Void
    let toggleReview: (StorageItem) -> Void
    let reviewEligibility: (StorageItem) -> StorageExplorerReviewEligibility
    let revealInFinder: (StorageItem) -> Void
    @State private var statusExplanation: StatusExplanation?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let hoveredEntry {
                StorageExplorerTreemapHoverLayer(entry: hoveredEntry)
                    .allowsHitTesting(false)
            }

            if let hovered = hoveredEntry {
                let eligibility = eligibility(for: hovered)
                if let hoverLocation = pointerState.hoverLocation,
                   eligibility.canAdd {
                    dragHotspot(for: hovered, at: hoverLocation)
                }
                hoverReviewControl(for: hovered, eligibility: eligibility)
                statusExplanationControl(for: hovered, eligibility: eligibility)
            }
        }
    }

    private var hoveredEntry: StorageExplorerHierarchyRect? {
        guard let hoveredIndex = pointerState.hoveredIndex,
              rectangles.indices.contains(hoveredIndex) else { return nil }
        return rectangles[hoveredIndex]
    }

    private func activate(_ entry: StorageExplorerHierarchyRect) {
        if entry.node.item.isDirectory && !entry.node.item.isPackage {
            open(entry.node.item)
        } else {
            selection = entry.id
        }
    }

    /// Keep exactly one compact drag source under the pointer. This gives every drag a visible,
    /// pointer-anchored preview without registering a drag interaction for every treemap tile.
    private func dragHotspot(
        for entry: StorageExplorerHierarchyRect,
        at location: CGPoint
    ) -> some View {
        let inset = interactionRect(for: entry.rect)
        let diameter: CGFloat = 34
        let width = max(0, min(diameter, inset.width))
        let height = max(0, min(diameter, inset.height))
        let halfWidth = width / 2
        let halfHeight = height / 2
        let x = min(max(location.x, inset.minX + halfWidth), inset.maxX - halfWidth)
        let y = min(max(location.y, inset.minY + halfHeight), inset.maxY - halfHeight)
        return Color.clear
            .contentShape(Rectangle())
            .frame(width: width, height: height)
            .draggable(entry.node.item.path) {
                StorageExplorerDragPreview(item: entry.node.item, bytes: entry.node.bytes)
            }
            .onTapGesture { activate(entry) }
            .contextMenu {
                Button(reviewCopy.addToReview) { toggleReview(entry.node.item) }
                Divider()
                Button {
                    revealInFinder(entry.node.item)
                } label: {
                    Label(revealInFinderLabel, systemImage: "folder")
                }
            }
            .accessibilityHidden(true)
            .position(x: x, y: y)
            .zIndex(9)
    }

    @ViewBuilder
    private func hoverReviewControl(
        for entry: StorageExplorerHierarchyRect,
        eligibility: StorageExplorerReviewEligibility
    ) -> some View {
        let inset = interactionRect(for: entry.rect)
        if eligibility.canToggle {
            let usesCornerControl = inset.width > 54 && inset.height > 38
            Button { toggleReview(entry.node.item) } label: {
                Image(systemName: eligibility == .selected ? "minus.circle.fill" : "plus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.system(size: usesCornerControl ? 16 : 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(eligibility == .selected ? reviewCopy.removeFromReview : reviewCopy.addToReview)
            .position(
                x: usesCornerControl ? inset.maxX - 15 : inset.midX,
                y: usesCornerControl ? inset.minY + 15 : inset.midY
            )
            .zIndex(10)
        }
    }

    @ViewBuilder
    private func statusExplanationControl(
        for entry: StorageExplorerHierarchyRect,
        eligibility: StorageExplorerReviewEligibility
    ) -> some View {
        let inset = interactionRect(for: entry.rect)
        if let badge = StorageExplorerTreemapBadgeGeometry.frame(for: eligibility, in: inset) {
            let message = reviewCopy.message(for: eligibility)
            Button {
                statusExplanation = StatusExplanation(
                    id: entry.id,
                    title: entry.node.item.name,
                    detail: message,
                    path: entry.node.item.path,
                    systemImage: statusSystemImage(for: eligibility)
                )
            } label: {
                Color.clear
                    .frame(width: max(24, badge.width + 6), height: max(24, badge.height + 6))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(message)
            .accessibilityLabel(message)
            .position(x: badge.midX, y: badge.midY)
            .zIndex(11)
            .popover(item: $statusExplanation, arrowEdge: .trailing) { explanation in
                VStack(alignment: .leading, spacing: 6) {
                    Label(explanation.title, systemImage: explanation.systemImage)
                        .font(.headline)
                    Text(explanation.detail)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(explanation.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .frame(width: 300, alignment: .leading)
                .padding(12)
            }
        }
    }

    private func interactionRect(for rect: CGRect) -> CGRect {
        rect.insetBy(
            dx: min(2, max(0, rect.width / 2)),
            dy: min(2, max(0, rect.height / 2))
        )
    }

    private func eligibility(for entry: StorageExplorerHierarchyRect) -> StorageExplorerReviewEligibility {
        entry.node.isAggregate ? .aggregate : reviewEligibility(entry.node.item)
    }

    private func statusSystemImage(for eligibility: StorageExplorerReviewEligibility) -> String {
        switch eligibility {
        case .incomplete:
            "exclamationmark.triangle.fill"
        case .selected, .includedBySelectedParent:
            "checkmark.circle.fill"
        default:
            reviewCopy.icon(for: eligibility)
        }
    }

    private struct StatusExplanation: Identifiable {
        let id: String
        let title: String
        let detail: String
        let path: String
        let systemImage: String
    }
}

private struct StorageExplorerTreemapBaseLayer: View, Equatable {
    let rectangles: [StorageExplorerHierarchyRect]
    let reviewEligibility: [String: StorageExplorerReviewEligibility]
    let selectedID: String?
    let focusedID: String?

    var body: some View {
        Canvas { context, _ in
            for entry in rectangles {
                StorageExplorerTreemapRenderer.drawBase(
                    entry,
                    reviewEligibility: reviewEligibility[entry.id] ?? .unavailable,
                    context: &context,
                    selected: selectedID == entry.id,
                    focused: focusedID == entry.id
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct StorageExplorerTreemapHoverLayer: View, Equatable {
    let entry: StorageExplorerHierarchyRect

    var body: some View {
        Canvas { context, _ in
            StorageExplorerTreemapRenderer.drawHover(entry, context: &context)
        }
        .accessibilityHidden(true)
    }
}

private enum StorageExplorerTreemapBadgeGeometry {
    static func frame(
        for eligibility: StorageExplorerReviewEligibility,
        in bounds: CGRect
    ) -> CGRect? {
        guard eligibility != .eligible,
              eligibility != .busy,
              eligibility != .cachedPreview,
              bounds.width >= 24,
              bounds.height >= 24
        else { return nil }

        let diameter = min(18, min(bounds.width, bounds.height) - 6)
        guard diameter >= 10 else { return nil }
        let usesBottomCorner = switch eligibility {
        case .incomplete, .selected:
            true
        default:
            false
        }
        return CGRect(
            x: bounds.maxX - diameter - 4,
            y: usesBottomCorner ? bounds.maxY - diameter - 4 : bounds.minY + 4,
            width: diameter,
            height: diameter
        )
    }
}

private enum StorageExplorerTreemapRenderer {
    private static let palette: [Color] = [
        Color(red: 0.68, green: 0.34, blue: 0.38),
        Color(red: 0.69, green: 0.46, blue: 0.37),
        Color(red: 0.64, green: 0.54, blue: 0.36),
        Color(red: 0.42, green: 0.54, blue: 0.40),
        Color(red: 0.34, green: 0.52, blue: 0.51),
        Color(red: 0.39, green: 0.48, blue: 0.61),
        Color(red: 0.48, green: 0.43, blue: 0.61),
        Color(red: 0.56, green: 0.41, blue: 0.51),
    ]

    static func drawBase(
        _ entry: StorageExplorerHierarchyRect,
        reviewEligibility: StorageExplorerReviewEligibility,
        context: inout GraphicsContext,
        selected: Bool,
        focused: Bool
    ) {
        let inset = entry.rect.insetBy(dx: entry.depth == 0 ? 1.5 : 1, dy: entry.depth == 0 ? 1.5 : 1)
        guard inset.width > 0, inset.height > 0 else { return }
        let shape = Path(roundedRect: inset, cornerRadius: entry.depth == 0 ? 6 : 4)
        let brightness = max(0.5, 0.88 - Double(entry.depth) * 0.10)
        context.fill(shape, with: .color(color(for: entry.node.colorKey).opacity(brightness)))
        if entry.node.isAggregate {
            drawAggregatePattern(in: shape, bounds: inset, context: &context)
        }
        if case .incomplete = reviewEligibility {
            context.stroke(
                shape,
                with: .color(.orange.opacity(0.9)),
                style: StrokeStyle(lineWidth: 2, dash: [5, 3])
            )
        }
        context.stroke(
            shape,
            with: .color(.white.opacity(entry.depth == 0 ? 0.72 : 0.42)),
            lineWidth: 1
        )
        if focused || selected {
            context.stroke(
                shape,
                with: .color(focused ? Color.accentColor : .white),
                lineWidth: focused ? 4 : 2.5
            )
        }
        if inset.width > 62, inset.height > 30 {
            context.draw(
                Text(entry.node.item.name)
                    .font(.system(size: entry.depth == 0 ? 13 : 11, weight: .semibold))
                    .foregroundStyle(.white),
                in: CGRect(x: inset.minX + 8, y: inset.minY + 6, width: inset.width - 16, height: 18)
            )
            if inset.height > 52 {
                context.draw(
                    Text(entry.sizeLabel).font(.caption2).foregroundStyle(.white.opacity(0.9)),
                    in: CGRect(x: inset.minX + 8, y: inset.minY + 25, width: inset.width - 16, height: 16)
                )
            }
        }
        drawReviewBadge(reviewEligibility, in: inset, context: &context)
    }

    private static func drawReviewBadge(
        _ eligibility: StorageExplorerReviewEligibility,
        in bounds: CGRect,
        context: inout GraphicsContext
    ) {
        let icon: String
        let color: Color
        switch eligibility {
        case .eligible:
            return
        case .selected:
            icon = "checkmark"
            color = .accentColor
        case .includedBySelectedParent:
            icon = "checkmark"
            color = .accentColor
        case .busy:
            return
        case .cachedPreview:
            return
        case .incomplete:
            icon = "exclamationmark"
            color = .orange
        case .symlink:
            icon = "link"
            color = .secondary
        case .aggregate:
            icon = "square.stack.3d.up.slash"
            color = .secondary
        case .scanRoot:
            icon = "scope"
            color = .red
        case .protectedLocation:
            icon = "lock.fill"
            color = .red
        case .unavailable:
            icon = "exclamationmark"
            color = .orange
        }
        guard let badge = StorageExplorerTreemapBadgeGeometry.frame(for: eligibility, in: bounds) else { return }
        let diameter = badge.width
        context.fill(Path(ellipseIn: badge), with: .color(color.opacity(0.92)))
        context.draw(
            Text(Image(systemName: icon))
                .font(.system(size: max(7, diameter * 0.56), weight: .bold))
                .foregroundStyle(.white),
            at: CGPoint(x: badge.midX, y: badge.midY)
        )
    }

    static func drawHover(_ entry: StorageExplorerHierarchyRect, context: inout GraphicsContext) {
        let inset = entry.rect.insetBy(dx: entry.depth == 0 ? 1.5 : 1, dy: entry.depth == 0 ? 1.5 : 1)
        guard inset.width > 0, inset.height > 0 else { return }
        let shape = Path(roundedRect: inset, cornerRadius: entry.depth == 0 ? 6 : 4)
        context.fill(shape, with: .color(.white.opacity(0.18)))
        context.stroke(shape, with: .color(.white), lineWidth: 3.5)
        context.stroke(shape, with: .color(.black.opacity(0.45)), lineWidth: 1)
    }

    private static func drawAggregatePattern(in shape: Path, bounds: CGRect, context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.clip(to: shape)
            var stripes = Path()
            let spacing: CGFloat = 10
            var offset = -bounds.height
            while offset < bounds.width {
                stripes.move(to: CGPoint(x: bounds.minX + offset, y: bounds.maxY))
                stripes.addLine(to: CGPoint(x: bounds.minX + offset + bounds.height, y: bounds.minY))
                offset += spacing
            }
            layer.stroke(stripes, with: .color(.white.opacity(0.15)), lineWidth: 2)
        }
    }

    private static func color(for key: String) -> Color {
        if key.hasPrefix("size-rank:"),
           let rank = Int(key.dropFirst("size-rank:".count).prefix { $0.isNumber }) {
            return palette[min(rank, palette.count - 1)]
        }
        return .gray
    }
}

private struct StorageExplorerTreemapAccessibilityModifier: ViewModifier {
    let label: String
    let value: String
    let hint: String
    let enabled: Bool
    let reviewAvailable: Bool
    let addReviewLabel: String
    let activate: () -> Void
    let addToReview: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            if reviewAvailable {
                accessible(content)
                    .accessibilityAction { activate() }
                    .accessibilityAction(named: Text(addReviewLabel)) { addToReview() }
            } else {
                accessible(content)
                    .accessibilityAction { activate() }
            }
        } else {
            accessible(content)
        }
    }

    private func accessible(_ content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityHint(hint)
    }
}

private struct StorageExplorerDragPreview: View {
    let item: StorageItem
    let bytes: Int64

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.iconSystemName)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(StorageExplorerFormatting.bytes(bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
