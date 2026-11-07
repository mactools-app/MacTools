import AppKit
import SwiftUI
import MacToolsPluginKit

@MainActor
final class QuitProtectionFeedback {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private struct Indicator: View {
        let name: String
        let icon: NSImage?
        let localization: PluginLocalization
        let state: QuitProtectionSession.Feedback

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source

        var message: String {
            let key: String
            switch state {
            case .holding: key = "Hold ⌘Q to quit"
            case .ready: key = "Release Q to quit"
            case .doublePress: key = "Press ⌘Q again to quit"
            case .chromeUnavailable: key = "Couldn’t quit Chrome. Use Chrome’s Quit menu."
            }
            return localization.string(key, defaultValue: key)
        }

        var body: some View {
            let _ = runtimeLocale.revision
            let locale = runtimeLocale.locale
            HStack(spacing: 10) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(PluginTypography.pageTitle.font)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(message)
                        .font(PluginTypography.sectionTitle.font)
                        .lineLimit(2)
                    Text(name)
                        .font(PluginTypography.caption.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    switch state {
                    case let .holding(duration, deadline):
                        TimelineView(.animation(minimumInterval: reduceMotion ? 0.15 : 1.0 / 30)) { _ in
                            let remaining = ContinuousClock.now.duration(to: deadline)
                            progress(duration > .zero ? min(1, max(0, 1 - remaining / duration)) : 1)
                        }
                    case .ready:
                        progress(1)
                    case .doublePress, .chromeUnavailable:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(width: 282, height: 68)
            .background {
                PluginFloatingPanelSurface(shape: .roundedRectangle(cornerRadius: 14))
            }
            .accessibilityElement(children: .combine)
            .environment(\.locale, locale)
            .environment(\.layoutDirection, locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
        }

        private func progress(_ value: Double) -> some View {
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .controlSize(.mini)
        }
    }

    private var panel: Panel?
    private var dismiss: Task<Void, Never>?

    func show(for app: NSRunningApplication, localization: PluginLocalization, state: QuitProtectionSession.Feedback) {
        dismiss?.cancel()
        dismiss = nil
        let dismissAt: ContinuousClock.Instant?
        switch state {
        case let .doublePress(deadline): dismissAt = deadline
        case .chromeUnavailable: dismissAt = .now + .seconds(4)
        default: dismissAt = nil
        }
        if let deadline = dismissAt {
            guard deadline > .now else {
                hide()
                return
            }
            dismiss = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                self?.hide()
            }
        }

        let indicator = Indicator(
            name: app.localizedName ?? app.bundleIdentifier ?? "",
            icon: app.icon, localization: localization, state: state
        )
        // The panel leaves keyboard focus in the target app. Announce each
        // instruction once, including when the existing panel becomes ready.
        defer {
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: indicator.message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
        if let hostingView = panel?.contentView as? NSHostingView<Indicator> {
            hostingView.rootView = indicator
            return
        }

        guard let screen = Self.targetScreen(for: app) else { return }
        let hostingView = NSHostingView(rootView: indicator)
        let size = hostingView.fittingSize
        let frame = NSRect(
            x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 42,
            width: size.width, height: size.height
        )
        let panel = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        dismiss?.cancel()
        dismiss = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func targetScreen(for app: NSRunningApplication) -> NSScreen? {
        let screens = NSScreen.screens
        let fallback = NSScreen.main ?? screens.first
        guard screens.count > 1, let primary = screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                  as? [[String: Any]],
              let window = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier
                      && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
              }),
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { return fallback }

        let appKitFrame = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        return screens.compactMap { screen -> (screen: NSScreen, area: CGFloat)? in
            let intersection = screen.frame.intersection(appKitFrame)
            guard !intersection.isEmpty else { return nil }
            return (screen, intersection.width * intersection.height)
        }.max(by: { $0.area < $1.area })?.screen ?? fallback
    }
}
