import SwiftUI

/// Keeps drill-in controls in the visible popup while retaining the list and its anchors.
struct PanelInlineDetailViewport {
    let coordinateSpace: UUID
    let height: CGFloat
}

private struct PanelInlineDetailViewportKey: EnvironmentKey {
    static let defaultValue: PanelInlineDetailViewport? = nil
}

extension EnvironmentValues {
    var panelInlineDetailViewport: PanelInlineDetailViewport? {
        get { self[PanelInlineDetailViewportKey.self] }
        set { self[PanelInlineDetailViewportKey.self] = newValue }
    }
}

struct PanelInlineDetailContainer<Content: View>: View {
    @Environment(\.panelInlineDetailViewport) private var viewport
    let fallbackHeight: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        if let viewport {
            GeometryReader { geometry in
                content(viewport.height)
                    .frame(width: geometry.size.width, height: viewport.height, alignment: .topLeading)
                    // Measure the stationary document container, not the offset detail,
                    // so scrolling cannot feed its presentation back into layout.
                    .offset(y: -geometry.frame(in: .named(viewport.coordinateSpace)).minY)
            }
        } else {
            content(fallbackHeight)
        }
    }
}
