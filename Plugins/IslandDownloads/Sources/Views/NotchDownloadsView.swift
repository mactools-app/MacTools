// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Vorssaint (github.com/vorssaint/vorssaint-utils), GPL-3.0-or-later.
// Copyright (C) 2026 Vorssaint; MacTools adaptation (C) 2026 MacTools contributors.

import AppKit
import MacToolsPluginKit
import SwiftUI

/// Before a folder is chosen the page says what it will do and offers the one
/// step that starts it, in the same voice as the panel's other empty pages.
private struct NotchDownloadsSetupView: View {
    @ObservedObject private var downloads = NotchDownloadService.shared
    private var text: NotchDownloadStrings { NotchDownloadStrings.current }

    var body: some View {
        NotchEmptyView(symbol: downloads.folderUnavailable ? "exclamationmark.triangle" : "arrow.down.circle",
                       message: downloads.folderUnavailable ? text.folderUnavailable : text.downloadsHint) {
            HStack(spacing: 8) {
                NotchPillButton(title: text.chooseFolder, prominent: true, action: downloads.chooseFolder)
                if downloads.folderUnavailable {
                    NotchPillButton(title: text.clearFolder, action: downloads.forgetFolder)
                }
            }
        }
    }
}

/// Vorssaint's Downloads page. The island's top row becomes the page's own
/// band, since the MacTools panel names no page above it; the cards, their
/// readings and actions are Vorssaint's.
struct NotchDownloadsView: View {
    let size: CGSize
    @ObservedObject private var downloads = NotchDownloadService.shared
    private var text: NotchDownloadStrings { NotchDownloadStrings.current }

    private var needsSetup: Bool { downloads.folderName == nil || downloads.folderUnavailable }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchDownloadsLayout.bandSpacing) {
            if needsSetup {
                NotchDownloadsSetupView()
            } else {
                band
                let recent = NotchDownloadsLayout.recent(downloads.items, now: Date())
                if recent.isEmpty {
                    NotchEmptyView(symbol: "arrow.down.circle", message: NotchDownloadsLayout.noRecentDownloads)
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(recent) { item in
                                downloadCard(item)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.locale, PluginRuntimeLocalization.locale)
    }

    /// The watched folder heads the page, with the choice of another one or
    /// none, where the island put it in its top row.
    private var band: some View {
        HStack(spacing: 6) {
            Text(text.downloadsTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.agentInk)
                .padding(.leading, 4)
            Spacer(minLength: 4)
            folderMenu
        }
        .frame(height: NotchDownloadsLayout.bandHeight)
    }

    private var folderMenu: some View {
        let name = downloads.folderName ?? text.downloadsTitle
        return Menu {
            if let folder = downloads.folder {
                // Older files stay in the folder; this is the way to them.
                Button(text.showInFinder) { NSWorkspace.shared.open(folder) }
                Divider()
            }
            Button(text.chooseFolder, action: downloads.chooseFolder)
            Button(text.clearFolder, action: downloads.forgetFolder)
        } label: {
            NotchBandMenuLabel(title: name, symbol: "folder", truncation: .middle)
        }
        // The label draws as it is, as the island's own menus do.
        .menuStyle(.button)
        .buttonStyle(NotchButtonStyle(cornerRadius: 9))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(name)
        .accessibilityLabel(text.downloadsTitle)
        .accessibilityValue(name)
    }

    private func downloadCard(_ item: NotchDownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                let fileLabel = HStack(spacing: 8) {
                    Image(systemName: item.completed ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(item.completed ? Color.green : Color.agentInk)
                        .accessibilityHidden(true)
                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(Color.agentInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if item.completed {
                    Button {
                        if !NSWorkspace.shared.open(item.url) { NSSound.beep() }
                    } label: {
                        fileLabel.frame(minHeight: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(NotchButtonStyle(cornerRadius: 6, lifts: false))
                    .help(text.open)
                    .accessibilityHint(text.open)
                    NotchIconButton(symbol: "folder", title: text.showInFinder) {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                } else {
                    fileLabel
                    if let fraction = item.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(Color.agentInk)
                    }
                }
            }
            if item.completed {
                Text(text.saved).font(.caption).foregroundStyle(.secondary)
            } else {
                if let fraction = item.fraction {
                    NotchMeter(value: fraction)
                } else if item.active {
                    ProgressView().controlSize(.small)
                }
                HStack {
                    Text(item.active ? text.inProgress : "")
                    Spacer()
                    if let bytes = item.receivedBytes, bytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    } else if item.fraction == nil {
                        Text(text.totalUnknown)
                    }
                }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(NotchAgentCardSurface())
        .clipped()
        .accessibilityElement(children: .contain)
    }
}

enum NotchDownloadsLayout {
    static let bandHeight: CGFloat = 28
    static let bandSpacing: CGFloat = 8
    /// The page's height in the panel: its band and three cards, scrolling
    /// for more, as the island's Downloads page did at its default size.
    static let contentHeight: CGFloat = 248

    /// Like Safari's downloads list, which removes items after one day by default: what is
    /// downloading, then what arrived in the last 24 hours, newest first. Vorssaint listed the
    /// whole folder, as the Dock's stack does; the folder itself stays a click away in Finder.
    static let recentWindow: TimeInterval = 24 * 60 * 60
    static let maximumRecent = 10

    static func recent(_ items: [NotchDownloadItem], now: Date) -> [NotchDownloadItem] {
        let active = items.filter { !$0.completed }
        let arrived = items.filter { $0.completed && now.timeIntervalSince($0.date) <= recentWindow }
        return Array((active + arrived).prefix(maximumRecent))
    }

    static var noRecentDownloads: String {
        for language in PluginRuntimeLocalization.preferredLanguages {
            let code = language.lowercased()
            if code.hasPrefix("zh-hant") || code.hasPrefix("zh-tw") || code.hasPrefix("zh-hk") { return "過去 24 小時內沒有下載" }
            if code.hasPrefix("zh") { return "过去 24 小时内没有下载" }
            switch code.prefix(2) {
            case "en": return "No downloads in the last 24 hours"
            case "pt": return "Nenhum download nas últimas 24 horas"
            case "es": return "No hay descargas en las últimas 24 horas"
            case "sk": return "Za posledných 24 hodín žiadne stiahnutia"
            case "de": return "Keine Downloads in den letzten 24 Stunden"
            case "fr": return "Aucun téléchargement ces dernières 24 heures"
            case "it": return "Nessun download nelle ultime 24 ore"
            case "ru": return "Нет загрузок за последние 24 часа"
            case "tr": return "Son 24 saatte indirme yok"
            case "ja": return "過去24時間にダウンロードはありません"
            case "ko": return "지난 24시간 동안 다운로드 없음"
            case "uk": return "Немає завантажень за останні 24 години"
            default: continue
            }
        }
        return "No downloads in the last 24 hours"
    }
}
