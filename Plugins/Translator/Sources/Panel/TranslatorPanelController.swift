import AppKit
import Combine
import MacToolsPluginKit
import SwiftUI

@MainActor
final class TranslatorPanelController: TranslatorPanelControlling {
    private static let panelSize = NSSize(width: 606, height: 380)
    private static let screenPadding: CGFloat = 16

    private var panelWindow: TranslatorPanelWindow?
    private var lastFrame: NSRect?
    private let model = TranslatorPanelModel()
    private let localization: PluginLocalization
    private var localeSubscription: AnyCancellable?

    var onAction: ((TranslatorPanelAction) -> Void)?

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
        localeSubscription = PluginRuntimeLocalization.source.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshPanelLocalization() }
        }
    }

    func show(snapshot: TranslatorPanelSnapshot) {
        model.snapshot = snapshot
        let panel = panelWindow ?? makePanel()
        panelWindow = panel
        refreshPanelLocalization()
        panel.setFrame(clampedFrame(for: panel.frame, panel: panel), display: true)

        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.orderFrontRegardless()

        // Keep the panel non-key while capturing so the frontmost app keeps keyboard focus
        // for AX selection and simulated Cmd-C. Result states become key to support buttons,
        // text selection, and Esc close without activating the whole app.
        if snapshot.phase != .capturing {
            panel.makeKey()
        }
    }

    func update(snapshot: TranslatorPanelSnapshot) {
        model.snapshot = snapshot
    }

    func close() {
        guard let panelWindow else { return }

        lastFrame = panelWindow.frame
        panelWindow.performProgrammaticClose {
            panelWindow.orderOut(nil)
        }
    }

    private func makePanel() -> TranslatorPanelWindow {
        let panel = TranslatorPanelWindow(size: Self.panelSize)
        panel.onCloseRequest = { [weak self] in
            self?.onAction?(.close)
        }

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.roundedMaskImage(size: Self.panelSize, cornerRadius: 18)

        let rootView = TranslatorPanelHostView(model: model, localization: localization) { [weak self] action in
            self?.onAction?(action)
        }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = effectView.bounds
        hostingView.autoresizingMask = [.width, .height]
        effectView.addSubview(hostingView)

        panel.contentView = effectView
        panel.setContentSize(Self.panelSize)
        let initialFrame = lastFrame ?? defaultFrame(for: panel)
        panel.setFrame(clampedFrame(for: initialFrame, panel: panel), display: true)
        return panel
    }

    private func refreshPanelLocalization() {
        guard let panelWindow else { return }
        panelWindow.title = localization.string("metadata.title", defaultValue: "翻译")
        panelWindow.setAccessibilityTitle(panelWindow.title)
    }

    private func defaultFrame(for panel: NSPanel) -> NSRect {
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = visibleFrame.maxX - Self.panelSize.width - Self.screenPadding
        let y = visibleFrame.maxY - Self.panelSize.height - Self.screenPadding
        return clampedFrame(
            NSRect(origin: CGPoint(x: x, y: y), size: Self.panelSize),
            within: visibleFrame
        )
    }

    private func clampedFrame(_ frame: NSRect, within visibleFrame: NSRect) -> NSRect {
        guard !visibleFrame.isEmpty else { return frame }

        let minX = visibleFrame.minX + Self.screenPadding
        let maxX = visibleFrame.maxX - frame.width - Self.screenPadding
        let minY = visibleFrame.minY + Self.screenPadding
        let maxY = visibleFrame.maxY - frame.height - Self.screenPadding
        let x = maxX >= minX ? min(max(frame.minX, minX), maxX) : visibleFrame.midX - frame.width / 2
        let y = maxY >= minY ? min(max(frame.minY, minY), maxY) : visibleFrame.midY - frame.height / 2
        return NSRect(origin: CGPoint(x: x, y: y), size: frame.size)
    }

    private func clampedFrame(for frame: NSRect, panel: NSPanel) -> NSRect {
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        return clampedFrame(frame, within: visibleFrame)
    }

    private static func roundedMaskImage(size: NSSize, cornerRadius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius,
            left: cornerRadius,
            bottom: cornerRadius,
            right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }
}
