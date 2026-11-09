import AppKit
import SwiftUI
import MacToolsPluginKit

@MainActor
final class TrackpadSettingsSearchFocusController: ObservableObject {
    @Published private(set) var requestID: UInt = 0
    private var consumedRequestID: UInt = 0

    func requestFocus() {
        requestID &+= 1
    }

    func consumePendingFocusRequest() -> Bool {
        guard consumedRequestID != requestID else { return false }
        consumedRequestID = requestID
        return true
    }
}

struct TrackpadActionPickerAccessibility: Equatable {
    let confirmationValue: String?

    init(isSafe: Bool, confirmationRequiredText: String) {
        confirmationValue = isSafe ? nil : confirmationRequiredText
    }
}

enum TrackpadMappingSearchPresentation {
    static func showsSearchField(
        isSearchRequested: Bool,
        mappingsAreEmpty _: Bool
    ) -> Bool {
        isSearchRequested
    }
}

private struct TrackpadConfirmationAccessibilityModifier: ViewModifier {
    let value: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let value {
            content.accessibilityValue(Text(value))
        } else {
            content
        }
    }
}

struct TrackpadGestureTestingHeaderAccessory: View {
    @ObservedObject var store: TrackpadGestureStore
    let localization: PluginLocalization
    let onSetTesting: (Bool) -> Void

    @ViewBuilder
    var body: some View {
        let title = store.isTesting
            ? localization.string("settings.testing.stop", defaultValue: "停止测试")
            : localization.string("settings.testing.inactive", defaultValue: "测试手势")
        let button = Button {
            onSetTesting(!store.isTesting)
        } label: {
            Label(
                title,
                systemImage: store.isTesting ? "stop.circle.fill" : "waveform.path"
            )
            .font(PluginSettingsTheme.Typography.controlLabel)
        }
        .controlSize(.small)
        .fixedSize()
        .help(title)
        .accessibilityLabel(Text(title))

        if store.isTesting {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

struct TrackpadGesturesSettingsView: View {
    enum SectionKind {
        case mappings
        case typingProtection
    }

    @ObservedObject var store: TrackpadGestureStore
    @ObservedObject var testingModel: TrackpadGestureTestingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    let localization: PluginLocalization
    let actionHostContext: TrackpadActionHostContext?
    let isGestureOwned: (TrackpadGesture) -> Bool
    let onChange: () -> Void
    let onSetTesting: (Bool) -> Void
    let onSetTestingMode: (TrackpadGestureTestingMode?) -> Void
    let section: SectionKind
    @ObservedObject var searchFocusController = TrackpadSettingsSearchFocusController()

    @State private var editingDraft: TrackpadGestureMappingDraft?
    @State private var isShowingTipTapGuide = false
    @State private var mappingSearchQuery = ""
    @State private var isShowingMappingSearch = false
    @FocusState private var isMappingSearchFocused: Bool

    @ViewBuilder
    var body: some View {
        Group {
            switch section {
            case .mappings:
                mappingsContent
            case .typingProtection:
                typingProtectionSection
            }
        }
        .onAppear {
            focusMappingSearchIfRequested()
        }
        .onChange(of: searchFocusController.requestID) {
            focusMappingSearchIfRequested()
        }
    }

    private func focusMappingSearchIfRequested() {
        guard section == .mappings,
              searchFocusController.consumePendingFocusRequest() else {
            return
        }
        isShowingMappingSearch = true
        DispatchQueue.main.async {
            isMappingSearchFocused = true
        }
    }

    private var mappingsContent: some View {
        mappingsSection
        .sheet(item: $editingDraft) { draft in
            TrackpadGestureEditor(
                draft: draft,
                store: store,
                localization: localization,
                actionHostContext: actionHostContext,
                onCancel: { editingDraft = nil },
                onDelete: store.mappings.contains(where: { $0.id == draft.id }) ? {
                    guard store.delete(id: draft.id) else { return }
                    editingDraft = nil
                    onChange()
                } : nil,
                onSave: { mapping in
                    let previousMappings = store.mappings
                    guard store.save(mapping) else { return }
                    editingDraft = nil
                    if store.mappings != previousMappings {
                        onChange()
                    }
                }
            )
            .environment(\.layoutDirection, layoutDirection)
            .environment(\.locale, locale)
        }
        .onChange(of: store.testRecognitionSequence) { _, _ in
            guard let gesture = store.lastTestGesture else { return }
            announceRecognizedTestGesture(gesture)
        }
    }

    private var typingProtectionSection: some View {
        VStack(spacing: 0) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(
                        alignment: .leading,
                        spacing: PluginSettingsTheme.Spacing.rowTitleDescription
                    ) {
                        Text(localization.string(
                            "settings.typing.ignore.title",
                            defaultValue: "输入时忽略手势"
                        ))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        Text(localization.string(
                            "settings.typing.ignore.description",
                            defaultValue: "按下普通按键时暂停识别，避免手掌误触触控板。"
                        ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                    Toggle("", isOn: Binding(
                        get: { store.ignoresGesturesWhileTyping },
                        set: { isEnabled in
                            if store.setIgnoresGesturesWhileTyping(isEnabled) {
                                onChange()
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text(localization.string(
                        "settings.typing.ignore.title",
                        defaultValue: "输入时忽略手势"
                    )))
                    .accessibilityHint(Text(localization.string(
                        "settings.typing.ignore.description",
                        defaultValue: "按下普通按键时暂停识别，避免手掌误触触控板。"
                    )))
                }
                .pluginSettingsListRowPadding(interactive: true)

                PluginSettingsListDivider()

                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(
                        alignment: .leading,
                        spacing: PluginSettingsTheme.Spacing.rowTitleDescription
                    ) {
                        Text(localization.string(
                            "settings.typing.grace.title",
                            defaultValue: "停止输入后的延迟"
                        ))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        Text(localization.string(
                            "settings.typing.grace.description",
                            defaultValue: "最后一次按键后继续暂停识别；较短更灵敏，较长可减少更多误触；默认 0.4 秒。"
                        ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                    PluginSettingsSlider(
                        value: Binding(
                            get: { store.typingGracePeriod },
                            set: { gracePeriod in
                                if store.setTypingGracePeriod(gracePeriod) {
                                    onChange()
                                }
                            }
                        ),
                        in: TrackpadTypingSuppressionGate.minimumGracePeriod
                            ... TrackpadTypingSuppressionGate.maximumGracePeriod,
                        step: 0.1
                    )
                    .frame(minWidth: 120, idealWidth: 150, maxWidth: 180)
                    .disabled(!store.ignoresGesturesWhileTyping)
                    .accessibilityLabel(Text(localization.string(
                        "settings.typing.grace.title",
                        defaultValue: "停止输入后的延迟"
                    )))
                    .accessibilityValue(Text(typingGracePeriodText))
                    .accessibilityHint(Text(localization.string(
                        "settings.typing.grace.description",
                        defaultValue: "最后一次按键后继续暂停识别；较短更灵敏，较长可减少更多误触；默认 0.4 秒。"
                    )))
                    Text(localization.format(
                        "settings.typing.grace.valueFormat",
                        defaultValue: "%.1f 秒",
                        store.typingGracePeriod
                    ))
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .frame(width: 52, alignment: .trailing)
                }
                .pluginSettingsListRowPadding(interactive: true)
        }
    }

    private var mappingsSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Spacer(minLength: PluginSettingsTheme.Spacing.controlCluster)

                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    ViewThatFits(in: .horizontal) {
                        mappingToolbar(compact: false)
                        mappingToolbar(compact: true)
                    }
                }
                .popover(isPresented: $isShowingTipTapGuide, arrowEdge: .top) {
                    tipTapGuide
                }
            }
            .pluginSettingsListRowPadding()

            if TrackpadMappingSearchPresentation.showsSearchField(
                isSearchRequested: isShowingMappingSearch,
                mappingsAreEmpty: store.mappings.isEmpty
            ) {
                mappingSearchField
            }

            if store.isTesting {
                testingStatusBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                TrackpadGestureTestingPanel(
                    model: testingModel,
                    store: store,
                    localization: localization,
                    actionTitle: mappingActionTitle,
                    onSetMode: onSetTestingMode
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if !enabledOwnedOverlappingTapFingerCounts.isEmpty {
                overlappingTapBehaviorNotice
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if store.mappings.isEmpty {
                emptyState
            } else {
                if visibleMappings.isEmpty {
                    noMatchingMappingsState
                } else {
                    mappingList
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.isTesting)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: enabledOwnedOverlappingTapFingerCounts
        )
    }

    private var enabledOwnedOverlappingTapFingerCounts: [Int] {
        store.enabledOverlappingTapFingerCounts(where: isGestureOwned)
    }

    private func mappingToolbar(compact: Bool) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            mappingViewMenu(compact: compact)
            tipTapGuideButton
            addMappingButton(compact: compact)
        }
        .fixedSize()
    }

    private func mappingViewMenu(compact: Bool) -> some View {
        let title = localization.string(
            "settings.mappings.viewOptions",
            defaultValue: "查看选项"
        )
        return Menu {
            Button {
                toggleMappingSearch()
            } label: {
                Label(
                    localization.string(
                        "settings.mappings.search",
                        defaultValue: "搜索映射"
                    ),
                    systemImage: isShowingMappingSearch ? "checkmark" : "magnifyingglass"
                )
            }

            Divider()

            Menu {
                ForEach(TrackpadGestureMappingSort.allCases, id: \.self) { sort in
                    Button {
                        store.setMappingSort(sort)
                    } label: {
                        menuChoiceLabel(
                            sort.title(localization: localization),
                            selected: store.mappingSort == sort
                        )
                    }
                }
            } label: {
                Label(
                    localization.string(
                        "settings.mappings.sort.title",
                        defaultValue: "排序方式"
                    ),
                    systemImage: "arrow.up.arrow.down"
                )
            }

            Menu {
                ForEach(TrackpadGestureMappingStatusFilter.allCases, id: \.self) { filter in
                    Button {
                        store.setMappingStatusFilter(filter)
                    } label: {
                        menuChoiceLabel(
                            filter.title(localization: localization),
                            selected: store.mappingStatusFilter == filter
                        )
                    }
                }
            } label: {
                Label(
                    localization.string(
                        "settings.mappings.filter.status",
                        defaultValue: "状态"
                    ),
                    systemImage: "checkmark.circle"
                )
            }

            Menu {
                ForEach(TrackpadGestureMappingActionFilter.allCases, id: \.self) { filter in
                    Button {
                        store.setMappingActionFilter(filter)
                    } label: {
                        menuChoiceLabel(
                            filter.title(localization: localization),
                            selected: store.mappingActionFilter == filter
                        )
                    }
                }
            } label: {
                Label(
                    localization.string(
                        "settings.mappings.filter.action",
                        defaultValue: "操作类型"
                    ),
                    systemImage: "bolt.circle"
                )
            }

            if hasCustomizedMappingView {
                Divider()

                Button {
                    resetMappingView()
                } label: {
                    Label(
                        localization.string(
                            "settings.mappings.view.reset",
                            defaultValue: "还原默认视图"
                        ),
                        systemImage: "arrow.counterclockwise"
                    )
                }
            }
        } label: {
            if compact {
                Image(systemName: hasCustomizedMappingView
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(hasCustomizedMappingView ? Color.accentColor : Color.primary)
            } else {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: hasCustomizedMappingView
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(
                            hasCustomizedMappingView ? Color.accentColor : Color.primary
                        )
                }
                .font(PluginSettingsTheme.Typography.controlLabel)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help(title)
        .accessibilityLabel(Text(title))
    }

    @ViewBuilder
    private func menuChoiceLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var tipTapGuideButton: some View {
        let title = localization.string(
            "settings.mappings.tipTapGuide",
            defaultValue: "了解 TipTap"
        )
        return Button {
            isShowingTipTapGuide.toggle()
        } label: {
            Label(title, systemImage: "questionmark.circle")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(Text(title))
    }

    private func addMappingButton(compact: Bool) -> some View {
        let title = localization.string("settings.mappings.add", defaultValue: "添加手势")
        return Button(action: addMapping) {
            if compact {
                Label(title, systemImage: "plus")
                    .labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: "plus")
                    .font(PluginSettingsTheme.Typography.controlLabel)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(Text(title))
        .disabled(store.mappings.count == TrackpadGesture.configurableCases.count)
    }

    private var testingStatusBanner: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: "waveform.path")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(
                    cornerRadius: PluginSettingsTheme.Radius.control,
                    style: .continuous
                ))
                .accessibilityHidden(true)

            VStack(
                alignment: .leading,
                spacing: PluginSettingsTheme.Spacing.rowTitleDescription
            ) {
                Text(localization.string(
                    "settings.testing.active",
                    defaultValue: "正在识别手势"
                ))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(testingDescription)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Button {
                onSetTesting(false)
            } label: {
                Text(localization.string(
                    "settings.testing.stop",
                    defaultValue: "停止测试"
                ))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .pluginSettingsListRowPadding(interactive: true)
        .background(PluginSettingsTheme.Palette.recordingBackground)
        .accessibilityElement(children: .contain)
    }

    private var overlappingTapBehaviorNotice: some View {
        Label {
            Text(localization.string(
                "settings.mappings.overlappingTapBehavior",
                defaultValue: "同时启用相同手指数量的轻点和双击时，双击会先执行轻点操作，再执行双击操作。"
            ))
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentColor)
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .foregroundStyle(.secondary)
        .pluginSettingsListRowPadding()
        .background(Color.accentColor.opacity(0.06))
    }

    private func toggleMappingSearch() {
        withAnimation(.easeOut(duration: 0.16)) {
            isShowingMappingSearch.toggle()
            if !isShowingMappingSearch {
                mappingSearchQuery = ""
            }
        }
        isMappingSearchFocused = isShowingMappingSearch
    }

    private var tipTapGuide: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(
                localization.string(
                    "settings.mappings.tipTapGuide",
                    defaultValue: "了解 TipTap"
                ),
                systemImage: "hand.tap"
            )
            .font(PluginSettingsTheme.Typography.sectionTitle)

            Label(
                localization.string(
                    "settings.mappings.tipTapGuide.hold",
                    defaultValue: "先放下 1 或 2 指并保持不动。"
                ),
                systemImage: "1.circle"
            )
            Label(
                localization.string(
                    "settings.mappings.tipTapGuide.tap",
                    defaultValue: "用另一指在固定手指组的左侧或右侧轻点。"
                ),
                systemImage: "2.circle"
            )
            Label(
                localization.string(
                    "settings.mappings.tipTapGuide.repeat",
                    defaultValue: "只抬起轻点手指；固定手指保持接触即可继续轻点。"
                ),
                systemImage: "3.circle"
            )

            Label(
                localization.string(
                    "settings.mappings.tipTapGuide.middle",
                    defaultValue: "固定两指时，“中间”表示在两指之间轻点。"
                ),
                systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)

            Divider()

            Label(
                localization.format(
                    "settings.mappings.tipTapGuide.test",
                    defaultValue: "可使用“%@”练习，不会执行已配置的操作。",
                    localization.string(
                        "settings.testing.inactive",
                        defaultValue: "测试手势"
                    )
                ),
                systemImage: "waveform.path"
            )
            .foregroundStyle(.secondary)
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .fixedSize(horizontal: false, vertical: true)
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
        .frame(width: 360, alignment: .leading)
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: "hand.tap")
                    .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon))
                    .foregroundStyle(.secondary)
                Text(localization.string("settings.empty.title", defaultValue: "尚未配置手势"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(localization.string(
                    "settings.empty.description",
                    defaultValue: "仅添加你需要使用的触控板手势。"
                ))
                .font(PluginSettingsTheme.Typography.pageDescription)
                .foregroundStyle(.secondary)
                Button(action: addMapping) {
                    Text(localization.string("settings.mappings.add", defaultValue: "添加手势"))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
            Spacer()
        }
    }

    private var mappingSearchField: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                localization.string(
                    "settings.mappings.search.placeholder",
                    defaultValue: "搜索手势、操作或提供者"
                ),
                text: $mappingSearchQuery
            )
            .textFieldStyle(.plain)
            .focused($isMappingSearchFocused)
            .accessibilityIdentifier("mactools.trackpad.mapping-search")

            if !mappingSearchQuery.isEmpty {
                Button {
                    mappingSearchQuery = ""
                    isMappingSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(localization.string(
                    "settings.mappings.search.clear",
                    defaultValue: "清除搜索"
                ))
                .accessibilityLabel(Text(localization.string(
                    "settings.mappings.search.clear",
                    defaultValue: "清除搜索"
                )))
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
        .background(
            PluginSettingsTheme.Palette.fieldBackground,
            in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control, style: .continuous)
                .strokeBorder(PluginSettingsTheme.Palette.separator, lineWidth: PluginSettingsTheme.Stroke.hairline)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var noMatchingMappingsState: some View {
        VStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon))
                .foregroundStyle(.secondary)
            Text(localization.string(
                "settings.mappings.noMatches.title",
                defaultValue: "没有符合条件的映射"
            ))
            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
            Button {
                resetMappingView()
            } label: {
                Text(localization.string(
                    "settings.mappings.view.reset",
                    defaultValue: "还原默认视图"
                ))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
    }

    private var mappingList: some View {
        let mappings = visibleMappings
        return VStack(spacing: 0) {
            ForEach(mappings) { mapping in
                mappingRow(mapping)
                if mapping.id != mappings.last?.id {
                    PluginSettingsListDivider()
                }
            }
        }
    }

    private func mappingRow(_ mapping: TrackpadGestureMapping) -> some View {
        let gestureTitle = mapping.gesture.title(localization: localization)
        let editTitle = localization.string("settings.mapping.edit", defaultValue: "编辑映射")

        return HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Button {
                stopTestingBeforeConfiguration()
                editingDraft = TrackpadGestureMappingDraft(mapping: mapping)
            } label: {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Image(systemName: PluginSystemImage.resolvedName(mapping.gesture.systemImage))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 9))

                    VStack(
                        alignment: .leading,
                        spacing: PluginSettingsTheme.Spacing.rowTitleDescription
                    ) {
                        HStack(spacing: 7) {
                            Text(mapping.gesture.title(localization: localization))
                                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                                .lineLimit(1)
                            Text(mapping.gesture.category.title(localization: localization))
                                .font(PluginSettingsTheme.Typography.statusBadge)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.10))
                                .clipShape(Capsule())
                        }
                        HStack(spacing: 5) {
                            Image(systemName: PluginSystemImage.resolvedName(
                                mappingActionSystemImage(mapping.action)
                            ))
                            .frame(width: 13)
                            Text(mappingActionTitle(mapping.action))
                                .lineLimit(1)
                        }
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        if mapping.isEnabled && !isGestureOwned(mapping.gesture) {
                            Text(localization.string(
                                "settings.mapping.usedByAnotherPlugin",
                                defaultValue: "此手势已被另一个插件使用。"
                            ))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.forward")
                        .pluginSettingsRowIconStyle(.secondary)
                        .frame(
                            width: PluginSettingsTheme.Size.rowIcon,
                            height: PluginSettingsTheme.Size.controlHeight
                        )
                }
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, minHeight: PluginSettingsTheme.Size.controlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(gestureTitle)
            .accessibilityValue(mappingActionTitle(mapping.action))
            .accessibilityHint(editTitle)
            .onHover { hovering in
                TrackpadSettingsCursor.update(isHovering: hovering)
            }
            .onDisappear {
                TrackpadSettingsCursor.reset()
            }

            Toggle(gestureTitle, isOn: Binding(
                get: { mapping.isEnabled },
                set: { enabled in
                    stopTestingBeforeConfiguration()
                    guard store.setEnabled(enabled, id: mapping.id) else { return }
                    onChange()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(gestureTitle)

            Button {
                onSetTestingMode(.practice(mapping.gesture))
            } label: {
                Image(systemName: testingModel.mode == .practice(mapping.gesture)
                    ? "scope"
                    : "target")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(localization.format(
                "settings.testing.practiceGestureFormat",
                defaultValue: "练习“%@”",
                gestureTitle
            ))
            .accessibilityLabel(Text(localization.format(
                "settings.testing.practiceGestureFormat",
                defaultValue: "练习“%@”",
                gestureTitle
            )))
            .accessibilityAddTraits(
                TrackpadGestureTestingModeAccessibilityState(mode: testingModel.mode)
                    .isPracticeSelected(mapping.gesture) ? .isSelected : []
            )
            .accessibilityValue(Text(localization.string(
                TrackpadGestureTestingModeAccessibilityState(mode: testingModel.mode)
                    .isPracticeSelected(mapping.gesture)
                    ? "settings.testing.mode.accessibility.active"
                    : "settings.testing.mode.accessibility.inactive",
                defaultValue: TrackpadGestureTestingModeAccessibilityState(mode: testingModel.mode)
                    .isPracticeSelected(mapping.gesture)
                    ? "当前模式"
                    : "未启用"
            )))
        }
        .pluginSettingsListRowPadding(interactive: true)
        .contextMenu {
            mappingManagementMenuItems(mapping)
        }
    }

    @ViewBuilder
    private func mappingManagementMenuItems(_ mapping: TrackpadGestureMapping) -> some View {
        Button {
            onSetTestingMode(.practice(mapping.gesture))
        } label: {
            Label(
                localization.string(
                    "settings.testing.mode.practice",
                    defaultValue: "练习一个手势"
                ),
                systemImage: "target"
            )
        }

        Divider()

        Button {
            stopTestingBeforeConfiguration()
            editingDraft = TrackpadGestureMappingDraft(mapping: mapping)
        } label: {
            Label(
                localization.string("settings.mapping.edit", defaultValue: "编辑映射"),
                systemImage: "pencil"
            )
        }

        Button {
            stopTestingBeforeConfiguration()
            guard store.setEnabled(!mapping.isEnabled, id: mapping.id) else { return }
            onChange()
        } label: {
            Label(
                mapping.isEnabled
                    ? localization.string("settings.mapping.disable", defaultValue: "停用")
                    : localization.string("settings.mapping.enable", defaultValue: "启用"),
                systemImage: mapping.isEnabled ? "pause.circle" : "play.circle"
            )
        }

        Divider()

        Button(role: .destructive) {
            stopTestingBeforeConfiguration()
            guard store.delete(id: mapping.id) else { return }
            onChange()
        } label: {
            Label(
                localization.string("settings.mapping.delete", defaultValue: "删除"),
                systemImage: "trash"
            )
        }
    }

    private var hasCustomizedMappingView: Bool {
        !mappingSearchQuery.isEmpty
            || store.mappingSort != .gesture
            || store.mappingStatusFilter != .all
            || store.mappingActionFilter != .all
    }

    private var visibleMappings: [TrackpadGestureMapping] {
        let sourceIndices = Dictionary(
            uniqueKeysWithValues: store.mappings.enumerated().map { ($0.element.id, $0.offset) }
        )
        let query = mappingSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.mappings
            .filter { mappingMatchesStatus($0) && mappingMatchesActionType($0) }
            .filter { mapping in
                guard !query.isEmpty else { return true }
                let ownerTitle: String? = if case let .action(reference) = mapping.action {
                    actionHostContext?.item(for: reference)?.ownerTitle
                } else {
                    nil
                }
                return [
                    mapping.gesture.title(localization: localization),
                    mapping.gesture.category.title(localization: localization),
                    mappingActionTitle(mapping.action),
                    ownerTitle,
                ]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            .sorted { lhs, rhs in
                mappingComesBefore(
                    lhs,
                    rhs,
                    sourceIndices: sourceIndices
                )
            }
    }

    private func mappingMatchesStatus(_ mapping: TrackpadGestureMapping) -> Bool {
        switch store.mappingStatusFilter {
        case .all: true
        case .enabled: mapping.isEnabled
        case .disabled: !mapping.isEnabled
        }
    }

    private func mappingMatchesActionType(_ mapping: TrackpadGestureMapping) -> Bool {
        switch (store.mappingActionFilter, mapping.action) {
        case (.all, _), (.macToolsAction, .action),
             (.keyboardShortcut, .keyboardShortcut), (.singleKey, .keyTap),
             (.middleClick, .middleClick):
            true
        default:
            false
        }
    }

    private func mappingComesBefore(
        _ lhs: TrackpadGestureMapping,
        _ rhs: TrackpadGestureMapping,
        sourceIndices: [UUID: Int]
    ) -> Bool {
        switch store.mappingSort {
        case .gesture:
            return lhs.gesture.settingsOrder < rhs.gesture.settingsOrder
        case .enabledFirst:
            if lhs.isEnabled != rhs.isEnabled {
                return lhs.isEnabled && !rhs.isEnabled
            }
            return lhs.gesture.settingsOrder < rhs.gesture.settingsOrder
        case .actionName:
            let comparison = mappingActionTitle(lhs.action)
                .localizedStandardCompare(mappingActionTitle(rhs.action))
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.gesture.settingsOrder < rhs.gesture.settingsOrder
        case .addedOrder:
            return (sourceIndices[lhs.id] ?? .max) < (sourceIndices[rhs.id] ?? .max)
        }
    }

    private func resetMappingView() {
        mappingSearchQuery = ""
        store.resetMappingViewPreferences()
        isMappingSearchFocused = isShowingMappingSearch
    }

    private var testingDescription: String {
        let status = TrackpadGestureTestingStatusResolver.resolve(
            snapshot: testingModel.selectedSnapshot,
            retainedRecognition: testingModel.selectedRecognizedGesture,
            retainedContactPattern: testingModel.selectedContactPatternGesture,
            retainedRejection: testingModel.selectedRejection
        )
        if case let .recognized(gesture) = status {
            return localization.format(
                "settings.testing.recognizedFormat",
                defaultValue: "已识别：%@。停止测试前，已配置的操作不会执行。",
                gesture.title(localization: localization)
            )
        }
        if case let .contactPatternDetected(gesture) = status {
            return localization.format(
                "settings.testing.contactPatternFormat",
                defaultValue: "已检测到 %@ 的接触动作。实际映射仍需关联 macOS 轻点点击。",
                gesture.title(localization: localization)
            )
        }
        return localization.string(
            "settings.testing.description",
            defaultValue: "测试模式已开启。停止测试前，已配置的操作不会执行。"
        )
    }

    private var typingGracePeriodText: String {
        localization.format(
            "settings.typing.grace.valueFormat",
            defaultValue: "%.1f 秒",
            store.typingGracePeriod
        )
    }

    private func announceRecognizedTestGesture(_ gesture: TrackpadGesture) {
        let announcement = localization.format(
            "settings.testing.recognizedFormat",
            defaultValue: "已识别：%@。停止测试前，已配置的操作不会执行。",
            gesture.title(localization: localization)
        )
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func addMapping() {
        guard let gesture = store.availableGestures().first else {
            return
        }
        stopTestingBeforeConfiguration()
        editingDraft = TrackpadGestureMappingDraft(gesture: gesture)
    }

    private func stopTestingBeforeConfiguration() {
        guard store.isTesting else { return }
        onSetTesting(false)
    }

    private func mappingActionTitle(_ action: TrackpadGestureAction) -> String {
        if case let .action(reference) = action {
            return actionHostContext?.item(for: reference)?.title
                ?? localization.string(
                    "editor.action.unavailable",
                    defaultValue: "不可用的 MacTools 操作"
                )
        }
        return action.title(localization: localization)
    }

    private func mappingActionSystemImage(_ action: TrackpadGestureAction) -> String {
        switch action {
        case let .action(reference):
            actionHostContext?.item(for: reference)?.systemImage ?? "questionmark.square.dashed"
        case .keyboardShortcut:
            "keyboard"
        case .keyTap:
            "keyboard.badge.ellipsis"
        case .middleClick:
            "computermouse"
        }
    }
}

private enum TrackpadGestureEditorActionKind: String, Identifiable {
    case none
    case action
    case keyboardShortcut
    case keyTap
    case middleClick

    var id: String { rawValue }
}

private struct TrackpadGestureMappingDraft: Identifiable {
    let id: UUID
    var gesture: TrackpadGesture
    var actionKind: TrackpadGestureEditorActionKind
    var actionReference: ActionReference?
    var shortcut: ShortcutBinding?
    var keyTap: KeyboardKeyTap?
    var isEnabled: Bool

    init(gesture: TrackpadGesture) {
        self.id = UUID()
        self.gesture = gesture
        self.actionKind = .none
        self.actionReference = nil
        self.shortcut = nil
        self.keyTap = nil
        self.isEnabled = true
    }

    init(mapping: TrackpadGestureMapping) {
        self.id = mapping.id
        self.gesture = mapping.gesture
        self.isEnabled = mapping.isEnabled
        switch mapping.action {
        case let .action(reference):
            self.actionKind = .action
            self.actionReference = reference
            self.shortcut = nil
            self.keyTap = nil
        case let .keyboardShortcut(shortcut):
            self.actionKind = .keyboardShortcut
            self.actionReference = nil
            self.shortcut = shortcut
            self.keyTap = nil
        case let .keyTap(keyTap):
            self.actionKind = .keyTap
            self.actionReference = nil
            self.shortcut = nil
            self.keyTap = keyTap
        case .middleClick:
            self.actionKind = .middleClick
            self.actionReference = nil
            self.shortcut = nil
            self.keyTap = nil
        }
    }

    var mapping: TrackpadGestureMapping? {
        let action: TrackpadGestureAction
        switch actionKind {
        case .none:
            return nil
        case .action:
            guard let actionReference else { return nil }
            action = .action(actionReference)
        case .keyboardShortcut:
            guard let shortcut, shortcut.isValid else { return nil }
            action = .keyboardShortcut(shortcut)
        case .keyTap:
            guard let keyTap else { return nil }
            action = .keyTap(keyTap)
        case .middleClick:
            action = .middleClick
        }
        return TrackpadGestureMapping(
            id: id,
            gesture: gesture,
            action: action,
            isEnabled: isEnabled
        )
    }
}

private extension TrackpadGestureMappingSort {
    func title(localization: PluginLocalization) -> String {
        switch self {
        case .gesture:
            localization.string("settings.mappings.sort.gesture", defaultValue: "手势顺序")
        case .enabledFirst:
            localization.string("settings.mappings.sort.enabled", defaultValue: "已启用优先")
        case .actionName:
            localization.string("settings.mappings.sort.action", defaultValue: "操作名称")
        case .addedOrder:
            localization.string("settings.mappings.sort.added", defaultValue: "添加顺序")
        }
    }
}

private extension TrackpadGestureMappingStatusFilter {
    func title(localization: PluginLocalization) -> String {
        switch self {
        case .all:
            localization.string("settings.mappings.filter.all", defaultValue: "全部")
        case .enabled:
            localization.string("settings.mappings.filter.enabled", defaultValue: "已启用")
        case .disabled:
            localization.string("settings.mappings.filter.disabled", defaultValue: "已停用")
        }
    }
}

private extension TrackpadGestureMappingActionFilter {
    func title(localization: PluginLocalization) -> String {
        switch self {
        case .all:
            localization.string("settings.mappings.filter.action.all", defaultValue: "所有操作")
        case .macToolsAction:
            localization.string(
                "settings.mappings.filter.action.macTools",
                defaultValue: "MacTools 操作"
            )
        case .keyboardShortcut:
            localization.string("action.shortcut", defaultValue: "键盘快捷键")
        case .singleKey:
            localization.string("action.singleKey", defaultValue: "单键")
        case .middleClick:
            localization.string("action.middleClick", defaultValue: "鼠标中键")
        }
    }
}

private enum TrackpadGestureCategory: String, CaseIterable, Identifiable {
    case tipTap
    case tap
    case doubleTap
    case click
    case longTouch

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .tipTap, .tap, .doubleTap: "hand.tap"
        case .click: "computermouse"
        case .longTouch: "hand.raised"
        }
    }

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .tipTap:
            localization.string("gesture.category.tipTap", defaultValue: "TipTap")
        case .tap:
            localization.string("gesture.category.tap", defaultValue: "轻点")
        case .doubleTap:
            localization.string("gesture.category.doubleTap", defaultValue: "双击")
        case .click:
            localization.string("gesture.category.click", defaultValue: "按下点击")
        case .longTouch:
            localization.string("gesture.category.longTouch", defaultValue: "长触")
        }
    }
}

private struct TrackpadGesturePickerControl: View {
    let gestures: [TrackpadGesture]
    let localization: PluginLocalization
    let actionKind: TrackpadGestureEditorActionKind
    @Binding var selection: TrackpadGesture

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: PluginSystemImage.resolvedName(selection.systemImage))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.title(localization: localization))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(selection.category.title(localization: localization))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minWidth: 340, idealWidth: 390, maxWidth: 440, minHeight: 52)
            .contentShape(Rectangle())
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            pickerContent
        }
        .accessibilityIdentifier("mactools.trackpad.gesture-picker")
        .accessibilityLabel(localization.string("editor.gesture.title", defaultValue: "手势"))
        .accessibilityValue(selection.title(localization: localization))
    }

    private var pickerContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(TrackpadGestureCategory.allCases) { category in
                    let categoryGestures = gestures.filter { $0.category == category }
                    if !categoryGestures.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(
                                category.title(localization: localization),
                                systemImage: category.systemImage
                            )
                            .font(PluginSettingsTheme.Typography.sectionTitle)
                            .foregroundStyle(.secondary)

                            ForEach(categoryGestures) { gesture in
                                gestureRow(gesture)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 440, height: 500)
    }

    private func gestureRow(_ gesture: TrackpadGesture) -> some View {
        let hasConflict = !gesture.conflictGuidance(
            localization: localization,
            actionKind: actionKind
        ).isEmpty

        return Button {
            selection = gesture
            isPresented = false
        } label: {
            HStack(spacing: 9) {
                Image(systemName: PluginSystemImage.resolvedName(gesture.systemImage))
                    .frame(width: 20)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(gesture.title(localization: localization))
                        .foregroundStyle(.primary)
                    Text(gesture.demonstration(localization: localization))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if hasConflict {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help(gesture.conflictGuidance(
                            localization: localization,
                            actionKind: actionKind
                        ).joined(separator: "\n"))
                }
                if gesture == selection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                gesture == selection ? Color.accentColor.opacity(0.08) : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mactools.trackpad.gesture-picker.\(gesture.rawValue)")
    }
}

private struct TrackpadGestureEditor: View {
    @ObservedObject var store: TrackpadGestureStore
    let localization: PluginLocalization
    let actionHostContext: TrackpadActionHostContext?
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    let onSave: (TrackpadGestureMapping) -> Void

    @State private var draft: TrackpadGestureMappingDraft

    init(
        draft: TrackpadGestureMappingDraft,
        store: TrackpadGestureStore,
        localization: PluginLocalization,
        actionHostContext: TrackpadActionHostContext?,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)?,
        onSave: @escaping (TrackpadGestureMapping) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.store = store
        self.localization = localization
        self.actionHostContext = actionHostContext
        self.onCancel = onCancel
        self.onDelete = onDelete
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    Text(localization.string("editor.title", defaultValue: "手势映射"))
                        .font(PluginSettingsTheme.Typography.pageTitle)

                    editorSection(
                        title: localization.string("editor.gesture.title", defaultValue: "手势"),
                        icon: "hand.tap"
                    ) {
                        TrackpadGesturePickerControl(
                            gestures: store.availableGestures(excludingID: draft.id),
                            localization: localization,
                            actionKind: draft.actionKind,
                            selection: $draft.gesture
                        )

                        Label(
                            draft.gesture.demonstration(localization: localization),
                            systemImage: draft.gesture.systemImage
                        )
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)

                        ForEach(
                            draft.gesture.conflictGuidance(
                                localization: localization,
                                actionKind: draft.actionKind
                            ),
                            id: \.self
                        ) { guidance in
                            Label(guidance, systemImage: "exclamationmark.triangle")
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    editorSection(
                        title: localization.string("editor.action.title", defaultValue: "操作"),
                        icon: "arrow.forward.circle"
                    ) {
                        TrackpadUnifiedActionPickerControl(
                            localization: localization,
                            context: actionHostContext,
                            actionKind: $draft.actionKind,
                            actionReference: $draft.actionReference,
                            shortcut: $draft.shortcut,
                            keyTap: $draft.keyTap
                        )

                        if draft.actionKind == .keyboardShortcut {
                            PluginSettingsShortcutControlLayout {
                                Label(
                                    localization.string(
                                        "editor.shortcut.record",
                                        defaultValue: "录制快捷键"
                                    ),
                                    systemImage: "keyboard"
                                )
                                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                                .lineLimit(1)

                                PluginShortcutRecorder(
                                    title: localization.string(
                                        "editor.shortcut.record",
                                        defaultValue: "录制快捷键"
                                    ),
                                    displayText: shortcutDisplayText,
                                    minWidth: PluginSettingsTheme.Size.shortcutRecorderWidth,
                                    onRecord: { binding in
                                        draft.shortcut = binding
                                        return .accepted
                                    }
                                )
                                .frame(width: PluginSettingsTheme.Size.shortcutRecorderWidth)
                            }

                            if let shortcutReuseGuidance {
                                Label(shortcutReuseGuidance, systemImage: "info.circle")
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if draft.actionKind == .keyTap {
                            PluginSettingsShortcutControlLayout {
                                Label(
                                    localization.string("action.singleKey", defaultValue: "单键"),
                                    systemImage: "keyboard.badge.ellipsis"
                                )
                                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                                .lineLimit(1)

                                PluginKeyTapPicker(
                                    title: localization.string("action.singleKey", defaultValue: "单键"),
                                    selection: $draft.keyTap,
                                    minWidth: PluginSettingsTheme.Size.shortcutRecorderWidth,
                                )
                                .frame(width: PluginSettingsTheme.Size.shortcutRecorderWidth)
                            }
                        }
                    }

                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.red)
                    }
                }
                .padding(PluginSettingsTheme.Spacing.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                if let onDelete {
                    Button(
                        localization.string(
                            "settings.mapping.deleteMapping",
                            defaultValue: "删除映射"
                        ),
                        role: .destructive,
                        action: onDelete
                    )
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button(
                    localization.string("editor.cancel", defaultValue: "取消"),
                    action: onCancel
                )
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                Button(localization.string("editor.save", defaultValue: "保存")) {
                    if let mapping = draft.mapping {
                        onSave(mapping)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(validationMessage != nil || draft.mapping == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.pagePadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 430, idealHeight: 520)
    }

    @ViewBuilder
    private func editorSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(title, systemImage: icon)
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pluginSettingsListRowPadding(interactive: true)
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var validationMessage: String? {
        if store.conflictingMapping(for: draft.gesture, excludingID: draft.id) != nil {
            return localization.string(
                "editor.error.duplicateGesture",
                defaultValue: "该手势已配置，请选择其他手势。"
            )
        }
        if draft.actionKind == .none {
            return localization.string(
                "editor.error.actionRequired",
                defaultValue: "请选择一个操作。"
            )
        }
        if draft.actionKind == .keyboardShortcut, draft.shortcut == nil {
            return localization.string(
                "editor.error.shortcutRequired",
                defaultValue: "请录制一个键盘快捷键。"
            )
        }
        if draft.actionKind == .keyTap, draft.keyTap == nil {
            return localization.string(
                "editor.error.singleKeyRequired",
                defaultValue: "请选择一个按键。"
            )
        }
        if draft.actionKind == .action, draft.actionReference == nil {
            return localization.string(
                "editor.error.actionRequired",
                defaultValue: "请选择一个操作。"
            )
        }
        return nil
    }

    private var shortcutDisplayText: String {
        guard let shortcut = draft.shortcut else {
            return localization.string("editor.shortcut.unset", defaultValue: "未设置")
        }
        return ShortcutFormatter.displayString(for: shortcut)
    }

    private var shortcutReuseGuidance: String? {
        guard draft.actionKind == .keyboardShortcut,
              let shortcut = draft.shortcut
        else {
            return nil
        }
        let gestureTitles = store.mappings(
            using: shortcut,
            excludingID: draft.id
        ).map { $0.gesture.title(localization: localization) }
        guard !gestureTitles.isEmpty else {
            return nil
        }
        return localization.format(
            "editor.shortcut.reusedFormat",
            defaultValue: "此快捷键也用于：%@。允许重复使用。",
            gestureTitles.joined(separator: ", ")
        )
    }
}

private struct TrackpadActionPickerGroup: Identifiable {
    let title: String
    let items: [ActionSurfaceCatalogItem]

    var id: String { title }
}

private enum TrackpadInputActionChoice: String, CaseIterable, Identifiable {
    case keyboardShortcut
    case singleKey
    case middleClick

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .keyboardShortcut: "keyboard"
        case .singleKey: "keyboard.badge.ellipsis"
        case .middleClick: "computermouse"
        }
    }

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .keyboardShortcut:
            localization.string("action.shortcut", defaultValue: "键盘快捷键")
        case .singleKey:
            localization.string("action.singleKey", defaultValue: "单键")
        case .middleClick:
            localization.string("action.middleClick", defaultValue: "鼠标中键")
        }
    }
}

private struct TrackpadUnifiedActionPickerControl: View {
    let localization: PluginLocalization
    let context: TrackpadActionHostContext?
    @Binding var actionKind: TrackpadGestureEditorActionKind
    @Binding var actionReference: ActionReference?
    @Binding var shortcut: ShortcutBinding?
    @Binding var keyTap: KeyboardKeyTap?

    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: PluginSystemImage.resolvedName(selectedSystemImage))
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(actionKind == .none ? Color.secondary : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(actionKind == .none ? 0.06 : 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedTitle)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let selectedSubtitle {
                        Text(selectedSubtitle)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minWidth: 340, idealWidth: 390, maxWidth: 440, minHeight: 52)
            .contentShape(Rectangle())
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            pickerContent
        }
        .accessibilityIdentifier("mactools.trackpad.action-picker")
        .accessibilityLabel(localization.string("editor.action.title", defaultValue: "操作"))
        .accessibilityValue(selectedTitle)
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                localization.string("editor.action.search", defaultValue: "搜索操作"),
                text: $query
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("mactools.trackpad.action-picker.search")

            Divider()

            if !hasResults {
                ContentUnavailableView(
                    localization.string("editor.action.empty", defaultValue: "没有匹配的操作"),
                    systemImage: "magnifyingglass"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if !filteredInputActions.isEmpty {
                            pickerGroup(
                                title: localization.string(
                                    "editor.action.inputGroup",
                                    defaultValue: "输入"
                                )
                            ) {
                                ForEach(filteredInputActions) { choice in
                                    inputActionRow(choice)
                                }
                            }
                        }

                        ForEach(groups) { group in
                            pickerGroup(title: group.title) {
                                ForEach(group.items) { item in
                                    macToolsActionRow(item)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .frame(width: 460, height: 500)
    }

    private var selectedItem: ActionSurfaceCatalogItem? {
        guard actionKind == .action, let actionReference else { return nil }
        return context?.item(for: actionReference)
    }

    private var selectedTitle: String {
        switch actionKind {
        case .none:
            localization.string("editor.action.choose", defaultValue: "选择操作")
        case .action:
            selectedItem?.title ?? localization.string(
                "editor.action.unavailable",
                defaultValue: "不可用的 MacTools 操作"
            )
        case .keyboardShortcut:
            localization.string("action.shortcut", defaultValue: "键盘快捷键")
        case .keyTap:
            localization.string("action.singleKey", defaultValue: "单键")
        case .middleClick:
            localization.string("action.middleClick", defaultValue: "鼠标中键")
        }
    }

    private var selectedSubtitle: String? {
        switch actionKind {
        case .none, .middleClick:
            nil
        case .action:
            selectedItem?.ownerTitle
        case .keyboardShortcut:
            shortcut.map(ShortcutFormatter.displayString(for:))
                ?? localization.string("editor.shortcut.unset", defaultValue: "未设置")
        case .keyTap:
            keyTap.map(KeyboardKeyTapFormatter.displayString(for:))
                ?? localization.string("editor.singleKey.unset", defaultValue: "未设置")
        }
    }

    private var selectedSystemImage: String {
        switch actionKind {
        case .none: "bolt.circle"
        case .action: selectedItem?.systemImage ?? "questionmark.square.dashed"
        case .keyboardShortcut: TrackpadInputActionChoice.keyboardShortcut.systemImage
        case .keyTap: TrackpadInputActionChoice.singleKey.systemImage
        case .middleClick: TrackpadInputActionChoice.middleClick.systemImage
        }
    }

    private var hasResults: Bool {
        !filteredInputActions.isEmpty || !groups.isEmpty
    }

    private var filteredInputActions: [TrackpadInputActionChoice] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return TrackpadInputActionChoice.allCases.filter { choice in
            normalizedQuery.isEmpty
                || choice.title(localization: localization)
                    .localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var groups: [TrackpadActionPickerGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = (context?.catalog ?? []).filter { item in
            guard item.availability.isAvailable else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return [item.title, item.subtitle, item.ownerTitle]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
        }
        let grouped = Dictionary(grouping: items, by: \.ownerTitle)
        return grouped.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map { owner in
            TrackpadActionPickerGroup(title: owner, items: grouped[owner] ?? [])
        }
    }

    @ViewBuilder
    private func pickerGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func inputActionRow(_ choice: TrackpadInputActionChoice) -> some View {
        let subtitle: String? = switch choice {
        case .keyboardShortcut: shortcut.map(ShortcutFormatter.displayString(for:))
        case .singleKey: keyTap.map(KeyboardKeyTapFormatter.displayString(for:))
        case .middleClick: nil
        }
        return Button {
            actionReference = nil
            switch choice {
            case .keyboardShortcut:
                actionKind = .keyboardShortcut
                keyTap = nil
            case .singleKey:
                actionKind = .keyTap
                shortcut = nil
            case .middleClick:
                actionKind = .middleClick
                shortcut = nil
                keyTap = nil
            }
            isPresented = false
        } label: {
            pickerRow(
                title: choice.title(localization: localization),
                subtitle: subtitle,
                systemImage: choice.systemImage,
                isSafe: true,
                isSelected: isSelected(choice)
            )
        }
        .buttonStyle(.plain)
    }

    private func macToolsActionRow(_ item: ActionSurfaceCatalogItem) -> some View {
        Button {
            actionKind = .action
            actionReference = item.reference
            shortcut = nil
            keyTap = nil
            isPresented = false
        } label: {
            pickerRow(
                title: item.title,
                subtitle: item.subtitle,
                systemImage: item.systemImage,
                isSafe: item.isSafe,
                isSelected: actionKind == .action && actionReference == item.reference
            )
        }
        .buttonStyle(.plain)
        .disabled(!item.availability.isAvailable)
    }

    private func pickerRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        isSafe: Bool,
        isSelected: Bool
    ) -> some View {
        let accessibility = TrackpadActionPickerAccessibility(
            isSafe: isSafe,
            confirmationRequiredText: localization.string(
                "editor.action.confirmationRequired",
                defaultValue: "执行前需要确认。"
            )
        )
        return HStack(spacing: 9) {
            Image(systemName: PluginSystemImage.resolvedName(systemImage))
                .frame(width: 20)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isSafe {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .modifier(TrackpadConfirmationAccessibilityModifier(
            value: accessibility.confirmationValue
        ))
    }

    private func isSelected(_ choice: TrackpadInputActionChoice) -> Bool {
        switch choice {
        case .keyboardShortcut: actionKind == .keyboardShortcut
        case .singleKey: actionKind == .keyTap
        case .middleClick: actionKind == .middleClick
        }
    }
}

@MainActor
private enum TrackpadSettingsCursor {
    static func update(isHovering: Bool) {
        (isHovering ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    static func reset() {
        NSCursor.arrow.set()
    }
}

extension TrackpadGesture {
    var systemImage: String {
        category.systemImage
    }

    fileprivate var category: TrackpadGestureCategory {
        if tipTapConfiguration != nil {
            return .tipTap
        }
        if fingerTapCount != nil {
            return .tap
        }
        if doubleFingerTapCount != nil {
            return .doubleTap
        }
        if physicalClickFingerCount != nil {
            return .click
        }
        return .longTouch
    }

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .tipTapLeftOneFixed:
            localization.string("gesture.tipTapLeftOneFixed", defaultValue: "TipTap 左侧（1 指固定）")
        case .tipTapRightOneFixed:
            localization.string("gesture.tipTapRightOneFixed", defaultValue: "TipTap 右侧（1 指固定）")
        case .tipTapLeftTwoFixed:
            localization.string("gesture.tipTapLeftTwoFixed", defaultValue: "TipTap 左侧（2 指固定）")
        case .tipTapMiddleTwoFixed:
            localization.string("gesture.tipTapMiddleTwoFixed", defaultValue: "TipTap 中间（2 指固定）")
        case .tipTapRightTwoFixed:
            localization.string("gesture.tipTapRightTwoFixed", defaultValue: "TipTap 右侧（2 指固定）")
        case .threeFingerTap:
            localization.string("gesture.threeFingerTap", defaultValue: "三指轻点")
        case .fourFingerTap:
            localization.string("gesture.fourFingerTap", defaultValue: "四指轻点")
        case .fiveFingerTap:
            localization.string("gesture.fiveFingerTap", defaultValue: "五指轻点")
        case .threeFingerLongTouch:
            localization.string("gesture.threeFingerLongTouch", defaultValue: "三指长触")
        case .fourFingerLongTouch:
            localization.string("gesture.fourFingerLongTouch", defaultValue: "四指长触")
        case .fiveFingerLongTouch:
            localization.string("gesture.fiveFingerLongTouch", defaultValue: "五指长触")
        case .threeFingerDoubleTap:
            localization.string("gesture.threeFingerDoubleTap", defaultValue: "三指双击")
        case .fourFingerDoubleTap:
            localization.string("gesture.fourFingerDoubleTap", defaultValue: "四指双击")
        case .fiveFingerDoubleTap:
            localization.string("gesture.fiveFingerDoubleTap", defaultValue: "五指双击")
        case .twoFingerClick:
            localization.string("gesture.twoFingerClick", defaultValue: "双指按下点击")
        case .threeFingerClick:
            localization.string("gesture.threeFingerClick", defaultValue: "三指按下点击")
        }
    }

    func demonstration(localization: PluginLocalization) -> String {
        if let configuration = tipTapConfiguration {
            return localization.format(
                "gesture.demo.tipTapFormat",
                defaultValue: "保持 %d 指不动，再用一指反复轻点指定区域。",
                configuration.fixedFingerCount
            )
        }
        if let count = fingerTapCount {
            return localization.format(
                "gesture.demo.tapFormat",
                defaultValue: "%d 指同时轻触并抬起。",
                count
            )
        }
        if let count = doubleFingerTapCount {
            return localization.format(
                "gesture.demo.doubleTapFormat",
                defaultValue: "%d 指连续轻触并抬起两次。",
                count
            )
        }
        if let count = physicalClickFingerCount {
            return localization.format(
                "gesture.demo.clickFormat",
                defaultValue: "保持 %d 指接触并按下触控板，直到产生一次物理点击。",
                count
            )
        }
        return localization.format(
            "gesture.demo.longTouchFormat",
            defaultValue: "%d 指保持接触约半秒。",
            longTouchFingerCount ?? 3
        )
    }

    fileprivate func conflictGuidance(
        localization: PluginLocalization,
        actionKind: TrackpadGestureEditorActionKind
    ) -> [String] {
        var guidance: [String] = []
        if tipTapConfiguration != nil || physicalClickFingerCount != nil
            || actionKind == .middleClick {
            guidance.append(localization.string(
                "gesture.conflict.secondaryClick",
                defaultValue: "macOS 不提供原生点击来源。MacTools 仅在一个手势候选活动时关联点击；同时点击外接鼠标时可能发生冲突。"
            ))
        }

        switch self {
        case .threeFingerTap, .threeFingerLongTouch, .threeFingerDoubleTap,
             .threeFingerClick:
            guidance.append(localization.string(
                "gesture.conflict.threeFinger",
                defaultValue: "可能与“查询与数据检测器”或三指拖移冲突。"
            ))
        case .fourFingerTap, .fourFingerLongTouch, .fourFingerDoubleTap:
            guidance.append(localization.string(
                "gesture.conflict.fourFinger",
                defaultValue: "可能与调度中心、App Exposé 或全屏切换手势冲突。"
            ))
        case .tipTapLeftOneFixed, .tipTapRightOneFixed,
             .tipTapLeftTwoFixed, .tipTapMiddleTwoFixed, .tipTapRightTwoFixed,
             .fiveFingerTap, .fiveFingerLongTouch, .fiveFingerDoubleTap:
            break
        case .twoFingerClick:
            guidance.append(localization.string(
                "gesture.conflict.twoFingerClick",
                defaultValue: "通常会替代 macOS 的双指辅助点按（右键）。"
            ))
        }
        return guidance
    }
}

extension TrackpadGestureAction {
    func title(localization: PluginLocalization) -> String {
        switch self {
        case .action:
            localization.string("action.macToolsAction", defaultValue: "MacTools 操作")
        case let .keyboardShortcut(binding):
            localization.format(
                "action.shortcutFormat",
                defaultValue: "快捷键 %@",
                ShortcutFormatter.displayString(for: binding)
            )
        case let .keyTap(keyTap):
            localization.format(
                "action.singleKeyFormat",
                defaultValue: "单键 %@",
                KeyboardKeyTapFormatter.displayString(for: keyTap)
            )
        case .middleClick:
            localization.string("action.middleClick", defaultValue: "鼠标中键")
        }
    }
}
