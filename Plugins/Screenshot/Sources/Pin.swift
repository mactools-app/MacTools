import AppKit
import Combine
import MacToolsPluginKit

/// A movable image window retained by the plugin environment until closed or disabled.
@MainActor
final class PinWindow: NSWindow {
    init(png: Data, at frame: NSRect, name: String, environment: ScreenshotEnvironment) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = PinView(png: png, size: frame.size, name: name, environment: environment)
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
private final class PinView: NSImageView {
    private let png: Data
    private let name: String
    private let baseSize: NSSize
    private weak var environment: ScreenshotEnvironment?
    private var zoom: CGFloat = 1
    private var localeSubscription: AnyCancellable?

    init(png: Data, size: NSSize, name: String, environment: ScreenshotEnvironment) {
        self.png = png
        self.name = name
        self.environment = environment
        baseSize = size
        super.init(frame: NSRect(origin: .zero, size: size))
        image = NSImage(data: png)
        imageScaling = .scaleAxesIndependently
        autoresizingMask = [.width, .height]
        refreshTooltip()
        localeSubscription = PluginRuntimeLocalization.source.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshTooltip() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var acceptsFirstResponder: Bool { true }

    private func refreshTooltip() {
        toolTip = environment?.string("pin.tooltip", "拖动移动 · 滚轮缩放 · 双击/Esc 关闭 · ⌘C 复制 · ⌘S 保存")
    }

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

    override func keyDown(with event: NSEvent) {
        switch (event.keyCode, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers) {
        case (53, _, _): window?.close()
        case (_, true, "c"):
            ScreenshotOutput.copyToPasteboard(png)
            if let environment { environment.showToast(environment.string("output.copied", "已复制到剪贴板")) }
        case (_, true, "s"):
            if let environment { ScreenshotOutput.saveAs(png, suggestedName: name, environment: environment) }
        default: super.keyDown(with: event)
        }
    }
}
