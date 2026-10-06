// SPDX-License-Identifier: GPL-3.0-only
// Restored and adapted for MacTools on 2026-09-07.

import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

// MARK: - MenuBarHiddenPopupPanel

@MainActor
final class MenuBarHiddenPopupPanel: NSPanel {
    private weak var controller: MenuBarHiddenController?
    private let panelSize = NSSize(width: 400, height: 120)

    init(controller: MenuBarHiddenController) {
        self.controller = controller
        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 400, height: 120)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMaskImage(size: panelSize, cornerRadius: 14)

        let hosting = NSHostingView(rootView: MenuBarHiddenPopupView(
            controller: controller,
            onLocaleChange: { [weak self] in
                guard let self else { return }
                self.title = controller.localization.string("popup.title", defaultValue: "隐藏图标")
                self.setAccessibilityLabel(self.title)
            }
        ))
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        contentView = effect
        setContentSize(panelSize)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(anchor: NSRect?) {
        position(anchor: anchor)
        PluginPresentationSafety.prepareForWindowOrdering(self)
        orderFrontRegardless()
        makeKey()
    }

    override func cancelOperation(_: Any?) {
        orderOut(nil)
        controller?.closePopup()
    }

    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.orderOut(nil)
            self.controller?.closePopup()
        }
    }

    private func position(anchor: NSRect?) {
        let matchingScreen = anchor.flatMap { rect in
            NSScreen.screens.first(where: { $0.frame.intersects(rect) })
        }
        guard let screen = matchingScreen ?? NSScreen.main else { return }

        let x: CGFloat
        let y: CGFloat
        if let anchor {
            x = max(
                screen.visibleFrame.minX + 8,
                min(anchor.midX - panelSize.width / 2, screen.visibleFrame.maxX - panelSize.width - 8)
            )
            y = max(
                screen.visibleFrame.minY + 8,
                min(anchor.minY - panelSize.height - 8, screen.visibleFrame.maxY - panelSize.height - 8)
            )
        } else {
            x = screen.visibleFrame.midX - panelSize.width / 2
            y = screen.visibleFrame.maxY - panelSize.height - 12
        }
        setFrame(NSRect(origin: CGPoint(x: x, y: y), size: panelSize), display: true)
    }

    private static func roundedMaskImage(size: NSSize, cornerRadius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: NSRect(origin: .zero, size: size),
                xRadius: cornerRadius,
                yRadius: cornerRadius
            ).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius, left: cornerRadius,
            bottom: cornerRadius, right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Popup contents

private struct MenuBarHiddenPopupView: View {
    @ObservedObject var controller: MenuBarHiddenController
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let onLocaleChange: () -> Void
    private var localization: PluginLocalization { controller.localization }

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    localization.string("popup.title", defaultValue: "隐藏图标"),
                    systemImage: "menubar.arrow.up.rectangle"
                )
                    .font(.headline)
                Spacer()
            }

            if controller.snapshot.hiddenItems.isEmpty {
                emptyView
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(controller.snapshot.hiddenItems) { item in
                            MenuBarHiddenPopupItem(
                                item: item,
                                iconCache: controller.manager.iconCache,
                                onLeftClick: {
                                    controller.clickItemAfterPopupCloses(item, button: .left)
                                },
                                onRightClick: {
                                    controller.clickItemAfterPopupCloses(item, button: .right)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                // Mirror semantic copy, retaining the menu bar's physical item order.
                .environment(\.layoutDirection, .leftToRight)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.locale, locale)
        .environment(
            \.layoutDirection,
            locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
        )
        .onChange(of: runtimeLocale.revision, initial: true) { _, _ in onLocaleChange() }
    }

    private var emptyView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            Text(localization.string("popup.empty", defaultValue: "没有隐藏的菜单栏图标"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension NSPanel {
    @MainActor
    func waitUntilClosed(timeout: Duration = .milliseconds(200)) async {
        guard isVisible else { return }

        let deadline = ContinuousClock.now + timeout
        while isVisible, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - Per-item popup cell (left/right click)

private struct MenuBarHiddenPopupItem: NSViewRepresentable {
    let item: MenuBarItem
    let iconCache: MenuBarHiddenIconCache
    let onLeftClick: () -> Void
    let onRightClick: () -> Void

    func makeNSView(context _: Context) -> MenuBarHiddenPopupItemNSView {
        MenuBarHiddenPopupItemNSView(
            item: item,
            iconCache: iconCache,
            onLeftClick: onLeftClick,
            onRightClick: onRightClick
        )
    }

    func updateNSView(_ nsView: MenuBarHiddenPopupItemNSView, context _: Context) {
        nsView.update(
            item: item,
            iconCache: iconCache,
            onLeftClick: onLeftClick,
            onRightClick: onRightClick
        )
    }
}

final class MenuBarHiddenPopupItemNSView: NSView {
    private var item: MenuBarItem
    private var iconCache: MenuBarHiddenIconCache
    private var onLeftClick: () -> Void
    private var onRightClick: () -> Void
    private var cachedImage: MenuBarHiddenIconCache.CapturedImage? {
        didSet {
            guard !MenuBarHiddenIconCache.CapturedImage.isVisuallyEqual(oldValue, cachedImage) else { return }
            needsDisplay = true
        }
    }
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var cancellables = Set<AnyCancellable>()

    private static let itemSize: CGFloat = 38

    init(
        item: MenuBarItem,
        iconCache: MenuBarHiddenIconCache,
        onLeftClick: @escaping () -> Void,
        onRightClick: @escaping () -> Void
    ) {
        self.item = item
        self.iconCache = iconCache
        self.onLeftClick = onLeftClick
        self.onRightClick = onRightClick
        self.cachedImage = iconCache.image(for: item.tag)
        super.init(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        toolTip = item.displayName
        configureCancellables()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func update(
        item: MenuBarItem,
        iconCache: MenuBarHiddenIconCache,
        onLeftClick: @escaping () -> Void,
        onRightClick: @escaping () -> Void
    ) {
        self.item = item
        self.iconCache = iconCache
        self.onLeftClick = onLeftClick
        self.onRightClick = onRightClick
        toolTip = item.displayName
        cachedImage = iconCache.image(for: item.tag)
        configureCancellables()
        needsDisplay = true
    }

    private func configureCancellables() {
        cancellables.removeAll()
        let tag = item.tag
        iconCache.$images
            .map { [weak iconCache] _ in iconCache?.image(for: tag) }
            .removeDuplicates(by: MenuBarHiddenIconCache.CapturedImage.isVisuallyEqual)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                self?.cachedImage = image
            }
            .store(in: &cancellables)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 48, height: 48) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true; needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false; needsDisplay = true
    }

    override func mouseUp(with _: NSEvent) { onLeftClick() }
    override func rightMouseUp(with _: NSEvent) { onRightClick() }

    override func draw(_: NSRect) {
        let bg: NSColor = isHovered
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18)
            : .clear
        bg.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()

        let iconSize = Self.itemSize
        let iconRect = CGRect(
            x: (bounds.width - iconSize) / 2,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        if let image = cachedImage?.nsImage {
            image.draw(
                in: aspectFitRect(imageSize: image.size, in: iconRect),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }
    }

    private func aspectFitRect(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
