import AppKit
import SwiftUI
import MacToolsPluginKit

// MARK: - Window

@MainActor
final class XcodeCleanConfirmWindow: NSPanel {

    private let viewModel: XcodeCleanConfirmViewModel
    private var onDismiss: (() -> Void)?

    init(
        candidates: [XcodeCleanCandidate],
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        onConfirm: @escaping (Set<XcodeCleanCandidate.ID>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let size = NSSize(width: 480, height: 540)
        self.viewModel = XcodeCleanConfirmViewModel(candidates: candidates, localization: localization)

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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.roundedMaskImage(size: size, cornerRadius: 16)

        let rootView = XcodeCleanConfirmView(
            viewModel: viewModel,
            localization: localization,
            onConfirm: { [weak self] selectedIDs in
                onConfirm(selectedIDs)
                self?.orderOut(nil)
                self?.onDismiss?()
            },
            onCancel: { [weak self] in
                onCancel()
                self?.orderOut(nil)
                self?.onDismiss?()
            },
            onLocaleChange: { [weak self] in
                guard let self else { return }
                self.title = localization.string("confirm.title", defaultValue: "确认清理 Xcode 缓存")
                self.setAccessibilityLabel(self.title)
            }
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = effectView.bounds
        hostingView.autoresizingMask = [.width, .height]
        effectView.addSubview(hostingView)
        contentView = effectView
        setContentSize(size)
    }

    func attachDismissHandler(_ handler: @escaping () -> Void) {
        onDismiss = handler
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
        onDismiss?()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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

// MARK: - View Model

@MainActor
final class XcodeCleanConfirmViewModel: ObservableObject {
    struct Section: Identifiable {
        let id: XcodeCleanCategory
        let localization: PluginLocalization
        let candidates: [XcodeCleanCandidate]

        var title: String { id.title(localization: localization) }
    }

    @Published private(set) var sections: [Section]
    @Published private(set) var selectedIDs: Set<XcodeCleanCandidate.ID>

    private let allCleanableIDs: Set<XcodeCleanCandidate.ID>

    init(
        candidates: [XcodeCleanCandidate],
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        let cleanable = candidates.filter { $0.safety.isCleanable }
        self.allCleanableIDs = Set(cleanable.map(\.id))
        self.selectedIDs = self.allCleanableIDs

        var grouped: [XcodeCleanCategory: [XcodeCleanCandidate]] = [:]
        for candidate in cleanable {
            grouped[candidate.category, default: []].append(candidate)
        }
        self.sections = XcodeCleanCategory.allCases.compactMap { category in
            guard let items = grouped[category], !items.isEmpty else { return nil }
            return Section(
                id: category,
                localization: localization,
                candidates: items.sorted { $0.sizeBytes > $1.sizeBytes }
            )
        }
    }

    var totalCount: Int { allCleanableIDs.count }

    var selectedCount: Int { selectedIDs.count }

    var selectedSizeBytes: Int64 {
        sections.reduce(Int64(0)) { partial, section in
            partial + section.candidates.reduce(Int64(0)) { sum, candidate in
                selectedIDs.contains(candidate.id) ? sum + max(candidate.sizeBytes, 0) : sum
            }
        }
    }

    var allSelected: Bool {
        selectedIDs == allCleanableIDs
    }

    func toggle(id: XcodeCleanCandidate.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func setSection(_ category: XcodeCleanCategory, selected: Bool) {
        guard let section = sections.first(where: { $0.id == category }) else { return }
        for candidate in section.candidates {
            if selected {
                selectedIDs.insert(candidate.id)
            } else {
                selectedIDs.remove(candidate.id)
            }
        }
    }

    func sectionState(_ category: XcodeCleanCategory) -> SectionSelectionState {
        guard let section = sections.first(where: { $0.id == category }) else { return .none }
        let selected = section.candidates.filter { selectedIDs.contains($0.id) }.count
        if selected == 0 { return .none }
        if selected == section.candidates.count { return .all }
        return .partial
    }

    func toggleAll() {
        if allSelected {
            selectedIDs.removeAll()
        } else {
            selectedIDs = allCleanableIDs
        }
    }
}

enum SectionSelectionState {
    case none
    case partial
    case all
}

// MARK: - SwiftUI View

private struct XcodeCleanConfirmView: View {
    @ObservedObject var viewModel: XcodeCleanConfirmViewModel
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let localization: PluginLocalization
    let onConfirm: (Set<XcodeCleanCandidate.ID>) -> Void
    let onCancel: () -> Void
    let onLocaleChange: () -> Void

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            candidateList
            Divider().opacity(0.5)
            footer
        }
        .environment(\.locale, locale)
        .environment(
            \.layoutDirection,
            locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
        )
        .onChange(of: runtimeLocale.revision, initial: true) { _, _ in onLocaleChange() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemBlue))

            VStack(alignment: .leading, spacing: 2) {
                Text(localization.string("confirm.title", defaultValue: "确认清理 Xcode 缓存"))
                    .font(PluginTypography.pageTitle.font)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: { viewModel.toggleAll() }) {
                Text(viewModel.allSelected
                    ? localization.string("confirm.action.deselectAll", defaultValue: "全不选")
                    : localization.string("confirm.action.selectAll", defaultValue: "全选")
                )
                    .font(PluginTypography.control.font)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headerSubtitle: String {
        if viewModel.totalCount == 0 {
            return localization.string("confirm.noItems", defaultValue: "没有可清理项目")
        }
        return localization.format(
            "confirm.subtitle.selected",
            defaultValue: "已选 %d / %d 项 · %@",
            viewModel.selectedCount,
            viewModel.totalCount,
            byteText(viewModel.selectedSizeBytes)
        )
    }

    private var candidateList: some View {
        ScrollView {
            if viewModel.sections.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.sections) { section in
                        sectionHeader(for: section)
                        ForEach(section.candidates) { candidate in
                            candidateRow(candidate)
                                .padding(.leading, 22)
                            Divider().opacity(0.3)
                                .padding(.leading, 22)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 60)
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(localization.string("confirm.noItems", defaultValue: "没有可清理项目"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionHeader(for section: XcodeCleanConfirmViewModel.Section) -> some View {
        let state = viewModel.sectionState(section.id)
        return HStack(spacing: 8) {
            Button(action: {
                viewModel.setSection(section.id, selected: state != .all)
            }) {
                Image(systemName: sectionToggleIcon(state))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)

            Text(section.title)
                .font(PluginTypography.sectionTitle.font)
                .foregroundStyle(.secondary)

            Spacer()

            Text(itemCountText(section.candidates.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func sectionToggleIcon(_ state: SectionSelectionState) -> String {
        switch state {
        case .all: return "checkmark.square.fill"
        case .partial: return "minus.square.fill"
        case .none: return "square"
        }
    }

    private func candidateRow(_ candidate: XcodeCleanCandidate) -> some View {
        Button(action: { viewModel.toggle(id: candidate.id) }) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: viewModel.selectedIDs.contains(candidate.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(viewModel.selectedIDs.contains(candidate.id) ? Color.accentColor : Color.secondary)
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text((candidate.path as NSString).lastPathComponent)
                        .font(PluginTypography.body.font)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(candidate.path)
                        .font(PluginTypography.detail.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 8)

                Text(byteText(candidate.sizeBytes))
                    .font(PluginTypography.value.font)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Button(action: {
                onConfirm(viewModel.selectedIDs)
            }) {
                Text(confirmTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.selectedCount == 0)

            Button(action: onCancel) {
                Text(localization.string("confirm.action.cancel", defaultValue: "取消"))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var confirmTitle: String {
        if viewModel.selectedCount == 0 {
            return localization.string("confirm.action.empty", defaultValue: "请选择要清理的项目")
        }
        return localization.format(
            "confirm.action.confirm",
            defaultValue: "清理 %d 项 · %@",
            viewModel.selectedCount,
            byteText(viewModel.selectedSizeBytes)
        )
    }

    private func byteText(_ bytes: Int64) -> String {
        XcodeCleanByteFormatter.string(fromByteCount: bytes)
    }

    private func itemCountText(_ count: Int) -> String {
        localization.format("confirm.itemCount", defaultValue: "%d 项", count)
    }
}
