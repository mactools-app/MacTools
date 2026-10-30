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
        let size = expanded ? NSSize(width: 440, height: 520) : NSSize(width: 380, height: 290)
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
        if model.active && !model.connected { return model.text(model.status) }
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
                if model.active && !model.connected {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: model.speaking ? "speaker.wave.2" : (model.muted ? "mic.slash" : "mic"))
                        .foregroundStyle(model.active ? Color.accentColor : .secondary)
                }
                Text(status).font(PluginTypography.detail.font).lineLimit(2)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 0)
            }
            if presenter.expanded {
                HStack {
                    meterLabel(.user)
                    Spacer(minLength: 16)
                    meterLabel(.assistant)
                }
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if model.turns.isEmpty {
                                captionRow(speaker: .user, turn: nil, compact: false)
                                captionRow(speaker: .assistant, turn: nil, compact: false)
                            } else {
                                ForEach(model.turns) { turn in
                                    captionRow(speaker: turn.speaker, turn: turn, compact: false)
                                }
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.turns) { _, _ in scroll.scrollTo("latest", anchor: .bottom) }
                }.frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    captionRow(speaker: .user, turn: model.turns.last { $0.speaker == .user }, compact: true)
                    Divider()
                    captionRow(speaker: .assistant, turn: model.turns.last { $0.speaker == .assistant }, compact: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(model.text(!model.hasCredentials ? "设置" : model.active ? "停止" : "开始对话")) {
                    if !model.hasCredentials { presenter.openSettings?() }
                    else if model.active { model.stop() } else { model.start() }
                }.buttonStyle(.borderedProminent).disabled(model.credentialBusy)
                    .accessibilityIdentifier("voice-control.start-stop")
                Button { model.toggleMute() } label: {
                    Image(systemName: model.muted ? "mic.slash" : "mic")
                }.disabled(!model.capturing).help(model.text(model.muted ? "取消静音" : "静音麦克风"))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PluginPaletteSurface(reducesTransparency: false))
        .clipShape(RoundedRectangle(cornerRadius: PluginPaletteMetrics.surfaceCornerRadius, style: .continuous))
        .environment(\.locale, runtimeLocale.locale)
        .environment(\.layoutDirection, runtimeLocale.locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
        .onChange(of: runtimeLocale.revision) { _, _ in presenter.refreshLocalization() }
        .accessibilityIdentifier("voice-control.assistant")
    }

    private func speakerTitle(_ speaker: VoiceTranscript.Speaker) -> String {
        model.text(speaker == .user ? "你：" : "助手：")
    }
    private func meterLabel(_ speaker: VoiceTranscript.Speaker) -> some View {
        HStack(spacing: 8) {
            Label(speakerTitle(speaker), systemImage: speaker == .user ? (model.muted ? "mic.slash" : "mic") : "speaker.wave.2")
                .font(PluginTypography.caption.font).foregroundStyle(.secondary)
            VoiceWaveform(levels: speaker == .user ? model.inputLevels : model.outputLevels)
                .foregroundStyle(speaker == .user ? Color.accentColor : Color.primary)
                .frame(width: 74, height: 16)
        }
    }
    private func captionRow(speaker: VoiceTranscript.Speaker, turn: VoiceTranscript.Turn?, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if compact { meterLabel(speaker) }
            else {
                Label(speakerTitle(speaker), systemImage: speaker == .user ? "mic" : "speaker.wave.2")
                    .font(PluginTypography.caption.font).foregroundStyle(.secondary)
            }
            let placeholder = model.text(speaker == .user ? "说话时会在这里显示字幕" : "助手的回复会在这里显示")
            Text(turn.map { compact ? String($0.text.suffix(180)) : $0.text } ?? placeholder)
                .font(PluginTypography.body.font)
                .foregroundStyle(turn == nil ? .secondary : .primary)
                .lineLimit(compact ? 2 : nil).truncationMode(.head)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18, height: 18) }
            .buttonStyle(.borderless).help(model.text(title)).accessibilityLabel(model.text(title))
    }
}

private struct VoiceWaveform: View {
    let levels: [Float]
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 1) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule().frame(height: max(2, geometry.size.height * CGFloat(levels[index])))
                }
            }.frame(height: geometry.size.height)
        }
        .animation(reducesMotion ? nil : .linear(duration: 0.06), value: levels)
        .accessibilityHidden(true)
    }
}
