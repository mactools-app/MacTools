import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

struct AutoInputSettingsView: View {
    private enum Layout {
        static let trailingControlMinWidth: CGFloat = 220
        static let trailingControlIdealWidth: CGFloat = 260
        static let trailingControlMaxWidth: CGFloat = 300
    }

    enum SectionKind {
        case behavior
        case hud
        case rules
    }

    private enum NumericField: Hashable {
        case reminderInterval
        case appSwitchCount
    }

    @ObservedObject var store: AutoInputStore
    @ObservedObject var controller: AutoInputController
    let localization: PluginLocalization
    let onChange: () -> Void
    let onHUDChange: (Bool) -> Void
    let section: SectionKind
    @State private var reminderIntervalText: String
    @State private var appSwitchCountText: String
    @FocusState private var focusedNumericField: NumericField?

    init(
        store: AutoInputStore,
        controller: AutoInputController,
        localization: PluginLocalization,
        onChange: @escaping () -> Void,
        onHUDChange: @escaping (Bool) -> Void,
        section: SectionKind
    ) {
        self.store = store
        self.controller = controller
        self.localization = localization
        self.onChange = onChange
        self.onHUDChange = onHUDChange
        self.section = section
        _reminderIntervalText = State(initialValue: "\(store.inputHUDReminderIntervalSeconds)")
        _appSwitchCountText = State(initialValue: "\(store.inputHUDAppSwitchReminderCount)")
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch section {
            case .behavior:
                behaviorSection
            case .hud:
                hudSection
            case .rules:
                rulesSection
            }
        }
        .pluginSettingsSearchAnchor(
            pluginID: "auto-input",
            entryID: searchEntryID
        )
        .onChange(of: store.inputHUDReminderIntervalSeconds) { _, value in
            reminderIntervalText = "\(value)"
        }
        .onChange(of: store.inputHUDAppSwitchReminderCount) { _, value in
            appSwitchCountText = "\(value)"
        }
    }

    private var searchEntryID: String {
        switch section {
        case .behavior:
            AutoInputSettingsSearchEntryID.behavior
        case .hud:
            AutoInputSettingsSearchEntryID.hud
        case .rules:
            AutoInputSettingsSearchEntryID.rules
        }
    }

    private var behaviorSection: some View {
        settingToggle(
            icon: "arrow.counterclockwise",
            title: localization.string("settings.memory.title", defaultValue: "自动记忆"),
            description: localization.string(
                "settings.memory.description",
                defaultValue: "切回应用时恢复上次使用的输入法。"
            ),
            isOn: Binding(
                get: { store.remembersLastInputSource },
                set: { value in
                    store.setRemembersLastInputSource(value)
                    onChange()
                }
            )
        )
    }

    private var hudSection: some View {
        VStack(spacing: 0) {
            settingToggle(
                icon: "text.cursor",
                title: localization.string("settings.hud.title", defaultValue: "输入法提示"),
                description: localization.string(
                    "settings.hud.description",
                    defaultValue: "聚焦文本输入区域或终端时，在附近短暂显示当前输入法。需要辅助功能权限。"
                ),
                isOn: Binding(
                    get: { store.isInputHUDEnabled },
                    set: { value in
                        guard store.setInputHUDEnabled(value) == .committed else {
                            onChange()
                            return
                        }
                        onHUDChange(value)
                    }
                )
            )
            if store.isInputHUDEnabled {
                PluginSettingsListDivider()
                hudSizePicker
                PluginSettingsListDivider()
                reducedHUDFrequencyToggle
                if store.reducesFrequentHUDPresentations {
                    PluginSettingsListDivider()
                    hudReminderIntervalRow
                    PluginSettingsListDivider()
                    hudAppSwitchReminderRow
                }
                PluginSettingsListDivider()
                interactiveHUDToggle
                PluginSettingsListDivider()
                hudPositionPicker
            }
        }
    }

    private var reducedHUDFrequencyToggle: some View {
        settingToggle(
            icon: "timer",
            title: localization.string(
                "settings.hud.reducedFrequency.title",
                defaultValue: "减少频繁提示"
            ),
            description: localization.string(
                "settings.hud.reducedFrequency.description",
                defaultValue: "首次聚焦和输入法变化时立即提示。输入法不变时，达到下方任一条件后再次提示。"
            ),
            isOn: Binding(
                get: { store.reducesFrequentHUDPresentations },
                set: { value in
                    store.setReducesFrequentHUDPresentations(value)
                    onChange()
                }
            )
        )
    }

    private var hudReminderIntervalRow: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            settingLabel(
                icon: "clock.arrow.circlepath",
                title: hudReminderIntervalTitle,
                description: hudReminderIntervalDescription
            )

            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                PluginSettingsSlider(
                    value: Binding(
                        get: { Double(store.inputHUDReminderIntervalSeconds) },
                        set: { value in
                            store.setInputHUDReminderIntervalSeconds(Int(value.rounded()))
                            onChange()
                        }
                    ),
                    in: Double(AutoInputHUDReminderLimits.minimumIntervalSeconds)...Double(AutoInputHUDReminderLimits.maximumIntervalSeconds),
                    step: 5
                )
                .frame(minWidth: 120, idealWidth: 150, maxWidth: 180)
                .accessibilityLabel(Text(hudReminderIntervalTitle))
                .accessibilityValue(Text(
                    "\(store.inputHUDReminderIntervalSeconds) \(hudReminderIntervalUnit)"
                ))
                .accessibilityHint(Text(hudReminderIntervalDescription))
                .accessibilityIdentifier("auto-input.hud-reminder-interval-slider")

                numericTextField(
                    text: $reminderIntervalText,
                    validRange: AutoInputHUDReminderLimits.minimumIntervalSeconds...AutoInputHUDReminderLimits.maximumIntervalSeconds,
                    field: .reminderInterval,
                    accessibilityLabel: hudReminderIntervalTitle,
                    accessibilityHint: hudReminderIntervalDescription,
                    accessibilityIdentifier: "auto-input.hud-reminder-interval-field",
                    update: { value in
                        store.setInputHUDReminderIntervalSeconds(value)
                    },
                    commit: commitReminderIntervalText
                )

                Text(localization.string(
                    "settings.hud.reminderInterval.unit",
                    defaultValue: "秒"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .leading)
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var hudAppSwitchReminderRow: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            settingLabel(
                icon: "arrow.triangle.swap",
                title: hudAppSwitchReminderTitle,
                description: hudAppSwitchReminderDescription
            )

            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                numericTextField(
                    text: $appSwitchCountText,
                    validRange: AutoInputHUDReminderLimits.minimumAppSwitchCount...AutoInputHUDReminderLimits.maximumAppSwitchCount,
                    field: .appSwitchCount,
                    accessibilityLabel: hudAppSwitchReminderTitle,
                    accessibilityHint: hudAppSwitchReminderDescription,
                    accessibilityIdentifier: "auto-input.hud-app-switch-field",
                    update: { value in
                        store.setInputHUDAppSwitchReminderCount(value)
                    },
                    commit: commitAppSwitchCountText
                )

                Text(localization.string(
                    "settings.hud.appSwitchReminder.unit",
                    defaultValue: "次"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)

                Stepper(
                    "",
                    value: Binding(
                        get: { store.inputHUDAppSwitchReminderCount },
                        set: { value in
                            store.setInputHUDAppSwitchReminderCount(value)
                            onChange()
                        }
                    ),
                    in: AutoInputHUDReminderLimits.minimumAppSwitchCount...AutoInputHUDReminderLimits.maximumAppSwitchCount
                )
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(Text(hudAppSwitchReminderTitle))
                .accessibilityValue(Text(
                    "\(store.inputHUDAppSwitchReminderCount) \(hudAppSwitchReminderUnit)"
                ))
                .accessibilityHint(Text(hudAppSwitchReminderDescription))
                .accessibilityIdentifier("auto-input.hud-app-switch-stepper")
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func settingLabel(
        icon: String,
        title: String,
        description: String
    ) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: icon)
                .pluginSettingsRowIconStyle()
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numericTextField(
        text: Binding<String>,
        validRange: ClosedRange<Int>,
        field: NumericField,
        accessibilityLabel: String,
        accessibilityHint: String,
        accessibilityIdentifier: String,
        update: @escaping (Int) -> Void,
        commit: @escaping () -> Void
    ) -> some View {
        TextField(
            "",
            text: Binding(
                get: { text.wrappedValue },
                set: { value in
                    let digits = value.filter(\.isNumber)
                    text.wrappedValue = digits
                    guard let number = Int(digits), validRange.contains(number) else { return }
                    update(number)
                    onChange()
                }
            )
        )
        .textFieldStyle(.roundedBorder)
        .font(PluginSettingsTheme.Typography.monospacedValue)
        .multilineTextAlignment(.trailing)
        .frame(width: 58)
        .focused($focusedNumericField, equals: field)
        .onChange(of: focusedNumericField) { previousField, currentField in
            if previousField == field && currentField != field {
                commit()
            }
        }
        .onSubmit(commit)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(accessibilityHint))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var hudReminderIntervalTitle: String {
        localization.string(
            "settings.hud.reminderInterval.title",
            defaultValue: "提示间隔"
        )
    }

    private var hudReminderIntervalDescription: String {
        localization.string(
            "settings.hud.reminderInterval.description",
            defaultValue: "经过这段时间后，在下一次有效聚焦时再次提示。"
        )
    }

    private var hudReminderIntervalUnit: String {
        localization.string(
            "settings.hud.reminderInterval.unit",
            defaultValue: "秒"
        )
    }

    private var hudAppSwitchReminderTitle: String {
        localization.string(
            "settings.hud.appSwitchReminder.title",
            defaultValue: "应用切换提示"
        )
    }

    private var hudAppSwitchReminderDescription: String {
        localization.string(
            "settings.hud.appSwitchReminder.description",
            defaultValue: "达到此切换次数后，即使尚未到提示间隔，也会在输入区域聚焦时提示。"
        )
    }

    private var hudAppSwitchReminderUnit: String {
        localization.string(
            "settings.hud.appSwitchReminder.unit",
            defaultValue: "次"
        )
    }

    private func commitReminderIntervalText() {
        let value = clamped(
            Int(reminderIntervalText) ?? store.inputHUDReminderIntervalSeconds,
            to: AutoInputHUDReminderLimits.minimumIntervalSeconds...AutoInputHUDReminderLimits.maximumIntervalSeconds
        )
        store.setInputHUDReminderIntervalSeconds(value)
        reminderIntervalText = "\(store.inputHUDReminderIntervalSeconds)"
        onChange()
    }

    private func commitAppSwitchCountText() {
        let value = clamped(
            Int(appSwitchCountText) ?? store.inputHUDAppSwitchReminderCount,
            to: AutoInputHUDReminderLimits.minimumAppSwitchCount...AutoInputHUDReminderLimits.maximumAppSwitchCount
        )
        store.setInputHUDAppSwitchReminderCount(value)
        appSwitchCountText = "\(store.inputHUDAppSwitchReminderCount)"
        onChange()
    }

    private func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private var interactiveHUDToggle: some View {
        settingToggle(
            icon: "hand.tap",
            title: localization.string(
                "settings.hud.interactive.title",
                defaultValue: "交互式提示"
            ),
            description: localization.string(
                "settings.hud.interactive.description",
                defaultValue: "悬停时保持显示；可连续点击循环切换输入法。"
            ),
            isOn: Binding(
                get: { store.isInteractiveHUDEnabled },
                set: { value in
                    store.setInteractiveHUDEnabled(value)
                    onChange()
                }
            )
        )
    }

    private var hudSizePicker: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: "textformat.size")
                    .pluginSettingsRowIconStyle()
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(localization.string("settings.hud.size.title", defaultValue: "提示大小"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(localization.string(
                        "settings.hud.size.description",
                        defaultValue: "调整提示的文字和面板大小。"
                    ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("", selection: Binding(
                    get: { store.inputHUDSize },
                    set: { value in
                        store.setInputHUDSize(value)
                        onChange()
                    }
                )) {
                    ForEach(AutoInputHUDSize.allCases) { size in
                        Text(localizedHUDSize(size)).tag(size)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(
                    minWidth: Layout.trailingControlMinWidth,
                    idealWidth: Layout.trailingControlIdealWidth,
                    maxWidth: Layout.trailingControlMaxWidth
                )
                .accessibilityLabel(Text(localization.string(
                    "settings.hud.size.title",
                    defaultValue: "提示大小"
                )))
                .accessibilityHint(Text(localization.string(
                    "settings.hud.size.description",
                    defaultValue: "调整提示的文字和面板大小。"
                )))
                .accessibilityIdentifier("auto-input.hud-size")
            }

            GeometryReader { proxy in
                ZStack {
                    InputSourceHUDPreview(
                        title: hudPreviewSourceName,
                        size: store.inputHUDSize,
                        maximumWidth: max(proxy.size.width - 24, 1)
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            }
            .frame(maxWidth: .infinity, minHeight: 96, idealHeight: 96, maxHeight: 96)
            .pluginSettingsCardBackground(.recessed)
            .accessibilityHidden(true)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var hudPreviewSourceName: String {
        controller.sources.first(where: { $0.id == controller.currentSourceID })?.name
            ?? controller.sources.first?.name
            ?? "ABC"
    }

    private var hudPositionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingPickerRow(
                icon: "rectangle.and.hand.point.up.left",
                title: localization.string("settings.hud.position.title", defaultValue: "提示位置"),
                description: localization.string(
                    "settings.hud.position.description",
                    defaultValue: "选择提示显示在当前输入区域、指针附近或所在显示器中央。"
                )
            ) {
                Picker("", selection: Binding(
                    get: { store.inputHUDPosition },
                    set: { value in
                        store.setInputHUDPosition(value)
                        onChange()
                    }
                )) {
                    ForEach(AutoInputHUDPosition.allCases) { position in
                        hudPositionOption(position)
                    }
                }
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .help(hudPositionAccessibilityHint)
                .accessibilityLabel(Text(localization.string(
                    "settings.hud.position.title",
                    defaultValue: "提示位置"
                )))
                .accessibilityHint(Text(hudPositionAccessibilityHint))
                .accessibilityIdentifier("auto-input.hud-position")
            }

            if store.inputHUDPosition == .atPointer {
                Label {
                    Text(store.isInteractiveHUDEnabled
                        ? atPointerSelectedHelp
                        : atPointerRequiresInteractiveHelp)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                .padding(.bottom, PluginSettingsTheme.Spacing.rowVertical)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func hudPositionOption(_ position: AutoInputHUDPosition) -> some View {
        if position == .atPointer {
            Text(localizedHUDPosition(position))
                .tag(position)
                .disabled(!position.isAvailable(isInteractive: store.isInteractiveHUDEnabled))
                .help(atPointerPlacementHelp)
                .accessibilityHint(Text(
                    store.isInteractiveHUDEnabled
                        ? atPointerPlacementHelp
                        : atPointerRequiresInteractiveHelp
                ))
        } else {
            Text(localizedHUDPosition(position)).tag(position)
        }
    }

    private var hudPositionAccessibilityHint: String {
        if store.inputHUDPosition == .atPointer {
            return store.isInteractiveHUDEnabled
                ? atPointerSelectedHelp
                : atPointerRequiresInteractiveHelp
        }
        let positionDescription = localization.string(
            "settings.hud.position.description",
            defaultValue: "选择提示显示在当前输入区域、指针附近或所在显示器中央。"
        )
        guard !store.isInteractiveHUDEnabled else { return positionDescription }
        return "\(positionDescription) \(atPointerRequiresInteractiveHelp)"
    }

    private var atPointerPlacementHelp: String {
        localization.string(
            "settings.hud.position.at-pointer.help",
            defaultValue: "将提示放在指针左上方，指针停在右下角，避免遮挡文字。"
        )
    }

    private var atPointerSelectedHelp: String {
        localization.string(
            "settings.hud.position.at-pointer.selected-help",
            defaultValue: "提示显示时，下次点击会切换输入法，而不会点击下方内容。"
        )
    }

    private var atPointerRequiresInteractiveHelp: String {
        localization.string(
            "settings.hud.position.at-pointer.requires-interactive",
            defaultValue: "开启“交互式提示”后才能使用“指针处”。"
        )
    }

    @ViewBuilder
    private var rulesSection: some View {
        if store.rules.isEmpty {
            emptyRulesView
        } else {
            VStack(spacing: 0) {
                ForEach(store.rules) { rule in
                    ruleRow(rule)
                    if rule.id != store.rules.last?.id {
                        PluginSettingsListDivider()
                    }
                }
            }
        }
    }

    private var emptyRulesView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon))
                    .foregroundStyle(.secondary)
                Text(localization.string(
                    "settings.rules.empty",
                    defaultValue: "添加应用，为它指定固定输入法"
                ))
                .font(PluginSettingsTheme.Typography.pageDescription)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
            Spacer()
        }
    }

    private func ruleRow(_ rule: AutoInputRule) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(nsImage: applicationIcon(for: rule))
                .resizable()
                .frame(width: PluginSettingsTheme.Size.rowIcon, height: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(rule.displayName)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    .lineLimit(1)
                Text(ruleSubtitle(rule))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundColor(isSourceAvailable(rule.inputSourceID) ? .secondary : .red)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ruleInputSourcePicker(rule)
            ruleKeyboardModePicker(rule)

            Button {
                store.removeRule(bundleIdentifier: rule.bundleIdentifier)
                onChange()
            } label: {
                Image(systemName: "trash")
                    .pluginSettingsRowIconStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(localization.string("settings.rules.delete", defaultValue: "删除此规则"))
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func ruleInputSourcePicker(_ rule: AutoInputRule) -> some View {
        Picker("", selection: Binding(
            get: { rule.inputSourceID },
            set: { sourceID in
                store.updateRule(bundleIdentifier: rule.bundleIdentifier, inputSourceID: sourceID)
                onChange()
            }
        )) {
            if !isSourceAvailable(rule.inputSourceID) {
                Text(localization.string("settings.source.unavailable", defaultValue: "输入法不可用"))
                    .tag(rule.inputSourceID)
            }
            ForEach(controller.sources) { source in
                Text(source.name).tag(source.id)
            }
        }
        .labelsHidden()
        .frame(minWidth: 140, idealWidth: 170, maxWidth: 210)
        .help(inputSourceTitle)
        .accessibilityLabel(Text(inputSourceTitle))
        .accessibilityIdentifier("auto-input.rule-input-source")
    }

    private func ruleKeyboardModePicker(_ rule: AutoInputRule) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Image(systemName: "keyboard")
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .help(keyboardModeDescription)
                .accessibilityHidden(true)

            Picker("", selection: Binding(
                get: { rule.keyboardMode },
                set: { mode in
                    store.updateRuleKeyboardMode(
                        bundleIdentifier: rule.bundleIdentifier,
                        keyboardMode: mode
                    )
                    onChange()
                }
            )) {
                ForEach(AutoInputKeyboardMode.allCases) { mode in
                    Text(localizedKeyboardMode(mode)).tag(mode)
                }
            }
            .labelsHidden()
            .frame(minWidth: 120, idealWidth: 150, maxWidth: 190)
            .help(keyboardModeDescription)
            .accessibilityLabel(Text(keyboardModeTitle))
            .accessibilityHint(Text(keyboardModeDescription))
            .accessibilityIdentifier("auto-input.rule-keyboard-mode")
        }
    }

    private var inputSourceTitle: String {
        localization.string("settings.rules.inputSource.title", defaultValue: "输入法")
    }

    private var keyboardModeTitle: String {
        localization.string("settings.rules.keyboardMode.title", defaultValue: "键盘模式")
    }

    private var keyboardModeDescription: String {
        localization.string(
            "settings.rules.keyboardMode.description",
            defaultValue: "该应用位于前台时，顶部按键的用途。"
        )
    }

    private func localizedKeyboardMode(_ mode: AutoInputKeyboardMode) -> String {
        switch mode {
        case .system:
            localization.string("settings.rules.keyboardMode.system", defaultValue: "跟随系统")
        case .standardFunctionKeys:
            localization.string(
                "settings.rules.keyboardMode.functionKeys",
                defaultValue: "F1–F12 功能键"
            )
        case .mediaShortcuts:
            localization.string("settings.rules.keyboardMode.media", defaultValue: "MacBook 快捷键")
        }
    }

    private func settingToggle(
        icon: String,
        title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: icon)
                .pluginSettingsRowIconStyle()
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(
                    minWidth: Layout.trailingControlMinWidth,
                    idealWidth: Layout.trailingControlIdealWidth,
                    maxWidth: Layout.trailingControlMaxWidth,
                    alignment: .trailing
                )
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(description))
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func settingPickerRow<Control: View>(
        icon: String,
        title: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: icon)
                .pluginSettingsRowIconStyle()
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .frame(
                    minWidth: Layout.trailingControlMinWidth,
                    idealWidth: Layout.trailingControlIdealWidth,
                    maxWidth: Layout.trailingControlMaxWidth,
                    alignment: .trailing
                )
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func localizedHUDSize(_ size: AutoInputHUDSize) -> String {
        switch size {
        case .compact:
            localization.string("settings.hud.size.compact", defaultValue: "紧凑")
        case .standard:
            localization.string("settings.hud.size.standard", defaultValue: "标准")
        case .large:
            localization.string("settings.hud.size.large", defaultValue: "大")
        }
    }

    private func localizedHUDPosition(_ position: AutoInputHUDPosition) -> String {
        switch position {
        case .automatic:
            localization.string("settings.hud.position.automatic", defaultValue: "自动")
        case .above:
            localization.string("settings.hud.position.above", defaultValue: "优先显示在上方")
        case .below:
            localization.string("settings.hud.position.below", defaultValue: "优先显示在下方")
        case .screenCenter:
            localization.string("settings.hud.position.screen-center", defaultValue: "屏幕中央")
        case .atPointer:
            localization.string("settings.hud.position.at-pointer", defaultValue: "指针处")
        }
    }

    static func addApplication(
        store: AutoInputStore,
        controller: AutoInputController,
        localization: PluginLocalization,
        onChange: () -> Void
    ) {
        guard let defaultSource = controller.sources.first else { return }
        let panel = NSOpenPanel()
        panel.title = localization.string("openPanel.title", defaultValue: "选择应用")
        panel.message = localization.string("openPanel.message", defaultValue: "选择要自动切换输入法的应用")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty
        else { return }

        let existingSourceID = store.rule(for: bundleIdentifier)?.inputSourceID
        let sourceID = existingSourceID
            ?? controller.sources.first(where: { $0.id == controller.currentSourceID })?.id
            ?? defaultSource.id
        store.upsertRule(AutoInputRule(
            bundleIdentifier: bundleIdentifier,
            displayName: url.deletingPathExtension().lastPathComponent,
            bundleURL: url,
            inputSourceID: sourceID
        ))
        onChange()
    }

    private func applicationIcon(for rule: AutoInputRule) -> NSImage {
        guard let url = rule.bundleURL else {
            return NSWorkspace.shared.icon(forFile: "/Applications")
        }
        return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }

    private func ruleSubtitle(_ rule: AutoInputRule) -> String {
        guard isSourceAvailable(rule.inputSourceID) else {
            return localization.string("settings.source.unavailable", defaultValue: "输入法不可用")
        }
        return rule.bundleIdentifier
    }

    private func isSourceAvailable(_ id: String) -> Bool {
        controller.sources.contains { $0.id == id }
    }
}
