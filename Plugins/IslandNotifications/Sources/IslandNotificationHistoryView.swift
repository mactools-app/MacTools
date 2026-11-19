import AppKit
import MacToolsPluginKit
import SwiftUI

enum IslandHistoryLayout {
    /// The widget grows with its list up to about five notifications, then scrolls.
    static let maximumHeight: CGFloat = 560
    /// Opening, folding and clearing. The panel changes height on the same spring once the host has
    /// passed the new size on (about 80 ms), so the list starts that much later and both move together.
    static let motion = Animation.spring(response: 0.36, dampingFraction: 0.86).delay(0.09)
    /// The "No Notifications" line.
    static let emptyHeight: CGFloat = 64
    static let cornerRadius: CGFloat = 16
    static let iconSize: CGFloat = 32
    /// How far each card under a stack's top card shows below it.
    static let peek: CGFloat = 10
    /// The dark line between a card and the one peeking out under it, which makes the stack read.
    static let gap: CGFloat = 2
    /// Room around the list for the close button, which sits over a card's corner.
    static let inset: CGFloat = 8
}

/// The panel's Notifications list, drawn as Notification Centre draws it: one stack per app with
/// the newest on top, a click on a stack fans it out with Show Less and Clear above it, and a click
/// on a notification opens it. Hovering shows the close button at the card's corner.
struct IslandNotificationHistoryView: View {
    let size: CGSize
    @ObservedObject var history: IslandNotificationHistory
    let localization: PluginLocalization
    let onOpen: (IslandHistoryEntry) -> Void
    let onClear: ([IslandHistoryEntry]) -> Void
    /// The list's full height (0 when empty), so the widget can fit it.
    let onContentHeight: (CGFloat) -> Void
    @State private var expanded: String?
    @State private var listHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animation: Animation? { reduceMotion ? nil : IslandHistoryLayout.motion }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let groups = IslandNotificationHistory.groups(history.entries)
            if groups.isEmpty {
                Text(localization.string("history.empty", defaultValue: "没有通知"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { onContentHeight(0) }
            } else {
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(spacing: 8) {
                            ForEach(groups) { group in
                                stack(group, now: context.date)
                            }
                        }
                        .padding(IslandHistoryLayout.inset)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            listHeight = height
                            onContentHeight(height)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                // While the list fits, it isn't cut at the widget's edge: the panel's own surface
                // clips it, so a list changing height and the panel following it move as one.
                .scrollClipDisabled(listHeight <= IslandHistoryLayout.maximumHeight + 1)
                .modifier(IslandScrollFade(overflows: listHeight > IslandHistoryLayout.maximumHeight + 1))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // No heading on screen, as in Notification Centre's list; VoiceOver still names it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.string("history.title", defaultValue: "通知"))
        .environment(\.locale, PluginRuntimeLocalization.locale)
        .onChange(of: history.entries) { _, entries in
            if let expanded, !entries.contains(where: { $0.groupKey == expanded }) { self.expanded = nil }
        }
    }

    /// One view tree for both states, so opening a stack is one motion: the cards underneath grow
    /// out from their edges below the top card into full cards, and fold back the same way.
    private func stack(_ group: IslandNotificationHistory.Group, now: Date) -> some View {
        let open = expanded == group.id && group.entries.count > 1
        let more = group.entries.count - 1
        return VStack(spacing: 0) {
            if open {
                HStack(spacing: 6) {
                    Text(group.newest.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    IslandHistoryPill(title: localization.string("history.showLess", defaultValue: "收起")) {
                        withAnimation(animation) { expanded = nil }
                    }
                    IslandHistoryCloseButton(title: localization.string("history.clearAll", defaultValue: "全部清除"), size: 22) {
                        withAnimation(animation) { onClear(group.entries) }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
            ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                // 0: a full card; 1 and 2: an edge peeking out under the top card; 3: hidden behind.
                let level = open ? 0 : min(index, 3)
                let top = index == 0
                IslandHistoryCard(entry: entry, now: now, localization: localization,
                                  closeTitle: localization.string(top && !open && more > 0 ? "history.clearAll" : "history.close",
                                                                  defaultValue: top && !open && more > 0 ? "全部清除" : "关闭"),
                                  folded: level,
                                  onClick: {
                                      if top, !open, more > 0 { withAnimation(animation) { expanded = group.id } }
                                      // Opening takes the notification off the list, as Clear does: the
                                      // cards below move up on the panel's spring instead of leaving a gap.
                                      else { withAnimation(animation) { onOpen(entry) } }
                                  },
                                  onClose: { withAnimation(animation) { onClear(top && !open ? group.entries : [entry]) } })
                    .padding(.horizontal, CGFloat(min(level, 2)) * 12)
                    .padding(.top, top ? 0 : (open ? 8 : (level < 3 ? IslandHistoryLayout.gap : 0)))
                    .zIndex(Double(-index))
            }
        }
    }
}

/// Notification Centre fades its list into the edge where more is scrolled out of sight.
private struct IslandScrollFade: ViewModifier {
    let overflows: Bool
    @State private var atTop = true
    @State private var atBottom = false
    private static let fade: CGFloat = 28

    func body(content: Content) -> some View {
        let faded = content.mask {
            if overflows {
                VStack(spacing: 0) {
                    edge(faded: !atTop, towardTop: true)
                    Color.black
                    edge(faded: !atBottom, towardTop: false)
                }
            } else {
                // Nothing to fade: the mask reaches past the edges so it cuts nothing off.
                Color.black.padding(-2000)
            }
        }
        if #available(macOS 15, *) {
            faded.onScrollGeometryChange(for: [Bool].self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                return [offset <= 1, offset + geometry.containerSize.height >= geometry.contentSize.height - 1]
            } action: { _, edges in
                atTop = edges[0]
                atBottom = edges[1]
            }
        } else {
            faded
        }
    }

    private func edge(faded: Bool, towardTop: Bool) -> some View {
        LinearGradient(colors: faded ? [.clear, .black] : [.black, .black],
                       startPoint: towardTop ? .top : .bottom, endPoint: towardTop ? .bottom : .top)
            .frame(height: Self.fade)
            .animation(.easeOut(duration: 0.2), value: faded)
    }
}

/// One notification, laid out like a Notification Centre row: icon, bold title with the time on
/// the right, then the message.
private struct IslandHistoryCard: View {
    let entry: IslandHistoryEntry
    let now: Date
    let localization: PluginLocalization
    let closeTitle: String
    /// 0: the card in full. 1, 2: only its lower edge shows, under a stack's top card. 3: hidden.
    var folded = 0
    let onClick: () -> Void
    let onClose: () -> Void
    @State private var hovered = false
    @Environment(\.pluginComponentTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IslandHistoryLayout.cornerRadius, style: .continuous)
        Button(action: onClick) {
            HStack(alignment: .top, spacing: 10) {
                IslandHistoryIcon(url: entry.appURL)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.title.isEmpty ? entry.appName : entry.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Text(IslandHistoryTime.text(for: entry.date, now: now, localization: localization))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if let subtitle = entry.subtitle {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    if !entry.message.isEmpty {
                        Text(entry.message)
                            .font(.system(size: 13))
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .opacity(folded > 0 ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surfaces.card, in: shape)
            // An edge under the top card is a little brighter, the second one fainter, so the stack reads.
            .overlay { shape.fill(Color.primary.opacity(folded == 1 ? 0.05 : 0)).allowsHitTesting(false) }
            .opacity(folded == 2 ? 0.6 : (folded == 3 ? 0 : 1))
            .overlay {
                shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
            // Folded, only the bottom of the card is left: its rounded lower edge.
            .frame(height: folded == 0 ? nil : (folded < 3 ? IslandHistoryLayout.peek - IslandHistoryLayout.gap : 0),
                   alignment: .bottom)
            .clipped()
        }
        .buttonStyle(IslandHistoryPressStyle())
        .allowsHitTesting(folded == 0)
        .accessibilityHidden(folded > 0)
        .overlay(alignment: .topLeading) {
            if hovered, folded == 0 {
                IslandHistoryCloseButton(title: closeTitle, size: 18, action: onClose)
                    .offset(x: -6, y: -6)
                    .transition(.opacity)
            }
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovered = inside } }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: closeTitle, onClose)
    }
}

private struct IslandHistoryIcon: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app.badge").resizable().scaledToFit().foregroundStyle(.secondary).padding(4)
            }
        }
        .frame(width: IslandHistoryLayout.iconSize, height: IslandHistoryLayout.iconSize)
        .accessibilityHidden(true)
    }
}

/// The round ✕ Notification Centre shows on a hovered notification, and beside an open stack.
private struct IslandHistoryCloseButton: View {
    let title: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct IslandHistoryPill: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(.regularMaterial, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct IslandHistoryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
