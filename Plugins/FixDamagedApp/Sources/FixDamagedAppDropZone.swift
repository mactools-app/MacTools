import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

// MARK: - View Model

@MainActor
final class DropZoneViewModel: ObservableObject {

    enum Phase: Equatable {
        case waiting
        case running
        case success(appName: String)
        case failure(message: String)
    }

    @Published private(set) var phase: Phase = .waiting

    /// True after a drop is accepted but before the async URL load finishes.
    /// Prevents `dismissIfIdle` from closing the panel too early.
    private var isDropPending = false

    private let localization: PluginLocalization
    private let onComplete: (String, Bool, String?) -> Void
    private let onDismiss: () -> Void

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        onComplete: @escaping (String, Bool, String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.localization = localization
        self.onComplete = onComplete
        self.onDismiss = onDismiss
    }

    func beginDrop() {
        isDropPending = true
    }

    func cancelDropPending() {
        isDropPending = false
    }

    func dropApp(url: URL) {
        isDropPending = false
        guard phase == .waiting else { return }
        let appName = url.deletingPathExtension().lastPathComponent
        let appPath = url.path
        phase = .running
        Task {
            do {
                try await runQuarantineRemoval(appPath: appPath, localization: localization)
                phase = .success(appName: appName)
                onComplete(appName, true, nil)
                try? await Task.sleep(for: .seconds(1.5))
                onDismiss()
            } catch {
                let msg = error.localizedDescription
                phase = .failure(message: msg)
                onComplete(appName, false, msg)
            }
        }
    }

    func dismissIfIdle() {
        guard phase == .waiting, !isDropPending else { return }
        onDismiss()
    }

    func dismiss() {
        onDismiss()
    }
}

// MARK: - Drop Zone View

struct FixDropZoneView: View {
    @ObservedObject var viewModel: DropZoneViewModel
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let localization: PluginLocalization
    let onLocaleChange: () -> Void
    @State private var isTargeted = false

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.primary.opacity(0.1),
                    lineWidth: isTargeted ? 2 : 1
                )

            content
                .padding(20)
        }
        .frame(width: 280, height: 160)
        .background(Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .environment(\.locale, locale)
        .environment(
            \.layoutDirection,
            locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
        )
        .onChange(of: runtimeLocale.revision, initial: true) { _, _ in onLocaleChange() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .waiting:
            VStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.dotted")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                    .scaleEffect(isTargeted ? 1.15 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isTargeted)

                Text(localization.string("dropZone.waiting", defaultValue: "将 .app 文件拖到此处以修复"))
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        case .running:
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.2)

                Text(localization.string("dropZone.running", defaultValue: "修复中…"))
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .foregroundStyle(.secondary)
            }

        case .success(let name):
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)

                Text(localization.format("dropZone.successFormat", defaultValue: "已修复：%@", name))
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

        case .failure(let message):
            VStack(spacing: 10) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)

                Text(message)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                Button(localization.string("dropZone.close", defaultValue: "关闭")) {
                    viewModel.dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @MainActor
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // Mark pending before the async URL load finishes so the mouseUp monitor does not
        // misclassify the panel as idle and close it.
        viewModel.beginDrop()
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard
                let data,
                let url = URL(dataRepresentation: data, relativeTo: nil),
                url.pathExtension.lowercased() == "app"
            else {
                Task { @MainActor in viewModel.cancelDropPending() }
                return
            }
            Task { @MainActor in
                viewModel.dropApp(url: url)
            }
        }
        return true
    }
}

// MARK: - Panel

@MainActor
final class FixDamagedAppDropZonePanel: NSPanel {

    private let viewModel: DropZoneViewModel
    private let localization: PluginLocalization

    init(
        viewModel: DropZoneViewModel,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.viewModel = viewModel
        self.localization = localization
        let size = NSSize(width: 280, height: 160)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true

        // NSVisualEffectView is the correct host for the glass effect. `.behindWindow` plus a
        // rounded `maskImage` is more reliable than `layer.cornerRadius` for this borderless panel.
        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.makeRoundedMaskImage(size: size, cornerRadius: 20)

        // The SwiftUI layer draws only the border and content over the transparent effect view.
        let hostingView = NSHostingView(rootView: FixDropZoneView(
            viewModel: viewModel,
            localization: localization,
            onLocaleChange: { [weak self] in
                guard let self else { return }
                self.title = localization.string("metadata.title", defaultValue: "修复损坏应用")
                self.setAccessibilityLabel(self.title)
            }
        ))
        hostingView.frame = effectView.bounds
        hostingView.autoresizingMask = [.width, .height]
        effectView.addSubview(hostingView)

        contentView = effectView
        setContentSize(size)
    }

    func dismissIfIdle() {
        viewModel.dismissIfIdle()
    }

    /// Builds an `NSVisualEffectView.maskImage`: a black rounded rectangle whose alpha controls visibility.
    private static func makeRoundedMaskImage(size: NSSize, cornerRadius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
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
