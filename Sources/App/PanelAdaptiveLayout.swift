import AppKit
import SwiftUI
import MacToolsPluginKit

private struct MenuBarPanelSurfaceWidthKey: EnvironmentKey {
    static let defaultValue = MenuBarPanelLayout.surfaceWidth
}

extension EnvironmentValues {
    var menuBarPanelSurfaceWidth: CGFloat {
        get { self[MenuBarPanelSurfaceWidthKey.self] }
        set { self[MenuBarPanelSurfaceWidthKey.self] = newValue }
    }
}

enum MenuBarPanelWidth {
    static let columnSpacing: CGFloat = 16
    // Preserve saved widths and column counts. Flexible rows absorb the wider
    // gutters while widget dimensions and the established presets stay intact.
    static let allocationSpacing: CGFloat = 8
    static let minimumColumnWidth = CGFloat(MenuBarPanelItemWidth.minimumPoints)

    static func width(forColumns count: Int) -> CGFloat {
        CGFloat(max(1, count)) * (minimumColumnWidth + allocationSpacing) - allocationSpacing
            + MenuBarPanelLayout.outerPadding * 2
    }

    static func columns(forSurfaceWidth width: CGFloat) -> Int {
        guard width.isFinite, width >= minimumColumnWidth else { return 1 }
        let count = floor((width + allocationSpacing) / (minimumColumnWidth + allocationSpacing))
        guard count < CGFloat(Int.max) else { return Int.max }
        return max(1, Int(count))
    }

    static func columnWidth(forSurfaceWidth width: CGFloat) -> CGFloat {
        return min(MenuBarPanelLayout.maximumFeatureContentWidth,
                   columnSlotWidth(forSurfaceWidth: width) - columnInset(forSurfaceWidth: width) * 2)
    }

    static func columnSlotWidth(forSurfaceWidth width: CGFloat) -> CGFloat {
        let columns = columns(forSurfaceWidth: width)
        return (width - CGFloat(columns - 1) * allocationSpacing) / CGFloat(columns)
    }

    static func columnInset(forSurfaceWidth width: CGFloat) -> CGFloat {
        columns(forSurfaceWidth: width) > 1 ? (columnSpacing - allocationSpacing) / 2 : 0
    }

    static func columnOrigin(_ column: Int, surfaceWidth: CGFloat) -> CGFloat {
        CGFloat(column) * (columnSlotWidth(forSurfaceWidth: surfaceWidth) + allocationSpacing)
    }

    static func columnTitle(_ count: Int) -> String {
        count == 1 ? FeatureL10n.string("1 列") : FeatureL10n.format("%lld 列", count)
    }

    static func maximum(visibleFrameWidth: CGFloat?) -> CGFloat {
        max(MenuBarPanelLayout.baseWidth, (visibleFrameWidth ?? 1440) - 32)
    }

    static func resolved(preferred: Double, maximum: CGFloat) -> CGFloat {
        guard preferred.isFinite else { return MenuBarPanelLayout.baseWidth }
        return min(maximum, max(MenuBarPanelLayout.baseWidth, preferred))
    }

    static func validatedDraft(_ draft: Double, maximum: CGFloat) -> Double? {
        guard draft.isFinite, draft >= MenuBarPanelLayout.baseWidth, draft <= maximum else { return nil }
        return min(maximum, draft.rounded())
    }

    static var title: String { FeatureL10n.string("面板宽度") }
}

enum PanelItemWidthLayout {
    static var title: String { FeatureL10n.string("内容宽度") }
    static var automaticTitle: String { FeatureL10n.string("自动") }
    static var fillTitle: String { FeatureL10n.string("填满面板") }
    static var customTitle: String { FeatureL10n.string("自定宽度…") }

    static func resolved(_ preference: MenuBarPanelItemWidth?, available: CGFloat) -> CGFloat {
        switch preference?.mode {
        case "fill": return available
        case "custom":
            guard let points = preference?.normalized?.points else { fallthrough }
            return min(available, points)
        default: return MenuBarPanelWidth.columnWidth(forSurfaceWidth: available)
        }
    }
}

/// Exact widths are committed explicitly; closing the editor discards unfinished input.
struct PanelItemWidthPicker: View {
    let preference: MenuBarPanelItemWidth?
    let availableWidth: CGFloat
    let onCommit: (MenuBarPanelItemWidth?) -> Void
    @State private var mode: String
    @State private var draft: Double
    @State private var hasEdits = false
    @State private var presentationFocus = MenuBarPanelPopoverFocus()

    init(preference: MenuBarPanelItemWidth?, availableWidth: CGFloat,
         onCommit: @escaping (MenuBarPanelItemWidth?) -> Void) {
        self.preference = preference
        self.availableWidth = availableWidth
        self.onCommit = onCommit
        _mode = State(initialValue: "custom")
        _draft = State(initialValue: preference?.points
            ?? PanelItemWidthLayout.resolved(preference, available: availableWidth))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PanelItemWidthLayout.title).font(PluginTypography.sectionTitle.font)
            Picker(PanelItemWidthLayout.title, selection: $mode) {
                Text(PanelItemWidthLayout.automaticTitle).tag("automatic")
                Text(PanelItemWidthLayout.fillTitle).tag("fill")
                Text(FeatureL10n.string("自定")).tag("custom")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, _ in commit() }
            if mode == "custom" {
                HStack(spacing: 8) {
                    Stepper(FeatureL10n.string("宽度"), value: Binding(get: { draft }, set: {
                        draft = $0; hasEdits = true
                    }), in: minimum...maximum, step: 16)
                    TextField(PanelItemWidthLayout.title, value: Binding(get: { draft }, set: {
                        draft = $0; hasEdits = true
                    }), format: .number.precision(.fractionLength(0)))
                        .frame(width: 64)
                        .onSubmit(commit)
                        .accessibilityIdentifier("panel.itemWidth.value")
                    Button(FeatureL10n.string("应用宽度"), action: commit)
                        .fixedSize()
                        .disabled(!hasEdits)
                        .accessibilityIdentifier("panel.itemWidth.apply")
                }
            }
            Text(FeatureL10n.string("仅调整此内容，面板宽度不变"))
                .font(PluginTypography.detail.font).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(16)
        .frame(width: 280)
        .background(MenuBarPanelPopoverFocusLifecycle(focus: presentationFocus).allowsHitTesting(false))
    }

    private var minimum: Double { MenuBarPanelItemWidth.minimumPoints }
    private var maximum: Double { max(minimum, availableWidth) }

    private func commit() {
        guard draft.isFinite else { draft = preference?.points ?? minimum; hasEdits = false; return }
        presentationFocus.end()
        draft = min(maximum, max(minimum, draft.rounded()))
        hasEdits = false
        onCommit(mode == "custom" ? .custom(draft) : mode == "fill" ? .fill : nil)
    }
}

enum PanelCompactSwitchLayout {
    static let span = PluginPanelWidgetSpan(width: 2, height: 8)!
    static let spacing: CGFloat = 8
    static let horizontalThreshold: CGFloat = 220
    static let contentPadding: CGFloat = 10
    static let symbolWidth: CGFloat = 16
    static let labelSpacing: CGFloat = 6
    static let switchWidth: CGFloat = 44
    static let switchHeight: CGFloat = 22

    static func height(title: String, width: CGFloat) -> CGFloat {
        let horizontal = width >= horizontalThreshold
        let textWidth = max(1, width - contentPadding * 2 - symbolWidth - labelSpacing
            - (horizontal ? switchWidth + spacing : 0))
        let font = PluginTypography.control.nsFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let bounds = (title as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let labelHeight = max(symbolWidth, min(lineHeight * 2, ceil(bounds.height)))
        let contentHeight = horizontal ? max(labelHeight, switchHeight) : labelHeight + labelSpacing + switchHeight
        return ceil((contentHeight + contentPadding * 2) / 8) * 8
    }
}

extension PluginPanelRowSnapshot {
    var compactLayoutWidget: PluginPanelWidgetSnapshot? {
        guard usesCompactPresentation else { return nil }
        return PluginPanelWidgetSnapshot(id: id, title: title, iconName: iconName, iconTint: iconTint,
            description: description, helpText: helpText, descriptionTone: descriptionTone,
            span: PanelCompactSwitchLayout.span, isActive: isOn, isEnabled: isEnabled, pluginID: pluginID)
    }
}

/// Uses the existing row action and snapshot; resizing never creates plugin work.
struct PanelCompactSwitchView: View {
    let item: PluginPanelRowSnapshot
    let onChange: (Bool) -> Void
    @Environment(\.menuBarPanelTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width >= PanelCompactSwitchLayout.horizontalThreshold {
                    HStack(spacing: PanelCompactSwitchLayout.spacing) {
                        label
                        control
                    }
                } else {
                    VStack(alignment: .leading, spacing: PanelCompactSwitchLayout.labelSpacing) {
                        label
                        HStack { Spacer(minLength: 0); control }
                    }
                }
            }
            .padding(PanelCompactSwitchLayout.contentPadding)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
        .background(theme.surfaces.control, in: RoundedRectangle(cornerRadius: MenuBarPanelLayout.cornerRadius))
        .disabled(!item.isEnabled)
        .help(item.title + (item.helpText.isEmpty ? "" : "\n" + item.helpText))
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: PanelCompactSwitchLayout.labelSpacing) {
            Image(systemName: PluginSystemImage.resolvedName(item.iconName))
                .frame(width: PanelCompactSwitchLayout.symbolWidth)
            Text(item.title)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(PluginTypography.control.font)
        .foregroundStyle(theme.text.primary)
        .accessibilityHidden(true)
    }

    private var control: some View {
        Toggle(item.title, isOn: Binding(get: { item.isOn }, set: { onChange($0) }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("panel.compactSwitch.\(item.id)")
    }

}

struct PanelWidthPicker: View {
    let preferredWidth: Double
    let maximumWidth: CGFloat
    let onCommit: (Double) -> Void
    @State private var draft: Double
    @State private var hasEdits = false
    @State private var presentationFocus = MenuBarPanelPopoverFocus()

    init(preferredWidth: Double, maximumWidth: CGFloat, onCommit: @escaping (Double) -> Void) {
        self.preferredWidth = preferredWidth
        self.maximumWidth = maximumWidth
        self.onCommit = onCommit
        _draft = State(initialValue: preferredWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MenuBarPanelWidth.title).font(PluginTypography.sectionTitle.font)
            HStack(spacing: 8) {
                ForEach(1...min(3, maximumColumns), id: \.self) { count in
                    Button { applyColumns(count) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .opacity(selectedColumns == count ? 1 : 0)
                                .accessibilityHidden(true)
                            Text(MenuBarPanelWidth.columnTitle(count))
                        }
                    }
                        .tint(selectedColumns == count ? .accentColor : .secondary)
                        .accessibilityAddTraits(selectedColumns == count ? .isSelected : [])
                        .accessibilityIdentifier("panel.width.columns.\(count)")
                }
            }
            .buttonStyle(.bordered)
            // Swift 6.3.3 crashes when an isolated method reference is used as this setter.
            Stepper(value: Binding(get: {
                MenuBarPanelWidth.columns(forSurfaceWidth: feedbackWidth - MenuBarPanelLayout.outerPadding * 2)
            }, set: { applyColumns($0) }), in: 1...maximumColumns) {
                Text(MenuBarPanelWidth.columnTitle(MenuBarPanelWidth.columns(
                    forSurfaceWidth: feedbackWidth - MenuBarPanelLayout.outerPadding * 2)))
            }
            HStack(spacing: 8) {
                Text(FeatureL10n.string("宽度"))
                TextField(MenuBarPanelWidth.title, value: Binding(get: { draft }, set: { draft = $0; hasEdits = true }), format: .number.precision(.fractionLength(0)))
                    .frame(width: 88)
                    .onSubmit(commit)
                    .accessibilityIdentifier("panel.width.value")
                Button(FeatureL10n.string("应用宽度"), action: commit)
                    .fixedSize()
                    .disabled(!hasEdits || validatedDraft == nil)
                    .accessibilityIdentifier("panel.width.apply")
            }
            Text(FeatureL10n.string("选择列数后拖放内容，也可输入精确宽度"))
                .font(PluginTypography.detail.font).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(16)
        .frame(width: 320)
        .background(MenuBarPanelPopoverFocusLifecycle(focus: presentationFocus).allowsHitTesting(false))
        .onChange(of: preferredWidth) { _, width in if !hasEdits { draft = width } }
    }

    private var validatedDraft: Double? {
        MenuBarPanelWidth.validatedDraft(draft, maximum: maximumWidth)
    }

    private var feedbackWidth: CGFloat {
        validatedDraft ?? MenuBarPanelWidth.resolved(preferred: preferredWidth, maximum: maximumWidth)
    }

    private var maximumColumns: Int {
        MenuBarPanelWidth.columns(forSurfaceWidth: maximumWidth - MenuBarPanelLayout.outerPadding * 2)
    }

    private var selectedColumns: Int {
        MenuBarPanelWidth.columns(forSurfaceWidth:
            min(maximumWidth, preferredWidth) - MenuBarPanelLayout.outerPadding * 2)
    }

    private func applyColumns(_ count: Int) {
        draft = MenuBarPanelWidth.width(forColumns: count)
        commit()
    }

    private func commit() {
        guard let width = validatedDraft else { return }
        // Resizing repositions this child popover. Release its field editor before
        // AppKit rebuilds the parent/child window responder chain.
        presentationFocus.end()
        draft = width
        hasEdits = false
        onCommit(width)
    }
}
