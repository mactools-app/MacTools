import SwiftUI
import MacToolsPluginKit

struct TrackpadScaleView: View {
    let model: TrackpadScaleModel
    let localization: PluginLocalization
    @Environment(\.pluginPresentationIsVisible) private var isPresentationVisible

    private func localized(_ key: String, _ fallback: String) -> String {
        localization.string(key, defaultValue: fallback)
    }

    var body: some View {
        PluginObservedContent(model) { _ in
            measurementContent
        }
    }

    private var measurementContent: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.pagePadding) {
                    reading.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                    contactIndicator
                }
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    reading
                    contactIndicator
                }
            }
            Divider()
            controls
            Label(localized("inputSharing.notice", "称重时暂停「中键点击」和「触控板手势」。记录或停止后，抬起全部手指即可恢复。"),
                  systemImage: "info.circle")
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.section) {
                    steps
                }
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    steps
                }
            }
        }
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .background {
            if isPresentationVisible, !model.isCalibrationExpanded {
                TrackpadScaleTareButton(title: localized("tare", "归零"),
                                       isEnabled: model.isRunning && model.measurement.canTare,
                                       action: model.tare)
                    .hidden().frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Text(localized("reading.title", "估算重量"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            PluginMetricValue(
                displayedGrams.map {
                    String(format: "≈ %.0f", locale: PluginRuntimeLocalization.locale, $0)
                } ?? "—",
                unit: "g", isProminent: true
            )
            .accessibilityLabel(localized("approximate", "估算重量 · 实验性"))
            .accessibilityValue(displayedGrams.map {
                String(format: "≈ %.0f g", locale: PluginRuntimeLocalization.locale, $0)
            } ?? status)
            Text(localized("reading.accuracyWarning", "仅供参考。即使校准后，估算仍可能不准确。"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.capturedReading != nil || model.measurement.state == .measuring {
                Label(readingBadge, systemImage: model.capturedReading != nil || model.measurement.isStable
                      ? "checkmark.circle.fill" : "waveform")
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(model.capturedReading != nil || model.measurement.isStable ? Color.green : Color.secondary)
                    .padding(.horizontal, PluginSettingsTheme.Spacing.controlCluster)
                    .padding(.vertical, PluginSettingsTheme.Spacing.rowTitleDescription)
                    .background(.quaternary, in: Capsule())
            }
            HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                if model.measurement.isAutoTarePending, model.measurement.hasPressureReading {
                    ProgressView().controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(status).font(PluginSettingsTheme.Typography.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("trackpad-scale-status")
            }
            if let statusDetail {
                Text(statusDetail).font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.measurement.captureProgress > 0 {
                ProgressView(value: model.measurement.captureProgress)
                    .progressViewStyle(.linear).frame(maxWidth: 160)
                    .accessibilityLabel(localized("capture.progress", "称重记录进度"))
            }
        }
    }

    private var contactIndicator: some View {
        VStack(spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            ZStack {
                if model.capturedReading != nil {
                    Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                } else if model.measurement.hasPressureReading {
                    Circle().fill(Color.accentColor)
                        .frame(width: PluginSettingsTheme.Size.emptyStateIcon,
                               height: PluginSettingsTheme.Size.emptyStateIcon)
                } else if model.measurement.state == .multipleContacts {
                    Image(systemName: "hand.raised.fingers.spread")
                        .font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 108)
            .pluginSettingsCardBackground(.recessed)
            .overlay {
                RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card)
                    .strokeBorder(PluginSettingsTheme.Palette.separator,
                                  lineWidth: PluginSettingsTheme.Stroke.standard)
            }
            .accessibilityHidden(true)
            Text(contactStatus)
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .frame(width: 160)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trackpad-scale-contact")
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                sessionButtons
                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                autoCaptureToggle
            }
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                sessionButtons
                autoCaptureToggle
            }
        }
        .controlSize(.small)
    }

    private var sessionButtons: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            controlButtons
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var autoCaptureToggle: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Text(localized("autoCapture.title", "自动记录"))
            Toggle(localized("autoCapture.title", "自动记录"), isOn: Binding(
                get: { model.autoCaptureEnabled }, set: { model.setAutoCaptureEnabled($0) }
            ))
            .labelsHidden().toggleStyle(.switch)
        }
        .font(PluginSettingsTheme.Typography.controlLabel)
        .fixedSize(horizontal: true, vertical: false)
        .help(localized("autoCapture.help", "重量超过基线波动且至少为 2 g，稳定约两秒后自动记录并停止。展开校准时暂停自动记录。"))
    }

    @ViewBuilder private var controlButtons: some View {
        if !model.isRunning || needsRestart {
            Button {
                model.restart()
            } label: {
                Label(model.capturedReading != nil ? localized("startAgain", "再次称重")
                      : needsRestart ? localized("restart", "重新开始") : localized("start", "开始"),
                      systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        if model.isRunning {
            Button { model.stop() } label: {
                Label(localized("stop", "停止"), systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var steps: some View {
        TrackpadScaleStep(number: 1, title: localized("step.touch", "轻触"),
                          description: localized("step.touch.description", "保持一根手指轻触触控板。"),
                          completed: model.capturedReading != nil || model.measurement.hasPressureReading,
                          active: model.isRunning && !model.measurement.hasPressureReading)
        TrackpadScaleStep(number: 2, title: localized("step.autoTare", "自动归零"),
                          description: localized("step.autoTare.description", "勿放物件，保持轻触约一秒。"),
                          completed: model.capturedReading != nil || model.measurement.tare != nil,
                          active: model.measurement.isAutoTarePending && model.measurement.hasPressureReading)
        TrackpadScaleStep(number: 3, title: localized("step.weigh", "称重"),
                          description: localized("step.weigh.description", "轻放小物件，手指保持不动。"),
                          completed: model.capturedReading != nil, active: model.measurement.tare != nil)
    }

    private var displayedGrams: Double? { model.capturedReading?.grams ?? model.measurement.estimatedGrams }

    private var readingBadge: String {
        if model.capturedReading != nil { return localized("capture.badge", "已记录") }
        return model.measurement.isStable ? localized("stable", "稳定") : localized("unstable", "未稳定")
    }

    private var needsRestart: Bool {
        model.isRunning && !model.measurement.isAutoTarePending && model.measurement.tare == nil
    }

    private var contactStatus: String {
        if model.capturedReading != nil { return localized("capture.stopped", "已停止采样") }
        if model.measurement.hasPressureReading { return localized("contact.one", "检测到一根手指") }
        if model.measurement.state == .multipleContacts { return localized("contact.multiple", "检测到多个触点") }
        return localized("contact.none", "无触点")
    }

    private var status: String {
        if model.capturedReading != nil { return localized("status.captured", "重量已记录，可抬起手指。") }
        switch model.measurement.state {
        case .stopped: return localized("state.stopped", "点按“开始”以称重。")
        case .unsupported: return localized("state.unsupported", "未检测到支持压力读取的内置 Force Touch 触控板。")
        case .noContact:
            return needsRestart ? localized("status.contactLost", "手指已离开触控板。")
                : localized("state.noContact", "请移开物件，保持一根手指轻触触控板。")
        case .multipleContacts: return localized("state.multipleContacts", "检测到多个触点。请只保留一根手指，然后重新归零。")
        case .needsTare:
            return model.measurement.isAutoTarePending
                ? localized("state.autoTaring", "正在自动归零，请保持手指平稳，勿放物件。")
                : localized("state.needsTare", "请移开物件并重新开始，或保持手指平稳按 ⌘T 归零。")
        case .measuring:
            return model.measurement.captureProgress > 0 ? localized("status.capturing", "请保持平稳，正在记录重量。")
                : localized("status.ready", "已就绪，可轻放小物件。")
        case .invalidSample: return localized("state.invalidSample", "压力读数无效。请重新轻触并归零。")
        case .interrupted: return localized("state.interrupted", "会话已中断。请移开物件并重新开始。")
        }
    }

    private var statusDetail: String? {
        if model.capturedReading != nil {
            return localized("capture.detail", "读数会保留至下次称重，可切换到其他任务。")
        }
        switch model.measurement.state {
        case .stopped: return localized("status.removeObject", "请先移开物件。")
        case .noContact where needsRestart: return localized("status.restart", "请移开物件，再点按“重新开始”。")
        case .measuring: return localized("status.keepFinger", "保持手指位置和力度不变。")
        case .interrupted: return localized("status.recovery", "若仍无法开始，请在“插件”中更新或停用旧版触控板手势和模拟鼠标中键。")
        default: return nil
        }
    }
}

private struct TrackpadScaleStep: View {
    let number: Int
    let title: String
    let description: String
    let completed: Bool
    let active: Bool

    var body: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Image(systemName: completed ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(completed || active ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title).font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(description).font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 135, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct TrackpadScaleCalibrationView: View {
    let model: TrackpadScaleModel
    let localization: PluginLocalization
    @State private var knownGrams = ""

    private func localized(_ key: String, _ fallback: String) -> String {
        localization.string(key, defaultValue: fallback)
    }

    var body: some View {
        PluginObservedContent(model) { _ in
            DisclosureGroup(isExpanded: Binding(
                get: { model.isCalibrationExpanded }, set: { model.setCalibrationExpanded($0) }
            )) {
                calibrationContent
                    .padding(.top, PluginSettingsTheme.Spacing.sectionHeaderContent)
            } label: {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Label(localized("calibration.title", "校准"), systemImage: "slider.horizontal.3")
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                    if model.isRunning || model.capturedReading != nil {
                        Text(isCalibrated ? localized("calibration.saved", "已校准")
                             : localized("calibration.unsaved", "未校准"))
                            .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    }
                }
            }
            .onChange(of: model.calibrationError) { _, hasError in
                if hasError { model.setCalibrationExpanded(true) }
            }
        }
    }

    private var calibrationContent: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            if model.autoCaptureEnabled {
                Text(localized("autoCapture.paused", "展开校准时暂停自动记录。"))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
            TrackpadScaleTareButton(title: localized("tare", "归零"),
                                   isEnabled: model.isRunning && model.measurement.canTare,
                                   action: model.tare)
            Text(localized("calibration.instructions", "先在没有物件时归零，再放置已知重量的物件（1–100 g）。保持同一根手指轻触，稳定后保存。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    weightField
                    calibrationButtons
                }
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    weightField
                    calibrationButtons
                }
            }
            if model.isRunning || model.capturedReading != nil {
                Text(!isCalibrated
                     ? localized("uncalibrated", "未校准：原始压力差仅作为经验估算。")
                     : localized("calibrated", "已校准：校准仍不能保证准确度。"))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                if model.isRunning, model.measurement.device?.hasPersistentIdentity == false {
                    Text(localized("temporaryCalibration", "设备标识不可用，校准仅在本次会话有效。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
            }
            if model.calibrationError {
                Text(localized("calibrationError", "请输入 1–100 g 的有效重量，并等待有物件的读数稳定后重试。"))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red)
            }
            Divider()
            Text(localized("limitations", "仅支持内置 Force Touch 触控板。依赖 macOS 私有 API，兼容性可能变化。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isCalibrated: Bool { model.capturedReading?.wasCalibrated ?? model.hasCalibration }

    private var weightField: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            TextField(localized("knownWeight", "已知重量"), text: $knownGrams,
                      prompt: Text(localized("knownWeight", "已知重量")))
                .labelsHidden()
                .textFieldStyle(.roundedBorder).frame(minWidth: 100, idealWidth: 140, maxWidth: 160)
                .accessibilityLabel(localized("knownWeight", "已知重量"))
            Text("g").font(PluginSettingsTheme.Typography.rowDescription)
        }
    }

    private var calibrationButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                calibrationActions
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                calibrationActions
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    @ViewBuilder private var calibrationActions: some View {
        Button(localized("saveCalibration", "保存校准")) { model.calibrate(knownGrams) }
            .disabled(!model.isRunning || !model.measurement.canCalibrate)
        Button(localized("resetCalibration", "重置校准")) { model.resetCalibration() }
            .disabled(!model.isRunning)
    }
}

private struct TrackpadScaleTareButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Text(title)
                Text("⌘T").foregroundStyle(.secondary)
            }
        }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(!isEnabled)
        .buttonStyle(.bordered).controlSize(.small)
    }
}
