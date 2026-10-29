import AppKit
import Combine
import MacToolsPluginKit
import SwiftUI

@MainActor
final class VoiceAssistantPanel: ObservableObject {
    @Published private(set) var visible = false
    @Published private(set) var expanded = false
    private var panel: AssistantWindow?
    let conversation: VoiceConversation
    var openSettings: (() -> Void)?

    init(conversation: VoiceConversation) { self.conversation = conversation }
    func toggle() { visible ? dismiss() : present() }
    func present() {
        guard !visible else { panel?.orderFront(nil); return }
        if panel == nil {
            let panel = AssistantWindow(contentRect: .zero, styleMask: PluginPanelPresentation.styleMask,
                                        backing: .buffered, defer: false)
            PluginPanelPresentation.configure(panel)
            panel.title = conversation.text("语音控制")
            panel.identifier = NSUserInterfaceItemIdentifier("voice-control.assistant")
            panel.level = .floating
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.onDismiss = { [weak self] in self?.dismiss() }
            panel.contentView = NSHostingView(rootView: VoiceAssistantView(presenter: self, model: conversation))
            self.panel = panel
            resize()
            if let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 24,
                                             y: screen.visibleFrame.maxY - panel.frame.height - 24))
            }
        }
        resize()
        visible = true
        // Opening never takes the keyboard target away from the user's current app.
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel?.orderFront(nil)
        conversation.start()
    }
    func dismiss() {
        conversation.stop()
        panel?.orderOut(nil)
        visible = false
    }
    func tearDown() {
        dismiss()
        panel?.contentView = nil
        panel = nil
    }
    func refreshLocalization() { panel?.title = conversation.text("语音控制") }
    func toggleExpanded() { expanded.toggle(); resize() }
    private func resize() {
        guard let panel else { return }
        let size = expanded ? NSSize(width: 440, height: 480) : NSSize(width: 380, height: 205)
        let top = panel.frame.maxY
        var frame = NSRect(origin: panel.frame.origin, size: size)
        if top > 0 { frame.origin.y = top - size.height }
        if let screen = panel.screen ?? NSScreen.main {
            frame.origin.x = max(screen.visibleFrame.minX, min(frame.minX, screen.visibleFrame.maxX - frame.width))
            frame.origin.y = max(screen.visibleFrame.minY, min(frame.minY, screen.visibleFrame.maxY - frame.height))
        }
        panel.setFrame(frame, display: true, animate: visible)
    }
}

@MainActor
private final class AssistantWindow: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func close() { onDismiss?() }
}

@MainActor
private struct VoiceAssistantView: View {
    @ObservedObject var presenter: VoiceAssistantPanel
    @ObservedObject var model: VoiceConversation
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    @State private var showsScope = false
    private var status: String {
        if !model.hasCredentials { return model.text(model.credentialStatus) }
        if let activity = model.activity { return activity }
        if model.muted { return model.text("麦克风已静音") }
        return model.text(model.speaking ? "正在回复" : model.status)
    }
    var body: some View {
        let _ = runtimeLocale.revision
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.text("语音控制"), systemImage: "waveform")
                    .font(PluginTypography.sectionTitle.font)
                Spacer()
                iconButton("设置", symbol: "gearshape") { model.stop(); presenter.openSettings?() }
                iconButton(presenter.expanded ? "收起对话" : "展开对话", symbol: presenter.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    presenter.toggleExpanded()
                }
                iconButton("关闭", symbol: "xmark") { presenter.dismiss() }
            }
            HStack(spacing: 8) {
                Image(systemName: model.speaking ? "speaker.wave.2" : (model.muted ? "mic.slash" : "mic"))
                    .foregroundStyle(model.active ? Color.accentColor : .secondary)
                Text(status).font(PluginTypography.body.font).lineLimit(2)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 0)
            }
            if presenter.expanded {
                ScrollViewReader { scroll in
                    ScrollView {
                        Text(model.transcript.isEmpty ? model.text("开始后可以直接说话。字幕只保留在当前窗口，不保存到磁盘。") : model.transcript)
                            .font(PluginTypography.body.font).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("latest")
                    }
                    .onChange(of: model.transcript) { _, _ in scroll.scrollTo("latest", anchor: .bottom) }
                }
                .frame(maxHeight: .infinity)
            } else {
                Text(model.transcript.isEmpty ? model.text("可说“调亮一点”“开启深色模式”或“让 Mac 保持唤醒”。") : String(model.transcript.suffix(220)))
                    .font(PluginTypography.detail.font).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !presenter.expanded { Spacer(minLength: 0) }
            HStack(spacing: 8) {
                Button(model.text(!model.hasCredentials ? "设置" : model.active ? "停止" : "开始对话")) {
                    if !model.hasCredentials { presenter.openSettings?() }
                    else if model.active { model.stop() } else { model.start() }
                }.buttonStyle(.borderedProminent).disabled(model.credentialBusy)
                    .accessibilityIdentifier("voice-control.start-stop")
                Button { model.toggleMute() } label: {
                    Image(systemName: model.muted ? "mic.slash" : "mic")
                }.disabled(!model.connected).help(model.text(model.muted ? "取消静音" : "静音麦克风"))
                    .accessibilityLabel(model.text(model.muted ? "取消静音" : "静音麦克风"))
                Spacer(minLength: 0)
                Button(model.text("允许的功能")) { showsScope.toggle() }
                    .popover(isPresented: $showsScope) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(model.allowedProviders) { provider in
                                    Label(provider.title, systemImage: "checkmark")
                                }
                            }.padding().font(PluginTypography.body.font)
                        }.frame(width: 240, height: 220)
                    }
            }.controlSize(.small)
        }
        .padding(16)
        .background(PluginFloatingPanelSurface(shape: .roundedRectangle(cornerRadius: 16)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .environment(\.locale, runtimeLocale.locale)
        .environment(\.layoutDirection, runtimeLocale.locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
        .onChange(of: runtimeLocale.revision) { _, _ in presenter.refreshLocalization() }
        .accessibilityIdentifier("voice-control.assistant")
    }
    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18, height: 18) }
            .buttonStyle(.borderless).help(model.text(title)).accessibilityLabel(model.text(title))
    }
}
