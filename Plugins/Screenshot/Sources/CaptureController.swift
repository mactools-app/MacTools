import AppKit
import MacToolsPluginKit
import QuartzCore

/// Acquires a fresh desktop before presenting any capture UI, without activating the host.
@MainActor
final class CaptureController {
    var onFinish: (() -> Void)?
    var onError: ((String) -> Void)?
    var onRecord: ((CaptureRegion) -> Void)?
    var onScroll: ((CaptureRegion) -> Void)?

    private let quick: Bool
    private let environment: ScreenshotEnvironment
    private let pool: CaptureOverlayPool
    private var overlays: [OverlayWindow] = []
    private var pointerTracker: CapturePointerTracker?
    private var startTask: Task<Void, Never>?
    private var cursorPushed = false
    private var finished = false

    private nonisolated static let standardPanelLevels: Set<Int> = [
        Int(CGWindowLevelForKey(.normalWindow)),
        Int(CGWindowLevelForKey(.floatingWindow)),
        Int(CGWindowLevelForKey(.modalPanelWindow)),
        Int(CGWindowLevelForKey(.utilityWindow)),
    ]
    private nonisolated static let menuPanelLevels = Int(CGWindowLevelForKey(.mainMenuWindow))
        ... Int(CGWindowLevelForKey(.popUpMenuWindow))

    init(quick: Bool, environment: ScreenshotEnvironment, pool: CaptureOverlayPool) {
        self.quick = quick
        self.environment = environment
        self.pool = pool
    }

    func start() {
        guard !finished, startTask == nil else { return }
        let displays = CaptureDisplay.current()
        let windowTask = Task.detached(priority: .userInitiated) { Self.onScreenWindows() }
        startTask = Task { [weak self] in
            guard let self else { windowTask.cancel(); return }
            defer { windowTask.cancel(); startTask = nil }
            do {
                let images = try await CapturePipeline.capture(displays)
                try Task.checkCancellation()
                guard !finished else { return }
                let windows = await windowTask.value
                try Task.checkCancellation()
                guard displays == CaptureDisplay.current() else { throw CaptureFailure.displayChanged }

                pool.prepare()
                for display in displays {
                    guard let screen = NSScreen.screens.first(where: {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
                    }), let image = images[display.id], let overlay = pool.window(for: display) else {
                        throw CaptureFailure.displayChanged
                    }
                    let localWindows = windows
                        .map { $0.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
                        .filter { $0.intersects(NSRect(origin: .zero, size: display.frame.size)) }
                    overlay.prepare(screen: screen, frozen: image, windows: localWindows, quick: quick)
                    configure(overlay, display: display)
                    overlays.append(overlay)
                }

                // The overlay owns this cursor until every capture exit path dismisses it.
                NSCursor.crosshair.push()
                cursorPushed = true
                let pointerTracker = CapturePointerTracker(overlays: overlays)
                self.pointerTracker = pointerTracker
                pointerTracker.update()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for overlay in overlays { overlay.prepareForPresentation() }
                CATransaction.commit()
                CATransaction.flush()
                PluginPresentationSafety.prepareForWindowOrdering()
                for overlay in overlays { overlay.orderFrontRegardless() }
                pointerTracker.update()
            } catch {
                guard !finished, !Task.isCancelled else { return }
                onError?(environment.format("capture.failed", "截图失败：%@", environment.captureErrorDescription(error)))
                dismiss()
            }
        }
    }

    private func configure(_ overlay: OverlayWindow, display: CaptureDisplay) {
        overlay.onComplete = { [weak self] png, mode in
            guard let self, !finished else { return }
            guard mode == .ask else {
                dismiss()
                ScreenshotOutput.save(png, mode: mode, environment: environment)
                return
            }
            // Keep the selection and annotations until the file is written; cancelling or a write
            // failure returns to them.
            suspend()
            let chosen = ScreenshotOutput.saveAs(png, suggestedName: ScreenshotOutput.suggestedScreenshotName(environment),
                                                 environment: environment) { [weak self] written in
                guard let self, !finished else { return }
                if written {
                    ScreenshotOutput.copyToPasteboard(png)
                    dismiss()
                } else {
                    resume()
                }
            }
            if !chosen, !finished { resume() }
        }
        overlay.onCancel = { [weak self] in self?.dismiss() }
        overlay.onRecord = { [weak self] rect in
            guard let self, !finished else { return }
            guard let request = makeRegion(rect, display: display) else { return }
            dismiss()
            onRecord?(request)
        }
        overlay.onScroll = { [weak self] rect in
            guard let self, !finished else { return }
            guard let request = makeRegion(rect, display: display) else { return }
            dismiss()
            onScroll?(request)
        }
        overlay.onPin = { [weak self] png, frame, shadowed in
            guard let self, !finished else { return }
            dismiss()
            environment.pin(png, at: frame, bakedShadow: shadowed,
                            name: "\(environment.string("output.screenshotName", "截图")) \(environment.stamp()).png")
            environment.showToast(environment.string("pin.created", "已钉在屏幕上，双击或 Esc 关闭"))
        }
    }

    /// Hides the capture surfaces without discarding their session state.
    private func suspend() {
        pointerTracker?.stop()
        for overlay in overlays { overlay.orderOut(nil) }
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    private func resume() {
        NSCursor.crosshair.push()
        cursorPushed = true
        PluginPresentationSafety.prepareForWindowOrdering()
        for overlay in overlays { overlay.orderFrontRegardless() }
        let tracker = CapturePointerTracker(overlays: overlays)
        pointerTracker = tracker
        // Keyboard focus follows the pointer's display, as when capture first appears.
        tracker.update()
    }

    func dismiss() {
        guard !finished else { return }
        finished = true
        startTask?.cancel()
        startTask = nil
        pointerTracker?.stop()
        pointerTracker = nil
        for overlay in overlays { overlay.dismiss() }
        overlays.removeAll()
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        onFinish?()
    }

    private func makeRegion(_ rect: NSRect, display: CaptureDisplay) -> CaptureRegion? {
        do { return try CaptureRegion(selection: rect, display: display) }
        catch { onError?(environment.captureErrorDescription(error)); return nil }
    }

    private nonisolated static func onScreenWindows() -> [NSRect] {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return selectableWindowRects(from: windows, primaryHeight: primaryHeight)
    }

    nonisolated static func selectableWindowRects(from windows: [[String: Any]], primaryHeight: CGFloat) -> [NSRect] {
        windows.compactMap { window in
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  isSelectableWindowLayer(layer),
                  ((window[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 1, frame.height > 1
            else { return nil }
            return NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        }
    }

    nonisolated static func isSelectableWindowLayer(_ layer: Int) -> Bool {
        if standardPanelLevels.contains(layer) { return true }
        // Menu bar popovers can use levels between the public menu and pop-up menu levels.
        return menuPanelLevels.contains(layer)
    }
}

/// Resolves one pointer owner for the capture session, independently of tracking-event order.
@MainActor
final class CapturePointerTracker {
    private let overlays: [OverlayWindow]
    private let mouseLocation: () -> NSPoint
    private weak var activeOverlay: OverlayWindow?
    private var stopped = false

    init(overlays: [OverlayWindow], mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }) {
        self.overlays = overlays
        self.mouseLocation = mouseLocation
        for overlay in overlays {
            (overlay.contentView as? OverlayView)?.onPointerActivity = { [weak self] in self?.update() }
        }
    }

    func update() {
        guard !stopped else { return }
        // Tracking events can arrive late; their type and saved coordinates are not ownership.
        let point = mouseLocation()
        let next = overlays.first { NSMouseInRect(point, $0.frame, false) }
        if activeOverlay !== next {
            (activeOverlay?.contentView as? OverlayView)?.updatePointer(at: nil)
            activeOverlay = next
        }
        guard let next, let view = next.contentView as? OverlayView else { return }
        if next.isVisible, !next.isKeyWindow { next.makeKey() }
        view.updatePointer(at: view.convert(next.convertPoint(fromScreen: point), from: nil))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for overlay in overlays {
            guard let view = overlay.contentView as? OverlayView else { continue }
            view.onPointerActivity = nil
            view.updatePointer(at: nil)
        }
        activeOverlay = nil
    }
}
