import AppKit
import SwiftUI

struct PanelItemFrame: Identifiable, Equatable {
    let id: String
    let frame: CGRect
}

@MainActor
final class PanelViewportState: ObservableObject {
    @Published private(set) var visibleIDs: Set<String>?
    private(set) var rect: CGRect?

    static func visibleIDs(in rect: CGRect, frames: [PanelItemFrame]) -> Set<String> {
        let overscan = rect.insetBy(dx: 0, dy: -rect.height / 2)
        return Set(frames.lazy.filter { $0.frame.intersects(overscan) }.map(\.id))
    }

    static func clampedViewport(_ rect: CGRect, contentHeight: CGFloat) -> CGRect {
        var rect = rect
        rect.origin.y = min(max(0, rect.minY), max(0, contentHeight - rect.height))
        return rect
    }

    func update(rect: CGRect, frames: [PanelItemFrame]) {
        self.rect = rect
        let ids = Self.visibleIDs(in: rect, frames: frames)
        if visibleIDs != ids { visibleIDs = ids }
    }
}

/// Preserve packing and the full scroll document while mounting nearby views.
/// Observe AppKit's viewport so native drag scrolling and bottom-following use
/// exactly the same visibility as wheel/trackpad scrolling.
struct PanelViewportStack<Content: View>: View {
    let frames: [PanelItemFrame]
    let width: CGFloat
    let height: CGFloat
    var retainedIDs: Set<String> = []
    @ViewBuilder var content: (String) -> Content
    @StateObject private var viewport = PanelViewportState()
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        // Bootstrap at most a screenful before the native clip view is attached.
        let initialRect = CGRect(x: 0, y: 0, width: width, height: NSScreen.main?.visibleFrame.height ?? 800)
        // Re-evaluate new geometry immediately, even before the reader's next
        // layout notification, so additions never leave a transient empty frame.
        let rect = PanelViewportState.clampedViewport(viewport.rect ?? initialRect, contentHeight: height)
        let ids = PanelViewportState.visibleIDs(in: rect, frames: frames)
        ZStack(alignment: .topLeading) {
            ForEach(frames.filter { ids.contains($0.id) || retainedIDs.contains($0.id) }) { item in
                content(item.id)
                    .environment(\.layoutDirection, layoutDirection)
                    .environment(\.menuBarPanelSurfaceWidth, item.frame.width)
                    .frame(width: item.frame.width, height: item.frame.height)
                    .offset(x: layoutDirection == .rightToLeft ? width - item.frame.maxX : item.frame.minX,
                            y: item.frame.minY)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(PanelViewportReader(frames: frames, state: viewport).allowsHitTesting(false))
        .environment(\.layoutDirection, .leftToRight)
    }
}

private struct PanelViewportReader: NSViewRepresentable {
    let frames: [PanelItemFrame]
    let state: PanelViewportState

    func makeNSView(context: Context) -> PanelViewportView { PanelViewportView() }
    func updateNSView(_ view: PanelViewportView, context: Context) {
        view.frames = frames
        view.state = state
        view.scheduleRefresh()
    }
    static func dismantleNSView(_ view: PanelViewportView, coordinator: ()) { view.disconnect() }
}

private final class PanelViewportView: NSView {
    var frames: [PanelItemFrame] = []
    weak var state: PanelViewportState?
    private weak var clip: NSClipView?
    private var scheduled = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeClip()
        scheduleRefresh()
    }
    override func layout() {
        super.layout()
        observeClip()
        scheduleRefresh()
    }
    private func observeClip() {
        let next = window == nil ? nil : enclosingScrollView?.contentView
        guard next !== clip else { return }
        NotificationCenter.default.removeObserver(self)
        clip = next
        if let next {
            next.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipChanged),
                name: NSView.boundsDidChangeNotification, object: next)
        }
    }
    @objc private func clipChanged() { scheduleRefresh() }
    func scheduleRefresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard self.window != nil else { return }
            let rect = self.clip.map { self.convert($0.bounds, from: $0) } ?? self.visibleRect
            self.state?.update(rect: rect, frames: self.frames)
        }
    }
    func disconnect() {
        NotificationCenter.default.removeObserver(self)
        clip = nil
        state = nil
    }
}
