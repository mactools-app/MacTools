import AppKit
import MacToolsPluginKit

@MainActor
final class OverlayWindow: NSPanel {
    var onComplete: ((Data, SaveMode) -> Void)?
    var onPin: ((Data, NSRect, Bool) -> Void)?
    var onRecord: ((NSRect) -> Void)?
    var onScroll: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    init(screen: NSScreen, environment: ScreenshotEnvironment) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isOpaque = true
        // The native backing must also be opaque so screen-edge clicks cannot pass through.
        backgroundColor = .black
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        // Full-display panels must not use AppKit's inferred ordering animation.
        animationBehavior = .none
        hidesOnDeactivate = false
        sharingType = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // Reused panels must be able to join other applications' full-screen Spaces.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary]
        // Set the final level after panel flags; isFloatingPanel resets it to .floating.
        level = .screenSaver

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size),
                               environment: environment)
        contentView = view
        setFrame(screen.frame, display: false)
        view.layoutSubtreeIfNeeded()
    }

    convenience init(screen: NSScreen, frozen: CGImage, windows: [NSRect], quick: Bool, environment: ScreenshotEnvironment) {
        self.init(screen: screen, environment: environment)
        prepare(screen: screen, frozen: frozen, windows: windows, quick: quick)
    }

    func prepare(screen: NSScreen, frozen: CGImage, windows: [NSRect], quick: Bool) {
        guard let view = contentView as? OverlayView else { return }
        setFrame(screen.frame, display: false)
        colorSpace = frozen.colorSpace.flatMap(NSColorSpace.init(cgColorSpace:)) ?? screen.colorSpace
        let obscuredArea: NSRect?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           !left.isEmpty, !right.isEmpty, right.minX > left.maxX {
            obscuredArea = NSRect(x: left.maxX - screen.frame.minX,
                                  y: min(left.minY, right.minY) - screen.frame.minY,
                                  width: right.minX - left.maxX,
                                  height: max(left.height, right.height))
        } else {
            obscuredArea = nil
        }
        view.prepare(frozen: frozen, windows: windows, quick: quick, topObscuredArea: obscuredArea)
        view.onComplete = { [weak self] png, mode in self?.onComplete?(png, mode) }
        view.onPin = { [weak self] png, rect, shadowed in
            guard let self else { return }
            self.onPin?(png, self.convertToScreen(rect), shadowed)
        }
        view.onRecord = { [weak self] rect in self?.onRecord?(rect) }
        view.onScroll = { [weak self] rect in self?.onScroll?(rect) }
        view.onCancel = { [weak self] in self?.onCancel?() }
        makeFirstResponder(view)
    }

    /// Finish layout and drawing while hidden, before the coordinator orders any display.
    func prepareForPresentation() {
        (contentView as? OverlayView)?.prepareForPresentation()
        contentView?.layoutSubtreeIfNeeded()
        contentView?.displayIfNeeded()
        displayIfNeeded()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Text editors work without replacing the host application's Edit menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let editor = firstResponder as? NSTextView else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command {
            switch key {
            case "a": editor.selectAll(nil)
            case "c": editor.copy(nil)
            case "x": editor.cut(nil)
            case "v": editor.paste(nil)
            case "z": editor.undoManager?.undo()
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        if modifiers == [.command, .shift], key == "z" {
            editor.undoManager?.redo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func dismiss() {
        orderOut(nil)
        makeFirstResponder(nil)
        (contentView as? OverlayView)?.stop()
        onComplete = nil
        onPin = nil
        onRecord = nil
        onScroll = nil
        onCancel = nil
    }

    override func close() {
        (contentView as? OverlayView)?.stop()
        super.close()
    }
}

private enum Tool: Int {
    case none, rect, ellipse, line, arrow, pen, text, tag, mosaic, blur

    var usesStroke: Bool { self != .none && self != .mosaic && self != .blur }
}

private enum Mode: Int { case shot = 0, ocr = 1, scroll = 2, record = 3 }

private enum Edge { case min, mid, max }

private let handleSpots: [(x: Edge, y: Edge)] = [
    (.min, .min), (.mid, .min), (.max, .min),
    (.min, .mid),               (.max, .mid),
    (.min, .max), (.mid, .max), (.max, .max),
]

private enum Drag {
    case select
    case move
    case resize(Int)
    case draw
}

enum MagnifierColorFormat: Equatable {
    case rgb
    case hex

    mutating func toggle() {
        self = self == .rgb ? .hex : .rgb
    }
}

struct MagnifierColorValue: Equatable {
    let red: Int
    let green: Int
    let blue: Int

    var rgb: String { "\(red), \(green), \(blue)" }
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    func value(for format: MagnifierColorFormat) -> String {
        format == .rgb ? rgb : hex
    }
}

@MainActor
final class DragHandle: NSView {
    var color: NSColor = .tertiaryLabelColor
    var onDrag: ((NSSize) -> Void)?
    private var last: NSPoint?

    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        NSAttributedString(string: "⋮⋮", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: color,
        ]).draw(at: NSPoint(x: 2, y: 5))
    }

    override func mouseDown(with event: NSEvent) { last = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let last else { return }
        let p = event.locationInWindow
        self.last = p
        onDrag?(NSSize(width: p.x - last.x, height: p.y - last.y))
    }

    override func mouseUp(with event: NSEvent) { last = nil }
}

@MainActor
final class BarButton: NSButton {
    var isSelectedLook = false { didSet { refresh() } }
    var isHovered = false { didSet { refresh() } }
    var tint: NSColor = .labelColor { didSet { refresh() } }
    var selectedUsesAccent = true
    var usesCircularBackground = false { didSet { refresh() } }
    var backgroundVerticalInset: CGFloat = 0 { didSet { refresh() } }
    private var pressed = false
    private var backgroundFill: NSColor?

    override func mouseDown(with event: NSEvent) {
        pressed = true
        refresh()
        super.mouseDown(with: event)
        pressed = false
        refresh()
    }

    override func draw(_ dirtyRect: NSRect) {
        if let backgroundFill {
            backgroundFill.setFill()
            backgroundPath.fill()
        }
        super.draw(dirtyRect)
    }

    private var backgroundPath: NSBezierPath {
        let backgroundBounds = bounds.insetBy(dx: 0, dy: backgroundVerticalInset)
        if usesCircularBackground {
            let diameter = min(backgroundBounds.width, backgroundBounds.height)
            return NSBezierPath(ovalIn: NSRect(
                x: backgroundBounds.midX - diameter / 2,
                y: backgroundBounds.midY - diameter / 2,
                width: diameter,
                height: diameter
            ))
        }
        return NSBezierPath(
            roundedRect: backgroundBounds,
            xRadius: backgroundBounds.height / 2,
            yRadius: backgroundBounds.height / 2
        )
    }

    func refresh() {
        let selectedFill = selectedUsesAccent ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                                              : NSColor.labelColor.withAlphaComponent(0.12)
        backgroundFill = isSelectedLook ? selectedFill
            : pressed ? NSColor.labelColor.withAlphaComponent(0.16)
            : isHovered ? NSColor.labelColor.withAlphaComponent(0.08)
            : nil
        let color: NSColor = isSelectedLook && selectedUsesAccent ? .controlAccentColor : tint
        contentTintColor = color
        if image == nil, !title.isEmpty {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: font?.pointSize ?? 13, weight: isSelectedLook ? .semibold : .medium),
                .foregroundColor: color,
            ])
        }
        needsDisplay = true
    }
}

@MainActor
final class OverlayView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    var onComplete: ((Data, SaveMode) -> Void)?
    var onPin: ((Data, NSRect, Bool) -> Void)?
    var onRecord: ((NSRect) -> Void)?
    var onScroll: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    var onPointerActivity: (() -> Void)?

    private var cgImage: CGImage?
    private var scale: CGFloat = 1
    private var renderer: AnnotationRenderer?
    private var exportTask: Task<Void, Never>?
    private var backdrop: CaptureBackdrop?
    private var selectionChrome: CaptureSelectionChrome?
    private let annotationView = CaptureAnnotationView()
    private let sizeBadge: CaptureSizeBadge
    private let magnifier: CaptureMagnifierView
    private let environment: ScreenshotEnvironment

    private var windowRects: [NSRect] = []
    private var topObscuredArea: NSRect?
    private var quick = false
    private var tips: [NSButton: String] = [:]
    private var tipView: NSView!
    private let tipLabel = NSTextField(labelWithString: "")
    private var tipTimer: Timer?
    private weak var tipButton: NSButton?
    private var clickMonitor: Any?
    private var hoverRect: NSRect?
    private var lastMouse: NSPoint?
    private var qrRects: [NSRect] = []
    private var resultURL: URL?
    private lazy var maskButton = NSButton(title: environment.string("overlay.recognition.mask", "打码"), target: nil, action: nil)
    private lazy var openButton = NSButton(title: environment.string("overlay.recognition.open", "打开链接"), target: nil, action: nil)
    private var toolbarPinned = false
    private var cornerRadius: CGFloat
    private var radiusRow: NSView!
    private let radiusSlider = NSSlider()
    private let radiusLabel = NSTextField(labelWithString: "0")

    private var radius: CGFloat { mode == .shot ? min(cornerRadius, min(selection.width, selection.height) / 2) : 0 }

    private var shadowSize: CGFloat
    private var shadowColorIndex: Int
    private let shadowSlider = NSSlider()
    private let shadowLabel = NSTextField(labelWithString: "0")
    private var shadowButtons: [BarButton] = []
    private var shadowBlur: CGFloat { mode == .shot ? shadowSize : 0 }
    private var shadowColor: NSColor { Self.palette[min(max(shadowColorIndex, 0), Self.palette.count - 1)] }
    private var shadowMargin: CGFloat { AnnotationRenderer.shadowMargin(for: shadowBlur) }

    private var selection: NSRect = .zero {
        didSet {
            guard selection != oldValue else { return }
            recognition.cancel()
            qrRects = []
            resultURL = nil
        }
    }
    private var editing = false
    private var tool: Tool = .none
    private var stroke = Stroke(color: .systemRed, width: 2)
    private var items: [Item] = []

    private var anchor: NSPoint?
    private var dragMode: Drag?
    private var origSelection: NSRect = .zero
    private var draft: Item?
    private var penPoints: [NSPoint] = []
    private var textField: NSTextField?

    private var modeBar: NSView!
    private var modeBarSize = NSSize.zero
    private var modeBarPreferredX: CGFloat?
    private var modeButtons: [BarButton] = []
    private static let segmentModes: [Mode] = [.shot, .scroll, .record, .ocr]
    private let toolbar = NSStackView()
    private var styleRow: NSView!
    private var toolButtons: [BarButton] = []
    private var colorButtons: [BarButton] = []
    private var widthButtons: [BarButton] = []
    private var mode: Mode = .shot
    private var recordBar: NSView!
    private var scrollBar: NSView!
    private var ocrPanel: NSView?
    private var ocrTextView: NSTextView?
    private var ocrScrollWidth: NSLayoutConstraint?
    private var ocrScrollHeight: NSLayoutConstraint?
    private lazy var ocrTitle = NSTextField(labelWithString: environment.string("overlay.recognition.text", "提取文字"))
    private let ocrStatus = NSTextField(labelWithString: "")
    private let ocrSpinner = NSProgressIndicator()
    private let recognition = RecognitionSession()
    private var recognitionKind: RecognitionKind?
    private var ocrShowing: Bool { recognitionKind != nil }
    private var pointerInside = false
    private var magnifierColorFormat: MagnifierColorFormat = .rgb

    private static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                             .systemBlue, .systemPurple, .black, .white]
    private var paletteNames: [String] {
        [environment.string("overlay.color.red", "红色"), environment.string("overlay.color.orange", "橙色"),
         environment.string("overlay.color.yellow", "黄色"), environment.string("overlay.color.green", "绿色"),
         environment.string("overlay.color.blue", "蓝色"), environment.string("overlay.color.purple", "紫色"),
         environment.string("overlay.color.black", "黑色"), environment.string("overlay.color.white", "白色")]
    }
    private static let widths: [CGFloat] = [2, 4, 6]
    private weak var hoverButton: BarButton?

    init(frame: NSRect, environment: ScreenshotEnvironment) {
        self.environment = environment
        sizeBadge = CaptureSizeBadge(environment: environment)
        magnifier = CaptureMagnifierView(environment: environment)
        cornerRadius = min(80, max(0, CGFloat((environment.storage.object(forKey: "cornerRadius") as? NSNumber)?.doubleValue ?? 0)))
        shadowSize = min(60, max(0, CGFloat((environment.storage.object(forKey: "shadowSize") as? NSNumber)?.doubleValue ?? 0)))
        shadowColorIndex = environment.storage.object(forKey: "shadowColor") == nil
            ? 6 : environment.storage.integer(forKey: "shadowColor")
        super.init(frame: frame)
        wantsLayer = true
        if let layer {
            backdrop = CaptureBackdrop(parent: layer)
            selectionChrome = CaptureSelectionChrome(parent: layer)
        }
        annotationView.frame = bounds
        annotationView.autoresizingMask = [.width, .height]
        annotationView.wantsLayer = true
        annotationView.drawContent = { [weak self] dirtyRect in self?.drawAnnotations(in: dirtyRect) }
        addSubview(annotationView)
        addSubview(sizeBadge)
        addSubview(magnifier)
        buildModeBar()
        buildToolbar()
        buildRecordBar()
        buildScrollBar()
        buildTip()
    }

    func prepare(frozen image: CGImage, windows: [NSRect], quick: Bool, topObscuredArea: NSRect? = nil) {
        stop()
        cgImage = image
        scale = CGFloat(image.width) / bounds.width
        renderer = AnnotationRenderer(image: image, scale: scale, size: bounds.size)
        magnifier.prepare(image: image, size: bounds.size)
        sizeBadge.prepare()
        windowRects = windows.map { $0.intersection(bounds) }
        self.topObscuredArea = topObscuredArea
        self.quick = quick
        cornerRadius = min(80, max(0, CGFloat((environment.storage.object(forKey: "cornerRadius") as? NSNumber)?.doubleValue ?? 0)))
        shadowSize = min(60, max(0, CGFloat((environment.storage.object(forKey: "shadowSize") as? NSNumber)?.doubleValue ?? 0)))
        shadowColorIndex = environment.storage.object(forKey: "shadowColor") == nil
            ? 6 : environment.storage.integer(forKey: "shadowColor")
        radiusSlider.doubleValue = Double(cornerRadius)
        radiusLabel.stringValue = "\(Int(cornerRadius))"
        shadowSlider.doubleValue = Double(shadowSize)
        shadowLabel.stringValue = "\(Int(shadowSize))"
        radiusRow.isHidden = cornerRadius == 0 && shadowSize == 0
        refreshShadowButtons()
        refreshStyleButtons()
        for button in modeButtons { button.isSelectedLook = button.tag == 0 }
        for button in toolButtons { button.isSelectedLook = false }
        backdrop?.prepare(image: image, bounds: bounds, scale: scale)
        updateTrackingAreas()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.hideTip()
            return event
        }
        invalidateAnnotations()
    }

    func prepareForPresentation() {
        updateSelectionPresentation()
    }

    /// Remove session state while keeping the native controls available for reuse.
    func stop() {
        exportTask?.cancel()
        exportTask = nil
        cancelRecognition()
        hideTip()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        trackingAreas.forEach(removeTrackingArea)
        ocrSpinner.stopAnimation(nil)
        textField?.delegate = nil
        textField?.removeFromSuperview()
        textField = nil
        ocrTextView?.string = ""
        ocrStatus.stringValue = ""
        ocrPanel?.isHidden = true
        [modeBar, recordBar, scrollBar, tipView].forEach { $0?.isHidden = true }
        toolbar.isHidden = true
        styleRow.isHidden = true
        setHover(nil)
        tipButton = nil
        pointerInside = false
        hoverRect = nil
        lastMouse = nil
        anchor = nil
        dragMode = nil
        origSelection = .zero
        draft = nil
        penPoints.removeAll()
        selection = .zero
        items.removeAll()
        editing = false
        toolbarPinned = false
        modeBarPreferredX = nil
        topObscuredArea = nil
        tool = .none
        mode = .shot
        magnifierColorFormat = .rgb
        stroke = Stroke(color: .systemRed, width: 2)
        windowRects.removeAll()
        renderer = nil
        cgImage = nil
        backdrop?.clear()
        selectionChrome?.clear()
        sizeBadge.isHidden = true
        magnifier.clear()
        annotationView.needsDisplay = true
        annotationView.displayIfNeeded()
        onComplete = nil
        onPin = nil
        onRecord = nil
        onScroll = nil
        onCancel = nil
        onPointerActivity = nil
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func invalidate(_ rects: NSRect...) {
        updateSelectionPresentation()
        for r in rects where !r.isEmpty { annotationView.setNeedsDisplay(r.insetBy(dx: -2, dy: -2)) }
    }

    private func invalidateAnnotations() {
        updateSelectionPresentation()
        annotationView.needsDisplay = true
    }

    private func updateSelectionPresentation() {
        guard cgImage != nil else { return }
        // AppKit may invalidate transparent siblings when chrome moves. Keep the
        // annotation surface out of drawing until there are handles or marks.
        annotationView.isHidden = !editing && items.isEmpty && draft == nil
        let hole = selection.isEmpty ? (pointerInside ? hoverRect : nil) : selection
        backdrop?.update(bounds: bounds, selection: hole, radius: selection.isEmpty ? 0 : radius)
        selectionChrome?.update(bounds: bounds, selection: hole, radius: selection.isEmpty ? 0 : radius,
                                shadowSize: selection.isEmpty ? 0 : shadowBlur, shadowColor: shadowColor,
                                scale: window?.backingScaleFactor ?? 1)
        sizeBadge.update(selection: hole, radius: selection.isEmpty ? 0 : radius,
                         shadowSize: selection.isEmpty ? 0 : shadowBlur, in: bounds)
        updateMagnifier()
    }

    private func updateMagnifier() {
        magnifier.update(at: pointerInside && !editing ? lastMouse : nil,
                         format: magnifierColorFormat, in: bounds)
    }

    private var selectionDirty: NSRect {
        selection.isEmpty ? .zero : selection.insetBy(dx: -(shadowMargin + 60), dy: -(shadowMargin + 60))
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        onPointerActivity?()
    }

    override func mouseExited(with event: NSEvent) {
        onPointerActivity?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard cgImage != nil else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways,
                                                            .inVisibleRect, .enabledDuringMouseDrag],
                                       owner: self, userInfo: nil))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard cgImage != nil else { return }
        if window == nil { updatePointer(at: nil) }
        else { onPointerActivity?() }
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerActivity?()
    }

    /// Only the session's pointer tracker supplies a location; nil clears transient hover UI.
    func updatePointer(at point: NSPoint?) {
        guard cgImage != nil else { return }
        guard let p = point, isMousePoint(p, in: bounds) else {
            setPointerInside(false)
            lastMouse = nil
            setHoverRect(nil)
            updateMagnifier()
            setHover(nil)
            tipButton = nil
            hideTip()
            return
        }
        let wasInside = pointerInside
        setPointerInside(true)
        guard dragMode == nil, !wasInside || lastMouse != p else { return }
        lastMouse = p
        updateHover(at: p)
        updateMagnifier()
        cursor(at: p).set()
        trackTip(at: p)
    }

    private func buildTip() {
        tipLabel.font = PluginTypography.control.nsFont
        tipLabel.textColor = .labelColor
        let box = NSStackView(views: [tipLabel])
        box.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        tipView = Glass.wrap(box, radius: 6)
        tipView.isHidden = true
        addSubview(tipView)
    }

    private func trackTip(at p: NSPoint) {
        let hit = toolbar.hitTest(p) ?? modeBar.hitTest(p)
        let button = hit as? BarButton ?? hit?.superview as? BarButton
        setHover(button)
        guard button !== tipButton else { return }
        tipButton = button
        hideTip()
        guard let button, let text = tips[button] else { return }
        tipTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self, weak button] _ in
            MainActor.assumeIsolated {
                guard let self, let button else { return }
                self.showTip(text, above: button)
            }
        }
    }

    private func hideTip() {
        tipTimer?.invalidate()
        tipTimer = nil
        tipView.isHidden = true
    }

    private func setHover(_ button: BarButton?) {
        guard button !== hoverButton else { return }
        hoverButton?.isHovered = false
        hoverButton = button
        if let button, button.isEnabled { button.isHovered = true }
    }

    private func showTip(_ text: String, above button: NSButton) {
        tipLabel.stringValue = text
        tipView.layoutSubtreeIfNeeded()
        let size = tipView.fittingSize
        let anchor = button.convert(button.bounds, to: self)
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 8)
        if origin.y + size.height > bounds.maxY { origin.y = anchor.minY - 8 - size.height }
        origin.x = min(max(4, origin.x), bounds.maxX - size.width - 4)
        tipView.frame = NSRect(origin: origin, size: size)
        tipView.alphaValue = 0
        tipView.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            tipView.animator().alphaValue = 1
        }
    }

    private func updateHover(at p: NSPoint) {
        guard pointerInside, !editing else { return }
        setHoverRect(Self.hoverTarget(at: p, in: bounds, windowRects: windowRects))
    }

    static func hoverTarget(at point: NSPoint, in bounds: NSRect, windowRects: [NSRect]) -> NSRect? {
        guard NSMouseInRect(point, bounds, false) else { return nil }
        return windowRects.first { NSMouseInRect(point, $0, false) } ?? bounds
    }

    private func setHoverRect(_ rect: NSRect?) {
        guard rect != hoverRect else { return }
        hoverRect = rect
        updateSelectionPresentation()
    }

    private func setPointerInside(_ isInside: Bool) {
        guard pointerInside != isInside else { return }
        pointerInside = isInside
        if modeBar != nil { placeModeBar() }
    }

    private func cursor(at p: NSPoint) -> NSCursor {
        let bars: [NSView] = [modeBar, toolbar, recordBar, scrollBar] + (ocrPanel.map { [$0] } ?? [])
        if bars.contains(where: { !$0.isHidden && $0.frame.contains(p) }) { return .arrow }
        guard editing, tool == .none else { return .crosshair }
        if let i = handleIndex(at: p) { return resizeCursor(for: handleSpots[i]) }
        return selection.contains(p) ? .openHand : .crosshair
    }

    private func resizeCursor(for handle: (x: Edge, y: Edge)) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch (handle.x, handle.y) {
            case (.min, .max): position = .topLeft
            case (.mid, .max): position = .top
            case (.max, .max): position = .topRight
            case (.min, .mid): position = .left
            case (.max, .mid): position = .right
            case (.min, .min): position = .bottomLeft
            case (.mid, .min): position = .bottom
            default:           position = .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        if handle.x == .mid { return .resizeUpDown }
        if handle.y == .mid { return .resizeLeftRight }
        return .crosshair
    }

    private func drawAnnotations(in dirtyRect: NSRect) {
        guard cgImage != nil, !selection.isEmpty else { return }
        if selection.intersects(dirtyRect), !items.isEmpty || draft != nil {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: selection, xRadius: radius, yRadius: radius).setClip()
            drawItems()
            NSGraphicsContext.restoreGraphicsState()
        }
        if editing, tool == .none, selectionDirty.intersects(dirtyRect) { drawHandles() }
    }

    private func pixelColor(at point: NSPoint) -> MagnifierColorValue? {
        magnifier.color(at: point)
    }

    private func drawHandles() {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        for p in handlePoints() {
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.white.setFill()
            dot.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            dot.lineWidth = 0.5
            dot.stroke()
        }
    }

    private func drawItems() {
        renderer?.drawItems(items, draft: draft, selection: selection)
    }

    private func cropFrozen(_ rect: NSRect) -> (CGImage, NSRect)? {
        renderer?.crop(rect, selection: selection)
    }

    private func render(completion: @escaping (Data) -> Void) {
        guard exportTask == nil else { return }
        guard let raster = renderer?.render(selection: selection, items: items, draft: draft, radius: radius,
                                            shadowSize: shadowBlur, shadowColor: shadowColor) else {
            environment.showToast(environment.string("overlay.export.failed", "截图导出失败"))
            return
        }
        exportTask = Task { [weak self] in
            do {
                let png = try await ScreenshotImageEncoder.png(raster)
                guard let self, !Task.isCancelled else { return }
                exportTask = nil
                completion(png)
            } catch {
                guard let self, !Task.isCancelled else { return }
                exportTask = nil
                environment.showToast(environment.string("overlay.export.failed", "截图导出失败"))
            }
        }
    }

    private func handlePoints() -> [NSPoint] {
        handleSpots.map { NSPoint(x: coord($0.x, selection.minX, selection.maxX),
                                  y: coord($0.y, selection.minY, selection.maxY)) }
    }

    private func coord(_ edge: Edge, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        switch edge {
        case .min: return lo
        case .mid: return (lo + hi) / 2
        case .max: return hi
        }
    }

    private func handleIndex(at p: NSPoint) -> Int? {
        handlePoints().firstIndex { hypot($0.x - p.x, $0.y - p.y) <= 8 }
    }

    private func resized(_ r: NSRect, handle: (x: Edge, y: Edge), dx: CGFloat, dy: CGFloat) -> NSRect {
        var left = r.minX, right = r.maxX, bottom = r.minY, top = r.maxY
        switch handle.x {
        case .min: left += dx
        case .max: right += dx
        case .mid: break
        }
        switch handle.y {
        case .min: bottom += dy
        case .max: top += dy
        case .mid: break
        }
        return NSRect(x: min(left, right), y: min(bottom, top), width: abs(right - left), height: abs(top - bottom))
    }

    private func clamped(_ r: NSRect) -> NSRect {
        var r = r
        r.origin.x = min(max(0, r.minX), bounds.maxX - r.width)
        r.origin.y = min(max(0, r.minY), bounds.maxY - r.height)
        return r
    }

    override func mouseDown(with event: NSEvent) {
        onPointerActivity?()
        commitText()
        hideTip()
        let p = convert(event.locationInWindow, from: nil)
        lastMouse = p
        anchor = p
        origSelection = selection
        penPoints = []
        guard editing else { dragMode = .select; return }

        switch tool {
        case .none:
            if let i = handleIndex(at: p) {
                dragMode = .resize(i)
            } else if selection.contains(p) {
                dragMode = .move
                NSCursor.closedHand.set()
            } else {
                dragMode = .select
            }
        case .text:
            dragMode = nil
            placeTextField(at: p)
        case .tag:
            dragMode = nil
            let count = items.filter { if case .tag = $0.shape { return true } else { return false } }.count
            items.append(Item(shape: .tag(count + 1, at: p), stroke: stroke))
            invalidateAnnotations()
        default:
            dragMode = .draw
            if tool == .pen { penPoints = [p] }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        onPointerActivity?()
        updateDrag(at: convert(event.locationInWindow, from: nil))
    }

    private func updateDrag(at p: NSPoint) {
        guard let a = anchor, let mode = dragMode else { return }
        lastMouse = p
        let dx = p.x - a.x, dy = p.y - a.y
        let before = selectionDirty
        let hadAnnotations = editing || !items.isEmpty || draft != nil

        switch mode {
        case .draw:
            if tool == .pen {
                penPoints.append(p)
                draft = Item(shape: .pen(penPoints), stroke: stroke)
            } else if let shape = makeShape(from: a, to: p) {
                draft = Item(shape: shape, stroke: stroke)
            } else {
                draft = nil
            }
        case .move:
            selection = clamped(origSelection.offsetBy(dx: dx, dy: dy))
            layoutBars()
        case .resize(let i):
            let r = resized(origSelection, handle: handleSpots[i], dx: dx, dy: dy)
            if r.width >= 8, r.height >= 8 { selection = r }
            layoutBars()
        case .select:
            guard hypot(dx, dy) > 4 else { return }
            if editing {
                editing = false
                toolbar.isHidden = true
                recordBar.isHidden = true
                scrollBar.isHidden = true
                toolbarPinned = false
                hideOcrPanel()
                items.removeAll()
                renderer?.clearCache()
                placeModeBar()
            }
            hoverRect = nil
            selection = NSRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(dx), height: abs(dy))
        }
        if hadAnnotations || draft != nil { invalidate(before, selectionDirty) }
        else { updateSelectionPresentation() }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            anchor = nil; draft = nil; dragMode = nil
            onPointerActivity?()
        }
        let p = convert(event.locationInWindow, from: nil)
        guard let mode = dragMode else { return }
        // Event coalescing must not leave the final selection at the last drag sample.
        if lastMouse != p { updateDrag(at: p) }

        switch mode {
        case .draw:
            if let d = draft { items.append(d) }
        case .move:
            if event.clickCount == 2 { primaryAction() }
            else if ocrShowing { rerunRecognition() }
        case .resize:
            if ocrShowing { rerunRecognition() }
        case .select:
            if editing { break }
            if selection.width >= 3, selection.height >= 3 {
                confirmSelection()
            } else if let hover = hoverRect, !hover.isEmpty {
                selection = hover
                confirmSelection()
            } else {
                selection = .zero
                updateHover(at: p)
            }
        }
        // A double-click action can synchronously dismiss this overlay.
        guard cgImage != nil else { return }
        cursor(at: p).set()
        invalidateAnnotations()
    }

    private func primaryAction() {
        switch mode {
        case .shot: finish()
        case .ocr: runOCR()
        case .record: startRecord()
        case .scroll: startScroll()
        }
    }

    private func confirmSelection() {
        hoverRect = nil
        editing = true
        invalidateAnnotations()
        if quick { export(.clipboard); return }
        placeModeBar()
        switch mode {
        case .ocr: runOCR()
        case .record: place(recordBar)
        case .scroll: place(scrollBar)
        case .shot: layoutToolbar()
        }
    }

    private func layoutBars() {
        placeModeBar()
        if ocrShowing { return }
        switch mode {
        case .record: place(recordBar)
        case .scroll: place(scrollBar)
        case .shot, .ocr: layoutToolbar()
        }
    }

    private func makeShape(from a: NSPoint, to p: NSPoint) -> Shape? {
        let r = NSRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
        let big = r.width >= 2 && r.height >= 2
        let far = hypot(p.x - a.x, p.y - a.y) >= 4
        switch tool {
        case .rect:    return big ? .rect(r) : nil
        case .ellipse: return big ? .ellipse(r) : nil
        case .mosaic:  return big ? .mosaic(r) : nil
        case .blur:    return big ? .blur(r) : nil
        case .line:    return far ? .line(from: a, to: p) : nil
        case .arrow:   return far ? .arrow(from: a, to: p) : nil
        case .none, .pen, .text, .tag: return nil
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        switch event.keyCode {
        case 53: onCancel?(); return
        case 36, 76: if editing { primaryAction() }; return
        case 48:
            guard !editing, lastMouse != nil else {
                super.keyDown(with: event)
                return
            }
            magnifierColorFormat.toggle()
            updateMagnifier()
            return
        case 123, 124, 125, 126:
            guard editing else { return }
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let delta: [UInt16: (CGFloat, CGFloat)] = [123: (-step, 0), 124: (step, 0), 125: (0, -step), 126: (0, step)]
            let (dx, dy) = delta[event.keyCode]!
            selection = clamped(selection.offsetBy(dx: dx, dy: dy))
            layoutBars()
            if ocrShowing { rerunRecognition() }
            invalidateAnnotations()
            return
        default: break
        }
        if flags.contains(.command) {
            switch key {
            case "z": undoLast()
            case "s": if editing { export(flags.contains(.shift) ? .ask : .folder) }
            case "c": copy(nil)
            default: super.keyDown(with: event)
            }
            return
        }
        if editing, key == "[" { setRadius(cornerRadius - 4); return }
        if editing, key == "]" { setRadius(cornerRadius + 4); return }
        if editing, key == "{" { setShadow(shadowSize - 4); return }
        if editing, key == "}" { setShadow(shadowSize + 4); return }
        let shortcuts: [String: Tool] = ["r": .rect, "o": .ellipse, "l": .line, "a": .arrow, "p": .pen,
                                         "t": .text, "n": .tag, "m": .mosaic, "b": .blur]
        if editing, let t = shortcuts[key] { select(tool: t) } else { super.keyDown(with: event) }
    }

    private func buildModeBar() {
        let handle = DragHandle()
        handle.setAccessibilityLabel(environment.string("overlay.mode.move", "左右移动模式栏"))
        handle.onDrag = { [weak self] delta in self?.moveModeBar(by: delta.width) }
        let titles = [environment.string("overlay.mode.screenshot", "截图"),
                      environment.string("overlay.mode.scroll", "滚动截图"),
                      environment.string("overlay.mode.record", "录屏"),
                      environment.string("overlay.recognition.text", "提取文字")]
        for (i, title) in titles.enumerated() {
            let button = BarButton(title: title, target: self, action: #selector(pickMode(_:)))
            button.isBordered = false
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.selectedUsesAccent = false
            button.backgroundVerticalInset = 3
            button.tag = i
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.widthAnchor.constraint(equalToConstant: button.intrinsicContentSize.width + 28).isActive = true
            button.setAccessibilityLabel(title)
            if Self.segmentModes[i] == .record, #unavailable(macOS 15) {
                button.isEnabled = false
                let reason = environment.string("overlay.record.unavailable", "录屏需要 macOS 15 或更高版本")
                button.setAccessibilityHelp(reason)
                tips[button] = reason
            }
            button.isSelectedLook = i == 0
            modeButtons.append(button)
        }
        modeBar = capsule([handle] + modeButtons, spacing: 2, inset: 4)
        modeBar.identifier = NSUserInterfaceItemIdentifier("screenshot.modeBar")
        modeBarSize = modeBar.fittingSize
        addSubview(modeBar)
        placeModeBar()
    }

    private func placeModeBar() {
        guard Self.modeBarShouldBeVisible(quick: quick, pointerInside: pointerInside, overlapsSelection: false) else {
            modeBar.isHidden = true
            return
        }
        var frame = Self.modeBarFrame(size: modeBarSize, in: bounds,
                                      preferredX: modeBarPreferredX ?? bounds.minX + 16,
                                      obscuredArea: topObscuredArea)
        let busy = editing ? selection.insetBy(dx: -8, dy: -8) : .zero
        if busy.intersects(frame), modeBarPreferredX == nil {
            frame = Self.modeBarFrame(size: modeBarSize, in: bounds,
                                      preferredX: bounds.maxX - 16 - modeBarSize.width,
                                      obscuredArea: topObscuredArea)
        }
        modeBar.frame = frame
        modeBar.isHidden = !Self.modeBarShouldBeVisible(
            quick: quick,
            pointerInside: pointerInside,
            overlapsSelection: busy.intersects(frame)
        )
    }

    private func moveModeBar(by deltaX: CGFloat) {
        guard deltaX != 0, !modeBar.isHidden else { return }
        // Keep the unclipped horizontal preference so a single drag can cross the notch.
        let proposedX = (modeBarPreferredX ?? modeBar.frame.minX) + deltaX
        let bounded = Self.modeBarFrame(size: modeBarSize, in: bounds, preferredX: proposedX)
        modeBarPreferredX = bounded.minX
        let frame = Self.modeBarFrame(size: modeBarSize, in: bounds,
                                      preferredX: bounded.minX, obscuredArea: topObscuredArea)
        if modeBar.frame.origin != frame.origin { modeBar.setFrameOrigin(frame.origin) }
    }

    static func modeBarFrame(size: NSSize, in bounds: NSRect, preferredX: CGFloat,
                             obscuredArea: NSRect? = nil) -> NSRect {
        let inset: CGFloat = 4
        let minX = bounds.minX + inset
        let maxX = max(minX, bounds.maxX - inset - size.width)
        var frame = NSRect(x: min(max(preferredX, minX), maxX),
                           y: bounds.maxY - inset - size.height, width: size.width, height: size.height)
        if let obscuredArea, frame.intersects(obscuredArea.insetBy(dx: -inset, dy: 0)) {
            let candidates = [obscuredArea.minX - inset - size.width, obscuredArea.maxX + inset]
                .filter { $0 >= minX && $0 <= maxX }
            if let nearest = candidates.min(by: { abs($0 - frame.minX) < abs($1 - frame.minX) }) {
                frame.origin.x = nearest
            }
        }
        return frame
    }

    static func modeBarShouldBeVisible(quick: Bool, pointerInside: Bool, overlapsSelection: Bool) -> Bool {
        !quick && pointerInside && !overlapsSelection
    }

    @objc private func pickMode(_ sender: BarButton) {
        mode = Self.segmentModes[max(0, min(sender.tag, Self.segmentModes.count - 1))]
        for b in modeButtons { b.isSelectedLook = b === sender }
        guard editing else { return }
        hideOcrPanel()
        toolbar.isHidden = true
        recordBar.isHidden = true
        scrollBar.isHidden = true
        confirmSelection()
    }

    private func buildScrollBar() {
        let hint = NSTextField(labelWithString: environment.string("overlay.scroll.hint", "选择要截取的区域，开始后手动向下滚动"))
        hint.font = PluginTypography.detail.nsFont
        hint.textColor = .secondaryLabelColor
        let start = sessionButton(
            title: environment.string("overlay.scroll.start", "开始滚动截图"),
            symbol: "arrow.down.doc",
            action: #selector(startScroll),
            isPrimary: true
        )
        let cancel = sessionButton(
            title: environment.string("overlay.action.cancel", "取消"),
            action: #selector(cancel)
        )
        scrollBar = CaptureActionBar.make([hint, start, cancel])
        scrollBar.isHidden = true
        addSubview(scrollBar)
    }

    @objc private func startScroll() {
        commitText()
        onScroll?(selection)
    }

    private func buildRecordBar() {
        let start = sessionButton(
            title: environment.string("overlay.record.start", "开始录制"),
            symbol: "record.circle",
            tint: .systemRed,
            action: #selector(startRecord),
            isPrimary: true
        )
        let cancel = sessionButton(
            title: environment.string("overlay.action.cancel", "取消"),
            action: #selector(cancel)
        )
        recordBar = CaptureActionBar.make([start, cancel])
        recordBar.isHidden = true
        addSubview(recordBar)
    }

    private func sessionButton(
        title: String,
        symbol: String? = nil,
        tint: NSColor? = nil,
        action: Selector,
        isPrimary: Bool = false
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        CaptureActionBar.configure(button, isPrimary: isPrimary)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            button.imagePosition = .imageLeading
        }
        button.contentTintColor = tint
        if isPrimary { button.keyEquivalent = "\r" }
        return button
    }

    @objc private func startRecord() {
        guard #available(macOS 15, *) else {
            environment.showToast(environment.string("overlay.record.unavailable", "录屏需要 macOS 15 或更高版本"))
            return
        }
        commitText()
        onRecord?(selection)
    }

    private func buildToolbar() {
        toolbar.orientation = .vertical
        toolbar.alignment = .trailing
        toolbar.spacing = 8
        if #unavailable(macOS 26) {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            toolbar.shadow = shadow
        }

        let handle = DragHandle()
        handle.setAccessibilityLabel(environment.string("overlay.toolbar.move", "移动工具栏"))
        handle.onDrag = { [weak self] delta in
            guard let self else { return }
            toolbar.setFrameOrigin(NSPoint(x: toolbar.frame.minX + delta.width,
                                           y: toolbar.frame.minY + delta.height))
            toolbarPinned = true
        }
        var annotate: [NSView] = [handle]
        let drawTools: [(String, Tool, String)] = [
            ("rectangle", .rect, environment.string("overlay.tool.rectangle", "矩形 (R)")),
            ("circle", .ellipse, environment.string("overlay.tool.ellipse", "椭圆 (O)")),
            ("line.diagonal", .line, environment.string("overlay.tool.line", "直线 (L)")),
            ("arrow.up.right", .arrow, environment.string("overlay.tool.arrow", "箭头 (A)")),
            ("pencil.line", .pen, environment.string("overlay.tool.pen", "画笔 (P)")),
            ("textformat", .text, environment.string("overlay.tool.text", "文字 (T)")),
            ("tag", .tag, environment.string("overlay.tool.number", "序号 (N)")),
        ]
        for (symbol, t, tip) in drawTools {
            let button = iconButton(symbol, tip: tip, action: #selector(pickTool(_:)), tag: t.rawValue)
            toolButtons.append(button)
            annotate.append(button)
        }
        annotate.append(separator())
        for (symbol, t, tip) in [("checkerboard.rectangle", Tool.mosaic, environment.string("overlay.tool.mosaic", "马赛克 (M)")),
                                ("aqi.medium", .blur, environment.string("overlay.tool.blur", "模糊 (B)"))] {
            let button = iconButton(symbol, tip: tip, action: #selector(pickTool(_:)), tag: t.rawValue)
            toolButtons.append(button)
            annotate.append(button)
        }

        let process: [NSView] = [
            iconButton("rectangle.roundedtop", tip: environment.string("overlay.tool.effects", "圆角与阴影（[ ] 圆角，{ } 阴影）"), action: #selector(toggleRadiusRow)),
            iconButton("text.viewfinder", tip: environment.string("overlay.recognition.text", "提取文字"), action: #selector(runOCR)),
            iconButton("qrcode.viewfinder", tip: environment.string("overlay.recognition.barcode", "识别二维码与条形码"), action: #selector(detectQR)),
            iconButton("pin", tip: environment.string("overlay.action.pin", "贴图：钉在屏幕上"), action: #selector(pinShot)),
        ]

        let output: [NSView] = [
            iconButton("arrow.uturn.backward", tip: environment.string("overlay.action.undo", "撤销 (⌘Z)"), action: #selector(undoLast)),
            iconButton("arrow.down.to.line", tip: environment.format("overlay.action.save", "保存到「%@」(⌘S) · 按住 ⌥ 点击可另存为 (⇧⌘S)",
                                                                    environment.saveFolderDisplayName), action: #selector(download)),
        ]

        let cancel = iconButton("xmark", tip: environment.string("overlay.action.cancelShortcut", "取消 (Esc)"),
                                action: #selector(cancel), width: 36)
        let done = iconButton("checkmark", tip: environment.string("overlay.action.finish", "复制并完成 (↩ / ⌘C)"),
                              tint: .white, action: #selector(finish), width: 36)
        cancel.backgroundVerticalInset = 0
        done.backgroundVerticalInset = 0

        let row = NSStackView(views: [capsule(annotate), capsule(process), capsule(output),
                                      circularControl(cancel),
                                      circularControl(done, tint: .controlAccentColor)])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        toolbar.addArrangedSubview(Glass.container(row, spacing: 8))

        var style: [NSView] = []
        for (i, color) in Self.palette.enumerated() {
            let button = styledButton(image: dotImage(color: color, diameter: 12), tip: paletteNames[i],
                                      action: #selector(pickColor(_:)), tag: i)
            colorButtons.append(button)
            style.append(button)
        }
        style.append(separator())
        for (i, width) in Self.widths.enumerated() {
            let button = styledButton(image: dotImage(color: .labelColor, diameter: 4 + width * 1.5),
                                      tip: [environment.string("overlay.stroke.thin", "细"),
                                            environment.string("overlay.stroke.medium", "中"),
                                            environment.string("overlay.stroke.thick", "粗")][i], action: #selector(pickWidth(_:)), tag: i)
            widthButtons.append(button)
            style.append(button)
        }
        styleRow = capsule(style)
        styleRow.isHidden = true
        toolbar.addArrangedSubview(styleRow)
        refreshStyleButtons()

        radiusSlider.minValue = 0
        radiusSlider.maxValue = 80
        radiusSlider.doubleValue = Double(cornerRadius)
        radiusSlider.isContinuous = true
        radiusSlider.target = self
        radiusSlider.action = #selector(radiusChanged(_:))
        radiusSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        radiusSlider.setAccessibilityLabel(environment.string("overlay.style.radius", "圆角"))
        radiusLabel.font = PluginTypography.value.nsFont
        radiusLabel.textColor = .secondaryLabelColor
        radiusLabel.alignment = .right
        radiusLabel.stringValue = "\(Int(cornerRadius))"
        radiusLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true
        shadowSlider.minValue = 0
        shadowSlider.maxValue = 60
        shadowSlider.doubleValue = Double(shadowSize)
        shadowSlider.isContinuous = true
        shadowSlider.target = self
        shadowSlider.action = #selector(shadowChanged(_:))
        shadowSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        shadowSlider.setAccessibilityLabel(environment.string("overlay.style.shadow", "阴影"))
        shadowLabel.font = PluginTypography.value.nsFont
        shadowLabel.textColor = .secondaryLabelColor
        shadowLabel.alignment = .right
        shadowLabel.stringValue = "\(Int(shadowSize))"
        shadowLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true
        for (i, color) in Self.palette.enumerated() {
            let button = styledButton(image: dotImage(color: color, diameter: 10),
                                      tip: environment.format("overlay.style.shadowColor", "阴影颜色：%@", paletteNames[i]),
                                      action: #selector(pickShadowColor(_:)), tag: i)
            shadowButtons.append(button)
        }
        refreshShadowButtons()
        let effects: [NSView] = [caption(environment.string("overlay.style.radius", "圆角")), radiusSlider, radiusLabel, separator(),
                                 caption(environment.string("overlay.style.shadow", "阴影")), shadowSlider, shadowLabel] + shadowButtons
        radiusRow = capsule(effects, spacing: 8, inset: 12)
        radiusRow.isHidden = cornerRadius == 0 && shadowSize == 0
        toolbar.addArrangedSubview(radiusRow)

        toolbar.isHidden = true
        addSubview(toolbar)
    }

    private func capsule(
        _ views: [NSView],
        tint: NSColor? = nil,
        spacing: CGFloat = 2,
        inset: CGFloat = 2
    ) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 4, left: inset, bottom: 4, right: inset)
        return Glass.wrap(stack, radius: stack.fittingSize.height / 2, tint: tint)
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = PluginTypography.control.nsFont
        label.textColor = .secondaryLabelColor
        return label
    }

    private func styledButton(
        image: NSImage,
        tip: String?,
        action: Selector?,
        tag: Int = -1,
        enabled: Bool = true,
        width: CGFloat = 32
    ) -> BarButton {
        let button = BarButton(image: image, target: self, action: action)
        button.isBordered = false
        (button.cell as? NSButtonCell)?.highlightsBy = []
        button.imagePosition = .imageOnly
        if let tip {
            tips[button] = tip
            button.setAccessibilityLabel(tip)
        }
        button.tag = tag
        button.isEnabled = enabled
        button.usesCircularBackground = true
        button.backgroundVerticalInset = 6
        button.alphaValue = enabled ? 1 : 0.35
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        button.refresh()
        return button
    }

    private func circularControl(_ button: BarButton, tint: NSColor? = nil) -> NSView {
        Glass.wrap(button, radius: 18, tint: tint)
    }

    private func iconButton(_ symbol: String, tip: String, tint: NSColor = .labelColor,
                            action: Selector?, tag: Int = -1, enabled: Bool = true,
                            width: CGFloat = 32) -> BarButton {
        let image = (NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
                     ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)!)
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))!
        let button = styledButton(image: image, tip: tip, action: action, tag: tag, enabled: enabled, width: width)
        button.tint = tint
        return button
    }

    private func dotImage(color: NSColor, diameter: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let r = NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(ovalIn: r).stroke()
            return true
        }
    }

    private func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }

    private func layoutToolbar() {
        if toolbarPinned {
            toolbar.layoutSubtreeIfNeeded()
            let size = toolbar.fittingSize
            toolbar.frame = NSRect(x: toolbar.frame.minX, y: toolbar.frame.maxY - size.height,
                                   width: size.width, height: size.height)
            reveal(toolbar)
            return
        }
        place(toolbar)
    }

    private func place(_ bar: NSView) {
        bar.layoutSubtreeIfNeeded()
        let size = bar.fittingSize
        var origin = NSPoint(x: selection.maxX - size.width, y: selection.minY - 10 - size.height)
        if origin.y < 0 { origin.y = selection.maxY + 10 }
        if origin.y + size.height > bounds.maxY { origin.y = selection.minY + 10 }
        origin.x = min(max(0, origin.x), bounds.maxX - size.width)
        bar.frame = NSRect(origin: origin, size: size)
        reveal(bar)
    }

    private func reveal(_ bar: NSView) {
        guard bar.isHidden else { return }
        bar.alphaValue = 0
        bar.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            bar.animator().alphaValue = 1
        }
    }

    private func select(tool picked: Tool) {
        commitText()
        tool = tool == picked ? .none : picked
        for b in toolButtons { b.isSelectedLook = b.tag == tool.rawValue }
        styleRow.isHidden = !tool.usesStroke
        layoutToolbar()
        invalidateAnnotations()
    }

    private func refreshStyleButtons() {
        for b in colorButtons { b.isSelectedLook = Self.palette[b.tag] == stroke.color }
        for b in widthButtons { b.isSelectedLook = Self.widths[b.tag] == stroke.width }
        textField?.font = .systemFont(ofSize: stroke.fontSize)
        textField?.textColor = stroke.color
    }

    @objc private func pickTool(_ sender: NSButton) { select(tool: Tool(rawValue: sender.tag) ?? .none) }

    @objc private func toggleRadiusRow() {
        radiusRow.isHidden.toggle()
        layoutToolbar()
    }

    @objc private func radiusChanged(_ sender: NSSlider) { setRadius(CGFloat(sender.doubleValue.rounded())) }
    @objc private func shadowChanged(_ sender: NSSlider) { setShadow(CGFloat(sender.doubleValue.rounded())) }

    private func setShadow(_ value: CGFloat) {
        shadowSize = max(0, min(value, 60))
        shadowSlider.doubleValue = Double(shadowSize)
        shadowLabel.stringValue = "\(Int(shadowSize))"
        environment.storage.set(Double(shadowSize), forKey: "shadowSize")
        updateSelectionPresentation()
    }

    @objc private func pickShadowColor(_ sender: NSButton) {
        shadowColorIndex = sender.tag
        environment.storage.set(sender.tag, forKey: "shadowColor")
        refreshShadowButtons()
        updateSelectionPresentation()
    }

    private func refreshShadowButtons() {
        for b in shadowButtons { b.isSelectedLook = b.tag == shadowColorIndex }
    }

    private func setRadius(_ value: CGFloat) {
        cornerRadius = max(0, min(value, 80))
        radiusSlider.doubleValue = Double(cornerRadius)
        radiusLabel.stringValue = "\(Int(cornerRadius))"
        environment.storage.set(Double(cornerRadius), forKey: "cornerRadius")
        invalidateAnnotations()
    }

    @objc private func pickColor(_ sender: NSButton) {
        stroke.color = Self.palette[sender.tag]
        refreshStyleButtons()
    }

    @objc private func pickWidth(_ sender: NSButton) {
        stroke.width = Self.widths[sender.tag]
        refreshStyleButtons()
    }

    @objc private func undoLast() {
        commitText()
        _ = items.popLast()
        invalidateAnnotations()
    }

    @objc func undo(_ sender: Any?) { undoLast() }
    @objc func copy(_ sender: Any?) {
        if editing {
            finish()
            return
        }
        guard let point = lastMouse, let color = pixelColor(at: point) else { return }
        copyMagnifierValue(color.value(for: magnifierColorFormat), to: .general)
    }

    @discardableResult
    func copyMagnifierValue(_ value: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else { return false }
        onCancel?()
        return true
    }

    @objc private func cancel() { onCancel?() }
    @objc private func finish() { export(.clipboard) }
    @objc private func download() { export(NSEvent.modifierFlags.contains(.option) ? .ask : .folder) }

    @objc private func pinShot() {
        commitText()
        let m = shadowMargin
        let frame = selection.insetBy(dx: -m, dy: -m)
        let shadowed = shadowBlur > 0
        render { [weak self] png in self?.onPin?(png, frame, shadowed) }
    }

    private func export(_ mode: SaveMode) {
        commitText()
        render { [weak self] png in self?.onComplete?(png, mode) }
    }

    private func rerunRecognition() {
        guard let kind = recognitionKind else { return }
        recognize(kind)
    }

    @objc private func detectQR() { recognize(.barcode) }
    @objc private func runOCR() { recognize(.text) }

    private func recognize(_ kind: RecognitionKind) {
        commitText()
        recognition.cancel()
        guard let (sub, r) = cropFrozen(selection) else { return }
        recognitionKind = kind
        toolbar.isHidden = true
        qrRects = []
        resultURL = nil
        showOcrPanel(title: kind.title(in: environment), text: "",
                     status: environment.string("overlay.recognition.busy", "识别中…"), busy: true)

        recognition.start(sub, kind: kind) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let found):
                self.qrRects = found.barcodeRects.map { rect in
                    NSRect(x: r.minX + rect.minX * r.width, y: r.minY + rect.minY * r.height,
                           width: rect.width * r.width, height: rect.height * r.height)
                }
                self.presentRecognized(title: kind.title(in: self.environment), lines: found.lines,
                                       unit: kind.unit(in: self.environment))
            case .failure(let error):
                self.showOcrPanel(title: kind.title(in: self.environment), text: "",
                                 status: self.environment.format("overlay.recognition.failed", "识别失败：%@", error.localizedDescription),
                                 busy: false)
            }
        }
    }

    private func presentRecognized(title: String, lines: [String], unit: String) {
        let text = lines.joined(separator: "\n")
        resultURL = Self.firstLink(in: text)
        if lines.isEmpty {
            showOcrPanel(title: title, text: "", status: environment.string("overlay.recognition.empty", "未识别到内容"), busy: false)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showOcrPanel(title: title, text: text,
                     status: environment.format("overlay.recognition.copiedCount", "%d %@ · 已复制到剪贴板", lines.count, unit),
                     busy: false)
    }

    private static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.url
    }

    @objc private func maskQR() {
        items.append(contentsOf: qrRects.map(Item.qrMask))
        qrRects = []
        hideOcrPanel()
        layoutToolbar()
        invalidateAnnotations()
    }

    @objc private func openLink() {
        guard let url = resultURL else { return }
        onCancel?()
        NSWorkspace.shared.open(url)
    }

    private func showOcrPanel(title: String, text: String, status: String, busy: Bool) {
        if ocrPanel == nil { buildOcrPanel() }
        guard let panel = ocrPanel, let textView = ocrTextView else { return }
        ocrTitle.stringValue = title
        panel.setAccessibilityLabel(title)
        ocrStatus.stringValue = status
        ocrSpinner.isHidden = !busy
        busy ? ocrSpinner.startAnimation(nil) : ocrSpinner.stopAnimation(nil)
        textView.string = text
        maskButton.isHidden = qrRects.isEmpty
        openButton.isHidden = resultURL == nil

        ocrScrollWidth?.constant = min(max(selection.width, 320), 640)
        panel.layoutSubtreeIfNeeded()
        if let manager = textView.layoutManager, let container = textView.textContainer {
            manager.ensureLayout(for: container)
            ocrScrollHeight?.constant = min(max(manager.usedRect(for: container).height + 16, 56), 260)
        }
        place(panel)
        if !busy, !text.isEmpty {
            window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    private func hideOcrPanel() {
        cancelRecognition()
        ocrPanel?.isHidden = true
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }

    func cancelRecognition() {
        recognition.cancel()
        recognitionKind = nil
        qrRects = []
        resultURL = nil
    }

    private func buildOcrPanel() {

        let icon = NSImageView(image: NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        ocrTitle.font = PluginTypography.sectionTitle.nsFont
        ocrTitle.textColor = .labelColor
        ocrSpinner.style = .spinning
        ocrSpinner.controlSize = .small
        ocrSpinner.isDisplayedWhenStopped = false
        ocrStatus.font = PluginTypography.detail.nsFont
        ocrStatus.textColor = .secondaryLabelColor
        ocrStatus.alignment = .right
        let header = NSStackView(views: [icon, ocrTitle, spacer(), ocrSpinner, ocrStatus])
        header.orientation = .horizontal
        header.spacing = 6

        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = true
        textView.isRichText = false
        textView.setAccessibilityLabel(environment.string("overlay.recognition.result", "识别结果"))
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self
        ocrScrollWidth = scroll.widthAnchor.constraint(equalToConstant: 420)
        ocrScrollHeight = scroll.heightAnchor.constraint(equalToConstant: 120)
        ocrScrollWidth?.isActive = true
        ocrScrollHeight?.isActive = true
        ocrTextView = textView

        let hint = NSTextField(labelWithString: environment.string("overlay.recognition.editHint", "可直接编辑 · 选中文本后按 ⌘C 复制 · Esc 关闭"))
        hint.font = PluginTypography.detail.nsFont
        hint.textColor = .tertiaryLabelColor
        CaptureActionBar.configure(maskButton)
        maskButton.target = self
        maskButton.action = #selector(maskQR)
        CaptureActionBar.configure(openButton)
        openButton.target = self
        openButton.action = #selector(openLink)
        let close = sessionButton(
            title: environment.string("overlay.action.close", "关闭"),
            action: #selector(closeOcr)
        )
        let done = sessionButton(
            title: environment.string("overlay.action.done", "完成"),
            action: #selector(finishOcr),
            isPrimary: true
        )
        let footer = NSStackView(views: [hint, spacer(),
                                         close, maskButton, openButton, done])
        footer.orientation = .horizontal
        footer.spacing = 8

        let content = NSStackView(views: [header, scroll, footer])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let panel = Glass.wrap(content, radius: 16)
        panel.isHidden = true
        addSubview(panel)
        ocrPanel = panel
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        return view
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onCancel?()
        return true
    }

    @objc private func closeOcr() {
        hideOcrPanel()
        layoutToolbar()
    }

    @objc private func finishOcr() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ocrTextView?.string ?? "", forType: .string)
        onCancel?()
        environment.showToast(environment.string("overlay.action.copied", "已复制到剪贴板"))
    }

    private func placeTextField(at p: NSPoint) {
        let size = stroke.fontSize
        let field = NSTextField(frame: NSRect(x: p.x, y: p.y - size, width: max(60, selection.maxX - p.x), height: size * 1.4))
        field.font = .systemFont(ofSize: size)
        field.textColor = stroke.color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel(environment.string("overlay.tool.text", "文字 (T)"))
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let string = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !string.isEmpty {
            items.append(Item(shape: .text(string, at: field.frame.origin), stroke: stroke))
        }
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        invalidateAnnotations()
    }

    private func discardText() {
        textField?.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):   commitText(); return true
        case #selector(NSResponder.cancelOperation(_:)): discardText(); return true
        default: return false
        }
    }
}
