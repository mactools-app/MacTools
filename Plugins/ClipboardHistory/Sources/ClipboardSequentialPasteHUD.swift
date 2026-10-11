import AppKit
import MacToolsPluginKit
import SwiftUI

struct ClipboardSequentialPasteHUDContent: Equatable, Sendable {
    let source: ClipboardSequentialPasteSource
    let justPastedTitle: String?
    let nextTitle: String?
    let justPastedPreviewImageData: Data?
    let nextPreviewImageData: Data?
    let position: Int
    let totalCount: Int
    let hidesPreview: Bool
    let isComplete: Bool
}

@MainActor
final class ClipboardSequentialPasteHUDController {
    static let panelIdentifier = NSUserInterfaceItemIdentifier(
        "mactools.clipboard-history.sequential-paste-hud"
    )

    var onPasteNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSkip: (() -> Void)?
    var onRestart: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

    private let localization: PluginLocalization
    private var panel: ClipboardSequentialPasteHUDPanel?
    private var hostingView: NSHostingView<ClipboardSequentialPasteHUDRootView>?
    private var dismissTask: Task<Void, Never>?
    private var presentationGeneration: UInt64 = 0

    init(localization: PluginLocalization) {
        self.localization = localization
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(
        _ content: ClipboardSequentialPasteHUDContent,
        dismissAfter interval: TimeInterval?
    ) {
        presentationGeneration &+= 1
        dismissTask?.cancel()
        dismissTask = nil

        let panel = panel ?? makePanel()
        self.panel = panel
        updateHostedContent(content)

        if !panel.isVisible {
            position(panel)
        }
        let restoration = PluginPresentationSafety.prepareForWindowOrdering(
            panel,
            windows: NSApp.windows,
            restoringTextEditingIn: NSApp.isActive ? NSApp.keyWindow : nil
        )
        panel.orderFrontRegardless()
        restoration?.restore()

        guard let interval else { return }
        let generation = presentationGeneration
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled,
                  let self,
                  self.presentationGeneration == generation else { return }
            self.dismiss()
        }
    }

    func updateContentIfVisible(_ content: ClipboardSequentialPasteHUDContent) {
        guard isVisible else { return }
        updateHostedContent(content)
    }

    private func updateHostedContent(_ content: ClipboardSequentialPasteHUDContent) {
        refreshPanelLocalization()
        let hud = ClipboardSequentialPasteHUDView(
            content: content,
            localization: localization,
            onPasteNext: { [weak self] in self?.onPasteNext?() },
            onPrevious: { [weak self] in self?.onPrevious?() },
            onSkip: { [weak self] in self?.onSkip?() },
            onRestart: { [weak self] in self?.onRestart?() },
            onCancel: { [weak self] in self?.onCancel?() },
            onClose: { [weak self] in
                self?.dismiss()
                self?.onClose?()
            }
        )
        let view = ClipboardSequentialPasteHUDRootView(
            hud: hud,
            onLocaleChange: { [weak self] in self?.refreshPanelLocalization() }
        )
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hostingView = NSHostingView(rootView: view)
            self.hostingView = hostingView
            panel?.contentView = hostingView
        }
    }

    private func refreshPanelLocalization() {
        guard let panel else { return }
        panel.title = localization.string("hud.queue.explicit", defaultValue: "Paste Queue")
        panel.setAccessibilityLabel(panel.title)
    }

    func showCompletion(
        source: ClipboardSequentialPasteSource,
        dismissAfter interval: TimeInterval?
    ) {
        let content = ClipboardSequentialPasteHUDContent(
            source: source,
            justPastedTitle: nil,
            nextTitle: nil,
            justPastedPreviewImageData: nil,
            nextPreviewImageData: nil,
            position: 0,
            totalCount: 0,
            hidesPreview: false,
            isComplete: true
        )
        show(content, dismissAfter: interval)
    }

    func dismiss() {
        presentationGeneration &+= 1
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> ClipboardSequentialPasteHUDPanel {
        let panel = ClipboardSequentialPasteHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 142),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = Self.panelIdentifier
        panel.title = localization.string("hud.queue.explicit", defaultValue: "Paste Queue")
        panel.setAccessibilityLabel(panel.title)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setFrameAutosaveName("MacTools.ClipboardHistory.SequentialPasteHUD")
        return panel
    }

    private func position(_ panel: NSPanel) {
        if panel.setFrameUsingName("MacTools.ClipboardHistory.SequentialPasteHUD") {
            let screen = NSScreen.screens.max { lhs, rhs in
                let lhsIntersection = lhs.visibleFrame.intersection(panel.frame)
                let rhsIntersection = rhs.visibleFrame.intersection(panel.frame)
                return lhsIntersection.width * lhsIntersection.height
                    < rhsIntersection.width * rhsIntersection.height
            } ?? NSScreen.main
            if let visibleFrame = screen?.visibleFrame {
                panel.setFrame(Self.clampedFrame(panel.frame, to: visibleFrame), display: false)
            }
            return
        }
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - panel.frame.width - 24,
            y: visibleFrame.maxY - panel.frame.height - 52
        ))
    }

    nonisolated static func clampedFrame(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        var result = frame
        result.size.width = min(result.width, visibleFrame.width)
        result.size.height = min(result.height, visibleFrame.height)
        result.origin.x = min(max(result.minX, visibleFrame.minX), visibleFrame.maxX - result.width)
        result.origin.y = min(max(result.minY, visibleFrame.minY), visibleFrame.maxY - result.height)
        return result
    }
}

@MainActor
final class ClipboardSequentialPasteHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ClipboardSequentialPasteHUDRootView: View {
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let hud: ClipboardSequentialPasteHUDView
    let onLocaleChange: () -> Void

    init(hud: ClipboardSequentialPasteHUDView, onLocaleChange: @escaping () -> Void) {
        self.hud = hud
        self.onLocaleChange = onLocaleChange
    }

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        hud
            .environment(\.locale, locale)
            .environment(
                \.layoutDirection,
                locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
            )
            .onChange(of: runtimeLocale.revision) { _, _ in onLocaleChange() }
    }
}

struct ClipboardSequentialPasteHUDView: View {
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency
    @Environment(\.locale) private var locale
    let content: ClipboardSequentialPasteHUDContent
    let localization: PluginLocalization
    let onPasteNext: () -> Void
    let onPrevious: () -> Void
    let onSkip: () -> Void
    let onRestart: () -> Void
    let onCancel: () -> Void
    let onClose: () -> Void

    var body: some View {
        // Refresh runtime copy when the inherited locale changes without resetting preview state.
        let _ = locale
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(
                    content.source == .explicitQueue
                        ? localization.string("hud.queue.explicit", defaultValue: "Paste Queue")
                        : localization.string("hud.queue.recent", defaultValue: "Recent History"),
                    systemImage: "list.number"
                )
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                .foregroundStyle(.secondary)
                Spacer()
                Text(progressTitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(progressTitle)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(localization.string("common.close", defaultValue: "Close"))
                .accessibilityLabel(localization.string("common.close", defaultValue: "Close"))
            }

            if content.isComplete {
                Label(
                    localization.string("hud.queue.complete", defaultValue: "Queue Complete"),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } else if !content.hidesPreview {
                HStack(alignment: .top, spacing: 10) {
                    ClipboardSequentialPasteHUDPreview(
                        data: content.justPastedPreviewImageData ?? content.nextPreviewImageData,
                        localization: localization
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        if let justPastedTitle = content.justPastedTitle {
                            Text(localization.string("hud.queue.pasted", defaultValue: "Pasted"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(justPastedTitle).lineLimit(1)
                        }
                        if let nextTitle = content.nextTitle {
                            Text(localization.string("hud.queue.next", defaultValue: "Next") + ": " + nextTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if !content.isComplete {
                HStack(spacing: 8) {
                    hudButton(
                        "arrow.backward",
                        help: localization.string("hud.queue.previous", defaultValue: "Previous"),
                        action: onPrevious
                    )
                    hudButton(
                        "forward.end",
                        help: localization.string("hud.queue.skip", defaultValue: "Skip"),
                        action: onSkip
                    )
                    Button(action: onPasteNext) {
                        Label(
                            localization.string("hud.queue.pasteNext", defaultValue: "Paste Next"),
                            systemImage: "arrow.forward"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel(localization.string(
                        "hud.queue.pasteNext",
                        defaultValue: "Paste Next"
                    ))
                    Menu {
                        Button(
                            localization.string("hud.queue.restart", defaultValue: "Restart Queue"),
                            action: onRestart
                        )
                        Divider()
                        Button(
                            localization.string("hud.queue.cancel", defaultValue: "Cancel Queue"),
                            role: .destructive,
                            action: onCancel
                        )
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .help(localization.string("common.actions", defaultValue: "Actions"))
                    .accessibilityLabel(localization.string("common.actions", defaultValue: "Actions"))
                }
            }
        }
        .padding(PluginPaletteMetrics.contentPadding)
        .frame(width: 410)
        .frame(minHeight: 118)
        .background {
            ClipboardHistoryWindowSurface(role: .queue, reducesTransparency: reducesTransparency)
        }
        .overlay(alignment: .top) {
            ClipboardSequentialPasteHUDDragRegion(
                accessibilityLabel: localization.string(
                    "panel.drag.help",
                    defaultValue: "Drag to move"
                )
            )
                .frame(width: 72, height: 15)
                .contentShape(Rectangle())
                .overlay {
                    Capsule()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 28, height: 3)
                        .allowsHitTesting(false)
                }
                .help(localization.string("panel.drag.help", defaultValue: "Drag to move"))
        }
    }

    private var progressTitle: String {
        guard content.totalCount > 0 else {
            return localization.string("hud.queue.complete", defaultValue: "Complete")
        }
        return localization.format(
            "hud.queue.progress",
            defaultValue: "%lld of %lld",
            min(content.position, content.totalCount),
            content.totalCount
        )
    }

    private func hudButton(
        _ systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: systemImage) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(help)
            .accessibilityLabel(help)
    }
}

private struct ClipboardSequentialPasteHUDPreview: View {
    let data: Data?
    let localization: PluginLocalization
    @State private var image: NSImage?
    @State private var didFinishLoading = false
    @State private var retryID: UInt = 0

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if data != nil {
                if didFinishLoading {
                    Button { retryID &+= 1 } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "exclamationmark.triangle")
                            Image(systemName: "arrow.clockwise").font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(localization.string("panel.preview.failed", defaultValue: "无法载入预览"))
                    .accessibilityLabel(localization.string("panel.preview.retry", defaultValue: "重试"))
                } else {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(localization.string("panel.preview.loading", defaultValue: "正在载入预览…"))
                }
            }
        }
        .frame(
            width: ClipboardSequentialPasteHUDPreviewLayout.dimension(hasData: data != nil),
            height: ClipboardSequentialPasteHUDPreviewLayout.dimension(hasData: data != nil)
        )
        .background(Color.primary.opacity(data == nil ? 0 : 0.05), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            if data != nil {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
        }
        .task(id: ClipboardPreviewRequestID(key: data, retry: retryID)) {
            image = nil
            didFinishLoading = false
            guard let data else {
                return
            }
            let result = await ClipboardBoundedImagePreviewWork.image(from: data)
            guard !Task.isCancelled else { return }
            image = result
            didFinishLoading = true
        }
    }
}

enum ClipboardSequentialPasteHUDPreviewLayout {
    static let previewDimension: CGFloat = 48

    static func dimension(hasData: Bool) -> CGFloat {
        hasData ? previewDimension : 0
    }
}

@MainActor
private struct ClipboardSequentialPasteHUDDragRegion: NSViewRepresentable {
    let accessibilityLabel: String

    final class DragView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            NSCursor.closedHand.push()
            defer { NSCursor.pop() }
            window.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView {
        let view = DragView(frame: .zero)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.handle)
        view.setAccessibilityLabel(accessibilityLabel)
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) {}
}
