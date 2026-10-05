import AppKit
import SwiftUI
import MacToolsPluginKit

private enum SystemSoftRestartWindowLayout {
    static let size = NSSize(width: 460, height: 390)
    static let horizontalPadding: CGFloat = 32
    static let diagnosticsHeight: CGFloat = 108
}

@MainActor
protocol SystemSoftRestartPresenting: AnyObject {
    var isPresenting: Bool { get }

    func presentConfirmation(
        plan: SystemSoftRestartPlan,
        anchorRect: NSRect?,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    )
    func presentProgress(plan: SystemSoftRestartPlan, anchorRect: NSRect?)
    func update(event: SystemSoftRestartEvent)
    func complete(result: SystemSoftRestartResult)
    func fail(message: String)
    func dismiss()
}

@MainActor
final class SystemSoftRestartWindowPresenter: SystemSoftRestartPresenting {
    private var window: SystemSoftRestartWindow?
    private let localization: PluginLocalization

    init(localization: PluginLocalization) {
        self.localization = localization
    }

    var isPresenting: Bool {
        window?.isVisible == true
    }

    func presentConfirmation(
        plan: SystemSoftRestartPlan,
        anchorRect: NSRect?,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss()
        let viewModel = SystemSoftRestartWindowViewModel(
            plan: plan,
            localization: localization,
            mode: .confirmation
        )
        let window = makeWindow(
            viewModel: viewModel,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
        show(window: window, anchorRect: anchorRect)
    }

    func presentProgress(plan: SystemSoftRestartPlan, anchorRect: NSRect?) {
        dismiss()
        let viewModel = SystemSoftRestartWindowViewModel(
            plan: plan,
            localization: localization,
            mode: .running(.preparing)
        )
        let window = makeWindow(viewModel: viewModel, onConfirm: {}, onCancel: {})
        show(window: window, anchorRect: anchorRect)
    }

    func update(event: SystemSoftRestartEvent) {
        window?.viewModel.update(event: event)
    }

    func complete(result: SystemSoftRestartResult) {
        window?.viewModel.complete(result: result)
    }

    func fail(message: String) {
        window?.viewModel.fail(message: message)
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }

    private func makeWindow(
        viewModel: SystemSoftRestartWindowViewModel,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> SystemSoftRestartWindow {
        let window = SystemSoftRestartWindow(
            viewModel: viewModel,
            localization: localization,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
        window.onDismiss = { [weak self] in
            self?.window = nil
        }
        return window
    }

    private func show(window: SystemSoftRestartWindow, anchorRect: NSRect?) {
        position(window: window, anchorRect: anchorRect)
        PluginPresentationSafety.prepareForWindowOrdering(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func position(window: NSWindow, anchorRect: NSRect?) {
        let anchorScreen = anchorRect.flatMap { anchor in
            NSScreen.screens.first { $0.frame.intersects(anchor) }
        }
        let pointerLocation = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(pointerLocation) }
        let visibleFrame = (anchorScreen ?? pointerScreen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        ))
    }
}

@MainActor
final class SystemSoftRestartWindow: NSPanel {
    let viewModel: SystemSoftRestartWindowViewModel
    var onDismiss: (() -> Void)?

    private var cancelHandler: (() -> Void)?

    init(
        viewModel: SystemSoftRestartWindowViewModel,
        localization: PluginLocalization,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.cancelHandler = onCancel
        let size = SystemSoftRestartWindowLayout.size

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        title = localization.string("window.title", defaultValue: "系统软重启")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .windowBackgroundColor

        let rootView = SystemSoftRestartWindowView(
            viewModel: viewModel,
            localization: localization,
            onConfirm: onConfirm,
            onDismiss: { [weak self] in self?.dismissIfAllowed() },
            onLocaleChange: { [weak self] in
                guard let self else { return }
                self.title = localization.string("window.title", defaultValue: "系统软重启")
                self.setAccessibilityLabel(self.title)
            }
        )
        contentView = NSHostingView(rootView: rootView)
        setContentSize(size)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        dismissIfAllowed()
    }

    override func performClose(_ sender: Any?) {
        dismissIfAllowed()
    }

    private func dismissIfAllowed() {
        guard viewModel.canDismiss else {
            NSSound.beep()
            return
        }
        cancelHandler?()
        cancelHandler = nil
        orderOut(nil)
        onDismiss?()
    }
}

@MainActor
final class SystemSoftRestartWindowViewModel: ObservableObject {
    enum Mode: Equatable {
        case confirmation
        case running(SystemSoftRestartPhase)
        case succeeded(SystemSoftRestartResult)
        case failed(String)
    }

    let plan: SystemSoftRestartPlan
    let localization: PluginLocalization

    @Published var mode: Mode
    @Published var hasSavedWork = false

    init(plan: SystemSoftRestartPlan, localization: PluginLocalization, mode: Mode) {
        self.plan = plan
        self.localization = localization
        self.mode = mode
    }

    var canDismiss: Bool {
        if case .running = mode { return false }
        return true
    }

    @discardableResult
    func confirm() -> Bool {
        guard mode == .confirmation, hasSavedWork else { return false }
        mode = .running(.preparing)
        return true
    }

    func update(event: SystemSoftRestartEvent) {
        guard case .running = mode else { return }
        mode = .running(event.phase)
    }

    func complete(result: SystemSoftRestartResult) {
        mode = .succeeded(result)
    }

    func fail(message: String) {
        mode = .failed(message)
    }

    func phaseText(_ phase: SystemSoftRestartPhase) -> String {
        switch phase {
        case .preparing:
            return localization.string("progress.preparing", defaultValue: "正在准备软重启…")
        case .backingUpDock:
            return localization.string("progress.backingUpDock", defaultValue: "正在备份 Dock 布局…")
        case .restartingServices:
            return localization.string("progress.restartingServices", defaultValue: "正在重启用户服务…")
        case .waitingForServices:
            return localization.string("progress.waitingForServices", defaultValue: "正在等待系统服务恢复…")
        case .reopeningApplications:
            return localization.string("progress.reopeningApplications", defaultValue: "正在重新打开应用…")
        case .restoringDock:
            return localization.string("progress.restoringDock", defaultValue: "正在恢复 Dock 布局…")
        case .completed:
            return localization.string("progress.completed", defaultValue: "系统软重启已完成。")
        }
    }
}

private struct SystemSoftRestartWindowView: View {
    @ObservedObject var viewModel: SystemSoftRestartWindowViewModel
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source

    let localization: PluginLocalization
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    let onLocaleChange: () -> Void

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, SystemSoftRestartWindowLayout.horizontalPadding)
            .padding(.top, 38)
            .padding(.bottom, 26)
            .frame(
                width: SystemSoftRestartWindowLayout.size.width,
                height: SystemSoftRestartWindowLayout.size.height
            )
            .environment(\.locale, locale)
            .environment(
                \.layoutDirection,
                locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
            )
            .onChange(of: runtimeLocale.revision, initial: true) { _, _ in onLocaleChange() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.mode {
        case .confirmation:
            confirmationContent
        case let .running(phase):
            runningContent(phase: phase)
        case let .succeeded(result):
            completionContent(result: result)
        case let .failed(message):
            failureContent(message: message)
        }
    }

    private var confirmationContent: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.13))
                    .frame(width: 66, height: 66)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            VStack(spacing: 8) {
                Text(localization.string("confirm.title", defaultValue: "重启用户服务？"))
                    .font(.title2.weight(.semibold))
                Text(localization.string(
                    "confirm.message",
                    defaultValue: "运行中的应用将立即退出，未保存的内容可能丢失。屏幕和菜单栏可能短暂闪烁。"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            }

            HStack(spacing: 10) {
                summaryBadge(applicationSummary, systemImage: "square.stack.3d.up")
                summaryBadge(dockSummary, systemImage: "dock.rectangle")
            }

            HStack {
                Spacer(minLength: 0)
                Toggle(
                    localization.string("confirm.savedWork", defaultValue: "我已保存当前工作"),
                    isOn: $viewModel.hasSavedWork
                )
                .toggleStyle(.checkbox)
                Spacer(minLength: 0)
            }

            Button {
                if viewModel.confirm() {
                    onConfirm()
                }
            } label: {
                Text(localization.string("confirm.action", defaultValue: "重启用户服务"))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .disabled(!viewModel.hasSavedWork)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func runningContent(phase: SystemSoftRestartPhase) -> some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 68, height: 68)
                ProgressView()
                    .controlSize(.large)
            }
            Text(viewModel.phaseText(phase))
                .font(.title2.weight(.semibold))
            Text(localization.string(
                "progress.message",
                defaultValue: "请保持 MacTools 运行。服务恢复前，部分系统界面可能暂时不可用。"
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
    }

    private func completionContent(result: SystemSoftRestartResult) -> some View {
        VStack(spacing: result.diagnostics.isEmpty ? 18 : 13) {
            ZStack {
                Circle()
                    .fill((result.warningCount == 0 ? Color.green : Color.orange).opacity(0.12))
                    .frame(
                        width: result.diagnostics.isEmpty ? 68 : 58,
                        height: result.diagnostics.isEmpty ? 68 : 58
                    )
                Image(systemName: result.warningCount == 0 ? "checkmark" : "exclamationmark")
                    .font(.system(size: result.diagnostics.isEmpty ? 29 : 25, weight: .bold))
                    .foregroundStyle(result.warningCount == 0 ? .green : .orange)
            }
            Text(localization.string("complete.title", defaultValue: "系统软重启已完成"))
                .font(.title2.weight(.semibold))
            Text(result.warningCount == 0
                ? localization.string(
                    "complete.message",
                    defaultValue: "核心系统界面和应用已恢复，部分后台服务可能仍在继续恢复。"
                )
                : localization.format(
                    "complete.warningFormat",
                    defaultValue: "软重启已完成，但有 %d 项需要留意。",
                    result.warningCount
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if !result.diagnostics.isEmpty {
                diagnosticsView(result.diagnostics)
            }

            Button(localization.string("common.close", defaultValue: "完成"), action: onDismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minWidth: 120)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func diagnosticsView(_ diagnostics: [SystemSoftRestartDiagnostic]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(
                    localization.string("diagnostics.title", defaultValue: "详细信息"),
                    systemImage: "doc.text.magnifyingglass"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button {
                    copyDiagnostics(diagnostics)
                } label: {
                    Label(
                        localization.string("diagnostics.copy", defaultValue: "复制"),
                        systemImage: "doc.on.doc"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(localization.string("diagnostics.copy", defaultValue: "复制"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostic.subject)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(diagnostic.message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: SystemSoftRestartWindowLayout.diagnosticsHeight)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        }
    }

    private func copyDiagnostics(_ diagnostics: [SystemSoftRestartDiagnostic]) {
        let text = diagnostics.map { diagnostic in
            "\(diagnostic.subject): \(diagnostic.message)"
        }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func failureContent(message: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 58, height: 58)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
            }
            Text(localization.string("failure.title", defaultValue: "系统软重启未完成"))
                .font(.title2.weight(.semibold))

            diagnosticsView([SystemSoftRestartDiagnostic(
                kind: .essentialServices,
                subject: localization.string("window.title", defaultValue: "系统软重启"),
                message: message
            )])

            Button(localization.string("common.close", defaultValue: "关闭"), action: onDismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minWidth: 120)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func summaryBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: Capsule()
            )
    }

    private var applicationSummary: String {
        guard viewModel.plan.reopensApplications else {
            return localization.string("confirm.apps.notReopened", defaultValue: "不重新打开应用")
        }
        return localization.format(
            "confirm.apps.countFormat",
            defaultValue: "重新打开 %d 个应用",
            viewModel.plan.applicationCount
        )
    }

    private var dockSummary: String {
        viewModel.plan.preservesDockLayout
            ? localization.string("confirm.dock.preserved", defaultValue: "保留 Dock 布局")
            : localization.string("confirm.dock.notPreserved", defaultValue: "不备份 Dock")
    }
}
