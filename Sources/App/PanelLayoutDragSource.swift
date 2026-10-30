import AppKit
import SwiftUI
import MacToolsPluginKit

/// Native source completion owns cancellation; SwiftUI's destination owns commit.
struct PanelLayoutDragSource: NSViewRepresentable {
    let id: String
    let title: String
    let icon: String
    let showsControls: Bool
    let isDraggable: Bool
    let rightToLeft: Bool
    let hover: PanelLayoutHoverState
    let nativeSource: PanelLayoutNativeDragSource
    let begin: () -> String?
    let end: (String) -> Void

    func makeNSView(context: Context) -> PanelLayoutDragSourceView {
        let view = PanelLayoutDragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PanelLayoutDragSourceView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier("panel.layout.drag.\(id)")
        view.title = title
        view.icon = icon
        view.toolTip = FeatureL10n.string("拖移以移动")
        view.controlLabels = .localized
        view.showsControls = showsControls
        view.isDraggable = isDraggable
        view.rightToLeft = rightToLeft
        view.hover = hover
        view.nativeSource = nativeSource
        hover.register(view, id: id)
        view.onBegin = begin
        view.onEnd = end
    }

    static func dismantleNSView(_ view: PanelLayoutDragSourceView, coordinator: ()) {
        view.hover?.unregister(view)
    }
}

@MainActor
final class PanelLayoutDragSourceView: NSView {
    var title = ""
    var icon = ""
    var showsControls = false {
        didSet {
            if showsControls != oldValue { updateTrackingAreas() }
        }
    }
    var isDraggable = true
    var rightToLeft = false {
        didSet { if rightToLeft != oldValue { updateTrackingAreas() } }
    }
    var controlLabels: PanelLayoutControlLabels = .localized {
        didSet { if controlLabels != oldValue { updateTrackingAreas() } }
    }
    private(set) var controlFrames: [CGRect] = []
    weak var hover: PanelLayoutHoverState?
    var onBegin: (() -> String?)?
    var onEnd: ((String) -> Void)?
    weak var nativeSource: PanelLayoutNativeDragSource?
    private var mouseDownPoint: CGPoint?
    private var cursorTrackingAreas: [NSTrackingArea] = []
    private struct TrackingGeometry: Equatable {
        let bounds: CGRect
        let visibleBounds: CGRect
        let showsControls: Bool
        let rightToLeft: Bool
        let labels: PanelLayoutControlLabels
    }
    private var trackingGeometry: TrackingGeometry?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), !(showsControls && controlFrames.contains { $0.contains(local) }) else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let visibleBounds = bounds.intersection(visibleRect)
        let next = TrackingGeometry(bounds: bounds, visibleBounds: visibleBounds,
                                    showsControls: showsControls, rightToLeft: rightToLeft, labels: controlLabels)
        guard next != trackingGeometry else { return }
        trackingGeometry = next
        controlFrames = PanelLayoutItemControlsLayout(size: bounds.size, labels: controlLabels)
            .buttonFrames(in: bounds, rightToLeft: rightToLeft)
        cursorTrackingAreas.forEach(removeTrackingArea)
        cursorTrackingAreas.removeAll(keepingCapacity: true)
        // Track actual controls, not their bounding box: toolbar gaps remain draggable.
        let regions = showsControls
            ? [visibleBounds] + controlFrames.map { $0.intersection(visibleBounds) } : [visibleBounds]
        for rect in regions where !rect.isEmpty && !rect.isNull {
            let area = NSTrackingArea(rect: rect, options: [.cursorUpdate, .activeInKeyWindow],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            cursorTrackingAreas.append(area)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.intersection(visibleRect).contains(point) else {
            super.cursorUpdate(with: event)
            return
        }
        if isDraggable && !(showsControls && controlFrames.contains { $0.contains(point) }) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func layout() {
        super.layout()
        updateTrackingAreas()
        hover?.trackingView?.scheduleRefresh()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggable, let nativeSource, !nativeSource.isDragging, let start = mouseDownPoint,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        let verticalAnchor = min(1, max(0, convert(start, from: nil).y / max(1, bounds.height)))
        guard let token = onBegin?() else { return }
        mouseDownPoint = nil
        // Capture this gesture's callback. SwiftUI may update or remove the source
        // view after a commit, and a late source callback must not end a newer drag.
        let end = onEnd
        nativeSource.begin(verticalAnchorFraction: verticalAnchor) { end?(token) }
        let item = NSDraggingItem(pasteboardWriter: PanelLayoutDragTransfer.pasteboardItem(token: token))
        // AppKit also tracks the initiating view. Keep it attached when a tab
        // switch removes the original card, independently of the source delegate.
        let dragView = window?.contentView ?? self
        let point = dragView.convert(event.locationInWindow, from: nil)
        let image = draggingImage()
        item.setDraggingFrame(CGRect(x: point.x - 18, y: point.y - 18,
                                     width: image.size.width, height: image.size.height), contents: image)
        let draggingSession = dragView.beginDraggingSession(with: [item], event: event, source: nativeSource)
        draggingSession.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    private func draggingImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 200, height: 36))
        image.lockFocus()
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: CGRect(origin: .zero, size: image.size), xRadius: 8, yRadius: 8).fill()
        NSImage(systemSymbolName: PluginSystemImage.resolvedName(icon), accessibilityDescription: nil)?
            .draw(in: CGRect(x: 10, y: 10, width: 16, height: 16))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: CGRect(x: 34, y: 9, width: 156, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        image.unlockFocus()
        return image
    }
}

/// The panel owns the native source, so replacing a tab's content cannot end its drag.
@MainActor
final class PanelLayoutNativeDragSource: NSObject, NSDraggingSource {
    private var completion: (() -> Void)?
    var isDragging: Bool { completion != nil }
    private(set) var verticalAnchorFraction: CGFloat?

    func begin(verticalAnchorFraction: CGFloat? = nil, completion: @escaping () -> Void) {
        self.verticalAnchorFraction = verticalAnchorFraction
        self.completion = completion
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        finish()
    }

    func finish() {
        let end = completion
        completion = nil
        verticalAnchorFraction = nil
        end?()
    }
}
