import AppKit
import SwiftUI

/// One owner controls every editing overlay, including keyboard navigation.
@MainActor
final class PanelLayoutHoverState: ObservableObject {
    @Published private(set) var activeItemID: String?
    private var hoveredItemID: String?
    private(set) var focusedItemID: String?
    private var isDragging = false
    private var itemStates: [String: PanelLayoutItemHoverState] = [:]
    private let items = NSMapTable<NSView, NSString>.weakToStrongObjects()
    weak var trackingView: PanelLayoutHoverTrackingView?

    /// Keep one stable subscription per entry through layout changes.
    func state(for id: String) -> PanelLayoutItemHoverState {
        if let state = itemStates[id] { return state }
        let state = PanelLayoutItemHoverState(isActive: activeItemID == id)
        itemStates[id] = state
        return state
    }

    func register(_ view: NSView, id: String) {
        guard items.object(forKey: view) as String? != id else { return }
        items.setObject(id as NSString, forKey: view)
        trackingView?.scheduleRefresh()
    }

    func unregister(_ view: NSView) {
        if items.object(forKey: view) as String? == focusedItemID { focusedItemID = nil }
        items.removeObject(forKey: view)
        trackingView?.scheduleRefresh()
    }

    func updatePointer(at point: CGPoint?, in region: NSView) {
        guard !isDragging else { return }
        var target: String?
        if let point, let window = region.window,
           region.bounds.contains(region.convert(point, from: nil)),
           region.visibleRect.contains(region.convert(point, from: nil)) {
            let views = items.keyEnumerator()
            while let view = views.nextObject() as? NSView {
                guard view.window === window, !view.isHiddenOrHasHiddenAncestor,
                      view.bounds.contains(view.convert(point, from: nil)),
                      view.visibleRect.contains(view.convert(point, from: nil)) else { continue }
                target = items.object(forKey: view) as String?
                break
            }
        }
        hoveredItemID = target
        updateOwner()
    }

    func focusChanged(id: String, isFocused: Bool) {
        if isFocused { focusedItemID = id }
        else if focusedItemID == id { focusedItemID = nil }
        updateOwner()
    }

    func setDragging(_ dragging: Bool) {
        isDragging = dragging
        if dragging { hoveredItemID = nil }
        updateOwner()
        if !dragging { trackingView?.scheduleRefresh() }
    }

    private func updateOwner() {
        let owner = isDragging ? nil : hoveredItemID ?? focusedItemID
        guard activeItemID != owner else { return }
        if let previous = activeItemID { itemStates[previous]?.isActive = false }
        activeItemID = owner
        if let owner { itemStates[owner]?.isActive = true }
    }
}

/// Only the departing and arriving cards redraw when the pointer changes owners.
@MainActor
final class PanelLayoutItemHoverState: ObservableObject {
    @Published fileprivate(set) var isActive: Bool

    fileprivate init(isActive: Bool) { self.isActive = isActive }
}

/// Track the document's visible region, not individual moving cards. Clip-view
/// notifications also refresh the hit test when the pointer stays still during scrolling.
@MainActor
final class PanelLayoutHoverTrackingView: NSView {
    weak var hover: PanelLayoutHoverState?
    var onLayout: ((PanelLayoutHoverTrackingView) -> Void)?
    var pointerLocationInWindow: (NSWindow) -> CGPoint = { $0.mouseLocationOutsideOfEventStream }
    private weak var observedClip: NSClipView?
    private var trackingArea: NSTrackingArea?
    private var refreshScheduled = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeClipView()
        scheduleRefresh()
    }

    override func layout() {
        super.layout()
        observeClipView()
        scheduleRefresh()
        onLayout?(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        observeClipView()
        scheduleRefresh()
    }

    override func mouseEntered(with event: NSEvent) { refresh(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { refresh(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { refresh(at: event.locationInWindow) }

    private func observeClipView() {
        let clip = window == nil ? nil : enclosingScrollView?.contentView
        guard observedClip !== clip else { return }
        if let observedClip {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClip)
        }
        observedClip = clip
        if let clip {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @objc private func clipBoundsChanged() { scheduleRefresh() }

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Coalesce layout notifications and publish after SwiftUI has finished
        // updating the native frames. There is no timer or per-card hover history.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        refresh(at: window.flatMap { $0.isVisible ? pointerLocationInWindow($0) : nil })
    }

    private func refresh(at point: CGPoint?) {
        hover?.updatePointer(at: point, in: self)
    }
}
