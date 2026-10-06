import AppKit
import SwiftUI
import MacToolsPluginKit

// MARK: - App Entry Model

struct QuitAppEntry: Identifiable {
    let id: String
    let displayName: String
    let icon: NSImage?
    let applications: [any QuitAppRunningApplication]
    var isSelected: Bool

    init(group: QuitAppGroup, isSelected: Bool) {
        self.id = group.id
        self.displayName = group.displayName
        self.icon = group.icon
        self.applications = group.applications
        self.isSelected = isSelected
    }
}

// MARK: - View Model

@MainActor
final class QuitAppsViewModel: ObservableObject {
    @Published var entries: [QuitAppEntry] = []
    private let localization: PluginLocalization

    var selectedEntries: [QuitAppEntry] { entries.filter(\.isSelected) }

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
    }

    var confirmTitle: String {
        let count = selectedEntries.count
        guard count > 0 else {
            return localization.string("selection.confirm.quitAll", defaultValue: "退出全部应用")
        }
        return localization.format("selection.confirm.quitCountFormat", defaultValue: "退出 %d 个应用", count)
    }

    func load() {
        apply(groups: QuitAppsApplicationCatalog.currentGroups())
    }

    func load(applications: [any QuitAppRunningApplication]) {
        apply(groups: QuitAppsApplicationCatalog.groups(
            from: applications,
            excludingBundleIdentifier: Bundle.main.bundleIdentifier
        ))
    }

    private func apply(groups: [QuitAppGroup]) {
        let currentSelectionIDs = Set(entries.filter(\.isSelected).map(\.id))
        entries = groups.map { group in
            QuitAppEntry(
                group: group,
                isSelected: currentSelectionIDs.contains(group.id)
            )
        }
    }

    func invertSelection() {
        entries = entries.map { var e = $0; e.isSelected = !e.isSelected; return e }
    }

    func toggleEntry(id: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].isSelected.toggle()
    }

    func confirmQuit(onDone: () -> Void) {
        let targets = selectedEntries.isEmpty ? entries : selectedEntries
        for entry in targets {
            for application in entry.applications where !application.isTerminated {
                application.terminate()
            }
        }
        onDone()
    }
}

// MARK: - Selection Window

@MainActor
final class QuitAppsSelectionWindow: NSPanel {

    private let viewModel: QuitAppsViewModel
    private let localization: PluginLocalization
    private var launchObserver: (any NSObjectProtocol)?
    private var terminateObserver: (any NSObjectProtocol)?
    private var onDismiss: (() -> Void)?
    private var isDismissing = false

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        onDismiss: @escaping () -> Void
    ) {
        self.localization = localization
        self.viewModel = QuitAppsViewModel(localization: localization)
        let size = NSSize(width: 360, height: 460)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.onDismiss = onDismiss
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.roundedMaskImage(size: size, cornerRadius: 16)

        let rootView = QuitAppsSelectionView(
            viewModel: viewModel,
            localization: localization,
            onDismiss: { [weak self] in
                self?.dismiss()
            },
            onLocaleChange: { [weak self] in
                guard let self else { return }
                self.title = localization.string("selection.title", defaultValue: "退出应用")
                self.setAccessibilityLabel(self.title)
            }
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = effectView.bounds
        hostingView.autoresizingMask = [.width, .height]
        effectView.addSubview(hostingView)
        contentView = effectView
        setContentSize(size)

        viewModel.load()
        setupAppObservers()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()

        guard isVisible else { return }
        dismiss()
    }

    func dismiss(notifyingOwner: Bool = true) {
        guard !isDismissing else { return }
        isDismissing = true

        cleanup()
        orderOut(nil)

        let dismissalHandler = onDismiss
        onDismiss = nil
        if notifyingOwner {
            dismissalHandler?()
        }
    }

    private func setupAppObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        launchObserver = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.viewModel.load() }
        }
        terminateObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.viewModel.load() }
        }
    }

    private func cleanup() {
        let nc = NSWorkspace.shared.notificationCenter
        if let obs = launchObserver { nc.removeObserver(obs); launchObserver = nil }
        if let obs = terminateObserver { nc.removeObserver(obs); terminateObserver = nil }
    }

    private static func roundedMaskImage(size: NSSize, cornerRadius: CGFloat) -> NSImage {
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

// MARK: - SwiftUI View

private struct QuitAppsSelectionView: View {
    @ObservedObject var viewModel: QuitAppsViewModel
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let localization: PluginLocalization
    let onDismiss: () -> Void
    let onLocaleChange: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 8)]

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        VStack(spacing: 0) {
            headerView
            Divider().opacity(0.5)
            appGridView
            Divider().opacity(0.5)
            footerView
        }
        .environment(\.locale, locale)
        .environment(
            \.layoutDirection,
            locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
        )
        .onChange(of: runtimeLocale.revision, initial: true) { _, _ in onLocaleChange() }
    }

    // MARK: Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "power")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.red)
            Text(localization.string("selection.title", defaultValue: "退出应用"))
                .font(PluginTypography.pageTitle.font)
                .foregroundStyle(.primary)
            Spacer()
            Text(localization.format(
                "selection.appCountFormat",
                defaultValue: "%d 个应用",
                viewModel.entries.count
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !viewModel.selectedEntries.isEmpty {
                Button(action: { viewModel.invertSelection() }) {
                    Text(localization.string("selection.invert", defaultValue: "反选"))
                        .font(PluginTypography.control.font)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: App Grid

    private var appGridView: some View {
        ScrollView {
            if viewModel.entries.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 60)
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(localization.string("selection.empty", defaultValue: "没有正在运行的应用"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 60)
                }
                .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(viewModel.entries) { entry in
                        AppIconCell(entry: entry) {
                            viewModel.toggleEntry(id: entry.id)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Footer

    private var footerView: some View {
        VStack(spacing: 6) {
            Button(action: {
                viewModel.confirmQuit(onDone: onDismiss)
            }) {
                Text(viewModel.confirmTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.red)
            .disabled(viewModel.entries.isEmpty)

            Button(action: onDismiss) {
                Text(localization.string("selection.cancel", defaultValue: "取消"))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

// MARK: - App Icon Cell

private struct AppIconCell: View {
    let entry: QuitAppEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let icon = entry.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 46, height: 46)
                        } else {
                            Image(systemName: "app.fill")
                                .resizable()
                                .frame(width: 46, height: 46)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                entry.isSelected ? Color.red : Color.clear,
                                lineWidth: 2
                            )
                    )

                    if entry.isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white, .red)
                            .offset(x: 5, y: -5)
                    }
                }

                Text(entry.displayName)
                    .font(PluginTypography.detail.font)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(entry.isSelected ? Color.red : Color.primary)
                    .frame(width: 68)
                    .help(entry.displayName)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(entry.isSelected ? Color.red.opacity(0.08) : Color.clear)
        )
    }
}
