import AppKit
import Combine
import MacToolsPluginKit
import SwiftUI

enum ClipboardCaptureSuppressionMode: Equatable, Sendable {
    case ignoreNextCopy
    case privateCopy
}

enum ClipboardCaptureSuppressionEvent: Equatable, Sendable {
    case armed(mode: ClipboardCaptureSuppressionMode, timeout: TimeInterval)
    case consumed(mode: ClipboardCaptureSuppressionMode)
    case expired(mode: ClipboardCaptureSuppressionMode)
    case cancelled(mode: ClipboardCaptureSuppressionMode)
}

@MainActor
protocol ClipboardPrivacyHUDPresenting: AnyObject {
    func handleSuppressionEvent(_ event: ClipboardCaptureSuppressionEvent)
    func showSuccess(_ message: String)
    func showFailure(_ message: String)
    func showSuccess(localizedMessage: @escaping () -> String)
    func showFailure(localizedMessage: @escaping () -> String)
    func dismiss()
}

extension ClipboardPrivacyHUDPresenting {
    func showSuccess(localizedMessage: @escaping () -> String) { showSuccess(localizedMessage()) }
    func showFailure(localizedMessage: @escaping () -> String) { showFailure(localizedMessage()) }
}

struct ClipboardPrivacyHUDContent: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case neutral
        case success
        case failure
    }

    let title: String
    let systemImage: String
    let tone: Tone

    static func armed(secondsRemaining: Int, localization: PluginLocalization) -> Self {
        Self(
            title: localization.format(
                "hud.ignoreNext.armed",
                defaultValue: "下次复制不会保存 · %d 秒",
                max(0, secondsRemaining)
            ),
            systemImage: "eye.slash.fill",
            tone: .neutral
        )
    }

    static func ignored(localization: PluginLocalization) -> Self {
        Self(
            title: localization.string("hud.ignoreNext.consumed", defaultValue: "已忽略此次复制"),
            systemImage: "eye.slash.fill",
            tone: .success
        )
    }

    static func privateCopySucceeded(localization: PluginLocalization) -> Self {
        Self(
            title: localization.string("hud.privateCopy.succeeded", defaultValue: "已私密复制"),
            systemImage: "checkmark.shield.fill",
            tone: .success
        )
    }

    static func ignoreExpired(localization: PluginLocalization) -> Self {
        Self(
            title: localization.string("hud.ignoreNext.expired", defaultValue: "忽略已取消"),
            systemImage: "clock.badge.xmark",
            tone: .neutral
        )
    }

    static func failure(_ message: String) -> Self {
        Self(title: message, systemImage: "exclamationmark.triangle.fill", tone: .failure)
    }

    static func success(_ message: String) -> Self {
        Self(title: message, systemImage: "checkmark.circle.fill", tone: .success)
    }
}

@MainActor
final class ClipboardPrivacyHUDController: ClipboardPrivacyHUDPresenting {
    static let panelIdentifier = NSUserInterfaceItemIdentifier("mactools.clipboard-history.privacy-hud")

    private let transientDuration: Duration
    private let failureDuration: Duration
    private let localization: PluginLocalization
    private let systemUptime: () -> TimeInterval
    private let screens: () -> [NSScreen]
    private let mouseLocation: () -> NSPoint
    private let announce: (String) -> Void

    private var panel: ClipboardPrivacyHUDPanel?
    private var hostingView: NSHostingView<ClipboardPrivacyHUDRootView>?
    private var localeSubscription: AnyCancellable?
    private var contentProvider: (() -> ClipboardPrivacyHUDContent)?
    private var dismissTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var presentationGeneration: UInt64 = 0

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        transientDuration: Duration = .milliseconds(1_200),
        failureDuration: Duration = .milliseconds(1_800),
        systemUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        screens: @escaping () -> [NSScreen] = { NSScreen.screens },
        mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
        announce: @escaping (String) -> Void = { title in
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: title,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    ) {
        self.localization = localization
        self.transientDuration = transientDuration
        self.failureDuration = failureDuration
        self.systemUptime = systemUptime
        self.screens = screens
        self.mouseLocation = mouseLocation
        self.announce = announce
        localeSubscription = PluginRuntimeLocalization.source.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshLocalization() }
        }
    }

    func handleSuppressionEvent(_ event: ClipboardCaptureSuppressionEvent) {
        switch event {
        case let .armed(mode, timeout):
            switch mode {
            case .ignoreNextCopy:
                showCountdown(timeout: timeout)
            case .privateCopy:
                dismiss()
            }
        case let .consumed(mode):
            showTransient(contentProvider: { [localization] in
                mode == .privateCopy
                    ? .privateCopySucceeded(localization: localization)
                    : .ignored(localization: localization)
            })
        case let .expired(mode):
            if mode == .privateCopy {
                showTransient(contentProvider: { [localization] in
                    .failure(localization.string("hud.privateCopy.failed", defaultValue: "私密复制失败"))
                }, duration: failureDuration)
            } else {
                showTransient(contentProvider: { [localization] in .ignoreExpired(localization: localization) })
            }
        case let .cancelled(mode):
            if mode == .privateCopy {
                showTransient(contentProvider: { [localization] in
                    .failure(localization.string("hud.privateCopy.failed", defaultValue: "私密复制失败"))
                }, duration: failureDuration)
            } else {
                dismiss()
            }
        }
    }

    func showFailure(_ message: String) {
        showTransient(.failure(message), duration: failureDuration)
    }

    func showSuccess(_ message: String) {
        showTransient(.success(message))
    }

    func showFailure(localizedMessage: @escaping () -> String) {
        showTransient(contentProvider: { .failure(localizedMessage()) }, duration: failureDuration)
    }

    func showSuccess(localizedMessage: @escaping () -> String) {
        showTransient(contentProvider: { .success(localizedMessage()) })
    }

    func dismiss() {
        presentationGeneration &+= 1
        dismissTask?.cancel()
        dismissTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        contentProvider = nil
        panel?.orderOut(nil)
    }

    private func showCountdown(timeout: TimeInterval) {
        beginPresentation()
        let generation = presentationGeneration
        let deadline = systemUptime() + max(0, timeout)
        var displayedSeconds = max(1, Int(ceil(timeout)))
        contentProvider = { [localization] in .armed(secondsRemaining: displayedSeconds, localization: localization) }
        present(content: .armed(secondsRemaining: displayedSeconds, localization: localization))

        countdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled,
                      let self,
                      self.presentationGeneration == generation else {
                    return
                }
                let remaining = max(0, Int(ceil(deadline - self.systemUptime())))
                if remaining != displayedSeconds {
                    displayedSeconds = remaining
                    self.updateVisibleContent(
                        .armed(secondsRemaining: remaining, localization: self.localization)
                    )
                }
                if remaining == 0 {
                    return
                }
            }
        }
    }

    private func showTransient(
        _ content: ClipboardPrivacyHUDContent,
        duration: Duration? = nil
    ) {
        showTransient(contentProvider: { content }, duration: duration)
    }

    private func showTransient(
        contentProvider: @escaping () -> ClipboardPrivacyHUDContent,
        duration: Duration? = nil
    ) {
        beginPresentation()
        self.contentProvider = contentProvider
        present(content: contentProvider())
        let generation = presentationGeneration
        let duration = duration ?? transientDuration
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled,
                  let self,
                  self.presentationGeneration == generation else {
                return
            }
            self.dismiss()
        }
    }

    private func beginPresentation() {
        presentationGeneration &+= 1
        dismissTask?.cancel()
        dismissTask = nil
        countdownTask?.cancel()
        countdownTask = nil
    }

    private func present(content: ClipboardPrivacyHUDContent) {
        let panel = panel ?? Self.makePanel()
        self.panel = panel
        let rootView = ClipboardPrivacyHUDRootView(content: content)
        let hostingView: NSHostingView<ClipboardPrivacyHUDRootView>
        if let existing = self.hostingView {
            hostingView = existing
            hostingView.rootView = rootView
        } else {
            hostingView = NSHostingView(rootView: rootView)
            self.hostingView = hostingView
            panel.contentView = hostingView
        }

        let frame = panelFrame(on: targetScreen(), content: content)
        panel.setFrame(frame, display: true)
        panel.title = content.title
        panel.setAccessibilityLabel(content.title)
        let restoration = PluginPresentationSafety.prepareForWindowOrdering(
            panel,
            windows: NSApp.windows,
            restoringTextEditingIn: NSApp.isActive ? NSApp.keyWindow : nil
        )
        panel.orderFrontRegardless()
        restoration?.restore()
        announce(content.title)
    }

    private func updateVisibleContent(_ content: ClipboardPrivacyHUDContent) {
        guard let panel, panel.isVisible, let hostingView else { return }
        hostingView.rootView = ClipboardPrivacyHUDRootView(content: content)
        panel.title = content.title
        panel.setAccessibilityLabel(content.title)
    }

    private func refreshLocalization() {
        guard let panel, panel.isVisible, let contentProvider else { return }
        let content = contentProvider()
        updateVisibleContent(content)
        let size = panelFrame(on: panel.screen, content: content).size
        var frame = NSRect(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
        if let visibleFrame = panel.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
        }
        panel.setFrame(frame, display: true)
    }

    private func targetScreen() -> NSScreen? {
        let availableScreens = screens()
        let pointer = mouseLocation()
        return availableScreens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
            ?? availableScreens.first
    }

    private func panelFrame(
        on screen: NSScreen?,
        content: ClipboardPrivacyHUDContent
    ) -> NSRect {
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let textWidth = ceil((content.title as NSString).size(withAttributes: [.font: font]).width)
        let width = min(max(textWidth + 76, 210), max(210, visibleFrame.width - 24))
        let size = NSSize(width: width, height: 50)
        return NSRect(
            x: (visibleFrame.midX - size.width / 2).rounded(),
            y: (visibleFrame.maxY - size.height - 48).rounded(),
            width: size.width.rounded(.up),
            height: size.height
        )
    }

    static func makePanel() -> ClipboardPrivacyHUDPanel {
        let panel = ClipboardPrivacyHUDPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = panelIdentifier
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}

@MainActor
final class ClipboardPrivacyHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ClipboardPrivacyHUDView: View {
    let content: ClipboardPrivacyHUDContent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: content.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
            Text(content.title)
                .font(PluginTypography.sectionTitle.font)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            PluginFloatingPanelSurface(
                shape: .roundedRectangle(cornerRadius: 13)
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(content.title)
    }

    private var iconColor: Color {
        switch content.tone {
        case .neutral:
            .secondary
        case .success:
            .green
        case .failure:
            .orange
        }
    }
}

private struct ClipboardPrivacyHUDRootView: View {
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let content: ClipboardPrivacyHUDContent

    init(content: ClipboardPrivacyHUDContent) { self.content = content }

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        ClipboardPrivacyHUDView(content: content)
            .environment(\.locale, locale)
            .environment(\.layoutDirection, locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }
}
