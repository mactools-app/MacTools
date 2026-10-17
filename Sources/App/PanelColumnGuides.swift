import SwiftUI

/// Guides occupy empty gutters. Custom-width rows and plugin widgets cut their
/// own openings, so a divider never runs through interactive content.
struct PanelColumnGuides: View {
    let frames: [CGRect]
    let width: CGFloat
    let height: CGFloat
    var isEditing = false
    var isDragging = false
    @Environment(\.menuBarPanelTheme) private var theme
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        Path { path in
            let columns = MenuBarPanelWidth.columns(forSurfaceWidth: width)
            let stride = MenuBarPanelWidth.columnSlotWidth(forSurfaceWidth: width) + MenuBarPanelWidth.allocationSpacing
            if columns > 1 {
                for column in 1..<columns {
                    let x = CGFloat(column) * stride - MenuBarPanelWidth.allocationSpacing / 2
                    let left = frames.filter { $0.maxX <= x - 2 && $0.maxX > x - stride }
                    let right = frames.filter { $0.minX >= x + 2 && $0.minX < x + stride }
                    let blocked = frames.filter { $0.minX < x + 2 && $0.maxX > x - 2 }
                    for range in Self.segments(left: left, right: right, blocked: blocked, height: height) {
                        let physicalX = layoutDirection == .rightToLeft ? width - x : x
                        path.move(to: CGPoint(x: physicalX, y: range.lowerBound))
                        path.addLine(to: CGPoint(x: physicalX, y: range.upperBound))
                    }
                }
            }
        }
        .stroke(isEditing ? theme.accent.opacity(isDragging ? 0.55 : 0.28) : theme.surfaces.separator,
                style: StrokeStyle(lineWidth: isEditing ? 1 : 0.5, dash: isEditing ? [3, 3] : []))
        .frame(width: width, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func segments(left: [CGRect], right: [CGRect], blocked: [CGRect], height: CGFloat) -> [ClosedRange<CGFloat>] {
        func merged(_ frames: [CGRect]) -> [ClosedRange<CGFloat>] {
            let ranges = frames.map { max(0, $0.minY - 3)...min(height, $0.maxY + 3) }
                .sorted { $0.lowerBound < $1.lowerBound }
            var result: [ClosedRange<CGFloat>] = []
            for range in ranges {
                if let last = result.last, last.upperBound >= range.lowerBound {
                    result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
                } else { result.append(range) }
            }
            return result
        }
        let obstacles = merged(blocked)
        var result: [ClosedRange<CGFloat>] = []
        for lhs in merged(left) {
            for rhs in merged(right) {
                var start = max(lhs.lowerBound, rhs.lowerBound)
                let end = min(lhs.upperBound, rhs.upperBound)
                guard start < end else { continue }
                for obstacle in obstacles where obstacle.upperBound > start && obstacle.lowerBound < end {
                    if obstacle.lowerBound > start { result.append(start...min(end, obstacle.lowerBound)) }
                    start = max(start, obstacle.upperBound)
                    if start >= end { break }
                }
                if start < end { result.append(start...end) }
            }
        }
        return result
    }
}
