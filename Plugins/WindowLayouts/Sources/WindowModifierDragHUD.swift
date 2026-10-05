import AppKit
import Combine
import Foundation
import MacToolsPluginKit
import SwiftUI

enum WindowModifierDragHUDState: Equatable, Sendable {
    case armed(modifiers: ShortcutModifiers, pointer: CGPoint)
    case active(modifiers: ShortcutModifiers, pointer: CGPoint)
    case failure(message: String, pointer: CGPoint)
}

@MainActor
protocol WindowModifierDragHUDPresenting: AnyObject {
    func present(_ state: WindowModifierDragHUDState)
    func dismiss()
}

final class WindowModifierDragHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct WindowModifierDragHUDView: View {
    let state: WindowModifierDragHUDState
    let movePointerTitle: String
    let movingWindowTitle: String

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case let .armed(modifiers, _):
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .semibold))
                Text(modifiers.symbolString)
                    .font(PluginTypography.body.font.weight(.semibold))
                Text(movePointerTitle)
                    .font(PluginTypography.control.font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            case let .active(modifiers, _):
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                Text(modifiers.symbolString)
                    .font(PluginTypography.body.font.weight(.semibold))
                Text(movingWindowTitle)
                    .font(PluginTypography.control.font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            case let .failure(message, _):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(PluginTypography.control.font)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(foregroundColor)
        .background {
            ZStack {
                PluginFloatingPanelSurface(shape: .capsule)
                if case .active = state {
                    Capsule().fill(Color.accentColor)
                }
            }
        }
        .overlay {
            Capsule()
                .stroke(borderColor, lineWidth: colorSchemeContrast == .increased ? 1.5 : 0.5)
        }
        .shadow(
            color: Color.black.opacity(reduceTransparency ? 0.05 : 0.18),
            radius: 4,
            x: 0,
            y: 2
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: state)
    }

    private var foregroundColor: Color {
        switch state {
        case .armed:
            return .primary
        case .active:
            return .white
        case .failure:
            return .primary
        }
    }

    private var borderColor: Color {
        switch state {
        case .active:
            return Color.white.opacity(0.3)
        case .armed, .failure:
            return colorSchemeContrast == .increased
                ? Color.primary.opacity(0.4)
                : Color.primary.opacity(0.12)
        }
    }
}

@MainActor
final class WindowModifierDragHUDController: WindowModifierDragHUDPresenting {
    private var panel: WindowModifierDragHUDPanel?
    private var hostingView: NSHostingView<WindowModifierDragHUDRootView>?
    private var localeSubscription: AnyCancellable?
    private var renderedLocaleRevision: Int?
    private(set) var currentState: WindowModifierDragHUDState?

    private let visibleFramesProvider: () -> [CGRect]
    private let displayFramesProvider: () -> [CGRect]
    private let movePointerTitleProvider: () -> String
    private let movingWindowTitleProvider: () -> String
    private let announceAccessibility: (String) -> Void

    var presentedPanelForTests: WindowModifierDragHUDPanel? { panel }

    init(
        visibleFramesProvider: @escaping () -> [CGRect] = {
            NSScreen.screens.map(\.visibleFrame)
        },
        displayFramesProvider: @escaping () -> [CGRect] = {
            NSScreen.screens.map(\.frame)
        },
        movePointerTitleProvider: @escaping () -> String = { "Move the pointer to reposition the window" },
        movingWindowTitleProvider: @escaping () -> String = { "Moving window — release the keys to finish" },
        announceAccessibility: @escaping (String) -> Void = { message in
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    ) {
        self.visibleFramesProvider = visibleFramesProvider
        self.displayFramesProvider = displayFramesProvider
        self.movePointerTitleProvider = movePointerTitleProvider
        self.movingWindowTitleProvider = movingWindowTitleProvider
        self.announceAccessibility = announceAccessibility
        localeSubscription = PluginRuntimeLocalization.source.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, let state = self.currentState else { return }
                self.update(state, announcesFailure: false)
            }
        }
    }

    func present(_ state: WindowModifierDragHUDState) {
        update(state, announcesFailure: true)
    }

    private func update(_ state: WindowModifierDragHUDState, announcesFailure: Bool) {
        let previousState = currentState
        currentState = state

        if announcesFailure, case let .failure(message, _) = state {
            announceAccessibility(message)
        }

        let panel = panel ?? makePanel()
        self.panel = panel

        if let hostingView,
           renderedLocaleRevision == PluginRuntimeLocalization.source.revision,
           Self.hasSameContent(previousState, state) {
            let targetFrame = Self.panelFrame(
                at: Self.pointerLocation(from: state),
                panelSize: panel.frame.size,
                displayFrames: displayFramesProvider(),
                visibleFrames: visibleFramesProvider()
            )
            panel.setFrameOrigin(targetFrame.origin)
            if !panel.isVisible {
                let textEditingRestoration = PluginPresentationSafety.prepareForWindowOrdering(
                    panel,
                    restoringTextEditingIn: NSApp.isActive ? NSApp.keyWindow : nil
                )
                panel.orderFrontRegardless()
                textEditingRestoration?.restore()
            }
            hostingView.displayIfNeeded()
            return
        }

        let movePointerTitle = movePointerTitleProvider()
        let movingWindowTitle = movingWindowTitleProvider()
        let hudView = WindowModifierDragHUDRootView(content: WindowModifierDragHUDView(
            state: state,
            movePointerTitle: movePointerTitle,
            movingWindowTitle: movingWindowTitle
        ))
        renderedLocaleRevision = PluginRuntimeLocalization.source.revision
        switch state {
        case .armed: panel.title = movePointerTitle
        case .active: panel.title = movingWindowTitle
        case let .failure(message, _): panel.title = message
        }
        panel.setAccessibilityLabel(panel.title)

        let hosting: NSHostingView<WindowModifierDragHUDRootView>
        if let existing = hostingView {
            existing.rootView = hudView
            existing.invalidateIntrinsicContentSize()
            hosting = existing
        } else {
            let newHosting = NSHostingView(rootView: hudView)
            newHosting.sizingOptions = [.intrinsicContentSize]
            panel.contentView = newHosting
            self.hostingView = newHosting
            hosting = newHosting
        }

        hosting.layoutSubtreeIfNeeded()
        let fittingSize = hosting.fittingSize
        let resolvedSize = CGSize(
            width: max(fittingSize.width, 40),
            height: max(fittingSize.height, 24)
        )

        let pointerLocation = Self.pointerLocation(from: state)
        let targetFrame = Self.panelFrame(
            at: pointerLocation,
            panelSize: resolvedSize,
            displayFrames: displayFramesProvider(),
            visibleFrames: visibleFramesProvider()
        )

        panel.setFrame(targetFrame, display: true)
        let textEditingRestoration = PluginPresentationSafety.prepareForWindowOrdering(
            panel,
            restoringTextEditingIn: NSApp.isActive ? NSApp.keyWindow : nil
        )
        panel.orderFrontRegardless()
        textEditingRestoration?.restore()
    }

    private static func hasSameContent(
        _ lhs: WindowModifierDragHUDState?,
        _ rhs: WindowModifierDragHUDState
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.armed(lhsModifiers, _), .armed(rhsModifiers, _)),
             let (.active(lhsModifiers, _), .active(rhsModifiers, _)):
            return lhsModifiers == rhsModifiers
        case let (.failure(lhsMessage, _), .failure(rhsMessage, _)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }

    func dismiss() {
        currentState = nil
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        renderedLocaleRevision = nil
    }

    private func makePanel() -> WindowModifierDragHUDPanel {
        let panel = WindowModifierDragHUDPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("WindowModifierDragHUDPanel")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        return panel
    }

    private static func pointerLocation(from state: WindowModifierDragHUDState) -> CGPoint {
        switch state {
        case let .armed(_, pointer):
            return pointer
        case let .active(_, pointer):
            return pointer
        case let .failure(_, pointer):
            return pointer
        }
    }

    static func panelFrame(
        at pointerLocation: CGPoint,
        panelSize: CGSize,
        displayFrames: [CGRect],
        visibleFrames: [CGRect],
        offset: CGPoint = CGPoint(x: 14, y: 12)
    ) -> CGRect {
        let targetScreenRect = CGRect(origin: pointerLocation, size: CGSize(width: 1, height: 1))
        let visibleFrame = matchingVisibleFrame(
            for: targetScreenRect,
            displayFrames: displayFrames,
            visibleFrames: visibleFrames
        )

        let minX = visibleFrame.minX + 8
        let maxX = visibleFrame.maxX - panelSize.width - 8
        let preferredX = pointerLocation.x + offset.x
        let clampedX: CGFloat
        if maxX >= minX {
            clampedX = min(max(preferredX, minX), maxX)
        } else {
            clampedX = visibleFrame.midX - panelSize.width / 2
        }

        let minY = visibleFrame.minY + 8
        let maxY = visibleFrame.maxY - panelSize.height - 8
        let aboveY = pointerLocation.y + offset.y
        let belowY = pointerLocation.y - panelSize.height - offset.y

        let preferredY: CGFloat
        if aboveY <= maxY {
            preferredY = aboveY
        } else if belowY >= minY {
            preferredY = belowY
        } else {
            preferredY = aboveY
        }

        let clampedY: CGFloat
        if maxY >= minY {
            clampedY = min(max(preferredY, minY), maxY)
        } else {
            clampedY = visibleFrame.midY - panelSize.height / 2
        }

        return CGRect(
            origin: CGPoint(x: clampedX, y: clampedY),
            size: panelSize
        ).integral
    }

    private static func matchingVisibleFrame(
        for targetRect: CGRect,
        displayFrames: [CGRect],
        visibleFrames: [CGRect]
    ) -> CGRect {
        for (display, visible) in zip(displayFrames, visibleFrames) {
            if display.contains(targetRect.origin) {
                return visible
            }
        }
        for (display, visible) in zip(displayFrames, visibleFrames) {
            if display.intersects(targetRect) {
                return visible
            }
        }
        var bestVisible = visibleFrames.first ?? targetRect
        var minDistance = CGFloat.greatestFiniteMagnitude
        for (display, visible) in zip(displayFrames, visibleFrames) {
            let dist = distance(from: targetRect.origin, to: display)
            if dist < minDistance {
                minDistance = dist
                bestVisible = visible
            }
        }
        return bestVisible
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}

private struct WindowModifierDragHUDRootView: View {
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let content: WindowModifierDragHUDView

    init(content: WindowModifierDragHUDView) { self.content = content }

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        content
            .environment(\.locale, locale)
            .environment(\.layoutDirection, locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }
}
