import SwiftUI
import MacToolsPluginKit

@MainActor
final class TranslatorPanelModel: ObservableObject {
    @Published var snapshot: TranslatorPanelSnapshot = .idle
}

/// Keeps the SwiftUI view tree alive and lets SwiftUI diff updates when `model.snapshot` changes.
/// This avoids rebuilding the NSHostingView for every snapshot and losing scroll position or text selection.
struct TranslatorPanelHostView: View {
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    @ObservedObject var model: TranslatorPanelModel
    let localization: PluginLocalization
    let onAction: (TranslatorPanelAction) -> Void

    init(model: TranslatorPanelModel, localization: PluginLocalization, onAction: @escaping (TranslatorPanelAction) -> Void) {
        self.model = model
        self.localization = localization
        self.onAction = onAction
    }

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        TranslatorPanelView(snapshot: model.snapshot, localization: localization, onAction: onAction)
            .environment(\.locale, locale)
            .environment(\.layoutDirection, locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }
}

struct TranslatorPanelView: View {
    @Environment(\.locale) private var locale
    let snapshot: TranslatorPanelSnapshot
    let localization: PluginLocalization
    let onAction: (TranslatorPanelAction) -> Void

    init(
        snapshot: TranslatorPanelSnapshot,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        onAction: @escaping (TranslatorPanelAction) -> Void
    ) {
        self.snapshot = snapshot
        self.localization = localization
        self.onAction = onAction
    }

    var body: some View {
        let _ = locale
        VStack(spacing: 8) {
            sourceEditor
            languageRow
            if let tip = presentation.tip {
                tipCard(tip)
            }
            providerRows
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 606, height: 380, alignment: .top)
    }

    private var presentation: TranslatorPanelPresentation {
        TranslatorPanelPresentation(snapshot: snapshot, localization: localization)
    }

    private var sourceEditor: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if presentation.usesSourceCaretPlaceholder {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(width: 2.5, height: 18)
                        .padding(.leading, 11)
                        .padding(.top, 11)
                } else {
                    ScrollView {
                        Text(presentation.sourceText)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(spacing: 8) {
                sourceIconButton(
                    "speaker.wave.2",
                    help: localization.string("panel.source.speakHelp", defaultValue: "朗读原文"),
                    action: .speakSource,
                    isDisabled: presentation.sourceText.isEmpty
                )
                sourceIconButton(
                    "doc.on.doc",
                    help: localization.string("panel.source.copyHelp", defaultValue: "复制原文"),
                    action: .copySource,
                    isDisabled: presentation.sourceText.isEmpty
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .frame(height: 36)
        }
        .frame(height: 86)
        .background(panelCardColor, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var languageRow: some View {
        HStack(spacing: 0) {
            languageSegment(title: presentation.sourceLanguageTitle)
            Spacer(minLength: 0)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 56)
            Spacer(minLength: 0)
            languageSegment(title: presentation.targetLanguageTitle)
        }
        .frame(height: 30)
        .background(panelCardColor, in: RoundedRectangle(cornerRadius: 8))
    }

    private func languageSegment(title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(PluginTypography.sectionTitle.font)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 30)
    }

    private func tipCard(_ tip: TranslatorPanelPresentation.Tip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: PluginSystemImage.resolvedName(tip.systemImage))
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.multicolor)
                Text(tip.title)
                    .font(PluginTypography.sectionTitle.font)
            }
            Text(tip.message)
                .font(PluginTypography.body.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onAction(.openSettings)
            } label: {
                Label(tip.actionTitle, systemImage: "questionmark.bubble")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .background(panelCardColor, in: RoundedRectangle(cornerRadius: 8))
    }

    private var providerRows: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(presentation.providerRows) { row in
                    providerRow(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func providerRow(_ row: TranslatorPanelPresentation.ProviderRow) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                providerSymbol(row)
                Text(row.title)
                    .font(PluginTypography.body.font.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if row.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.forward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            if row.isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.bodyText)
                        .font(.body)
                        .foregroundStyle(row.isError ? .red : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    HStack(spacing: 8) {
                        sourceIconButton(
                            "speaker.wave.2",
                            help: localization.string("panel.result.speakHelp", defaultValue: "朗读译文"),
                            action: .speakTranslation,
                            isDisabled: row.bodyText.isEmpty || row.isError
                        )
                        sourceIconButton(
                            "doc.on.doc",
                            help: localization.format(
                                "panel.result.copyProviderHelpFormat",
                                defaultValue: "复制%@译文",
                                row.title
                            ),
                            action: row.id == "placeholder" ? .copyTranslation : .copyProviderTranslation(row.id),
                            isDisabled: !row.canCopy
                        )
                        sourceIconButton(
                            "arrow.clockwise",
                            help: localization.string("panel.retryHelp", defaultValue: "重试"),
                            action: .retry,
                            isDisabled: false
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(panelCardColor, in: RoundedRectangle(cornerRadius: 8))
    }

    private func providerSymbol(_ row: TranslatorPanelPresentation.ProviderRow) -> some View {
        Image(systemName: row.symbolName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(providerTint(for: row.title))
            .frame(width: 18, height: 18)
            .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
    }

    private func sourceIconButton(
        _ systemName: String,
        help: String,
        action: TranslatorPanelAction,
        isDisabled: Bool
    ) -> some View {
        Button {
            onAction(action)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
        .disabled(isDisabled)
        .help(help)
    }

    private func providerTint(for title: String) -> Color {
        let normalized = title.lowercased()
        if normalized.contains("deepseek") {
            return Color(red: 0.32, green: 0.42, blue: 1.0)
        }
        if normalized.contains("fireworks") {
            return Color(red: 0.39, green: 0.16, blue: 0.95)
        }
        return .primary
    }

    private var panelCardColor: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }
}
