import AppKit
import SwiftUI
import MacToolsPluginKit

/// Cache localized measurements independently of hover and pointer movement.
struct PanelLayoutControlLabels: Equatable, Sendable {
    let titles: [String]
    let widths: [CGFloat]
    let fontSize: CGFloat
    @MainActor private static var cached: (locale: String, labels: Self)?

    @MainActor init(titles: [String]) {
        self.titles = titles
        let font = PluginTypography.control.nsFont
        fontSize = font.pointSize
        widths = titles.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
    }

    @MainActor static var localized: Self {
        let locale = PluginRuntimeLocalization.preferredLanguages.joined(separator: ",")
        if let cached, cached.locale == locale,
           cached.labels.fontSize == PluginTypography.control.nsFont.pointSize { return cached.labels }
        let labels = Self(titles: [FeatureL10n.string("移除"), FeatureL10n.string("移动到"),
                                   FeatureL10n.string("更多")])
        cached = (locale, labels)
        return labels
    }
}

/// One geometry contract for SwiftUI controls, AppKit hit testing, and cursors.
struct PanelLayoutItemControlsLayout {
    let isVertical: Bool
    let isCompact: Bool
    let showsLabels: Bool
    let buttonSide: CGFloat
    let buttonWidths: [CGFloat]
    let spacing: CGFloat = 8

    @MainActor init(size: CGSize, labels: PanelLayoutControlLabels = .localized) {
        isVertical = size.width < 120 && size.height > size.width
        let main = isVertical ? size.height : size.width
        let cross = isVertical ? size.width : size.height
        let expandedSide = min(32, floor((main - 8 - 16) / 3), cross - 8)
        // Do not shrink three controls into tiny targets. A single centered menu
        // leaves a continuous drag area around compact tiles without resizing them.
        isCompact = expandedSide < 24
        buttonSide = isCompact ? max(0, min(24, size.width, size.height)) : expandedSide
        let labeledWidths = labels.widths.map { $0 + 16 + 5 + 16 }
        // Leave a drag gutter on both sides; long translations fall back to icons.
        showsLabels = !isVertical && !isCompact && labels.titles.count == 3
            && labeledWidths.reduce(0, +) + 16 <= size.width - 40
        buttonWidths = showsLabels ? labeledWidths : Array(repeating: buttonSide, count: isCompact ? 1 : 3)
    }

    var controlCount: Int { buttonWidths.count }

    var size: CGSize {
        let length = buttonWidths.reduce(0, +) + spacing * CGFloat(controlCount - 1)
        return isVertical ? CGSize(width: buttonSide, height: length) : CGSize(width: length, height: buttonSide)
    }

    func buttonFrame(at index: Int, rightToLeft: Bool = false) -> CGRect {
        let offset = buttonWidths.prefix(index).reduce(0, +) + CGFloat(index) * spacing
        let width = buttonWidths[index]
        let origin = isVertical ? CGPoint(x: 0, y: offset) : CGPoint(x: offset, y: 0)
        return CGRect(x: rightToLeft ? size.width - origin.x - width : origin.x,
                      y: origin.y, width: width, height: buttonSide)
    }

    func frame(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
               width: size.width, height: size.height)
    }

    func buttonFrames(in bounds: CGRect, rightToLeft: Bool) -> [CGRect] {
        let origin = frame(in: bounds).origin
        return (0..<controlCount).map {
            buttonFrame(at: $0, rightToLeft: rightToLeft).offsetBy(dx: origin.x, dy: origin.y)
        }
    }
}

struct PanelLayoutControls: Layout {
    let metrics: PanelLayoutItemControlsLayout
    let rightToLeft: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { metrics.size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            let frame = metrics.buttonFrame(at: index, rightToLeft: rightToLeft)
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

/// Keep edit actions readable above arbitrary plugin content and custom themes.
struct PanelLayoutControlsBackground: View {
    @Environment(\.menuBarPanelTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(reduceTransparency || contrast == .increased
                ? AnyShapeStyle(theme.surfaces.panel) : AnyShapeStyle(.regularMaterial))
            .overlay {
                // Shield the actions from live text without filtering the plugin view.
                RoundedRectangle(cornerRadius: 8).fill(theme.surfaces.panel.opacity(0.97))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8).fill(theme.surfaces.control)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.text.secondary.opacity(contrast == .increased ? 0.8 : 0.38), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
    }
}
