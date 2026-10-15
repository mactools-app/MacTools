import AppKit
import MacToolsPluginKit

/// Shared presentation only; recording and scrolling retain their own session state.
@MainActor
final class CaptureStatusPanel: NSPanel {
    var onPrimary: (() -> Void)?
    var onCancel: (() -> Void)?
    private let label = NSTextField(labelWithString: "00:00")
    private let primary = NSButton()
    private var indicator: NSImageView?

    init(primaryTitle: String, cancelTitle: String? = nil, indicatorColor: NSColor? = nil) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        var views: [NSView] = []
        if let indicatorColor, let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) {
            let indicator = NSImageView(image: image)
            self.indicator = indicator
            indicator.contentTintColor = indicatorColor
            indicator.widthAnchor.constraint(equalToConstant: 10).isActive = true
            indicator.heightAnchor.constraint(equalToConstant: 10).isActive = true
            views.append(indicator)
        }
        label.font = PluginTypography.value.nsFont
        label.textColor = .labelColor
        views.append(label)
        if let cancelTitle {
            let cancel = NSButton(title: cancelTitle, target: self, action: #selector(cancelTapped))
            CaptureActionBar.configure(cancel)
            views.append(cancel)
        }
        primary.title = primaryTitle
        primary.target = self
        primary.action = #selector(primaryTapped)
        CaptureActionBar.configure(primary, isPrimary: true)
        views.append(primary)
        // Floating windows sample the desktop; confirmation bars sample their frozen overlay.
        let bar = CaptureActionBar.make(views, blending: .behindWindow)
        setContentSize(bar.fittingSize)
        contentView = bar
    }

    func update(_ text: String, primaryEnabled: Bool = true) {
        label.stringValue = text
        primary.isEnabled = primaryEnabled
        contentView?.layoutSubtreeIfNeeded()
        if let size = contentView?.fittingSize, size.width > 0 { setContentSize(size) }
        if isVisible, let screen {
            let room = screen.visibleFrame
            setFrameOrigin(CGPoint(x: min(max(frame.minX, room.minX), room.maxX - frame.width),
                                   y: min(max(frame.minY, room.minY), room.maxY - frame.height)))
        }
    }

    /// Reuses the visible panel for a follow-up phase, such as processing a finished recording.
    func setPrimary(title: String, indicatorColor: NSColor? = nil) {
        primary.title = title
        if let indicatorColor { indicator?.contentTintColor = indicatorColor }
    }

    func show(near region: CGRect, displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return }
        setFrame(CaptureControlPlacement.frame(size: frame.size, near: region, visibleFrame: screen.visibleFrame), display: false)
        PluginPresentationSafety.prepareForWindowOrdering(self)
        orderFrontRegardless()
    }

    @objc private func primaryTapped() { onPrimary?() }
    @objc private func cancelTapped() { onCancel?() }
}
