import AppKit
import Combine
import MacToolsPluginKit

/// A movable image window retained by the plugin environment until closed or disabled.
@MainActor
final class PinWindow: NSWindow {
    /// A result pin, such as an assembled scrolling screenshot, closes after it is copied or saved.
    /// A deliberately pinned image stays on screen after either action.
    init(png: Data, at frame: NSRect, name: String, isResult: Bool = false, environment: ScreenshotEnvironment) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = PinView(png: png, size: frame.size, name: name, isResult: isResult, environment: environment)
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        (contentView as? PinView)?.dismissControls()
        super.close()
    }
}

@MainActor
final class PinView: NSImageView {
    private let png: Data
    private let name: String
    private let isResult: Bool
    private let baseSize: NSSize
    private weak var environment: ScreenshotEnvironment?
    private var zoom: CGFloat = 1
    private var localeSubscription: AnyCancellable?
    private var controls: NSView!
    private var controlButtons: [(button: BarButton, key: String, fallback: String)] = []
    private var controlsPanel: PinControlsPanel?
    private var controlsTrackingArea: NSTrackingArea?
    private var hideTimer: Timer?

    init(png: Data, size: NSSize, name: String, isResult: Bool, environment: ScreenshotEnvironment) {
        self.png = png
        self.name = name
        self.isResult = isResult
        self.environment = environment
        baseSize = size
        super.init(frame: NSRect(origin: .zero, size: size))
        image = NSImage(data: png)
        imageScaling = .scaleAxesIndependently
        autoresizingMask = [.width, .height]
        buildControls()
        refreshLocalizedText()
        localeSubscription = PluginRuntimeLocalization.source.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshLocalizedText() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var acceptsFirstResponder: Bool { true }

    private func refreshLocalizedText() {
        toolTip = environment?.string("pin.tooltip", "拖动移动 · 滚轮缩放 · 双击/Esc 关闭 · ⌘C 复制 · ⌘S 保存")
        for control in controlButtons {
            let text = environment?.string(control.key, control.fallback) ?? control.fallback
            control.button.toolTip = text
            control.button.setAccessibilityLabel(text)
        }
    }

    // MARK: Hover controls

    /// Copy, save, and close actions appear on hover so they do not cover the image otherwise.
    private func buildControls() {
        let specs: [(String, String, String, Selector)] = [
            ("doc.on.doc", "pin.copy", "复制 (⌘C)", #selector(copyImage)),
            ("arrow.down.to.line", "pin.save", "另存为 (⌘S)", #selector(saveImage)),
            ("xmark", "pin.close", "关闭 (Esc)", #selector(closeWindow)),
        ]
        var buttons: [NSView] = []
        for (symbol, key, fallback, action) in specs {
            let image = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                         ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)!)
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))!
            let button = BarButton(image: image, target: self, action: action)
            button.isBordered = false
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.imagePosition = .imageOnly
            button.usesCircularBackground = true
            button.backgroundVerticalInset = 6
            button.setAccessibilityIdentifier(key)
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            button.refresh()
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self, userInfo: ["button": button]))
            controlButtons.append((button, key, fallback))
            buttons.append(button)
        }
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        controls = Glass.wrap(stack, radius: stack.fittingSize.height / 2, blending: .behindWindow)
        controls.isHidden = true
        addSubview(controls)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { dismissControls(); return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(positionControls), name: name, object: window)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo == nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func layout() {
        super.layout()
        positionControls()
    }

    /// Controls sit inside the image when they fit; small images show them in an adjacent panel instead.
    @objc private func positionControls() {
        let size = controls.fittingSize
        if bounds.width >= size.width, bounds.height >= size.height + 10 {
            if controls.superview !== self {
                if let tracking = controlsTrackingArea { controls.removeTrackingArea(tracking) }
                controlsTrackingArea = nil
                controlsPanel?.contentView = nil
                controls.removeFromSuperview()
                addSubview(controls)
            }
            hideControlsPanel()
            controls.frame = NSRect(x: (bounds.width - size.width) / 2, y: 10, width: size.width, height: size.height)
        } else if let window {
            let panel = controlsPanel ?? PinControlsPanel()
            controlsPanel = panel
            if panel.contentView !== controls {
                controls.removeFromSuperview()
                panel.contentView = controls
                let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                              owner: self, userInfo: nil)
                controls.addTrackingArea(tracking)
                controlsTrackingArea = tracking
            }
            let screen = window.screen ?? NSScreen.screens.first { $0.frame.intersects(window.frame) }
            let area = screen?.visibleFrame ?? window.frame.insetBy(dx: -size.width, dy: -size.height)
            panel.setFrame(Self.controlsFrame(adjacentTo: window.frame, size: size, within: area), display: true)
            if !controls.isHidden, window.isVisible, panel.parent !== window {
                window.addChildWindow(panel, ordered: .above)
            }
        }
    }

    /// Chooses the screen-clamped side position that overlaps the image least.
    static func controlsFrame(adjacentTo image: NSRect, size: NSSize, within screen: NSRect) -> NSRect {
        let origins = [NSPoint(x: image.midX - size.width / 2, y: image.minY - size.height),
                       NSPoint(x: image.midX - size.width / 2, y: image.maxY),
                       NSPoint(x: image.maxX, y: image.midY - size.height / 2),
                       NSPoint(x: image.minX - size.width, y: image.midY - size.height / 2)]
        let candidates = origins.map { point in
            NSRect(x: max(screen.minX, min(point.x, screen.maxX - size.width)),
                   y: max(screen.minY, min(point.y, screen.maxY - size.height)),
                   width: size.width, height: size.height)
        }
        return candidates.min { lhs, rhs in
            let left = lhs.intersection(image), right = rhs.intersection(image)
            return left.width * left.height < right.width * right.height
        }!
    }

    private func hideControlsPanel() {
        guard let panel = controlsPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func dismissControls() {
        hideTimer?.invalidate()
        hideTimer = nil
        controls.isHidden = true
        for control in controlButtons { control.button.isHovered = false }
        hideControlsPanel()
    }

    override func mouseEntered(with event: NSEvent) {
        if let button = event.trackingArea?.userInfo?["button"] as? BarButton {
            button.isHovered = true
            return
        }
        setControls(visible: true)
    }

    override func mouseExited(with event: NSEvent) {
        if let button = event.trackingArea?.userInfo?["button"] as? BarButton {
            button.isHovered = false
            return
        }
        setControls(visible: false)
    }

    private func setControls(visible: Bool) {
        hideTimer?.invalidate()
        hideTimer = nil
        if visible {
            controls.isHidden = false
            positionControls()
            return
        }
        // Give the pointer time to cross into the adjacent control panel.
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pointer = NSEvent.mouseLocation
                if self.window?.frame.contains(pointer) == true { return }
                if let panel = self.controlsPanel, panel.isVisible, panel.frame.contains(pointer) { return }
                self.dismissControls()
            }
        }
    }

    // MARK: Actions

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.close(); return }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        zoom = min(max(zoom * (1 + event.scrollingDeltaY * 0.01), 0.2), 4)
        let size = NSSize(width: baseSize.width * zoom, height: baseSize.height * zoom)
        // Keep the top-left corner fixed while resizing.
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size.height,
                               width: size.width, height: size.height), display: true)
    }

    @objc private func copyImage() {
        ScreenshotOutput.copyToPasteboard(png)
        if let environment { environment.showToast(environment.string("output.copied", "已复制到剪贴板")) }
        if isResult { closeWindow() }
    }

    @objc private func saveImage() {
        guard let environment else { return }
        // A result closes only after its file is written; cancellation or a write failure keeps it for another try.
        ScreenshotOutput.saveAs(png, suggestedName: name, environment: environment) { [weak self] written in
            guard let self, written, isResult else { return }
            closeWindow()
        }
    }

    @objc private func closeWindow() { window?.close() }

    override func keyDown(with event: NSEvent) {
        switch (event.keyCode, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers) {
        case (53, _, _): closeWindow()
        case (_, true, "c"): copyImage()
        case (_, true, "s"): saveImage()
        default: super.keyDown(with: event)
        }
    }
}

/// Hosts pin controls beside an image that is too small to contain them.
private final class PinControlsPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
